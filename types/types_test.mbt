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

///|
test "integer parsing is range-checked, never wrapping" {
  // boundaries stay exact
  assert_eq(@types.parse_i64("9223372036854775807"), Some(9223372036854775807L))
  assert_eq(
    @types.parse_i64("-9223372036854775808"),
    Some(-9223372036854775808L),
  )
  assert_eq(@types.parse_i64("-9223372036854775809"), None)
  assert_eq(@types.parse_i64("9223372036854775808"), None)
  assert_eq(@types.parse_i64("99999999999999999999"), None)
  assert_eq(@types.parse_i32("2147483647"), Some(2147483647))
  assert_eq(@types.parse_i32("-2147483648"), Some(-2147483648))
  // out of int32 range: None, not a wrapped negative
  assert_eq(@types.parse_i32("2147483648"), None)
  assert_eq(@types.parse_i32("-2147483649"), None)
  // junk and sign-only inputs
  assert_eq(@types.parse_i64("-"), None)
  assert_eq(@types.parse_i64("+"), None)
  assert_eq(@types.parse_i64(""), None)
  assert_eq(@types.parse_i64("12x"), None)
}

///|
test "parse_f64 keeps 20-digit integers exact" {
  // 2^63: the decimal accumulator used to land on a neighbor double
  assert_eq(
    @types.parse_f64("9223372036854775808"),
    Some(9223372036854775808.0),
  )
  assert_eq(
    @types.parse_f64("-9223372036854775808"),
    Some(-9223372036854775808.0),
  )
  // uint64 max rounds to the nearest representable double, 2^64
  assert_eq(
    @types.parse_f64("18446744073709551615"),
    Some(18446744073709551616.0),
  )
  // beyond uint64: the accumulator's 1e-9 relative contract still holds
  let v = @types.parse_f64("99999999999999999999")
  match v {
    Some(x) => assert_true(x > 0.99999999e20 && x < 1.00000001e20)
    None => fail("expected a value")
  }
  // small integers stay exact too
  assert_eq(@types.parse_f64("42"), Some(42.0))
}

///|
test "parse_f64 takes the whole double range, non-finite spellings included" {
  // a CSV float column and CAST(... AS DOUBLE) both hold NaN and infinities;
  // the parser used to reject every spelling, which made a valid float column
  // infer as STRING and a cast of "NaN" an error
  for text in ["nan", "NaN", "NAN", "-nan"] {
    match @types.parse_f64(text) {
      Some(x) => assert_true(x.is_nan())
      None => fail("\{text} should parse as nan")
    }
  }
  for text in ["inf", "Infinity", "INFINITY"] {
    match @types.parse_f64(text) {
      Some(x) => assert_true(x > 1.0e308)
      None => fail("\{text} should parse as +inf")
    }
  }
  match @types.parse_f64("-inf") {
    Some(x) => assert_true(x < -1.0e308)
    None => fail("-inf should parse")
  }
  // the exponent range is the double range: no 300 cutoff on the way in, inf
  // past 1e308, subnormals kept, 0 past the smallest subnormal
  match @types.parse_f64("1e307") {
    Some(x) => assert_true(x > 0.999999999e307 && x < 1.000000001e307)
    None => fail("1e307 should parse")
  }
  match @types.parse_f64("1e309") {
    Some(x) => assert_true(x > 1.0e308)
    None => fail("1e309 should overflow to inf")
  }
  match @types.parse_f64("1e999999999999") {
    Some(x) => assert_true(x > 1.0e308)
    None => fail("an absurd exponent should be inf, not an error")
  }
  assert_eq(@types.parse_f64("0e999"), Some(0.0))
  match @types.parse_f64("1e-309") {
    // below 1e-308 the value is subnormal: answering 0 would lose the value
    Some(x) => assert_true(x > 0.0 && x < 1.0e-308)
    None => fail("1e-309 should parse as a subnormal")
  }
  assert_eq(@types.parse_f64("1e-400"), Some(0.0))
  assert_eq(@types.parse_f64("nanna"), None)
  assert_eq(@types.parse_f64("1e"), None)
}

