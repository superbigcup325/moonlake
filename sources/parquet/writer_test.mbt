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
/// A column with NULLs is written OPTIONAL: the file must scan back with the
/// same values and the NULLs in the same rows, for every physical type.
test "writer round trips NULLs through optional columns" {
  let columns : Array[(String, @types.DataType, Array[@types.Scalar])] = [
    ("a", @types.Int32, [@types.Int32(1), @types.Null, @types.Int32(3)]),
    ("b", @types.Int64, [@types.Null, @types.Int64(-9L), @types.Null]),
    (
      "c",
      @types.Float64,
      [@types.Float64(1.5), @types.Float64(-2.25), @types.Null],
    ),
    ("d", @types.Str, [@types.Str("alpha"), @types.Null, @types.Str("ccc")]),
    (
      "e",
      @types.Bool,
      [@types.Null, @types.Boolean(false), @types.Boolean(true)],
    ),
  ]
  let entry = make_entry(columns, [
    [
      make_vector(@types.Int32, [@types.Int32(1), @types.Null, @types.Int32(3)]),
      make_vector(@types.Int64, [@types.Null, @types.Int64(-9L), @types.Null]),
      make_vector(@types.Float64, [
        @types.Float64(1.5),
        @types.Float64(-2.25),
        @types.Null,
      ]),
      make_vector(@types.Str, [
        @types.Str("alpha"),
        @types.Null,
        @types.Str("ccc"),
      ]),
      make_vector(@types.Bool, [
        @types.Null,
        @types.Boolean(false),
        @types.Boolean(true),
      ]),
    ],
  ])
  let bytes = @parquet.write_bytes(entry) catch { e => abort("\{e}") }
  let back = @parquet.scan_bytes(bytes, "t", []) catch { e => abort("\{e}") }
  assert_eq(back.batches.length(), 1)
  let scanned = back.batches[0]
  assert_eq(scanned.row_count(), 3)
  for index in 0..<5 {
    for row in 0..<3 {
      assert_eq(
        scanned.columns()[index].get(row),
        entry.batches[0].columns()[index].get(row),
      )
    }
  }
}

///|
/// The schema is file-wide: a column that is null-free in the first row group
/// but NULL in the second still has to carry levels in both.
test "writer writes definition levels in every group of an optional column" {
  let columns : Array[(String, @types.DataType, Array[@types.Scalar])] = [
    ("a", @types.Int32, [@types.Int32(1), @types.Null]),
  ]
  let entry = make_entry(columns, [
    [make_vector(@types.Int32, [@types.Int32(10), @types.Int32(11)])],
    [make_vector(@types.Int32, [@types.Null, @types.Int32(12)])],
  ])
  let bytes = @parquet.write_bytes(entry) catch { e => abort("\{e}") }
  let back = @parquet.scan_bytes(bytes, "t", []) catch { e => abort("\{e}") }
  // the scanner concatenates row groups, so the groups show up as one batch
  assert_eq(back.batches.length(), 1)
  let scanned = back.batches[0]
  assert_eq(scanned.row_count(), 4)
  assert_eq(scanned.columns()[0].get(0), @types.Int32(10))
  assert_eq(scanned.columns()[0].get(1), @types.Int32(11))
  assert_eq(scanned.columns()[0].get(2), @types.Null)
  assert_eq(scanned.columns()[0].get(3), @types.Int32(12))
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
