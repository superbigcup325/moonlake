// moonlake - embeddable analytical query engine for MoonBit.
// Root package: engine facade. Sub-packages arrive with the v1 milestones.

///|
/// Version of the `superbigcup325/moonlake` module, kept in sync with `moon.mod`.
pub const VERSION : String = "0.1.0"

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
