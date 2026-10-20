// Page decoding: turns the column chunks of a Parquet file into values the
// adapter can hand to the engine.
//
// Scope: flat schemas, data page v1, PLAIN and dictionary encodings,
// UNCOMPRESSED and SNAPPY. Anything else is refused with a pointed message
// rather than guessed at, because a wrong decode is worse than a refusal.

///|
/// Decoded values for one column, with a parallel validity array. A `false`
/// entry means SQL NULL, which in Parquet means the definition level was
/// below the maximum.
priv enum ColumnValues {
  Bools(Array[Bool], Array[Bool])
  Int32s(Array[Int32], Array[Bool])
  Int64s(Array[Int64], Array[Bool])
  Floats(Array[Float], Array[Bool])
  Doubles(Array[Double], Array[Bool])
  Strings(Array[String], Array[Bool])
}

///|
fn unsupported(msg : String) -> @types.SqlError {
  @types.SqlError::Scan("parquet: " + msg)
}

///|
/// A page header, flattened into the fields the decoders need.
priv struct PageHeader {
  page_type : Int32
  uncompressed_size : Int32
  compressed_size : Int32
  num_values : Int32
  encoding : Encoding
  def_encoding : Encoding
  dict_num_values : Int32
}

///|
fn parse_page_header(tr : Tr) -> PageHeader raise @types.SqlError {
  let mut page_type = 0
  let mut uncompressed_size = 0
  let mut compressed_size = 0
  let mut num_values = 0
  let mut encoding = Plain
  let mut def_encoding = Plain
  let mut dict_num_values = 0
  let mut last : Int32 = 0
  while true {
    let (id, t) = tr.field_header(last)
    last = id
    if t is Stop {
      break
    }
    match id {
      1 => if t is I32T { page_type = tr.zigzag_i32() } else { tr.skip(t) }
      2 =>
        if t is I32T {
          uncompressed_size = tr.zigzag_i32()
        } else {
          tr.skip(t)
        }
      3 =>
        if t is I32T {
          compressed_size = tr.zigzag_i32()
        } else {
          tr.skip(t)
        }
      5 =>
        if t is StructT {
          let (n, e, de) = parse_data_page_header(tr)
          num_values = n
          encoding = e
          def_encoding = de
        } else {
          tr.skip(t)
        }
      7 =>
        if t is StructT {
          let (n, e) = parse_dictionary_page_header(tr)
          dict_num_values = n
          encoding = e
        } else {
          tr.skip(t)
        }
      _ => tr.skip(t)
    }
  }
  {
    page_type,
    uncompressed_size,
    compressed_size,
    num_values,
    encoding,
    def_encoding,
    dict_num_values,
  }
}

///|
fn parse_data_page_header(
  tr : Tr,
) -> (Int32, Encoding, Encoding) raise @types.SqlError {
  let mut num_values = 0
  let mut encoding = Plain
  let mut def_encoding = Plain
  let mut last : Int32 = 0
  while true {
    let (id, t) = tr.field_header(last)
    last = id
    if t is Stop {
      break
    }
    match id {
      1 => if t is I32T { num_values = tr.zigzag_i32() } else { tr.skip(t) }
      2 =>
        if t is I32T {
          encoding = encoding_of(tr.zigzag_i32())
        } else {
          tr.skip(t)
        }
      3 =>
        if t is I32T {
          def_encoding = encoding_of(tr.zigzag_i32())
        } else {
          tr.skip(t)
        }
      _ => tr.skip(t)
    }
  }
  (num_values, encoding, def_encoding)
}

