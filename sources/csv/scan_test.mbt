///|
/// Blackbox tests for CSV scanning: inference, NULL cells, quoting,
/// batch splitting.

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
  assert_eq(entry.batches.length(), 1)
  let b = entry.batches[0]
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
  assert_eq(entry.batches[0].row_count(), 4096)
  assert_eq(entry.batches[1].row_count(), 904)
  assert_eq(entry.batches[1].columns()[0].get(903), @types.Scalar::Int32(4999))
}

///|
test "empty table keeps column structure" {
  let entry = @csv.scan_string("a,b\n", "empty")
  assert_eq(entry.schema.columns.length(), 2)
  assert_eq(entry.batches.length(), 1)
  assert_eq(entry.batches[0].row_count(), 0)
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
  let b = entry.batches[0]
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
  let b = entry.batches[0]
  assert_eq(b.columns()[0].get(0), @types.Scalar::Int32(1))
  assert_eq(b.columns()[1].get(0), @types.Scalar::Int32(2))
}

///|
test "reader dialect: CRLF, blank lines, escapes, no trailing newline" {
  // CRLF terminators
  let e1 = @csv.scan_string("a,b\r\n1,x\r\n2,y\r\n", "t1")
  assert_eq(e1.batches[0].row_count(), 2)
  assert_eq(e1.batches[0].columns()[0].get(1), @types.Scalar::Int32(2))
  assert_eq(e1.batches[0].columns()[1].get(1), @types.Str("y"))
  // blank lines in the middle are skipped
  let e2 = @csv.scan_string("a\n1\n\n2\n", "t2")
  assert_eq(e2.batches[0].row_count(), 2)
  // "" escape folds to a single quote; quoted comma and newline stay
  let e3 = @csv.scan_string("s\n\"say \"\"hi\"\"\"\n\"line1\nline2\"\n", "t3")
  assert_eq(e3.batches[0].columns()[0].get(0), @types.Str("say \"hi\""))
  assert_eq(e3.batches[0].columns()[0].get(1), @types.Str("line1\nline2"))
  // unquoted empty and quoted empty both read as NULL
  let e4 = @csv.scan_string("a,b\n,\"\"\n", "t4")
  assert_eq(e4.batches[0].columns()[0].get(0), @types.Scalar::Null)
  assert_eq(e4.batches[0].columns()[1].get(0), @types.Scalar::Null)
  // no trailing newline; single cell row
  let e5 = @csv.scan_string("a\n7", "t5")
  assert_eq(e5.batches[0].columns()[0].get(0), @types.Scalar::Int32(7))
  // trailing comma: empty last field
  let e6 = @csv.scan_string("a,b\n1,\n", "t6")
  assert_eq(e6.batches[0].columns()[1].get(0), @types.Scalar::Null)
  // header-only file keeps one empty batch
  let e7 = @csv.scan_string("a,b\n", "t7")
  assert_eq(e7.batches.length(), 1)
  assert_eq(e7.batches[0].row_count(), 0)
  // unicode passes through
  let e8 = @csv.scan_string("s\ncafé ☕\n", "t8")
  assert_eq(e8.batches[0].columns()[0].get(0), @types.Str("café ☕"))
}
