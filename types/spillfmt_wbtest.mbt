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
