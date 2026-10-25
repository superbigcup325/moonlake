// Scalar comparison, arithmetic and three-valued logic.
// All helpers take/return Scalar and propagate Null per SQL semantics.

///|
/// Non-null total compare: -1|0|1, or 0 when the values do not compare
/// (binder guarantees matching types). Callers that pre-filter NULL —
/// sort comparators, min/max folds — use this instead of
/// Scalar::compare to avoid an Option allocation per comparison.
pub fn Scalar::compare_nn(a : Scalar, b : Scalar) -> Int32 {
  match (a, b) {
    (Int32(x), Int32(y)) => cmp_i(x, y)
    (Int64(x), Int64(y)) => if x < y { -1 } else if x > y { 1 } else { 0 }
    (Float64(x), Float64(y)) => if x < y { -1 } else if x > y { 1 } else { 0 }
    (Date(x), Date(y)) => cmp_i(x, y)
    (Str(x), Str(y)) => String::lexical_compare(x, y) // dictionary order
    (Boolean(x), Boolean(y)) =>
      match (x, y) {
        (false, true) => -1
        (true, false) => 1
        _ => 0
      }
    _ => 0
  }
}

///|
/// Three-valued comparison: Some(-1|0|1), or None when either side is Null
/// or the types do not compare (binder guarantees matching types).
pub fn Scalar::compare(a : Scalar, b : Scalar) -> Int32? {
  match (a, b) {
    (Int32(x), Int32(y)) => Some(cmp_i(x, y))
    (Int64(x), Int64(y)) =>
      if x < y {
        Some(-1)
      } else if x > y {
        Some(1)
      } else {
        Some(0)
      }
    (Float64(x), Float64(y)) =>
      if x < y {
        Some(-1)
      } else if x > y {
        Some(1)
      } else {
        Some(0)
      }
    (Date(x), Date(y)) => Some(cmp_i(x, y))
    (Str(x), Str(y)) => Some(String::lexical_compare(x, y)) // dictionary order (String::compare is length-first)
    (Boolean(x), Boolean(y)) =>
      match (x, y) {
        (false, true) => Some(-1)
        (true, false) => Some(1)
        _ => Some(0)
      }
    _ => None
  }
}

///|
fn cmp_i(x : Int32, y : Int32) -> Int32 {
  if x < y {
    -1
  } else if x > y {
    1
  } else {
    0
  }
}

///|
/// Arithmetic with NULL propagation. Operand types must match (binder
/// inserts Promote nodes to unify them beforehand). Division follows
/// DuckDB: `/` is true division and always yields Float64 (the binder
/// promotes both sides), so a zero divisor is IEEE ±inf (0/0 is nan),
/// not an error; `%` is C fmod — the result takes the dividend's sign —
/// and `x % 0` is NULL.
///
/// Integer add/sub/mul WRAP here (two's complement). This non-raising helper
/// is what keeps that contract available; the executor does not use it — it
/// evaluates through `arith_checked`, which turns the wrap into an error,
/// because a wrapped value is a wrong number a query never asked for.
pub fn Scalar::arith(op : ArithOp, a : Scalar, b : Scalar) -> Scalar {
  match (op, a, b) {
    (Add, Int32(x), Int32(y)) => Int32(x + y)
    (Sub, Int32(x), Int32(y)) => Int32(x - y)
    (Mul, Int32(x), Int32(y)) => Int32(x * y)
    (Div, Int32(x), Int32(y)) => Float64(x.to_double() / y.to_double())
    (Mod, Int32(x), Int32(y)) => if y == 0 { Null } else { Int32(x % y) }
    (Add, Int64(x), Int64(y)) => Int64(x + y)
    (Sub, Int64(x), Int64(y)) => Int64(x - y)
    (Mul, Int64(x), Int64(y)) => Int64(x * y)
    (Div, Int64(x), Int64(y)) => Float64(x.to_double() / y.to_double())
    (Mod, Int64(x), Int64(y)) => if y == 0L { Null } else { Int64(x % y) }
    (Add, Float64(x), Float64(y)) => Float64(x + y)
    (Sub, Float64(x), Float64(y)) => Float64(x - y)
    (Mul, Float64(x), Float64(y)) => Float64(x * y)
    (Div, Float64(x), Float64(y)) => Float64(x / y)
    (Mod, Float64(x), Float64(y)) =>
      if y == 0.0 {
        Null
      } else {
        Float64(x - y * (x / y).trunc())
      }
    _ => Null // mismatched or Null operands, or Date arithmetic (v1: unsupported)
  }
}

