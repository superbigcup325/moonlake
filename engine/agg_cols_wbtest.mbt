// The column-wise fold for one integer key against the general fold. A spec
// list with a `max` in it takes the general path, so the same batches answer
// both ways and the shared columns must agree cell for cell.

///|
fn cols_spec(
  kind : AggKind,
  input : PhysExpr?,
  out : @types.DataType,
) -> AggSpec {
  { kind, input, out_type: out, sep: None, q: None, }
}

///|
fn cols_specs() -> Array[AggSpec] {
  let v = PhysExpr::ColRef(2, @types.Int32)
  [
    cols_spec(Sum, Some(v), @types.Int64),
    cols_spec(Sum, Some(v), @types.Float64),
    cols_spec(Count, Some(v), @types.Int64),
    cols_spec(CountStar, None, @types.Int64),
  ]
}

///|
fn cols_run(
  batches : Array[@types.DataBatch],
  key : PhysExpr,
  key_type : @types.DataType,
  aggs : Array[AggSpec],
) -> @types.DataBatch {
  aggregate(batches, [key], [key_type], aggs) catch {
    e => abort("aggregate failed: \{e}")
  }
}

///|
test "the column-wise fold takes one integer key over sums and counts only" {
  let aggs = cols_specs()
  assert_true(col_agg_plan([@types.Int32], aggs) is Some(_))
  assert_true(col_agg_plan([@types.Int64], aggs) is Some(_))
  assert_true(col_agg_plan([@types.Str], aggs) is None)
  assert_true(col_agg_plan([@types.Int32, @types.Int32], aggs) is Some(_))
  assert_true(col_agg_plan([@types.Int32, @types.Int64], aggs) is None)
  assert_true(
    col_agg_plan([@types.Int32, @types.Int32, @types.Int32], aggs) is None,
  )
  let max = cols_spec(
    Max,
    Some(PhysExpr::ColRef(2, @types.Int32)),
    @types.Int32,
  )
  assert_true(col_agg_plan([@types.Int32], [aggs[0], max]) is None)
  assert_true(col_agg_plan([@types.Int32], []) is None)
}

///|
test "the column-wise fold answers as the general fold does" {
  let aggs = cols_specs()
  let general = aggs.copy()
  general.push(
    cols_spec(Max, Some(PhysExpr::ColRef(2, @types.Int32)), @types.Int32),
  )
  let key = PhysExpr::ColRef(1, @types.Int32)
  let fast = cols_run(agg_batches(), key, @types.Int32, aggs)
  let slow = cols_run(agg_batches(), key, @types.Int32, general)
  assert_eq(fast.row_count(), slow.row_count())
  assert_eq(fast.row_count(), 3) // keys 1, null, 2 in first-seen order
  for c in 0..<5 {
    for r in 0..<fast.row_count() {
      assert_eq(
        fast.columns()[c].get(r).to_string(),
        slow.columns()[c].get(r).to_string(),
      )
    }
  }
}

///|
test "the column-wise fold keeps an all-NULL sum NULL on an Int64 key" {
  // key 5 only ever sees NULL inputs: its sums are NULL, its counts 0 and 2
  let k = @types.ColumnVector::make(@types.Int64, 4)
  let v = @types.ColumnVector::make(@types.Int32, 4)
  let ks : Array[@types.Scalar] = [
    @types.Int64(5L),
    @types.Int64(9000000000L),
    @types.Int64(5L),
    @types.Int64(9000000000L),
  ]
  let vs : Array[@types.Scalar] = [
    @types.Null,
    @types.Int32(4),
    @types.Null,
    @types.Int32(6),
  ]
  for i in 0..<4 {
    k.set(i, ks[i])
    v.set(i, vs[i])
  }
  let batch = @types.DataBatch::new([k, k, v], 4)
  let out = cols_run(
    [batch],
    PhysExpr::ColRef(0, @types.Int64),
    @types.Int64,
    cols_specs(),
  )
  assert_eq(out.row_count(), 2)
  assert_eq(
    out.columns()[0].get(1).to_string(),
    @types.Scalar::Int64(9000000000L).to_string(),
  )
  assert_true(out.columns()[1].get(0) is @types.Null)
  assert_true(out.columns()[2].get(0) is @types.Null)
  assert_eq(
    out.columns()[3].get(0).to_string(),
    @types.Scalar::Int64(0L).to_string(),
  )
  assert_eq(
    out.columns()[4].get(0).to_string(),
    @types.Scalar::Int64(2L).to_string(),
  )
  assert_eq(
    out.columns()[1].get(1).to_string(),
    @types.Scalar::Int64(10L).to_string(),
  )
}

