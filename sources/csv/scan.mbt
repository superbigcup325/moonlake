// CSV scanning: a byte-level reader (reader.mbt) records per-cell
// offsets, type inference samples the first rows at registration, and the
// data itself is materialized batch by batch, only for the columns a query
// projects. Registering a file therefore reads it (the fs API has no
// range reads) but keeps no bytes: the source re-reads on `open`.
//
// Empty cells become NULL. An empty table still emits one zero-row batch,
// with the projected columns, so the engine sees the layout.

///|
/// Rows per DataBatch emitted by the CSV scan.
const BATCH_SIZE : Int32 = @catalog.SCAN_BATCH_ROWS

///|
/// Sample rows consulted per column when inferring a type.
const INFER_SAMPLE : Int32 = 100

///|
/// Where a source's bytes come from: content the caller already holds
/// (playground, tests) or a file to re-read on demand.
priv enum CsvInput {
  Memory(Bytes)
  File(String)
}

///|
/// A lazily scanned CSV table: header, inferred types and where the bytes
/// live. No cell has been parsed into a typed column yet.
priv struct CsvSource {
  table_name : String
  header : Array[String]
  dtypes : Array[@types.DataType]
  inputs : Array[CsvInput]
}

///|
/// Scan CSV content (with a header row) into a table entry. The bytes stay
/// with the source (the caller already has them); decoding starts at `open`.
pub fn scan_string(
  content : String,
  table_name : String,
) -> @catalog.TableEntry raise @types.SqlError {
  scan_inputs([CsvInput::Memory(@utf8.encode(content))], table_name)
}

///|
/// Scan a CSV file from disk (native target; wasm targets load files via
/// the playground bridge instead). Registration reads the file to infer the
/// schema and then keeps only the path: the data is read back by `open`.
pub fn scan_file(
  path : String,
  table_name : String,
) -> @catalog.TableEntry raise @types.SqlError {
  scan_inputs([CsvInput::File(path)], table_name)
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
  let inputs : Array[CsvInput] = []
  for p in paths {
    inputs.push(CsvInput::File(p))
  }
  scan_inputs(inputs, table_name)
}

///|
/// Open the source's bytes. `Memory` inputs are already in hand; `File`
/// inputs are read here, so nothing is held between registration and scan.
fn read_input(input : CsvInput) -> Bytes raise @types.SqlError {
  match input {
    Memory(content) => content
    File(path) =>
      @fs.read_file_to_bytes(path) catch {
        _ => raise @types.SqlError::Scan("cannot read file at \{path}")
      }
  }
}