///|
/// Integer arithmetic that refuses to wrap: the result is computed in Int64
/// (lossless for Int32) and the dtype picks the range it must stay in. Wrap is
/// not a number a query can mean — `2147483647 + 1` answering -2147483648 is a
/// silent wrong answer, and `sum()` already raises where it would overflow — so
/// the executor raises the way DuckDB does instead of returning the wrap.
/// Non-integer operators do not belong here: they go through `arith`.
pub fn int_arith_checked(
  op : ArithOp,
  dt : DataType,
  x : Int64,
  y : Int64,
) -> Int64 raise SqlError {
  let (value, wrapped) = match op {
    Add => {
      let s = x + y
      (s, (y > 0L && s < x) || (y < 0L && s > x))
    }
    Sub => {
      let d = x - y
      (d, (y > 0L && d > x) || (y < 0L && d < x))
    }
    Mul =>
      if x == 0L || y == 0L {
        (0L, false)
      } else if (x == -1L && y == -9223372036854775808L) ||
        (y == -1L && x == -9223372036854775808L) {
        // the one product a division cannot verify: it wraps to the minimum
        // and Int64 has no minimum/-1 quotient to divide back with
        (0L, true)
      } else {
        let p = x * y
        (p, p / x != y)
      }
    _ =>
      raise SqlError::Execute(
        "integer arithmetic called with a non-integer operator",
      )
  }
  if wrapped {
    raise int_overflow(op, dt)
  }
  match dt {
    Int32 =>
      if value < -2147483648L || value > 2147483647L {
        raise int_overflow(op, dt)
      }
    _ => ()
  }
  value
}

///|
fn int_overflow(op : ArithOp, dt : DataType) -> SqlError {
  let target = match dt {
    Int32 => "int32"
    Int64 => "int64"
    _ => "integer"
  }
  let symbol = match op {
    Add => "+"
    Sub => "-"
    Mul => "*"
    _ => "?"
  }
  SqlError::Execute(
    "integer overflow: \{target} \{symbol} left the \{target} range (cast an operand to float64 to keep going)",
  )
}

///|
/// `Scalar::arith` with the integer cases checked: identical results for every
/// in-range value, and an Execute error where `arith` would wrap.
pub fn Scalar::arith_checked(
  op : ArithOp,
  a : Scalar,
  b : Scalar,
) -> Scalar raise SqlError {
  match (op, a, b) {
    (Add | Sub | Mul, Int32(x), Int32(y)) =>
      Int32(int_arith_checked(op, Int32, x.to_int64(), y.to_int64()).to_int())
    (Add | Sub | Mul, Int64(x), Int64(y)) =>
      Int64(int_arith_checked(op, Int64, x, y))
    _ => Scalar::arith(op, a, b)
  }
}

///|
/// Three-valued AND: false dominates.
pub fn Scalar::logic_and(a : Scalar, b : Scalar) -> Scalar {
  match (a, b) {
    (Boolean(false), _) | (_, Boolean(false)) => Boolean(false)
    (Boolean(true), Boolean(true)) => Boolean(true)
    _ => Null
  }
}

///|
/// Three-valued OR: true dominates.
pub fn Scalar::logic_or(a : Scalar, b : Scalar) -> Scalar {
  match (a, b) {
    (Boolean(true), _) | (_, Boolean(true)) => Boolean(true)
    (Boolean(false), Boolean(false)) => Boolean(false)
    _ => Null
  }
}

///|
pub fn Scalar::logic_not(a : Scalar) -> Scalar {
  match a {
    Boolean(b) => Boolean(!b)
    _ => Null
  }
}
