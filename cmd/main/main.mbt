// The executable: turn argv into a catalog plus one query and dispatch to
// `write` or `exec`. The pieces it leans on live next door -- spill_dir.mbt for
// the run directory, glob.mbt for `--csv` expansion, usage.mbt for the texts.

///|
/// `--csv` globs expand to their matches; several matches scan into ONE table
/// named after the pattern (partitioned-dataset shape). `--parquet` stays
/// single-file. Each group is (table name, kind, files).
fn build_groups(
  paths : Array[(String, String)],
) -> Array[(String, String, Array[String])] raise {
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
  groups
}

///|
/// Register every input as a table. A misspelled `--date-col` would otherwise
/// be a silent no-op and only surface later as a confusing int32-vs-date type
/// mismatch, so it is checked against the registered schemas.
fn register_inputs(
  groups : Array[(String, String, Array[String])],
  date_cols : Array[String],
) -> @catalog.Catalog raise {
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
  cat
}

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
  if args.length() > 1 && args[1] == "write" {
    write_command(args)
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
/// `write`: register the inputs and write one table back out as Parquet.
/// This is the writer's only way out of the library. Without it a round trip
/// cannot be scripted, and a round trip that is not scripted cannot be checked
/// against another reader.
fn write_command(args : Array[String]) -> Unit raise {
  let paths : Array[(String, String)] = []
  let date_cols : Array[String] = []
  let mut out : String? = None
  let mut table : String? = None
  let mut codec = @pq.ParquetCodec::Raw
  let mut i = 2
  let n = args.length()
  while i < n {
    if args[i] == "--csv" && i + 1 < n {
      paths.push(("csv", args[i + 1]))
      i += 2
    } else if args[i] == "--parquet" && i + 1 < n {
      paths.push(("parquet", args[i + 1]))
      i += 2
    } else if args[i] == "--date-col" && i + 1 < n {
      date_cols.push(args[i + 1])
      i += 2
    } else if args[i] == "--out" && i + 1 < n {
      out = Some(args[i + 1])
      i += 2
    } else if args[i] == "--table" && i + 1 < n {
      table = Some(args[i + 1])
      i += 2
    } else if args[i] == "--snappy" {
      codec = @pq.ParquetCodec::Snappy
      i += 1
    } else {
      raise cli_fail(write_usage())
    }
  }
  let out = match out {
    Some(o) => o
    None => raise cli_fail(write_usage())
  }
  if paths.length() == 0 {
    raise cli_fail(write_usage())
  }
  let cat = register_inputs(build_groups(paths), date_cols)
  let entry = match table {
    Some(name) =>
      match cat.lookup(name) {
        Some(e) => e
        None => raise cli_fail("no table named \"\{name}\" is registered")
      }
    None => {
      let mut only : @catalog.TableEntry? = None
      let mut count = 0
      for _, e in cat.tables {
        count += 1
        if only is None {
          only = Some(e)
        }
      }
      if count != 1 {
        raise cli_fail(
          "--table <name> is required when more than one table is registered (\{count} here)",
        )
      }
      match only {
        Some(e) => e
        None => raise cli_fail(write_usage())
      }
    }
  }
  @pq.write_file_with(out, entry, codec) catch {
    err => raise cli_fail(err.to_string())
  }
  println("wrote \{out}")
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
  let mut memory : Int32 = 0
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
  let groups = build_groups(paths)
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
  let cat = register_inputs(groups, date_cols)
  if explain || analyze {
    let rendered = if analyze {
      analyze_query(sql, cat, memory, spill_dir) catch {
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
/// The one scope every budgeted query runs inside: take a spill directory,
/// open the store in it, run `body` under those options, and remove the
/// directory again on both exit paths.
///
/// The error path is the reason this exists. A query that spills and then
/// fails must not leave its run files behind, and that purge is easy to leave
/// out of a second copy of this skeleton -- which is what the two commands below
/// used to be.
fn[T] with_spill_run(
  spill_dir : String?,
  memory : Int32,
  body : (@engine.ExecOptions) -> T raise @types.SqlError,
) -> T raise @types.SqlError {
  let run = spill_run_dir(spill_dir)
  let fs = @spill.FsStore::new(run.dir) catch {
    err => {
      purge_spill_run(run)
      raise cli_fail(err.to_string())
    }
  }
  errdefer purge_spill_run(run)
  let out = body({ budget: memory, spill: Some(fs.store()), })
  purge_spill_run(run)
  out
}

///|
/// ANALYZE under the same memory options a real run would use: it
/// executes the query, so the spill counters it reports must come from
/// the budget the caller asked for (an in-memory analyze can never show
/// a spill).
fn analyze_query(
  sql : String,
  cat : @catalog.Catalog,
  memory : Int32,
  spill_dir : String?,
) -> String raise @types.SqlError {
  if memory <= 0 {
    return @engine.explain_analyze(sql, cat)
  }
  with_spill_run(spill_dir, memory, opts => {
    @engine.explain_analyze_with(sql, cat, opts)
  })
}

///|
/// Run the query under the memory options: a positive budget lets the
/// blocking operators (ORDER BY, grace join, grace aggregation) spill into a
/// per-run directory under `--spill-dir` or TMPDIR, which `with_spill_run`
/// removes once the query ends, on both the success and the error path.
fn run_query(
  sql : String,
  cat : @catalog.Catalog,
  memory : Int32,
  spill_dir : String?,
) -> @engine.SelectResult raise @types.SqlError {
  if memory <= 0 {
    return @moonlake.execute(sql, cat)
  }
  with_spill_run(spill_dir, memory, opts => {
    @moonlake.execute_with(sql, cat, opts)
  })
}

///|
/// Bytes with an optional K/M/G suffix (case-insensitive).
fn parse_memory(text : String) -> Int32 raise @types.SqlError {
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
fn join_row(result : @engine.SelectResult, r : Int32) -> String {
  let sb = StringBuilder()
  for c in 0..<result.names().length() {
    if c > 0 {
      sb.write_char('|')
    }
    sb.write_string(result.get(r, c).to_string())
  }
  sb.to_string()
}