///|
test "the column-wise fold reports an int64 sum overflow" {
  let k = @types.ColumnVector::make(@types.Int32, 2)
  let v = @types.ColumnVector::make(@types.Int64, 2)
  for i in 0..<2 {
    k.set(i, @types.Int32(1))
    v.set(i, @types.Int64(9223372036854775807L))
  }
  let batch = @types.DataBatch::new([k, v], 2)
  let spec = cols_spec(
    Sum,
    Some(PhysExpr::ColRef(1, @types.Int64)),
    @types.Int64,
  )
  let mut raised = false
  let _ = aggregate(
    [batch],
    [PhysExpr::ColRef(0, @types.Int32)],
    [@types.Int32],
    [spec],
  ) catch {
    @types.SqlError::Execute(msg) => {
      raised = msg.contains("overflows int64")
      batch
    }
    _ => batch
  }
  assert_true(raised)
}

///|
test "the column-wise fold of an empty input has no groups" {
  let out = cols_run(
    [],
    PhysExpr::ColRef(1, @types.Int32),
    @types.Int32,
    cols_specs(),
  )
  assert_eq(out.row_count(), 0)
  assert_eq(out.columns().length(), 5)
}

///|
test "the column-wise fold of two Int32 keys answers as the general fold does" {
  let aggs = cols_specs()
  let general = aggs.copy()
  general.push(
    cols_spec(Max, Some(PhysExpr::ColRef(2, @types.Int32)), @types.Int32),
  )
  let keys = [
    PhysExpr::ColRef(1, @types.Int32),
    PhysExpr::ColRef(2, @types.Int32),
  ]
  let types : Array[@types.DataType] = [
    @types.DataType::Int32,
    @types.DataType::Int32,
  ]
  let fast = aggregate(agg_batches(), keys, types, aggs) catch {
    e => abort("aggregate failed: \{e}")
  }
  let slow = aggregate(agg_batches(), keys, types, general) catch {
    e => abort("aggregate failed: \{e}")
  }
  assert_eq(fast.row_count(), slow.row_count())
  assert_true(fast.row_count() > 3)
  for c in 0..<6 {
    for r in 0..<fast.row_count() {
      assert_eq(
        fast.columns()[c].get(r).to_string(),
        slow.columns()[c].get(r).to_string(),
      )
    }
  }
}

///|
test "the column-wise fold of two Int32 keys keeps signs and NULL patterns apart" {
  let a = @types.ColumnVector::make(@types.Int32, 7)
  let b = @types.ColumnVector::make(@types.Int32, 7)
  let av : Array[@types.Scalar] = [
    @types.Int32(-1),
    @types.Int32(1),
    @types.Int32(-1),
    @types.Int32(0),
    @types.Null,
    @types.Int32(1),
    @types.Null,
  ]
  let bv : Array[@types.Scalar] = [
    @types.Int32(1),
    @types.Int32(-1),
    @types.Int32(1),
    @types.Int32(0),
    @types.Int32(1),
    @types.Null,
    @types.Int32(1),
  ]
  for i in 0..<7 {
    a.set(i, av[i])
    b.set(i, bv[i])
  }
  let batch = @types.DataBatch::new([a, b], 7)
  let spec = cols_spec(CountStar, None, @types.Int64)
  let out = aggregate(
    [batch],
    [PhysExpr::ColRef(0, @types.Int32), PhysExpr::ColRef(1, @types.Int32)],
    [@types.Int32, @types.Int32],
    [spec],
  ) catch {
    e => abort("aggregate failed: \{e}")
  }
  // (-1,1) x2, (1,-1), (0,0), (NULL,1) x2, (1,NULL), in first-seen order
  assert_eq(out.row_count(), 5)
  let counts = [2L, 1L, 1L, 2L, 1L]
  for r in 0..<5 {
    assert_eq(
      out.columns()[2].get(r).to_string(),
      @types.Scalar::Int64(counts[r]).to_string(),
    )
  }
  assert_true(out.columns()[0].get(3) is @types.Null)
  assert_true(out.columns()[1].get(4) is @types.Null)
  assert_eq(
    out.columns()[0].get(0).to_string(),
    @types.Scalar::Int32(-1).to_string(),
  )
  assert_eq(
    out.columns()[1].get(1).to_string(),
    @types.Scalar::Int32(-1).to_string(),
  )
}
