// Vectorized expression evaluation: a PhysExpr over a whole DataBatch
// produces a ColumnVector in one typed pass instead of per-row Scalar
// boxing. Typed kernels cover the hot shapes (column refs, constants,
// same-type arithmetic and comparison, three-valued logic); every other
// shape falls back to eval_scalar row by row. Semantics must mirror
// eval_with exactly — the differential tests pin the two paths together.

///|
pub fn eval_vec(e : PhysExpr, batch : @types.DataBatch) -> @types.ColumnVector {
  let n = batch.row_count()
  match e {
    ColRef(i, _) => batch.columns()[i] // shared reference, never mutated
    Const(v) => broadcast(v, n)
    Promote(inner, dt) => {
      let v = eval_vec(inner, batch)
      match promote_vec(v, dt) {
        Some(out) => out
        None => fallback(e, batch)
      }
    }
    ArithE(op, l, r, dt) => {
      let lv = eval_vec(l, batch)
      let rv = eval_vec(r, batch)
      match arith_vec(op, lv, rv, dt) {
        Some(out) => out
        None => fallback(e, batch)
      }
    }
    CmpE(op, l, r) => {
      let lv = eval_vec(l, batch)
      let rv = eval_vec(r, batch)
      match cmp_vec(op, lv, rv) {
        Some(out) => out
        None => fallback(e, batch)
      }
    }
    AndE(l, r) => {
      let lv = eval_vec(l, batch)
      let rv = eval_vec(r, batch)
      match logic_vec(false, lv, rv) {
        Some(out) => out
        None => fallback(e, batch)
      }
    }
    OrE(l, r) => {
      let lv = eval_vec(l, batch)
      let rv = eval_vec(r, batch)
      match logic_vec(true, lv, rv) {
        Some(out) => out
        None => fallback(e, batch)
      }
    }
    NotE(inner) => {
      let v = eval_vec(inner, batch)
      match v {
        @types.BoolV(d, valid) => {
          let od : FixedArray[Bool] = FixedArray::make(n, false)
          let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
          for i in 0..<n {
            if valid[i] {
              od[i] = !d[i]
              ovalid[i] = true
            }
          }
          @types.BoolV(od, ovalid)
        }
        _ => fallback(e, batch)
      }
    }
    IsNullE(inner, negated) => {
      let iv = v_validity(eval_vec(inner, batch))
      let od : FixedArray[Bool] = FixedArray::make(n, false)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, true)
      for i in 0..<n {
        od[i] = if iv[i] { negated } else { !negated }
      }
      @types.BoolV(od, ovalid)
    }
    _ => fallback(e, batch)
  }
}

///|
/// Per-row fallback: the exact scalar interpreter, one boxed cell at a
/// time. dt comes from the expression shape itself.
fn fallback(e : PhysExpr, batch : @types.DataBatch) -> @types.ColumnVector {
  let n = batch.row_count()
  let vec = @types.ColumnVector::make(expr_dtype(e), n)
  for r in 0..<n {
    vec.set(r, eval_scalar(e, batch, r))
  }
  vec
}

///|
/// The output type the binder declared for this expression shape.
fn expr_dtype(e : PhysExpr) -> @types.DataType {
  match e {
    ColRef(_, dt) => dt
    Const(v) => scalar_type(v)
    Promote(_, dt) => dt
    ArithE(_, _, _, dt) => dt
    CmpE(_, _, _) => @types.Bool
    AndE(_, _) => @types.Bool
    OrE(_, _) => @types.Bool
    NotE(_) => @types.Bool
    LikeE(_, _) => @types.Bool
    IsNullE(_, _) => @types.Bool
    ExtractE(_, _) => @types.Int32
    InSetE(_, _, _, _) => @types.Bool
    CaseE(_, _, dt) => dt
  }
}

///|
fn broadcast(v : @types.Scalar, n : Int) -> @types.ColumnVector {
  let vec = @types.ColumnVector::make(scalar_type(v), n)
  for i in 0..<n {
    vec.set(i, v)
  }
  vec
}

///|
/// The validity array of any vector (NULL slots read as false).
fn v_validity(v : @types.ColumnVector) -> FixedArray[Bool] {
  match v {
    @types.I32(_, valid) => valid
    @types.I64(_, valid) => valid
    @types.F64(_, valid) => valid
    @types.BoolV(_, valid) => valid
    @types.StrV(_, valid) => valid
    @types.DateV(_, valid) => valid
  }
}

