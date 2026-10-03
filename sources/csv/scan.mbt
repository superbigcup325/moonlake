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
  // strip a UTF-8 BOM so it does not glue onto the first header cell's
  // name (Excel-exported CSVs carry one)
  let content = if content.has_prefix("\u{FEFF}") {
    content[1:].to_owned()
  } else {
    content
  }
  let csv = @NyaCSV.CSV::parse_string(content)
  build_entry(table_name, csv.header(), csv.data())
}

///|
/// Scan a CSV file from disk (native target; wasm targets load files via
/// the playground bridge instead). Reads bytes and hands them to NyaCSV
/// directly — no full-file String decode on the way in.
pub fn scan_file(
  path : String,
  table_name : String,
) -> @catalog.TableEntry raise @types.SqlError {
  let content = @fs.read_file_to_bytes(path) catch {
    _ => raise @types.SqlError::Scan("cannot read file at \{path}")
  }
  // UTF-8 BOM (Excel exports): rare, so take the String path when one
  // is present rather than copying the bytes to shift it off
  let has_bom = content.length() >= 3 &&
    content[0].to_int() == 0xEF &&
    content[1].to_int() == 0xBB &&
    content[2].to_int() == 0xBF
  if has_bom {
    return scan_file_string(path, table_name)
  }
  let csv = @NyaCSV.CSV::parse_bytes(content)
  build_entry(table_name, csv.header(), csv.data())
}

///|
/// The String-based path, kept for BOM-carrying files; scan_string
/// strips the BOM at the character level.
fn scan_file_string(
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
/// int32, int64, float64, bool, date, else string — an integer too big
/// for int32 widens to int64, one too big for int64 falls to float64
/// (DuckDB-style sniffing), never wraps. All-null columns infer as string.
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
    let mut all_i32 = true
    let mut all_i64 = true
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
      if @types.parse_i32(cell) is None {
        all_i32 = false
      }
      if @types.parse_i64(cell) is None {
        all_i64 = false
      }
      if @types.parse_f64(cell) is None {
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
    } else if all_i32 {
      dtypes.push(@types.Int32)
    } else if all_i64 {
      dtypes.push(@types.Int64)
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
/// Parse one column's cells straight into typed arrays — no boxed
/// Scalars on the way in. Empty cells mark the slot invalid (NULL); an
/// unparsable non-empty cell is a scan error with row/column context.
fn build_column(
  dtype : @types.DataType,
  rows : Array[Array[String]],
  start : Int,
  end : Int,
  c : Int,
) -> @types.ColumnVector raise @types.SqlError {
  let n = end - start
  match dtype {
    Int32 => {
      let d : FixedArray[Int] = FixedArray::make(n, 0)
      let valid : FixedArray[Bool] = FixedArray::make(n, false)
      for r in start..<end {
        let cell = rows[r][c]
        if cell != "" {
          let i = r - start
          match @types.parse_i32(cell) {
            Some(v) => {
              d[i] = v
              valid[i] = true
            }
            None =>
              raise @types.SqlError::Scan(
                "row \{r + 1} column \{c}: cannot parse \"\{cell}\" as int32",
              )
          }
        }
      }
      @types.I32(d, valid)
    }
    Int64 => {
      let d : FixedArray[Int64] = FixedArray::make(n, 0L)
      let valid : FixedArray[Bool] = FixedArray::make(n, false)
      for r in start..<end {
        let cell = rows[r][c]
        if cell != "" {
          let i = r - start
          match @types.parse_i64(cell) {
            Some(v) => {
              d[i] = v
              valid[i] = true
            }
            None =>
              raise @types.SqlError::Scan(
                "row \{r + 1} column \{c}: cannot parse \"\{cell}\" as int64",
              )
          }
        }
      }
      @types.I64(d, valid)
    }
    Float64 => {
      let d : FixedArray[Double] = FixedArray::make(n, 0.0)
      let valid : FixedArray[Bool] = FixedArray::make(n, false)
      for r in start..<end {
        let cell = rows[r][c]
        if cell != "" {
          let i = r - start
          match @types.parse_f64(cell) {
            Some(v) => {
              d[i] = v
              valid[i] = true
            }
            None =>
              raise @types.SqlError::Scan(
                "row \{r + 1} column \{c}: cannot parse \"\{cell}\" as float64",
              )
          }
        }
      }
      @types.F64(d, valid)
    }
    Bool => {
      let d : FixedArray[Bool] = FixedArray::make(n, false)
      let valid : FixedArray[Bool] = FixedArray::make(n, false)
      for r in start..<end {
        let cell = rows[r][c]
        if cell != "" {
          let i = r - start
          match @types.parse_bool(cell) {
            Some(v) => {
              d[i] = v
              valid[i] = true
            }
            None =>
              raise @types.SqlError::Scan(
                "row \{r + 1} column \{c}: cannot parse \"\{cell}\" as bool",
              )
          }
        }
      }
      @types.BoolV(d, valid)
    }
    Date => {
      let d : FixedArray[Int] = FixedArray::make(n, 0)
      let valid : FixedArray[Bool] = FixedArray::make(n, false)
      for r in start..<end {
        let cell = rows[r][c]
        if cell != "" {
          let i = r - start
          match @types.parse_date(cell) {
            Some(v) => {
              d[i] = v
              valid[i] = true
            }
            None =>
              raise @types.SqlError::Scan(
                "row \{r + 1} column \{c}: cannot parse \"\{cell}\" as date",
              )
          }
        }
      }
      @types.DateV(d, valid)
    }
    Str => {
      // cells arrive as NyaCSV-owned Strings: move them, no re-boxing
      let d : FixedArray[String] = FixedArray::make(n, "")
      let valid : FixedArray[Bool] = FixedArray::make(n, false)
      for r in start..<end {
        let cell = rows[r][c]
        let i = r - start
        if cell != "" {
          d[i] = cell
          valid[i] = true
        }
      }
      @types.StrV(d, valid)
    }
  }
}

///|
fn build_batch(
  dtypes : Array[@types.DataType],
  rows : Array[Array[String]],
  start : Int,
  end : Int,
) -> @types.DataBatch raise @types.SqlError {
  let columns : Array[@types.ColumnVector] = []
  for c, dtype in dtypes {
    columns.push(build_column(dtype, rows, start, end, c))
  }
  @types.DataBatch::new(columns, end - start)
}
