///|
/// Entry point for the `moonlake` CLI.
/// Run with `moon run cmd/main` from the project root.
fn main {
  let args = @env.args()
  if args.contains("--version") {
    println("moonlake \{@moonlake.version()}")
    return
  }
  if args.length() > 1 && args[1] == "exec" {
    exec_command(args)
    return
  }
  println(usage())
}

///|
fn exec_command(args : Array[String]) -> Unit {
  // expected shape: exec (--csv <path> | --parquet <path> | --date-col <c>)* <sql words...>
  let paths : Array[(String, String)] = [] // (kind, path)
  let date_cols : Array[String] = []
  let mut i = 2
  let n = args.length()
  let mut reading = true
  while reading && i + 1 < n {
    if args[i] == "--csv" {
      paths.push(("csv", args[i + 1]))
      i += 2
    } else if args[i] == "--parquet" {
      paths.push(("parquet", args[i + 1]))
      i += 2
    } else if args[i] == "--date-col" {
      date_cols.push(args[i + 1])
      i += 2
    } else {
      reading = false
    }
  }
  if paths.length() == 0 || i >= n {
    println(exec_usage())
    return
  }
  let sb = StringBuilder()
  for j in i..<n {
    if j > i {
      sb.write_char(' ')
    }
    sb.write_string(args[j])
  }
  let sql = sb.to_string()
  let cat = @catalog.Catalog::new()
  for pair in paths {
    let entry = match pair.0 {
      "parquet" =>
        @pq.scan_file(pair.1, table_stem(pair.1), date_cols) catch {
          err => {
            println(err.to_string())
            return
          }
        }
      _ =>
        @csv.scan_file(pair.1, table_stem(pair.1)) catch {
          err => {
            println(err.to_string())
            return
          }
        }
    }
    cat.register(entry)
  }
  let result = @moonlake.execute(sql, cat) catch {
    err => {
      println(err.to_string())
      return
    }
  }
  // pipe-friendly output: header row, then '|' separated values
  println(join_names(result.names()))
  for r in 0..<result.row_count() {
    println(join_row(result, r))
  }
}

///|
fn join_names(names : Array[String]) -> String {
  let sb = StringBuilder()
  for i, name in names {
    if i > 0 {
      sb.write_char('|')
    }
    sb.write_string(name)
  }
  sb.to_string()
}

///|
fn join_row(result : @engine.SelectResult, r : Int) -> String {
  let sb = StringBuilder()
  for c in 0..<result.names().length() {
    if c > 0 {
      sb.write_char('|')
    }
    sb.write_string(result.get(r, c).to_string())
  }
  sb.to_string()
}

///|
/// File stem: strip directories and a trailing ".csv" or ".parquet".
fn table_stem(path : String) -> String {
  let mut start = 0
  for i, ch in path {
    if ch == '/' {
      start = i + 1
    }
  }
  let base = path[start:].to_owned()
  for suffix in [".csv", ".parquet"] {
    if base.length() > suffix.length() && base.has_suffix(suffix) {
      return base[:base.length() - suffix.length()].to_owned()
    }
  }
  base
}

///|
fn exec_usage() -> String {
  (
    #|usage: moonlake exec (--csv <file> | --parquet <file> | --date-col <c>)+ <sql>
    #|
    #|CSV: first row is the header, types inferred. Parquet: DATE columns
    #|are declared with --date-col (epoch-day int32). File stems become
    #|table names; pass one --csv/--parquet per joined table.
    #|Example:
    #|  moonlake exec --csv lineitem.csv \
    #|    "SELECT sum(x) AS s FROM lineitem WHERE x > 1"
  )
}

///|
fn usage() -> String {
  (
    #|moonlake - embeddable analytical query engine for MoonBit
    #|
    #|Usage: moonlake [options] [command]
    #|
    #|Commands:
    #|  exec --csv <file.csv> <sql>   Run a SELECT over a CSV file
    #|
    #|Options:
    #|  --version   Print version and exit
    #|  --help      Print this help and exit
    #|
    #|The engine is under active development.
  )
}

///|
test {
  assert_true(usage().contains("moonlake"))
  assert_eq(table_stem("lineitem.csv"), "lineitem")
  assert_eq(table_stem("/tmp/data/lineitem.csv"), "lineitem")
  assert_eq(table_stem("plain.tsv"), "plain.tsv")
}
