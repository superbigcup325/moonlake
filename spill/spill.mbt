// Spill format, mizchi/parquet-backed arm of the bake-off.
//
// Each batch serializes as its own parquet file (one row group). The
// upstream 0.2.2 write path is row-major only — write_bytes accepts a
// ParquetFile built from Array[Array[Value]] — so this arm pays a
// column->row transcode on the way out; the read path is columnar
// (read_bytes_columnar). The envelope preserves batch boundaries and
// engine dtypes (parquet stores physical types; Date rides as Int32):
//   "MLSPILQ1"                 magic
//   batch_count : i32
//   per batch:    row_count : i32
//                 col_count : i32
//                 dtype codes : col_count bytes (raw-arm numbering)
//                 blob_len : i32   (0 when col_count == 0)
//                 blob     : parquet bytes
//
// Every column is declared Optional and read back through the
// Nullable*/Optional value path — the obvious implementation; a
// null-free fast path exists but is not taken here.

///|
fn magic() -> Bytes {
  b"MLSPILQ1"
}

///|
fn dtype_code(dt : @types.DataType) -> Int {
  match dt {
    @types.Int32 => 0
    @types.Int64 => 1
    @types.Float64 => 2
    @types.Str => 3
    @types.Date => 4
    @types.Bool => 5
  }
}

///|
fn code_dtype(code : Int) -> @types.DataType raise @types.SqlError {
  match code {
    0 => @types.Int32
    1 => @types.Int64
    2 => @types.Float64
    3 => @types.Str
    4 => @types.Date
    5 => @types.Bool
    _ =>
      raise @types.SqlError::Execute("spill file: unknown dtype code \{code}")
  }
}

///|
/// The 0.2.2 writer only accepts Int32 | Int64 | String | Binary, so
/// Double rides as its IEEE bit pattern in an Int64 column and Bool as
/// 0/1 in an Int32 column; the envelope's dtype codes restore both on
/// the way back. These are workarounds, not semantics.
fn parquet_type(dt : @types.DataType) -> @pq.ColumnType {
  match dt {
    @types.Int32 => @pq.ColumnType::Int32
    @types.Int64 => @pq.ColumnType::Int64
    @types.Float64 => @pq.ColumnType::Int64
    @types.Str => @pq.ColumnType::String
    @types.Date => @pq.ColumnType::Int32
    @types.Bool => @pq.ColumnType::Int32
  }
}

///|
/// Column->row transcode: the upstream write API is row-major only.
fn to_rows(batch : @types.DataBatch, cols : Int) -> Array[Array[@pq.Value]] {
  let rows : Array[Array[@pq.Value]] = []
  for r in 0..<batch.row_count() {
    let row : Array[@pq.Value] = []
    for c in 0..<cols {
      let col = batch.columns()[c]
      row.push(
        match col.get(r) {
          @types.Null => @pq.Value::Null
          @types.Int32(v) => @pq.Value::Int32(v)
          @types.Int64(v) => @pq.Value::Int64(v)
          @types.Float64(v) => @pq.Value::Int64(v.reinterpret_as_int64())
          @types.Str(v) => @pq.Value::String(v)
          @types.Date(v) => @pq.Value::Int32(v)
          @types.Boolean(v) => @pq.Value::Int32(if v { 1 } else { 0 })
        },
      )
    }
    rows.push(row)
  }
  rows
}

///|
fn blob_of(batch : @types.DataBatch) -> Bytes raise @types.SqlError {
  let cols = batch.columns()
  let columns : Array[@pq.Column] = []
  for i, col in cols {
    columns.push(
      @pq.new_column(
        "c\{i}",
        parquet_type(col.dtype()),
        @pq.Repetition::Optional,
      ),
    )
  }
  let file = @pq.new_parquet_file(columns, to_rows(batch, cols.length()), None)
  @pq.write_bytes(file) catch {
    err => raise @types.SqlError::Execute("spill parquet write: \{err}")
  }
}

///|
/// Serialize batches to `path`. Returns the number of file bytes
/// written (envelope included).
pub fn write_batches(
  path : String,
  batches : Array[@types.DataBatch],
) -> Int raise @types.SqlError {
  let bytes = to_bytes(batches)
  @fs.write_bytes_to_file(path, bytes) catch {
    @fs.IOError(msg) => raise @types.SqlError::Execute("spill write: \{msg}")
  }
  bytes.length()
}

///|
/// Serialize batches: envelope of per-batch parquet blobs.
pub fn to_bytes(
  batches : Array[@types.DataBatch],
) -> Bytes raise @types.SqlError {
  let out : @buffer.Buffer = @buffer.Buffer::Buffer(size_hint=1 << 20)
  out.write_bytes(magic())
  write_i32(out, batches.length())
  for batch in batches {
    write_i32(out, batch.row_count())
    let cols = batch.columns()
    write_i32(out, cols.length())
    for col in cols {
      out.write_byte(dtype_code(col.dtype()).to_byte())
    }
    if cols.length() == 0 {
      write_i32(out, 0)
      continue
    }
    let blob = blob_of(batch)
    write_i32(out, blob.length())
    out.write_bytes(blob[:])
  }
  out.to_bytes()
}

