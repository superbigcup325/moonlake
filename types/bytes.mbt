// Byte-range variants of the scalar parsers: identical semantics to the
// String versions in num.mbt and date.mbt (optional sign, overflow
// checked, no trailing junk, strict yyyy-mm-dd) but reading a Bytes
// range directly, so CSV materialization never builds per-cell Strings
// for numeric, boolean or date columns.

///|
pub fn parse_i32_bytes(buf : Bytes, start : Int32, end : Int32) -> Int32? {
  // fast path: short digit runs accumulate in Int32 directly (9 digits
  // cap at 999999999, far below 2^31); anything else — long runs, edge
  // magnitudes, non-digit junk — falls back to the int64 parser with
  // its overflow model, keeping the semantics identical
  let n = end - start
  if n > 0 && n <= 9 {
    let mut i = start
    let mut neg = false
    let first = buf.unsafe_get(i).to_int()
    if first == 45 || first == 43 {
      neg = first == 45
      i += 1
    }
    if end - i > 0 && end - i <= 9 {
      let mut acc = 0
      let mut ok = true
      while i < end {
        let v = buf.unsafe_get(i).to_int()
        if v < 48 || v > 57 {
          ok = false
          break
        }
        acc = acc * 10 + (v - 48)
        i += 1
      }
      if ok {
        return Some(if neg { -acc } else { acc })
      }
      return None
    }
  }
  match parse_i64_bytes(buf, start, end) {
    Some(v) =>
      if v >= -2147483648L && v <= 2147483647L {
        Some(v.to_int())
      } else {
        None
      }
    None => None
  }
}

///|
pub fn parse_i64_bytes(buf : Bytes, start : Int32, end : Int32) -> Int64? {
  let mut acc = 0L
  let mut neg = false
  let mut seen_sign = false
  let mut digits = 0
  for i in start..<end {
    let v = buf.unsafe_get(i).to_int()
    if !seen_sign && (v == 45 || v == 43) {
      // '-' or '+'
      neg = v == 45
      seen_sign = true
      continue
    }
    seen_sign = true
    if v < 48 || v > 57 {
      return None
    }
    digits += 1
    // floor(2^63 / 10): past this magnitude the * 10 step would wrap
    if acc < -922337203685477580L {
      return None
    }
    acc = acc * 10L - (v - 48).to_int64()
    if acc > 0L {
      return None // wrapped past -2^63
    }
  }
  if !seen_sign || digits == 0 {
    return None // empty or sign-only
  }
  if !neg {
    if acc == -9223372036854775808L {
      return None // 2^63 overflows positive int64
    }
    acc = -acc
  }
  Some(acc)
}

///|
/// Does `start..<end` spell `word` (given in lower case), ignoring ASCII case?
fn ascii_ci_eq(buf : Bytes, start : Int32, end : Int32, word : String) -> Bool {
  let w = @utf8.encode(word)
  if end - start != w.length() {
    return false
  }
  for i in 0..<w.length() {
    let a = buf[start + i].to_int()
    let ca = if a >= 65 && a <= 90 { a + 32 } else { a }
    if ca != w[i].to_int() {
      return false
    }
  }
  true
}

///|
/// Non-finite spellings, case-insensitive. A float column legitimately holds
/// NaN and infinities, and the writers people export from (pandas, numpy, the
/// JSON emitters) spell them exactly this way; the reader used to reject every
/// spelling, which turned a valid float column into a STRING column and made
/// `CAST('NaN' AS DOUBLE)` an error.
fn parse_nonfinite_bytes(buf : Bytes, start : Int32, end : Int32) -> Double? {
  if ascii_ci_eq(buf, start, end, "nan") ||
    ascii_ci_eq(buf, start, end, "+nan") ||
    ascii_ci_eq(buf, start, end, "-nan") {
    return Some(@double.not_a_number)
  }
  if ascii_ci_eq(buf, start, end, "inf") ||
    ascii_ci_eq(buf, start, end, "+inf") ||
    ascii_ci_eq(buf, start, end, "infinity") ||
    ascii_ci_eq(buf, start, end, "+infinity") {
    return Some(@double.infinity)
  }
  if ascii_ci_eq(buf, start, end, "-inf") ||
    ascii_ci_eq(buf, start, end, "-infinity") {
    return Some(@double.neg_infinity)
  }
  None
}