///|
fn ord_i(x : Int, y : Int) -> Int {
  if x < y {
    -1
  } else if x > y {
    1
  } else {
    0
  }
}

///|
/// Typed promotion; None falls back. The binder only emits the three
/// widening pairs below; identity promotions are zero-copy here.
fn promote_vec(
  v : @types.ColumnVector,
  dt : @types.DataType,
) -> @types.ColumnVector? {
  if v.dtype() == dt {
    return Some(v)
  }
  let n = v.len()
  match (v, dt) {
    (@types.I32(d, valid), @types.Int64) => {
      let od : FixedArray[Int64] = FixedArray::make(n, 0L)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for i in 0..<n {
        od[i] = d[i].to_int64()
        ovalid[i] = valid[i]
      }
      Some(@types.I64(od, ovalid))
    }
    (@types.I32(d, valid), @types.Float64) => {
      let od : FixedArray[Double] = FixedArray::make(n, 0.0)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for i in 0..<n {
        od[i] = d[i].to_double()
        ovalid[i] = valid[i]
      }
      Some(@types.F64(od, ovalid))
    }
    (@types.I64(d, valid), @types.Float64) => {
      let od : FixedArray[Double] = FixedArray::make(n, 0.0)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for i in 0..<n {
        od[i] = d[i].to_double()
        ovalid[i] = valid[i]
      }
      Some(@types.F64(od, ovalid))
    }
    _ => None
  }
}

///|
/// Same-type arithmetic in one loop. Mirrors Scalar::arith: Int32
/// add/sub/mul wrap, % is NULL on a zero divisor, / is always DOUBLE
/// with IEEE infinities, Float64 % is fmod (dividend's sign). None
/// falls back (mismatched operand dtypes never reach the executor —
/// the binder inserts Promote — but staying safe costs nothing).
fn arith_vec(
  op : @types.ArithOp,
  l : @types.ColumnVector,
  r : @types.ColumnVector,
  dt : @types.DataType,
) -> @types.ColumnVector? {
  let n = l.len()
  match (l, r) {
    (@types.I32(ld, lv), @types.I32(rd, rv)) => {
      let is_f64 = dt is @types.Float64
      let od : FixedArray[Int] = FixedArray::make(n, 0)
      let ofd : FixedArray[Double] = FixedArray::make(n, 0.0)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for i in 0..<n {
        if lv[i] && rv[i] {
          ovalid[i] = true
          match op {
            Add => od[i] = ld[i] + rd[i]
            Sub => od[i] = ld[i] - rd[i]
            Mul => od[i] = ld[i] * rd[i]
            Mod =>
              if rd[i] == 0 {
                ovalid[i] = false
              } else {
                od[i] = ld[i] % rd[i]
              }
            Div => ofd[i] = ld[i].to_double() / rd[i].to_double()
          }
        }
      }
      if is_f64 {
        Some(@types.F64(ofd, ovalid))
      } else if op is @types.Div {
        None // int/int must yield Float64; dt says otherwise: fall back
      } else {
        Some(@types.I32(od, ovalid))
      }
    }
    (@types.I64(ld, lv), @types.I64(rd, rv)) => {
      let is_f64 = dt is @types.Float64
      let od : FixedArray[Int64] = FixedArray::make(n, 0L)
      let ofd : FixedArray[Double] = FixedArray::make(n, 0.0)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for i in 0..<n {
        if lv[i] && rv[i] {
          ovalid[i] = true
          match op {
            Add => od[i] = ld[i] + rd[i]
            Sub => od[i] = ld[i] - rd[i]
            Mul => od[i] = ld[i] * rd[i]
            Mod =>
              if rd[i] == 0L {
                ovalid[i] = false
              } else {
                od[i] = ld[i] % rd[i]
              }
            Div => ofd[i] = ld[i].to_double() / rd[i].to_double()
          }
        }
      }
      if is_f64 {
        Some(@types.F64(ofd, ovalid))
      } else if op is @types.Div {
        None
      } else {
        Some(@types.I64(od, ovalid))
      }
    }
    (@types.F64(ld, lv), @types.F64(rd, rv)) => {
      let od : FixedArray[Double] = FixedArray::make(n, 0.0)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for i in 0..<n {
        if lv[i] && rv[i] {
          ovalid[i] = true
          match op {
            Add => od[i] = ld[i] + rd[i]
            Sub => od[i] = ld[i] - rd[i]
            Mul => od[i] = ld[i] * rd[i]
            Div => od[i] = ld[i] / rd[i]
            Mod =>
              if rd[i] == 0.0 {
                ovalid[i] = false
              } else {
                od[i] = ld[i] - rd[i] * (ld[i] / rd[i]).trunc()
              }
          }
        }
      }
      Some(@types.F64(od, ovalid))
    }
    _ => None
  }
}