///|
fn parse_dictionary_page_header(
  tr : Tr,
) -> (Int32, Encoding) raise @types.SqlError {
  let mut num_values = 0
  let mut encoding = Plain
  let mut last : Int32 = 0
  while true {
    let (id, t) = tr.field_header(last)
    last = id
    if t is Stop {
      break
    }
    match id {
      1 => if t is I32T { num_values = tr.zigzag_i32() } else { tr.skip(t) }
      2 =>
        if t is I32T {
          encoding = encoding_of(tr.zigzag_i32())
        } else {
          tr.skip(t)
        }
      _ => tr.skip(t)
    }
  }
  (num_values, encoding)
}

// ------------------------------------------------------------------ RLE

///|
/// RLE / bit-packed hybrid decoder over a byte range — the format Parquet
/// uses both for definition levels and for dictionary indices. A run header
/// carries a mode bit: an RLE run repeats one value, a bit-packed run holds
/// `count * 8` values at a fixed bit width, packed LSB-first.
priv struct Hybrid {
  data : BytesView
  mut pos : Int32
  bit_width : Int32
  mut run_left : Int32
  mut run_value : Int32
  mut packed_left : Int32
  mut packed_base : Int32
  mut packed_index : Int32
}

///|
fn hybrid_new(data : BytesView, bit_width : Int32) -> Hybrid {
  {
    data,
    pos: 0,
    bit_width,
    run_left: 0,
    run_value: 0,
    packed_left: 0,
    packed_base: 0,
    packed_index: 0,
  }
}

///|
fn hybrid_byte_len(bit_width : Int32) -> Int32 {
  (bit_width + 7) / 8
}

///|
fn Hybrid::varint(self : Hybrid) -> Int32 raise @types.SqlError {
  let mut result = 0
  let mut shift = 0
  while true {
    if self.pos >= self.data.length() {
      raise unsupported("truncated RLE run header")
    }
    let b = self.data[self.pos].to_int()
    self.pos += 1
    result = result | ((b & 0x7F) << shift)
    if (b & 0x80) == 0 {
      break
    }
    shift += 7
    if shift > 28 {
      raise unsupported("RLE run header longer than 4 bytes")
    }
  }
  result
}

///|
/// Next value from the stream. Raises when the stream runs out, so a
/// malformed page cannot silently produce zeros.
fn Hybrid::next(self : Hybrid) -> Int32 raise @types.SqlError {
  if self.run_left > 0 {
    self.run_left -= 1
    return self.run_value
  }
  if self.packed_left > 0 {
    let offset = self.packed_index * self.bit_width
    let base = self.packed_base + offset / 8
    let shift = offset % 8
    // one byte is enough for bit widths up to 8 (levels); wider widths
    // (dictionary indices) need a window
    let window_bytes = hybrid_byte_len(self.bit_width + shift)
    let mut window : UInt64 = 0UL
    for k in 0..<window_bytes {
      let p = base + k
      if p < self.data.length() {
        window = window | (self.data[p].to_uint64() << (8 * k))
      }
    }
    self.packed_index += 1
    self.packed_left -= 1
    ((window >> shift) & ((1UL << self.bit_width) - 1UL)).to_int()
  } else {
    if self.pos >= self.data.length() {
      raise unsupported("RLE/bit-packed stream ran out of run headers")
    }
    let header = self.varint()
    let mode = header & 1
    let count = header >> 1
    if count == 0 {
      raise unsupported("RLE run with zero values")
    }
    if mode == 0 {
      let n = hybrid_byte_len(self.bit_width)
      if self.pos + n > self.data.length() {
        raise unsupported("truncated RLE run value")
      }
      let mut v = 0
      for i in 0..<n {
        v = v | (self.data[self.pos + i].to_int() << (8 * i))
      }
      self.pos += n
      self.run_value = v
      self.run_left = count
    } else {
      self.packed_base = self.pos
      self.packed_index = 0
      self.packed_left = count * 8
      // a bit-packed run holds count * 8 values, i.e. exactly count bytes
      // per bit of width
      self.pos += count * self.bit_width
      if self.pos > self.data.length() {
        raise unsupported("bit-packed run overruns the page")
      }
    }
    self.next()
  }
}

