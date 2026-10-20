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
  @catalog.TableEntry::new({ table: "t", columns: schema_columns, }, built)
}

///|
/// Read a written file back through the lazy scan: every column, no hints.
fn read_all(entry : @catalog.TableEntry) -> Array[@types.DataBatch] {
  entry.scan(@catalog.ScanRequest::all(entry.schema.columns.length())) catch {
    e => abort("\{e}")
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
  assert_eq(read_all(back).length(), 1)
  let scanned = read_all(back)[0]
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
  // the scan emits one batch per row group (each sliced to 4096 rows), so the
  // two groups written above come back as two batches, not one
  let groups = read_all(back)
  assert_eq(groups.length(), 2)
  assert_eq(groups[0].row_count(), 2)
  assert_eq(groups[1].row_count(), 1)
  assert_eq(groups[0].columns()[0].get(0), @types.Int32(1))
  assert_eq(groups[0].columns()[0].get(1), @types.Int32(2))
  assert_eq(groups[1].columns()[0].get(0), @types.Int32(3))
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
  assert_eq(read_all(back).length(), 1)
  let scanned = read_all(back)[0]
  assert_eq(scanned.row_count(), 3)
  for index in 0..<5 {
    for row in 0..<3 {
      assert_eq(
        scanned.columns()[index].get(row),
        read_all(entry)[0].columns()[index].get(row),
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
  // each row group carries its own definition levels and comes back as its
  // own batch: the groups are not concatenated
  let groups = read_all(back)
  assert_eq(groups.length(), 2)
  assert_eq(groups[0].row_count(), 2)
  assert_eq(groups[1].row_count(), 2)
  assert_eq(groups[0].columns()[0].get(0), @types.Int32(10))
  assert_eq(groups[0].columns()[0].get(1), @types.Int32(11))
  assert_eq(groups[1].columns()[0].get(0), @types.Null)
  assert_eq(groups[1].columns()[0].get(1), @types.Int32(12))
}

///|
test "writer emits a file with no row groups for an empty entry" {
  let columns : Array[(String, @types.DataType, Array[@types.Scalar])] = [
    ("a", @types.Int64, []),
  ]
  let entry = make_entry(columns, [[make_vector(@types.Int64, [])]])
  let bytes = @parquet.write_bytes(entry) catch { e => abort("\{e}") }
  let back = @parquet.scan_bytes(bytes, "t", []) catch { e => abort("\{e}") }
  assert_eq(read_all(back)[0].row_count(), 0)
}

///|
/// The writer takes any table entry, including a lazy one: a CSV scan is
/// materialized inside `write_bytes` and lands as Parquet with the same rows.
test "a lazily scanned CSV table can be written as parquet" {
  let src = @csv.scan_string("k,v,s\n1,10,a\n2,20,b\n", "src") catch {
    e => abort("\{e}")
  }
  assert_true(src.is_lazy())
  let bytes = @parquet.write_bytes(src) catch { e => abort("\{e}") }
  let back = @parquet.scan_bytes(bytes, "t", []) catch { e => abort("\{e}") }
  let batches = read_all(back)
  let mut rows = 0
  for b in batches {
    rows += b.row_count()
  }
  assert_eq(rows, 2)
  assert_eq(batches[0].columns()[0].get(1), @types.Int32(2))
  assert_eq(batches[0].columns()[2].get(0), @types.Str("a"))
}