///|
/// The error `arith_checked` raises; a test fails when an overflow wraps.
fn arith_err(
  op : @types.ArithOp,
  a : @types.Scalar,
  b : @types.Scalar,
) -> String {
  let _ = @types.Scalar::arith_checked(op, a, b) catch {
    e => return e.to_string()
  }
  abort("expected an integer overflow error")
}

///|
test "checked integer arithmetic refuses to wrap; arith still wraps" {
  let add = @types.Add
  let sub = @types.Sub
  let mul = @types.Mul
  let max = @types.Scalar::Int32(2147483647)
  // in-range results are identical to arith's, the boundary included
  let min = @types.Scalar::Int32(-2147483648)
  assert_eq(
    @types.Scalar::arith_checked(add, @types.Int32(2147483646), @types.Int32(1)) catch {
      e => abort("\{e}")
    },
    max,
  )
  assert_eq(
    @types.Scalar::arith_checked(
      mul,
      @types.Int32(-2147483648),
      @types.Int32(1),
    ) catch {
      e => abort("\{e}")
    },
    min,
  )
  // the wrap positions raise, with the type and the operator in the message
  assert_true(arith_err(add, max, @types.Int32(1)).contains("int32 +"))
  assert_true(arith_err(sub, min, @types.Int32(1)).contains("int32 -"))
  assert_true(
    arith_err(mul, @types.Int32(2000000000), @types.Int32(2)).contains(
      "int32 *",
    ),
  )
  // an int32 product that only overflows past int32 is caught by the range
  assert_true(arith_err(mul, min, @types.Int32(-1)).contains("int32 *"))
  assert_true(
    arith_err(add, @types.Int64(9223372036854775807L), @types.Int64(1L)).contains(
      "int64 +",
    ),
  )
  assert_true(
    arith_err(sub, @types.Int64(-9223372036854775808L), @types.Int64(1L)).contains(
      "int64 -",
    ),
  )
  // the one product a division cannot verify back
  assert_true(
    arith_err(mul, @types.Int64(-9223372036854775808L), @types.Int64(-1L)).contains(
      "int64 *",
    ),
  )
  // non-integer operators and the Float64 path are untouched
  let div = @types.Scalar::arith_checked(
    @types.Div,
    @types.Int32(1),
    @types.Int32(0),
  ) catch {
    e => abort("\{e}")
  }
  match div {
    @types.Float64(x) => assert_true(x > 1.0e308)
    other => fail("expected +inf, got \{other.to_string()}")
  }
  // Scalar::arith keeps its documented wrapping contract
  assert_eq(
    @types.Scalar::arith(add, max, @types.Int32(1)),
    @types.Int32(-2147483648),
  )
  // int_arith_checked is the Int64 core both paths share: same error there
  assert_eq(
    @types.int_arith_checked(sub, @types.Int64, 5L, 3L) catch {
      e => abort("\{e}")
    },
    2L,
  )
}

///|
test "str_cell_bytes counts what the budget unit counts" {
  // a valid cell costs its four proxy bytes plus the characters, a NULL one byte
  let valid = FixedArray::make(3, true)
  let nulls = FixedArray::make(3, true)
  nulls[1] = false
  let col = @types.StrV(FixedArray::from_array(["ab", "", "ccc"]), valid)
  assert_eq(col.str_cell_bytes(), 4 + 2 + (4 + 0) + (4 + 3)) // 17
  let with_null = @types.StrV(
    FixedArray::from_array(["ab", "zz", "ccc"]),
    nulls,
  )
  assert_eq(with_null.str_cell_bytes(), 6 + 1 + 7) // the NULL slot costs one byte
  assert_eq(
    @types.I32(FixedArray::make(2, 1), FixedArray::make(2, true)).str_cell_bytes(),
    0,
  )
}
