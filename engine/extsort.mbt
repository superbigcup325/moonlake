// External sort for ORDER BY (spill milestone M1).
//
// Sorted runs: every source batch is sorted in memory and split into
// chunks; chunks accumulate until ~budget/4 bytes, then flush as one
// run file. Reduce: pairwise merges until at most FANIN runs remain
// (memory per pass = two runs). Final pass: k-way merge streams rows
// through projection, DISTINCT and the OFFSET/LIMIT window, so the
// result — with a LIMIT — never materializes beyond the output window;
// without LIMIT the full result is the query's answer and is
// materialized as such.
//
// The budget bounds the run state, not the base tables (scan laziness
// is out of M1's scope) and not the query result itself.

///|
const FANIN : Int = 8

///|
priv struct RunReader {
  batches : Array[@types.DataBatch]
  mut bi : Int
  mut ri : Int
  mut row : Array[@types.Scalar] // current pre-projection row, empty when exhausted
  mut keys : Array[@types.Scalar] // key values of the current row
  width : Int
  types : Array[@types.DataType]
  keyspecs : Array[(PhysExpr, Bool, Bool?)]
}

///|
fn RunReader::exhausted(self : RunReader) -> Bool {
  self.row.length() == 0
}

///|
fn RunReader::advance(self : RunReader) -> Unit raise @types.SqlError {
  self.ri += 1
  if self.ri >= self.batches[self.bi].row_count() {
    self.bi += 1
    self.ri = 0
    if self.bi >= self.batches.length() {
      self.row = []
      self.keys = []
      return
    }
  }
  let batch = self.batches[self.bi]
  let row : Array[@types.Scalar] = []
  for c in 0..<self.width {
    row.push(batch.columns()[c].get(self.ri))
  }
  self.row = row
  let get : (Int) -> @types.Scalar = fn(i) { row[i] }
  let keys : Array[@types.Scalar] = []
  for kv in self.keyspecs {
    keys.push(eval_with(kv.0, get))
  }
  self.keys = keys
}

///|
fn RunReader::make(
  batches : Array[@types.DataBatch],
  keyspecs : Array[(PhysExpr, Bool, Bool?)],
) -> RunReader raise @types.SqlError {
  let width = if batches.length() > 0 {
    batches[0].columns().length()
  } else {
    0
  }
  let types : Array[@types.DataType] = []
  if batches.length() > 0 {
    for col in batches[0].columns() {
      types.push(col.dtype())
    }
  }
  let r : RunReader = {
    batches,
    bi: 0,
    ri: -1,
    row: [],
    keys: [],
    width,
    types,
    keyspecs,
  }
  if batches.length() > 0 {
    r.advance()
  }
  r
}

///|
/// Compare two key rows under (desc, nulls_first) specs; ties return 0
/// (caller breaks them, e.g. by run order for global stability).
fn cmp_key_rows(
  a : Array[@types.Scalar],
  b : Array[@types.Scalar],
  keyspecs : Array[(PhysExpr, Bool, Bool?)],
) -> Int {
  for k, kv in keyspecs {
    let x = a[k]
    let y = b[k]
    let nf = match kv.2 {
      Some(f) => f
      None => false
    }
    let ord : Int = match (x, y) {
      (@types.Null, @types.Null) => 0
      (@types.Null, _) => if nf { -1 } else { 1 }
      (_, @types.Null) => if nf { 1 } else { -1 }
      _ => {
        let c = @types.Scalar::compare_nn(x, y)
        if kv.1 {
          -c
        } else {
          c
        }
      }
    }
    if ord != 0 {
      return ord
    }
  }
  0
}

///|
fn estimate_batch_bytes(batch : @types.DataBatch) -> Int {
  let mut total = 16
  for col in batch.columns() {
    let n = col.len()
    total += 4
    match col.dtype() {
      @types.Int32 | @types.Date => total += 4 * n
      @types.Int64 | @types.Float64 => total += 8 * n
      @types.Bool => total += n
      @types.Str =>
        for r in 0..<n {
          match col.get(r) {
            @types.Str(s) => total += 4 + s.length() // chars as a byte proxy: budgets stay approximate
            _ => total += 1
          }
        }
    }
  }
  total
}

///|
fn chunk_of(
  batch : @types.DataBatch,
  from : Int,
  until : Int,
) -> @types.DataBatch {
  let indices : Array[Int] = []
  for r in from..<until {
    indices.push(r)
  }
  take_rows(batch, indices)
}

///|
/// Sorted-run accumulator over the spill store.
priv struct RunWriter {
  store : SpillStore
  budget : Int
  mut acc : Array[@types.DataBatch]
  mut acc_bytes : Int
  ids : Array[Int] // spill file ids in run order
}

