// Joins: the left-deep chain over the FROM tables, the hash join and its
// grace-spill fallback (engine/extjoin.mbt), the semi/anti and swapped-right
// forms that decorrelate EXISTS/IN, and the residual machinery that rechecks
// the predicates a hash key cannot decide -- OR arms, Kleene tri-state, reduced
// rows.

///|
/// Execute the planned join chain left-deep over the FROM tables.
/// `prescanned[t]` says table t's build filter already ran during the scan,
/// so the rows reaching here satisfy it and filtering again would be waste.
fn exec_joins(
  tables : Array[Array[@types.DataBatch]],
  steps : Array[JoinStep],
  deferred : PhysExpr?,
  opts : ExecOptions,
  stats : Array[(String, Int64)],
  prescanned : Array[Bool],
  census~ : MemCensus? = None,
) -> Array[@types.DataBatch] raise @types.SqlError {
  if steps.length() == 0 {
    let cols : Array[@types.ColumnVector] = []
    return filter_batches([@types.DataBatch::new(cols, 1)], deferred)
  }
  // A census point in a step names the tables still alive and whatever that step
  // copies on top (§61). Which ones are alive changes: a step releases the
  // tables whose last step it was, so the total is read at the point, not once
  // before the loop.
  let mut acc = tables[steps[0].table]
  for i, step in steps {
    if i == 0 {
      if !prescanned[step.table] {
        acc = filter_batches(acc, step.build_filter)
      }
    } else {
      acc = filter_batches(acc, step.probe_filter)
      let right = if prescanned[step.table] {
        tables[step.table]
      } else {
        filter_batches(tables[step.table], step.build_filter)
      }
      match census {
        Some(c) => {
          // the roots this step stands on: the tables still alive, the probe
          // input once it is a step's own output, the filtered build scan if the
          // eager path just made one (a prescanned table is already counted)
          let extra : Array[(String, Int64)] = [
            ("collected FROM tables", alive_bytes(tables)),
          ]
          extra.push(("probe input", resident_batches_bytes(acc)))
          // a scan the eager path did not pre-filter, and a predicate to apply,
          // means `right` is a fresh compacted copy; without the predicate
          // `filter_batches` hands the table's own batches back, already counted
          if !prescanned[step.table] && step.build_filter is Some(_) {
            extra.push(("filtered build scan", resident_batches_bytes(right)))
          }
          acc = join_or_spill(
            acc,
            right,
            step,
            opts,
            stats,
            census=Some(c),
            extra~,
            tag="step \{i}",
          )
        }
        None => acc = join_or_spill(acc, right, step, opts, stats)
      }
    }
    // The tables whose last step was this one have no reader left: the plan is
    // left-deep, every table appears in the step that joins it, and nothing
    // re-scans. Letting go of them here is what keeps a finished table out of
    // the live set at the steps that come after — including the peak (§66).
    for t in tables_finished_at(steps, i) {
      tables[t] = []
    }
  }
  filter_batches(acc, deferred)
}

///|
/// The bytes of the tables still alive, for a census point.
fn alive_bytes(tables : Array[Array[@types.DataBatch]]) -> Int64 {
  let mut total = 0L
  for t in tables {
    total += resident_batches_bytes(t)
  }
  total
}

///|
/// The table indexes whose last step is step `i`: after that step runs, nothing
/// in the chain names them again. A table used by several steps (a self-join)
/// is finished only by the last of them.
fn tables_finished_at(steps : Array[JoinStep], i : Int32) -> Array[Int32] {
  let out : Array[Int32] = []
  for j, s in steps {
    let mut last = j
    for k, u in steps {
      if u.table == s.table {
        last = k
      }
    }
    if last == i && !out.contains(s.table) {
      out.push(s.table)
    }
  }
  out
}

///|
/// One join step under the memory budget: within budget the historical
/// in-memory join_step runs; over budget the join spills (grace hash
/// join) when a store is provided, and is a clean error without one.
fn join_or_spill(
  acc : Array[@types.DataBatch],
  right : Array[@types.DataBatch],
  step : JoinStep,
  opts : ExecOptions,
  stats : Array[(String, Int64)],
  census~ : MemCensus? = None,
  extra~ : Array[(String, Int64)] = [],
  tag~ : String = "",
) -> Array[@types.DataBatch] raise @types.SqlError {
  if opts.budget <= 0 {
    // no budget: nothing downstream will partition this output, so the step's
    // collected batches are handed on as they are (§65)
    return join_step(acc, right, step, census~, extra~, tag~)
  }
  // With a budget the eager path hands the next step (or the partitioner) one
  // batch a side, as it always did: a chain of many small batches costs a
  // partitioner a copy per batch per partition, and holding the handover's
  // batch and its copy at once measured worse than not collapsing (§65).
  let total = batches_bytes(acc) + batches_bytes(right)
  if total <= opts.budget {
    return join_step(acc, right, step, census~, extra~, tag~, collapse=true)
  }
  match opts.spill {
    Some(store) => {
      if step.keys_l.length() == 0 {
        raise @types.SqlError::Execute(
          "cross join input exceeds the memory budget (\{total} bytes > \{opts.budget}); a cross join has no keys to partition on",
        )
      }
      // The build side fits the budget: nothing has to be partitioned. The
      // step's hash side is the whole build, its probe side streams past it a
      // batch at a time, and the working set is the build plus its index plus
      // the output — the same set the `total <= budget` case above already
      // allows, minus the probe side (§81, measurement in docs/verification.md).
      // A RIGHT step builds from the accumulated side instead, so it is not
      // this check's shape.
      let build_fits = match step.kind {
        Right => false
        _ => batches_bytes(right) * 2 <= opts.budget
      }
      if build_fits {
        return join_step(acc, right, step, census~, extra~, tag~, collapse=true)
      }
      // The mirror: the accumulated side is what fits, so it becomes the hash
      // side and the table streams past it — the trick the join+aggregate path
      // already uses for its last step, with no partitioner in between (§82).
      // INNER only: a LEFT or FULL step owes its unmatched rows to the side that
      // would become the build side.
      let probe_fits = match step.kind {
        Inner => batches_bytes(acc) * 2 <= opts.budget
        _ => false
      }
      if probe_fits {
        return join_swapped_stream(acc, right, step, census~, extra~, tag~)
      }
      collapse_handed(
        grace_join(acc, right, step, opts.budget, store, stats, census~),
        step,
      )
    }
    None =>
      raise @types.SqlError::Execute(
        "join input exceeds the memory budget (\{total} bytes > \{opts.budget}); provide a spill store (--spill-dir) or raise the budget (--memory)",
      )
  }
}

