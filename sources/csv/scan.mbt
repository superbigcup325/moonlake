// CSV scanning: a byte-level reader (reader.mbt) records per-cell
// offsets, type inference samples the first rows, and materialization
// parses cells straight into typed vectors. Empty cells become NULL.

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
  scan_bytes(@utf8.encode(content), table_name)
}

///|
/// Scan a CSV file from disk (native target; wasm targets load files via
/// the playground bridge instead). Reads bytes — no full-file String
/// decode on the way in.
pub fn scan_file(
  path : String,
  table_name : String,
) -> @catalog.TableEntry raise @types.SqlError {
  let content = @fs.read_file_to_bytes(path) catch {
    _ => raise @types.SqlError::Scan("cannot read file at \{path}")
  }
  scan_bytes(content, table_name)
}

///|
/// Scan several CSV files into ONE table: the first file's header and
/// inferred types drive everything, and every later file must repeat
/// the same header (clean scan error otherwise). Partitioned datasets
/// (`--csv 'parts/part-*.csv'`) land as a single relation.
pub fn scan_files(
  paths : Array[String],
  table_name : String,
) -> @catalog.TableEntry raise @types.SqlError {
  if paths.length() == 0 {
    raise @types.SqlError::Scan("no CSV files to scan")
  }
  let first = read_bytes(paths[0])
  let raw = scan_csv(strip_bom(first))
  if raw.n_rows() == 0 {
    raise @types.SqlError::Scan("CSV has no header row")
  }
  let header : Array[String] = []
  for i in raw.row_start(0)..<raw.row_start(1) {
    header.push(raw.decode(i))
  }
  let dtypes = infer_types(header, strip_bom(first), raw)
  let columns : Array[@catalog.Column] = []
  for i, h in header {
    columns.push({ name: h, dtype: dtypes[i], })
  }
  let schema : @catalog.TableSchema = { table: table_name, columns, }
  let batches : Array[@types.DataBatch] = []
  for i, path in paths {
    let content = if i == 0 { first } else { read_bytes(path) }
    if i > 0 {
      validate_header(path, content, header)
    }
    append_batches(batches, dtypes, content, header)
  }
  if batches.length() == 0 {
    batches.push(build_batch(dtypes, first, raw, 0, 0))
  }
  { schema, batches, }
}

///|
fn read_bytes(path : String) -> Bytes raise @types.SqlError {
  @fs.read_file_to_bytes(path) catch {
    _ => raise @types.SqlError::Scan("cannot read file at \{path}")
  }
}

///|
fn strip_bom(content : Bytes) -> Bytes {
  if content.length() >= 3 &&
    content[0].to_int() == 0xEF &&
    content[1].to_int() == 0xBB &&
    content[2].to_int() == 0xBF {
    content[3:].to_owned()
  } else {
    content
  }
}

///|
/// Every appended file must repeat the first file's header verbatim —
/// a drifted column list would silently misalign the typed vectors.
fn validate_header(
  path : String,
  content : Bytes,
  header : Array[String],
) -> Unit raise @types.SqlError {
  let raw = scan_csv(strip_bom(content))
  if raw.n_rows() == 0 {
    raise @types.SqlError::Scan("\{path}: CSV has no header row")
  }
  for i, name in header {
    let cell = raw.row_start(0) + i
    if raw.row_start(1) - raw.row_start(0) != header.length() ||
      raw.decode(cell) != name {
      raise @types.SqlError::Scan(
        "\{path}: header does not match the first file (expected \{header.join(",")})",
      )
    }
  }
}

///|
/// Materialize one file's data rows as whole batches appended to the
/// table. Types come from the first file; an unparsable cell is a
/// clean scan error with the file's own row context.
fn append_batches(
  batches : Array[@types.DataBatch],
  dtypes : Array[@types.DataType],
  content : Bytes,
  _header : Array[String],
) -> Unit raise @types.SqlError {
  let content = strip_bom(content)
  let raw = scan_csv(content)
  let n = raw.n_rows() - 1
  let mut start = 0
  while start < n {
    let end = if start + BATCH_SIZE < n { start + BATCH_SIZE } else { n }
    batches.push(build_batch(dtypes, content, raw, start, end))
    start = end
  }
}

///|
fn scan_bytes(
  content : Bytes,
  table_name : String,
) -> @catalog.TableEntry raise @types.SqlError {
  // strip a UTF-8 BOM (Excel exports) so it does not glue onto the
  // first header cell's name
  let content = if content.length() >= 3 &&
    content[0].to_int() == 0xEF &&
    content[1].to_int() == 0xBB &&
    content[2].to_int() == 0xBF {
    content[3:].to_owned()
  } else {
    content
  }
  let raw = scan_csv(content)
  if raw.n_rows() == 0 {
    raise @types.SqlError::Scan("CSV has no header row")
  }
  let header : Array[String] = []
  for i in raw.row_start(0)..<raw.row_start(1) {
    header.push(raw.decode(i))
  }
  build_entry(table_name, content, raw, header)
}

///|
fn build_entry(
  table_name : String,
  buf : Bytes,
  raw : RawCsv,
  header : Array[String],
) -> @catalog.TableEntry raise @types.SqlError {
  if header.length() == 0 {
    raise @types.SqlError::Scan("CSV has no header row")
  }
  let dtypes = infer_types(header, buf, raw)
  let columns : Array[@catalog.Column] = []
  for i, h in header {
    columns.push({ name: h, dtype: dtypes[i], })
  }
  let schema : @catalog.TableSchema = { table: table_name, columns, }
  let batches : Array[@types.DataBatch] = []
  let n = raw.n_rows() - 1 // data rows after the header
  let mut start = 0
  while start < n {
    let end = if start + BATCH_SIZE < n { start + BATCH_SIZE } else { n }
    batches.push(build_batch(dtypes, buf, raw, start, end))
    start = end
  }
  if n == 0 {
    // zero-row table: emit a single empty batch so column count stays visible
    batches.push(build_batch(dtypes, buf, raw, 0, 0))
  }
  { schema, batches, }
}