///|
/// A file's name for error messages; in-memory content reports the table.
fn input_label(input : CsvInput, table_name : String) -> String {
  match input {
    Memory(_) => table_name
    File(path) => path
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
/// Infer the schema (header + sampled types) and check every file's header,
/// then hand the paths (or the in-memory bytes) to the lazy source.
fn scan_inputs(
  inputs : Array[CsvInput],
  table_name : String,
) -> @catalog.TableEntry raise @types.SqlError {
  let first = read_input(inputs[0])
  let buf = strip_bom(first)
  // only the header and the inference sample are parsed here: the rest of
  // the file is not touched until a query opens the scan
  let raw = scan_csv_prefix(buf, INFER_SAMPLE + 1)
  if raw.n_rows() == 0 {
    raise @types.SqlError::Scan("CSV has no header row")
  }
  let header : Array[String] = []
  for i in raw.row_start(0)..<raw.row_start(1) {
    header.push(raw.decode(i))
  }
  if header.length() == 0 {
    raise @types.SqlError::Scan("CSV has no header row")
  }
  let dtypes = infer_types(header, buf, raw)
  for i in 1..<inputs.length() {
    let content = read_input(inputs[i])
    validate_header(
      input_label(inputs[i], table_name),
      strip_bom(content),
      header,
    )
  }
  let columns : Array[@catalog.Column] = []
  for i, h in header {
    columns.push({ name: h, dtype: dtypes[i], })
  }
  let schema : @catalog.TableSchema = { table: table_name, columns, }
  let source : CsvSource = { table_name, header, dtypes, inputs, }
  @catalog.TableEntry::from_source(schema, source)
}

///|
/// Every file must repeat the first file's header verbatim — a drifted
/// column list would silently misalign the typed vectors.
fn validate_header(
  label : String,
  content : Bytes,
  header : Array[String],
) -> Unit raise @types.SqlError {
  let raw = scan_csv_prefix(content, 2)
  if raw.n_rows() == 0 {
    raise @types.SqlError::Scan("\{label}: CSV has no header row")
  }
  for i, name in header {
    let cell = raw.row_start(0) + i
    if raw.row_start(1) - raw.row_start(0) != header.length() ||
      raw.decode(cell) != name {
      raise @types.SqlError::Scan(
        "\{label}: header does not match the first file (expected \{header.join(",")})",
      )
    }
  }
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
      // each parser runs only while its type is still a candidate
      if all_i32 && @types.parse_i32_bytes(buf, s, e) is None {
        all_i32 = false
      }
      if all_i64 && @types.parse_i64_bytes(buf, s, e) is None {
        all_i64 = false
      }
      if all_double && @types.parse_f64_bytes(buf, s, e) is None {
        all_double = false
      }
      if all_bool && @types.parse_bool_bytes(buf, s, e) is None {
        all_bool = false
      }
      if all_date && @types.parse_date_bytes(buf, s, e) is None {
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
/// One scan over the source: walks files in order, and inside a file walks
/// data rows in BATCH_SIZE chunks. Only the projected columns are parsed.
priv struct CsvStream {
  table_name : String
  header : Array[String]
  dtypes : Array[@types.DataType] // projected
  columns : Array[Int32] // projected, original column indexes
  inputs : Array[CsvInput]
  mut next_file : Int32
  mut buf : Bytes
  mut raw : RawCsv?
  mut pos : Int32 // next data row (raw row 0 is the header)
  mut rows_left : Int32
  mut emitted : Bool
  mut finished : Bool
}

///|
impl @catalog.BatchStream for CsvStream with fn next(self) -> @types.DataBatch? raise @types.SqlError {
  if self.finished {
    return None
  }
  while true {
    match self.raw {
      Some(raw) =>
        if self.pos < self.rows_left {
          let end = if self.pos + BATCH_SIZE < self.rows_left {
            self.pos + BATCH_SIZE
          } else {
            self.rows_left
          }
          let batch = build_batch(
            self.dtypes,
            self.columns,
            self.buf,
            raw,
            self.pos,
            end,
          )
          self.pos = end
          self.emitted = true
          return Some(batch)
        }
      None => ()
    }
    // this file (if any) is exhausted: move on to the next one
    if !self.load_next() {
      self.finished = true
      // a table with no rows still reports its column layout once
      if !self.emitted {
        self.emitted = true
        return Some(empty_batch(self.dtypes))
      }
      return None
    }
  }
  None // unreachable: the loop returns
}

///|
impl @catalog.ScanSource for CsvSource with fn open(
  self,
  request : @catalog.ScanRequest,
) -> &@catalog.BatchStream raise @types.SqlError {
  let columns : Array[Int32] = []
  let dtypes : Array[@types.DataType] = []
  for c in request.projection {
    if c < 0 || c >= self.dtypes.length() {
      raise @types.SqlError::Scan(
        "projection column \{c} is outside the \{self.dtypes.length()} column table",
      )
    }
    columns.push(c)
    dtypes.push(self.dtypes[c])
  }
  let stream : CsvStream = {
    table_name: self.table_name,
    header: self.header,
    dtypes,
    columns,
    inputs: self.inputs,
    next_file: 0,
    buf: b"",
    raw: None,
    pos: 0,
    rows_left: 0,
    emitted: false,
    finished: false,
  }
  stream
}

///|
impl @catalog.ScanSource for CsvSource with fn plan(
  self,
  _request : @catalog.ScanRequest,
) -> @catalog.ScanPlan {
  // CSV has no row-group statistics, so nothing is skipped before reading;
  // the row count is unknown until the file is parsed.
  {
    files: self.inputs.length(),
    row_groups: 0,
    row_groups_skipped: 0,
    rows: None,
  }
}

///|
/// Read and index the next input file. Returns false once every input has
/// been consumed; skips files that hold only a header.
fn CsvStream::load_next(self : CsvStream) -> Bool raise @types.SqlError {
  while self.next_file < self.inputs.length() {
    let input = self.inputs[self.next_file]
    self.next_file += 1
    let content = read_input(input)
    let buf = strip_bom(content)
    let raw = scan_csv(buf)
    if raw.n_rows() == 0 {
      raise @types.SqlError::Scan(
        "\{input_label(input, self.table_name)}: CSV has no header row",
      )
    }
    // the file may have changed since registration: re-check the header
    // rather than silently misaligning the projected vectors
    validate_header(input_label(input, self.table_name), buf, self.header)
    let n = raw.n_rows() - 1
    if n > 0 {
      self.buf = buf
      self.raw = Some(raw)
      self.pos = 0
      self.rows_left = n
      return true
    }
  }
  false
}

///|
/// Zero rows, one column per projection entry.
fn empty_batch(dtypes : Array[@types.DataType]) -> @types.DataBatch {
  let columns : Array[@types.ColumnVector] = []
  for dtype in dtypes {
    columns.push(@types.ColumnVector::make(dtype, 0))
  }
  @types.DataBatch::new(columns, 0)
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
  start : Int32,
  end : Int32,
  c : Int32,
) -> @types.ColumnVector raise @types.SqlError {
  let n = end - start
  // the raw offset arrays are stable across materialization (trim ran at
  // scan end); the data locals plus unchecked reads/writes keep the
  // per-cell work to plain memory ops — every index here derives from
  // the scanner's own offsets, structurally in bounds
  let rows_data = raw.rows.data
  let starts_data = raw.starts.data
  let ends_data = raw.ends.data
  let quoted_data = raw.quoted.data
  match dtype {
    Int32 => {
      let d : FixedArray[Int32] = FixedArray::make(n, 0)
      let valid : FixedArray[Bool] = FixedArray::make(n, false)
      for r in start..<end {
        let i = rows_data.unsafe_get(r + 1) + c
        let s = starts_data.unsafe_get(i)
        let e = ends_data.unsafe_get(i)
        if !(s == e || (quoted_data.unsafe_get(i) && e - s == 2)) {
          let w = r - start
          match @types.parse_i32_bytes(buf, s, e) {
            Some(v) => {
              d.unsafe_set(w, v)
              valid.unsafe_set(w, true)
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
        let i = rows_data.unsafe_get(r + 1) + c
        let s = starts_data.unsafe_get(i)
        let e = ends_data.unsafe_get(i)
        if !(s == e || (quoted_data.unsafe_get(i) && e - s == 2)) {
          let w = r - start
          match @types.parse_i64_bytes(buf, s, e) {
            Some(v) => {
              d.unsafe_set(w, v)
              valid.unsafe_set(w, true)
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
        let i = rows_data.unsafe_get(r + 1) + c
        let s = starts_data.unsafe_get(i)
        let e = ends_data.unsafe_get(i)
        if !(s == e || (quoted_data.unsafe_get(i) && e - s == 2)) {
          let w = r - start
          match @types.parse_f64_bytes(buf, s, e) {
            Some(v) => {
              d.unsafe_set(w, v)
              valid.unsafe_set(w, true)
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
        let i = rows_data.unsafe_get(r + 1) + c
        let s = starts_data.unsafe_get(i)
        let e = ends_data.unsafe_get(i)
        if !(s == e || (quoted_data.unsafe_get(i) && e - s == 2)) {
          let w = r - start
          match @types.parse_bool_bytes(buf, s, e) {
            Some(v) => {
              d.unsafe_set(w, v)
              valid.unsafe_set(w, true)
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
      let d : FixedArray[Int32] = FixedArray::make(n, 0)
      let valid : FixedArray[Bool] = FixedArray::make(n, false)
      for r in start..<end {
        let i = rows_data.unsafe_get(r + 1) + c
        let s = starts_data.unsafe_get(i)
        let e = ends_data.unsafe_get(i)
        if !(s == e || (quoted_data.unsafe_get(i) && e - s == 2)) {
          let w = r - start
          match @types.parse_date_bytes(buf, s, e) {
            Some(v) => {
              d.unsafe_set(w, v)
              valid.unsafe_set(w, true)
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
        let i = rows_data.unsafe_get(r + 1) + c
        let w = r - start
        let s = starts_data.unsafe_get(i)
        let e = ends_data.unsafe_get(i)
        if !(s == e || (quoted_data.unsafe_get(i) && e - s == 2)) {
          d.unsafe_set(w, raw.decode(i))
          valid.unsafe_set(w, true)
        }
      }
      @types.StrV(d, valid)
    }
  }
}

///|
/// Materialize rows `start..<end` of one file, projected columns only.
fn build_batch(
  dtypes : Array[@types.DataType],
  columns : Array[Int32],
  buf : Bytes,
  raw : RawCsv,
  start : Int32,
  end : Int32,
) -> @types.DataBatch raise @types.SqlError {
  let out : Array[@types.ColumnVector] = []
  for i, dtype in dtypes {
    out.push(build_column(dtype, buf, raw, start, end, columns[i]))
  }
  @types.DataBatch::new(out, end - start)
}
