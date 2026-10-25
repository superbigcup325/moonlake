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
// from the batches as they arrive (`AggPull` below feeds `aggregate_seq`), so a
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
/// is one: one lazy table, an aggregate, and nothing above it that needs the row
/// order or the whole row set first. GROUP BY is fine — the group state is built
/// per batch — and so is HAVING, which runs on the finished groups.
///
/// A budget is what excludes the rest: under `--memory` the grace path chooses
/// between memory and spill partitions from the size of the input it was handed,
/// so it still needs that input collected first. A global aggregate never spills
/// (one row is one row), so it streams under a budget too.
fn streaming_agg_source(
  bq : BoundQuery,
  sources : Array[@catalog.TableEntry?],
  opts : ExecOptions,
) -> @catalog.TableEntry? {
  if !bq.aggregate ||
    bq.order_by.length() > 0 ||
    bq.windows.length() > 0 ||
    bq.distinct {
    return None
  }
  if opts.budget > 0 && bq.group_exprs.length() > 0 {
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
/// A scan cursor for an aggregate: the source's batches, this table's build
/// filter and the query's deferred WHERE applied to each one before it is
/// folded. `scanned` counts the rows the build filter kept, which is the number
/// the collected path reports for the same table, so `--analyze` reads the same
/// either way.
///
/// A batch that the filters empty is not handed on: the batch contract forbids
/// handing out a zero-row batch, and a fold of nothing adds nothing.
priv struct AggPull {
  stream : &@catalog.BatchStream
  build_filter : PhysExpr?
  deferred : PhysExpr?
  mut scanned : Int64
}

///|
fn agg_pull(
  bq : BoundQuery,
  plan : PrunePlan,
  entry : @catalog.TableEntry,
) -> AggPull raise @types.SqlError {
  {
    stream: entry.stream(scan_request_of(bq, plan.table_cols[0], 0)),
    build_filter: scan_filter_of(bq, 0),
    deferred: bq.deferred,
    scanned: 0L,
  }
}

///|
fn AggPull::next(self : AggPull) -> @types.DataBatch? raise @types.SqlError {
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
/// Run an aggregate from the scan instead of from a collected input: the same
/// fold (`aggregate_seq`) over a sequence that opens the table once, then the
/// same HAVING, projection and window the collected tail applies to an
/// aggregate's one output batch.
fn run_agg_pull(
  entry : @catalog.TableEntry,
  launch : Launch,
  stats : Array[(String, Int64)],
) -> SelectResult raise @types.SqlError {
  let bq = launch.bq
  let pull = agg_pull(bq, launch.plan, entry)
  let seq : BatchSeq = {
    next: fn() -> @types.DataBatch? raise @types.SqlError { pull.next() },
  }
  let grouped = aggregate_seq(seq, bq.group_exprs, bq.group_types, bq.aggs)
  let grouped = match bq.having {
    Some(h) => compact(grouped, eval_mask(h, grouped))
    None => grouped
  }
  stats.push(("scan \{launch.schemas[0].table}", pull.scanned))
  stats.push(("aggregate", grouped.row_count().to_int64()))
  let projected = project(grouped, bq.out_exprs, bq.out_types)
  let batch = order_limit(projected, [], bq.limit, bq.offset)
  stats.push(("result", batch.row_count().to_int64()))
  { names: bq.names, types: bq.out_types, batch, }
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
/// - Every other shape (a join, an aggregate, ORDER BY, DISTINCT, a window
///   function, a derived table, a set operation) must see all rows first, so it
///   is executed eagerly here and `next` yields that result as one batch. The
///   rows are the ones `execute` returns for the same query. An aggregate folds
///   those rows as they arrive rather than collecting them, so it is the answer
///   that is one batch, not the input array.
///
/// The lifecycle is short enough to state whole:
///
/// - Exhaustion: `next` returns `None` at the end and keeps returning `None`;
///   there is no second end and no reset.
/// - Early stop: `close` stops the pull, is idempotent, is safe before the
///   first `next`, and leaves `next` returning `None`.
/// - Failure: a pull that raises ends the stream, so a retry after an error
///   reports the end rather than resuming a scan whose state is unknown.
/// - Cleanup: dropping the stream releases the scan cursor. A stream owns no
///   spill files — a shape that needs a memory budget is materialized before
///   the stream is handed out — so there is nothing else to release, and a
///   consumer that vanishes costs nothing but the cursor. `catalog.BatchStream`
///   gains no `close` method for this: exhaustion is its whole protocol, and
///   adding one would break every implementation outside this module.
pub struct ResultStream {
  priv names : Array[String]
  priv types : Array[@types.DataType]
  priv pull : StreamPull
  priv mut done : Bool
}

///|
priv enum StreamPull {
  Scanned(ScanPull)
  Materialized(@types.DataBatch?)
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
  }
}

///|
/// Stop the pull. Idempotent, and early: a caller that has what it needs says
/// so instead of draining the scan.
pub fn ResultStream::close(self : ResultStream) -> Unit {
  self.done = true
}
