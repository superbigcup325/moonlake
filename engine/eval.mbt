// Scalar evaluation over two row contexts: a DataBatch row (batches,
// filters, aggregation inputs) and a flat joined row (join residuals).
// Both delegate to eval_with with a column getter.

///|
pub fn eval_scalar(
  e : PhysExpr,
  batch : @types.DataBatch,
  row : Int,
) -> @types.Scalar {
  eval_with(e, fn(i) { batch.columns()[i].get(row) })
}

///|
/// Evaluate against a fully materialized flat row (index = column).
fn eval_row(e : PhysExpr, row : Array[@types.Scalar]) -> @types.Scalar {
  eval_with(e, fn(i) { row[i] })
}

///|
fn eval_with(e : PhysExpr, get : (Int) -> @types.Scalar) -> @types.Scalar {
  match e {
    ColRef(i, _) => get(i)
    Const(v) => v
    Promote(inner, dt) => promote(eval_with(inner, get), dt)
    ArithE(op, l, r, _) =>
      @types.Scalar::arith(op, eval_with(l, get), eval_with(r, get))
    CmpE(op, l, r) =>
      op.apply(@types.Scalar::compare(eval_with(l, get), eval_with(r, get)))
    AndE(l, r) => @types.Scalar::logic_and(eval_with(l, get), eval_with(r, get))
    OrE(l, r) => @types.Scalar::logic_or(eval_with(l, get), eval_with(r, get))
    NotE(inner) => @types.Scalar::logic_not(eval_with(inner, get))
    ExtractE(inner, field) =>
      match eval_with(inner, get) {
        @types.Date(d) =>
          @types.Int32(
            match field {
              Year => @types.epoch_year(d)
              Month => @types.epoch_month(d)
              Day => @types.epoch_day(d)
            },
          )
        _ => @types.Null
      }
    InSetE(inner, set, negated, right_has_null) =>
      match eval_with(inner, get) {
        @types.Null => @types.Null // NULL never matches, either direction
        v => {
          let in_set = set.contains(scalar_key(v))
          if in_set {
            @types.Boolean(!negated)
          } else if negated && right_has_null {
            @types.Null
          } else {
            @types.Boolean( // NOT IN against a set containing NULL: unknown
              negated,
            )
          }
        }
      }
    LikeE(inner, pattern) =>
      match eval_with(inner, get) {
        @types.Str(s) => @types.Boolean(like_match(s, pattern))
        _ => @types.Null
      } // NULL never matches
    CaseE(whens, else_, _) => {
      for when in whens {
        match eval_with(when.0, get) {
          @types.Boolean(true) => return eval_with(when.1, get)
          _ => ()
        }
      }
      match else_ {
        Some(e) => eval_with(e, get)
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