///|
pub fn parse_f64_bytes(buf : Bytes, start : Int32, end : Int32) -> Double? {
  let n = end - start
  if n == 0 {
    return None
  }
  match parse_nonfinite_bytes(buf, start, end) {
    Some(v) => return Some(v)
    None => ()
  }
  let mut i = start
  let mut neg = false
  if buf[i].to_int() == 45 || buf[i].to_int() == 43 {
    neg = buf[i].to_int() == 45
    i += 1
  }
  let mut value = 0.0
  let mut int_digits = 0
  while i < end && is_digit_byte(buf.unsafe_get(i)) {
    value = value * 10.0 + (buf.unsafe_get(i).to_int() - 48).to_double()
    int_digits += 1
    i += 1
  }
  let mut frac_div = 1.0
  if i < end && buf.unsafe_get(i).to_int() == 46 {
    // '.'
    i += 1
    while i < end && is_digit_byte(buf.unsafe_get(i)) {
      frac_div = frac_div * 10.0
      value = value * 10.0 + (buf.unsafe_get(i).to_int() - 48).to_double()
      i += 1
    }
  }
  if int_digits == 0 && frac_div == 1.0 {
    return None
  }
  if frac_div > 1.0 {
    value = value / frac_div
  }
  if i < end && (buf[i].to_int() == 101 || buf[i].to_int() == 69) {
    // 'e' or 'E'
    i += 1
    let mut exp_neg = false
    if i < end && (buf[i].to_int() == 45 || buf[i].to_int() == 43) {
      exp_neg = buf[i].to_int() == 45
      i += 1
    }
    let mut exp = 0
    let mut exp_digits = 0
    while i < end && is_digit_byte(buf[i]) {
      if exp <= 100000 {
        exp = exp * 10 + (buf[i].to_int() - 48)
      }
      exp_digits += 1
      i += 1
    }
    if exp_digits == 0 {
      return None
    }
    // past the double range a cast returns inf (0 below the smallest
    // subnormal), which is what DuckDB returns; the shortcut also keeps an
    // absurd exponent from spinning pow10, and `0e999` stays 0 rather than
    // 0 * inf = nan
    if exp_neg {
      // a negative exponent below 1e-308 lands in the subnormals, where one
      // pow10 lands on inf and would answer 0: divide in two steps, and 0 only
      // past the smallest subnormal (4.9e-324)
      value = if exp > 324 {
        0.0
      } else if exp <= 308 {
        value / pow10(exp)
      } else {
        value / pow10(308) / pow10(exp - 308)
      }
    } else if value == 0.0 {
      value = 0.0
    } else if exp > 308 {
      value = @double.infinity
    } else {
      value = value * pow10(exp)
    }
  }
  if i != end {
    return None // trailing junk
  }
  Some(if neg { -value } else { value })
}

///|
pub fn parse_bool_bytes(buf : Bytes, start : Int32, end : Int32) -> Bool? {
  let n = end - start
  if n == 4 &&
    buf.unsafe_get(start).to_int() == 116 && // t
    buf.unsafe_get(start + 1).to_int() == 114 && // r
    buf.unsafe_get(start + 2).to_int() == 117 && // u
    buf.unsafe_get(start + 3).to_int() == 101 {
    Some(true)
  } else if n == 5 &&
    buf.unsafe_get(start).to_int() == 102 && // f
    buf.unsafe_get(start + 1).to_int() == 97 && // a
    buf.unsafe_get(start + 2).to_int() == 108 && // l
    buf.unsafe_get(start + 3).to_int() == 115 && // s
    buf.unsafe_get(start + 4).to_int() == 101 {
    Some(false)
  } else {
    None
  }
}

///|
/// Strict ISO "yyyy-mm-dd" over a byte range, mirroring parse_date.
pub fn parse_date_bytes(buf : Bytes, start : Int32, end : Int32) -> Int32? {
  if end - start != 10 ||
    buf.unsafe_get(start + 4).to_int() != 45 ||
    buf.unsafe_get(start + 7).to_int() != 45 {
    return None
  }
  let y = match digits4(buf, start) {
    Some(v) => v
    None => return None
  }
  let m = match digits2(buf, start + 5) {
    Some(v) => v
    None => return None
  }
  let d = match digits2(buf, start + 8) {
    Some(v) => v
    None => return None
  }
  if m < 1 || m > 12 {
    return None
  }
  if d < 1 || d > days_in_month(y, m) {
    return None
  }
  Some(days_from_civil(y, m, d))
}

///|
fn is_digit_byte(b : Byte) -> Bool {
  let v = b.to_int()
  v >= 48 && v <= 57
}

///|
fn digits4(buf : Bytes, off : Int32) -> Int32? {
  match
    (
      digit_byte(buf.unsafe_get(off)),
      digit_byte(buf.unsafe_get(off + 1)),
      digit_byte(buf.unsafe_get(off + 2)),
      digit_byte(buf.unsafe_get(off + 3)),
    ) {
    (Some(a), Some(b), Some(c), Some(d)) =>
      Some(a * 1000 + b * 100 + c * 10 + d)
    _ => None
  }
}

///|
fn digits2(buf : Bytes, off : Int32) -> Int32? {
  match (digit_byte(buf.unsafe_get(off)), digit_byte(buf.unsafe_get(off + 1))) {
    (Some(a), Some(b)) => Some(a * 10 + b)
    _ => None
  }
}

///|
fn digit_byte(b : Byte) -> Int32? {
  let v = b.to_int()
  if v >= 48 && v <= 57 {
    Some(v - 48)
  } else {
    None
  }
}