///|
/// One INNER step with the roles put back: the accumulated rows are small enough
/// to become the hash side whole, and the table streams past them a batch at a
/// time through `SwapCursor`. The output is the step's combined layout, in
/// batches of at most `JOIN_OUT_BATCH` (contract and measurement: §82).
fn join_swapped_stream(
  acc : Array[@types.DataBatch],
  right : Array[@types.DataBatch],
  step : JoinStep,
  census~ : MemCensus? = None,
  extra~ : Array[(String, Int64)] = [],
  tag~ : String = "",
) -> Array[@types.DataBatch] raise @types.SqlError {
  let left_width = step.out_dtypes.length() - step.right_width
  let prefix = concat_batches(acc, head_dtypes(step.out_dtypes, left_width))
  let mut at = 0
  let next_right : () -> @types.DataBatch? raise @types.SqlError = fn() {
    if at < right.length() {
      let b = right[at]
      at += 1
      Some(b)
    } else {
      None
    }
  }
  let cursor = SwapCursor::open(step, prefix, next_right)
  let out : Array[@types.DataBatch] = []
  while cursor.next() is Some(b) {
    out.push(b)
  }
  match census {
    Some(c) => {
      // the point where the swapped step's own pieces are all live: the prefix
      // copy that became the hash side, its index, and the output so far
      let entries = extra.copy()
      entries.push(("prefix copy", resident_batch_bytes(prefix)))
      entries.push(("index arrays", cursor.int_index.bytes()))
      entries.push(("index map (estimate)", cursor.int_index.map_bytes()))
      entries.push(("index keys (estimate)", str_map_bytes(cursor.str_map)))
      entries.push(("join output", resident_batches_bytes(out)))
      c.observe("hash join swapped its sides (\{tag})", entries)
    }
    None => ()
  }
  out
}

///|
/// Collapse a spilled step's output to the one batch the eager path handed on
/// before, for a budgeted run: the next step partitions it, and a partitioner
/// slices every input batch into every partition (§65).
fn collapse_handed(
  batches : Array[@types.DataBatch],
  step : JoinStep,
) -> Array[@types.DataBatch] {
  if batches.length() <= 1 {
    batches
  } else {
    [concat_batches(batches, step.out_dtypes)]
  }
}

///|
fn key_has_null(vals : Array[@types.Scalar]) -> Bool {
  for v in vals {
    if v is @types.Null {
      return true
    }
  }
  false
}

///|
/// One hash join: build a key -> row-ids map on the (filtered) right
/// side, probe with every accumulated row. NULL keys never match; LEFT
/// keeps unmatched probe rows with a NULL right side; the residual
/// filters candidate pairs before the match counts (so LEFT
/// NULL-extension sees the post-residual match set, per ON semantics).
///
/// Both sides are concatenated into single columnar batches, keys are
/// evaluated once per side, probe hits collect (left row, build row)
/// integer pairs, and the output is assembled by per-column gathers —
/// no boxed row arrays in the hot path. A single int join key (the
/// TPC-H shape) hashes Int64s directly instead of building key strings.
fn join_step(
  acc : Array[@types.DataBatch],
  right : Array[@types.DataBatch],
  step : JoinStep,
  census~ : MemCensus? = None,
  extra~ : Array[(String, Int64)] = [],
  tag~ : String = "",
  collapse~ : Bool = false,
) -> Array[@types.DataBatch] raise @types.SqlError {
  if step.kind is Right {
    return join_swapped(acc, right, step)
  }
  if step.kind is Semi || step.kind is Anti || step.kind is AntiLoose {
    return join_semi(acc, right, step, census~, extra~, tag~)
  }
  let build = concat_batches(
    right,
    tail_dtypes(step.out_dtypes, step.right_width),
  )
  // the probe side is handed over a batch at a time: `acc` already has the
  // left half of the combined layout, so nothing is concatenated here
  let mut at = 0
  let next_left : () -> @types.DataBatch? raise @types.SqlError = fn() {
    if at < acc.length() {
      let b = acc[at]
      at += 1
      Some(b)
    } else {
      None
    }
  }
  let cursor = JoinCursor::open(step, build, next_left)
  let out = drain_join(cursor)
  match census {
    Some(c) => {
      // the point where the step's own copies and its index are all live: the
      // collected FROM tables, the probe input, this step's build scan (when
      // the eager path made one), its concatenated copy, the index and the
      // output batches not yet collapsed into one
      let entries = extra.copy()
      entries.push(("build copy", resident_batch_bytes(build)))
      entries.push(("index arrays", cursor.int_index.bytes()))
      entries.push(("index map (estimate)", cursor.int_index.map_bytes()))
      entries.push(("index keys (estimate)", str_map_bytes(cursor.str_map)))
      entries.push(("join output", resident_batches_bytes(out)))
      c.observe("hash join collected its output (\{tag})", entries)
    }
    None => ()
  }
  // The collected output is handed on as it is: the next step's probe side and
  // every reader past the chain take batches, so collapsing it into one would
  // allocate a second copy of the whole step's output for nobody (contract:
  // docs/ROADMAP.md, measurement §65). A budgeted run keeps the one batch it
  // handed on before, because the partitioner slices every input batch into
  // every partition and measured 4.4x slower with many (§65).
  if !collapse {
    return out
  }
  let result = concat_batches(out, step.out_dtypes)
  match census {
    Some(c) => {
      // the collapse, where a budgeted run still makes one: only what is alive
      // here is named, and the cursor was released before the copy started
      let entries = extra.copy()
      entries.push(("collected output", resident_batches_bytes(out)))
      entries.push(("collapsed output", resident_batch_bytes(result)))
      c.observe("hash join collapsed its output (\{tag})", entries)
    }
    None => ()
  }
  [result]
}

///|
/// How many rows a join hands out at a time. One probe batch can produce more
/// than this (a duplicated join key), so the cursor slices its own output.
const JOIN_OUT_BATCH : Int32 = 4096

///|
/// The fast-path half of a build side's index: every matching row id, grouped by
/// key into one contiguous array, with a slot table holding each key's range. A
/// unique key costs its slot and one id, not an allocated list, which matters
/// when the build side is a primary key over millions of rows.
priv struct IntKeyIndex {
  lo : Int64 // dense lookup: the smallest key
  dense : FixedArray[Int32] // key - lo -> slot, -1 for none; empty when hashed
  slots : Map[Int64, Int32] // hashed lookup: key -> slot; empty when dense
  starts : FixedArray[Int32] // start of each slot's ids, plus one sentinel
  ids : FixedArray[Int32] // build row numbers, grouped by slot
}

///|
fn IntKeyIndex::empty() -> IntKeyIndex {
  {
    lo: 0L,
    dense: FixedArray::make(0, 0),
    slots: Map([]),
    starts: FixedArray::make(1, 0),
    ids: FixedArray::make(0, 0),
  }
}

