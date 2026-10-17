// Round-trip tests for the Parquet writer: what the writer emits must scan
// back through the in-house reader with the same values, including date
// lifting and multiple row groups.

///|
fn make_vector(
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
fn make_entry(
  columns : Array[(String, @types.DataType, Array[@types.Scalar])],
  batches : Array[Array[@types.ColumnVector]],
) -> @catalog.TableEntry {
  let schema_columns : Array[@catalog.Column] = []
  for column in columns {
    schema_columns.push({ name: column.0, dtype: column.1, })
  }
  let built : Array[@types.DataBatch] = []
  for vectors in batches {
    let rows = if vectors.length() > 0 { vectors[0].len() } else { 0 }
    built.push(@types.DataBatch::new(vectors, rows))
  }
  { schema: { table: "t", columns: schema_columns, }, batches: built, }
}

///|
fn capture_write_error(
  run : () -> Bytes raise @types.SqlError,
) -> @types.SqlError {
  let mut captured : @types.SqlError? = None
  try {
    let _ = run()
  } catch {
    e => captured = Some(e)
  }
  match captured {
    Some(e) => e
    None => abort("expected the write to fail")
  }
}

///|
test "writer round trips every physical type" {
  let columns : Array[(String, @types.DataType, Array[@types.Scalar])] = [
    ("a", @types.Int32, [@types.Int32(1), @types.Int32(-2), @types.Int32(3)]),
    ("b", @types.Int64, [@types.Int64(7L), @types.Int64(-9L), @types.Int64(1L)]),
    (
      "c",
      @types.Float64,
      [@types.Float64(1.5), @types.Float64(-2.25), @types.Float64(0.0)],
    ),
    ("d", @types.Str, [@types.Str("alpha"), @types.Str(""), @types.Str("ccc")]),
    (
      "e",
      @types.Bool,
      [@types.Boolean(true), @types.Boolean(false), @types.Boolean(true)],
    ),
    ("f", @types.Date, [@types.Date(0), @types.Date(1), @types.Date(20000)]),
  ]
  let batch = [
    make_vector(@types.Int32, columns[0].2),
    make_vector(@types.Int64, columns[1].2),
    make_vector(@types.Float64, columns[2].2),
    make_vector(@types.Str, columns[3].2),
    make_vector(@types.Bool, columns[4].2),
    make_vector(@types.Date, columns[5].2),
  ]
  let entry = make_entry(columns, [batch])
  let bytes = @parquet.write_bytes(entry) catch { e => abort("\{e}") }
  let back = @parquet.scan_bytes(bytes, "t", ["f"]) catch { e => abort("\{e}") }
  assert_eq(back.batches.length(), 1)
  let scanned = back.batches[0]
  assert_eq(scanned.row_count(), 3)
  for column in 0..<6 {
    let vec = scanned.columns()[column]
    for row in 0..<3 {
      assert_eq(vec.get(row), columns[column].2[row])
    }
  }
}

///|
test "writer emits one row group per batch" {
  let columns : Array[(String, @types.DataType, Array[@types.Scalar])] = [
    ("k", @types.Int32, []),
  ]
  let first = [make_vector(@types.Int32, [@types.Int32(1), @types.Int32(2)])]
  let second = [make_vector(@types.Int32, [@types.Int32(3)])]
  let entry = make_entry(columns, [first, second])
  let bytes = @parquet.write_bytes(entry) catch { e => abort("\{e}") }
  let back = @parquet.scan_bytes(bytes, "t", []) catch { e => abort("\{e}") }
  assert_eq(back.batches.length(), 1)
  let scanned = back.batches[0]
  assert_eq(scanned.row_count(), 3)
  let values = scanned.columns()[0]
  assert_eq(values.get(0), @types.Int32(1))
  assert_eq(values.get(1), @types.Int32(2))
  assert_eq(values.get(2), @types.Int32(3))
}

///|
test "writer refuses NULLs instead of writing them wrong" {
  let columns : Array[(String, @types.DataType, Array[@types.Scalar])] = [
    ("a", @types.Int32, [@types.Int32(1), @types.Null]),
  ]
  let entry = make_entry(columns, [
    [make_vector(@types.Int32, [@types.Int32(1), @types.Null])],
  ])
  let error = capture_write_error(() => @parquet.write_bytes(entry))
  assert_true(error.to_string().contains("NULL values are not supported"))
}

///|
test "writer emits a file with no row groups for an empty entry" {
  let columns : Array[(String, @types.DataType, Array[@types.Scalar])] = [
    ("a", @types.Int64, []),
  ]
  let entry = make_entry(columns, [[make_vector(@types.Int64, [])]])
  let bytes = @parquet.write_bytes(entry) catch { e => abort("\{e}") }
  let back = @parquet.scan_bytes(bytes, "t", []) catch { e => abort("\{e}") }
  assert_eq(back.batches[0].row_count(), 0)
}
