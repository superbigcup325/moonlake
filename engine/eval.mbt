// Row-at-a-time scalar evaluation over batches. Vectorized evaluation is
// a W3 optimization pass; Q6-scale data runs fine through this path.

///|
pub fn eval_scalar(
  e : PhysExpr,
  batch : @types.DataBatch,
  row : Int,
) -> @types.Scalar {
  match e {
    ColRef(i, _) => batch.columns()[i].get(row)
    Const(v) => v
    Promote(inner, dt) => promote(eval_scalar(inner, batch, row), dt)
    ArithE(op, l, r, _) =>
      @types.Scalar::arith(
        op,
        eval_scalar(l, batch, row),
        eval_scalar(r, batch, row),
      )
    CmpE(op, l, r) =>
      op.apply(
        @types.Scalar::compare(
          eval_scalar(l, batch, row),
          eval_scalar(r, batch, row),
        ),
      )
    AndE(l, r) =>
      @types.Scalar::logic_and(
        eval_scalar(l, batch, row),
        eval_scalar(r, batch, row),
      )
    OrE(l, r) =>
      @types.Scalar::logic_or(
        eval_scalar(l, batch, row),
        eval_scalar(r, batch, row),
      )
    NotE(inner) => @types.Scalar::logic_not(eval_scalar(inner, batch, row))
    LikeE(inner, pattern) =>
      match eval_scalar(inner, batch, row) {
        @types.Str(s) => @types.Boolean(like_match(s, pattern))
        _ => @types.Null
      } // NULL never matches
    CaseE(whens, else_, _) => {
      for when in whens {
        match eval_scalar(when.0, batch, row) {
          @types.Boolean(true) => return eval_scalar(when.1, batch, row)
          _ => ()
        }
      }
      match else_ {
        Some(e) => eval_scalar(e, batch, row)
        None => @types.Null
      }
    }
  }
}

///|
fn promote(s : @types.Scalar, dt : @types.DataType) -> @types.Scalar {
  match (s, dt) {
    (@types.Int32(v), @types.Int64) => @types.Int64(v.to_int64())
    (@types.Int32(v), @types.Float64) => @types.Float64(v.to_double())
    (@types.Int64(v), @types.Float64) => @types.Float64(v.to_double())
    _ => s
  }
}

///|
/// Evaluate a boolean predicate for every row: NULL rows do not pass the
/// filter (SQL WHERE semantics). Returns a dense selection mask.
fn eval_mask(e : PhysExpr, batch : @types.DataBatch) -> FixedArray[Bool] {
  let n = batch.row_count()
  let mask : FixedArray[Bool] = FixedArray::make(n, false)
  for r in 0..<n {
    match eval_scalar(e, batch, r) {
      @types.Boolean(v) => mask[r] = v
      _ => mask[r] = false // NULL never passes WHERE
    }
  }
  mask
}

///|
/// SQL LIKE with % (any run) and _ (one char); case-sensitive.
/// Two-pointer backtracking: on a mismatch after %, retry the % runway
/// one character longer.
fn like_match(text : String, pattern : String) -> Bool {
  let t : Array[Char] = []
  for ch in text {
    t.push(ch)
  }
  let p : Array[Char] = []
  for ch in pattern {
    p.push(ch)
  }
  let mut i = 0
  let mut j = 0
  let mut star = -1
  let mut mark = 0
  while i < t.length() {
    if j < p.length() && (p[j] == '_' || p[j] == t[i]) {
      i += 1
      j += 1
    } else if j < p.length() && p[j] == '%' {
      star = j
      mark = i
      j += 1
    } else if star >= 0 {
      j = star + 1
      mark += 1
      i = mark
    } else {
      return false
    }
  }
  while j < p.length() && p[j] == '%' {
    j += 1
  }
  j == p.length()
}
