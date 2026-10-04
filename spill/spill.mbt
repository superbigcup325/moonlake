// Spill-file format, hand-rolled minimal columnar serialization.
//
// Layout (little-endian throughout):
//   "MLSPILL1"                       magic
//   batch_count : i32
//   per batch:   row_count : i32
//                col_count : i32
//                per column: dtype_code : u8
//                            null_flags : row_count bytes (1 = present)
//                            payload    : only non-null values
// Payloads: Int32/Date 4B, Int64/Float64 8B (IEEE bits), Bool 1B,
// Str i32 length + UTF-8 bytes.
//
// The format is deliberately dumb: no compression, no dictionary, no
// alignment. It exists as one arm of the spill-format bake-off against
// a mizchi/parquet-backed writer (see docs/spill-survey.md).

///|
fn dtype_code(dt : @types.DataType) -> Byte {
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
fn code_dtype(code : Byte) -> @types.DataType raise @types.SqlError {
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
fn write_i32(out : @buffer.Buffer, v : Int) -> Unit {
  let x = v.reinterpret_as_uint()
  out.write_byte((x & 0xFF).to_byte())
  out.write_byte(((x >> 8) & 0xFF).to_byte())
  out.write_byte(((x >> 16) & 0xFF).to_byte())
  out.write_byte(((x >> 24) & 0xFF).to_byte())
}

///|
fn write_i64(out : @buffer.Buffer, v : Int64) -> Unit {
  let x = v.reinterpret_as_uint64()
  for k in 0..<8 {
    out.write_byte(((x >> (k * 8)) & 0xFF).to_byte())
  }
}

///|
fn read_i32(buf : Bytes, pos : Int) -> Int {
  let b0 = buf[pos].to_int()
  let b1 = buf[pos + 1].to_int()
  let b2 = buf[pos + 2].to_int()
  let b3 = buf[pos + 3].to_int()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24) // little-endian, two's complement
}

///|
fn read_i64(buf : Bytes, pos : Int) -> Int64 {
  let mut v : UInt64 = 0UL
  for k in 0..<8 {
    v = v | ((buf[pos + k].to_int().to_uint64() & 0xFFUL) << (k * 8))
  }
  v.reinterpret_as_int64()
}

///|
fn write_f64(out : @buffer.Buffer, v : Double) -> Unit {
  write_i64(out, v.reinterpret_as_int64())
}

///|
fn read_f64(buf : Bytes, pos : Int) -> Double {
  read_i64(buf, pos).reinterpret_as_double()
}

///|
fn write_str(out : @buffer.Buffer, s : String) -> Unit {
  let b = @utf8.encode(s)
  write_i32(out, b.length())
  out.write_bytes(b[:])
}

///|
/// Serialize batches to `path` in the raw format. Returns the number of
/// file bytes written.
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
/// Serialize batches to bytes in the raw format.
pub fn to_bytes(batches : Array[@types.DataBatch]) -> Bytes {
  let out : @buffer.Buffer = @buffer.Buffer::Buffer(size_hint=1 << 20)
  out.write_bytes(b"MLSPILL1")
  write_i32(out, batches.length())
  for batch in batches {
    write_i32(out, batch.row_count())
    let cols = batch.columns()
    write_i32(out, cols.length())
    for col in cols {
      out.write_byte(dtype_code(col.dtype()))
      let n = col.len()
      let nulls : @buffer.Buffer = @buffer.Buffer::Buffer(size_hint=n)
      let payload : @buffer.Buffer = @buffer.Buffer::Buffer(size_hint=n * 8)
      for r in 0..<n {
        match col.get(r) {
          @types.Null => nulls.write_byte(0)
          @types.Int32(v) => {
            nulls.write_byte(1)
            write_i32(payload, v)
          }
          @types.Int64(v) => {
            nulls.write_byte(1)
            write_i64(payload, v)
          }
          @types.Float64(v) => {
            nulls.write_byte(1)
            write_f64(payload, v)
          }
          @types.Str(v) => {
            nulls.write_byte(1)
            write_str(payload, v)
          }
          @types.Date(v) => {
            nulls.write_byte(1)
            write_i32(payload, v)
          }
          @types.Boolean(v) => {
            nulls.write_byte(1)
            payload.write_byte(if v { 1 } else { 0 })
          }
        }
      }
      out.write_bytes(nulls.to_bytes()[:])
      out.write_bytes(payload.to_bytes()[:])
    }
  }
  out.to_bytes()
}

///|
fn read_col(
  buf : Bytes,
  start : Int,
  dt : @types.DataType,
  n : Int,
) -> (@types.ColumnVector, Int) {
  let vec = @types.ColumnVector::make(dt, n)
  let flags = start
  let mut pos = start + n
  for r in 0..<n {
    if buf[flags + r].to_int() == 0 {
      vec.set(r, @types.Null)
      continue
    }
    match dt {
      @types.Int32 => {
        vec.set(r, @types.Int32(read_i32(buf, pos)))
        pos += 4
      }
      @types.Date => {
        vec.set(r, @types.Date(read_i32(buf, pos)))
        pos += 4
      }
      @types.Int64 => {
        vec.set(r, @types.Int64(read_i64(buf, pos)))
        pos += 8
      }
      @types.Float64 => {
        vec.set(r, @types.Float64(read_f64(buf, pos)))
        pos += 8
      }
      @types.Bool => {
        vec.set(r, @types.Boolean(buf[pos].to_int() == 1))
        pos += 1
      }
      @types.Str => {
        let len = read_i32(buf, pos)
        pos += 4
        vec.set(r, @types.Str(@utf8.decode_lossy(buf[pos:pos + len])))
        pos += len
      }
    }
  }
  (vec, pos)
}

///|
/// Deserialize batches written by write_batches. Dtype and layout
/// checks are structural; a corrupt file is an Execute error.
pub fn read_batches(
  path : String,
) -> Array[@types.DataBatch] raise @types.SqlError {
  let buf = @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => raise @types.SqlError::Execute("spill read: \{msg}")
  }
  from_bytes(buf)
}

///|
/// Deserialize batches from raw-format bytes.
pub fn from_bytes(buf : Bytes) -> Array[@types.DataBatch] raise @types.SqlError {
  if buf.length() < 16 || @utf8.decode_lossy(buf[0:8]) != "MLSPILL1" {
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
    let cols : Array[@types.ColumnVector] = []
    for _ in 0..<ncols {
      let dt = code_dtype(buf[pos])
      pos += 1
      let (vec, next) = read_col(buf, pos, dt, rows)
      cols.push(vec)
      pos = next
    }
    out.push(@types.DataBatch::new(cols, rows))
  }
  out
}
