///|
/// Round-trip over every dtype with NULLs mixed in: values, types and
/// column order must survive byte-for-byte.
test "spill wire format round-trips all dtypes with nulls" {
  fn vec(dt : DataType, vals : Array[Scalar]) -> ColumnVector {
    let v = ColumnVector::make(dt, vals.length())
    for r, x in vals {
      v.set(r, x)
    }
    v
  }

  let b1 = DataBatch::new(
    [
      vec(Int32, [Int32(1), Null, Int32(-2147483648), Int32(2147483647)]),
      vec(Int64, [
        Int64(-9223372036854775808L),
        Int64(9223372036854775807L),
        Null,
        Int64(42),
      ]),
      vec(Float64, [Float64(1.5), Null, Float64(-0.0), Float64(3.14159)]),
      // Non-ASCII on purpose: a multibyte UTF-8 value must round-trip too.
      vec(Str, [Str(""), Str("你好 spill"), Null, Str("quote\"and\nnewline")]),
      vec(Date, [Date(0), Null, Date(-25567), Date(20000)]),
      vec(Bool, [Boolean(true), Boolean(false), Null, Boolean(true)]),
    ],
    4,
  )
  let b2 = DataBatch::new([], 0) // empty batch: zero columns
  let batches = [b1, b2]
  let back = DataBatch::from_spill_bytes(DataBatch::to_spill_bytes(batches))
  assert_eq(back.length(), 2)
  let rb = back[0]
  assert_eq(rb.row_count(), 4)
  assert_eq(rb.columns().length(), 6)
  for c in 0..<6 {
    for r in 0..<4 {
      assert_eq(rb.columns()[c].get(r), b1.columns()[c].get(r))
    }
  }
  assert_eq(back[1].row_count(), 0)
}

///|
test "spill picks a compact encoding for repetitive integers" {
  let n = 1000
  let vec = ColumnVector::make(Int32, n)
  for r in 0..<n {
    vec.set(r, Int32(r % 10))
  }
  let batch = DataBatch::new([vec], n)
  let bytes = DataBatch::to_spill_bytes([batch]) catch { e => abort("\{e}") }
  // PLAIN would be 4000 payload bytes plus flags; dictionary or delta must win
  assert_true(bytes.length() < 2000)
  let back = DataBatch::from_spill_bytes(bytes) catch { e => abort("\{e}") }
  assert_eq(back[0].row_count(), n)
  for r in 0..<n {
    assert_eq(back[0].columns()[0].get(r), Int32(r % 10))
  }
}

///|
test "spill picks delta for monotonic integers" {
  let n = 1000
  let vec = ColumnVector::make(Int64, n)
  for r in 0..<n {
    vec.set(r, Int64(r.to_int64() * 7L))
  }
  let batch = DataBatch::new([vec], n)
  let bytes = DataBatch::to_spill_bytes([batch]) catch { e => abort("\{e}") }
  // one presence byte per row plus the delta stream; PLAIN would be 8000
  assert_true(bytes.length() < 1300)
  let back = DataBatch::from_spill_bytes(bytes) catch { e => abort("\{e}") }
  for r in 0..<n {
    assert_eq(back[0].columns()[0].get(r), Int64(r.to_int64() * 7L))
  }
}

///|
test "spill picks a compact encoding for low-cardinality strings" {
  let n = 500
  let vec = ColumnVector::make(Str, n)
  for r in 0..<n {
    vec.set(r, Str("tag-\{r % 4}"))
  }
  let batch = DataBatch::new([vec], n)
  let bytes = DataBatch::to_spill_bytes([batch]) catch { e => abort("\{e}") }
  // PLAIN is 4 bytes of length plus the text per value, so well over 3 KB
  assert_true(bytes.length() < 1500)
  let back = DataBatch::from_spill_bytes(bytes) catch { e => abort("\{e}") }
  for r in 0..<n {
    assert_eq(back[0].columns()[0].get(r), Str("tag-\{r % 4}"))
  }
}

///|
test "spill round trips all-null and sparse columns" {
  let all_null = ColumnVector::make(Int64, 4)
  for r in 0..<4 {
    all_null.set(r, Null)
  }
  let sparse = ColumnVector::make(Str, 4)
  for r in 0..<4 {
    sparse.set(r, Null)
  }
  sparse.set(1, Str("only"))
  let batch = DataBatch::new([all_null, sparse], 4)
  let bytes = DataBatch::to_spill_bytes([batch]) catch { e => abort("\{e}") }
  let back = DataBatch::from_spill_bytes(bytes) catch { e => abort("\{e}") }
  for r in 0..<4 {
    assert_eq(back[0].columns()[0].get(r), Null)
  }
  assert_eq(back[0].columns()[1].get(0), Null)
  assert_eq(back[0].columns()[1].get(1), Str("only"))
  assert_eq(back[0].columns()[1].get(2), Null)
  assert_eq(back[0].columns()[1].get(3), Null)
}
