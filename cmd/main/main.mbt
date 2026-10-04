///|
/// Entry point for the `moonlake` CLI.
/// Run with `moon run cmd/main` from the project root.
fn main raise {
  let args = @env.args()
  if args.contains("--version") {
    println("moonlake \{@moonlake.version()}")
    return
  }
  if args.contains("--help") {
    println(usage())
    return
  }
  if args.length() > 1 && args[1] == "exec" {
    exec_command(args)
    return
  }
  // the classic first-commands slip: flags without the subcommand
  if args.length() > 1 && (args[1] == "--csv" || args[1] == "--parquet") {
    eprintln(
      "it looks like you passed data flags without a subcommand; e.g.\n  moonlake exec --csv t.csv --file q.sql\n  moonlake exec --csv t.csv \"SELECT ...\"",
    )
    @sys.exit(1)
  }
  println(usage())
}

///|
fn exec_command(args : Array[String]) -> Unit raise {
  // expected shape: exec [flags] (--csv <path> | --parquet <path> | --date-col <c>)* <sql words...>
  let paths : Array[(String, String)] = [] // (kind, path)
  let date_cols : Array[String] = []
  let mut explain = false
  let mut analyze = false
  let mut json = false
  let mut sql_file : String? = None
  let mut memory : Int = 0
  let mut spill_dir : String? = None
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
    } else if args[i] == "--analyze" {
      analyze = true
      i += 1
    } else if args[i] == "--json" {
      json = true
      i += 1
    } else if args[i] == "--memory" && i + 1 < n {
      memory = parse_memory(args[i + 1]) catch {
        msg => raise cli_fail(msg.to_string())
      }
      i += 2
    } else if args[i] == "--spill-dir" && i + 1 < n {
      spill_dir = Some(args[i + 1])
      i += 2
    } else if args[i] == "--file" && i + 1 < n {
      sql_file = Some(args[i + 1])
      i += 2
    } else {
      reading = false
    }
  }
  if paths.length() == 0 || (i >= n && sql_file is None) {
    raise cli_fail(exec_usage())
  }
  // --csv globs expand to their matches; several matches scan into ONE
  // table named after the pattern (partitioned-dataset shape).
  // --parquet stays single-file.
  let groups : Array[(String, String, Array[String])] = []
  for pair in paths {
    if pair.0 == "csv" && pair.1.contains("*") {
      let hits = expand_glob(pair.1)
      if hits.length() == 0 {
        raise cli_fail("the --csv pattern \{pair.1} matched no files")
      }
      let name = if hits.length() == 1 {
        table_stem(hits[0])
      } else {
        pattern_stem(pair.1)
      }
      groups.push((name, "csv", hits))
    } else {
      groups.push((table_stem(pair.1), pair.0, [pair.1]))
    }
  }
  if sql_file is Some(_) && i < n {
    raise cli_fail("pass the SQL either inline or via --file, not both")
  }
  if n - i > 1 {
    // words after a quoted SQL would otherwise silently glue onto the
    // query and change its meaning (a stray word becomes a table alias)
    raise cli_fail(
      "sql must be one quoted argument, got \{n - i} words; wrap it: moonlake exec --csv t.csv \"SELECT ...\"",
    )
  }
  let sql = match sql_file {
    Some(f) =>
      @fs.read_file_to_string(f) catch {
        _ => raise cli_fail("cannot read SQL file at \{f}")
      }
    None => args[i]
  }
  let cat = @catalog.Catalog::new()
  for (name, kind, files) in groups {
    let entry = match kind {
      "parquet" =>
        @pq.scan_file(files[0], name, date_cols) catch {
          err => raise cli_fail(err.to_string())
        }
      _ =>
        if files.length() > 1 {
          @csv.scan_files(files, name) catch {
            err => raise cli_fail(err.to_string())
          }
        } else {
          @csv.scan_file(files[0], name) catch {
            err => raise cli_fail(err.to_string())
          }
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
  if explain || analyze {
    let rendered = if analyze {
      @engine.explain_analyze(sql, cat) catch {
        err => raise cli_fail(err.to_string())
      }
    } else {
      @engine.explain(sql, cat) catch {
        err => raise cli_fail(err.to_string())
      }
    }
    println(rendered)
    return
  }
  let result = run_query(sql, cat, memory, spill_dir) catch {
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
/// Run the query under the memory options: a positive budget spills the
/// blocking ORDER BY to a per-run directory (default under TMPDIR).
/// The directory is removed best-effort once the query ends.
fn run_query(
  sql : String,
  cat : @catalog.Catalog,
  memory : Int,
  spill_dir : String?,
) -> @engine.SelectResult raise @types.SqlError {
  if memory <= 0 {
    return @moonlake.execute(sql, cat)
  }
  let dir = match spill_dir {
    Some(d) => d
    None => pick_spill_dir()
  }
  let fs = @spill.FsStore::new(dir) catch {
    err => raise cli_fail(err.to_string())
  }
  errdefer {
    let _ = @fs.remove_dir(dir) catch { _ => () }
  }
  let result = @moonlake.execute_with(sql, cat, {
    budget: memory,
    spill: Some(fs.store()),
  })
  let _ = @fs.remove_dir(dir) catch { _ => () }
  result
}

///|
/// A fresh per-run directory under TMPDIR (or /tmp): bump a suffix
/// until create_dir succeeds, so concurrent processes do not collide.
fn pick_spill_dir() -> String raise @types.SqlError {
  let base = match @env.get_env_var("TMPDIR") {
    Some(d) => d
    None => "/tmp"
  }
  let mut n = 0
  while n < 1000 {
    let dir = "\{base}/moonlake-spill-\{n}"
    if !@fs.path_exists(dir) {
      @fs.create_dir(dir) catch {
        @fs.IOError(_) => {
          n += 1
          continue
        }
      }
      return dir
    }
    n += 1
  }
  raise @types.SqlError::Execute("no free spill directory under \{base}")
}

///|
/// Bytes with an optional K/M/G suffix (case-insensitive).
fn parse_memory(text : String) -> Int raise @types.SqlError {
  if text.length() == 0 {
    raise @types.SqlError::Execute("--memory: empty value")
  }
  let last = text[text.length() - 1].to_int()
  let mult = match last {
    75 | 107 => Some(1024) // K / k
    77 | 109 => Some(1024 * 1024) // M / m
    71 | 103 => Some(1024 * 1024 * 1024) // G / g
    _ => None
  }
  let digits = match mult {
    Some(_) => text[:text.length() - 1].to_owned()
    None => text
  }
  let m = mult.unwrap_or(1)
  let mut v = 0
  for ch in digits {
    let d = ch.to_int() - 48
    if d < 0 || d > 9 {
      raise @types.SqlError::Execute(
        "--memory: expected <n>[K|M|G], got \"\{text}\"",
      )
    }
    v = v * 10 + d
  }
  v * m
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
/// Expand one --csv glob pattern into sorted file paths. Only a single
/// `*` (matching any run within one directory level) is supported;
/// directories are skipped.
fn expand_glob(pattern : String) -> Array[String] raise {
  let mut slash = -1
  for i, ch in pattern {
    if ch == '/' {
      slash = i
    }
  }
  let dir = if slash >= 0 { pattern[:slash + 1].to_owned() } else { "" }
  let pat = pattern[slash + 1:].to_owned()
  let entries = @fs.read_dir(if dir == "" { "." } else { dir }) catch {
    _ => raise cli_fail("cannot read directory at \{dir}")
  }
  let hits : Array[String] = []
  for name in entries {
    if glob_match(pat, name) && @fs.is_file(dir + name) {
      hits.push(dir + name)
    }
  }
  hits.sort()
  hits
}

///|
/// Classic single-star glob match: `*` spans any run of characters,
/// everything else compares literally.
fn glob_match(pattern : String, name : String) -> Bool {
  let ps : Array[Char] = []
  for ch in pattern {
    ps.push(ch)
  }
  let ns : Array[Char] = []
  for ch in name {
    ns.push(ch)
  }
  let mut pi = 0
  let mut ni = 0
  let mut star = -1
  let mut mark = 0
  while ni < ns.length() {
    if pi < ps.length() && (ps[pi] == '*' || ps[pi] == ns[ni]) {
      if ps[pi] == '*' {
        star = pi
        mark = ni
        pi += 1
      } else {
        pi += 1
        ni += 1
      }
    } else if star >= 0 {
      pi = star + 1
      mark += 1
      ni = mark
    } else {
      return false
    }
  }
  while pi < ps.length() && ps[pi] == '*' {
    pi += 1
  }
  pi == ps.length()
}

///|
/// Table name for a multi-file glob pattern: the basename with `*`
/// removed ("parts/part-*.csv" scans into table "part-.csv"? no —
/// into "part-", keeping the suffix strip of table_stem).
fn pattern_stem(pattern : String) -> String {
  let mut start = 0
  for i, ch in pattern {
    if ch == '/' {
      start = i + 1
    }
  }
  let base = pattern[start:].to_owned()
  let mut stem = ""
  for ch in base {
    if ch != '*' {
      stem = stem + ch.to_string()
    }
  }
  for suffix in [".csv", ".parquet"] {
    if stem.has_suffix(suffix) {
      stem = stem[:stem.length() - suffix.length()].to_owned()
    }
  }
  // "part-*.csv" -> "part": the star leaves a separator behind that
  // would force quoting in every query
  let mut end = stem.length()
  while end > 0 {
    let last = stem[end - 1]
    if last == '-' || last == '_' || last == '.' {
      end -= 1
    } else {
      break
    }
  }
  stem[:end].to_owned()
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
    #|usage: moonlake exec (--csv <file> | --parquet <file> | --date-col <c>)+ <sql | --file <q.sql>>
    #|
    #|CSV: first row is the header, types inferred. Parquet: DATE columns
    #|are declared with --date-col (epoch-day int32). File stems become
    #|table names; pass one --csv/--parquet per joined table. A --csv
    #|argument may carry one `*`: the matches scan into one table
    #|named by the pattern. The SQL is
    #|one quoted argument, or a file with --file (handy to skip shell
    #|quoting; a trailing semicolon is fine).
    #|Examples:
    #|  moonlake exec --csv lineitem.csv \
    #|    "SELECT sum(x) AS s FROM lineitem WHERE x > 1"
    #|  moonlake exec --csv lineitem.csv --file q6.sql
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
    #|      --analyze             run it: plan plus actual rows per stage
    #|      --json                emit the result as one JSON array line
    #|      --memory <n>[K|M|G]   budget for the blocking ORDER BY; beyond
    #|                            it runs spill to disk (external sort)
    #|      --spill-dir <dir>     where run files go (default: TMPDIR)
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
  // single-star glob matching
  assert_true(glob_match("part-*.csv", "part-001.csv"))
  assert_true(glob_match("*.csv", "anything.csv"))
  assert_true(glob_match("a*b.csv", "aXxYb.csv"))
  assert_false(glob_match("part-*.csv", "part-001.tsv"))
  assert_false(glob_match("part-*.csv", "xpart-001.csv"))
  assert_false(glob_match("a*b.csv", "abcsv"))
  // pattern stem: star removed, suffix stripped, separator trimmed
  assert_eq(pattern_stem("parts/part-*.csv"), "part")
  assert_eq(pattern_stem("data-*.csv"), "data") // trailing separator trimmed
}
