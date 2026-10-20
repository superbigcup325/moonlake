// Parquet scanning: schema and row-group statistics come from the footer,
// and data is decoded row group by row group, projected column by projected
// column, in batches of BATCH_SIZE rows.
//
// Two pushdowns happen here. Column pruning: only the projected column
// chunks are decoded at all. Row-group skipping: each group's per-column
// min/max and null count rule it out when a predicate the engine will apply
// cannot match anything inside it (stats.mbt). Both are safe because the
// engine still runs the predicate itself.
//
// Registration reads the file (the fs API has no range reads) but keeps no
// bytes when the table came from a path; `open` re-reads it. FLOAT upcasts to
// float64; a column named in `date_columns` lifts its INT32 payload to DATE,
// which keeps DATE semantics in the catalog rather than in the decoder.

///|
/// Rows per DataBatch emitted by the Parquet scan.
const BATCH_SIZE : Int32 = @catalog.SCAN_BATCH_ROWS

///|
/// Where the file's bytes live: in hand (playground, tests) or on disk.
priv enum ParquetInput {
  Memory(Bytes)
  File(String)
}

///|
/// A lazily scanned Parquet table: schema plus where the bytes live.
priv struct ParquetSource {
  dtypes : Array[@types.DataType]
  input : ParquetInput
}

///|
fn read_input(input : ParquetInput) -> Bytes raise @types.SqlError {
  match input {
    Memory(content) => content
    File(path) =>
      @fs.read_file_to_bytes(path) catch {
        _ => raise @types.SqlError::Scan("cannot read file at \{path}")
      }
  }
}

///|
fn check_version(meta : FileMeta) -> Unit raise @types.SqlError {
  if meta.version != 1 && meta.version != 2 {
    raise unsupported(
      "file version \{meta.version} is not supported (readers accept 1 and 2)",
    )
  }
}

///|
/// The logical type the engine gets for one leaf. Written down at
/// registration so an unsupported physical type fails before any query runs,
/// while a column that is merely encoded in an unsupported way still fails
/// only when somebody reads it (so pruning can leave it alone).
fn column_dtype(
  el : SchemaElement,
  is_date : Bool,
) -> @types.DataType raise @types.SqlError {
  match el.physical {
    Some(BooleanT) => @types.Bool
    Some(Int32T) => if is_date { @types.Date } else { @types.Int32 }
    Some(Int64T) => @types.Int64
    Some(FloatT) | Some(DoubleT) => @types.Float64
    Some(ByteArrayT) => @types.Str
    Some(Int96T) =>
      raise unsupported(
        "column \"\{el.name}\": INT96 timestamps are not supported",
      )
    Some(FixedLenByteArrayT) =>
      raise unsupported(
        "column \"\{el.name}\": FIXED_LEN_BYTE_ARRAY is not supported",
      )
    Some(UnknownPhysical(id)) =>
      raise unsupported("column \"\{el.name}\": unknown physical type \{id}")
    None => raise unsupported("column \"\{el.name}\": missing physical type")
  }
}

///|
/// Scan Parquet bytes into a table entry. The bytes stay with the source;
/// decoding starts when a query opens it.
pub fn scan_bytes(
  content : Bytes,
  table_name : String,
  date_columns : Array[String],
) -> @catalog.TableEntry raise @types.SqlError {
  scan_input(ParquetInput::Memory(content), table_name, date_columns)
}

///|
/// Scan a Parquet file from disk (native target; wasm targets load the bytes
/// via the playground bridge and call scan_bytes). Registration reads the
/// file for its footer and keeps only the path.
pub fn scan_file(
  path : String,
  table_name : String,
  date_columns : Array[String],
) -> @catalog.TableEntry raise @types.SqlError {
  scan_input(ParquetInput::File(path), table_name, date_columns)
}

///|
fn scan_input(
  input : ParquetInput,
  table_name : String,
  date_columns : Array[String],
) -> @catalog.TableEntry raise @types.SqlError {
  let content = read_input(input)
  let meta = parse_footer(content)
  check_version(meta)
  // The schema gate runs first: it answers "can this reader represent the
  // file at all", and a file that is both out of scope and internally
  // inconsistent deserves the pointed refusal rather than a corruption
  // message (apache/parquet-testing's repeated_no_annotation.parquet is
  // repeated-scope *and* carries num_rows = 0 in its footer).
  // validates the schema shape (flat leaves, no repeated/nested/timestamp)
  let leaves = leaf_elements(meta)
  // a footer whose groups do not add up would silently truncate every scan
  let mut total : Int64 = 0L
  for rg in meta.row_groups {
    total += rg.num_rows
  }
  if total != meta.num_rows {
    raise unsupported(
      "row groups hold \{total} rows, the file metadata says \{meta.num_rows}",
    )
  }
  let columns : Array[@catalog.Column] = []
  let dtypes : Array[@types.DataType] = []
  for leaf in leaves {
    let (el, _) = leaf
    let dtype = column_dtype(el, date_columns.contains(el.name))
    columns.push({ name: el.name, dtype, })
    dtypes.push(dtype)
  }
  let schema : @catalog.TableSchema = { table: table_name, columns, }
  let source : ParquetSource = { dtypes, input, }
  @catalog.TableEntry::from_source(schema, source)
}

