// Batch serialization for spill files: hand-rolled minimal columnar
// format, pure bytes in and out (no fs here — spill STORES live behind
// engine's SpillStore trait, this is only the wire format).
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
// Deliberately dumb: no compression, no dictionary, no alignment. The
// spill-format bake-off (docs/spill-survey.md §3.5) picked this over a
// parquet-backed writer: faster to write, and the 0.2.2 upstream
// writer cannot even represent Double/Bool columns.

///|
fn dtype_code(dt : DataType) -> Byte {
  match dt {
    Int32 => 0
    Int64 => 1
    Float64 => 2
    Str => 3
    Date => 4
    Bool => 5
  }
}

///|
fn code_dtype(code : Byte) -> DataType raise SqlError {
  match code {
    0 => Int32
    1 => Int64
    2 => Float64
    3 => Str
    4 => Date
    5 => Bool
    _ => raise SqlError::Execute("spill file: unknown dtype code \{code}")
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
fn read_i32_checked(
  buf : Bytes,
  pos : Int,
  what : String,
) -> Int raise SqlError {
  if pos + 4 > buf.length() {
    raise SqlError::Execute(
      "spill read: truncated at \{what} (pos \{pos}, len \{buf.length()})",
    )
  }
  read_i32(buf, pos)
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
/// Serialize batches into the spill wire format.
pub fn DataBatch::to_spill_bytes(batches : Array[DataBatch]) -> Bytes {
  let out : @buffer.Buffer = @buffer.Buffer::Buffer(size_hint=1 << 20)
  out.write_bytes(b"MLSPILL1")
  write_i32(out, batches.length())
  for batch in batches {
    write_i32(out, batch.row_count())
    let cols = batch.columns()
    write_i32(out, cols.length())
    for col in cols {
      out.write_byte(dtype_code(col.dtype()))
      // row count, not the vector's allocated capacity: builders hand
      // out capacity-sized vectors with only part of it filled
      let n = batch.row_count()
      let nulls : @buffer.Buffer = @buffer.Buffer::Buffer(size_hint=n)
      let payload : @buffer.Buffer = @buffer.Buffer::Buffer(size_hint=n * 8)
      for r in 0..<n {
        match col.get(r) {
          Null => nulls.write_byte(0)
          Int32(v) => {
            nulls.write_byte(1)
            write_i32(payload, v)
          }
          Int64(v) => {
            nulls.write_byte(1)
            write_i64(payload, v)
          }
          Float64(v) => {
            nulls.write_byte(1)
            write_f64(payload, v)
          }
          Str(v) => {
            nulls.write_byte(1)
            write_str(payload, v)
          }
          Date(v) => {
            nulls.write_byte(1)
            write_i32(payload, v)
          }
          Boolean(v) => {
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
  dt : DataType,
  n : Int,
) -> (ColumnVector, Int) raise SqlError {
  let vec = ColumnVector::make(dt, n)
  let flags = start
  let mut pos = start + n
  for r in 0..<n {
    if buf[flags + r].to_int() == 0 {
      vec.set(r, Null)
      continue
    }
    match dt {
      Int32 => {
        vec.set(r, Int32(read_i32(buf, pos)))
        pos += 4
      }
      Date => {
        vec.set(r, Date(read_i32(buf, pos)))
        pos += 4
      }
      Int64 => {
        vec.set(r, Int64(read_i64(buf, pos)))
        pos += 8
      }
      Float64 => {
        vec.set(r, Float64(read_f64(buf, pos)))
        pos += 8
      }
      Bool => {
        vec.set(r, Boolean(buf[pos].to_int() == 1))
        pos += 1
      }
      Str => {
        if pos + 4 > buf.length() {
          raise SqlError::Execute(
            "spill read: truncated string header at \{pos} (len \{buf.length()})",
          )
        }
        let len = read_i32(buf, pos)
        pos += 4
        if pos + len > buf.length() {
          raise SqlError::Execute(
            "spill read: truncated string body at \{pos}+\{len} (len \{buf.length()})",
          )
        }
        vec.set(r, Str(@utf8.decode_lossy(buf[pos:pos + len])))
        pos += len
      }
    }
  }
  (vec, pos)
}

///|
/// Deserialize batches from the spill wire format. A corrupt buffer is
/// an Execute error.
pub fn DataBatch::from_spill_bytes(
  buf : Bytes,
) -> Array[DataBatch] raise SqlError {
  if buf.length() < 16 || @utf8.decode_lossy(buf[0:8]) != "MLSPILL1" {
    raise SqlError::Execute("spill read: bad magic")
  }
  let batch_count = read_i32(buf, 8)
  let mut pos = 12
  let out : Array[DataBatch] = []
  for b in 0..<batch_count {
    let rows = read_i32_checked(buf, pos, "batch \{b} row count")
    pos += 4
    let ncols = read_i32_checked(buf, pos, "batch \{b} column count")
    pos += 4
    let cols : Array[ColumnVector] = []
    for c in 0..<ncols {
      if pos + 1 > buf.length() {
        raise SqlError::Execute(
          "spill read: truncated at batch \{b} column \{c} (pos \{pos}, len \{buf.length()})",
        )
      }
      let dt = code_dtype(buf[pos])
      pos += 1
      let (vec, next) = read_col(buf, pos, dt, rows)
      cols.push(vec)
      pos = next
    }
    out.push(DataBatch::new(cols, rows))
  }
  out
}
