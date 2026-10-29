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

///|
test "the fast-path key index groups ids without a list per key" {
  // rows 0..7 over keys: 7, 7, 9, 7, (null), 9, 11, 7
  let bd : FixedArray[Int64] = FixedArray::make(8, 0L)
  let bv : FixedArray[Bool] = FixedArray::make(8, true)
  let keys = [7L, 7L, 9L, 7L, 0L, 9L, 11L, 7L]
  let valid = [true, true, true, true, false, true, true, true]
  for i in 0..<8 {
    bd[i] = keys[i]
    bv[i] = valid[i]
  }
  let index = IntKeyIndex::build(bd, bv, 8)
  // three distinct keys, and every valid row appears exactly once: the ids
  // array is the row count, not a padded per-key list
  assert_eq(index.starts.length(), 4)
  assert_eq(index.ids.length(), 7)
  // each slot's ids are contiguous and in ascending row order
  for slot in 0..<(index.starts.length() - 1) {
    let from = index.starts[slot]
    let to = index.starts[slot + 1]
    assert_true(from < to)
    for j in (from + 1)..<to {
      assert_true(index.ids[j - 1] < index.ids[j])
    }
  }
  // key 7 has four rows (0, 1, 3, 7) and key 11 has one (6)
  let seven = index.slots.get(7L).unwrap()
  assert_eq(index.starts[seven + 1] - index.starts[seven], 4)
  let eleven = index.slots.get(11L).unwrap()
  assert_eq(index.starts[eleven + 1] - index.starts[eleven], 1)
  assert_eq(index.ids[index.starts[eleven]], 6)
}

///|
test "the fast-path key index of an empty side has no slots and no ids" {
  let index = IntKeyIndex::build(
    FixedArray::make(0, 0L),
    FixedArray::make(0, true),
    0,
  )
  assert_eq(index.starts.length(), 1)
  assert_eq(index.ids.length(), 0)
  assert_eq(index.slots.get(1L), None)
}
