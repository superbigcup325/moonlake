// Batch serialization for spill files: the columnar wire format, pure bytes
// in and out (no fs here — spill STORES live behind the engine's SpillStore
// trait, this is only the format).
//
// Layout (little-endian throughout):
//   "MLSPILL3"                       magic
//   batch_count : i32
//   per batch:   row_count : i32
//                col_count : i32
//                per column: dtype_code   : u8
//                            encoding     : u8
//                            payload_len  : i32
//                            null_mode    : u8 (0 = every row present,
//                                               1 = a bitmap follows)
//                            [bitmap]     : ceil(row_count / 8) bytes when
//                                           null_mode = 1; bit r % 8 of byte
//                                           r / 8 is 1 when row r is present
//                            payload      : payload_len bytes
//
// The presence channel is a bitmap, not one byte per row: a column without
// NULLs costs a single mode byte, and a nullable one an eighth of the old
// size. The payload is a colenc column encoding over the non-null values only,
// so NULLs stay a side channel and the encoder sees a dense column. Encoding
// codes and payload framing live in the helpers below; the reader rejects
// unknown codes and short payloads with an Execute error.

///|
fn spill_write_error(msg : String) -> SqlError {
  SqlError::Execute("spill write: " + msg)
}

///|
fn spill_read_error(msg : String) -> SqlError {
  SqlError::Execute("spill read: " + msg)
}

///|
fn colenc_write_error(e : @colenc_types.EncodingError) -> SqlError {
  SqlError::Execute(
    "spill write: colenc: \{@colenc_types.EncodingError::message(e)}",
  )
}

///|
fn colenc_read_error(e : @colenc_types.EncodingError) -> SqlError {
  SqlError::Execute(
    "spill read: colenc: \{@colenc_types.EncodingError::message(e)}",
  )
}

///|
const ENC_PLAIN : Int32 = 0

///|
const ENC_DELTA : Int32 = 1

///|
const ENC_DELTA_LENGTH : Int32 = 2

///|
const ENC_DELTA_BYTE_ARRAY : Int32 = 3

///|
const ENC_DICTIONARY : Int32 = 4

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
    _ => raise spill_read_error("unknown dtype code \{code}")
  }
}

///|
fn spill_physical(dt : DataType) -> @colenc_types.PhysicalType {
  match dt {
    Int32 | Date => @colenc_types.Int32
    Int64 => @colenc_types.Int64
    Float64 => @colenc_types.Double
    Str => @colenc_types.ByteArray
    Bool => @colenc_types.Bool
  }
}

///|
fn write_i32(out : @buffer.Buffer, v : Int32) -> Unit {
  let x = v.reinterpret_as_uint()
  out.write_byte((x & 0xFF).to_byte())
  out.write_byte(((x >> 8) & 0xFF).to_byte())
  out.write_byte(((x >> 16) & 0xFF).to_byte())
  out.write_byte(((x >> 24) & 0xFF).to_byte())
}

///|
fn read_i32_checked(
  buf : Bytes,
  pos : Int32,
  what : String,
) -> Int32 raise SqlError {
  if pos + 4 > buf.length() {
    raise spill_read_error(
      "truncated at \{what} (pos \{pos}, len \{buf.length()})",
    )
  }
  read_i32(buf, pos)
}

///|
fn read_i32_view(buf : BytesView, pos : Int32) -> Int32 {
  let b0 = buf[pos].to_int()
  let b1 = buf[pos + 1].to_int()
  let b2 = buf[pos + 2].to_int()
  let b3 = buf[pos + 3].to_int()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
fn read_i32(buf : Bytes, pos : Int32) -> Int32 {
  let b0 = buf[pos].to_int()
  let b1 = buf[pos + 1].to_int()
  let b2 = buf[pos + 2].to_int()
  let b3 = buf[pos + 3].to_int()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24) // little-endian, two's complement
}

// ------------------------------------------------------------ column values

