// Manual number parsing shared by the CSV source and the SQL lexer.
// moonbitlang/core/internal/strconv is import-restricted, so these are
// hand-rolled; the double parser is accurate enough for the 1e-9
// relative tolerance used against duckdb goldens.

///|
/// Optional sign then digits, else None. Overflow is not checked (v1
/// values fit comfortably in 32 bits after inference).
pub fn parse_i32(s : String) -> Int? {
  let mut acc = 0
  let mut neg = false
  let mut seen = false
  for ch in s {
    if seen == false && (ch == '-' || ch == '+') {
      neg = ch == '-'
      seen = true
      continue
    }
    seen = true
    let v = ch.to_int()
    if v < 48 || v > 57 {
      return None
    }
    acc = acc * 10 + (v - 48)
  }
  if !seen {
    return None // empty
  }
  Some(if neg { -acc } else { acc })
}

///|
/// [sign] digits [ . digits ] [ (e|E) [sign] digits ], else None.
pub fn parse_f64(s : String) -> Double? {
  let chars : Array[Char] = []
  for ch in s {
    chars.push(ch)
  }
  let n = chars.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if chars[0] == '-' || chars[0] == '+' {
    neg = chars[0] == '-'
    i = 1
  }
  let mut int_part = 0L
  let mut int_digits = 0
  while i < n && is_digit(chars[i]) {
    int_part = int_part * 10L + (chars[i].to_int() - 48).to_int64()
    int_digits += 1
    i += 1
  }
  let mut frac_part = 0L
  let mut frac_len = 0
  if i < n && chars[i] == '.' {
    i += 1
    while i < n && is_digit(chars[i]) {
      if frac_len < 18 {
        frac_part = frac_part * 10L + (chars[i].to_int() - 48).to_int64()
        frac_len += 1
      }
      i += 1
    }
  }
  if int_digits == 0 && frac_len == 0 {
    return None
  }
  let mut value = int_part.to_double() + frac_part.to_double() / pow10(frac_len)
  if i < n && (chars[i] == 'e' || chars[i] == 'E') {
    i += 1
    let mut exp_neg = false
    if i < n && (chars[i] == '-' || chars[i] == '+') {
      exp_neg = chars[i] == '-'
      i += 1
    }
    let mut exp = 0
    let mut exp_digits = 0
    while i < n && is_digit(chars[i]) {
      exp = exp * 10 + (chars[i].to_int() - 48)
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
  if i != n {
    return None // trailing junk
  }
  Some(if neg { -value } else { value })
}

///|
pub fn parse_bool(s : String) -> Bool? {
  if s == "true" {
    Some(true)
  } else if s == "false" {
    Some(false)
  } else {
    None
  }
}

///|
fn is_digit(ch : Char) -> Bool {
  let v = ch.to_int()
  v >= 48 && v <= 57
}

///|
fn pow10(e : Int) -> Double {
  let mut v = 1.0
  for _ in 0..<e {
    v = v * 10.0
  }
  v
}
