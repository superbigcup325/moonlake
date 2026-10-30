// Shared spill-run machinery: the part of spilling that the external sort, the
// grace hash join and the grace hash aggregation all do.
//
// A run file is a serialized batch sequence, so the store never sees a row.
// Writers accumulate batches until ~budget/4 bytes and flush one run; the three
// algorithms differ only in whether a run is sorted before it is written, in
// how rows are routed into writers, and in how the runs are read back. Keeping
// the shared half here is what makes "remove what you wrote on both exit paths"
// a single call instead of a loop each caller copies.
//
// The engine still never touches the filesystem: everything goes through the
// injected SpillStore.

///|
/// What a batch costs before it holds a cell, and what each of its columns costs
/// before it holds one: the batch record, the column array, and per column the
/// vector's two arrays with their headers. Fitted from a probe that kept 50,000 to
/// 200,000 small pieces alive in a native process and read the resident bytes
/// (contract: docs/ROADMAP.md, "The partition piece cost contract"): about 157
/// bytes a piece and 58-70 a column, on top of the cells and their validity bytes.
/// A partitioner cuts every batch into many pieces of a few rows, so these
/// constants, not the cells, are most of what a piece costs.
const BATCH_FIXED_BYTES : Int32 = 160

///|
const COLUMN_FIXED_BYTES : Int32 = 64

///|
/// Estimated in-memory size of one batch: the unit the budgets here count
/// in. Approximate on purpose -- it decides when to flush a run, not whether
/// a result is right.
fn estimate_batch_bytes(batch : @types.DataBatch) -> Int32 {
  let mut total = BATCH_FIXED_BYTES
  for col in batch.columns() {
    let n = col.len()
    total += COLUMN_FIXED_BYTES
    match col.dtype() {
      @types.Int32 | @types.Date => total += 4 * n
      @types.Int64 | @types.Float64 => total += 8 * n
      @types.Bool => total += n
      // chars as a byte proxy: budgets stay approximate; the column reads its
      // own array rather than one Scalar per row (a budgeted step asks for this
      // on every side of every step, and a wide join makes that millions of rows)
      @types.Str => total += col.str_cell_bytes()
    }
  }
  total
}

///|
/// The bytes a batch really occupies, as a report should count them: the
/// estimate's cells and overheads plus the validity array every column
/// carries, one byte a cell. The budget deliberately keeps counting only
/// `estimate_batch_bytes` (contract: docs/ROADMAP.md, "The resident bytes
/// contract"): adding the validity byte to the bound made partitions smaller
/// and peaks higher (§76), so the bound keeps the unit that measured better and
/// the report names the whole structure.
fn resident_batch_bytes(batch : @types.DataBatch) -> Int64 {
  let mut total = estimate_batch_bytes(batch).to_int64()
  for col in batch.columns() {
    total += col.len().to_int64()
  }
  total
}

///|
fn resident_batches_bytes(batches : Array[@types.DataBatch]) -> Int64 {
  let mut total = 0L
  for b in batches {
    total += resident_batch_bytes(b)
  }
  total
}

///|
/// Total estimated byte size of a batch array.
fn batches_bytes(batches : Array[@types.DataBatch]) -> Int32 {
  let mut total = 0
  for b in batches {
    total += estimate_batch_bytes(b)
  }
  total
}

///|
/// Sorted-run accumulator over the spill store.
priv struct RunWriter {
  store : SpillStore
  budget : Int32
  sort_keys : Array[(PhysExpr, Bool, Bool?)] // empty: partitions (join/agg), not sorted runs
  mut acc : Array[@types.DataBatch]
  mut acc_bytes : Int32
  ids : Array[Int32] // spill file ids in run order
}

///|
/// A writer that does not sort its runs: it exists to route rows into
/// partitions (join and aggregation), not to produce a sorted stream.
fn RunWriter::partitioned(store : SpillStore, budget : Int32) -> RunWriter {
  { store, budget, sort_keys: [], acc: [], acc_bytes: 0, ids: [], }
}

///|
/// Add a batch to the current run, flushing first when the accumulator is full.
fn RunWriter::push(
  self : RunWriter,
  batch : @types.DataBatch,
) -> Unit raise @types.SqlError {
  let bytes = estimate_batch_bytes(batch)
  // flush before pushing when the accumulator is full: a run never
  // grows past ~budget/4 unless a single chunk is larger on its own
  if self.acc.length() > 0 && self.acc_bytes + bytes > self.budget / 4 {
    self.flush()
  }
  self.acc.push(batch)
  self.acc_bytes += bytes
}

///|
/// Add a batch to the current run without the per-writer size check: the caller
/// owns the budget for a group of writers (see `PartitionPool`) and decides which
/// writer to flush. `bytes` is the batch's estimate, so it is not computed twice.
fn RunWriter::stage(
  self : RunWriter,
  batch : @types.DataBatch,
  bytes : Int32,
) -> Unit {
  self.acc.push(batch)
  self.acc_bytes += bytes
}

