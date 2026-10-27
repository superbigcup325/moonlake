///|
/// Cap on how many hash partitions one aggregation may create. The join caps
/// at 256 and splits an over-budget partition again; aggregation cannot
/// recurse (a group's state must stay in one partition), so it stays lower.
const AGG_PARTITION_CAP : Int32 = 64

// Grace hash aggregation: when a GROUP BY's input
// exceeds the memory budget, the input is partitioned by the hash of
// its group keys into per-partition spill runs (the same SpillStore the
// sort and the join use), and the existing in-memory aggregate() runs
// one partition at a time. Equal group keys always land in the same
// partition, so each partition's group rows are FINAL — median,
// string_agg and count-distinct state never spans partitions, and no
// combine phase exists. The engine still never touches the filesystem.

///|
/// Dispatch a GROUP BY aggregation under the memory budget: within
/// budget (or budget-less, or a global aggregate with no GROUP BY) the
/// historical in-memory aggregate() runs; over budget the aggregation
/// spills (grace hash) when a store is provided, and is a clean error
/// without one.
fn aggregate_within_budget(
  joined : Array[@types.DataBatch],
  group_exprs : Array[PhysExpr],
  group_types : Array[@types.DataType],
  aggs : Array[AggSpec],
  opts : ExecOptions,
  stats : Array[(String, Int64)],
) -> @types.DataBatch raise @types.SqlError {
  if opts.budget <= 0 || group_exprs.length() == 0 {
    return aggregate(joined, group_exprs, group_types, aggs)
  }
  if batches_bytes(joined) <= opts.budget {
    return aggregate(joined, group_exprs, group_types, aggs)
  }
  match opts.spill {
    Some(store) =>
      grace_agg(
        joined,
        group_exprs,
        group_types,
        aggs,
        opts.budget,
        store,
        stats,
      )
    None =>
      raise @types.SqlError::Execute(
        "aggregate input exceeds the memory budget (\{batches_bytes(joined)} bytes > \{opts.budget}); provide a spill store (--spill-dir) or raise the budget (--memory)",
      )
  }
}

///|
/// Grace hash aggregation: partition the input by group-key hash into
/// spill runs, aggregate each partition in memory (its group rows are
/// final), and concatenate. P is derived from the estimated input bytes
/// so a partition's input fits the budget; a partition that still
/// overflows (few distinct keys — every row of a group shares its
/// partition) aggregates in memory, exceeding the budget for that
/// partition only — group state cannot be split further without a
/// combine phase (future work).
fn grace_agg(
  joined : Array[@types.DataBatch],
  group_exprs : Array[PhysExpr],
  group_types : Array[@types.DataType],
  aggs : Array[AggSpec],
  budget : Int32,
  store : SpillStore,
  stats : Array[(String, Int64)],
) -> @types.DataBatch raise @types.SqlError {
  let p = partition_count(batches_bytes(joined), budget, AGG_PARTITION_CAP)
  let writers : Array[RunWriter] = []
  for _ in 0..<p {
    writers.push(RunWriter::partitioned(store, budget))
  }
  // registered before the first run is written: a failure while partitioning or
  // flushing must remove the runs already on disk
  errdefer remove_writers(store, writers)
  for batch in joined {
    partition_side(batch, group_exprs, writers)
  }
  for k in 0..<p {
    writers[k].flush()
  }
  if stats.length() > 0 {
    stats.push(("spill partitions", p.to_int64()))
  }
  grace_finish(store, writers, group_exprs, group_types, aggs)
}

