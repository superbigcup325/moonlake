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
        let stem = pattern_stem(pair.1)
        // a bare "*.csv" keeps no name once the star and suffix go: the
        // group would register table "" and every query would quote it
        if stem == "" {
          raise cli_fail(
            "the --csv pattern \{pair.1} matched \{hits.length()} files and leaves no table name; give them a shared name prefix (part-*.csv) so they scan into a named table",
          )
        }
        stem
      }
      groups.push((name, "csv", hits))
    } else {
      groups.push((table_stem(pair.1), pair.0, [pair.1]))
    }
  }
  groups
}

///|
/// Lexical path identity, for refusing a `--out` that is one of the inputs:
/// "./t.csv", "t.csv" and "d/../t.csv" name the same file. This is not a
/// filesystem identity check (symlinks and hard links are not followed); it
/// covers the slip it exists for.
fn same_path(a : String, b : String) -> Bool {
  normalize_path(a) == normalize_path(b)
}

///|
fn normalize_path(path : String) -> String {
  let parts : Array[String] = []
  for view in path.split("/") {
    let seg = view.to_owned()
    if seg == "" || seg == "." {
      continue
    }
    if seg == ".." && parts.length() > 0 && parts[parts.length() - 1] != ".." {
      let _ = parts.pop()
      continue
    }
    parts.push(seg)
  }
  let joined = parts.join("/")
  if path.has_prefix("/") {
    "/" + joined
  } else {
    joined
  }
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
  // --date-col has one job: type an unannotated integer epoch-day PARQUET
  // column as DATE. CSV columns get their type from inference, so with no
  // Parquet input the flag can only be a silent no-op
  if date_cols.length() > 0 {
    let mut parquet = false
    for (_, kind, _) in groups {
      if kind == "parquet" {
        parquet = true
      }
    }
    if !parquet {
      raise cli_fail(
        "--date-col types --parquet columns only; a CSV column gets its type from inference, so this flag would do nothing",
      )
    }
  }
  // a second file with the same stem must not silently replace the first:
  // `--csv a/data.csv --csv b/data.csv` used to register both under "data"
  // and answer from the last one only
  let seen : Array[(String, String)] = []
  for (name, kind, files) in groups {
    for prev in seen {
      if prev.0 == name {
        raise cli_fail(
          "two inputs register as table \"\{name}\" (\{prev.1} and \{files[0]}); rename one file or load them into separate tables",
        )
      }
    }
    seen.push((name, files[0]))
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
/// argv as the subcommands expect it: args[0] is the launcher, args[1] the
/// subcommand, everything after it that subcommand's own arguments. js runs
/// the CLI through `node <script>.js`, which prepends the script path as a
/// second launcher entry (native and wasm-gc prepend only the executable), so
/// that entry is dropped here instead of shifting every index in the two
/// commands — before, every js invocation fell through to the usage text.
fn normalize_args(args : Array[String]) -> Array[String] {
  if args.length() < 2 || !args[1].has_suffix(".js") {
    return args
  }
  let out : Array[String] = [args[0]]
  for i in 2..<args.length() {
    out.push(args[i])
  }
  out
}

///|
/// Entry point for the `moonlake` CLI.
/// Run with `moon run cmd/main` from the project root.
fn main raise {
  let args = normalize_args(@env.args())
  if args.contains("--version") {
    println("moonlake \{@moonlake.version()}")
    return
  }
  if args.contains("--help") {
    println(usage())
    return
  }
  // A failure inside a command must leave through the same door as a usage
  // error: message on stderr, exit 1. Reading the inputs raises before the
  // query runs (a CSV whose rows do not parse), and an uncaught raise ends the
  // process with a panic trace and exit 134, which a shell pipeline cannot
  // tell apart from a crash.
  if args.length() > 1 && args[1] == "exec" {
    exec_command(args) catch {
      e => raise cli_fail(e.to_string())
    }
    return
  }
  if args.length() > 1 && args[1] == "write" {
    write_command(args) catch {
      e => raise cli_fail(e.to_string())
    }
    return
  }
  // the classic first-commands slip: options without the subcommand
  if args.length() > 1 && args[1].has_prefix("--") {
    eprintln(
      "it looks like you passed options without a subcommand; e.g.\n  moonlake exec --csv t.csv --file q.sql\n  moonlake exec --csv t.csv \"SELECT ...\"",
    )
    @sys.exit(1)
  }
  // a misspelled command must not print the usage text and exit 0: a script
  // that pipes the "result" of a typo would read the usage as data
  if args.length() > 1 {
    eprintln("unknown command \"\{args[1]}\"; try \"moonlake --help\"")
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
  // the writer streams into a temporary name and renames it over the target,
  // so an --out that is also an input would replace the source file with the
  // converted one: `write --csv t.csv --out t.csv` is always a slip
  let groups = build_groups(paths)
  for (_, _, files) in groups {
    for f in files {
      if same_path(f, out) {
        raise cli_fail(
          "--out \{out} is also the input \{f}; write somewhere else (the output would replace the source file)",
        )
      }
    }
  }
  let cat = register_inputs(groups, date_cols)
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
  let mut mem = false
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
    } else if args[i] == "--mem" {
      mem = true
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
  // no input files is fine: `exec "SELECT 1 + 1"` runs against an empty
  // catalog, which is what a quick expression check needs
  if i >= n && sql_file is None {
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
  if mem {
    let rendered = mem_query(sql, cat, memory, spill_dir) catch {
      err => raise cli_fail(err.to_string())
    }
    println(rendered)
    return
  }
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
  // Rows are printed as their batches arrive, so a large scan never becomes a
  // string in memory: what is held is one batch, not one result. A failure
  // after the first batch leaves what was already printed on stdout, then the
  // error on stderr and exit 1 — a pipeline that checks the exit status sees
  // the failure, and one that does not still gets the rows it could have had.
  let stream = run_query_stream(sql, cat, memory, spill_dir) catch {
    err => raise cli_fail(err.to_string())
  }
  if json {
    // One JSON array, whose rows arrive a batch at a time. A batch is printed
    // as its own line only once there is a following one, so the document
    // stays one line per batch and a single-batch result is byte-identical to
    // the whole-result encoding.
    let writer = @engine.JsonRow::new(stream.names())
    let mut pending : String? = None
    let mut printed = false
    while stream.next() is Some(batch) {
      match pending {
        Some(prev) => {
          // the opening bracket belongs to whichever line comes first
          let prefix = if printed { "" } else { "[" }
          println(prefix + prev + ",")
          printed = true
        }
        None => ()
      }
      pending = Some(writer.batch(batch))
    }
    let head = if printed { "" } else { "[" }
    match pending {
      Some(last) => println(head + last + "]")
      None => println(if printed { "]" } else { "[]" })
    }
  } else {
    // pipe-friendly output: header row, then '|' separated values
    println(join_names(stream.names()))
    while stream.next() is Some(batch) {
      for r in 0..<batch.row_count() {
        println(join_batch_row(batch, r))
      }
    }
  }
  stream.close()
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
  // a stage report is worth durations only when the caller asked for one, and
  // only a platform with a monotonic clock can supply them
  @engine.set_stage_clock(stage_clock())
  defer @engine.set_stage_clock(None)
  if memory <= 0 {
    return @engine.explain_analyze(sql, cat)
  }
  with_spill_run(spill_dir, memory, opts => {
    @engine.explain_analyze_with(sql, cat, opts)
  })
}

///|
/// A structure census under the same memory options a real run would use: a
/// budgeted census has to see the same store and budget as the query it stands
/// in for, or it would measure a different plan.
fn mem_query(
  sql : String,
  cat : @catalog.Catalog,
  memory : Int32,
  spill_dir : String?,
) -> String raise @types.SqlError {
  if memory <= 0 {
    return @engine.mem_report_with(
      sql,
      cat,
      @engine.ExecOptions::in_memory(),
      sample=Some({ read: rss_sample, }),
    )
  }
  with_spill_run(spill_dir, memory, opts => {
    @engine.mem_report_with(sql, cat, opts, sample=Some({ read: rss_sample, }))
  })
}

///|
/// Run the query under the memory options, handing the rows back as they come:
/// a positive budget lets the blocking operators (ORDER BY, grace join, grace
/// aggregation) spill into a per-run directory under `--spill-dir` or TMPDIR,
/// which `with_spill_run` removes once the query ends, on both the success and
/// the error path.
///
/// A query that can be pulled (a single-table scan) spills nothing, and a query
/// that cannot is materialized inside `stream_with` before the stream is
/// returned, so the purge above never removes a file the stream still needs.
fn run_query_stream(
  sql : String,
  cat : @catalog.Catalog,
  memory : Int32,
  spill_dir : String?,
) -> @engine.ResultStream raise @types.SqlError {
  if memory <= 0 {
    return @moonlake.stream(sql, cat)
  }
  with_spill_run(spill_dir, memory, opts => {
    @moonlake.stream_with(sql, cat, opts)
  })
}

///|
/// Bytes with an optional K/M/G suffix (case-insensitive). The budget is an
/// Int32, so a value past 2147483647 is an error: it used to wrap, and `4G`
/// wrapped to 0, which means "no budget at all" — a request for a 4 GiB cap
/// silently ran unbounded.
fn parse_memory(text : String) -> Int32 raise @types.SqlError {
  if text.length() == 0 {
    raise @types.SqlError::Execute("--memory: empty value")
  }
  let last = text[text.length() - 1].to_int()
  let mult : Int64 = match last {
    75 | 107 => 1024L // K / k
    77 | 109 => 1048576L // M / m
    71 | 103 => 1073741824L // G / g
    _ => 1L
  }
  let digits = match mult {
    1L => text
    _ => text[:text.length() - 1].to_owned()
  }
  if digits.length() == 0 {
    raise @types.SqlError::Execute(
      "--memory: expected <n>[K|M|G], got \"\{text}\"",
    )
  }
  let mut v = 0L
  for ch in digits {
    let d = ch.to_int() - 48
    if d < 0 || d > 9 {
      raise @types.SqlError::Execute(
        "--memory: expected <n>[K|M|G], got \"\{text}\"",
      )
    }
    v = v * 10L + d.to_int64()
    if v > 2147483647L {
      raise @types.SqlError::Execute(
        "--memory: \{text} is larger than 2147483647 bytes, the largest budget",
      )
    }
  }
  let bytes = v * mult
  if bytes > 2147483647L {
    raise @types.SqlError::Execute(
      "--memory: \{text} is larger than 2147483647 bytes, the largest budget",
    )
  }
  bytes.to_int()
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
fn join_batch_row(batch : @types.DataBatch, r : Int32) -> String {
  let sb = StringBuilder()
  let cols = batch.columns()
  for c in 0..<cols.length() {
    if c > 0 {
      sb.write_char('|')
    }
    sb.write_string(cols[c].get(r).to_string())
  }
  sb.to_string()
}

///|
/// `parse_memory`'s value, for a test: a rejected value aborts the test.
fn mem_ok(text : String) -> Int32 {
  parse_memory(text) catch {
    e => abort("\{e}")
  }
}

///|
/// `parse_memory`'s error message, for a test: an accepted value aborts.
fn mem_err(text : String) -> String {
  let _ = parse_memory(text) catch { e => return e.to_string() }
  abort("expected --memory to reject \{text}")
}

///|
test "parse_memory: suffixes, the int32 bound, malformed input" {
  assert_eq(mem_ok("4096"), 4096)
  assert_eq(mem_ok("1K"), 1024)
  assert_eq(mem_ok("2M"), 2097152)
  assert_eq(mem_ok("1G"), 1073741824)
  assert_eq(mem_ok("0"), 0)
  assert_eq(mem_ok("2147483647"), 2147483647)
  // these used to wrap: 4G wrapped to 0 (no budget at all, so a 4 GiB cap ran
  // unbounded) and 4294971392 wrapped to 4096 (a 4 GiB cap ran tiny)
  assert_true(mem_err("4G").contains("2147483647"))
  assert_true(mem_err("4294971392").contains("2147483647"))
  assert_true(mem_err("2147483648").contains("2147483647"))
  assert_true(mem_err("K").contains("<n>[K|M|G]"))
  assert_true(mem_err("12x").contains("<n>[K|M|G]"))
  assert_true(mem_err("").contains("empty"))
}

///|
test "normalize_args: js prepends the script path, native does not" {
  let native = ["moonlake", "exec", "--csv", "t.csv"]
  let same = normalize_args(native)
  assert_eq(same.length(), 4)
  assert_eq(same[1], "exec")
  // js argv is [node, script.js, ...]: the script path would shift every index
  // and the subcommand would never be found
  let js = ["/usr/bin/node", "/tmp/main.js", "exec", "--csv", "t.csv"]
  let fixed = normalize_args(js)
  assert_eq(fixed.length(), 4)
  assert_eq(fixed[1], "exec")
  // a bare js launch still reaches the usage text
  assert_eq(normalize_args(["/usr/bin/node", "/tmp/main.js"]).length(), 1)
}
