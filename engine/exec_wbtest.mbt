// Whitebox tests for the execution helpers.

///|
fn str_batch(vals : Array[String]) -> @types.DataBatch {
  let vec = @types.ColumnVector::make(@types.Str, vals.length())
  for i, v in vals {
    vec.set(i, @types.Str(v))
  }
  @types.DataBatch::new([vec], vals.length())
}

///|
test "order_limit sorts by a single string key" {
  let batch = str_batch([
    "pear", "apple", "mango", "banana", "kiwi", "cherry", "apricot", "blueberry",
  ])
  let out = order_limit(batch, [(0, false, None)], None, None)
  assert_eq(out.row_count(), 8)
  assert_eq(out.columns()[0].get(0), @types.Str("apple"))
  assert_eq(out.columns()[0].get(1), @types.Str("apricot"))
  assert_eq(out.columns()[0].get(7), @types.Str("pear"))
}

///|
test "order_limit sorts desc with limit" {
  let batch = str_batch(["a", "c", "b"])
  let out = order_limit(batch, [(0, true, None)], Some(2), None)
  assert_eq(out.row_count(), 2)
  assert_eq(out.columns()[0].get(0), @types.Str("c"))
  assert_eq(out.columns()[0].get(1), @types.Str("b"))
}

///|
test "lexical_compare is dictionary order" {
  // String::compare is length-first in moonbitlang/core; SQL ordering
  // needs lexicographic comparison
  assert_eq(String::compare("apple", "pear"), 1) // longer string wins there
  assert_eq(String::lexical_compare("apple", "pear"), -1)
}

///|
test "concat_batches copies live rows, not vector capacity" {
  // OutputBuilder::build hands out capacity-sized vectors (4096) with
  // only part of it filled; a partial last chunk used to overrun the
  // destination when copy_vec_range went by vector length
  let full_cols : Array[@types.ColumnVector] = [
    @types.ColumnVector::make(@types.Int32, 4096),
  ]
  let full = @types.DataBatch::new(full_cols, 4096)
  let partial_cols : Array[@types.ColumnVector] = [
    @types.ColumnVector::make(@types.Int32, 4096),
  ]
  let partial = @types.DataBatch::new(partial_cols, 100)
  for i in 0..<100 {
    partial.columns()[0].set(i, @types.Int32(i * 2))
  }
  let out = concat_batches([full, partial], [@types.Int32])
  assert_eq(out.row_count(), 4196)
  assert_eq(out.columns()[0].get(0), @types.Int32(0))
  assert_eq(out.columns()[0].get(4095), @types.Int32(0))
  assert_eq(out.columns()[0].get(4096), @types.Int32(0))
  assert_eq(out.columns()[0].get(4195), @types.Int32(198))
}
