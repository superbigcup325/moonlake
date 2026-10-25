// Manual number parsing shared by the CSV source and the SQL lexer.
// moonbitlang/core/internal/strconv is import-restricted, so these are
// hand-rolled; the double parser is accurate enough for the 1e-9
// relative tolerance used against duckdb goldens.

///|
/// Optional sign then digits, else None, range-checked to int32: a value
/// outside [-2^31, 2^31-1] returns None so callers promote or report
/// instead of wrapping silently.
pub fn parse_i32(s : String) -> Int32? {
  match parse_i64(s) {
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
/// Optional sign then digits, else None, range-checked to int64.
/// Accumulates as a negative magnitude — -2^63 is representable while
/// +2^63 is not, so negating at the end stays exact.
pub fn parse_i64(s : String) -> Int64? {
  let mut acc = 0L
  let mut neg = false
  let mut seen_sign = false
  let mut digits = 0
  for ch in s {
    if !seen_sign && (ch == '-' || ch == '+') {
      neg = ch == '-'
      seen_sign = true
      continue
    }
    seen_sign = true
    let v = ch.to_int()
    if v < 48 || v > 57 {
      return None
    }
    digits += 1
    // floor(2^63 / 10): at or above this magnitude the * 10 step would
    // leave the int64 range (any wrap lands on a positive value)
    if acc < -922337203685477580L {
      return None
    }
    acc = acc * 10L - (v - 48).to_int64()
    if acc > 0L {
      return None // wrapped past -2^63
    }
  }
  if !seen_sign || digits == 0 {
    return None // empty or sign-only input
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
/// [sign] digits [ . digits ] [ (e|E) [sign] digits ], else None.
/// Digits accumulate in Double — an Int64 accumulator would wrap exactly
/// the way this parser exists to prevent — so arbitrarily long inputs
/// degrade to the nearest float64 instead of flipping sign.
pub fn parse_f64(s : String) -> Double? {
  let chars : Array[Char] = []
  for ch in s {
    chars.push(ch)
  }
  let n = chars.length()
  if n == 0 {
    return None
  }
  match parse_nonfinite_chars(chars) {
    Some(v) => return Some(v)
    None => ()
  }
  let mut i = 0
  let mut neg = false
  if chars[0] == '-' || chars[0] == '+' {
    neg = chars[0] == '-'
    i = 1
  }
  // exact fast path: a pure-digit run that fits in UInt64 converts
  // through the exact uint64->double rounding, so every integer literal
  // up to 20 digits keeps its value (2^63 parsed by the decimal
  // accumulator below lands on a neighbor double, and `k = -2^63`
  // misses). Wider runs fall through to the accumulator's 1e-9 contract.
  if i < n {
    let mut acc : UInt64 = 0UL
    let mut fits = true
    let mut j = i
    while j < n && is_digit(chars[j]) {
      if fits {
        let d = (chars[j].to_int() - 48).to_uint64()
        if acc > 1844674407370955161UL {
          fits = false
        } else {
          let scaled = acc * 10UL
          if scaled > 18446744073709551615UL - d {
            fits = false
          } else {
            acc = scaled + d
          }
        }
      }
      j += 1
    }
    if fits && j == n {
      let v = acc.to_double()
      return Some(if neg { -v } else { v })
    }
  }
  let mut value = 0.0
  let mut int_digits = 0
  while i < n && is_digit(chars[i]) {
    value = value * 10.0 + (chars[i].to_int() - 48).to_double()
    int_digits += 1
    i += 1
  }
  let mut frac_div = 1.0
  if i < n && chars[i] == '.' {
    i += 1
    while i < n && is_digit(chars[i]) {
      frac_div = frac_div * 10.0
      value = value * 10.0 + (chars[i].to_int() - 48).to_double()
      i += 1
    }
  }
  if int_digits == 0 && frac_div == 1.0 {
    return None
  }
  if frac_div > 1.0 {
    value = value / frac_div
  }
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
      if exp <= 100000 {
        exp = exp * 10 + (chars[i].to_int() - 48)
      }
      exp_digits += 1
      i += 1
    }
    if exp_digits == 0 {
      return None
    }
    // past the double range a cast returns inf (0 below the smallest
    // subnormal): capping keeps a huge exponent from spinning, and `0e999`
    // stays 0 rather than 0 * inf = nan
    if exp_neg {
      // below 1e-308 the result is subnormal: one pow10 would be inf and the
      // answer 0, so divide in two steps, and 0 only past 4.9e-324
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
/// NaN / inf spellings over a char buffer, case-insensitive: the same set the
/// byte parser takes, so `CAST('NaN' AS DOUBLE)` and a CSV float column agree.
fn parse_nonfinite_chars(chars : Array[Char]) -> Double? {
  // the spellings are 3, 4, 8 or 9 chars: skip the copy for anything else
  let n = chars.length()
  if n != 3 && n != 4 && n != 8 && n != 9 {
    return None
  }
  let lower : StringBuilder = StringBuilder()
  for ch in chars {
    let v = ch.to_int()
    lower.write_char(
      if v >= 65 && v <= 90 {
        Int32::unsafe_to_char(v + 32)
      } else {
        ch
      },
    )
  }
  match lower.to_string() {
    "nan" | "+nan" | "-nan" => Some(@double.not_a_number)
    "inf" | "+inf" | "infinity" | "+infinity" => Some(@double.infinity)
    "-inf" | "-infinity" => Some(@double.neg_infinity)
    _ => None
  }
}

///|
fn is_digit(ch : Char) -> Bool {
  let v = ch.to_int()
  v >= 48 && v <= 57
}

///|
fn pow10(e : Int32) -> Double {
  let mut v = 1.0
  for _ in 0..<e {
    v = v * 10.0
  }
  v
}
