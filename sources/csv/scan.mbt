// CSV scanning: whole-value type inference from a sample, then a parsing
// pass that materializes fixed-size batches. Empty cells become NULL.

///|
/// Rows per DataBatch emitted by the CSV scan.
const BATCH_SIZE : Int = 4096

///|
/// Sample rows consulted per column when inferring a type.
const INFER_SAMPLE : Int = 100

///|
/// Scan CSV content (with a header row) into a registered table entry.
pub fn scan_string(
  content : String,
  table_name : String,
) -> @catalog.TableEntry raise @types.SqlError {
  let csv = @NyaCSV.CSV::parse_string(content)
  build_entry(table_name, csv.header(), csv.data())
}

///|
/// Scan a CSV file from disk (native target; wasm targets load files via
/// the playground bridge instead).
pub fn scan_file(
  path : String,
  table_name : String,
) -> @catalog.TableEntry raise @types.SqlError {
  let content = @fs.read_file_to_string(path) catch {
    _ => raise @types.SqlError::Scan("cannot read file at \{path}")
  }
  scan_string(content, table_name)
}

///|
fn build_entry(
  table_name : String,
  header : Array[String],
  rows : Array[Array[String]],
) -> @catalog.TableEntry raise @types.SqlError {
  if header.length() == 0 {
    raise @types.SqlError::Scan("CSV has no header row")
  }
  let dtypes = infer_types(header, rows)
  let columns : Array[@catalog.Column] = []
  for i, h in header {
    columns.push({ name: h, dtype: dtypes[i], })
  }
  let schema : @catalog.TableSchema = { table: table_name, columns, }
  let batches : Array[@types.DataBatch] = []
  let n = rows.length()
  let mut start = 0
  while start < n {
    let end = if start + BATCH_SIZE < n { start + BATCH_SIZE } else { n }
    batches.push(build_batch(dtypes, rows, start, end))
    start = end
  }
  if n == 0 {
    // zero-row table: emit a single empty batch so column count stays visible
    batches.push(build_batch(dtypes, rows, 0, 0))
  }
  { schema, batches, }
}

///|
/// Infer one type per column from the first INFER_SAMPLE rows: every
/// sampled non-empty cell must parse as the candidate type. Order:
/// int32, float64, bool, date, else string. All-null columns infer as string.
fn infer_types(
  header : Array[String],
  rows : Array[Array[String]],
) -> Array[@types.DataType] {
  let sample = if rows.length() < INFER_SAMPLE {
    rows.length()
  } else {
    INFER_SAMPLE
  }
  let dtypes : Array[@types.DataType] = []
  for c in 0..<header.length() {
    let mut all_int = true
    let mut all_double = true
    let mut all_bool = true
    let mut all_date = true
    let mut seen = false
    for r in 0..<sample {
      let cell = rows[r][c]
      if cell == "" {
        continue // NULL cells never veto a type
      }
      seen = true
      if parse_i32(cell) is None {
        all_int = false
      }
      if parse_f64(cell) is None {
        all_double = false
      }
      if !(cell == "true" || cell == "false") {
        all_bool = false
      }
      if @types.parse_date(cell) is None {
        all_date = false
      }
    }
    if !seen {
      dtypes.push(@types.Str)
    } else if all_int {
      dtypes.push(@types.Int32)
    } else if all_double {
      dtypes.push(@types.Float64)
    } else if all_bool {
      dtypes.push(@types.Bool)
    } else if all_date {
      dtypes.push(@types.Date)
    } else {
      dtypes.push(@types.Str)
    }
  }
  dtypes
}

