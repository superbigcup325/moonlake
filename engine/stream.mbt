// The batch contract, and the first operator that runs by it.
//
// A stage hands out batches one at a time. What a stage may assume, and what
// it must promise, is small enough to write down:
//
// - `next` returns whole batches until it returns `None`. A batch carries its
//   own vectors and row count, so a stage never hands out a partial row and a
//   consumer never sees a row count it did not receive.
// - `Some` means at least one live row. A stage that filters its input may end
//   up with nothing and must not pass that on; consumers may still receive a
//   zero-row batch from a source and must not treat it as an error.
// - Batch size is the producer's business: sources use SCAN_BATCH_ROWS, but no
//   stage may assume it, so a consumer that needs `n` rows loops.
// - Order is the order the source gives, and nothing may rely on an order the
//   query did not ask for. That is exactly what makes a LIMIT streamable and
//   an ORDER BY not.
// - A returned batch belongs to the caller: the stages here allocate a fresh
//   one per call (they copy into their own vectors), so a consumer may keep
//   the batches it has seen. Conversely a stage must not mutate a batch after
//   returning it.
// - Types and NULLs come from the batch layout unchanged. A stage does not
//   widen a column, convert a value, or represent NULL as a missing row.
//
// Early stop needs no protocol. A consumer that has what it asked for simply
// stops calling `next`; there is no cancel message and no `Stop` value, so a
// stage cannot claim to have stopped for a reason it did not have. What this
// costs the producer is that an unfinished stream must be safe to drop: no
// spill files, no locks (the scan sources here hold only decoders and open
// file handles, closed on drop).
//
// Rows may move toward the source only where the engine itself applies them
// before any join: the table's build filter is applied to that table's rows
// before the first join step, so a source may skip rows that cannot satisfy
// it (see scan.mbt for why probe filters, join residuals and the deferred
// WHERE may not travel). What streams: scan, build filter, the deferred WHERE,
// projection and an OFFSET/LIMIT window. What cannot, because its first output
// row does not exist until every input row is in: a join, ORDER BY, and SELECT
// DISTINCT.
//
// Aggregation is the case in between, and worth stating on its own: its output
// is one batch, but its *input* need not be one array. The group state is built
// from the batches as they arrive (`InputPull` below feeds `aggregate_seq`), so a
// single-table GROUP BY or a global aggregate holds its state plus one batch,
// not its input. It is the same fold the collected path uses, just not handed an
// array first.
//
// The pull lives here, not in the executor: `scan_pull` opens one and
// `ResultStream` hands its batches to a caller. Both result deliveries — the
// collected one the engine still returns and the incremental one a caller can
// ask for — read the same pull, so they cannot disagree about rows.

///|
/// The single-table shape that can be pulled instead of collected, if this
/// query is one: one lazy table, and nothing above the projection that has to
/// see every row first.
///
/// A LIMIT is not required and does not change the answer: the window is
/// applied to the batches as they arrive, so a windowed query stops reading as
/// soon as it is full and an unbounded one reads the table once.
fn streaming_source(
  bq : BoundQuery,
  sources : Array[@catalog.TableEntry?],
) -> @catalog.TableEntry? {
  if bq.aggregate ||
    bq.order_by.length() > 0 ||
    bq.windows.length() > 0 ||
    bq.distinct {
    return None
  }
  // one FROM table means one join step; a second step is a join, which needs
  // its build side whole
  if bq.steps.length() != 1 || bq.steps[0].table != 0 {
    return None
  }
  match sources[0] {
    Some(entry) => if entry.is_lazy() { Some(entry) } else { None }
    None => None
  }
}

///|
/// The single-table shape an aggregate can be fed from the scan, if this query
/// is one: one lazy table, an aggregate, and nothing above it that needs the
/// whole row set first. GROUP BY is fine — the group state is built per batch —
/// and so are HAVING, which runs on the finished groups, and ORDER BY, which
/// sorts those groups once the last input row has been folded.
///
/// A memory budget does not change the shape: a budgeted GROUP BY is also pulled,
/// and `run_agg_pull` buffers the batches up to the budget and partitions them
/// into spill runs only when they do not fit (`aggregate_pulled`).
fn streaming_agg_source(
  bq : BoundQuery,
  sources : Array[@catalog.TableEntry?],
) -> @catalog.TableEntry? {
  if !bq.aggregate || bq.windows.length() > 0 || bq.distinct {
    return None
  }
  if bq.steps.length() != 1 || bq.steps[0].table != 0 {
    return None
  }
  match sources[0] {
    Some(entry) => if entry.is_lazy() { Some(entry) } else { None }
    None => None
  }
}