///|
/// One scan: the surviving row groups, decoded one at a time and sliced into
/// batches. Memory holds one row group's projected columns, never the table.
priv struct ParquetStream {
  data : Bytes
  meta : FileMeta
  leaves : Array[(SchemaElement, Int32)]
  columns : Array[Int32] // projected, original column indexes
  dtypes : Array[@types.DataType] // projected
  groups : Array[Int32] // surviving row group indexes, in file order
  mut group_i : Int32
  mut decoded : Array[ColumnValues]?
  mut dense : Array[Int32] // value-array offset per column inside the group
  mut group_rows : Int32
  mut pos : Int32 // next row inside the decoded group
  mut emitted : Bool
  mut finished : Bool
}

///|
impl @catalog.BatchStream for ParquetStream with fn next(self) -> @types.DataBatch? raise @types.SqlError {
  if self.finished {
    return None
  }
  while true {
    match self.decoded {
      Some(cols) =>
        if self.pos < self.group_rows {
          let end = if self.pos + BATCH_SIZE < self.group_rows {
            self.pos + BATCH_SIZE
          } else {
            self.group_rows
          }
          let batch = slice_batch(cols, self.dtypes, self.dense, self.pos, end)
          self.pos = end
          self.emitted = true
          return Some(batch)
        }
      None => ()
    }
    // the current group is exhausted: decode the next one
    if self.group_i >= self.groups.length() {
      self.finished = true
      if !self.emitted {
        self.emitted = true
        return Some(empty_batch(self.dtypes))
      }
      return None
    }
    let g = self.groups[self.group_i]
    self.group_i += 1
    let rg = self.meta.row_groups[g]
    let rows = rg.num_rows.to_int()
    if rows <= 0 {
      continue
    }
    let cols : Array[ColumnValues] = []
    for c in self.columns {
      let (el, max_def) = self.leaves[c]
      let decoded = decode_chunk(self.data, rg.columns[c], max_def, el)
      // the group's row count is the contract every slice relies on
      let got = match decoded {
        Bools(_, v) => v.length()
        Int32s(_, v) => v.length()
        Int64s(_, v) => v.length()
        Floats(_, v) => v.length()
        Doubles(_, v) => v.length()
        Strings(_, v) => v.length()
      }
      if got != rows {
        raise unsupported(
          "row group \{g} column \"\{el.name}\": decoded \{got} rows, the group metadata says \{rows}",
        )
      }
      cols.push(decoded)
    }
    self.decoded = Some(cols)
    self.dense = Array::make(cols.length(), 0)
    self.group_rows = rows
    self.pos = 0
  }
  None // unreachable: the loop returns
}

///|
impl @catalog.ScanSource for ParquetSource with fn open(
  self,
  request : @catalog.ScanRequest,
) -> &@catalog.BatchStream raise @types.SqlError {
  let data = read_input(self.input)
  let meta = parse_footer(data)
  check_version(meta)
  let leaves = leaf_elements(meta)
  let columns : Array[Int32] = []
  let dtypes : Array[@types.DataType] = []
  for c in request.projection {
    if c < 0 || c >= leaves.length() {
      raise unsupported(
        "projection column \{c} is outside the \{leaves.length()} column table",
      )
    }
    columns.push(c)
    dtypes.push(self.dtypes[c])
  }
  let groups : Array[Int32] = []
  for g in 0..<meta.row_groups.length() {
    if !group_skipped(meta.row_groups[g], leaves, self.dtypes, request) {
      groups.push(g)
    }
  }
  let stream : ParquetStream = {
    data,
    meta,
    leaves,
    columns,
    dtypes,
    groups,
    group_i: 0,
    decoded: None,
    dense: [],
    group_rows: 0,
    pos: 0,
    emitted: false,
    finished: false,
  }
  stream
}

