// Whitebox tests for the write path: the pieces that need package-private
// access (the codec enum, the statistics encoder) rather than a round trip
// through the public API.

///|
fn wbt_vector(
  dtype : @types.DataType,
  values : Array[@types.Scalar],
) -> @types.ColumnVector {
  let vector = @types.ColumnVector::make(dtype, values.length())
  for index in 0..<values.length() {
    vector.set(index, values[index])
  }
  vector
}

///|
fn wbt_entry(
  name : String,
  dtype : @types.DataType,
  values : Array[@types.Scalar],
) -> @catalog.TableEntry {
  let schema : @catalog.TableSchema = {
    table: "t",
    columns: [{ name, dtype, }],
  }
  let batch = @types.DataBatch::new(
    [wbt_vector(dtype, values)],
    values.length(),
  )
  @catalog.TableEntry::new(schema, [batch])
}

///|
/// Snappy pages have to decode through the package's own reader path, and
/// repetitive text has to actually get smaller — otherwise the codec is a
/// promise with no payload.
test "a snappy-written file decodes and is smaller" {
  let values : Array[@types.Scalar] = []
  for i in 0..<500 {
    values.push(@types.Str("row-\{i % 7}-moonlake-parquet-page"))
  }
  let entry = wbt_entry("s", @types.Str, values)
  let raw = write_bytes_with(entry, ParquetCodec::Raw) catch {
    e => abort("\{e}")
  }
  let packed = write_bytes_with(entry, ParquetCodec::Snappy) catch {
    e => abort("\{e}")
  }
  assert_true(packed.length() < raw.length())
  let back = scan_bytes(packed, "t", []) catch { e => abort("\{e}") }
  let batches = back.scan(@catalog.ScanRequest::all(1)) catch {
    e => abort("\{e}")
  }
  assert_eq(batches.length(), 1)
  assert_eq(batches[0].row_count(), 500)
  for row in 0..<500 {
    assert_eq(batches[0].columns()[0].get(row), values[row])
  }
}

///|
/// The statistics encoder marks its bounds exact only when it has both of
/// them: a reader that trusts exactness would otherwise skip groups it only
/// half knows.
test "statistics omit bounds they cannot prove" {
  let with_nan = wbt_entry("f", @types.Float64, [
    @types.Float64(1.0),
    @types.Float64(0.0 / 0.0),
    @types.Float64(2.0),
  ])
  let st = column_stats(with_nan.batches[0].columns()[0])
  assert_true(st.min is None)
  assert_true(st.max is None)
  assert_eq(st.nulls, 0L)
  let ints = wbt_entry("i", @types.Int32, [@types.Int32(-3), @types.Null])
  let st2 = column_stats(ints.batches[0].columns()[0])
  assert_true(st2.min is Some(_))
  assert_true(st2.max is Some(_))
  assert_eq(st2.nulls, 1L)
}

///|
/// The writer pushes bytes out as it encodes them, so a sink that fails stops
/// the archive where it failed instead of after the whole table was built.
test "an emit failure stops the writer and propagates" {
  let entry = wbt_entry("a", @types.Int32, [
    @types.Int32(1),
    @types.Int32(2),
    @types.Int32(3),
  ])
  let mut calls = 0
  let mut raised = false
  write_with(entry, ParquetCodec::Raw, chunk => {
    calls += 1
    if calls == 3 {
      raise write_error("sink exploded")
    }
    ignore(chunk)
  }) catch {
    e => {
      assert_true(e.to_string().contains("sink exploded"))
      raised = true
    }
  }
  assert_true(raised)
  // the first two chunks (magic + page header) were emitted, then it stopped
  assert_eq(calls, 3)
}

///|
/// A file position is not a page offset: a 3 GiB output has page offsets past
/// 2 GiB, and both the column chunk and the metadata inside it have to carry
/// them. A synthetic footer is enough to prove the encoding end to end, because
/// the reader that would consume a real one parses exactly these fields.
test "a column chunk offset past 2 GiB survives the footer round trip" {
  let big : Int64 = 5_000_000_000L
  let meta = w_column_meta_data(
    "a",
    1, // INT32
    3,
    12,
    12,
    big,
    ParquetCodec::Raw,
    no_bounds(0L),
  )
  let chunk = w_column_chunk(big, meta)
  let group = w_row_group([chunk], 24, 3)
  let schema = [w_schema_root(1), w_schema_leaf("a", 1, @types.Int32)]
  let footer = w_file_meta_data(schema, 3L, [group])
  // PAR1, eight bytes of would-be data, the footer, its length, the tail magic
  let file = Buffer()
  file.write_bytes(b"PAR1")
  file.write_bytes(b"12345678")
  file.write_bytes(footer)
  let length = Buffer()
  length.write_int_le(footer.length())
  file.write_bytes(length.to_bytes())
  file.write_bytes(b"PAR1")
  let parsed = read_footer(memory_input(file.to_bytes())) catch {
    e => abort("\{e}")
  }
  assert_eq(parsed.row_groups[0].columns[0].data_page_offset, big)
  // the chunk carries the same position in its own field 2, and a reader that
  // trusted that field instead of the metadata's would see the same number
  let tr = Tr::new(chunk)
  let (id, kind) = tr.field_header(0) catch { e => abort("\{e}") }
  assert_eq(id, 2)
  assert_true(kind is TType::I64T)
  let file_offset = tr.zigzag_i64() catch { e => abort("\{e}") }
  assert_eq(file_offset, big)
}