///|
/// The shape an aggregate can be fed from a join, if this query is one: one or
/// more join steps over lazy base tables and an aggregate above it, with nothing
/// on top that needs the whole row set first.
///
/// It is `streaming_join_source`'s predicate with the aggregate allowed instead
/// of refused and the chain allowed instead of refused: every step is INNER,
/// LEFT or FULL with a key list on both sides, every `FROM` item is a lazy base
/// table, and the steps join the tables in `FROM` order. A step's probe layout
/// is the previous step's output layout, so the cursor's output is still the
/// layout the fold's expressions are bound to, one step or five. A budget is not
/// part of the shape: the build sides are summed against it where the query is
/// routed, because every step holds its side whole.
fn streaming_join_agg_source(
  bq : BoundQuery,
  sources : Array[@catalog.TableEntry?],
) -> JoinSource? {
  if !bq.aggregate || bq.windows.length() > 0 || bq.distinct {
    return None
  }
  let steps = bq.steps
  if steps.length() < 2 || steps.length() > sources.length() {
    return None
  }
  for i in 1..<steps.length() {
    let step = steps[i]
    match step.kind {
      Inner | Left | Full => ()
      _ => return None
    }
    // a keyless join is a cross join: the collected path refuses one that
    // overflows a budget instead of partitioning it, and this path keeps that
    // answer rather than disagreeing with it
    if step.keys_l.length() == 0 || step.keys_r.length() == 0 {
      return None
    }
  }
  let builds : Array[@catalog.TableEntry] = []
  for i in 0..<steps.length() {
    // the chain is the FROM order, so step i joins FROM item i
    if steps[i].table != i {
      return None
    }
    if i == 0 {
      continue
    }
    match sources[i] {
      Some(entry) =>
        if entry.is_lazy() {
          builds.push(entry)
        } else {
          return None
        }
      None => return None
    }
  }
  match sources[0] {
    Some(probe) => if probe.is_lazy() { Some({ probe, builds, }) } else { None }
    None => None
  }
}

///|
/// The single-table shape an `ORDER BY` can be handed from the scan, if this
/// query is one: one lazy table, a sort, and a memory budget to spill runs
/// against. DISTINCT is fine — it is applied while the merge hands rows back —
/// and so is an OFFSET/LIMIT window, which is what lets a windowed sort stop
/// merging early.
///
/// A budget is required because that is the only reason to sort in runs: with
/// no budget the in-memory sort has to see every row anyway, and building runs
/// would be work for nothing.
fn streaming_sort_source(
  bq : BoundQuery,
  sources : Array[@catalog.TableEntry?],
  opts : ExecOptions,
) -> @catalog.TableEntry? {
  if bq.aggregate ||
    bq.order_by.length() == 0 ||
    bq.windows.length() > 0 ||
    opts.budget <= 0 {
    return None
  }
  if bq.steps.length() != 1 || bq.steps[0].table != 0 {
    return None
  }
  match sources[0] {
    Some(entry) => if entry.is_lazy() { Some(entry) } else { None }
    None => None
  }
}

///|
/// This query's ORDER BY keys in the shape the sort compares.
fn order_keys(bq : BoundQuery) -> Array[(PhysExpr, Bool, Bool?)] {
  let keys : Array[(PhysExpr, Bool, Bool?)] = []
  for spec in bq.order_by {
    keys.push((spec.expr, spec.desc, spec.nulls_first))
  }
  keys
}

///|
/// What a spilled sort handed back: the run files it still owns, and either the
/// pre-projection input (everything fit the accumulator, so no file was
/// written) or the merge inputs to read.
priv enum SortedInput {
  InMemory(Array[@types.DataBatch])
  Runs(Array[Int32])
}

///|
/// The outcome of feeding a sort from the scan: how many rows the build filter
/// kept, how many runs were written (zero means the input fit the accumulator
/// and no file exists), and what to do with it.
priv struct SortInput {
  scanned : Int64
  runs : Int32
  input : SortedInput
}

///|
/// Build the sort's runs from the scan and answer what to do next. The pull is
/// consumed here, so the scan's rows are never an array; on the error path the
/// runs already written are removed before the error leaves.
fn sort_input(
  entry : @catalog.TableEntry,
  launch : Launch,
  opts : ExecOptions,
  store : SpillStore,
  owned : Array[Int32],
) -> SortInput raise @types.SqlError {
  let bq = launch.bq
  let pull = input_pull(bq, launch.plan, entry)
  let built = build_runs(
    fn() -> @types.DataBatch? raise @types.SqlError { pull.next() },
    order_keys(bq),
    opts.budget,
    store,
  )
  if built.ids.length() == 0 {
    return { scanned: pull.scanned, runs: 0, input: InMemory(built.acc), }
  }
  errdefer remove_ids(store, owned)
  // the primary runs are this sort's files too: `reduce_runs` only adds the
  // intermediates it writes, and a run set small enough to skip reduction would
  // otherwise have no owner at all
  let runs = built.ids.length()
  for id in built.ids {
    owned.push(id)
  }
  let inputs = reduce_runs(built.ids, order_keys(bq), store, owned)
  { scanned: pull.scanned, runs, input: Runs(inputs), }
}

///|
/// A scan cursor for the two operators that fold their input as it arrives: the
/// source's batches, this table's build filter and the query's deferred WHERE
/// applied to each one before it is folded (by `aggregate_seq`) or written to a
/// sorted run. `scanned` counts the rows the build filter kept, which is the
/// number the collected path reports for the same table, so `--analyze` reads
/// the same either way.
///
/// A batch that the filters empty is not handed on: the batch contract forbids
/// handing out a zero-row batch, and a fold or a run of nothing adds nothing.
priv struct InputPull {
  stream : &@catalog.BatchStream
  build_filter : PhysExpr?
  deferred : PhysExpr?
  mut scanned : Int64
}