///|
/// The slot of a key, or -1 when no build row has it.
fn IntKeyIndex::slot(self : IntKeyIndex, k : Int64) -> Int32 {
  if self.dense.length() > 0 {
    let off = k - self.lo
    if off >= 0L && off < self.dense.length().to_int64() {
      self.dense[off.to_int()]
    } else {
      -1
    }
  } else {
    match self.slots.get(k) {
      Some(slot) => slot
      None => -1
    }
  }
}

///|
/// Group the valid build keys by value. Two passes over the keys: the first
/// numbers the slots and counts them, the second writes each row id into its
/// slot's range, so the ids array is exactly `4 * rows` bytes and no per-key
/// list is ever allocated. When the keys sit in a range no wider than four times
/// the row count (and 2^24), the key-to-slot lookup is one array indexed by
/// `key - lowest`, which costs four bytes a cell where a hash map costs an entry
/// per distinct key; any other key set keeps the map.
fn IntKeyIndex::build(
  bd : FixedArray[Int64],
  bv : FixedArray[Bool],
  n : Int32,
) -> IntKeyIndex {
  let slots : Map[Int64, Int32] = Map([])
  let counts : Array[Int32] = []
  let mut lo = 0L
  let mut hi = 0L
  let mut valid_rows = 0
  for r in 0..<n {
    if bv[r] {
      let k = bd[r]
      if valid_rows == 0 {
        lo = k
        hi = k
      } else {
        if k < lo {
          lo = k
        }
        if k > hi {
          hi = k
        }
      }
      valid_rows += 1
    }
  }
  let span = hi - lo // negative only if the true span overflowed Int64
  let use_dense = valid_rows > 0 &&
    span >= 0L &&
    span < 16777216L &&
    span + 1L <= 4L * valid_rows.to_int64() + 1024L
  let dense : FixedArray[Int32] = if use_dense {
    FixedArray::make((span + 1L).to_int(), -1)
  } else {
    FixedArray::make(0, 0)
  }
  for r in 0..<n {
    if bv[r] {
      let k = bd[r]
      if use_dense {
        let off = (k - lo).to_int()
        let slot = dense[off]
        if slot >= 0 {
          counts[slot] = counts[slot] + 1
        } else {
          dense[off] = counts.length()
          counts.push(1)
        }
      } else {
        match slots.get(k) {
          Some(slot) => counts[slot] = counts[slot] + 1
          None => {
            slots[k] = counts.length()
            counts.push(1)
          }
        }
      }
    }
  }
  let m = counts.length()
  let starts : FixedArray[Int32] = FixedArray::make(m + 1, 0)
  let mut total = 0
  for slot in 0..<m {
    starts[slot] = total
    total += counts[slot]
  }
  starts[m] = total
  let ids : FixedArray[Int32] = FixedArray::make(total, 0)
  let cursor : Array[Int32] = []
  for slot in 0..<m {
    cursor.push(starts[slot])
  }
  for r in 0..<n {
    if bv[r] {
      let slot = if use_dense {
        dense[(bd[r] - lo).to_int()]
      } else {
        slots.get(bd[r]).unwrap()
      }
      ids[cursor[slot]] = r
      cursor[slot] = cursor[slot] + 1
    }
  }
  { lo, dense, slots, starts, ids, }
}

///|
/// The bytes the index's arrays own: the dense slot table, the per-slot starts
/// and the row-id range, four bytes a cell each. The hashed slot table is a map
/// and is estimated separately, so a report never mixes a sum with an estimate.
fn IntKeyIndex::bytes(self : IntKeyIndex) -> Int64 {
  4L * self.dense.length().to_int64() +
  4L * self.starts.length().to_int64() +
  4L * self.ids.length().to_int64()
}

///|
/// The hashed slot table at the measured cost of an entry: an estimate, and
/// named as one wherever it is reported. §75 measured a filled
/// `Map[Int64, Int32]` at 48 to 69 bytes an entry across 100 thousand to three
/// million entries (the spread is the doubling slack, which a filled map carries
/// and so does this count), and this is the value at the million-entry scale the
/// engine works at. Twenty-four bytes was the unmeasured guess before it.
const SLOT_MAP_BYTES : Int64 = 60

///|
fn IntKeyIndex::map_bytes(self : IntKeyIndex) -> Int64 {
  self.slots.length().to_int64() * SLOT_MAP_BYTES
}

///|
/// The string half of a join index: each canonical key's id array plus the key
/// string and an entry, at the measured cost of an entry (§75: a filled
/// `Map[String, _]` costs the same as an `Int64` one once the keys exist): an
/// estimate, named as one.
fn str_map_bytes(m : Map[String, Array[Int32]]) -> Int64 {
  let mut total = 0L
  m.each(fn(k, ids) {
    total += SLOT_MAP_BYTES +
      k.length().to_int64() +
      4L * ids.length().to_int64()
  })
  total
}

///|
/// `IntKeyIndex::build` for a single `Int32` key column read in place. Widening
/// the column to `Int64` first costs eight bytes a row for as long as the index
/// is being built, which on a six million row side is 48 MB that exists only to
/// be read once; this reads the narrow column and writes the same index.
fn IntKeyIndex::build_i32(
  bd : FixedArray[Int32],
  bv : FixedArray[Bool],
  n : Int32,
) -> IntKeyIndex {
  let slots : Map[Int64, Int32] = Map([])
  let counts : Array[Int32] = []
  let mut lo = 0L
  let mut hi = 0L
  let mut valid_rows = 0
  for r in 0..<n {
    if bv[r] {
      let k = bd[r].to_int64()
      if valid_rows == 0 {
        lo = k
        hi = k
      } else {
        if k < lo {
          lo = k
        }
        if k > hi {
          hi = k
        }
      }
      valid_rows += 1
    }
  }
  let span = hi - lo
  let use_dense = valid_rows > 0 &&
    span >= 0L &&
    span < 16777216L &&
    span + 1L <= 4L * valid_rows.to_int64() + 1024L
  let dense : FixedArray[Int32] = if use_dense {
    FixedArray::make((span + 1L).to_int(), -1)
  } else {
    FixedArray::make(0, 0)
  }
  for r in 0..<n {
    if bv[r] {
      let k = bd[r].to_int64()
      if use_dense {
        let off = (k - lo).to_int()
        let slot = dense[off]
        if slot >= 0 {
          counts[slot] = counts[slot] + 1
        } else {
          dense[off] = counts.length()
          counts.push(1)
        }
      } else {
        match slots.get(k) {
          Some(slot) => counts[slot] = counts[slot] + 1
          None => {
            slots[k] = counts.length()
            counts.push(1)
          }
        }
      }
    }
  }
  let m = counts.length()
  let starts : FixedArray[Int32] = FixedArray::make(m + 1, 0)
  let mut total = 0
  for slot in 0..<m {
    starts[slot] = total
    total += counts[slot]
  }
  starts[m] = total
  let ids : FixedArray[Int32] = FixedArray::make(total, 0)
  let cursor : Array[Int32] = []
  for slot in 0..<m {
    cursor.push(starts[slot])
  }
  for r in 0..<n {
    if bv[r] {
      let k = bd[r].to_int64()
      let slot = if use_dense {
        dense[(k - lo).to_int()]
      } else {
        slots.get(k).unwrap()
      }
      ids[cursor[slot]] = r
      cursor[slot] = cursor[slot] + 1
    }
  }
  { lo, dense, slots, starts, ids, }
}