///|
/// Aggregate every partition the writers hold, one run at a time, remove their
/// files and concatenate the groups. Shared by the collected and the pulled
/// grace aggregation: both end with every partition's runs on the store.
fn grace_finish(
  store : SpillStore,
  writers : Array[RunWriter],
  group_exprs : Array[PhysExpr],
  group_types : Array[@types.DataType],
  aggs : Array[AggSpec],
) -> @types.DataBatch raise @types.SqlError {
  let out : Array[@types.DataBatch] = []
  let dtypes : Array[@types.DataType] = []
  for k in 0..<writers.length() {
    if writers[k].ids.length() == 0 {
      continue // more partitions than distinct keys: nothing to aggregate
    }
    // pull the partition one run at a time: a hot group key can make a
    // partition far larger than the budget, and materializing it first
    // would defeat the budget entirely
    let grouped = aggregate_seq(
      BatchSeq::of_runs(store, writers[k].ids),
      group_exprs,
      group_types,
      aggs,
    )
    if dtypes.is_empty() {
      for col in grouped.columns() {
        dtypes.push(col.dtype())
      }
    }
    out.push(grouped)
  }
  remove_writers(store, writers)
  concat_batches(out, dtypes)
}

///|
/// The smallest run worth writing when the input size is not known: the shared
/// pool is split over at most `budget / 4 / AGG_MIN_RUN` partitions, so a small
/// budget does not turn into many tiny files. Measured on 8M rows, 100 groups,
/// at 16M and 32M budgets: 64 KiB gave 64 partitions and ran 20% slower than the
/// collected path (every batch is split 64 ways), 256 KiB stayed within 6% of it
/// at every budget tried, and 1 MiB within 7%.
const AGG_MIN_RUN : Int32 = 262144

///|
/// Partition count for a pulled aggregation: fixed by the budget alone, because
/// the input size is not known when the first batch overflows.
fn agg_pull_partitions(budget : Int32) -> Int32 {
  let mut p = budget / 4 / AGG_MIN_RUN
  if p < 2 {
    p = 2
  }
  if p > AGG_PARTITION_CAP {
    p = AGG_PARTITION_CAP
  }
  p
}

///|
/// The partition writers of one pulled aggregation and the single buffer they
/// share. Each writer used to hold its own `budget / 4`, so up to 64 of them
/// could keep 16 times the budget; here the buffers add up to `limit`, and when
/// they do not fit the largest one is written out as a run.
priv struct PartitionPool {
  writers : Array[RunWriter]
  limit : Int32
  mut pooled : Int32
  // the most the shared buffers held at once, before the flush that brought
  // them back under `limit`
  mut peak : Int32
  // estimated in-memory bytes each partition has written out as runs
  spilled : Array[Int64]
}

///|
/// Route each row of `batch` into its key-hash partition buffer, then write out
/// the largest buffers until the pool fits again.
fn PartitionPool::add(
  self : PartitionPool,
  batch : @types.DataBatch,
  key_exprs : Array[PhysExpr],
) -> Unit raise @types.SqlError {
  let p = self.writers.length()
  let key_vecs : Array[@types.ColumnVector] = []
  for e in key_exprs {
    key_vecs.push(eval_vec(e, batch))
  }
  let idx : Array[Array[Int32]] = []
  for _ in 0..<p {
    idx.push([])
  }
  for r in 0..<batch.row_count() {
    idx[key_partition(key_vecs, r, p)].push(r)
  }
  for k in 0..<p {
    if idx[k].length() > 0 {
      let part = take_rows(batch, idx[k])
      let bytes = estimate_batch_bytes(part)
      self.writers[k].stage(part, bytes)
      self.pooled += bytes
    }
  }
  if self.pooled > self.peak {
    self.peak = self.pooled
  }
  while self.pooled > self.limit {
    self.flush_largest()
  }
}

///|
/// Write the largest buffer as one run and release what it held.
fn PartitionPool::flush_largest(
  self : PartitionPool,
) -> Unit raise @types.SqlError {
  let mut best = 0
  for k in 1..<self.writers.length() {
    if self.writers[k].acc_bytes > self.writers[best].acc_bytes {
      best = k
    }
  }
  let w = self.writers[best]
  let held = w.acc_bytes
  if held == 0 {
    self.pooled = 0
    return
  }
  w.flush()
  self.pooled -= held
  self.spilled[best] += held.to_int64()
}