///|
fn input_pull(
  bq : BoundQuery,
  plan : PrunePlan,
  entry : @catalog.TableEntry,
) -> InputPull raise @types.SqlError {
  table_input_pull(bq, plan, entry, 0, bq.deferred)
}

///|
/// `input_pull` for table `t`, filtering with `deferred` instead of the query's
/// own WHERE: a join probes its first table with the step's probe filter, and
/// the deferred predicate runs after the join where its columns exist.
fn table_input_pull(
  bq : BoundQuery,
  plan : PrunePlan,
  entry : @catalog.TableEntry,
  t : Int32,
  deferred : PhysExpr?,
) -> InputPull raise @types.SqlError {
  {
    stream: entry.stream(scan_request_of(bq, plan.table_cols[t], t)),
    build_filter: scan_filter_of(bq, t),
    deferred,
    scanned: 0L,
  }
}

///|
fn InputPull::next(self : InputPull) -> @types.DataBatch? raise @types.SqlError {
  while self.stream.next() is Some(batch) {
    let kept = match self.build_filter {
      Some(p) => compact(batch, eval_mask(p, batch))
      None => batch
    }
    self.scanned += kept.row_count().to_int64()
    if kept.row_count() == 0 {
      continue
    }
    let kept = match self.deferred {
      Some(p) => compact(kept, eval_mask(p, kept))
      None => kept
    }
    if kept.row_count() > 0 {
      return Some(kept)
    }
  }
  None
}

///|
/// The fold a pulled aggregate runs: the budgeted partition path for a grouped
/// query under a budget, the unbounded fold otherwise. Both callers (a single
/// table and a join) differ only in what feeds `next`.
fn fold_pulled(
  next : () -> @types.DataBatch? raise @types.SqlError,
  launch : Launch,
  opts : ExecOptions,
) -> PulledAgg raise @types.SqlError {
  let bq = launch.bq
  if opts.budget > 0 && bq.group_exprs.length() > 0 {
    aggregate_pulled(next, bq.group_exprs, bq.group_types, bq.aggs, opts)
  } else {
    {
      batch: aggregate_seq({ next, }, bq.group_exprs, bq.group_types, bq.aggs),
      partitions: 0,
      peak_buffered: 0L,
      largest_spilled: 0L,
    }
  }
}

///|
/// The stages every pulled aggregate runs after its fold: HAVING on the finished
/// groups, the ORDER BY over them, the projection, the OFFSET/LIMIT window, and
/// the counters that describe them. A grouped result is final only once the last
/// input row has been folded, so the sort and the window are applied here, not to
/// the input.
///
/// The sort is the in-memory one the eager aggregate path runs, and for the same
/// reason: what it orders is the grouped result, not the fold's input, and a
/// budget bounds the input buffers (verification §45). Ordering a grouped result
/// through sorted runs would be a different, larger decision.
fn finish_agg_pull(
  folded : PulledAgg,
  launch : Launch,
  stats : Array[(String, Int64)],
) -> SelectResult raise @types.SqlError {
  let bq = launch.bq
  let grouped = match bq.having {
    Some(h) => compact(folded.batch, eval_mask(h, folded.batch))
    None => folded.batch
  }
  // only when it spilled, so a query that fits its budget reports what it did
  // before
  if folded.partitions > 0 {
    stats.push(("spill partitions", folded.partitions.to_int64()))
    stats.push(("buffered bytes peak (estimated)", folded.peak_buffered))
    stats.push(
      ("largest partition spilled (estimated)", folded.largest_spilled),
    )
  }
  stats.push(("aggregate", grouped.row_count().to_int64()))
  let batch = if bq.order_by.length() > 0 {
    // the same key resolution the eager path uses: an output-column key sorts by
    // the projection expression, which holds the values the projected column
    // will carry, and an expression key by its bound form
    let keys : Array[(PhysExpr, Bool, Bool?)] = []
    for spec in bq.order_by {
      let ke : PhysExpr = match spec.out_col {
        Some(i) => bq.out_exprs[i]
        None => spec.expr
      }
      keys.push((ke, spec.desc, spec.nulls_first))
    }
    let sorted = sort_exprs(grouped, keys, None, None)
    let projected = project(sorted, bq.out_exprs, bq.out_types)
    sort_exprs(projected, [], bq.offset, bq.limit)
  } else {
    let projected = project(grouped, bq.out_exprs, bq.out_types)
    order_limit(projected, [], bq.limit, bq.offset)
  }
  stats.push(("result", batch.row_count().to_int64()))
  { names: bq.names, types: bq.out_types, batch, }
}

///|
/// Run an aggregate from the scan instead of from a collected input: the same
/// fold (`aggregate_seq`) over a sequence that opens the table once, then the
/// same HAVING, ordering, projection and window the collected tail applies to an
/// aggregate's one output batch.
fn run_agg_pull(
  entry : @catalog.TableEntry,
  launch : Launch,
  opts : ExecOptions,
  stats : Array[(String, Int64)],
) -> SelectResult raise @types.SqlError {
  let bq = launch.bq
  let pull = input_pull(bq, launch.plan, entry)
  let next = fn() -> @types.DataBatch? raise @types.SqlError { pull.next() }
  let folded = fold_pulled(next, launch, opts)
  stats.push(("scan \{launch.schemas[0].table}", pull.scanned))
  finish_agg_pull(folded, launch, stats)
}

