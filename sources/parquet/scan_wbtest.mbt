// Round-trip test: build a Parquet file with the upstream writer, then
// read it back through the moonlake adapter. Exercises the type mapping
// (int32→DATE via date_columns, int64, utf8) without fixture files, so
// it runs on all three targets. The upstream writer covers these three
// types only; the double path is exercised end to end by the duckdb
// golden chain (harness/check_all.sh).

///|
test "round trip: columns survive write and read with declared types" {
  let cols = [
    @mp.new_column("id", @mp.Int32, @mp.Required),
    @mp.new_column("seq", @mp.Int64, @mp.Required),
    @mp.new_column("flag", @mp.String, @mp.Required),
  ]
  let rows : Array[Array[@mp.Value]] = [
    [@mp.Int32(19000), @mp.Int64(10L), @mp.String("N")],
    [@mp.Int32(19001), @mp.Int64(20L), @mp.String("O")],
    [@mp.Int32(19002), @mp.Int64(30L), @mp.String("A")],
  ]
  let pf = @mp.new_parquet_file(cols, rows, Some("moonlake-test"))
  let bytes = @mp.write_bytes(pf) catch { e => fail("writer: \{e}") }
  let entry = scan_bytes(bytes, "t", ["id"]) catch { e => fail("scan: \{e}") }
  // id declared as DATE: epoch-day int32 lifts to the DATE type
  assert_eq(entry.schema.columns[0].name, "id")
  assert_eq(entry.schema.columns[0].dtype, @types.Date)
  assert_eq(entry.schema.columns[1].dtype, @types.Int64)
  assert_eq(entry.schema.columns[2].dtype, @types.Str)
  let b = entry.batches[0]
  assert_eq(b.row_count(), 3)
  assert_eq(b.columns()[0].get(0), @types.Date(19000))
  assert_eq(b.columns()[1].get(1), @types.Int64(20L))
  assert_eq(b.columns()[2].get(2), @types.Str("A"))
}

///|
fn build_err(file : @mp.ParquetColumnarFile) -> @types.SqlError {
  let _ = build_entry("t", file, []) catch { e => return e }
  abort("expected a scan error")
}

///|
test "timestamp columns are rejected at registration" {
  let cols = [@mp.new_column("ts", @mp.TimestampMicros, @mp.Required)]
  let cdata = [@mp.TimestampMicrosValues([1000000L])]
  let file = @mp.new_parquet_columnar_file(cols, cdata, 1, Some("x"))
  let err = build_err(file)
  assert_true(err.to_string().contains("unsupported"))
}

///|
test "nullable utf8 columns carry NULL slots" {
  let cols = [@mp.new_column("note", @mp.String, @mp.Optional)]
  let cdata = [
    @mp.NullableUtf8Values([
      Some(@utf8.encode("hi")),
      None,
      Some(@utf8.encode("yo")),
    ]),
  ]
  let file = @mp.new_parquet_columnar_file(cols, cdata, 3, Some("x"))
  let entry = build_entry("t", file, []) catch { e => fail("scan: \{e}") }
  let b = entry.batches[0]
  assert_eq(b.row_count(), 3)
  assert_eq(b.columns()[0].get(0), @types.Str("hi"))
  assert_eq(b.columns()[0].get(1), @types.Null)
  assert_eq(b.columns()[0].get(2), @types.Str("yo"))
}
