///|
/// Round-trip over every dtype with NULLs mixed in: values, types and
/// column order must survive byte-for-byte.
test "raw spill round-trips all dtypes with nulls" {
  fn vec(
    dt : @types.DataType,
    vals : Array[@types.Scalar],
  ) -> @types.ColumnVector {
    let v = @types.ColumnVector::make(dt, vals.length())
    for r, x in vals {
      v.set(r, x)
    }
    v
  }

  let b1 = @types.DataBatch::new(
    [
      vec(@types.Int32, [
        @types.Int32(1),
        @types.Null,
        @types.Int32(-2147483648),
        @types.Int32(2147483647),
      ]),
      vec(@types.Int64, [
        @types.Int64(-9223372036854775808L),
        @types.Int64(9223372036854775807L),
        @types.Null,
        @types.Int64(42),
      ]),
      vec(@types.Float64, [
        @types.Float64(1.5),
        @types.Null,
        @types.Float64(-0.0),
        @types.Float64(3.14159),
      ]),
      vec(@types.Str, [
        @types.Str(""),
        @types.Str("你好 spill"),
        @types.Null,
        @types.Str("quote\"and\nnewline"),
      ]),
      vec(@types.Date, [
        @types.Date(0),
        @types.Null,
        @types.Date(-25567),
        @types.Date(20000),
      ]),
      vec(@types.Bool, [
        @types.Boolean(true),
        @types.Boolean(false),
        @types.Null,
        @types.Boolean(true),
      ]),
    ],
    4,
  )
  let b2 = @types.DataBatch::new([], 0) // empty batch: zero columns
  let batches = [b1, b2]
  let back = @spill.from_bytes(@spill.to_bytes(batches))
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