///|
/// Pull one column out of a batch: a dense colenc column of the non-null
/// values plus the presence flags, in row order.
fn collect_column(
  col : ColumnVector,
  n : Int32,
) -> (@colenc_types.ColBuf, Array[Bool]) raise SqlError {
  let flags : Array[Bool] = []
  match col.dtype() {
    Int32 => {
      let values : Array[Int32] = []
      for r in 0..<n {
        match col.get(r) {
          Null => flags.push(false)
          Int32(v) => {
            flags.push(true)
            values.push(v)
          }
          _ => raise spill_write_error("value does not match INT32")
        }
      }
      (@colenc_types.ColBuf::Int32s(values), flags)
    }
    Date => {
      let values : Array[Int32] = []
      for r in 0..<n {
        match col.get(r) {
          Null => flags.push(false)
          Date(v) => {
            flags.push(true)
            values.push(v)
          }
          _ => raise spill_write_error("value does not match DATE")
        }
      }
      (@colenc_types.ColBuf::Int32s(values), flags)
    }
    Int64 => {
      let values : Array[Int64] = []
      for r in 0..<n {
        match col.get(r) {
          Null => flags.push(false)
          Int64(v) => {
            flags.push(true)
            values.push(v)
          }
          _ => raise spill_write_error("value does not match INT64")
        }
      }
      (@colenc_types.ColBuf::Int64s(values), flags)
    }
    Float64 => {
      let values : Array[Double] = []
      for r in 0..<n {
        match col.get(r) {
          Null => flags.push(false)
          Float64(v) => {
            flags.push(true)
            values.push(v)
          }
          _ => raise spill_write_error("value does not match FLOAT64")
        }
      }
      (@colenc_types.ColBuf::Doubles(values), flags)
    }
    Str => {
      let values : Array[Bytes] = []
      for r in 0..<n {
        match col.get(r) {
          Null => flags.push(false)
          Str(v) => {
            flags.push(true)
            values.push(@utf8.encode(v))
          }
          _ => raise spill_write_error("value does not match STRING")
        }
      }
      (@colenc_types.ColBuf::ByteArrays(values), flags)
    }
    Bool => {
      let values : Array[Bool] = []
      for r in 0..<n {
        match col.get(r) {
          Null => flags.push(false)
          Boolean(v) => {
            flags.push(true)
            values.push(v)
          }
          _ => raise spill_write_error("value does not match BOOLEAN")
        }
      }
      (@colenc_types.ColBuf::Bools(values), flags)
    }
  }
}

///|
fn encode_with(
  column : @colenc_types.ColBuf,
  encoding : @colenc_types.Encoding,
) -> Bytes raise SqlError {
  let out = Buffer()
  let _ = @colenc.encode_column(column, encoding, out) catch {
    e => raise colenc_write_error(e)
  }
  out.to_bytes()
}

///|
/// Dictionary payload: entry count, dictionary bytes length, dictionary, then
/// the index stream (bit width byte plus hybrid runs).
fn encode_dictionary_payload(
  column : @colenc_types.ColBuf,
) -> Bytes? raise SqlError {
  let encoding = @colenc.encode_dictionary(column) catch {
    e => raise colenc_write_error(e)
  }
  match encoding {
    None => None
    Some(dict) => {
      let out = Buffer()
      write_i32(out, dict.dictionary_size)
      write_i32(out, dict.dictionary.length())
      out.write_bytes(dict.dictionary)
      out.write_bytes(dict.indices)
      Some(out.to_bytes())
    }
  }
}

