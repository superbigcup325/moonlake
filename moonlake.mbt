// moonlake - embeddable analytical query engine for MoonBit.
// Root package: engine facade. Sub-packages arrive with later releases.

///|
/// Version of the `superbigcup325/moonlake` module, kept in sync with `moon.mod`.
pub const VERSION : String = "0.6.0"

///|
/// Short human-readable description of the module.
pub const DESCRIPTION : String = "Embeddable analytical query engine for MoonBit"

///|
/// Returns the engine version string.
pub fn version() -> String {
  VERSION
}

///|
/// Parse, bind and execute a single SELECT over the catalog and return
/// the result as a columnar batch with output names.
pub fn execute(
  sql : String,
  catalog : @catalog.Catalog,
) -> @engine.SelectResult raise @types.SqlError {
  @engine.run_select(sql, catalog)
}

///|
/// Execute with explicit options: a memory budget turns the blocking
/// ORDER BY of non-aggregate queries into an external sort backed by
/// `opts.spill`. See `@engine.ExecOptions`.
pub fn execute_with(
  sql : String,
  catalog : @catalog.Catalog,
  opts : @engine.ExecOptions,
) -> @engine.SelectResult raise @types.SqlError {
  @engine.run_select_opts(sql, catalog, opts)
}

///|
/// Execute a SELECT and consume it as it runs, instead of collecting the whole
/// result first.
///
/// A single-table scan is pulled: the filter, the projection and an
/// OFFSET/LIMIT window run per batch, so a caller that wants the first few
/// rows reads only the batches those rows live in, and nothing accumulates
/// between the source and the caller. Every other shape — a join, ORDER BY,
/// DISTINCT, a window function, a derived table, a set operation — has to see
/// all rows before it can produce the first one, so it is executed eagerly and
/// `next` hands that result back as one batch. An aggregate is the case in
/// between: it must see every row too, but a single-table GROUP BY or a global
/// aggregate folds the scan's batches as they arrive, so it holds its group
/// state and not its input — its answer is still one batch. Both deliveries run
/// the same plan, so they agree on rows.
///
/// ```mbt nocheck
/// let s = @moonlake.stream("SELECT * FROM t LIMIT 3", cat)
/// while s.next() is Some(batch) {
///   inspect(batch.row_count())
/// }
/// ```
pub fn stream(
  sql : String,
  catalog : @catalog.Catalog,
) -> @engine.ResultStream raise @types.SqlError {
  @engine.run_select_stream(sql, catalog)
}

///|
/// `stream` under explicit options. A shape that needs the memory budget — a
/// join, a budgeted GROUP BY, an external sort — is materialized before this
/// returns, because a stream owns no spill files; `execute_with` is the right
/// call when the caller wants the budget to do the work and the result whole.
/// (A single-table aggregate that never spills is not one of those: a global
/// aggregate folds the scan under a budget too and hands back one batch.)
pub fn stream_with(
  sql : String,
  catalog : @catalog.Catalog,
  opts : @engine.ExecOptions,
) -> @engine.ResultStream raise @types.SqlError {
  @engine.run_select_stream_opts(sql, catalog, opts)
}