///|
/// Same-type three-valued comparison in one loop. Mirrors
/// Scalar::compare + CmpOp::apply: NULL on either side stays NULL,
/// Str is dictionary order, Bool orders false < true. None falls back
/// for mismatched dtypes.
fn cmp_vec(
  op : @types.CmpOp,
  l : @types.ColumnVector,
  r : @types.ColumnVector,
) -> @types.ColumnVector? {
  let n = l.len()
  fn flag(o : Int) -> Bool {
    match op {
      Eq => o == 0
      Neq => o != 0
      Lt => o < 0
      Le => o <= 0
      Gt => o > 0
      Ge => o >= 0
    }
  }
  let od : FixedArray[Bool] = FixedArray::make(n, false)
  let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
  match (l, r) {
    (@types.I32(ld, lv), @types.I32(rd, rv)) =>
      for i in 0..<n {
        if lv[i] && rv[i] {
          od[i] = flag(ord_i(ld[i], rd[i]))
          ovalid[i] = true
        }
      }
    (@types.I64(ld, lv), @types.I64(rd, rv)) =>
      for i in 0..<n {
        if lv[i] && rv[i] {
          od[i] = flag(ord_i64(ld[i], rd[i]))
          ovalid[i] = true
        }
      }
    (@types.F64(ld, lv), @types.F64(rd, rv)) =>
      for i in 0..<n {
        if lv[i] && rv[i] {
          od[i] = flag(ord_f(ld[i], rd[i]))
          ovalid[i] = true
        }
      }
    (@types.DateV(ld, lv), @types.DateV(rd, rv)) =>
      for i in 0..<n {
        if lv[i] && rv[i] {
          od[i] = flag(ord_i(ld[i], rd[i]))
          ovalid[i] = true
        }
      }
    (@types.StrV(ld, lv), @types.StrV(rd, rv)) =>
      for i in 0..<n {
        if lv[i] && rv[i] {
          od[i] = flag(ld[i].lexical_compare(rd[i]))
          ovalid[i] = true
        }
      }
    (@types.BoolV(ld, lv), @types.BoolV(rd, rv)) =>
      for i in 0..<n {
        if lv[i] && rv[i] {
          od[i] = flag(
            match (ld[i], rd[i]) {
              (false, true) => -1
              (true, false) => 1
              _ => 0
            },
          )
          ovalid[i] = true
        }
      }
    _ => return None
  }
  Some(@types.BoolV(od, ovalid))
}

///|
fn ord_i64(x : Int64, y : Int64) -> Int {
  if x < y {
    -1
  } else if x > y {
    1
  } else {
    0
  }
}

///|
fn ord_f(x : Double, y : Double) -> Int {
  if x < y {
    -1
  } else if x > y {
    1
  } else {
    0
  }
}

///|
/// Three-valued AND/OR in one loop with NULL-aware dominance, mirroring
/// Scalar::logic_and/logic_or: for AND, a valid false dominates even
/// against NULL; for OR, a valid true does. Both-NULL stays NULL.
/// `or` selects the operation. None falls back for non-bool operands.
fn logic_vec(
  is_or : Bool,
  l : @types.ColumnVector,
  r : @types.ColumnVector,
) -> @types.ColumnVector? {
  match (l, r) {
    (@types.BoolV(ld, lv), @types.BoolV(rd, rv)) => {
      let n = l.len()
      let od : FixedArray[Bool] = FixedArray::make(n, false)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for i in 0..<n {
        let l_true = lv[i] && ld[i]
        let r_true = rv[i] && rd[i]
        let l_false = lv[i] && !ld[i]
        let r_false = rv[i] && !rd[i]
        if is_or {
          if l_true || r_true {
            od[i] = true
            ovalid[i] = true
          } else if l_false && r_false {
            od[i] = false
            ovalid[i] = true
          }
        } else if l_false || r_false {
          od[i] = false
          ovalid[i] = true
        } else if l_true && r_true {
          od[i] = true
          ovalid[i] = true
        }
      }
      Some(@types.BoolV(od, ovalid))
    }
    _ => None
  }
}
