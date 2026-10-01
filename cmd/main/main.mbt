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
  // expected shape: exec --csv <path> <sql words...>
  let mut csv_path = ""
  let mut i = 2
  let n = args.length()
  while i < n {
    if args[i] == "--csv" && i + 1 < n {
      csv_path = args[i + 1]
      i += 2
    } else {
      break
    }
  }
  if csv_path == "" || i >= n {
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
  let entry = @csv.scan_file(csv_path, table_stem(csv_path)) catch {
    err => {
      println(err.to_string())
      return
    }
  }
  let cat = @catalog.Catalog::new()
  cat.register(entry)
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
/// File stem: strip directories and a trailing ".csv".
fn table_stem(path : String) -> String {
  let mut start = 0
  for i, ch in path {
    if ch == '/' {
      start = i + 1
    }
  }
  let base = path[start:].to_owned()
  let suffix = ".csv"
  if base.length() > suffix.length() && base.has_suffix(suffix) {
    return base[:base.length() - suffix.length()].to_owned()
  }
  base
}

///|
fn exec_usage() -> String {
  (
    #|usage: moonlake exec --csv <file.csv> <sql>
    #|
    #|The first CSV row is the header; column types are inferred.
    #|Example:
    #|  moonlake exec --csv lineitem.csv "SELECT sum(x) AS s FROM lineitem WHERE x > 1"
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