///|
/// Sample the leading values to decide whether a dictionary is worth trying.
/// The full dictionary build is a hash map over every value, so high-cardinality
/// columns skip it on a 4096-value sample instead. Returns false for an empty
/// column: PLAIN already wins there.
fn sample_dict_useful(column : @colenc_types.ColBuf) -> Bool {
  let n = column.value_count()
  if n == 0 {
    return false
  }
  let limit = if n < 4096 { n } else { 4096 }
  match column {
    Int32s(values) => {
      let seen : Map[Int32, Bool] = Map([])
      for i in 0..<limit {
        seen.set(values[i], true)
      }
      seen.length() * 4 <= limit
    }
    Int64s(values) => {
      let seen : Map[Int64, Bool] = Map([])
      for i in 0..<limit {
        seen.set(values[i], true)
      }
      seen.length() * 4 <= limit
    }
    Doubles(values) => {
      let seen : Map[Int64, Bool] = Map([])
      for i in 0..<limit {
        seen.set(values[i].reinterpret_as_int64(), true)
      }
      seen.length() * 4 <= limit
    }
    ByteArrays(values) => {
      let seen : Map[Bytes, Bool] = Map([])
      for i in 0..<limit {
        seen.set(values[i], true)
      }
      seen.length() * 4 <= limit
    }
    Floats(_) => false
    Bools(_) => false
  }
}

///|
fn common_prefix(a : Bytes, b : Bytes) -> Int32 {
  let limit = if a.length() < b.length() { a.length() } else { b.length() }
  let mut i = 0
  while i < limit && a[i] == b[i] {
    i += 1
  }
  i
}

///|
/// DELTA_BYTE_ARRAY only pays when consecutive values share a prefix; sample
/// the first pairs so unrelated strings skip a full extra encode.
fn sample_prefix_useful(values : Array[Bytes]) -> Bool {
  let n = values.length()
  if n < 2 {
    return false
  }
  let steps = if n - 1 < 256 { n - 1 } else { 256 }
  let mut total = 0
  for i in 0..<steps {
    total += common_prefix(values[i], values[i + 1])
  }
  total >= steps * 2
}

///|

///|
/// Pick the smallest of the candidate payloads for a column; ties keep the
/// earlier candidate, so PLAIN wins when nothing is smaller.
fn choose_payload(
  dt : DataType,
  column : @colenc_types.ColBuf,
) -> (Int32, Bytes) raise SqlError {
  let mut best_encoding = ENC_PLAIN
  let mut best = encode_with(column, @colenc_types.Plain)
  match dt {
    Int32 | Date | Int64 => {
      let candidate = encode_with(column, @colenc_types.DeltaBinaryPacked)
      if candidate.length() < best.length() {
        best = candidate
        best_encoding = ENC_DELTA
      }
      if sample_dict_useful(column) {
        match encode_dictionary_payload(column) {
          Some(candidate) =>
            if candidate.length() < best.length() {
              best = candidate
              best_encoding = ENC_DICTIONARY
            }
          None => ()
        }
      }
    }
    Str => {
      let candidate = encode_with(column, @colenc_types.DeltaLength)
      if candidate.length() < best.length() {
        best = candidate
        best_encoding = ENC_DELTA_LENGTH
      }
      let prefix_sharing = match column {
        ByteArrays(values) => sample_prefix_useful(values)
        _ => false
      }
      if prefix_sharing {
        let candidate = encode_with(column, @colenc_types.DeltaByteArray)
        if candidate.length() < best.length() {
          best = candidate
          best_encoding = ENC_DELTA_BYTE_ARRAY
        }
      }
      if sample_dict_useful(column) {
        match encode_dictionary_payload(column) {
          Some(candidate) =>
            if candidate.length() < best.length() {
              best = candidate
              best_encoding = ENC_DICTIONARY
            }
          None => ()
        }
      }
    }
    Float64 | Bool => ()
  }
  (best_encoding, best)
}