///|
/// A pull over a join's output for a fold above it: the chain hands out joined
/// batches in the last step's combined layout, the deferred WHERE trims each one,
/// and the rows that survive are folded. This is the one place a step's joined
/// rows exist, so a fold fed from here never holds them, whatever the chain
/// length.
priv struct JoinFoldPull {
  next_joined : () -> @types.DataBatch? raise @types.SqlError
  deferred : PhysExpr?
  mut joined : Int64
}

///|
fn JoinFoldPull::next(
  self : JoinFoldPull,
) -> @types.DataBatch? raise @types.SqlError {
  while (self.next_joined)() is Some(batch) {
    let rows = filter_batches([batch], self.deferred)
    // the batch contract forbids handing out a zero-row batch, and a fold of
    // nothing adds nothing
    if rows.length() == 0 || rows[0].row_count() == 0 {
      continue
    }
    self.joined += rows[0].row_count().to_int64()
    return Some(rows[0])
  }
  None
}

///|
/// Whether a query composes a join into an aggregate. The build side has to stay
/// whole for the join, so a budget smaller than the sides it holds keeps the
/// eager path, which can partition each join instead; with no budget there is no
/// bound to violate and the fold above it is unbounded with it. A chain keeps one
/// side and its key index per step, so those sides are the price of composing it,
/// and measurement put that price at or below what the eager path holds for every
/// TPC-H chain at SF1 once each side was indexed as one row-id range instead of a
/// list per key (verification §52).
fn join_agg_composes(sides_bytes : Int32, opts : ExecOptions) -> Bool {
  opts.budget <= 0 || sides_bytes <= opts.budget
}

///|
/// The build side of every step, scanned once, projected and filtered the way the
/// collected path does it. The scans are also the row counts `--analyze` reports,
/// and because a budget too small to hold the sides sends them to the eager path,
/// no table is read twice. The padded copies the cursors read are separate
/// (`join_agg_sides`), so a query that keeps the eager path never pays for them.
fn join_agg_scans(
  src : JoinSource,
  launch : Launch,
) -> Array[Array[@types.DataBatch]] raise @types.SqlError {
  let bq = launch.bq
  let steps = bq.steps
  let scans : Array[Array[@types.DataBatch]] = []
  for i in 1..<steps.length() {
    scans.push(
      materialize_scan(
        src.builds[i - 1],
        scan_request_of(bq, launch.plan.table_cols[i], i),
        scan_filter_of(bq, i),
      ),
    )
  }
  scans
}

///|
/// The bytes a chain's resident sides will take. A side is its scan's batches
/// concatenated into one batch (a single batch is kept as it is), so the scan's
/// own bytes bound it, and the check runs before the copy exists: a query that
/// keeps the eager path never pays for one.
fn join_agg_sides_bytes(scans : Array[Array[@types.DataBatch]]) -> Int32 {
  let mut total = 0
  for side in scans {
    total += batches_bytes(side)
  }
  total
}

///|
/// The resident side of every step in the layout its cursor reads: the scan's
/// rows followed by the columns the step's output carries beside them.
fn join_agg_sides(
  scans : Array[Array[@types.DataBatch]],
  steps : Array[JoinStep],
) -> Array[@types.DataBatch] {
  let sides : Array[@types.DataBatch] = []
  let count = scans.length()
  for i in 1..<(count + 1) {
    let step = steps[i]
    sides.push(
      concat_batches(
        scans[i - 1],
        tail_dtypes(step.out_dtypes, step.right_width),
      ),
    )
  }
  sides
}

///|
/// A pull over the output of a chain of steps. Each step's cursor is fed by the
/// one below it, so the joined rows of step `i` are the probe batches of step
/// `i+1` and only one batch of them exists at a time. The per-step order is the
/// collected path's: step `i`'s probe filter trims the previous output, and the
/// last step's output is what the fold receives.
fn chain_pull(
  steps : Array[JoinStep],
  builds : Array[@types.DataBatch],
  at : Int32,
  next_left : () -> @types.DataBatch? raise @types.SqlError,
) -> (() -> @types.DataBatch? raise @types.SqlError) raise @types.SqlError {
  if at >= steps.length() {
    return next_left
  }
  // step 1's probe filter is already applied by the probe pull; every later one
  // trims what the step below handed over
  let input = if at == 1 {
    next_left
  } else {
    filtered_pull(next_left, steps[at].probe_filter)
  }
  let cursor = JoinCursor::open(steps[at], builds[at - 1], input)
  let out : () -> @types.DataBatch? raise @types.SqlError = fn() -> @types.DataBatch? raise @types.SqlError {
    cursor.next()
  }
  chain_pull(steps, builds, at + 1, out)
}