///|
fn build_batch(
  dtypes : Array[@types.DataType],
  rows : Array[Array[String]],
  start : Int,
  end : Int,
) -> @types.DataBatch raise @types.SqlError {
  let n = end - start
  let columns : Array[@types.ColumnVector] = []
  for c, dtype in dtypes {
    let vec = @types.ColumnVector::make(dtype, n)
    for r in start..<end {
      let cell = rows[r][c]
      if cell != "" {
        match dtype {
          Int32 =>
            match parse_i32(cell) {
              Some(v) => vec.set(r - start, @types.Scalar::Int32(v))
              None =>
                raise @types.SqlError::Scan(
                  "row \{r + 1} column \{c}: cannot parse \"\{cell}\" as int32",
                )
            }
          Float64 =>
            match parse_f64(cell) {
              Some(v) => vec.set(r - start, @types.Scalar::Float64(v))
              None =>
                raise @types.SqlError::Scan(
                  "row \{r + 1} column \{c}: cannot parse \"\{cell}\" as float64",
                )
            }
          Bool =>
            match parse_bool(cell) {
              Some(v) => vec.set(r - start, @types.Scalar::Boolean(v))
              None =>
                raise @types.SqlError::Scan(
                  "row \{r + 1} column \{c}: cannot parse \"\{cell}\" as bool",
                )
            }
          Date =>
            match @types.parse_date(cell) {
              Some(v) => vec.set(r - start, @types.Scalar::Date(v))
              None =>
                raise @types.SqlError::Scan(
                  "row \{r + 1} column \{c}: cannot parse \"\{cell}\" as date",
                )
            }
          Int64 => () // not produced by inference (v1)
          Str => vec.set(r - start, @types.Scalar::Str(cell))
        }
      } else {
        vec.set(r - start, @types.Scalar::Null)
      }
    }
    columns.push(vec)
  }
  @types.DataBatch::new(columns, n)
}

///|
fn parse_bool(s : String) -> Bool? {
  if s == "true" {
    Some(true)
  } else if s == "false" {
    Some(false)
  } else {
    None
  }
}

///|
/// Manual int parse: optional sign then digits, else None.
fn parse_i32(s : String) -> Int? {
  let mut acc = 0
  let mut neg = false
  let mut first = true
  for ch in s {
    if first && (ch == '-' || ch == '+') {
      neg = ch == '-'
      first = false
      continue
    }
    first = false
    let v = ch.to_int()
    if v < 48 || v > 57 {
      return None
    }
    acc = acc * 10 + (v - 48)
  }
  if first {
    return None // empty or sign-only
  }
  Some(if neg { -acc } else { acc })
}

///|
/// Manual double parse: [sign] digits [ . digits ] [ (e|E) [sign] digits ].
/// Good enough for 1e-9 relative tolerance against duckdb goldens.
fn parse_f64(s : String) -> Double? {
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
  while i < n && chars[i].to_int() >= 48 && chars[i].to_int() <= 57 {
    int_part = int_part * 10L + (chars[i].to_int() - 48).to_int64()
    int_digits += 1
    i += 1
  }
  let mut frac_part = 0L
  let mut frac_len = 0
  if i < n && chars[i] == '.' {
    i += 1
    while i < n && chars[i].to_int() >= 48 && chars[i].to_int() <= 57 {
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
  let mut value = int_part.to_double() +
    frac_part.to_double() / pow10_int(frac_len)
  if i < n && (chars[i] == 'e' || chars[i] == 'E') {
    i += 1
    let mut exp_neg = false
    if i < n && (chars[i] == '-' || chars[i] == '+') {
      exp_neg = chars[i] == '-'
      i += 1
    }
    let mut exp = 0
    let mut exp_digits = 0
    while i < n && chars[i].to_int() >= 48 && chars[i].to_int() <= 57 {
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
      value = value / pow10_int(exp)
    } else {
      value = value * pow10_int(exp)
    }
  }
  if i != n {
    return None // trailing junk
  }
  Some(if neg { -value } else { value })
}

///|
fn pow10_int(e : Int) -> Double {
  let mut v = 1.0
  for _ in 0..<e {
    v = v * 10.0
  }
  v
}
