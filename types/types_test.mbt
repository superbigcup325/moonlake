///|
/// Blackbox tests for the types package: dates, three-valued logic,
/// arithmetic and vectors.

///|
test "date parse and epoch round trip" {
  assert_eq(@types.parse_date("1970-01-01"), Some(0)) // epoch anchor
  assert_eq(@types.parse_date("2000-01-01"), Some(10957)) // known Unix epoch days
  assert_eq(@types.epoch_to_string(10957), "2000-01-01")
  let d = @types.parse_date("1996-03-13").unwrap()
  assert_eq(@types.epoch_to_string(d), "1996-03-13") // round trip
  assert_eq(@types.parse_date("1994-1-1"), None) // strict two digit month/day
  assert_eq(@types.parse_date("1994-13-01"), None) // bad month
  assert_eq(@types.parse_date("1994-02-29"), None) // not a leap year
  assert_eq(
    @types.parse_date("2000-02-29"),
    Some(@types.days_from_civil(2000, 2, 29)),
  )
  assert_eq(
    @types.parse_date("1995-01-01"),
    Some(@types.days_from_civil(1995, 1, 1)),
  )
  let (y, m, dd) = @types.civil_from_days(9133)
  assert_eq(@types.days_from_civil(y, m, dd), 9133)
}

///|
test "three valued logic" {
  let t : @types.Scalar = @types.Scalar::Boolean(true)
  let f : @types.Scalar = @types.Scalar::Boolean(false)
  let n : @types.Scalar = @types.Scalar::Null
  assert_eq(@types.Scalar::logic_and(n, f), @types.Scalar::Boolean(false)) // false dominates
  assert_eq(@types.Scalar::logic_and(n, t), @types.Scalar::Null)
  assert_eq(@types.Scalar::logic_or(n, t), @types.Scalar::Boolean(true)) // true dominates
  assert_eq(@types.Scalar::logic_or(n, f), @types.Scalar::Null)
  assert_eq(@types.Scalar::logic_not(n), @types.Scalar::Null)
  assert_eq(@types.Scalar::logic_not(t), @types.Scalar::Boolean(false))
}

///|
test "compare propagates null and orders values" {
  assert_eq(
    @types.Scalar::compare(@types.Scalar::Int32(1), @types.Scalar::Int32(2)),
    Some(-1),
  )
  assert_eq(
    @types.Scalar::compare(@types.Scalar::Int32(2), @types.Scalar::Int32(2)),
    Some(0),
  )
  assert_eq(
    @types.Scalar::compare(@types.Scalar::Null, @types.Scalar::Int32(2)),
    None,
  )
  assert_eq(
    @types.Scalar::compare(@types.Scalar::Date(100), @types.Scalar::Date(200)),
    Some(-1),
  )
  assert_eq(
    @types.Scalar::compare(@types.Scalar::Str("a"), @types.Scalar::Str("b")),
    Some(-1),
  )
  assert_eq(@types.CmpOp::Ge.apply(Some(0)), @types.Scalar::Boolean(true))
  assert_eq(@types.CmpOp::Lt.apply(None), @types.Scalar::Null)
}

///|
test "arith with null and division by zero" {
  assert_eq(
    @types.Scalar::arith(
      @types.Mul,
      @types.Float64(2.5),
      @types.Scalar::Float64(4.0),
    ),
    @types.Scalar::Float64(10.0),
  )
  assert_eq(
    @types.Scalar::arith(@types.Mul, @types.Null, @types.Scalar::Float64(4.0)),
    @types.Scalar::Null,
  )
  // division is DuckDB true division: always Float64, zero divisor is
  // IEEE inf/nan rather than an error or NULL
  assert_eq(
    @types.Scalar::arith(@types.Div, @types.Int32(1), @types.Scalar::Int32(0)),
    @types.Scalar::Float64(double_inf()),
  )
  assert_eq(
    @types.Scalar::arith(@types.Div, @types.Int32(5), @types.Scalar::Int32(2)),
    @types.Scalar::Float64(2.5),
  )
  assert_eq(
    @types.Scalar::arith(
      @types.Div,
      @types.Int64(-1L),
      @types.Scalar::Int64(0L),
    ),
    @types.Scalar::Float64(double_neg_inf()),
  )
  assert_true(
    @types.Scalar::arith(
      @types.Div,
      @types.Float64(0.0),
      @types.Scalar::Float64(0.0),
    )
    is @types.Float64(f) &&
    f.is_nan(),
  )
  // % is fmod: sign of the dividend, NULL on a zero divisor
  assert_eq(
    @types.Scalar::arith(@types.Mod, @types.Int32(-10), @types.Scalar::Int32(3)),
    @types.Scalar::Int32(-1),
  )
  assert_eq(
    @types.Scalar::arith(
      @types.Mod,
      @types.Float64(-10.5),
      @types.Scalar::Float64(3.0),
    ),
    @types.Scalar::Float64(-1.5),
  )
  assert_eq(
    @types.Scalar::arith(
      @types.Mod,
      @types.Float64(10.5),
      @types.Scalar::Float64(-3.0),
    ),
    @types.Scalar::Float64(1.5),
  )
  assert_eq(
    @types.Scalar::arith(
      @types.Mod,
      @types.Float64(10.5),
      @types.Scalar::Float64(0.0),
    ),
    @types.Scalar::Null,
  )
  assert_eq(
    @types.Scalar::arith(@types.Add, @types.Int32(1), @types.Scalar::Int32(2)),
    @types.Scalar::Int32(3),
  )
  assert_eq(
    @types.Scalar::arith(@types.Add, @types.Int64(1L), @types.Scalar::Int64(2L)),
    @types.Scalar::Int64(3L),
  )
}

///|
fn double_inf() -> Double {
  1.0 / 0.0
}

///|
fn double_neg_inf() -> Double {
  -1.0 / 0.0
}

///|
test "vector get set and validity" {
  let v : @types.ColumnVector = @types.ColumnVector::make(@types.Float64, 3)
  v.set(0, @types.Scalar::Float64(1.5))
  v.set(1, @types.Scalar::Null)
  v.set(2, @types.Scalar::Float64(3.25))
  assert_eq(v.len(), 3)
  assert_eq(v.dtype(), @types.Float64)
  assert_eq(v.get(0), @types.Scalar::Float64(1.5))
  assert_eq(v.get(1), @types.Scalar::Null)
  assert_eq(v.get(2), @types.Scalar::Float64(3.25))
  let d : @types.ColumnVector = @types.ColumnVector::make(@types.Date, 1)
  d.set(0, @types.Scalar::Date(@types.parse_date("1994-01-01").unwrap()))
  assert_eq(
    d.get(0),
    @types.Scalar::Date(@types.parse_date("1994-01-01").unwrap()),
  )
}

///|
/// MoonBit's `<`/`>` operators on String are NOT lexicographic (they
/// appear to follow literal-pool order); dictionary comparison must go
/// through String::compare. Scalar ordering depends on this.
test "scalar string comparison is lexicographic" {
  assert_eq(
    @types.Scalar::compare(@types.Str("apple"), @types.Str("pear")),
    Some(-1),
  )
  assert_eq(
    @types.Scalar::compare(@types.Str("pear"), @types.Str("apple")),
    Some(1),
  )
  assert_eq(
    @types.Scalar::compare(@types.Str("same"), @types.Str("same")),
    Some(0),
  )
  // the operators are not: document the trap right next to the fix
  assert_false("apple" < "pear")
}