///|
/// Write the accumulated batches as one run file, then start a new run.
fn RunWriter::flush(self : RunWriter) -> Unit raise @types.SqlError {
  if self.acc.length() == 0 {
    return
  }
  // A run file is read back as ONE sorted stream (RunReader assumes that), but
  // the accumulator holds several independently sorted chunks/batches. Writing
  // them back to back made every multi-chunk run only piecewise sorted, and the
  // k-way merge then leaked chunk heads into the result: with a 1 MB budget the
  // spilled ORDER BY over SF0.1 returned a top-3 whose maximum was below the
  // true maximum (a smaller budget happened to hold one chunk per run, which is
  // why the 200 KB acceptance check stayed green). Sort the run before writing;
  // the accumulator is bounded by budget/4, which is the same bound the merge
  // passes work under.
  let payload = if self.sort_keys.length() > 0 {
    let dts : Array[@types.DataType] = []
    for col in self.acc[0].columns() {
      dts.push(col.dtype())
    }
    [sort_exprs(concat_batches(self.acc, dts), self.sort_keys, None, None)]
  } else {
    self.acc
  }
  let id = (self.store.write)(@types.DataBatch::to_spill_bytes(payload))
  self.ids.push(id)
  self.acc = []
  self.acc_bytes = 0
}

///|
/// Remove every spill file `ids` names.
///
/// The `let _` discards a unit result, not an error: a store whose delete
/// raises still fails the caller, exactly as the inline loops did before. This
/// runs on error paths too, where a second failure must not be hidden.
fn remove_ids(
  store : SpillStore,
  ids : Array[Int32],
) -> Unit raise @types.SqlError {
  for id in ids {
    let _ = (store.remove)(id)
  }
}

///|
/// Remove every run file of every writer. One call per exit path: a caller that
/// removes only on success leaks its runs when the query fails.
fn remove_writers(
  store : SpillStore,
  writers : Array[RunWriter],
) -> Unit raise @types.SqlError {
  for w in writers {
    remove_ids(store, w.ids)
  }
}

///|
/// Remove both sides of a join. A join spills its left and right input into
/// two writer arrays and must drop both on every exit path, success included.
fn remove_writer_sides(
  store : SpillStore,
  wl : Array[RunWriter],
  wr : Array[RunWriter],
) -> Unit raise @types.SqlError {
  remove_writers(store, wl)
  remove_writers(store, wr)
}

///|
/// One FNV-1a mixing step.
fn mix32(h : Int32, v : Int32) -> Int32 {
  (h ^ v) * 16777619
}

///|
/// Partition id for row `r` of the key vectors: FNV-1a over the key
/// values (a NULL key component contributes a fixed marker), reduced
/// modulo `p`. Equal keys land in the same partition; distinct keys may
/// share one, which the per-partition join resolves.
fn key_partition(
  keys : Array[@types.ColumnVector],
  r : Int32,
  p : Int32,
) -> Int32 {
  // 2166136261 (the FNV offset basis) as a 32-bit two's complement
  let mut h = -2128831035
  for kv in keys {
    match kv.get(r) {
      @types.Null => h = mix32(h, -2128831035)
      @types.Boolean(v) => h = mix32(h, if v { 1 } else { 2 })
      @types.Int32(v) => h = mix32(h, v)
      @types.Int64(v) => h = mix32(h, v.to_int())
      @types.Float64(v) => h = mix32(h, v.to_int())
      @types.Str(s) =>
        for ch in s {
          h = mix32(h, ch.to_int())
        }
      @types.Date(v) => h = mix32(h, v)
    }
  }
  let m = h % p
  if m < 0 {
    m + p
  } else {
    m
  }
}

///|
/// Route each row of `batch` into its key-hash partition writer.
fn partition_side(
  batch : @types.DataBatch,
  key_exprs : Array[PhysExpr],
  writers : Array[RunWriter],
) -> Unit raise @types.SqlError {
  let p = writers.length()
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
      writers[k].push(take_rows(batch, idx[k]))
    }
  }
}

///|
/// Read one partition's spill runs back as batches (each spill file
/// deserializes to the batch sequence that was written into it).
fn read_partition(
  store : SpillStore,
  ids : Array[Int32],
) -> Array[@types.DataBatch] raise @types.SqlError {
  let out : Array[@types.DataBatch] = []
  for id in ids {
    let bs = @types.DataBatch::from_spill_bytes((store.read)(id))
    for b in bs {
      out.push(b)
    }
  }
  out
}

///|
/// How many hash partitions to make for `bytes` under `budget`: proportional to
/// the input, at least two, at most `cap`. The four-to-one ratio keeps a
/// partition near budget/4, the bound a run writer works under.
///
/// `cap` is the caller's: the join recurses (so it may split a partition
/// again) and allows more partitions per level than the aggregation, which
/// cannot recurse because a group's state must stay in one partition.
fn partition_count(bytes : Int32, budget : Int32, cap : Int32) -> Int32 {
  let mut p = bytes * 4 / budget + 1
  if p < 2 {
    p = 2
  }
  if p > cap {
    p = cap
  }
  p
}
