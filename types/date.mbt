// DATE support: ISO "yyyy-mm-dd" parsing and epoch-day conversion
// (days since 1970-01-01, proleptic Gregorian).

///|
pub fn days_from_civil(y : Int, m : Int, d : Int) -> Int {
  let y = if m <= 2 { y - 1 } else { y }
  let era = (if y >= 0 { y } else { y - 399 }) / 400
  let yoe = y - era * 400 // [0, 399]
  let mp = (m + 9) % 12 // March = 0
  let doy = (153 * mp + 2) / 5 + d - 1 // [0, 365]
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy // [0, 146096]
  era * 146097 + doe - 719468
}

///|
pub fn civil_from_days(z : Int) -> (Int, Int, Int) {
  let z = z + 719468
  let era = (if z >= 0 { z } else { z - 146096 }) / 146097
  let doe = z - era * 146097 // [0, 146096]
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 // [0, 399]
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100) // [0, 365]
  let mp = (5 * doy + 2) / 153 // [0, 11]
  let d = doy - (153 * mp + 2) / 5 + 1 // [1, 31]
  let m = if mp < 10 { mp + 3 } else { mp - 9 } // [1, 12]
  (if m <= 2 { y + 1 } else { y }, m, d)
}

///|
fn is_leap(y : Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

///|
fn days_in_month(y : Int, m : Int) -> Int {
  match m {
    1 => 31
    2 => if is_leap(y) { 29 } else { 28 }
    3 => 31
    4 => 30
    5 => 31
    6 => 30
    7 => 31
    8 => 31
    9 => 30
    10 => 31
    11 => 30
    12 => 31
    _ => 0
  }
}

///|
/// Strict ISO parse: "yyyy-mm-dd" with real calendar validation.
/// Returns epoch days, or None on any malformed input.
pub fn parse_date(s : String) -> Int? {
  let cs : Array[Char] = []
  for ch in s {
    cs.push(ch)
  }
  if cs.length() != 10 || cs[4] != '-' || cs[7] != '-' {
    return None
  }
  let y = match parse_digits4(cs, 0) {
    Some(v) => v
    None => return None
  }
  let m = match parse_digits2(cs, 5) {
    Some(v) => v
    None => return None
  }
  let d = match parse_digits2(cs, 8) {
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
fn digit(ch : Char) -> Int? {
  let v = ch.to_int()
  if v >= 48 && v <= 57 {
    Some(v - 48)
  } else {
    None
  }
}

///|
fn parse_digits4(cs : Array[Char], off : Int) -> Int? {
  match (digit(cs[off]), digit(cs[off + 1]), digit(cs[off + 2]), digit(cs[off + 3])) {
    (Some(a), Some(b), Some(c), Some(dd)) => Some(a * 1000 + b * 100 + c * 10 + dd)
    _ => None
  }
}

///|
fn parse_digits2(cs : Array[Char], off : Int) -> Int? {
  match (digit(cs[off]), digit(cs[off + 1])) {
    (Some(a), Some(b)) => Some(a * 10 + b)
    _ => None
  }
}

///|
pub fn epoch_to_string(days : Int) -> String {
  let (y, m, d) = civil_from_days(days)
  let sb = StringBuilder()
  sb.write_string(y.to_string())
  sb.write_char('-')
  if m < 10 {
    sb.write_char('0')
  }
  sb.write_string(m.to_string())
  sb.write_char('-')
  if d < 10 {
    sb.write_char('0')
  }
  sb.write_string(d.to_string())
  sb.to_string()
}
