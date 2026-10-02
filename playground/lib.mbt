// Browser bridge: the whole engine, compiled to wasm-gc, callable from
// plain JavaScript. One entry point: hand it CSV text and a query, get
// a JSON array string (or {"error": ...}) back. No imports, no
// postMessage plumbing — the returned String is a JS string.
//
// Exported to JS via the `link.wasm.exports` entry in moon.pkg.

///|
/// Register `csv_content` as table `table_name` and run `sql`.
/// Returns a JSON array string of row objects, or {"error": "..."}.
pub fn run(csv_content : String, table_name : String, sql : String) -> String {
  let cat = @catalog.Catalog::new()
  let entry = @csv.scan_string(csv_content, table_name) catch {
    e => return error_json(e.to_string())
  }
  cat.register(entry)
  let result = @moonlake.execute(sql, cat) catch {
    e => return error_json(e.to_string())
  }
  result.to_json()
}

///|
fn error_json(message : String) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"error\":\"")
  for ch in message {
    match ch {
      '"' => sb.write_string("\\\"")
      '\\' => sb.write_string("\\\\")
      '\n' => sb.write_string("\\n")
      '\r' => sb.write_string("\\r")
      '\t' => sb.write_string("\\t")
      _ => sb.write_char(ch)
    }
  }
  sb.write_string("\"}")
  sb.to_string()
}

///|
/// Engine version, for the page footer.
pub fn version() -> String {
  @moonlake.version()
}
