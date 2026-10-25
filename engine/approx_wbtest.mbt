// The sketch accumulator from the inside: the canonical form it feeds the
// sketch, the rounding of an estimate, and the error a non-finite quantile
// input turns into (the fold cannot raise, so the finish step must).

///|
fn approx_spec(kind : AggKind, q : Double?) -> AggSpec {
  { kind, input: None, out_type: @types.Float64, sep: None, q, }
}

///|
fn distinct_estimate(values : Array[@types.Scalar]) -> Int64 {
  let spec = approx_spec(ApproxCountDistinct, None)
  let acc = new_accs([spec])[0]
  for v in values {
    acc_step(acc, spec, v)
  }
  let finished : @types.Scalar = acc_finish(acc, spec) catch {
    e => abort("distinct estimate failed: \{e}")
  }
  match finished {
    @types.Int64(n) => n
    other => abort("expected an int64 estimate, got \{other.to_string()}")
  }
}

///|
test "the distinct sketch treats signed zero as one value" {
  // the exact path compares their text form, which is "0" for both
  let n = distinct_estimate([
    @types.Float64(-0.0),
    @types.Float64(0.0),
    @types.Float64(2.0),
  ])
  assert_true(n >= 1L && n <= 3L)
  assert_eq(distinct_estimate([@types.Float64(-0.0), @types.Float64(0.0)]), 1L)
}

///|
test "the distinct sketch hashes every NaN payload to one canonical value" {
  let a = 0x7FF8000000000001L.reinterpret_as_double()
  let b = 0x7FF8000000000002L.reinterpret_as_double()
  let c = 0xFFF8000000000001L.reinterpret_as_double()
  assert_true(a.is_nan() && b.is_nan() && c.is_nan())
  assert_eq(distinct_estimate([@types.Float64(a), @types.Float64(b)]), 1L)
  assert_eq(distinct_estimate([@types.Float64(a), @types.Float64(c)]), 1L)
}

///|
test "the distinct sketch keeps int32 and int64 apart, as the exact key does" {
  // the exact path tags its keys by type, so these are two values
  assert_eq(distinct_estimate([@types.Int32(7), @types.Int64(7L)]), 2L)
}

///|
test "the distinct sketch folds strings, booleans and dates" {
  assert_eq(
    distinct_estimate([@types.Str("a"), @types.Str("a"), @types.Str("b")]),
    2L,
  )
  assert_eq(
    distinct_estimate([@types.Boolean(true), @types.Boolean(false)]),
    2L,
  )
  assert_eq(
    distinct_estimate([@types.Date(1), @types.Date(1), @types.Date(2)]),
    2L,
  )
}

///|
test "a distinct estimate rounds to the nearest integer and never goes below zero" {
  assert_eq(hll_round(0.0), 0L)
  assert_eq(hll_round(-3.0), 0L)
  assert_eq(hll_round(0.4), 0L)
  assert_eq(hll_round(0.6), 1L)
  assert_eq(hll_round(12.5), 13L)
}

///|
test "a non-finite quantile input fails the query at the finish step" {
  let spec = approx_spec(ApproxQuantile, Some(0.5))
  let acc = new_accs([spec])[0]
  acc_step(acc, spec, @types.Float64(1.0))
  acc_step(
    acc,
    spec,
    @types.Float64(0x7FF8000000000001L.reinterpret_as_double()),
  )
  let err = try {
    ignore(acc_finish(acc, spec))
    abort("expected an error")
  } catch {
    e => e
  }
  assert_true(err.to_string().contains("finite"))
}

///|
test "an empty quantile accumulator answers NULL" {
  let spec = approx_spec(ApproxQuantile, Some(0.5))
  let acc = new_accs([spec])[0]
  assert_eq(acc_finish(acc, spec), @types.Null)
}
