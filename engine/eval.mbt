// Scalar evaluation over two row contexts: a DataBatch row (batches,
// filters, aggregation inputs) and a flat joined row (join residuals).
// Both delegate to eval_with with a column getter.

///|
pub fn eval_scalar(
  e : PhysExpr,
  batch : @types.DataBatch,
  row : Int,
) -> @types.Scalar raise @types.SqlError {
  eval_with(e, fn(i) { batch.columns()[i].get(row) })
}

///|
/// Evaluate against a fully materialized flat row (index = column).
fn eval_row(
  e : PhysExpr,
  row : Array[@types.Scalar],
) -> @types.Scalar raise @types.SqlError {
  eval_with(e, fn(i) { row[i] })
}

///|
fn eval_with(
  e : PhysExpr,
  get : (Int) -> @types.Scalar,
) -> @types.Scalar raise @types.SqlError {
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
    IsNullE(inner, negated) =>
      @types.Boolean(
        if eval_with(inner, get) is @types.Null {
          !negated
        } else {
          negated
        },
      )
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
    FuncE(name, args, _) => {
      let vals : Array[@types.Scalar] = []
      for a in args {
        vals.push(eval_with(a, get))
      }
      eval_func(name, vals)
    }
    CastE(inner, dt) => cast_scalar(eval_with(inner, get), dt)
    DateArithE(inner, qty, unit) =>
      match eval_with(inner, get) {
        @types.Date(d) =>
          @types.Date(
            match unit {
              Days => d + qty.to_int()
              Months => @types.add_months(d, qty.to_int())
              Years => @types.add_months(d, qty.to_int() * 12)
            },
          )
        _ => @types.Null
      }
  }
}

///|
/// Scalar string and math functions. Every function propagates NULL.
fn eval_func(name : String, vals : Array[@types.Scalar]) -> @types.Scalar {
  for v in vals {
    if v is @types.Null {
      return @types.Null
    }
  }
  match name {
    "length" =>
      match vals[0] {
        @types.Str(s) => @types.Int32(char_count(s))
        _ => @types.Null
      }
    "upper" =>
      match vals[0] {
        @types.Str(s) => @types.Str(s.to_upper())
        _ => @types.Null
      }
    "lower" =>
      match vals[0] {
        @types.Str(s) => @types.Str(s.to_lower())
        _ => @types.Null
      }
    "trim" =>
      match vals[0] {
        @types.Str(s) => @types.Str(strip_spaces(s, true, true))
        _ => @types.Null
      }
    "ltrim" =>
      match vals[0] {
        @types.Str(s) => @types.Str(strip_spaces(s, true, false))
        _ => @types.Null
      }
    "rtrim" =>
      match vals[0] {
        @types.Str(s) => @types.Str(strip_spaces(s, false, true))
        _ => @types.Null
      }
    "substring" => {
      let chars : Array[Char] = []
      match vals[0] {
        @types.Str(s) =>
          for ch in s {
            chars.push(ch)
          }
        _ => return @types.Null
      }
      // DuckDB-style start: 1-based; zero or negative counts from the end
      let start = match vals[1] {
        @types.Int32(v) => v
        _ => return @types.Null
      }
      let len = chars.length()
      let begin0 = if start > 0 { start - 1 } else { len + start }
      let want = match vals.get(2) {
        Some(@types.Int32(v)) => v
        _ => len // no length: through the end
      }
      if want <= 0 || begin0 >= len {
        return @types.Str("")
      }
      let from = if begin0 < 0 { 0 } else { begin0 }
      // a negative begin consumes skipped characters against the length
      let mut remaining = want + (if begin0 < 0 { begin0 } else { 0 })
      let sb = StringBuilder()
      let mut i = from
      while i < len && remaining > 0 {
        sb.write_char(chars[i])
        i += 1
        remaining -= 1
      }
      @types.Str(sb.to_string())
    }
    "concat" => {
      let a = match vals[0] {
        @types.Str(s) => s
        _ => return @types.Null
      }
      let b = match vals[1] {
        @types.Str(s) => s
        _ => return @types.Null
      }
      @types.Str(a + b)
    }
    "abs" =>
      match vals[0] {
        @types.Int32(v) => @types.Int32(if v < 0 { -v } else { v })
        @types.Int64(v) => @types.Int64(if v < 0L { -v } else { v })
        @types.Float64(v) => @types.Float64(if v < 0.0 { -v } else { v })
        _ => @types.Null
      }
    "sqrt" =>
      match as_double_scalar(vals[0]) {
        Some(v) => @types.Float64(sqrt_fn(v))
        None => @types.Null
      }
    "floor" =>
      match as_double_scalar(vals[0]) {
        Some(v) => @types.Float64(v.floor())
        None => @types.Null
      }
    "ceil" =>
      match as_double_scalar(vals[0]) {
        Some(v) => @types.Float64(v.ceil())
        None => @types.Null
      }
    "round" => {
      let digits = match vals.get(1) {
        Some(@types.Int32(d)) => d
        _ => 0
      }
      match as_double_scalar(vals[0]) {
        Some(v) => {
          let scale = pow10i(digits)
          @types.Float64((v * scale).round() / scale)
        }
        None => @types.Null
      }
    }
    _ => @types.Null
  } // unreachable: the binder whitelists names
}