///|
/// One hash join as a cursor. The build side is resident — a probe row has to
/// find its matches — but the probe side arrives a batch at a time and the
/// output leaves in batches of at most `JOIN_OUT_BATCH` rows, so a caller never
/// holds the probe side or the joined row set.
///
/// `next` returns rows in the step's combined layout (left columns, then the
/// joining table's); the caller projects them. NULL keys never match, LEFT and
/// FULL keep unmatched probe rows with a NULL right side, FULL emits its
/// unmatched build rows once after the probe side ends, and the residual
/// filters candidate pairs before a match counts.
priv struct JoinCursor {
  step : JoinStep
  build : @types.DataBatch
  build_keys : Array[@types.ColumnVector]
  mut int_index : IntKeyIndex // the fast path: packed Int64 keys
  str_map : Map[String, Array[Int32]]
  mut fast : Bool // which index was built
  left_width : Int32
  empty_left : @types.DataBatch // the layout to gather NULLs from
  matched : FixedArray[Bool] // FULL: which build rows matched
  next_left : () -> @types.DataBatch? raise @types.SqlError
  mut left_now : @types.DataBatch? // the probe batch the pending ids belong to
  mut out_l : Array[Int32] // pending pairs, drained in slices of JOIN_OUT_BATCH
  mut out_r : Array[Int32]
  mut out_at : Int32
  mut primed : Bool
  mut tail_done : Bool
}

///|
fn JoinCursor::open(
  step : JoinStep,
  build : @types.DataBatch,
  next_left : () -> @types.DataBatch? raise @types.SqlError,
) -> JoinCursor raise @types.SqlError {
  let build_keys : Array[@types.ColumnVector] = []
  for e in step.keys_r {
    build_keys.push(eval_vec(e, build))
  }
  let left_width = step.out_dtypes.length() - step.right_width
  {
    step,
    build,
    build_keys,
    int_index: IntKeyIndex::empty(),
    str_map: Map([]),
    fast: false,
    left_width,
    empty_left: concat_batches([], head_dtypes(step.out_dtypes, left_width)),
    matched: FixedArray::make(build.row_count(), false),
    next_left,
    left_now: None,
    out_l: [],
    out_r: [],
    out_at: 0,
    primed: false,
    tail_done: false,
  }
}

///|
/// Build the key -> build-row-ids map, once, when the first probe batch shows
/// which of the two key shapes this join has: both sides packed into one Int64
/// (the TPC-H shape) or canonical key strings.
fn JoinCursor::prime(
  self : JoinCursor,
  left_keys : Array[@types.ColumnVector],
) -> Unit {
  let n_build = self.build.row_count()
  let narrow : (FixedArray[Int32], FixedArray[Bool])? = match self.build_keys {
    [@types.I32(d, v)] =>
      if int_key_vecs(left_keys) is Some(_) {
        Some((d, v))
      } else {
        None
      }
    _ => None
  }
  match narrow {
    Some((d, v)) => {
      self.fast = true
      self.int_index = IntKeyIndex::build_i32(d, v, n_build)
      self.primed = true
      return
    }
    None => ()
  }
  match int_key_cols(self.build_keys, left_keys) {
    Some((bd, bv, _, _)) => {
      self.fast = true
      // NULL join keys never match, and the index skips them
      self.int_index = IntKeyIndex::build(bd, bv, n_build)
    }
    None =>
      for r in 0..<n_build {
        let kv : Array[@types.Scalar] = []
        for c in self.build_keys {
          kv.push(c.get(r))
        }
        if key_has_null(kv) {
          continue // NULL join keys never match
        }
        let key = canonical_key(kv)
        match self.str_map.get(key) {
          Some(ids) => ids.push(r)
          None => self.str_map[key] = [r]
        }
      }
  }
  self.primed = true
}

///|
/// Match one probe batch, appending its output pairs (and remembering which
/// build rows matched).
fn JoinCursor::match_batch(
  self : JoinCursor,
  left : @types.DataBatch,
  left_keys : Array[@types.ColumnVector],
  rstate : ResidualState?,
) -> Unit raise @types.SqlError {
  let n_left = left.row_count()
  let keep_unmatched = self.step.kind is Left || self.step.kind is Full
  if self.fast {
    let (ld, lv) = match int_key_vecs(left_keys) {
      Some(pair) => pair
      None => abort("fast-path keys changed shape between batches")
    }
    for r in 0..<n_left {
      let mut hit = false
      if lv[r] {
        let slot = self.int_index.slot(ld[r])
        if slot >= 0 {
          let stops = self.int_index.starts
          for j in stops[slot]..<stops[slot + 1] {
            let id = self.int_index.ids[j]
            if residual_ok(rstate, left, r, self.build, id) {
              self.out_l.push(r)
              self.out_r.push(id)
              self.matched[id] = true
              hit = true
            }
          }
        }
      }
      if !hit && keep_unmatched {
        self.out_l.push(r)
        self.out_r.push(-1)
      }
    }
  } else {
    for r in 0..<n_left {
      let kv : Array[@types.Scalar] = []
      for c in left_keys {
        kv.push(c.get(r))
      }
      let mut hit = false
      if !key_has_null(kv) {
        match self.str_map.get(canonical_key(kv)) {
          Some(ids) =>
            for id in ids {
              if residual_ok(rstate, left, r, self.build, id) {
                self.out_l.push(r)
                self.out_r.push(id)
                self.matched[id] = true
                hit = true
              }
            }
          None => ()
        }
      }
      if !hit && keep_unmatched {
        self.out_l.push(r)
        self.out_r.push(-1)
      }
    }
  }
}

///|
/// Gather the next slice of pending pairs into a batch of the combined layout.
fn JoinCursor::slice(self : JoinCursor) -> @types.DataBatch {
  let total = self.out_l.length()
  let mut n = total - self.out_at
  if n > JOIN_OUT_BATCH {
    n = JOIN_OUT_BATCH
  }
  let l : Array[Int32] = []
  let r : Array[Int32] = []
  for i in self.out_at..<(self.out_at + n) {
    l.push(self.out_l[i])
    r.push(self.out_r[i])
  }
  self.out_at += n
  let left = match self.left_now {
    Some(b) => b
    None => self.empty_left
  }
  let columns : Array[@types.ColumnVector] = []
  for c in 0..<self.left_width {
    columns.push(gather(left.columns()[c], l))
  }
  for c in 0..<self.step.right_width {
    columns.push(gather(self.build.columns()[c], r))
  }
  @types.DataBatch::new(columns, n)
}