///|
/// What a pulled aggregation hands back besides its groups: how many partitions
/// it spilled into (0 when it fit its budget), the most input bytes it held at
/// once, and the most one partition wrote out. Both byte counts are the
/// engine's size estimate (`estimate_batch_bytes`), not file sizes.
priv struct PulledAgg {
  batch : @types.DataBatch
  partitions : Int32
  peak_buffered : Int64
  largest_spilled : Int64
}

///|
/// A GROUP BY under `--memory`, fed from a pull instead of a collected input.
/// Batches are buffered while their estimated bytes (summed in 64 bits) stay
/// within the budget; if the pull ends first, the buffered batches are aggregated
/// exactly as the within-budget path does and no spill store is needed. The first
/// overflow needs one: the buffer is then routed into a fixed number of hash
/// partitions that share one `budget / 4` pool, the rest of the pull follows, and
/// each partition is aggregated run by run. Retained input is the budget plus one
/// scan batch, whatever the total row count; group state and the grouped result
/// are not bounded by this. The result carries the counters `PulledAgg` names.
fn aggregate_pulled(
  next : () -> @types.DataBatch? raise @types.SqlError,
  group_exprs : Array[PhysExpr],
  group_types : Array[@types.DataType],
  aggs : Array[AggSpec],
  opts : ExecOptions,
) -> PulledAgg raise @types.SqlError {
  let limit = opts.budget.to_int64()
  let buffered : Array[@types.DataBatch] = []
  let mut bytes = 0L
  let mut exhausted = false
  while !exhausted && bytes <= limit {
    match next() {
      Some(batch) => {
        buffered.push(batch)
        bytes += estimate_batch_bytes(batch).to_int64()
      }
      None => exhausted = true
    }
  }
  if exhausted {
    return {
      batch: aggregate(buffered, group_exprs, group_types, aggs),
      partitions: 0,
      peak_buffered: bytes,
      largest_spilled: 0L,
    }
  }
  let store = match opts.spill {
    Some(store) => store
    None =>
      raise @types.SqlError::Execute(
        "aggregate input exceeds the memory budget (\{bytes} bytes > \{opts.budget}); provide a spill store (--spill-dir) or raise the budget (--memory)",
      )
  }
  let p = agg_pull_partitions(opts.budget)
  let writers : Array[RunWriter] = []
  for _ in 0..<p {
    writers.push(RunWriter::partitioned(store, opts.budget))
  }
  // registered before the first run is written, so a failing source, a failing
  // store and a failing aggregation all leave through the same removal
  errdefer remove_writers(store, writers)
  let spilled : Array[Int64] = []
  for _ in 0..<p {
    spilled.push(0L)
  }
  let pool : PartitionPool = {
    writers,
    limit: opts.budget / 4,
    pooled: 0,
    peak: 0,
    spilled,
  }
  // drain the buffer front to back while releasing it, so it shrinks as the
  // pool fills instead of both being resident
  buffered.rev_in_place()
  while buffered.pop() is Some(batch) {
    pool.add(batch, group_exprs)
  }
  while next() is Some(batch) {
    pool.add(batch, group_exprs)
  }
  for k in 0..<p {
    // what is still buffered is written now, so it counts toward its partition
    pool.spilled[k] += writers[k].acc_bytes.to_int64()
    writers[k].flush()
  }
  let mut largest = 0L
  for s in pool.spilled {
    if s > largest {
      largest = s
    }
  }
  let peak = pool.peak.to_int64()
  {
    batch: grace_finish(store, writers, group_exprs, group_types, aggs),
    partitions: p,
    // the buffer drains into the pool, so the most held at once is whichever
    // of the two phases was larger
    peak_buffered: if peak > bytes {
      peak
    } else {
      bytes
    },
    largest_spilled: largest,
  }
}