///|
/// Fill `vec` from a dense column plus presence flags, in row order.
fn fill_vector(
  vec : ColumnVector,
  column : @colenc_types.ColBuf,
  flags : Array[Bool],
  n : Int32,
  dt : DataType,
) -> Unit raise SqlError {
  match column {
    Int32s(values) => {
      let mut k = 0
      for r in 0..<n {
        if flags[r] {
          match dt {
            Date => vec.set(r, Date(values[k]))
            _ => vec.set(r, Int32(values[k]))
          }
          k += 1
        } else {
          vec.set(r, Null)
        }
      }
    }
    Int64s(values) => {
      let mut k = 0
      for r in 0..<n {
        if flags[r] {
          vec.set(r, Int64(values[k]))
          k += 1
        } else {
          vec.set(r, Null)
        }
      }
    }
    Doubles(values) => {
      let mut k = 0
      for r in 0..<n {
        if flags[r] {
          vec.set(r, Float64(values[k]))
          k += 1
        } else {
          vec.set(r, Null)
        }
      }
    }
    ByteArrays(values) => {
      let mut k = 0
      for r in 0..<n {
        if flags[r] {
          vec.set(r, Str(@utf8.decode_lossy(values[k][:])))
          k += 1
        } else {
          vec.set(r, Null)
        }
      }
    }
    Floats(_) =>
      raise spill_read_error("FLOAT columns are not supported in spill files")
    Bools(values) => {
      let mut k = 0
      for r in 0..<n {
        if flags[r] {
          vec.set(r, Boolean(values[k]))
          k += 1
        } else {
          vec.set(r, Null)
        }
      }
    }
  }
}

// --------------------------------------------------------------- public API

///|
/// Serialize batches into the spill wire format.
pub fn DataBatch::to_spill_bytes(
  batches : Array[DataBatch],
) -> Bytes raise SqlError {
  let out : @buffer.Buffer = @buffer.Buffer::Buffer(size_hint=1 << 20)
  out.write_bytes(b"MLSPILL3")
  write_i32(out, batches.length())
  for batch in batches {
    let n = batch.row_count()
    let cols = batch.columns()
    write_i32(out, n)
    write_i32(out, cols.length())
    for col in cols {
      let (column, flags) = collect_column(col, n)
      let (encoding, payload) = choose_payload(col.dtype(), column)
      out.write_byte(dtype_code(col.dtype()))
      out.write_byte(encoding.to_byte())
      write_i32(out, payload.length())
      let mut has_null = false
      for r in 0..<n {
        if !flags[r] {
          has_null = true
        }
      }
      if has_null {
        out.write_byte(1)
        let mut bits = 0
        for r in 0..<n {
          if flags[r] {
            bits = bits | (1 << (r % 8))
          }
          if r % 8 == 7 {
            out.write_byte(bits.to_byte())
            bits = 0
          }
        }
        if n % 8 != 0 {
          out.write_byte(bits.to_byte())
        }
      } else {
        out.write_byte(0)
      }
      out.write_bytes(payload)
    }
  }
  out.to_bytes()
}

///|
fn decode_dictionary_payload(
  payload : BytesView,
  physical : @colenc_types.PhysicalType,
  non_null : Int32,
) -> @colenc_types.ColBuf raise SqlError {
  if payload.length() < 8 {
    raise spill_read_error(
      "dictionary payload is \{payload.length()} bytes, expected at least 8",
    )
  }
  let dictionary_size = read_i32_view(payload, 0)
  let dictionary_len = read_i32_view(payload, 4)
  if dictionary_size < 0 || dictionary_len < 0 {
    raise spill_read_error("negative dictionary size or length")
  }
  if 8 + dictionary_len > payload.length() {
    raise spill_read_error(
      "dictionary body overruns the payload (\{dictionary_len} of \{payload.length()})",
    )
  }
  let dictionary = payload.exact_view(start=8, end=8 + dictionary_len)
  let indices = payload.exact_view(
    start=8 + dictionary_len,
    end=payload.length(),
  )
  @colenc.decode_dictionary(
    dictionary, indices, physical, non_null, dictionary_size,
  ) catch {
    e => raise colenc_read_error(e)
  }
}