///|
/// A pull that keeps the rows a predicate accepts and skips the batches it
/// empties: one step's probe filter over the output of the step below.
fn filtered_pull(
  next : () -> @types.DataBatch? raise @types.SqlError,
  pred : PhysExpr?,
) -> () -> @types.DataBatch? raise @types.SqlError {
  fn() -> @types.DataBatch? raise @types.SqlError {
    while next() is Some(batch) {
      let rows = filter_batches([batch], pred)
      if rows.length() > 0 && rows[0].row_count() > 0 {
        return Some(rows[0])
      }
    }
    None
  }
}

///|
/// Run an aggregate from a joined pull instead of from the collected joined
/// rows: the build side is already resident (it has to be), the probe side opens
/// once and arrives a batch at a time, and each joined batch is folded before the
/// next one exists. The budget bounds the fold's input buffer, as it does for a
/// single table; the build side is bounded by the routing decision that accepted
/// the shape.
fn run_join_agg_pull(
  src : JoinSource,
  scans : Array[Array[@types.DataBatch]],
  builds : Array[@types.DataBatch],
  launch : Launch,
  opts : ExecOptions,
  stats : Array[(String, Int64)],
) -> SelectResult raise @types.SqlError {
  let bq = launch.bq
  let steps = bq.steps
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
  let chain = chain_pull(steps, builds, 1, probe_next)
  let join : JoinFoldPull = {
    next_joined: chain,
    deferred: bq.deferred,
    joined: 0L,
  }
  let next = fn() -> @types.DataBatch? raise @types.SqlError { join.next() }
  let folded = fold_pulled(next, launch, opts)
  stats.push(("scan \{launch.schemas[0].table}", probe.scanned))
  for i in 1..<(scans.length() + 1) {
    let mut rows = 0L
    for b in scans[i - 1] {
      rows += b.row_count().to_int64()
    }
    stats.push(("scan \{launch.schemas[i].table}", rows))
  }
  stats.push(("joins", join.joined))
  finish_agg_pull(folded, launch, stats)
}

///|
/// The layout the sort's input has: the columns the scan was asked for, in
/// request order. Read from the schema rather than from a batch, so an input of
/// no batches still has the layout its empty answer needs.
fn sort_pre_types(launch : Launch) -> Array[@types.DataType] {
  let out : Array[@types.DataType] = []
  for c in launch.plan.table_cols[0] {
    out.push(launch.schemas[0].columns[c].dtype)
  }
  out
}

///|
/// The tables a join can be pulled from: the probe side, whose rows arrive a
/// batch at a time, and the build side of every step, in step order. Both have
/// to be lazy base tables, and each build side is resident because a probe row
/// has to find its matches in it.
priv struct JoinSource {
  probe : @catalog.TableEntry
  builds : Array[@catalog.TableEntry]
}

///|
/// The join shape a stream can be pulled from, if this query is one: one join
/// step over two lazy tables, with no aggregate, ORDER BY, DISTINCT or window
/// function above it. INNER, LEFT and FULL are the kinds whose output row is
/// decidable from the pair (RIGHT is a swapped LEFT and SEMI/ANTI drop a side),
/// and each of those goes through the same hash join the collected path uses.
///
/// A chain of two or more joins is not included: its probe side is the join
/// below it, which a stream would have to pipe into this one. That pipeline is
/// not built, so a chain collects as before.
fn streaming_join_source(
  bq : BoundQuery,
  sources : Array[@catalog.TableEntry?],
) -> JoinSource? {
  if bq.aggregate ||
    bq.order_by.length() > 0 ||
    bq.windows.length() > 0 ||
    bq.distinct {
    return None
  }
  if bq.steps.length() != 2 {
    return None
  }
  let step = bq.steps[1]
  match step.kind {
    Inner | Left | Full => ()
    _ => return None
  }
  if bq.steps[0].table != 0 || step.table != 1 {
    return None
  }
  // a keyless join is a cross join: the collected path refuses one that
  // overflows a budget instead of partitioning it, and the stream keeps that
  // answer rather than disagreeing with it
  if step.keys_l.length() == 0 || step.keys_r.length() == 0 {
    return None
  }
  match (sources[0], sources[1]) {
    (Some(probe), Some(build)) =>
      if probe.is_lazy() && build.is_lazy() {
        Some({ probe, builds: [build], })
      } else {
        None
      }
    _ => None
  }
}

///|
/// Run a spilled ORDER BY from the scan and hand the whole result back as one
/// batch — what `execute` wants. The win is on the input side: the runs are
/// built from the scan, so the table is never an array, and with a LIMIT the
/// merge stops as soon as the window is full.
fn run_sort_pull(
  entry : @catalog.TableEntry,
  launch : Launch,
  opts : ExecOptions,
  stats : Array[(String, Int64)],
) -> SelectResult raise @types.SqlError {
  let bq = launch.bq
  let store = budget_store(opts)
  let owned : Array[Int32] = []
  errdefer remove_ids(store, owned)
  let built = sort_input(entry, launch, opts, store, owned)
  stats.push(("scan \{launch.schemas[0].table}", built.scanned))
  let batch = match built.input {
    InMemory(batches) => {
      // no run was written: the batches are the input, and the in-memory tail
      // sorts, projects, dedupes and windows exactly as it does without a budget
      let pre = concat_batches(batches, sort_pre_types(launch))
      let sorted = sort_exprs(pre, order_keys(bq), None, None)
      finish_sorted(
        sorted,
        bq.out_exprs,
        bq.out_types,
        bq.distinct,
        bq.offset,
        bq.limit,
      )
    }
    Runs(inputs) => {
      stats.push(("spill runs", built.runs.to_int64()))
      let out = final_merge(
        inputs,
        order_keys(bq),
        bq.out_exprs,
        bq.out_types,
        bq.distinct,
        bq.offset,
        bq.limit,
        store,
      )
      out
    }
  }
  remove_ids(store, owned)
  stats.push(("result", batch.row_count().to_int64()))
  { names: bq.names, types: bq.out_types, batch, }
}

