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
  let out = order_limit(batch, [(0, false)], None)
  assert_eq(out.row_count(), 8)
  assert_eq(out.columns()[0].get(0), @types.Str("apple"))
  assert_eq(out.columns()[0].get(1), @types.Str("apricot"))
  assert_eq(out.columns()[0].get(7), @types.Str("pear"))
}

///|
test "order_limit sorts desc with limit" {
  let batch = str_batch(["a", "c", "b"])
  let out = order_limit(batch, [(0, true)], Some(2))
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
