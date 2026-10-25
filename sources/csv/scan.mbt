// CSV scanning: a byte-level reader (reader.mbt) records per-cell
// offsets, type inference samples the first rows at registration, and the
// data itself is materialized batch by batch, only for the columns a query
// projects. A file is read in byte ranges: registration touches only the
// header and the sample, and one scan holds one range's offsets rather than
// the whole file's, which is what large CSV scans cost most of their memory on.
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
/// Bytes per ranged read while scanning a file. Wide enough for several
/// thousand lineitem rows, so per-read overhead disappears; narrow enough that
/// the per-cell offset index for one range stays a few MB instead of growing
/// with the file.
const CHUNK_BYTES : Int32 = 4 * 1024 * 1024

///|
/// Bytes read when all a registration needs is the header and the inference
/// sample. Grown when a row does not fit.
const PREFIX_BYTES : Int32 = 64 * 1024

///|
/// Where a source's bytes come from: content the caller already holds
/// (playground, tests) or a file read by range. Reading is a pair of function
/// fields, not an enum with a `File` arm: an enum arm would keep the
/// filesystem call reachable from `scan_string`, and a wasm-gc build that only
/// scans in-memory content (the browser playground) must not import the host's
/// fs module at all.
priv struct CsvInput {
  label : String // empty for in-memory content: the table name is used
  size : () -> Int64 raise @types.SqlError
  read_at : (Int64, Int32) -> Bytes raise @types.SqlError
  // drop cached bytes when a scan starts on this input: hosts without range
  // reads keep a whole-file snapshot, and a table must still see the file as
  // it is when the scan opens
  reset : () -> Unit
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
  scan_inputs([memory_input(@utf8.encode(content))], table_name)
}

///|
/// Scan a CSV file from disk (native target; wasm targets load files via
/// the playground bridge instead). Registration reads the header and the
/// inference sample only, and then keeps the path: the data is read back by
/// `open`, in ranges.
pub fn scan_file(
  path : String,
  table_name : String,
) -> @catalog.TableEntry raise @types.SqlError {
  scan_inputs([file_input(path)], table_name)
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
    inputs.push(file_input(p))
  }
  scan_inputs(inputs, table_name)
}

///|
/// In-memory input: the bytes are already in hand, no filesystem involved. A
/// range is a copy of the slice.
fn memory_input(content : Bytes) -> CsvInput {
  let length = content.length()
  let total = length.to_int64()
  {
    label: "",
    size: fn() { total },
    read_at: (offset, count) => {
      let end = offset + count.to_int64()
      if offset < 0L || count < 0 || end > total {
        raise @types.SqlError::Scan(
          "cannot read \{count} bytes at \{offset} of a \{length} byte buffer",
        )
      }
      let start = offset.to_int()
      let out : @buffer.Buffer = @buffer.Buffer::Buffer(size_hint=count)
      out.write_bytes(content[start:start + count])
      out.to_bytes()
    },
    reset: fn() { () },
  }
}