///|
/// The spill store a budgeted shape needs, or the error that says so.
fn budget_store(opts : ExecOptions) -> SpillStore raise @types.SqlError {
  match opts.spill {
    Some(store) => store
    None =>
      raise @types.SqlError::Execute(
        "query has a memory budget but no spill store is configured (pass --spill-dir)",
      )
  }
}

///|
/// A live pull over one table: the source cursor, the stages that run per
/// batch, and how much of the OFFSET/LIMIT window is still untaken.
///
/// State is the struct's own (`mut`), so a caller mutates the pull it was
/// given rather than replacing it: `next` may be resumed, abandoned, or never
/// called, and the source cursor is dropped with the struct.
priv struct ScanPull {
  stream : &@catalog.BatchStream
  build_filter : PhysExpr?
  deferred : PhysExpr?
  out_exprs : Array[PhysExpr]
  out_types : Array[@types.DataType]
  table_name : String
  stats : Array[(String, Int64)]
  mut offset_left : Int64
  mut limit_left : Int64 // negative means the query has no LIMIT
  mut scanned : Int64
}

///|
/// Open the pull for a streamable query: one scan request, one source cursor,
/// and the per-batch stages the query needs.
fn scan_pull(
  bq : BoundQuery,
  plan : PrunePlan,
  entry : @catalog.TableEntry,
  table_name : String,
  stats : Array[(String, Int64)],
) -> ScanPull raise @types.SqlError {
  let request = scan_request_of(bq, plan.table_cols[0], 0)
  let stream = entry.stream(request)
  let offset = match bq.offset {
    Some(n) => n.to_int64()
    None => 0L
  }
  let limit = match bq.limit {
    Some(n) => n.to_int64()
    None => -1L
  }
  {
    stream,
    build_filter: scan_filter_of(bq, 0),
    deferred: bq.deferred,
    out_exprs: bq.out_exprs,
    out_types: bq.out_types,
    table_name,
    stats,
    offset_left: offset,
    limit_left: limit,
    scanned: 0L,
  }
}

///|
/// The next batch inside the window, or `None` once the scan is exhausted or
/// the window is full. A batch that the window empties is not returned: the
/// contract forbids handing out a zero-row batch.
fn ScanPull::next(self : ScanPull) -> @types.DataBatch? raise @types.SqlError {
  while self.limit_left != 0 {
    let raw = match self.stream.next() {
      None => break
      Some(batch) => batch
    }
    // the build filter travels to the source; rows that cannot match never
    // reach the stages below
    let kept = match self.build_filter {
      Some(p) => compact(raw, eval_mask(p, raw))
      None => raw
    }
    self.scanned += kept.row_count().to_int64()
    if kept.row_count() == 0 {
      continue
    }
    let rows = filter_batches([kept], self.deferred)
    if rows.length() == 0 || rows[0].row_count() == 0 {
      continue
    }
    let projected = project(rows[0], self.out_exprs, self.out_types)
    let n = projected.row_count().to_int64()
    let mut start = 0L
    if self.offset_left > 0 {
      start = if self.offset_left < n { self.offset_left } else { n }
      self.offset_left -= start
    }
    let mut take = n - start
    if self.limit_left >= 0 && take > self.limit_left {
      take = self.limit_left
    }
    if take <= 0 {
      continue
    }
    if self.limit_left >= 0 {
      self.limit_left -= take
    }
    if start == 0 && take == n {
      return Some(projected)
    }
    return Some(
      order_limit(projected, [], Some(take.to_int()), Some(start.to_int())),
    )
  }
  None
}

///|
/// Drain the pull into one batch — what a caller that wants the whole result
/// gets, and how the collected API stays the same one-row-set answer as the
/// stream.
fn drain_scan(
  pull : ScanPull,
  bq : BoundQuery,
) -> SelectResult raise @types.SqlError {
  let chunks : Array[@types.DataBatch] = []
  while pull.next() is Some(batch) {
    chunks.push(batch)
  }
  // what the query cost its source, reported once the pull is over: a scan
  // cut short by its window still says how much it read
  pull.stats.push(("scan \{pull.table_name}", pull.scanned))
  // the window was taken per batch, so there is nothing left to trim here
  let batch = concat_batches(chunks, bq.out_types)
  { names: bq.names, types: bq.out_types, batch, }
}

