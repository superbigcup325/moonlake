///|
/// Blackbox tests for CSV scanning: inference, NULL cells, quoting,
/// batch splitting.

///|
/// Drain a lazy entry the way the engine does: every column, no predicates.
fn read_all(entry : @catalog.TableEntry) -> Array[@types.DataBatch] {
  entry.scan(@catalog.ScanRequest::all(entry.schema.columns.length())) catch {
    e => abort("\{e}")
  }
}

///|
/// The message of the scan error `content` raises. Fails the test when the scan
/// succeeds: a `catch` that merely returns would pass a regression silently.
fn scan_error(content : String) -> String {
  // the scan is lazy: a row past the inference sample is refused when the scan
  // runs, not when the table is registered
  let entry = @csv.scan_string(content, "t") catch {
    err => return err.to_string()
  }
  let _ = entry.scan(@catalog.ScanRequest::all(entry.schema.columns.length())) catch {
    err => return err.to_string()
  }
  abort("expected a scan error, the scan succeeded")
}

///|
test "infer types, nulls and quoted strings" {
  let content = "id,qty,price,ok,day,name\n1,12.5,10000.50,true,1994-06-01,widget\n2,24.0,20000.00,false,1994-12-31,\"gear, big\"\n3,,9.99,true,,nut\n"
  let entry = @csv.scan_string(content, "t")
  assert_eq(entry.schema.table, "t")
  let cols = entry.schema.columns
  assert_eq(cols.length(), 6)
  assert_eq(cols[0].dtype, @types.Int32)
  assert_eq(cols[1].dtype, @types.Float64)
  assert_eq(cols[2].dtype, @types.Float64)
  assert_eq(cols[3].dtype, @types.Bool)
  assert_eq(cols[4].dtype, @types.Date)
  assert_eq(cols[5].dtype, @types.Str)
  assert_eq(read_all(entry).length(), 1)
  let b = read_all(entry)[0]
  assert_eq(b.row_count(), 3)
  assert_eq(b.columns()[0].get(2), @types.Scalar::Int32(3))
  assert_eq(b.columns()[1].get(0), @types.Scalar::Float64(12.5))
  assert_eq(b.columns()[1].get(2), @types.Scalar::Null) // empty cell
  assert_eq(b.columns()[3].get(1), @types.Scalar::Boolean(false))
  assert_eq(
    b.columns()[4].get(1),
    @types.Scalar::Date(@types.parse_date("1994-12-31").unwrap()),
  )
  assert_eq(b.columns()[5].get(1), @types.Scalar::Str("gear, big"))
}

///|
test "rows split into fixed size batches" {
  let sb = StringBuilder()
  sb.write_string("n\n")
  for i in 0..<5000 {
    sb.write_string(i.to_string())
    sb.write_char('\n')
  }
  let entry = @csv.scan_string(sb.to_string(), "big")
  assert_eq(read_all(entry)[0].row_count(), 4096)
  assert_eq(read_all(entry)[1].row_count(), 904)
  assert_eq(
    read_all(entry)[1].columns()[0].get(903),
    @types.Scalar::Int32(4999),
  )
}

///|
test "empty table keeps column structure" {
  let entry = @csv.scan_string("a,b\n", "empty")
  assert_eq(entry.schema.columns.length(), 2)
  assert_eq(read_all(entry).length(), 1)
  assert_eq(read_all(entry)[0].row_count(), 0)
}

///|
test "integer columns widen to int64 then float64, never wrap" {
  let entry = @csv.scan_string(
    "i32max,i32p1,i64max,i64p1\n2147483647,2147483648,9223372036854775807,9223372036854775808\n",
    "t",
  )
  let cols = entry.schema.columns
  assert_eq(cols[0].dtype, @types.Int32)
  assert_eq(cols[1].dtype, @types.Int64) // one past int32: widens, not wraps
  assert_eq(cols[2].dtype, @types.Int64)
  assert_eq(cols[3].dtype, @types.Float64) // one past int64: duckdb-style fallback
  let b = read_all(entry)[0]
  assert_eq(b.columns()[0].get(0), @types.Scalar::Int32(2147483647))
  assert_eq(b.columns()[1].get(0), @types.Scalar::Int64(2147483648L))
  assert_eq(b.columns()[2].get(0), @types.Scalar::Int64(9223372036854775807L))
  // past 2^53 the double parser degrades to the nearest float64 (its
  // documented accuracy contract); the sign and magnitude must survive
  assert_true(
    b.columns()[3].get(0) is @types.Scalar::Float64(v) &&
    (v - 9223372036854775808.0).abs() / 9223372036854775808.0 < 1.0e-9,
  )
}