///|
fn char_count(s : String) -> Int {
  let mut c = 0
  for _ in s {
    c += 1
  }
  c
}

///|
fn strip_spaces(s : String, left : Bool, right : Bool) -> String {
  let chars : Array[Char] = []
  for ch in s {
    chars.push(ch)
  }
  let mut lo = 0
  let mut hi = chars.length()
  if left {
    while lo < hi && chars[lo] == ' ' {
      lo += 1
    }
  }
  if right {
    while hi > lo && chars[hi - 1] == ' ' {
      hi -= 1
    }
  }
  let sb = StringBuilder()
  for i in lo..<hi {
    sb.write_char(chars[i])
  }
  sb.to_string()
}

///|
fn as_double_scalar(v : @types.Scalar) -> Double? {
  match v {
    @types.Int32(x) => Some(x.to_double())
    @types.Int64(x) => Some(x.to_double())
    @types.Float64(x) => Some(x)
    _ => None
  }
}

///|
fn sqrt_fn(v : Double) -> Double {
  v.sqrt()
}

///|
fn pow10i(e : Int) -> Double {
  let mut v = 1.0
  for _ in 0..<e {
    v = v * 10.0
  }
  v
}

///|
/// Runtime CAST. Failures are row errors (DuckDB-style): the query
/// aborts with an Execute error rather than silently producing NULL.
fn cast_scalar(
  v : @types.Scalar,
  dt : @types.DataType,
) -> @types.Scalar raise @types.SqlError {
  if v is @types.Null {
    return @types.Null
  }
  match dt {
    @types.Str => @types.Str(v.to_string())
    @types.Int32 =>
      match v {
        @types.Int32(_) => v
        @types.Int64(x) =>
          if x >= -2147483648L && x <= 2147483647L {
            @types.Int32(x.to_int())
          } else {
            raise @types.SqlError::Execute(
              "cannot cast \{x.to_string()} to int32: out of range",
            )
          }
        @types.Float64(x) => @types.Int32(x.to_int())
        @types.Boolean(b) => @types.Int32(if b { 1 } else { 0 })
        @types.Str(s) =>
          match @types.parse_i32(s) {
            Some(x) => @types.Int32(x)
            None =>
              raise @types.SqlError::Execute("cannot cast \"\{s}\" to int32")
          }
        _ => unreachable_cast(v, dt)
      }
    @types.Int64 =>
      match v {
        @types.Int32(x) => @types.Int64(x.to_int64())
        @types.Int64(_) => v
        @types.Float64(x) => @types.Int64(x.to_int64())
        @types.Boolean(b) => @types.Int64(if b { 1L } else { 0L })
        @types.Str(s) =>
          match @types.parse_i64(s) {
            Some(x) => @types.Int64(x)
            None =>
              raise @types.SqlError::Execute("cannot cast \"\{s}\" to int64")
          }
        _ => unreachable_cast(v, dt)
      }
    @types.Float64 =>
      match v {
        @types.Int32(x) => @types.Float64(x.to_double())
        @types.Int64(x) => @types.Float64(x.to_double())
        @types.Float64(_) => v
        @types.Boolean(b) => @types.Float64(if b { 1.0 } else { 0.0 })
        @types.Str(s) =>
          match @types.parse_f64(s) {
            Some(x) => @types.Float64(x)
            None =>
              raise @types.SqlError::Execute("cannot cast \"\{s}\" to float64")
          }
        _ => unreachable_cast(v, dt)
      }
    @types.Bool =>
      match v {
        @types.Boolean(_) => v
        @types.Int32(x) => @types.Boolean(x != 0)
        @types.Int64(x) => @types.Boolean(x != 0L)
        @types.Str(s) =>
          match @types.parse_bool(s) {
            Some(b) => @types.Boolean(b)
            None =>
              raise @types.SqlError::Execute("cannot cast \"\{s}\" to bool")
          }
        _ => unreachable_cast(v, dt)
      }
    @types.Date =>
      match v {
        @types.Date(_) => v
        @types.Int32(x) => @types.Date(x)
        @types.Str(s) =>
          match @types.parse_date(s) {
            Some(d) => @types.Date(d)
            None =>
              raise @types.SqlError::Execute(
                "cannot cast \"\{s}\" to date (expected yyyy-mm-dd)",
              )
          }
        _ => unreachable_cast(v, dt)
      }
  }
}

///|
fn unreachable_cast(
  v : @types.Scalar,
  dt : @types.DataType,
) -> @types.Scalar raise @types.SqlError {
  raise @types.SqlError::Execute(
    "cannot cast \{v.to_string()} to \{dt.to_string()}",
  )
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
fn eval_mask(
  e : PhysExpr,
  batch : @types.DataBatch,
) -> FixedArray[Bool] raise @types.SqlError {
  let n = batch.row_count()
  let mask : FixedArray[Bool] = FixedArray::make(n, false)
  match eval_vec(e, batch) {
    @types.BoolV(d, valid) =>
      for r in 0..<n {
        mask[r] = valid[r] && d[r]
      }
    _ =>
      // predicates are Bool by construction; stay safe via the interpreter
      for r in 0..<n {
        mask[r] = eval_scalar(e, batch, r) is @types.Boolean(true)
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