///|
impl @catalog.ScanSource for ParquetSource with fn plan(
  self,
  request : @catalog.ScanRequest,
) -> @catalog.ScanPlan raise @types.SqlError {
  let data = read_input(self.input)
  let meta = parse_footer(data)
  check_version(meta)
  let leaves = leaf_elements(meta)
  let mut skipped = 0
  let mut rows : Int64 = 0L
  for rg in meta.row_groups {
    if group_skipped(rg, leaves, self.dtypes, request) {
      skipped += 1
    } else {
      rows += rg.num_rows
    }
  }
  {
    files: 1,
    row_groups: meta.row_groups.length(),
    row_groups_skipped: skipped,
    rows: Some(rows),
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
/// Turn one decoded group's rows `from..<to` into a batch. The value arrays
/// are dense (NULLs are held out), so each column carries the number of dense
/// values already consumed: slicing resumes there instead of counting the
/// valid slots before `from` for every batch.
fn slice_batch(
  cols : Array[ColumnValues],
  dtypes : Array[@types.DataType],
  dense : Array[Int32],
  from : Int32,
  to : Int32,
) -> @types.DataBatch {
  let out : Array[@types.ColumnVector] = []
  for i, col in cols {
    let (vector, used) = slice_column(
      col,
      from,
      to,
      dense[i],
      dtypes[i] is @types.Date,
    )
    dense[i] = dense[i] + used
    out.push(vector)
  }
  @types.DataBatch::new(out, to - from)
}

///|
/// `(vector, values consumed)`: the second half feeds the dense cursor.
fn slice_column(
  col : ColumnValues,
  from : Int32,
  to : Int32,
  dense_start : Int32,
  is_date : Bool,
) -> (@types.ColumnVector, Int32) {
  let n = to - from
  match col {
    Bools(values, valid) => {
      let d : FixedArray[Bool] = FixedArray::make(n, false)
      let v : FixedArray[Bool] = FixedArray::make(n, false)
      let mut k = dense_start
      let mut w = 0
      for i in from..<to {
        if valid[i] {
          d.unsafe_set(w, values[k])
          v.unsafe_set(w, true)
          k += 1
        }
        w += 1
      }
      (@types.BoolV(d, v), k - dense_start)
    }
    Int32s(values, valid) => {
      let d : FixedArray[Int32] = FixedArray::make(n, 0)
      let v : FixedArray[Bool] = FixedArray::make(n, false)
      let mut k = dense_start
      let mut w = 0
      for i in from..<to {
        if valid[i] {
          d.unsafe_set(w, values[k])
          v.unsafe_set(w, true)
          k += 1
        }
        w += 1
      }
      let vector = if is_date { @types.DateV(d, v) } else { @types.I32(d, v) }
      (vector, k - dense_start)
    }
    Int64s(values, valid) => {
      let d : FixedArray[Int64] = FixedArray::make(n, 0L)
      let v : FixedArray[Bool] = FixedArray::make(n, false)
      let mut k = dense_start
      let mut w = 0
      for i in from..<to {
        if valid[i] {
          d.unsafe_set(w, values[k])
          v.unsafe_set(w, true)
          k += 1
        }
        w += 1
      }
      (@types.I64(d, v), k - dense_start)
    }
    Floats(values, valid) => {
      let d : FixedArray[Double] = FixedArray::make(n, 0.0)
      let v : FixedArray[Bool] = FixedArray::make(n, false)
      let mut k = dense_start
      let mut w = 0
      for i in from..<to {
        if valid[i] {
          d.unsafe_set(w, values[k].to_double())
          v.unsafe_set(w, true)
          k += 1
        }
        w += 1
      }
      (@types.F64(d, v), k - dense_start)
    }
    Doubles(values, valid) => {
      let d : FixedArray[Double] = FixedArray::make(n, 0.0)
      let v : FixedArray[Bool] = FixedArray::make(n, false)
      let mut k = dense_start
      let mut w = 0
      for i in from..<to {
        if valid[i] {
          d.unsafe_set(w, values[k])
          v.unsafe_set(w, true)
          k += 1
        }
        w += 1
      }
      (@types.F64(d, v), k - dense_start)
    }
    Strings(values, valid) => {
      let d : FixedArray[String] = FixedArray::make(n, "")
      let v : FixedArray[Bool] = FixedArray::make(n, false)
      let mut k = dense_start
      let mut w = 0
      for i in from..<to {
        if valid[i] {
          d.unsafe_set(w, values[k])
          v.unsafe_set(w, true)
          k += 1
        }
        w += 1
      }
      (@types.StrV(d, v), k - dense_start)
    }
  }
}
