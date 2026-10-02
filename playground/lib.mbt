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
/// Register Parquet bytes as table `table_name` and run `sql`.
/// `date_cols` is a comma-separated list of column names carrying
/// epoch-day int32 DATE semantics (the parquet reader exposes no
/// logical-type surface). Returns a JSON array string or
/// {"error": "..."}.
pub fn run_parquet(
  binary : String,
  table_name : String,
  date_cols : String,
  sql : String,
) -> String {
  let bytes = bytes_of_binary_string(binary)
  let cols : Array[String] = []
  for part in date_cols.split(",") {
    let name = part.trim().to_owned()
    if name != "" {
      cols.push(name)
    }
  }
  let cat = @catalog.Catalog::new()
  let entry = @pq.scan_bytes(bytes, table_name, cols) catch {
    e => return error_json(e.to_string())
  }
  cat.register(entry)
  let result = @moonlake.execute(sql, cat) catch {
    e => return error_json(e.to_string())
  }
  result.to_json()
}

///|
/// Undo the JS-side latin1 binary string: one code unit per byte.
fn bytes_of_binary_string(s : String) -> Bytes {
  let units = s.code_units()
  Bytes::makei(units.length(), fn(i) { units[i].to_int().to_byte() })
}

///|
/// Engine version, for the page footer.
pub fn version() -> String {
  @moonlake.version()
}