///|
test "UTF-8 BOM is stripped from the first header cell" {
  let entry = @csv.scan_string("\u{FEFF}a,b\n1,2\n", "bom")
  assert_eq(entry.schema.columns[0].name, "a")
  let b = read_all(entry)[0]
  assert_eq(b.columns()[0].get(0), @types.Scalar::Int32(1))
  assert_eq(b.columns()[1].get(0), @types.Scalar::Int32(2))
}

///|
test "reader dialect: CRLF, blank lines, escapes, no trailing newline" {
  // CRLF terminators
  let e1 = @csv.scan_string("a,b\r\n1,x\r\n2,y\r\n", "t1")
  assert_eq(read_all(e1)[0].row_count(), 2)
  assert_eq(read_all(e1)[0].columns()[0].get(1), @types.Scalar::Int32(2))
  assert_eq(read_all(e1)[0].columns()[1].get(1), @types.Str("y"))
  // blank lines in the middle are skipped
  let e2 = @csv.scan_string("a\n1\n\n2\n", "t2")
  assert_eq(read_all(e2)[0].row_count(), 2)
  // "" escape folds to a single quote; quoted comma and newline stay
  let e3 = @csv.scan_string("s\n\"say \"\"hi\"\"\"\n\"line1\nline2\"\n", "t3")
  assert_eq(read_all(e3)[0].columns()[0].get(0), @types.Str("say \"hi\""))
  assert_eq(read_all(e3)[0].columns()[0].get(1), @types.Str("line1\nline2"))
  // unquoted empty and quoted empty both read as NULL
  let e4 = @csv.scan_string("a,b\n,\"\"\n", "t4")
  assert_eq(read_all(e4)[0].columns()[0].get(0), @types.Scalar::Null)
  assert_eq(read_all(e4)[0].columns()[1].get(0), @types.Scalar::Null)
  // no trailing newline; single cell row
  let e5 = @csv.scan_string("a\n7", "t5")
  assert_eq(read_all(e5)[0].columns()[0].get(0), @types.Scalar::Int32(7))
  // trailing comma: empty last field
  let e6 = @csv.scan_string("a,b\n1,\n", "t6")
  assert_eq(read_all(e6)[0].columns()[1].get(0), @types.Scalar::Null)
  // header-only file keeps one empty batch
  let e7 = @csv.scan_string("a,b\n", "t7")
  assert_eq(read_all(e7).length(), 1)
  assert_eq(read_all(e7)[0].row_count(), 0)
  // unicode passes through
  let e8 = @csv.scan_string("s\ncafé ☕\n", "t8")
  assert_eq(read_all(e8)[0].columns()[0].get(0), @types.Str("café ☕"))
}

///|
test "scan_files concatenates same-schema files into one table" {
  let dir = temp_dir()
  let p1 = dir + "/part-1.csv"
  let p2 = dir + "/part-2.csv"
  @fs.write_bytes_to_file(p1, @utf8.encode("k,v\n1,10\n"))
  @fs.write_bytes_to_file(p2, @utf8.encode("k,v\n2,20\n3,30\n"))
  let entry = @csv.scan_files([p1, p2], "parts") catch { e => abort("\{e}") }
  assert_eq(entry.schema.table, "parts")
  let mut rows = 0
  for b in read_all(entry) {
    rows += b.row_count()
  }
  assert_eq(rows, 3)
  // a drifted header is a clean scan error naming the file
  let p3 = dir + "/part-3.csv"
  @fs.write_bytes_to_file(p3, @utf8.encode("k,w\n4,40\n"))
  let _ = @csv.scan_files([p1, p3], "parts") catch {
    e => {
      assert_true(e.to_string().contains("part-3"))
      return
    }
  }
  abort("expected a header-mismatch error")
}

///|
fn temp_dir() -> String {
  // @fs.create_dir is non-recursive on the native backend, so the parent has
  // to exist first: CI checks out a clean tree with no target/ directory.
  @fs.create_dir("target") catch {
    _ => ()
  }
  let d = "target/csv_glob_test"
  @fs.create_dir(d) catch {
    _ => ()
  }
  d
}

///|
test "a ragged row is a scan error, never a borrowed value" {
  // a short row's cells would run into the next row's cells: `a,b` plus a
  // one-cell row answered 1,2 / 3,4 / 5,4 before the width check, and the last
  // row of a range ran past the cell arrays and crashed the process
  assert_true(
    scan_error("a,b\n1,2\n3,4\n5\n").contains("row 4 has 1 field, expected 2"),
  )
  // extra cells are the same defect from the other side
  assert_true(
    scan_error("a,b\n1,2,3\n").contains("row 2 has 3 fields, expected 2"),
  )
  // mid-file, past the inference sample: registration passes it, the scan
  // refuses it instead of reading the next row's second cell
  let mut rows = "a,b\n"
  for i in 0..<150 {
    rows = rows + "\{i},1\n"
  }
  rows = rows + "99\n"
  assert_true(scan_error(rows).contains("row 152 has 1 field, expected 2"))
  // a well-formed file keeps its rows
  let ok = @csv.scan_string("a,b\n1,2\n3,4\n", "t")
  assert_eq(ok.schema.columns.length(), 2)
  assert_eq(read_all(ok)[0].row_count(), 2)
}

