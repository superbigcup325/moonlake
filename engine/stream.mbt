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
// WHERE may not travel). What streams today: scan, build filter, the deferred
// WHERE, projection and a LIMIT window. What does not, because it must see
// every row first: aggregation, a join, ORDER BY, and SELECT DISTINCT.

///|
/// The single-table LIMIT that can stop its scan, if this query is one: one
/// lazy table, nothing above the projection that needs every row, and a LIMIT.
///
/// A LIMIT over `select *` is the case this exists for: the scan used to
/// materialize the whole table and the window was cut from the result, which
/// cost one pass over every column to return ten rows.
fn streaming_limit_source(
  bq : BoundQuery,
  sources : Array[@catalog.TableEntry?],
) -> @catalog.TableEntry? {
  if bq.limit is None {
    return None
  }
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
/// Run a streamable LIMIT: pull one batch at a time, keep the window, and stop
/// as soon as the window is full.
fn stream_limit(
  bq : BoundQuery,
  plan : PrunePlan,
  entry : @catalog.TableEntry,
  table_name : String,
  stats : Array[(String, Int64)],
) -> SelectResult raise @types.SqlError {
  let limit = match bq.limit {
    Some(n) => n
    None => 0
  }
  let offset = match bq.offset {
    Some(n) => n
    None => 0
  }
  // In Int64: offset and limit are Int32 each and their sum need not fit
  let window = offset.to_int64() + limit.to_int64()
  let request = scan_request_of(bq, plan.table_cols[0], 0)
  let build_filter = scan_filter_of(bq, 0)
  let stream = entry.stream(request)
  let chunks : Array[@types.DataBatch] = []
  let mut scanned = 0L
  let mut got = 0L
  while got < window {
    match stream.next() {
      None => break
      Some(batch) => {
        let kept = match build_filter {
          Some(p) => compact(batch, eval_mask(p, batch))
          None => batch
        }
        scanned += kept.row_count().to_int64()
        if kept.row_count() > 0 {
          let rows = filter_batches([kept], bq.deferred)
          if rows.length() > 0 && rows[0].row_count() > 0 {
            let projected = project(rows[0], bq.out_exprs, bq.out_types)
            got += projected.row_count().to_int64()
            chunks.push(projected)
          }
        }
      }
    }
  }
  stats.push(("scan \{table_name}", scanned))
  let all = concat_batches(chunks, bq.out_types)
  let batch = order_limit(all, [], bq.limit, bq.offset)
  if stats.length() > 0 {
    stats.push(("result", batch.row_count().to_int64()))
  }
  { names: bq.names, types: bq.out_types, batch, }
}
