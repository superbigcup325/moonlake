// Swapping the last build side of a chain: when the rows the earlier steps
// produce are few, they become the hash side and the last table streams past
// them, so a large table named last is never held whole. The contract is in
// docs/ROADMAP.md ("The build side swap contract").

///|
/// The last join step of a chain with its roles swapped: the rows the earlier
/// steps produced are the build side, held whole behind an index, and the step's
/// own table is the probe side, arriving a batch at a time. Pairs leave in the
/// step's combined layout (prefix columns, then the table's) in batches of at
/// most `JOIN_OUT_BATCH`. Only INNER steps are swapped: a LEFT or FULL step owes
/// its unmatched rows to the side that would now be the build side. NULL keys
/// never match and the residual filters candidate pairs, as in `JoinCursor`.
priv struct SwapCursor {
  step : JoinStep
  prefix : @types.DataBatch
  prefix_keys : Array[@types.ColumnVector]
  mut int_index : IntKeyIndex
  str_map : Map[String, Array[Int32]]
  mut fast : Bool
  left_width : Int32
  next_right : () -> @types.DataBatch? raise @types.SqlError
  mut right_now : @types.DataBatch?
  mut out_p : Array[Int32] // pending prefix rows
  mut out_t : Array[Int32] // pending table rows, aligned with out_p
  mut out_at : Int32
  mut primed : Bool
  mut done : Bool
}

///|
fn SwapCursor::open(
  step : JoinStep,
  prefix : @types.DataBatch,
  next_right : () -> @types.DataBatch? raise @types.SqlError,
) -> SwapCursor raise @types.SqlError {
  let prefix_keys : Array[@types.ColumnVector] = []
  if prefix.row_count() > 0 {
    for e in step.keys_l {
      prefix_keys.push(eval_vec(e, prefix))
    }
  }
  {
    step,
    prefix,
    prefix_keys,
    int_index: IntKeyIndex::empty(),
    str_map: Map([]),
    fast: false,
    left_width: step.out_dtypes.length() - step.right_width,
    next_right,
    right_now: None,
    out_p: [],
    out_t: [],
    out_at: 0,
    primed: false,
    done: false,
  }
}