///|
fn JoinCursor::next(
  self : JoinCursor,
) -> @types.DataBatch? raise @types.SqlError {
  while true {
    if self.out_at < self.out_l.length() {
      let batch = self.slice()
      if self.out_at >= self.out_l.length() {
        // that probe batch is spent: start the next one on empty buffers
        self.out_l = []
        self.out_r = []
        self.out_at = 0
      }
      return Some(batch)
    }
    if self.tail_done {
      return None
    }
    match (self.next_left)() {
      Some(left) => {
        if left.row_count() == 0 {
          continue
        }
        let left_keys : Array[@types.ColumnVector] = []
        for e in self.step.keys_l {
          left_keys.push(eval_vec(e, left))
        }
        if !self.primed {
          self.prime(left_keys)
        }
        let rstate : ResidualState? = match self.step.residual {
          Some(re) =>
            Some(
              residual_state(
                residual_plan(re, self.left_width, self.step.right_width),
                left,
                self.build,
              ),
            )
          None => None
        }
        self.left_now = Some(left)
        self.match_batch(left, left_keys, rstate)
      }
      None => {
        self.tail_done = true
        if self.step.kind is Full {
          // FULL: unmatched build rows survive with a NULL accumulated side
          let n_build = self.build.row_count()
          for id in 0..<n_build {
            if !self.matched[id] {
              self.out_l.push(-1)
              self.out_r.push(id)
            }
          }
        }
        if self.out_l.length() == 0 {
          return None
        }
      }
    }
  }
  abort("join cursor: the loop leaves only by returning")
}

///|
fn drain_join(
  cursor : JoinCursor,
) -> Array[@types.DataBatch] raise @types.SqlError {
  let out : Array[@types.DataBatch] = []
  while cursor.next() is Some(batch) {
    out.push(batch)
  }
  out
}

///|
/// Kleene tri-state encoding for residual states: 0 = false, 1 =
/// unknown (NULL), 2 = true. Conjunction folds with min, disjunction
/// with max, so per-side precomputed states recombine exactly like the
/// original expression tree.

///|
/// One disjunct of a residual, split by the sides its conjuncts touch.
/// `left`/`build` hold the single-side conjuncts AndE-combined (None =
/// that side contributes TRUE); `spanning` holds both-side conjuncts
/// rewritten against their reduced row, paired with the Flat columns
/// they read.
priv struct ArmPlan {
  left : PhysExpr?
  build : PhysExpr?
  spanning : Array[(PhysExpr, Array[Int32])]
}

///|
/// A residual decomposed into arms. The Flat layout puts the left side
/// first, so `left_width` splits ColRef ownership.
priv struct ResidualPlan {
  arms : Array[ArmPlan]
  left_width : Int32
}

///|
/// Precomputed per-side Kleene states of a residual over one pair of
/// joined batches. Every residual call site evaluates a fixed (left,
/// build) batch pair inside nested loops, so the vectorized arm states
/// are computed once and the per-pair work collapses to array lookups
/// plus the (rare) spanning conjuncts.
priv struct ResidualState {
  plan : ResidualPlan
  lt : Array[FixedArray[Bool]]
  lu : Array[FixedArray[Bool]]
  bt : Array[FixedArray[Bool]]
  bu : Array[FixedArray[Bool]]
}

///|
/// Flatten a top-level OrE spine into arms (either nesting shape); a
/// non-OrE expression is a single arm.
fn or_arms(e : PhysExpr, out : Array[PhysExpr]) -> Unit {
  match e {
    OrE(l, r) => {
      or_arms(l, out)
      or_arms(r, out)
    }
    other => out.push(other)
  }
}

///|
/// Flatten a top-level AndE spine into conjuncts.
fn and_conjuncts(e : PhysExpr, out : Array[PhysExpr]) -> Unit {
  match e {
    AndE(l, r) => {
      and_conjuncts(l, out)
      and_conjuncts(r, out)
    }
    other => out.push(other)
  }
}

///|
/// Collect the Flat ColRef indices an expression reads.
fn expr_refs(e : PhysExpr, out : Array[Int32]) -> Unit {
  match e {
    ColRef(i, _) => out.push(i)
    Const(_) | WinRef(_, _) => ()
    Promote(x, _) => expr_refs(x, out)
    ArithE(_, a, b, _) => {
      expr_refs(a, out)
      expr_refs(b, out)
    }
    CmpE(_, a, b) => {
      expr_refs(a, out)
      expr_refs(b, out)
    }
    AndE(a, b) | OrE(a, b) => {
      expr_refs(a, out)
      expr_refs(b, out)
    }
    NotE(x)
    | LikeE(x, _)
    | IsNullE(x, _)
    | ExtractE(x, _)
    | CastE(x, _)
    | DateArithE(x, _, _) => expr_refs(x, out)
    InSetE(x, _, _, _) => expr_refs(x, out)
    CaseE(arms, els, _) => {
      for (w, t) in arms {
        expr_refs(w, out)
        expr_refs(t, out)
      }
      match els {
        Some(x) => expr_refs(x, out)
        None => ()
      }
    }
    FuncE(_, args, _) =>
      for a in args {
        expr_refs(a, out)
      }
  }
}

///|
/// Rewrite ColRef indices into positions within `refs` (the reduced row
/// a spanning conjunct is evaluated against).
fn remap_refs(e : PhysExpr, refs : Array[Int32]) -> PhysExpr {
  match e {
    ColRef(i, dt) => {
      let mut pos = 0
      for j, r in refs {
        if r == i {
          pos = j
          break
        }
      }
      ColRef(pos, dt)
    }
    Const(_) | WinRef(_, _) => e
    Promote(x, dt) => Promote(remap_refs(x, refs), dt)
    ArithE(op, a, b, dt) =>
      ArithE(op, remap_refs(a, refs), remap_refs(b, refs), dt)
    CmpE(op, a, b) => CmpE(op, remap_refs(a, refs), remap_refs(b, refs))
    AndE(a, b) => AndE(remap_refs(a, refs), remap_refs(b, refs))
    OrE(a, b) => OrE(remap_refs(a, refs), remap_refs(b, refs))
    NotE(x) => NotE(remap_refs(x, refs))
    LikeE(x, p) => LikeE(remap_refs(x, refs), p)
    IsNullE(x, n) => IsNullE(remap_refs(x, refs), n)
    ExtractE(x, f) => ExtractE(remap_refs(x, refs), f)
    CastE(x, dt) => CastE(remap_refs(x, refs), dt)
    DateArithE(x, n, u) => DateArithE(remap_refs(x, refs), n, u)
    InSetE(x, set, neg, nulls) => InSetE(remap_refs(x, refs), set, neg, nulls)
    CaseE(arms, els, dt) => {
      let out : Array[(PhysExpr, PhysExpr)] = []
      for (w, t) in arms {
        out.push((remap_refs(w, refs), remap_refs(t, refs)))
      }
      let rels : PhysExpr? = match els {
        Some(x) => Some(remap_refs(x, refs))
        None => None
      }
      CaseE(out, rels, dt)
    }
    FuncE(name, args, dt) => {
      let out : Array[PhysExpr] = []
      for a in args {
        out.push(remap_refs(a, refs))
      }
      FuncE(name, out, dt)
    }
  }
}