///|
/// A result the caller consumes batch by batch.
///
/// What the batches promise is the batch contract above: whole batches only,
/// `None` exactly once at the end, no zero-row batch, and a batch belongs to
/// the caller. What the *shape* promises:
///
/// - A single-table scan is pulled: a filter, the projection and an
///   OFFSET/LIMIT window run per batch, so the caller never holds more than one
///   batch and a windowed query stops reading when the window is full.
/// - An aggregate fold reads the scan rather than a collected input: the group
///   table is a running hash table, so the answer is one batch but the input
///   rows never are. A budget does not change that: the batches are buffered up
///   to the budget and partitioned into spill runs only past it.
/// - A spilled ORDER BY is pulled from its run files: the merge hands rows back
///   in order, and a windowed query stops merging once its window is full.
/// - A two-table INNER/LEFT/FULL join is pulled: the build side is read once
///   and stays resident — a probe row has to find its matches — but the probe
///   side arrives a batch at a time and the joined rows leave in batches, so
///   neither the probe side nor the output is ever held whole.
/// - Every other shape (a chain of two or more joins, a RIGHT or SEMI/ANTI
///   join, a keyless cross join, or anything above a join that needs every row
///   first: ORDER BY, GROUP BY, DISTINCT, a window function, a derived table, a
///   set operation) is executed eagerly here, and `next` yields that result as
///   one batch. The rows are the ones `execute` returns for the same query.
///
/// The lifecycle is short enough to state whole:
///
/// - Exhaustion: `next` returns `None` at the end and keeps returning `None`;
///   there is no second end and no reset.
/// - Early stop: `close` stops the pull, is idempotent, is safe before the
///   first `next`, and leaves `next` returning `None`.
/// - Failure: a pull that raises ends the stream, so a retry after an error
///   reports the end rather than resuming a scan whose state is unknown.
/// - Cleanup: dropping the stream releases the scan cursor. A spilled sort goes
///   further: a sort under a budget writes run files and hands out their merge,
///   so it owns files this stream removes when the merge ends, when `close`
///   stops it, and when it raises. A join owns nothing of its own — its build
///   side is resident and its probe side belongs to the catalog — so `close`
///   only stops probing. A consumer that vanishes without either leaves them to
///   the store's owner — the CLI deletes its per-query directory at exit, and a
///   library caller's `SpillStore` is the caller's to sweep. Exhaust the stream or close it and nothing is
///   left behind. `catalog.BatchStream` gains no `close` method for this:
///   exhaustion is its whole protocol, and adding one would break every
///   implementation outside this module.
pub struct ResultStream {
  priv names : Array[String]
  priv types : Array[@types.DataType]
  priv pull : StreamPull
  priv mut done : Bool
}

///|
priv enum StreamPull {
  Scanned(ScanPull)
  Sorted(SortedPull)
  Joined(JoinedPull)
  Materialized(@types.DataBatch?)
}

///|
/// A stream over a spilled sort's merge. This is the one pull that owns files:
/// the run files the sort wrote are removed when the merge ends, when `close`
/// stops it, and when the merge raises — the three ways a stream stops. A
/// caller that drops one unfinished leaves them to the store's owner (the CLI's
/// per-query directory goes away with the process); `close` is the way to
/// release them early.
priv struct SortedPull {
  cursor : MergeCursor
  store : SpillStore
  mut owned : Array[Int32]
}

///|
fn SortedPull::release(self : SortedPull) -> Unit {
  // best-effort on purpose: `close` cannot raise, and on the error path a
  // second failure must not replace the one that ended the merge
  remove_ids(self.store, self.owned) catch {
    _ => ()
  }
  self.owned = []
}

///|
/// The stream for a spilled ORDER BY: the runs are built here (the scan has to
/// be read to sort it), and then the merge is handed out batch by batch, so the
/// caller never holds the sorted row set. An input that fit the accumulator has
/// no merge and no files — it is one sorted batch, which is what `execute`
/// returns for the same query.
fn ResultStream::sorted(
  entry : @catalog.TableEntry,
  launch : Launch,
  opts : ExecOptions,
) -> ResultStream raise @types.SqlError {
  let bq = launch.bq
  let store = budget_store(opts)
  let owned : Array[Int32] = []
  errdefer remove_ids(store, owned)
  let built = sort_input(entry, launch, opts, store, owned)
  let pull : StreamPull = match built.input {
    InMemory(batches) => {
      let pre = concat_batches(batches, sort_pre_types(launch))
      let sorted = sort_exprs(pre, order_keys(bq), None, None)
      Materialized(
        Some(
          finish_sorted(
            sorted,
            bq.out_exprs,
            bq.out_types,
            bq.distinct,
            bq.offset,
            bq.limit,
          ),
        ),
      )
    }
    Runs(inputs) =>
      Sorted({
        cursor: merge_open(
          inputs,
          order_keys(bq),
          bq.out_exprs,
          bq.out_types,
          bq.distinct,
          bq.offset,
          bq.limit,
          store,
        ),
        store,
        owned,
      })
  }
  { names: bq.names, types: bq.out_types, pull, done: false, }
}

