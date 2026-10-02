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
            match @types.parse_i32(cell) {
              Some(v) => vec.set(r - start, @types.Scalar::Int32(v))
              None =>
                raise @types.SqlError::Scan(
                  "row \{r + 1} column \{c}: cannot parse \"\{cell}\" as int32",
                )
            }
          Float64 =>
            match @types.parse_f64(cell) {
              Some(v) => vec.set(r - start, @types.Scalar::Float64(v))
              None =>
                raise @types.SqlError::Scan(
                  "row \{r + 1} column \{c}: cannot parse \"\{cell}\" as float64",
                )
            }
          Bool =>
            match @types.parse_bool(cell) {
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
          Int64 =>
            match @types.parse_i64(cell) {
              Some(v) => vec.set(r - start, @types.Scalar::Int64(v))
              None =>
                raise @types.SqlError::Scan(
                  "row \{r + 1} column \{c}: cannot parse \"\{cell}\" as int64",
                )
            }
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