///|
/// Infer one type per column from the first INFER_SAMPLE data rows:
/// every sampled non-empty cell must parse as the candidate type.
/// Order: int32, int64, float64, bool, date, else string — an integer
/// too big for int32 widens to int64, one too big for int64 falls to
/// float64 (DuckDB-style sniffing), never wraps. All-null columns
/// infer as string.
fn infer_types(
  header : Array[String],
  buf : Bytes,
  raw : RawCsv,
) -> Array[@types.DataType] {
  let data_rows = raw.n_rows() - 1
  let sample = if data_rows < INFER_SAMPLE { data_rows } else { INFER_SAMPLE }
  let dtypes : Array[@types.DataType] = []
  for c in 0..<header.length() {
    let mut all_i32 = true
    let mut all_i64 = true
    let mut all_double = true
    let mut all_bool = true
    let mut all_date = true
    let mut seen = false
    for r in 1..<raw.n_rows() {
      if r > sample {
        break
      }
      let i = raw.row_start(r) + c
      if raw.is_empty_cell(i) {
        continue // NULL cells never veto a type
      }
      let s = raw.starts.data[i]
      let e = raw.ends.data[i]
      seen = true
      if @types.parse_i32_bytes(buf, s, e) is None {
        all_i32 = false
      }
      if @types.parse_i64_bytes(buf, s, e) is None {
        all_i64 = false
      }
      if @types.parse_f64_bytes(buf, s, e) is None {
        all_double = false
      }
      if @types.parse_bool_bytes(buf, s, e) is None {
        all_bool = false
      }
      if @types.parse_date_bytes(buf, s, e) is None {
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
/// Scalars on the way in, and no Strings for numeric/boolean/date
/// columns. Empty cells mark the slot invalid (NULL); an unparsable
/// non-empty cell is a scan error with row/column context. Row indices
/// here are data-row indices (the header is row 0 of the raw scan).
fn build_column(
  dtype : @types.DataType,
  buf : Bytes,
  raw : RawCsv,
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
        let i = raw.row_start(r + 1) + c
        if !raw.is_empty_cell(i) {
          let s = raw.starts.data[i]
          let e = raw.ends.data[i]
          let w = r - start
          match @types.parse_i32_bytes(buf, s, e) {
            Some(v) => {
              d[w] = v
              valid[w] = true
            }
            None =>
              raise @types.SqlError::Scan(
                "row \{r + 2} column \{c}: cannot parse \"\{raw.decode(i)}\" as int32",
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
        let i = raw.row_start(r + 1) + c
        if !raw.is_empty_cell(i) {
          let s = raw.starts.data[i]
          let e = raw.ends.data[i]
          let w = r - start
          match @types.parse_i64_bytes(buf, s, e) {
            Some(v) => {
              d[w] = v
              valid[w] = true
            }
            None =>
              raise @types.SqlError::Scan(
                "row \{r + 2} column \{c}: cannot parse \"\{raw.decode(i)}\" as int64",
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
        let i = raw.row_start(r + 1) + c
        if !raw.is_empty_cell(i) {
          let s = raw.starts.data[i]
          let e = raw.ends.data[i]
          let w = r - start
          match @types.parse_f64_bytes(buf, s, e) {
            Some(v) => {
              d[w] = v
              valid[w] = true
            }
            None =>
              raise @types.SqlError::Scan(
                "row \{r + 2} column \{c}: cannot parse \"\{raw.decode(i)}\" as float64",
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
        let i = raw.row_start(r + 1) + c
        if !raw.is_empty_cell(i) {
          let s = raw.starts.data[i]
          let e = raw.ends.data[i]
          let w = r - start
          match @types.parse_bool_bytes(buf, s, e) {
            Some(v) => {
              d[w] = v
              valid[w] = true
            }
            None =>
              raise @types.SqlError::Scan(
                "row \{r + 2} column \{c}: cannot parse \"\{raw.decode(i)}\" as bool",
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
        let i = raw.row_start(r + 1) + c
        if !raw.is_empty_cell(i) {
          let s = raw.starts.data[i]
          let e = raw.ends.data[i]
          let w = r - start
          match @types.parse_date_bytes(buf, s, e) {
            Some(v) => {
              d[w] = v
              valid[w] = true
            }
            None =>
              raise @types.SqlError::Scan(
                "row \{r + 2} column \{c}: cannot parse \"\{raw.decode(i)}\" as date",
              )
          }
        }
      }
      @types.DateV(d, valid)
    }
    Str => {
      let d : FixedArray[String] = FixedArray::make(n, "")
      let valid : FixedArray[Bool] = FixedArray::make(n, false)
      for r in start..<end {
        let i = raw.row_start(r + 1) + c
        let w = r - start
        if !raw.is_empty_cell(i) {
          d[w] = raw.decode(i)
          valid[w] = true
        }
      }
      @types.StrV(d, valid)
    }
  }
}

///|
fn build_batch(
  dtypes : Array[@types.DataType],
  buf : Bytes,
  raw : RawCsv,
  start : Int,
  end : Int,
) -> @types.DataBatch raise @types.SqlError {
  let columns : Array[@types.ColumnVector] = []
  for c, dtype in dtypes {
    columns.push(build_column(dtype, buf, raw, start, end, c))
  }
  @types.DataBatch::new(columns, end - start)
}