///|
/// A pull over a hash join's output: the build side is resident (it has to be),
/// the probe side arrives a batch at a time and the joined rows leave in batches
/// — so the peak is the build table plus one probe batch plus one output batch,
/// not both sides plus the joined row set.
///
/// The stages after the join are the ones `ScanPull` runs per batch: the
/// deferred WHERE, the projection and the OFFSET/LIMIT window, carried across
/// batches. A windowed join therefore stops reading when its window fills —
/// `LIMIT 10` reads until ten rows have matched, not to the end.
priv struct JoinedPull {
  cursor : JoinCursor
  deferred : PhysExpr?
  out_exprs : Array[PhysExpr]
  out_types : Array[@types.DataType]
  mut offset_left : Int64
  mut limit_left : Int64 // negative means the query has no LIMIT
}

///|
fn JoinedPull::next(
  self : JoinedPull,
) -> @types.DataBatch? raise @types.SqlError {
  while self.limit_left != 0 {
    let joined = match self.cursor.next() {
      None => break
      Some(batch) => batch
    }
    let rows = filter_batches([joined], self.deferred)
    if rows.length() == 0 || rows[0].row_count() == 0 {
      continue
    }
    let projected = project(rows[0], self.out_exprs, self.out_types)
    let n = projected.row_count().to_int64()
    let mut start = 0L
    if self.offset_left > 0 {
      start = if self.offset_left < n { self.offset_left } else { n }
      self.offset_left -= start
    }
    let mut take = n - start
    if self.limit_left >= 0 && take > self.limit_left {
      take = self.limit_left
    }
    if take <= 0 {
      continue
    }
    if self.limit_left >= 0 {
      self.limit_left -= take
    }
    if start == 0 && take == n {
      return Some(projected)
    }
    return Some(
      order_limit(projected, [], Some(take.to_int()), Some(start.to_int())),
    )
  }
  None
}

///|
/// The stream for a two-table hash join: the build side is read first, then the
/// probe side is pulled batch by batch, matched against it, and handed over.
/// Nothing here owns a file, so `close` only stops the probe.
fn ResultStream::joined(
  src : JoinSource,
  launch : Launch,
) -> ResultStream raise @types.SqlError {
  let bq = launch.bq
  let step = bq.steps[1]
  let build_rows = materialize_scan(
    src.builds[0],
    scan_request_of(bq, launch.plan.table_cols[1], 1),
    scan_filter_of(bq, 1),
  )
  let build = concat_batches(
    build_rows,
    tail_dtypes(step.out_dtypes, step.right_width),
  )
  let probe = table_input_pull(bq, launch.plan, src.probe, 0, step.probe_filter)
  let offset = match bq.offset {
    Some(n) => n.to_int64()
    None => 0L
  }
  let limit = match bq.limit {
    Some(n) => n.to_int64()
    None => -1L
  }
  let next_left : () -> @types.DataBatch? raise @types.SqlError = fn() -> @types.DataBatch? raise @types.SqlError {
    probe.next()
  }
  let pull : StreamPull = Joined({
    cursor: JoinCursor::open(step, build, next_left),
    deferred: bq.deferred,
    out_exprs: bq.out_exprs,
    out_types: bq.out_types,
    offset_left: offset,
    limit_left: limit,
  })
  { names: bq.names, types: bq.out_types, pull, done: false, }
}

///|
/// The stream for a result that is already computed: one batch, then `None`.
fn ResultStream::materialized(result : SelectResult) -> ResultStream {
  {
    names: result.names,
    types: result.types,
    pull: Materialized(Some(result.batch)),
    done: false,
  }
}

///|
pub fn ResultStream::names(self : ResultStream) -> Array[String] {
  self.names
}

///|
pub fn ResultStream::types(self : ResultStream) -> Array[@types.DataType] {
  self.types
}

///|
/// Release whatever the pull owns. A scan owns its cursor, which the stream's
/// lifetime already covers; a spill-owned sort owns files, which have to be
/// removed explicitly. Idempotent.
fn ResultStream::release(self : ResultStream) -> Unit {
  match self.pull {
    Sorted(pull) => pull.release()
    _ => ()
  }
}

///|
/// The next batch, or `None` once the result is exhausted or `close` was
/// called. A pull that raises ends the stream: the stream is finished either
/// way, and a caller that retries after an error gets the end, not a resumed
/// scan.
pub fn ResultStream::next(
  self : ResultStream,
) -> @types.DataBatch? raise @types.SqlError {
  if self.done {
    return None
  }
  errdefer {
    self.done = true
    self.release()
  }
  match self.pull {
    Materialized(batch) => {
      self.done = true
      batch
    }
    Scanned(pull) =>
      match pull.next() {
        Some(batch) => Some(batch)
        None => {
          self.done = true
          None
        }
      }
    Sorted(pull) =>
      match pull.cursor.next() {
        Some(batch) => Some(batch)
        None => {
          self.done = true
          pull.release()
          None
        }
      }
    Joined(pull) =>
      match pull.next() {
        Some(batch) => Some(batch)
        None => {
          self.done = true
          None
        }
      }
  }
}

///|
/// Stop the pull. Idempotent, and early: a caller that has what it needs says
/// so instead of draining the scan. A stream over spilled runs deletes them
/// here, so a caller that stops early releases its disk too.
pub fn ResultStream::close(self : ResultStream) -> Unit {
  self.done = true
  self.release()
}