///|
fn bit_width_of(max_level : Int32) -> Int32 {
  let mut w = 0
  let mut v = max_level
  while v > 0 {
    w += 1
    v = v >> 1
  }
  w
}

///|
/// Definition levels of a data page v1: a 4-byte little-endian byte length
/// followed by the RLE hybrid stream. A required column (max level 0) has no
/// level data at all.
fn read_def_levels_v1(
  tr : Tr,
  max_level : Int32,
  num_values : Int32,
) -> Array[Bool] raise @types.SqlError {
  if max_level == 0 {
    return Array::make(num_values, true)
  }
  tr.need(4)
  let mut len = 0
  for i in 0..<4 {
    len = len | (tr.u8() << (8 * i))
  }
  tr.need(len)
  let view = tr.data.exact_view(start=tr.pos, end=tr.pos + len)
  tr.pos += len
  let hybrid = hybrid_new(view, bit_width_of(max_level))
  let out : Array[Bool] = []
  for _ in 0..<num_values {
    out.push(hybrid.next() == max_level)
  }
  out
}

// -------------------------------------------------------- plain decoding

///|
fn plain_booleans(
  data : BytesView,
  n : Int32,
) -> Array[Bool] raise @types.SqlError {
  let need = (n + 7) / 8
  if data.length() < need {
    raise unsupported(
      "PLAIN BOOLEAN page needs \{need} bytes for \{n} values but has \{data.length()}",
    )
  }
  let out : Array[Bool] = []
  for i in 0..<n {
    let byte = data[i / 8].to_int()
    out.push(((byte >> (i % 8)) & 1) == 1)
  }
  out
}

///|
fn plain_i32(data : BytesView, n : Int32) -> Array[Int32] raise @types.SqlError {
  if data.length() < n * 4 {
    raise unsupported("PLAIN INT32 page is short")
  }
  let out : Array[Int32] = []
  for i in 0..<n {
    let mut v = 0
    for b in 0..<4 {
      v = v | (data[i * 4 + b].to_int() << (8 * b))
    }
    out.push(v)
  }
  out
}

///|
fn plain_i64(data : BytesView, n : Int32) -> Array[Int64] raise @types.SqlError {
  if data.length() < n * 8 {
    raise unsupported("PLAIN INT64 page is short")
  }
  let out : Array[Int64] = []
  for i in 0..<n {
    let mut v : UInt64 = 0UL
    for b in 0..<8 {
      v = v | (data[i * 8 + b].to_uint64() << (8 * b))
    }
    out.push(v.reinterpret_as_int64())
  }
  out
}

///|
fn plain_f32(data : BytesView, n : Int32) -> Array[Float] raise @types.SqlError {
  let raw = plain_i32(data, n)
  let out : Array[Float] = []
  for v in raw {
    out.push(Float::reinterpret_from_int(v))
  }
  out
}

///|
fn plain_f64(
  data : BytesView,
  n : Int32,
) -> Array[Double] raise @types.SqlError {
  let raw = plain_i64(data, n)
  let out : Array[Double] = []
  for v in raw {
    out.push(v.reinterpret_as_double())
  }
  out
}

///|
fn plain_strings(
  data : BytesView,
  n : Int32,
) -> Array[String] raise @types.SqlError {
  let out : Array[String] = []
  let mut pos = 0
  for _ in 0..<n {
    if pos + 4 > data.length() {
      raise unsupported("PLAIN BYTE_ARRAY page is short")
    }
    let mut len = 0
    for b in 0..<4 {
      len = len | (data[pos + b].to_int() << (8 * b))
    }
    pos += 4
    if len < 0 || pos + len > data.length() {
      raise unsupported("PLAIN BYTE_ARRAY value overruns the page")
    }
    out.push(@utf8.decode_lossy(data.exact_view(start=pos, end=pos + len)))
    pos += len
  }
  out
}