///|
test "a repeated header name is renamed, as DuckDB's read_csv does" {
  // both columns used to bind to the first one, so the second was unreachable:
  // `a,a` over 1,2 answered 1|1 and a JSON row repeated a key
  let entry = @csv.scan_string("a,a\n1,2\n3,4\n", "t")
  assert_eq(entry.schema.columns.length(), 2)
  assert_eq(entry.schema.columns[0].name, "a")
  assert_eq(entry.schema.columns[1].name, "a_1")
  let b = read_all(entry)[0]
  assert_eq(b.columns()[0].get(0), @types.Scalar::Int32(1))
  assert_eq(b.columns()[1].get(0), @types.Scalar::Int32(2))
  // a generated name never collides with one the header already uses
  let three = @csv.scan_string("a,a_1,a,a\n1,2,3,4\n", "t")
  assert_eq(three.schema.columns[0].name, "a")
  assert_eq(three.schema.columns[1].name, "a_1")
  assert_eq(three.schema.columns[2].name, "a_2")
  assert_eq(three.schema.columns[3].name, "a_3")
}

///|
test "non-finite float spellings are floats, not strings" {
  let entry = @csv.scan_string("x\n1.5\nNaN\ninf\n-Infinity\n", "t")
  assert_eq(entry.schema.columns[0].dtype, @types.Float64)
  let b = read_all(entry)[0]
  match b.columns()[0].get(1) {
    @types.Scalar::Float64(v) => assert_true(v.is_nan())
    other => fail("expected nan, got \{other.to_string()}")
  }
  match b.columns()[0].get(2) {
    @types.Scalar::Float64(v) => assert_true(v > 1.0e308)
    other => fail("expected +inf, got \{other.to_string()}")
  }
  match b.columns()[0].get(3) {
    @types.Scalar::Float64(v) => assert_true(v < -1.0e308)
    other => fail("expected -inf, got \{other.to_string()}")
  }
}

///|
/// A projected-away column is never parsed: the scan decodes only what the
/// query reads, so an unparsable value outside the projection costs nothing.
test "a column outside the projection is never parsed" {
  let sb = StringBuilder()
  sb.write_string("id,bad\n")
  for i in 0..<200 {
    sb.write_string("\{i},\{i}\n")
  }
  // past the 100-row inference sample, so `bad` is still inferred as int32
  sb.write_string("200,oops\n")
  let entry = @csv.scan_string(sb.to_string(), "t")
  let ids = entry.scan(@catalog.ScanRequest::new([0], [])) catch {
    e => abort("\{e}")
  }
  assert_eq(ids.length(), 1)
  assert_eq(ids[0].row_count(), 201)
  assert_eq(ids[0].columns()[0].get(200), @types.Int32(200))
  // asking for the column surfaces the parse error
  let _ = entry.scan(@catalog.ScanRequest::new([1], [])) catch {
    e => {
      assert_true(e.to_string().contains("cannot parse"))
      return
    }
  }
  abort("expected a scan error from the unreadable column")
}

///|
/// Predicate hints are advisory: a source that cannot use them still returns
/// every row, and the engine filters.
test "predicate hints never remove rows on their own" {
  let entry = @csv.scan_string("a\n1\n2\n3\n", "t")
  let request = @catalog.ScanRequest::new([0], [
    { column: 0, op: @types.Gt, value: @types.Int32(1), },
  ])
  let batches = entry.scan(request) catch { e => abort("\{e}") }
  assert_eq(batches.length(), 1)
  assert_eq(batches[0].row_count(), 3)
}

///|
/// A file-backed table holds the path, not the rows: the scan reads the file
/// when it opens, so registering is cheap and the bytes are not retained.
test "a file table re-reads the file when the scan opens" {
  let dir = temp_dir()
  let path = dir + "/lazy.csv"
  @fs.write_bytes_to_file(path, @utf8.encode("k,v\n1,10\n2,20\n"))
  let entry = @csv.scan_file(path, "lazy") catch { e => abort("\{e}") }
  assert_true(entry.is_lazy())
  assert_eq(entry.batches.length(), 0)
  @fs.write_bytes_to_file(path, @utf8.encode("k,v\n1,10\n2,20\n3,30\n"))
  assert_eq(read_all(entry)[0].row_count(), 3)
}