///|
/// AndE-combine conjuncts; None for an empty list (that side is TRUE).
fn conjoin(exprs : Array[PhysExpr]) -> PhysExpr? {
  match exprs.length() {
    0 => None
    1 => Some(exprs[0])
    _ => {
      let mut acc = exprs[0]
      for i in 1..<exprs.length() {
        acc = AndE(acc, exprs[i])
      }
      Some(acc)
    }
  }
}

///|
/// Decompose a residual into arms and classify every conjunct by side.
/// The Flat layout puts the left side first (`left_width` columns), so
/// a conjunct's ColRef span decides its bucket; conjuncts touching both
/// sides stay per-pair (`spanning`), rewritten against their reduced
/// row. Build-side conjuncts are reindexed to the build batch's local
/// layout (Flat `left_width + c` becomes `c`); left-side conjuncts are
/// already in local order.
fn residual_plan(
  residual : PhysExpr,
  left_width : Int32,
  right_width : Int32,
) -> ResidualPlan {
  let shift : Array[Int32] = []
  for c in 0..<right_width {
    shift.push(left_width + c)
  }
  let raw : Array[PhysExpr] = []
  or_arms(residual, raw)
  let arms : Array[ArmPlan] = []
  for arm in raw {
    let conj : Array[PhysExpr] = []
    and_conjuncts(arm, conj)
    let lefts : Array[PhysExpr] = []
    let builds : Array[PhysExpr] = []
    let spanning : Array[(PhysExpr, Array[Int32])] = []
    for c in conj {
      let refs : Array[Int32] = []
      expr_refs(c, refs)
      let mut saw_left = false
      let mut saw_build = false
      for i in refs {
        if i >= left_width {
          saw_build = true
        } else {
          saw_left = true
        }
      }
      if saw_left && saw_build {
        // dedupe refs, keep first-seen order
        let uniq : Array[Int32] = []
        for i in refs {
          let mut hit = false
          for u in uniq {
            if u == i {
              hit = true
              break
            }
          }
          if !hit {
            uniq.push(i)
          }
        }
        spanning.push((remap_refs(c, uniq), uniq))
      } else if saw_build {
        builds.push(remap_refs(c, shift))
      } else {
        lefts.push(c)
      }
    }
    arms.push({ left: conjoin(lefts), build: conjoin(builds), spanning, })
  }
  { arms, left_width, }
}

///|
/// Per-row Kleene state of a boolean expression as (true, unknown)
/// masks; valid=false marks the unknown rows. The interpreter path
/// keeps the same semantics for the non-BoolV fallbacks.
fn tri_state(
  e : PhysExpr,
  batch : @types.DataBatch,
) -> (FixedArray[Bool], FixedArray[Bool]) raise @types.SqlError {
  let n = batch.row_count()
  let t : FixedArray[Bool] = FixedArray::make(n, false)
  let u : FixedArray[Bool] = FixedArray::make(n, false)
  match eval_vec(e, batch) {
    @types.BoolV(d, valid) =>
      for r in 0..<n {
        if valid[r] {
          t[r] = d[r]
        } else {
          u[r] = true
        }
      }
    _ =>
      for r in 0..<n {
        match eval_scalar(e, batch, r) {
          @types.Boolean(true) => t[r] = true
          @types.Null => u[r] = true
          _ => ()
        }
      }
  }
  (t, u)
}

///|
/// Compute the per-arm per-side states for one (left, build) batch pair.
/// An absent side contributes constant TRUE.
fn residual_state(
  plan : ResidualPlan,
  left : @types.DataBatch,
  build : @types.DataBatch,
) -> ResidualState raise @types.SqlError {
  let nl = left.row_count()
  let nb = build.row_count()
  let lt : Array[FixedArray[Bool]] = []
  let lu : Array[FixedArray[Bool]] = []
  let bt : Array[FixedArray[Bool]] = []
  let bu : Array[FixedArray[Bool]] = []
  for arm in plan.arms {
    match arm.left {
      Some(e) => {
        let (t, u) = tri_state(e, left)
        lt.push(t)
        lu.push(u)
      }
      None => {
        lt.push(FixedArray::make(nl, true))
        lu.push(FixedArray::make(nl, false))
      }
    }
    match arm.build {
      Some(e) => {
        let (t, u) = tri_state(e, build)
        bt.push(t)
        bu.push(u)
      }
      None => {
        bt.push(FixedArray::make(nb, true))
        bu.push(FixedArray::make(nb, false))
      }
    }
  }
  { plan, lt, lu, bt, bu, }
}

///|
/// Box only the Flat columns a spanning conjunct reads. The old path
/// boxed both sides wholesale for every candidate pair.
fn reduced_row(
  left : @types.DataBatch,
  lrow : Int32,
  build : @types.DataBatch,
  brow : Int32,
  left_width : Int32,
  refs : Array[Int32],
) -> Array[@types.Scalar] {
  let row : Array[@types.Scalar] = []
  for i in refs {
    if i < left_width {
      row.push(left.columns()[i].get(lrow))
    } else {
      row.push(build.columns()[i - left_width].get(brow))
    }
  }
  row
}

///|
/// Residual gate for one candidate pair over precomputed arm states.
/// Passes iff the Kleene OR over arms is TRUE — exactly the old
/// row-at-a-time walk's `is Boolean(true)` contract (NULL and false
/// fail). Arms short-circuit on false, the disjunction on true.
fn residual_passes(
  state : ResidualState,
  left : @types.DataBatch,
  lrow : Int32,
  build : @types.DataBatch,
  brow : Int32,
) -> Bool raise @types.SqlError {
  let arms = state.plan.arms
  let lw = state.plan.left_width
  let mut pair = 0
  for k in 0..<arms.length() {
    let arm = arms[k]
    let mut v = if state.lt[k][lrow] {
      2
    } else if state.lu[k][lrow] {
      1
    } else {
      0
    }
    if v > 0 {
      let b = if state.bt[k][brow] {
        2
      } else if state.bu[k][brow] {
        1
      } else {
        0
      }
      if b < v {
        v = b
      }
      if v > 0 {
        for (expr, refs) in arm.spanning {
          let row = reduced_row(left, lrow, build, brow, lw, refs)
          let s = match eval_row(expr, row) {
            @types.Boolean(true) => 2
            @types.Null => 1
            _ => 0
          }
          if s < v {
            v = s
          }
          if v == 0 {
            break
          }
        }
      }
    }
    if v > pair {
      pair = v
    }
    if pair == 2 {
      break
    }
  }
  pair == 2
}