///|
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
fn RunWriter::flush(self : RunWriter) -> Unit raise @types.SqlError {
  if self.acc.length() == 0 {
    return
  }
  let id = (self.store.write)(@types.DataBatch::to_spill_bytes(self.acc))
  self.ids.push(id)
  self.acc = []
  self.acc_bytes = 0
}

///|
/// External sort driving the whole ORDER BY tail: returns the final
/// projected (and DISTINCT/OFFSET/LIMIT-filtered) batch. Falls back to
/// the in-memory pipeline when everything fits within the run
/// accumulator.
fn external_sort_project(
  kept : Array[@types.DataBatch],
  keys : Array[(PhysExpr, Bool, Bool?)],
  out_exprs : Array[PhysExpr],
  out_types : Array[@types.DataType],
  distinct : Bool,
  offset : Int?,
  limit : Int?,
  budget : Int,
  store : SpillStore,
  stats : Array[(String, Int)],
) -> @types.DataBatch raise @types.SqlError {
  let writer : RunWriter = { store, budget, acc: [], acc_bytes: 0, ids: [], }
  for batch in kept {
    if keys.length() > 0 && batch.row_count() > 1 {
      let sorted = sort_exprs(batch, keys, None, None)
      // split oversized sorted batches so one run cannot balloon past
      // the accumulator by itself
      let bytes = estimate_batch_bytes(sorted)
      let per_row = if sorted.row_count() > 0 {
        bytes / sorted.row_count()
      } else {
        1
      }
      let chunk_rows = if per_row > 0 {
        budget / 8 / per_row
      } else {
        sorted.row_count()
      }
      if chunk_rows >= sorted.row_count() || chunk_rows < 1 {
        writer.push(sorted)
      } else {
        let mut from = 0
        while from < sorted.row_count() {
          let until = if from + chunk_rows < sorted.row_count() {
            from + chunk_rows
          } else {
            sorted.row_count()
          }
          writer.push(chunk_of(sorted, from, until))
          from = until
        }
      }
    } else {
      writer.push(batch)
    }
  }
  // everything fit: no run was flushed — take the in-memory path
  if writer.ids.length() == 0 {
    let dts : Array[@types.DataType] = []
    for col in kept[0].columns() {
      dts.push(col.dtype())
    }
    let pre = concat_batches(kept, dts)
    let sorted = sort_exprs(pre, keys, None, None)
    return finish_sorted(sorted, out_exprs, out_types, distinct, offset, limit)
  }
  writer.flush()
  if stats.length() > 0 {
    stats.push(("spill runs", writer.ids.length()))
  }
  errdefer (for id in writer.ids {
    let _ = (store.remove)(id)
  })
  let out = reduce_and_merge(
    writer.ids,
    keys,
    out_exprs,
    out_types,
    distinct,
    offset,
    limit,
    store,
  )
  for id in writer.ids {
    let _ = (store.remove)(id)
  }
  out
}

///|
/// Pairwise-merge runs down to FANIN, then run the final streaming
/// merge. Removes every intermediate file it creates, successfully or
/// not.
fn reduce_and_merge(
  runs0 : Array[Int],
  keys : Array[(PhysExpr, Bool, Bool?)],
  out_exprs : Array[PhysExpr],
  out_types : Array[@types.DataType],
  distinct : Bool,
  offset : Int?,
  limit : Int?,
  store : SpillStore,
) -> @types.DataBatch raise @types.SqlError {
  let created : Array[Int] = [] // intermediate files this function wrote
  errdefer (for id in created {
    let _ = (store.remove)(id)
  })
  fn go(level : Array[Int]) -> @types.DataBatch raise @types.SqlError {
    let mut cur = level
    while cur.length() > FANIN {
      let next : Array[Int] = []
      let mut i = 0
      while i < cur.length() {
        if i + 1 < cur.length() {
          let id = merge_runs(cur[i], cur[i + 1], keys, store)
          created.push(id)
          next.push(id)
        } else {
          next.push(cur[i])
        }
        i += 2
      }
      cur = next
    }
    final_merge(cur, keys, out_exprs, out_types, distinct, offset, limit, store)
  }

  go(runs0)
}