///|
/// A file's name for error messages; in-memory content reports the table.
fn input_label(input : CsvInput, table_name : String) -> String {
  if input.label == "" {
    table_name
  } else {
    input.label
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
/// Read a prefix of a source holding at least `want_rows` records (the whole
/// source when it is shorter), widening the range when a record does not fit.
/// A record cut in half by the range does not count: the schema must be
/// inferred from whole cells.
fn read_prefix(
  input : CsvInput,
  want_rows : Int32,
) -> Bytes raise @types.SqlError {
  let size = (input.size)()
  let mut want = PREFIX_BYTES
  while true {
    let count = if size < want.to_int64() { size.to_int() } else { want }
    let bytes = (input.read_at)(0L, count)
    let at_eof = count.to_int64() >= size
    let (raw, _) = scan_chunk(bytes, at_eof)
    if raw.n_rows() >= want_rows || at_eof {
      return bytes
    }
    want = want * 4
  }
  b""
}

///|
/// Infer the schema (header + sampled types) and check every file's header,
/// then hand the paths (or the in-memory bytes) to the lazy source.
fn scan_inputs(
  inputs : Array[CsvInput],
  table_name : String,
) -> @catalog.TableEntry raise @types.SqlError {
  let buf = strip_bom(read_prefix(inputs[0], INFER_SAMPLE + 1))
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
  let label0 = input_label(inputs[0], table_name)
  // every sampled row must hold the header's cell count; a prefix that stops
  // short of EOF can end mid-record, and that fragment is not the file's data
  // (the scan reports a ragged row against the range it really sits in)
  let mut sample_rows = raw.n_rows()
  if buf.length().to_int64() < (inputs[0].size)() && sample_rows > 1 {
    sample_rows -= 1
  }
  check_width(raw, header.length(), 1, sample_rows - 1, 0, label0)
  let dtypes = infer_types(header, buf, raw)
  for i in 1..<inputs.length() {
    validate_header(
      input_label(inputs[i], table_name),
      read_prefix(inputs[i], 2),
      header,
    )
  }
  let names = unique_names(header)
  let columns : Array[@catalog.Column] = []
  for i, h in names {
    columns.push({ name: h, dtype: dtypes[i], })
  }
  let schema : @catalog.TableSchema = { table: table_name, columns, }
  let source : CsvSource = { table_name, header, dtypes, inputs, }
  @catalog.TableEntry::from_source(schema, source)
}

///|
/// Every file must repeat the first file's header verbatim — a drifted
/// column list would silently misalign the typed vectors. The prefix carries
/// a byte order mark when the file has one.
fn validate_header(
  label : String,
  content : Bytes,
  header : Array[String],
) -> Unit raise @types.SqlError {
  let raw = scan_csv_prefix(strip_bom(content), 2)
  if raw.n_rows() == 0 {
    raise @types.SqlError::Scan("\{label}: CSV has no header row")
  }
  if !check_header(raw, header) {
    raise @types.SqlError::Scan(
      "\{label}: header does not match the first file (expected \{header.join(",")})",
    )
  }
}

///|
/// Does this scan's first row repeat `header` verbatim? Called on the first
/// range of every file at scan time too, since a file can change between
/// registration and scan.
fn check_header(raw : RawCsv, header : Array[String]) -> Bool {
  if raw.n_rows() == 0 || raw.row_start(1) - raw.row_start(0) != header.length() {
    return false
  }
  for i, name in header {
    if raw.decode(raw.row_start(0) + i) != name {
      return false
    }
  }
  true
}

///|
/// Every data row must hold exactly the header's cell count. A short row's
/// cell offsets run into the next row's cells — the row would silently answer
/// with its neighbour's values — and on a range's last row they run past the
/// cell arrays, which is a crash. A row with extra cells is equally wrong: the
/// file does not match the header it registered under, so no cell means what
/// the schema says. Errors report the file row (1-based, header included) and
/// the file, the same numbering `build_column` uses.
fn check_width(
  raw : RawCsv,
  ncols : Int32,
  skip : Int32, // raw row of the first data row in this range (1 = header here)
  rows : Int32, // data rows to check
  row_base : Int32, // data rows of the file before this range
  label : String,
) -> Unit raise @types.SqlError {
  for r in skip..<(skip + rows) {
    let got = raw.n_cells(r)
    if got != ncols {
      raise @types.SqlError::Scan(
        "\{label}: row \{row_base + r - skip + 2} has \{got} field\{if got == 1 { "" } else { "s" }}, expected \{ncols}",
      )
    }
  }
}

///|
/// Column names for the schema. A repeated header name is a data defect: the
/// second column is unreachable (both names bind to the first) and a JSON row
/// would repeat a key, so repeats get DuckDB's read_csv rename — the second
/// `a` becomes `a_1`, the third `a_2`, and a generated name never collides
/// with one the header already uses. The bytes of the file are untouched:
/// per-file header validation compares the names as written.
fn unique_names(header : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for name in header {
    let mut candidate = name
    let mut n = 0
    while has_name(out, candidate) {
      n += 1
      candidate = "\{name}_\{n}"
    }
    out.push(candidate)
  }
  out
}

///|
fn has_name(names : Array[String], name : String) -> Bool {
  for n in names {
    if n == name {
      return true
    }
  }
  false
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
      if c >= raw.n_cells(r) {
        continue // a short row carries no cell for this column
      }
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
/// One scan over the source: files in order, and inside a file byte ranges.
/// A range is indexed, trimmed to whole batches, materialized and then
/// dropped, so the scan holds one range's cell offsets instead of offsets for
/// every cell of the file.
priv struct CsvStream {
  table_name : String
  header : Array[String]
  dtypes : Array[@types.DataType] // projected
  columns : Array[Int32] // projected, original column indexes
  inputs : Array[CsvInput]
  mut next_file : Int32
  mut buf : Bytes // the current range's bytes
  mut raw : RawCsv? // the current range's cell offsets
  mut skip : Int32 // raw rows before this range's first data row
  mut pos : Int32 // next data row of this range
  mut rows_left : Int32 // data rows in this range
  mut row_base : Int32 // data rows of this file already emitted
  mut chunk_base : Int64 // where the current range starts in the file
  mut file_size : Int64
  mut header_pending : Bool // this file's header is not checked yet
  mut emitted : Bool
  mut finished : Bool
}

///|
impl @catalog.BatchStream for CsvStream with fn next(self) -> @types.DataBatch? raise @types.SqlError {
  if self.finished {
    return None
  }
  while true {
    if self.pos >= self.rows_left {
      // this range is fully emitted: drop its bytes and index, load the next
      self.row_base = self.row_base + self.rows_left
      self.pos = 0
      self.rows_left = 0
      self.raw = None
      if !self.load_chunk() {
        if !self.start_next_file() {
          self.finished = true
          // a table with no rows still reports its column layout once
          if !self.emitted {
            self.emitted = true
            return Some(empty_batch(self.dtypes))
          }
          return None
        }
        continue
      }
    }
    let raw = self.raw.unwrap()
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
      self.skip,
      self.row_base,
      self.pos,
      end,
    )
    self.pos = end
    self.emitted = true
    return Some(batch)
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
    skip: 0,
    pos: 0,
    rows_left: 0,
    row_base: 0,
    chunk_base: 0L,
    file_size: 0L,
    header_pending: true,
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
/// Start the next input file, or report that every input has been consumed.
/// The header is checked against the registration-time one when the file's
/// first range arrives, since the file can change between the two.
fn CsvStream::start_next_file(self : CsvStream) -> Bool raise @types.SqlError {
  while self.next_file < self.inputs.length() {
    let input = self.inputs[self.next_file]
    self.next_file += 1
    (input.reset)()
    let size = (input.size)()
    if size == 0L {
      raise @types.SqlError::Scan(
        "\{input_label(input, self.table_name)}: CSV has no header row",
      )
    }
    self.file_size = size
    self.chunk_base = 0L
    self.row_base = 0
    self.pos = 0
    self.rows_left = 0
    self.raw = None
    self.header_pending = true
    return true
  }
  false
}

///|
/// Read and index the next range of the current file. Returns false when the
/// file is exhausted; a file that holds only a header is validated and
/// skipped. A range that cannot hold one whole record (a very long line) is
/// widened until it can.
fn CsvStream::load_chunk(self : CsvStream) -> Bool raise @types.SqlError {
  if self.next_file == 0 {
    return false // no file has started yet
  }
  let input = self.inputs[self.next_file - 1]
  let label = input_label(input, self.table_name)
  while self.chunk_base < self.file_size {
    let at_start = self.chunk_base == 0L
    let mut want = CHUNK_BYTES
    while true {
      let rest = self.file_size - self.chunk_base
      let count = if rest < want.to_int64() { rest.to_int() } else { want }
      let bytes = (input.read_at)(self.chunk_base, count)
      let at_eof = self.chunk_base + count.to_int64() >= self.file_size
      // a byte order mark can only sit at the very front of the file
      let stripped = if at_start { strip_bom(bytes) } else { bytes }
      let base = self.chunk_base +
        (bytes.length() - stripped.length()).to_int64()
      let (raw, consumed) = scan_chunk(stripped, at_eof)
      let skip : Int32 = if self.header_pending { 1 } else { 0 }
      let data_rows = raw.n_rows() - skip
      if data_rows <= 0 {
        if !at_eof {
          want = want * 2
          continue
        }
        if self.header_pending {
          if raw.n_rows() == 0 {
            raise @types.SqlError::Scan("\{label}: CSV has no header row")
          }
          self.check_chunk_header(raw, label)
          self.header_pending = false
        }
        // header only, or trailing blank lines: nothing left to read
        self.chunk_base = self.file_size
        return false
      }
      if self.header_pending {
        self.check_chunk_header(raw, label)
        self.header_pending = false
      }
      // whole batches only, so a batch never straddles two ranges; the rows
      // past the last whole batch are read again as the start of the next one
      let mut usable = data_rows
      let mut next_base = base + consumed.to_int64()
      if data_rows > BATCH_SIZE {
        let whole = data_rows - data_rows % BATCH_SIZE
        if whole < data_rows {
          usable = whole
          next_base = base + raw.cut_rows(skip + whole).to_int64()
        }
      }
      // every row this range will emit must hold the header's cell count
      check_width(raw, self.header.length(), skip, usable, self.row_base, label)
      self.buf = stripped
      self.raw = Some(raw)
      self.skip = skip
      self.pos = 0
      self.rows_left = usable
      self.chunk_base = next_base
      return true
    }
  }
  false
}

///|
/// The header of a file's first range must repeat the header the schema was
/// inferred from.
fn CsvStream::check_chunk_header(
  self : CsvStream,
  raw : RawCsv,
  label : String,
) -> Unit raise @types.SqlError {
  if !check_header(raw, self.header) {
    raise @types.SqlError::Scan(
      "\{label}: header does not match the first file (expected \{self.header.join(",")})",
    )
  }
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
/// non-empty cell is a scan error with row/column context.
///
/// `start..<end` are rows of the current chunk, `skip` is the raw row the
/// chunk's first data row sits at (1 while the chunk still holds the header),
/// and `row_base` is how many data rows of the file came before it: error
/// messages report file rows, so a chunked scan numbers rows exactly like a
/// whole-file one.
fn build_column(
  dtype : @types.DataType,
  buf : Bytes,
  raw : RawCsv,
  skip : Int32,
  row_base : Int32,
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
        let i = rows_data.unsafe_get(skip + r) + c
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
                "row \{row_base + r + 2} column \{c}: cannot parse \"\{raw.decode(i)}\" as int32",
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
        let i = rows_data.unsafe_get(skip + r) + c
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
                "row \{row_base + r + 2} column \{c}: cannot parse \"\{raw.decode(i)}\" as int64",
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
        let i = rows_data.unsafe_get(skip + r) + c
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
                "row \{row_base + r + 2} column \{c}: cannot parse \"\{raw.decode(i)}\" as float64",
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
        let i = rows_data.unsafe_get(skip + r) + c
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
                "row \{row_base + r + 2} column \{c}: cannot parse \"\{raw.decode(i)}\" as bool",
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
        let i = rows_data.unsafe_get(skip + r) + c
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
                "row \{row_base + r + 2} column \{c}: cannot parse \"\{raw.decode(i)}\" as date",
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
        let i = rows_data.unsafe_get(skip + r) + c
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
/// Materialize rows `start..<end` of one chunk, projected columns only.
fn build_batch(
  dtypes : Array[@types.DataType],
  columns : Array[Int32],
  buf : Bytes,
  raw : RawCsv,
  skip : Int32,
  row_base : Int32,
  start : Int32,
  end : Int32,
) -> @types.DataBatch raise @types.SqlError {
  let out : Array[@types.ColumnVector] = []
  for i, dtype in dtypes {
    out.push(
      build_column(dtype, buf, raw, skip, row_base, start, end, columns[i]),
    )
  }
  @types.DataBatch::new(out, end - start)
}