///|
/// Residual gate for one candidate pair; no residual = unconditional
/// pass. Keeps the join loops identical for the common no-residual case.
fn residual_ok(
  state : ResidualState?,
  left : @types.DataBatch,
  lrow : Int32,
  build : @types.DataBatch,
  brow : Int32,
) -> Bool raise @types.SqlError {
  match state {
    Some(s) => residual_passes(s, left, lrow, build, brow)
    None => true
  }
}

///|
/// Normalize one side's join keys into Int64 hash keys, or None when the
/// shape has no exact Int64 form.
///
/// One int-like key is used as it stands. Two int32-width keys are packed
/// into one Int64 as `(a << 32) | (b & 0xFFFFFFFF)`, which is injective: a
/// distinct `a` changes the high half, a distinct `b` the low half. This is
/// worth a fast path because the alternative builds a canonical string per
/// row on both sides: on a 100k x 100k join, two int keys measured 69 ms
/// against 13 ms for one. The TPC-H shape it covers is partsupp joined on
/// (partkey, suppkey).
///
/// Wider keys, strings and three-plus columns stay on the general path: an
/// Int64 cannot hold them exactly, and a plain hash would need collision
/// handling the packed form does not.
fn int_key_vecs(
  keys : Array[@types.ColumnVector],
) -> (FixedArray[Int64], FixedArray[Bool])? {
  match keys {
    [one] =>
      match one {
        @types.I32(d, valid) => {
          let n = one.len()
          let od : FixedArray[Int64] = FixedArray::make(n, 0L)
          for i in 0..<n {
            od[i] = d[i].to_int64()
          }
          Some((od, valid))
        }
        @types.I64(d, valid) => Some((d, valid))
        _ => None
      }
    [first, second] =>
      match (first, second) {
        (@types.I32(a, av), @types.I32(b, bv)) => {
          let n = first.len()
          let od : FixedArray[Int64] = FixedArray::make(n, 0L)
          let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
          for i in 0..<n {
            // a NULL in any component can never match
            ovalid[i] = av[i] && bv[i]
            od[i] = (a[i].to_int64() << 32) | (b[i].to_int64() & 0xFFFFFFFFL)
          }
          Some((od, ovalid))
        }
        (@types.DateV(a, av), @types.DateV(b, bv)) => {
          let n = first.len()
          let od : FixedArray[Int64] = FixedArray::make(n, 0L)
          let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
          for i in 0..<n {
            ovalid[i] = av[i] && bv[i]
            od[i] = (a[i].to_int64() << 32) | (b[i].to_int64() & 0xFFFFFFFFL)
          }
          Some((od, ovalid))
        }
        _ => None
      }
    _ => None
  }
}

///|
fn int_key_cols(
  build_keys : Array[@types.ColumnVector],
  left_keys : Array[@types.ColumnVector],
) -> (FixedArray[Int64], FixedArray[Bool], FixedArray[Int64], FixedArray[Bool])? {
  match (int_key_vecs(build_keys), int_key_vecs(left_keys)) {
    (Some((bd, bv)), Some((ld, lv))) => Some((bd, bv, ld, lv))
    _ => None
  }
}

///|
/// The first `count` dtypes of the combined join layout.
fn head_dtypes(
  dtypes : Array[@types.DataType],
  count : Int32,
) -> Array[@types.DataType] {
  let out : Array[@types.DataType] = []
  for i in 0..<count {
    out.push(dtypes[i])
  }
  out
}

///|
/// The last `count` dtypes of the combined join layout.
fn tail_dtypes(
  dtypes : Array[@types.DataType],
  count : Int32,
) -> Array[@types.DataType] {
  let out : Array[@types.DataType] = []
  let start = dtypes.length() - count
  for i in start..<dtypes.length() {
    out.push(dtypes[i])
  }
  out
}

