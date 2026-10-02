// Scalar comparison, arithmetic and three-valued logic.
// All helpers take/return Scalar and propagate Null per SQL semantics.

///|
/// Three-valued comparison: Some(-1|0|1), or None when either side is Null
/// or the types do not compare (binder guarantees matching types).
pub fn Scalar::compare(a : Scalar, b : Scalar) -> Int? {
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
fn cmp_i(x : Int, y : Int) -> Int {
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
