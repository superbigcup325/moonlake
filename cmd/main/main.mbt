///|
/// Entry point for the `moonlake` CLI.
/// Run with `moon run cmd/main` from the project root.
fn main raise {
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
fn exec_command(args : Array[String]) -> Unit raise {
  // expected shape: exec [flags] (--csv <path> | --parquet <path> | --date-col <c>)* <sql words...>
  let paths : Array[(String, String)] = [] // (kind, path)
  let date_cols : Array[String] = []
  let mut explain = false
  let mut json = false
  let mut i = 2
  let n = args.length()
  let mut reading = true
  while reading && i < n {
    if args[i] == "--csv" && i + 1 < n {
      paths.push(("csv", args[i + 1]))
      i += 2
    } else if args[i] == "--parquet" && i + 1 < n {
      paths.push(("parquet", args[i + 1]))
      i += 2
    } else if args[i] == "--date-col" && i + 1 < n {
      date_cols.push(args[i + 1])
      i += 2
    } else if args[i] == "--explain" {
      explain = true
      i += 1
    } else if args[i] == "--json" {
      json = true
      i += 1
    } else {
      reading = false
    }
  }
  if paths.length() == 0 || i >= n {
    raise cli_fail(exec_usage())
  }
  if n - i > 1 {
    // words after a quoted SQL would otherwise silently glue onto the
    // query and change its meaning (a stray word becomes a table alias)
    raise cli_fail(
      "sql must be one quoted argument, got \{n - i} words; wrap it: moonlake exec --csv t.csv \"SELECT ...\"",
    )
  }
  let sql = args[i]
  let cat = @catalog.Catalog::new()
  for pair in paths {
    let entry = match pair.0 {
      "parquet" =>
        @pq.scan_file(pair.1, table_stem(pair.1), date_cols) catch {
          err => raise cli_fail(err.to_string())
        }
      _ =>
        @csv.scan_file(pair.1, table_stem(pair.1)) catch {
          err => raise cli_fail(err.to_string())
        }
    }
    cat.register(entry)
  }
  // a misspelled --date-col would otherwise be a silent no-op and only
  // surface later as a confusing int32-vs-date type mismatch
  for dc in date_cols {
    let mut found = false
    for _, entry in cat.tables {
      for col in entry.schema.columns {
        if col.name == dc {
          found = true
        }
      }
    }
    if !found {
      raise cli_fail(
        "--date-col: no column named \"\{dc}\" in any scanned table",
      )
    }
  }
  if explain {
    println(
      @engine.explain(sql, cat) catch {
        err => raise cli_fail(err.to_string())
      },
    )
    return
  }
  let result = @moonlake.execute(sql, cat) catch {
    err => raise cli_fail(err.to_string())
  }
  if json {
    println(result.to_json())
  } else {
    // pipe-friendly output: header row, then '|' separated values
    println(join_names(result.names()))
    for r in 0..<result.row_count() {
      println(join_row(result, r))
    }
  }
}

///|
/// Report a fatal error and exit non-zero so shell pipelines can tell a
/// failed query from an empty result. The real message goes to stderr
/// and the process exits 1 via @sys.exit — a clean process exit, so no
/// abort stack trace follows the message. catch arms `raise` this error
/// to unwind to main.
fn cli_fail(msg : String) -> @types.SqlError {
  eprintln(msg)
  @sys.exit(1)
  abort("") // unreachable: exit terminates the process
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
    #|  exec (--csv <file> | --parquet <file> | --date-col <c])+ <sql>
    #|      Run a SELECT over CSV/Parquet files (one flag per table)
    #|
    #|    exec options:
    #|      --date-col <c>        declare a Parquet column as DATE (epoch-day)
    #|      --explain             print the physical plan instead of running
    #|      --json                emit the result as one JSON array line
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