///|
fn final_merge(
  runs : Array[Int],
  keys : Array[(PhysExpr, Bool, Bool?)],
  out_exprs : Array[PhysExpr],
  out_types : Array[@types.DataType],
  distinct : Bool,
  offset : Int?,
  limit : Int?,
  store : SpillStore,
) -> @types.DataBatch raise @types.SqlError {
  let readers : Array[RunReader] = []
  for id in runs {
    readers.push(
      RunReader::make(
        @types.DataBatch::from_spill_bytes((store.read)(id)),
        keys,
      ),
    )
  }
  let mut builder = OutputBuilder::new(out_types, 4096)
  let chunks : Array[@types.DataBatch] = []
  let seen : Map[String, Bool] = Map([])
  let mut skipped = 0
  let want = match limit {
    Some(l) => l
    None => -1 // unbounded
  }
  let mut taken = 0
  while want < 0 || taken < want {
    // pick the smallest current row; ties prefer the lower run index
    let mut best = -1
    for r, rd in readers {
      if rd.exhausted() {
        continue
      }
      if best == -1 || cmp_key_rows(rd.keys, readers[best].keys, keys) < 0 {
        best = r
      }
    }
    if best == -1 {
      break
    }
    let row = readers[best].row
    if offset is Some(o) && skipped < o {
      skipped += 1
    } else {
      let get : (Int) -> @types.Scalar = fn(i) { row[i] }
      let projected : Array[@types.Scalar] = []
      for e in out_exprs {
        projected.push(eval_with(e, get))
      }
      let mut keep = true
      if distinct {
        let kv = canonical_key(projected)
        if seen.get(kv) is Some(_) {
          keep = false
        } else {
          seen[kv] = true
        }
      }
      if keep {
        builder.push_row(projected)
        taken += 1
        if builder.full() {
          chunks.push(builder.build())
          builder = OutputBuilder::new(out_types, 4096)
        }
      }
    }
    readers[best].advance()
  }
  if !builder.empty() {
    chunks.push(builder.build())
  }
  concat_batches(chunks, out_types)
}

///|
/// Merge two run files into a new one (row payloads only, ordering
/// preserved). Memory = the two inputs plus the merged buffer.
fn merge_runs(
  a : Int,
  b : Int,
  keys : Array[(PhysExpr, Bool, Bool?)],
  store : SpillStore,
) -> Int raise @types.SqlError {
  let ra = RunReader::make(
    @types.DataBatch::from_spill_bytes((store.read)(a)),
    keys,
  )
  let rb = RunReader::make(
    @types.DataBatch::from_spill_bytes((store.read)(b)),
    keys,
  )
  let chunks : Array[@types.DataBatch] = []
  let mut builder = OutputBuilder::new(ra.types, 4096)
  while !(ra.exhausted() && rb.exhausted()) {
    let take_a = if ra.exhausted() {
      false
    } else if rb.exhausted() {
      true
    } else {
      cmp_key_rows(ra.keys, rb.keys, keys) <= 0 // ties prefer the earlier run: global stability
    }
    let row = if take_a { ra.row } else { rb.row }
    builder.push_row(row)
    if builder.full() {
      chunks.push(builder.build())
      builder = OutputBuilder::new(ra.types, 4096)
    }
    if take_a {
      ra.advance()
    } else {
      rb.advance()
    }
  }
  if !builder.empty() {
    chunks.push(builder.build())
  }
  let id = (store.write)(@types.DataBatch::to_spill_bytes(chunks))
  (store.remove)(a)
  (store.remove)(b)
  id
}

///|
/// Column builder for streamed output rows.
priv struct OutputBuilder {
  types : Array[@types.DataType]
  cap : Int
  mut filled : Int
  cols : Array[@types.ColumnVector]
}

///|
fn OutputBuilder::new(
  types : Array[@types.DataType],
  cap : Int,
) -> OutputBuilder {
  let cols : Array[@types.ColumnVector] = []
  for dt in types {
    cols.push(@types.ColumnVector::make(dt, cap))
  }
  { types, cap, filled: 0, cols, }
}

///|
fn OutputBuilder::full(self : OutputBuilder) -> Bool {
  self.filled == self.cap
}

///|
fn OutputBuilder::empty(self : OutputBuilder) -> Bool {
  self.filled == 0
}

///|
fn OutputBuilder::push_row(
  self : OutputBuilder,
  row : Array[@types.Scalar],
) -> Unit {
  for c in 0..<self.types.length() {
    self.cols[c].set(self.filled, row[c])
  }
  self.filled += 1
}

///|
fn OutputBuilder::build(self : OutputBuilder) -> @types.DataBatch {
  @types.DataBatch::new(self.cols, self.filled)
}

///|
/// The in-memory tail for the everything-fit fallback: sort, project,
/// dedupe, window.
fn finish_sorted(
  sorted : @types.DataBatch,
  out_exprs : Array[PhysExpr],
  out_types : Array[@types.DataType],
  distinct : Bool,
  offset : Int?,
  limit : Int?,
) -> @types.DataBatch raise @types.SqlError {
  let projected = project(sorted, out_exprs, out_types)
  let projected = if distinct { dedupe_rows(projected) } else { projected }
  order_limit(projected, [], limit, offset)
}