///|
/// Decode one column payload back into a vector, interleaving NULLs from the
/// presence flags.
fn decode_column(
  dt : DataType,
  encoding : Int32,
  payload : BytesView,
  flags : Array[Bool],
  rows : Int32,
  non_null : Int32,
) -> ColumnVector raise SqlError {
  let physical = spill_physical(dt)
  let column = match encoding {
    ENC_PLAIN =>
      @colenc.decode_column(payload, physical, @colenc_types.Plain, non_null) catch {
        e => raise colenc_read_error(e)
      }
    ENC_DELTA =>
      @colenc.decode_column(
        payload,
        physical,
        @colenc_types.DeltaBinaryPacked,
        non_null,
      ) catch {
        e => raise colenc_read_error(e)
      }
    ENC_DELTA_LENGTH =>
      @colenc.decode_column(
        payload,
        physical,
        @colenc_types.DeltaLength,
        non_null,
      ) catch {
        e => raise colenc_read_error(e)
      }
    ENC_DELTA_BYTE_ARRAY =>
      @colenc.decode_column(
        payload,
        physical,
        @colenc_types.DeltaByteArray,
        non_null,
      ) catch {
        e => raise colenc_read_error(e)
      }
    ENC_DICTIONARY => decode_dictionary_payload(payload, physical, non_null)
    _ => raise spill_read_error("unknown encoding code \{encoding}")
  }
  let vec = ColumnVector::make(dt, rows)
  fill_vector(vec, column, flags, rows, dt)
  vec
}

///|
/// Deserialize batches from the spill wire format. A corrupt buffer is an
/// Execute error; spill files never outlive the process, so earlier versions
/// (MLSPILL1, MLSPILL2) are rejected by the magic rather than read.
pub fn DataBatch::from_spill_bytes(
  buf : Bytes,
) -> Array[DataBatch] raise SqlError {
  if buf.length() < 16 || @utf8.decode_lossy(buf[0:8]) != "MLSPILL3" {
    raise spill_read_error("bad magic")
  }
  let batch_count = read_i32(buf, 8)
  if batch_count < 0 {
    raise spill_read_error("negative batch count \{batch_count}")
  }
  let mut pos = 12
  let out : Array[DataBatch] = []
  for b in 0..<batch_count {
    let rows = read_i32_checked(buf, pos, "batch \{b} row count")
    pos += 4
    if rows < 0 {
      raise spill_read_error("batch \{b}: negative row count \{rows}")
    }
    let ncols = read_i32_checked(buf, pos, "batch \{b} column count")
    pos += 4
    if ncols < 0 {
      raise spill_read_error("batch \{b}: negative column count \{ncols}")
    }
    let cols : Array[ColumnVector] = []
    for c in 0..<ncols {
      if pos + 2 > buf.length() {
        raise spill_read_error(
          "truncated at batch \{b} column \{c} header (pos \{pos}, len \{buf.length()})",
        )
      }
      let dt = code_dtype(buf[pos])
      pos += 1
      let encoding = buf[pos].to_int()
      pos += 1
      let payload_len = read_i32_checked(buf, pos, "column payload length")
      pos += 4
      if payload_len < 0 {
        raise spill_read_error("negative payload length \{payload_len}")
      }
      if pos >= buf.length() {
        raise spill_read_error(
          "truncated at batch \{b} column \{c} null mode (pos \{pos}, len \{buf.length()})",
        )
      }
      let null_mode = buf[pos].to_int()
      pos += 1
      let presence_bytes : Int32 = match null_mode {
        0 => 0
        1 => (rows + 7) >> 3
        _ =>
          raise spill_read_error(
            "batch \{b} column \{c}: unknown null mode \{null_mode}",
          )
      }
      if pos + presence_bytes + payload_len > buf.length() {
        raise spill_read_error(
          "truncated at batch \{b} column \{c} body (pos \{pos}, presence \{presence_bytes}, payload \{payload_len}, len \{buf.length()})",
        )
      }
      let flags : Array[Bool] = []
      let mut non_null = 0
      if null_mode == 0 {
        non_null = rows
        for _r in 0..<rows {
          flags.push(true)
        }
      } else {
        for r in 0..<rows {
          let byte = buf[pos + (r >> 3)].to_int()
          let present = ((byte >> (r % 8)) & 1) == 1
          flags.push(present)
          if present {
            non_null += 1
          }
        }
      }
      pos += presence_bytes
      let payload = buf[pos:pos + payload_len]
      pos += payload_len
      cols.push(decode_column(dt, encoding, payload, flags, rows, non_null))
    }
    out.push(DataBatch::new(cols, rows))
  }
  out
}
