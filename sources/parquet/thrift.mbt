// Thrift compact protocol reader — the wire format Parquet uses for its
// FileMetaData footer and for every page header.
//
// Only what those structures need is implemented: structs, lists, the
// integer forms (zigzag varint), double (little-endian), binary/string and
// booleans. Unknown fields are skipped generically, so a file written by a
// newer writer still parses as long as the fields we read keep their ids.
//
// Every read is bounds-checked: a truncated or hostile file must produce a
// SqlError, never a trap, because the engine treats scan errors as data
// errors and a trap would take the process down.

///|
/// Compact-protocol type nibble, as it appears in field headers and list
/// element headers.
priv enum TType {
  Stop
  BoolTrue
  BoolFalse
  ByteType
  I16
  I32T
  I64T
  DoubleT
  BinaryT
  ListT
  SetT
  MapT
  StructT
}

///|
/// A cursor over the bytes being parsed. `pos` only ever moves forward.
priv struct Tr {
  data : BytesView
  mut pos : Int32
}

///|
fn parquet_error(msg : String) -> @types.SqlError {
  @types.SqlError::Scan("parquet: \{msg}")
}

///|
fn Tr::new(data : BytesView) -> Tr {
  { data, pos: 0, }
}

///|
fn Tr::remaining(self : Tr) -> Int32 {
  self.data.length() - self.pos
}

///|
fn Tr::need(self : Tr, n : Int32) -> Unit raise @types.SqlError {
  if n < 0 || self.pos + n > self.data.length() {
    raise parquet_error(
      "truncated input: want \{n} byte(s) at offset \{self.pos}, \{self.remaining()} left",
    )
  }
}

///|
fn Tr::u8(self : Tr) -> Int32 raise @types.SqlError {
  self.need(1)
  let b = self.data[self.pos].to_int()
  self.pos += 1
  b
}

///|
/// Little-endian unsigned varint (LEB128), as used for lengths and for
/// zigzag-encoded integers.
fn Tr::varint(self : Tr) -> UInt64 raise @types.SqlError {
  let mut result : UInt64 = 0UL
  let mut shift = 0
  while true {
    let b = self.u8()
    result = result | ((b & 0x7F).to_uint64() << shift)
    if (b & 0x80) == 0 {
      break
    }
    shift += 7
    if shift > 63 {
      raise parquet_error("varint longer than 10 bytes at offset \{self.pos}")
    }
  }
  result
}

///|
/// Unsigned varint used as a length or count; rejects values that cannot
/// index into the file.
fn Tr::varint_size(self : Tr) -> Int32 raise @types.SqlError {
  let v = self.varint()
  if v > 0x7FFFFFFFUL {
    raise parquet_error("length \{v} out of range at offset \{self.pos}")
  }
  v.to_int()
}

///|
fn Tr::zigzag_i64(self : Tr) -> Int64 raise @types.SqlError {
  let u = self.varint()
  ((u >> 1) ^ (0UL - (u & 1UL))).reinterpret_as_int64()
}

///|
fn Tr::zigzag_i32(self : Tr) -> Int32 raise @types.SqlError {
  self.zigzag_i64().to_int()
}

///|
/// Length-prefixed bytes; the returned view aliases the input buffer.
fn Tr::binary(self : Tr) -> BytesView raise @types.SqlError {
  let n = self.varint_size()
  self.need(n)
  let view = self.data.exact_view(start=self.pos, end=self.pos + n)
  self.pos += n
  view
}

///|
fn Tr::string(self : Tr) -> String raise @types.SqlError {
  @utf8.decode_lossy(self.binary())
}

///|
fn ttype_of_nibble(nibble : Int32) -> TType raise @types.SqlError {
  match nibble {
    0 => Stop
    1 => BoolTrue
    2 => BoolFalse
    3 => ByteType
    4 => I16
    5 => I32T
    6 => I64T
    7 => DoubleT
    8 => BinaryT
    9 => ListT
    10 => SetT
    11 => MapT
    12 => StructT
    _ => raise parquet_error("unknown compact-protocol type nibble \{nibble}")
  }
}

///|
/// Read one field header. `last` is the previous field id in the *same*
/// struct: the compact protocol encodes the id as a delta from it, and the
/// caller is responsible for feeding the returned id back in. Returns
/// `Stop` when the struct ends.
fn Tr::field_header(
  self : Tr,
  last : Int32,
) -> (Int32, TType) raise @types.SqlError {
  let b = self.u8()
  if b == 0 {
    return (last, Stop)
  }
  let t = ttype_of_nibble(b & 0x0F)
  let delta = (b >> 4) & 0x0F
  if delta == 0 {
    let id = self.zigzag_i16()
    (id, t)
  } else {
    (last + delta, t)
  }
}

///|
fn Tr::zigzag_i16(self : Tr) -> Int32 raise @types.SqlError {
  self.zigzag_i32()
}

///|
/// Header of a list or set: element type plus element count.
fn Tr::list_header(self : Tr) -> (TType, Int32) raise @types.SqlError {
  let b = self.u8()
  let t = ttype_of_nibble(b & 0x0F)
  let size = (b >> 4) & 0x0F
  let n = if size == 15 { self.varint_size() } else { size }
  (t, n)
}

///|
/// Skip one value of the given type. Structs and containers recurse, so an
/// unrecognised field costs a scan but never a misparse.
fn Tr::skip(self : Tr, t : TType) -> Unit raise @types.SqlError {
  match t {
    Stop | BoolTrue | BoolFalse => ()
    ByteType => {
      let _ = self.u8()
    }
    I16 | I32T | I64T => {
      let _ = self.varint()
    }
    DoubleT => self.pos += 8
    BinaryT => {
      let _ = self.binary()
    }
    ListT | SetT => {
      let (et, n) = self.list_header()
      for _ in 0..<n {
        self.skip(et)
      }
    }
    MapT => {
      let n = self.varint_size()
      if n > 0 {
        let kv = self.u8()
        let kt = ttype_of_nibble((kv >> 4) & 0x0F)
        let vt = ttype_of_nibble(kv & 0x0F)
        for _ in 0..<n {
          self.skip(kt)
          self.skip(vt)
        }
      }
    }
    StructT => self.skip_struct()
  }
}

///|
fn Tr::skip_struct(self : Tr) -> Unit raise @types.SqlError {
  let mut last : Int32 = 0
  while true {
    let (id, t) = self.field_header(last)
    last = id
    if t is Stop {
      break
    }
    self.skip(t)
  }
}