///|
fn column_of(
  data : @pq.ParquetColumnData,
  dt : @types.DataType,
  n : Int,
) -> @types.ColumnVector raise @types.SqlError {
  let vec = @types.ColumnVector::make(dt, n)
  for r in 0..<n {
    let v : @pq.Value? = match data {
      @pq.Values(vals) => vals.get(r)
      @pq.BooleanValues(vals) =>
        match vals.get(r) {
          Some(x) => Some(@pq.Value::Boolean(x))
          None => None
        }
      @pq.Int32Values(vals) =>
        match vals.get(r) {
          Some(x) => Some(@pq.Value::Int32(x))
          None => None
        }
      @pq.NullableInt32Values(vals) =>
        if r < vals.length() {
          match vals[r] {
            Some(x) => Some(@pq.Value::Int32(x))
            None => None
          }
        } else {
          None
        }
      @pq.Int64Values(vals) =>
        match vals.get(r) {
          Some(x) => Some(@pq.Value::Int64(x))
          None => None
        }
      @pq.NullableInt64Values(vals) =>
        if r < vals.length() {
          match vals[r] {
            Some(x) => Some(@pq.Value::Int64(x))
            None => None
          }
        } else {
          None
        }
      @pq.NullableTimestampMicrosValues(vals) =>
        if r < vals.length() {
          match vals[r] {
            Some(x) => Some(@pq.Value::Int64(x))
            None => None
          }
        } else {
          None
        }
      @pq.TimestampMicrosValues(vals) =>
        match vals.get(r) {
          Some(x) => Some(@pq.Value::Int64(x))
          None => None
        }
      @pq.FloatValues(vals) =>
        match vals.get(r) {
          Some(x) => Some(@pq.Value::Double(x.to_double()))
          None => None
        }
      @pq.DoubleValues(vals) =>
        match vals.get(r) {
          Some(x) => Some(@pq.Value::Double(x))
          None => None
        }
      @pq.Utf8Values(vals) =>
        match vals.get(r) {
          Some(x) => Some(@pq.Value::String(@utf8.decode_lossy(x)))
          None => None
        }
      @pq.NullableUtf8Values(vals) =>
        if r < vals.length() {
          match vals[r] {
            Some(x) => Some(@pq.Value::String(@utf8.decode_lossy(x)))
            None => None
          }
        } else {
          None
        }
      @pq.BinaryValues(_) | @pq.NullableBinaryValues(_) =>
        raise @types.SqlError::Execute(
          "spill parquet: binary columns are not produced by this arm",
        )
    }
    match v {
      None => vec.set(r, @types.Null)
      Some(@pq.Value::Null) => vec.set(r, @types.Null)
      Some(@pq.Value::Boolean(x)) => vec.set(r, @types.Boolean(x))
      Some(@pq.Value::Int32(x)) =>
        vec.set(
          r,
          match dt {
            @types.Date => @types.Date(x)
            @types.Bool => @types.Boolean(x == 1)
            _ => @types.Int32(x)
          },
        )
      Some(@pq.Value::Int64(x)) =>
        vec.set(
          r,
          if dt is @types.Float64 {
            @types.Float64(x.reinterpret_as_double())
          } else {
            @types.Int64(x)
          },
        )
      Some(@pq.Value::TimestampMicros(x)) => vec.set(r, @types.Int64(x))
      Some(@pq.Value::Float(x)) => vec.set(r, @types.Float64(x.to_double()))
      Some(@pq.Value::Double(x)) => vec.set(r, @types.Float64(x))
      Some(@pq.Value::String(x)) => vec.set(r, @types.Str(x))
      Some(@pq.Value::Binary(_)) =>
        raise @types.SqlError::Execute("spill parquet: unexpected Bytes value")
    }
  }
  vec
}

///|
/// Deserialize batches written by write_batches.
pub fn read_batches(
  path : String,
) -> Array[@types.DataBatch] raise @types.SqlError {
  let buf = @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => raise @types.SqlError::Execute("spill read: \{msg}")
  }
  from_bytes(buf)
}

///|
/// Deserialize batches from envelope bytes.
pub fn from_bytes(buf : Bytes) -> Array[@types.DataBatch] raise @types.SqlError {
  if buf.length() < 16 || buf[0:8].to_owned() != magic() {
    raise @types.SqlError::Execute("spill read: bad magic")
  }
  let batch_count = read_i32(buf, 8)
  let mut pos = 12
  let out : Array[@types.DataBatch] = []
  for _ in 0..<batch_count {
    let rows = read_i32(buf, pos)
    pos += 4
    let ncols = read_i32(buf, pos)
    pos += 4
    let dts : Array[@types.DataType] = []
    for _ in 0..<ncols {
      dts.push(code_dtype(buf[pos].to_int()))
      pos += 1
    }
    let blob_len = read_i32(buf, pos)
    pos += 4
    if ncols == 0 {
      out.push(@types.DataBatch::new([], rows))
      continue
    }
    let file = @pq.read_bytes_columnar(buf[pos:pos + blob_len].to_owned()) catch {
      err => raise @types.SqlError::Execute("spill parquet read: \{err}")
    }
    pos += blob_len
    let cols : Array[@types.ColumnVector] = []
    for i, data in file.column_data() {
      cols.push(column_of(data, dts[i], rows))
    }
    out.push(@types.DataBatch::new(cols, rows))
  }
  out
}

///|
fn write_i32(out : @buffer.Buffer, v : Int) -> Unit {
  let x = v.reinterpret_as_uint()
  out.write_byte((x & 0xFF).to_byte())
  out.write_byte(((x >> 8) & 0xFF).to_byte())
  out.write_byte(((x >> 16) & 0xFF).to_byte())
  out.write_byte(((x >> 24) & 0xFF).to_byte())
}

///|
fn read_i32(buf : Bytes, pos : Int) -> Int {
  let b0 = buf[pos].to_int()
  let b1 = buf[pos + 1].to_int()
  let b2 = buf[pos + 2].to_int()
  let b3 = buf[pos + 3].to_int()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}