///|
/// Semi/anti join against a pre-executed inner batch (the
/// decorrelation of a correlated EXISTS / [NOT] IN): probe rows pass a
/// SEMI when some inner row shares the (non-null) key and satisfies the
/// residual. Anti flavors differ on a NULL probe key: NOT IN's
/// comparison is UNKNOWN and drops the row, NOT EXISTS's subquery is
/// simply empty so only an actual match drops it. The inner side
/// contributes no output columns.
fn join_semi(
  acc : Array[@types.DataBatch],
  inner : Array[@types.DataBatch],
  step : JoinStep,
  census~ : MemCensus? = None,
  extra~ : Array[(String, Int64)] = [],
  tag~ : String = "",
) -> Array[@types.DataBatch] raise @types.SqlError {
  let anti = step.kind is Anti || step.kind is AntiLoose
  let null_key_excludes = step.kind is Anti
  // the inner layout, so a zero-batch inner side — a grace partition with no
  // build rows — becomes an empty batch of the right width instead of a batch
  // with no columns at all, which `eval_vec` below would index past
  let inner_batch = concat_batches(
    inner,
    tail_dtypes(step.out_dtypes, step.right_width),
  )
  let n_inner = inner_batch.row_count()
  let mut int_index = IntKeyIndex::empty()
  let str_map : Map[String, Array[Int32]] = Map([])
  let inner_keys : Array[@types.ColumnVector] = []
  for e in step.keys_r {
    inner_keys.push(eval_vec(e, inner_batch))
  }
  let single_int = step.keys_r.length() == 1 &&
    inner_keys[0] is (@types.I32(_, _) | @types.I64(_, _))
  if single_int {
    // NULL inner keys match nothing, and the index skips them
    int_index = match inner_keys[0] {
      @types.I32(d, valid) => IntKeyIndex::build_i32(d, valid, n_inner)
      @types.I64(d, valid) => IntKeyIndex::build(d, valid, n_inner)
      _ => abort("unreachable: single_int checked above")
    }
  } else {
    for r in 0..<n_inner {
      let kv : Array[@types.Scalar] = []
      for c in inner_keys {
        kv.push(c.get(r))
      }
      if key_has_null(kv) {
        continue
      }
      let key = canonical_key(kv)
      match str_map.get(key) {
        Some(ids) => ids.push(r)
        None => str_map[key] = [r]
      }
    }
  }
  let left_width = step.out_dtypes.length() - step.right_width
  let left = concat_batches(acc, head_dtypes(step.out_dtypes, left_width))
  let n_left = left.row_count()
  let rstate : ResidualState? = match step.residual {
    Some(re) =>
      Some(
        residual_state(
          residual_plan(re, left_width, step.right_width),
          left,
          inner_batch,
        ),
      )
    None => None
  }
  let left_keys : Array[@types.ColumnVector] = []
  for e in step.keys_l {
    left_keys.push(eval_vec(e, left))
  }
  match census {
    Some(c) => {
      // the inner side's own copy and index next to the probe copy: this is
      // the point §58 could only estimate, before the answer rows are filtered
      let entries = extra.copy()
      entries.push(("inner copy", resident_batch_bytes(inner_batch)))
      entries.push(("index arrays", int_index.bytes()))
      entries.push(("index map (estimate)", int_index.map_bytes()))
      entries.push(("index keys (estimate)", str_map_bytes(str_map)))
      entries.push(("probe copy", resident_batch_bytes(left)))
      c.observe("semi/anti join's inner side (\{tag})", entries)
    }
    None => ()
  }
  let left_ids : Array[Int32] = []
  for r in 0..<n_left {
    let kv : Array[@types.Scalar] = []
    for c in left_keys {
      kv.push(c.get(r))
    }
    let null_key = key_has_null(kv)
    let mut matched = false
    if !null_key {
      if single_int {
        let k = match left_keys[0].get(r) {
          @types.Int32(v) => v.to_int64()
          @types.Int64(v) => v
          _ => 0L
        }
        let slot = int_index.slot(k)
        if slot >= 0 {
          for j in int_index.starts[slot]..<int_index.starts[slot + 1] {
            let id = int_index.ids[j]
            if residual_ok(rstate, left, r, inner_batch, id) {
              matched = true
            }
          }
        }
      } else {
        let key = canonical_key(kv)
        match str_map.get(key) {
          Some(ids) =>
            for id in ids {
              if residual_ok(rstate, left, r, inner_batch, id) {
                matched = true
              }
            }
          None => ()
        }
      }
    }
    // SEMI: keep matches. ANTI: keep non-matches — NOT IN additionally
    // drops a null correlation key (UNKNOWN), NOT EXISTS keeps it (the
    // subquery is empty regardless). A null key is only UNKNOWN against a set
    // with a member, though: `v NOT IN <empty set>` is TRUE even for a null
    // `v`, so the row survives when nothing in its set satisfies the residual.
    let mut set_has_member = false
    if null_key && null_key_excludes {
      for id in 0..<n_inner {
        if residual_ok(rstate, left, r, inner_batch, id) {
          set_has_member = true
          break
        }
      }
    }
    let keep = if anti {
      !matched && (!null_key || !null_key_excludes || !set_has_member)
    } else {
      matched
    }
    if keep {
      left_ids.push(r)
    }
  }
  // full-width assembly like a plain join: the layout stays flat so the
  // residual and projection see every column; the projection drops the
  // inner columns naturally. No single inner row belongs to a semi/anti
  // match, so the inner columns gather id -1 (all-NULL placeholders);
  // gathering row 0 would also index out of an empty inner batch.
  let columns : Array[@types.ColumnVector] = []
  for c in 0..<left.columns().length() {
    columns.push(gather(left.columns()[c], left_ids))
  }
  for c in 0..<inner_batch.columns().length() {
    let right_ids : Array[Int32] = Array::make(left_ids.length(), -1)
    columns.push(gather(inner_batch.columns()[c], right_ids))
  }
  [@types.DataBatch::new(columns, left_ids.length())]
}

///|
/// RIGHT JOIN with roles swapped: the accumulated (optional) side
/// becomes the hash map, the joining (preserved) side probes, and every
/// unmatched probe row keeps its values with a NULL accumulated side.
/// Output column order stays (accumulated, joining) as the layout
/// requires.
fn join_swapped(
  acc : Array[@types.DataBatch],
  right : Array[@types.DataBatch],
  step : JoinStep,
) -> Array[@types.DataBatch] raise @types.SqlError {
  let right_width = step.right_width
  let left_width = step.out_dtypes.length() - right_width
  // build: the accumulated (optional) side; keys are the Flat left keys
  let build = concat_batches(acc, head_dtypes(step.out_dtypes, left_width))
  let n_build = build.row_count()
  // probe: the preserved joining table; keys are its Slot keys
  let probe = concat_batches(right, tail_dtypes(step.out_dtypes, right_width))
  let n_probe = probe.row_count()
  let rstate : ResidualState? = match step.residual {
    Some(re) =>
      Some(
        residual_state(residual_plan(re, left_width, right_width), build, probe),
      )
    None => None
  }
  let build_keys : Array[@types.ColumnVector] = []
  for e in step.keys_l {
    build_keys.push(eval_vec(e, build))
  }
  let probe_keys : Array[@types.ColumnVector] = []
  for e in step.keys_r {
    probe_keys.push(eval_vec(e, probe))
  }
  let acc_ids : Array[Int32] = []
  let right_ids : Array[Int32] = [] // -1 marks a NULL accumulated side
  let int_keys = int_key_cols(build_keys, probe_keys)
  match int_keys {
    Some((bd, bv, pd, pv)) => {
      let index = IntKeyIndex::build(bd, bv, n_build)
      for r in 0..<n_probe {
        let mut matched = false
        if pv[r] {
          let slot = index.slot(pd[r])
          if slot >= 0 {
            for j in index.starts[slot]..<index.starts[slot + 1] {
              let id = index.ids[j]
              if residual_ok(rstate, build, id, probe, r) {
                acc_ids.push(id)
                right_ids.push(r)
                matched = true
              }
            }
          }
        }
        if !matched {
          acc_ids.push(-1)
          right_ids.push(r)
        }
      }
    }
    None => {
      let map : Map[String, Array[Int32]] = Map([])
      for r in 0..<n_build {
        let kv : Array[@types.Scalar] = []
        for c in build_keys {
          kv.push(c.get(r))
        }
        if key_has_null(kv) {
          continue
        }
        let key = canonical_key(kv)
        match map.get(key) {
          Some(ids) => ids.push(r)
          None => map[key] = [r]
        }
      }
      for r in 0..<n_probe {
        let kv : Array[@types.Scalar] = []
        for c in probe_keys {
          kv.push(c.get(r))
        }
        let mut matched = false
        if !key_has_null(kv) {
          match map.get(canonical_key(kv)) {
            Some(ids) =>
              for id in ids {
                if residual_ok(rstate, build, id, probe, r) {
                  acc_ids.push(id)
                  right_ids.push(r)
                  matched = true
                }
              }
            None => ()
          }
        }
        if !matched {
          acc_ids.push(-1)
          right_ids.push(r)
        }
      }
    }
  }
  // assemble: accumulated columns first, then the joining table
  let columns : Array[@types.ColumnVector] = []
  for c in 0..<left_width {
    columns.push(gather(build.columns()[c], acc_ids))
  }
  for c in 0..<right_width {
    columns.push(gather(probe.columns()[c], right_ids))
  }
  [@types.DataBatch::new(columns, acc_ids.length())]
}
