// Byte-range variants of the scalar parsers: identical semantics to the
// String versions in num.mbt and date.mbt (optional sign, overflow
// checked, no trailing junk, strict yyyy-mm-dd) but reading a Bytes
// range directly, so CSV materialization never builds per-cell Strings
// for numeric, boolean or date columns.

///|
pub fn parse_i32_bytes(buf : Bytes, start : Int, end : Int) -> Int? {
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
pub fn parse_i64_bytes(buf : Bytes, start : Int, end : Int) -> Int64? {
  let mut acc = 0L
  let mut neg = false
  let mut seen_sign = false
  let mut digits = 0
  for i in start..<end {
    let v = buf[i].to_int()
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
pub fn parse_f64_bytes(buf : Bytes, start : Int, end : Int) -> Double? {
  let n = end - start
  if n == 0 {
    return None
  }
  let mut i = start
  let mut neg = false
  if buf[i].to_int() == 45 || buf[i].to_int() == 43 {
    neg = buf[i].to_int() == 45
    i += 1
  }
  let mut value = 0.0
  let mut int_digits = 0
  while i < end && is_digit_byte(buf[i]) {
    value = value * 10.0 + (buf[i].to_int() - 48).to_double()
    int_digits += 1
    i += 1
  }
  let mut frac_div = 1.0
  if i < end && buf[i].to_int() == 46 {
    // '.'
    i += 1
    while i < end && is_digit_byte(buf[i]) {
      frac_div = frac_div * 10.0
      value = value * 10.0 + (buf[i].to_int() - 48).to_double()
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
      exp = exp * 10 + (buf[i].to_int() - 48)
      exp_digits += 1
      i += 1
      if exp > 300 {
        return None
      }
    }
    if exp_digits == 0 {
      return None
    }
    if exp_neg {
      value = value / pow10(exp)
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
pub fn parse_bool_bytes(buf : Bytes, start : Int, end : Int) -> Bool? {
  let n = end - start
  if n == 4 &&
    buf[start].to_int() == 116 && // t
    buf[start + 1].to_int() == 114 && // r
    buf[start + 2].to_int() == 117 && // u
    buf[start + 3].to_int() == 101 {
    Some(true)
  } else if n == 5 &&
    buf[start].to_int() == 102 && // f
    buf[start + 1].to_int() == 97 && // a
    buf[start + 2].to_int() == 108 && // l
    buf[start + 3].to_int() == 115 && // s
    buf[start + 4].to_int() == 101 {
    Some(false)
  } else {
    None
  }
}

///|
/// Strict ISO "yyyy-mm-dd" over a byte range, mirroring parse_date.
pub fn parse_date_bytes(buf : Bytes, start : Int, end : Int) -> Int? {
  if end - start != 10 ||
    buf[start + 4].to_int() != 45 ||
    buf[start + 7].to_int() != 45 {
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
fn digits4(buf : Bytes, off : Int) -> Int? {
  match
    (
      digit_byte(buf[off]),
      digit_byte(buf[off + 1]),
      digit_byte(buf[off + 2]),
      digit_byte(buf[off + 3]),
    ) {
    (Some(a), Some(b), Some(c), Some(d)) =>
      Some(a * 1000 + b * 100 + c * 10 + d)
    _ => None
  }
}

///|
fn digits2(buf : Bytes, off : Int) -> Int? {
  match (digit_byte(buf[off]), digit_byte(buf[off + 1])) {
    (Some(a), Some(b)) => Some(a * 10 + b)
    _ => None
  }
}

///|
fn digit_byte(b : Byte) -> Int? {
  let v = b.to_int()
  if v >= 48 && v <= 57 {
    Some(v - 48)
  } else {
    None
  }
}