///|
/// Index the prefix once, when the first table batch shows which of the two key
/// shapes this join has.
fn SwapCursor::prime(
  self : SwapCursor,
  right_keys : Array[@types.ColumnVector],
) -> Unit {
  let n = self.prefix.row_count()
  match int_key_cols(self.prefix_keys, right_keys) {
    Some((bd, bv, _, _)) => {
      self.fast = true
      self.int_index = IntKeyIndex::build(bd, bv, n)
    }
    None =>
      for r in 0..<n {
        let kv : Array[@types.Scalar] = []
        for c in self.prefix_keys {
          kv.push(c.get(r))
        }
        if key_has_null(kv) {
          continue
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
/// Match one table batch against the prefix, appending its output pairs.
fn SwapCursor::match_batch(
  self : SwapCursor,
  right : @types.DataBatch,
  right_keys : Array[@types.ColumnVector],
  rstate : ResidualState?,
) -> Unit raise @types.SqlError {
  let n = right.row_count()
  if self.fast {
    let (rd, rv) = match int_key_vecs(right_keys) {
      Some(pair) => pair
      None => abort("fast-path keys changed shape between batches")
    }
    for r in 0..<n {
      if rv[r] {
        let slot = self.int_index.slot(rd[r])
        if slot >= 0 {
          let stops = self.int_index.starts
          for j in stops[slot]..<stops[slot + 1] {
            let id = self.int_index.ids[j]
            if residual_ok(rstate, self.prefix, id, right, r) {
              self.out_p.push(id)
              self.out_t.push(r)
            }
          }
        }
      }
    }
  } else {
    for r in 0..<n {
      let kv : Array[@types.Scalar] = []
      for c in right_keys {
        kv.push(c.get(r))
      }
      if !key_has_null(kv) {
        match self.str_map.get(canonical_key(kv)) {
          Some(ids) =>
            for id in ids {
              if residual_ok(rstate, self.prefix, id, right, r) {
                self.out_p.push(id)
                self.out_t.push(r)
              }
            }
          None => ()
        }
      }
    }
  }
}

///|
/// Gather the next slice of pending pairs into a batch of the combined layout.
fn SwapCursor::slice(self : SwapCursor) -> @types.DataBatch {
  let total = self.out_p.length()
  let mut n = total - self.out_at
  if n > JOIN_OUT_BATCH {
    n = JOIN_OUT_BATCH
  }
  let p : Array[Int32] = []
  let t : Array[Int32] = []
  for i in self.out_at..<(self.out_at + n) {
    p.push(self.out_p[i])
    t.push(self.out_t[i])
  }
  self.out_at += n
  let right = match self.right_now {
    Some(b) => b
    None => abort("swap cursor: pending pairs without a table batch")
  }
  let columns : Array[@types.ColumnVector] = []
  for c in 0..<self.left_width {
    columns.push(gather(self.prefix.columns()[c], p))
  }
  for c in 0..<self.step.right_width {
    columns.push(gather(right.columns()[c], t))
  }
  @types.DataBatch::new(columns, n)
}

///|
/// The next batch of joined rows, or `None` once, after the table's stream ends.
/// An empty prefix matches nothing but the table is still read to its end, so
/// the scan counter is the one the unswapped chain reports.
fn SwapCursor::next(
  self : SwapCursor,
) -> @types.DataBatch? raise @types.SqlError {
  while true {
    if self.out_at < self.out_p.length() {
      let batch = self.slice()
      if self.out_at >= self.out_p.length() {
        self.out_p = []
        self.out_t = []
        self.out_at = 0
      }
      return Some(batch)
    }
    if self.done {
      return None
    }
    match (self.next_right)() {
      Some(right) => {
        if right.row_count() == 0 || self.prefix.row_count() == 0 {
          continue
        }
        let right_keys : Array[@types.ColumnVector] = []
        for e in self.step.keys_r {
          right_keys.push(eval_vec(e, right))
        }
        if !self.primed {
          self.prime(right_keys)
        }
        let rstate : ResidualState? = match self.step.residual {
          Some(re) =>
            Some(
              residual_state(
                residual_plan(re, self.left_width, self.step.right_width),
                self.prefix,
                right,
              ),
            )
          None => None
        }
        self.right_now = Some(right)
        self.match_batch(right, right_keys, rstate)
      }
      None => {
        self.done = true
        return None
      }
    }
  }
  abort("swap cursor: the loop leaves only by returning")
}

///|
/// The most rows the earlier steps of a chain may hand over for the last step to
/// be swapped. Under a budget a quarter of it, in estimated bytes, is the other
/// bound, so the swapped side is the same kind of promise the fit check gives.
const SWAP_PREFIX_ROWS : Int32 = 65536

///|
/// Whether the last step of this chain may swap its sides. INNER only; an
/// aggregate whose answer depends on the order rows arrive in (`string_agg`,
/// `approx_quantile`) keeps the unswapped chain, and so does a LIMIT or OFFSET
/// over groups with no ORDER BY, because the groups it keeps would change.
fn join_agg_swappable(bq : BoundQuery) -> Bool {
  let last = bq.steps.length() - 1
  if last < 1 {
    return false
  }
  match bq.steps[last].kind {
    Inner => ()
    _ => return false
  }
  for spec in bq.aggs {
    match spec.kind {
      StringAgg | ApproxQuantile => return false
      _ => ()
    }
  }
  if bq.order_by.length() == 0 && (bq.limit is Some(_) || bq.offset is Some(_)) {
    return false
  }
  true
}

///|
/// Pull the output of every step but the last, up to the cap. `Some` carries the
/// rows and the rows table 0 delivered when the pull ended inside the cap; `None`
/// means it passed the cap, and everything collected is dropped.
fn join_agg_swap_prefix(
  src : JoinSource,
  launch : Launch,
  scans : Array[Array[@types.DataBatch]],
  opts : ExecOptions,
) -> (Array[@types.DataBatch], Int64)? raise @types.SqlError {
  let bq = launch.bq
  let steps = bq.steps
  let last = steps.length() - 1
  let head : Array[JoinStep] = []
  for i in 0..<last {
    head.push(steps[i])
  }
  let probe = table_input_pull(
    bq,
    launch.plan,
    src.probe,
    0,
    steps[1].probe_filter,
  )
  let probe_next : () -> @types.DataBatch? raise @types.SqlError = fn() -> @types.DataBatch? raise @types.SqlError {
    probe.next()
  }
  let chain = chain_pull(head, join_agg_sides(scans, steps), 1, probe_next)
  // step 1's probe filter already ran in the probe pull
  let input = if last == 1 {
    chain
  } else {
    filtered_pull(chain, steps[last].probe_filter)
  }
  let cap_bytes = if opts.budget > 0 { opts.budget / 4 } else { 2147483647 }
  let out : Array[@types.DataBatch] = []
  let mut rows = 0
  let mut bytes = 0
  while input() is Some(batch) {
    out.push(batch)
    rows += batch.row_count()
    bytes += estimate_batch_bytes(batch)
    if rows > SWAP_PREFIX_ROWS || bytes > cap_bytes {
      return None
    }
  }
  Some((out, probe.scanned))
}

///|
/// Run the aggregate from the swapped last step: the prefix is the build side and
/// the last table is the probe, streamed through its build filter. The counters
/// are the unswapped chain's: one `scan` per table, then `joins`.
fn run_join_agg_swap(
  src : JoinSource,
  launch : Launch,
  scans : Array[Array[@types.DataBatch]],
  prefix : (Array[@types.DataBatch], Int64),
  opts : ExecOptions,
  stats : Array[(String, Int64)],
  census~ : MemCensus? = None,
) -> SelectResult raise @types.SqlError {
  let bq = launch.bq
  let steps = bq.steps
  let last = steps.length() - 1
  let step = steps[last]
  let left_width = step.out_dtypes.length() - step.right_width
  let prefix_batch = concat_batches(
    prefix.0,
    head_dtypes(step.out_dtypes, left_width),
  )
  let table = table_input_pull(
    bq,
    launch.plan,
    src.builds[last - 1],
    last,
    None,
  )
  let table_next : () -> @types.DataBatch? raise @types.SqlError = fn() -> @types.DataBatch? raise @types.SqlError {
    table.next()
  }
  let cursor = SwapCursor::open(step, prefix_batch, table_next)
  let out : () -> @types.DataBatch? raise @types.SqlError = fn() -> @types.DataBatch? raise @types.SqlError {
    cursor.next()
  }
  let join : JoinFoldPull = {
    next_joined: out,
    deferred: bq.deferred,
    joined: 0L,
  }
  let next = fn() -> @types.DataBatch? raise @types.SqlError { join.next() }
  let folded = fold_pulled(next, launch, opts, census~)
  stats.push(("scan \{launch.schemas[0].table}", prefix.1))
  for i in 1..<last {
    let mut rows = 0L
    for b in scans[i - 1] {
      rows += b.row_count().to_int64()
    }
    stats.push(("scan \{launch.schemas[i].table}", rows))
  }
  stats.push(("scan \{launch.schemas[last].table}", table.scanned))
  stats.push(("joins", join.joined))
  finish_agg_pull(folded, launch, stats)
}
