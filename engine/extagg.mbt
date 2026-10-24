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
  for batch in joined {
    partition_side(batch, group_exprs, writers)
  }
  for k in 0..<p {
    writers[k].flush()
  }
  if stats.length() > 0 {
    stats.push(("spill partitions", p.to_int64()))
  }
  errdefer remove_writers(store, writers)
  let out : Array[@types.DataBatch] = []
  let dtypes : Array[@types.DataType] = []
  for k in 0..<p {
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
