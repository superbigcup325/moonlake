// Browser bridge: the whole engine, compiled to wasm-gc, callable from plain
// JavaScript.
//
// The bridge keeps one session — a catalog — alive between calls, so the page
// can register several files, list them, drop one and ask for a plan without
// re-uploading. Every entry point returns a JSON string: `""` or an object for
// the registering calls, an array of row objects for `query`, and
// `{"error": "…"}` for anything that fails (the page surfaces that verbatim).
//
// Exported to JS via the `link.wasm.exports` entry in moon.pkg.

///|
let session : @ref.Ref[@catalog.Catalog] = @ref.Ref(@catalog.Catalog::new())

///|
/// The engine version, shown in the page's status line.
pub fn version() -> String {
  @moonlake.version()
}

///|
/// Start a fresh session: drop every registered table.
pub fn reset() -> Unit {
  session.val = @catalog.Catalog::new()
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
/// A name already in use is an error rather than a silent replacement: the
/// page shows the table list, so a rename or a drop is visible there, and
/// "the second upload quietly replaced the first" is not.
fn check_free(name : String) -> String {
  if session.val.lookup(name) is Some(_) {
    return error_json(
      "table \"\{name}\" is already registered; drop it first if you meant to replace it",
    )
  }
  ""
}

///|
/// Register CSV text as table `name`. Returns `""` or `{"error": …}`.
pub fn add_csv(name : String, content : String) -> String {
  let busy = check_free(name)
  if busy != "" {
    return busy
  }
  let entry = @csv.scan_string(content, name) catch {
    e => return error_json(e.to_string())
  }
  session.val.register(entry)
  ""
}

///|
/// Register Parquet bytes as table `name`. `date_cols` is a comma-separated
/// list of columns carrying epoch-day INT32 DATE semantics for files without
/// the standard annotation; an annotated file needs nothing here.
pub fn add_parquet(
  name : String,
  binary : String,
  date_cols : String,
) -> String {
  let busy = check_free(name)
  if busy != "" {
    return busy
  }
  let cols : Array[String] = []
  for part in date_cols.split(",") {
    let trimmed = part.trim().to_owned()
    if trimmed != "" {
      cols.push(trimmed)
    }
  }
  let entry = @pq.scan_bytes(bytes_of_binary_string(binary), name, cols) catch {
    e => return error_json(e.to_string())
  }
  session.val.register(entry)
  ""
}

///|
/// Drop one table. Returns `""` or `{"error": …}`.
pub fn drop_table(name : String) -> String {
  if session.val.lookup(name) is None {
    return error_json("no table named \"\{name}\"")
  }
  session.val.drop(name)
  ""
}

///|
fn dtype_name(dt : @types.DataType) -> String {
  match dt {
    Int32 => "int32"
    Int64 => "int64"
    Float64 => "double"
    Str => "string"
    Bool => "boolean"
    Date => "date"
  }
}

///|
/// The registered tables and their columns, in registration order:
/// `[{"name":"lineitem","columns":[{"name":"l_orderkey","type":"int32"}]}]`.
pub fn tables() -> String {
  let sb = StringBuilder()
  sb.write_char('[')
  let mut first = true
  for name, entry in session.val.tables {
    if !first {
      sb.write_char(',')
    }
    first = false
    sb.write_string("{\"name\":\"")
    sb.write_string(json_escape(name))
    sb.write_string("\",\"columns\":[")
    for i, column in entry.schema.columns {
      if i > 0 {
        sb.write_char(',')
      }
      sb.write_string("{\"name\":\"")
      sb.write_string(json_escape(column.name))
      sb.write_string("\",\"type\":\"")
      sb.write_string(dtype_name(column.dtype))
      sb.write_string("\"}")
    }
    sb.write_string("]}")
  }
  sb.write_char(']')
  sb.to_string()
}

///|
/// Run a query against the session. Returns the rows as a JSON array, or
/// `{"error": …}`.
pub fn query(sql : String) -> String {
  let result = @moonlake.execute(sql, session.val) catch {
    e => return error_json(e.to_string())
  }
  result.to_json()
}

///|
/// The physical plan for `sql`, as text, including the scan row counts and
/// row-group counts the planner knows. Returns `{"error": …}` when it does not
/// bind.
pub fn plan(sql : String) -> String {
  @engine.explain(sql, session.val) catch {
    e => return error_json(e.to_string())
  }
}

///|
fn json_escape(s : String) -> String {
  let sb = StringBuilder()
  for ch in s {
    match ch {
      '"' => sb.write_string("\\\"")
      '\\' => sb.write_string("\\\\")
      '\n' => sb.write_string("\\n")
      _ => sb.write_char(ch)
    }
  }
  sb.to_string()
}

///|
/// One char per byte: the page builds this string with `String.fromCharCode`,
/// and letting the browser decode the buffer as windows-1252 would remap
/// 0x80-0x9F and corrupt the block.
fn bytes_of_binary_string(binary : String) -> Bytes {
  let out = Buffer()
  for ch in binary {
    out.write_byte(ch.to_int().to_byte())
  }
  out.to_bytes()
}
