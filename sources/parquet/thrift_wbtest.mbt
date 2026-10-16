// Unit tests for the Thrift compact-protocol reader, driven by hand-built
// byte buffers so they run on every target.

///|
fn bytes_of(values : Array[Int32]) -> Bytes {
  Bytes::makei(values.length(), fn(i) { values[i].to_byte() })
}

///|
fn decode_varint(values : Array[Int32]) -> UInt64 raise @types.SqlError {
  let tr = Tr::new(bytes_of(values))
  tr.varint()
}

///|
test "compact varint ignores the continuation flag bit" {
  // 0x96 has the continuation bit set: its low 7 bits are 0x16, and the
  // next byte contributes 4 << 7 — a decoder that forgets to mask off
  // 0x80 reads 128 too much here
  assert_eq(decode_varint([0x96, 0x04]), 534UL)
  assert_eq(decode_varint([0x01]), 1UL)
  assert_eq(decode_varint([0xFF, 0x01]), 255UL)
  assert_eq(decode_varint([0x80, 0x01]), 128UL)
}

///|
test "zigzag decodes signed integers" {
  let tr = Tr::new(bytes_of([0x00, 0x02, 0x01, 0xFE, 0x01, 0x03]))
  assert_eq(tr.zigzag_i64(), 0L)
  assert_eq(tr.zigzag_i64(), 1L)
  assert_eq(tr.zigzag_i64(), -1L)
  assert_eq(tr.zigzag_i64(), 127L)
  assert_eq(tr.zigzag_i64(), -2L)
}

///|
test "field headers carry deltas and stop at the struct end" {
  // field 1 (i32) = 5, field 2 (binary) = "hi", field 9 (i64) = 7, STOP
  let tr = Tr::new(
    bytes_of([
      0x15, 0x0A, // delta 1, type I32T, zigzag 10 -> 5
       0x18, 0x02, 0x68, 0x69, // delta 1, type BINARY, len 2, "hi"
       0x76, 0x0E, // delta 7, type I64T, zigzag 14 -> 7
       0x00, // STOP
    ]),
  )
  let mut last = 0
  let (id, t) = tr.field_header(last)
  last = id
  assert_eq(id, 1)
  assert_true(t is I32T)
  assert_eq(tr.zigzag_i32(), 5)
  let (id, t) = tr.field_header(last)
  last = id
  assert_eq(id, 2)
  assert_true(t is BinaryT)
  assert_eq(tr.string(), "hi")
  let (id, t) = tr.field_header(last)
  last = id
  assert_eq(id, 9)
  assert_true(t is I64T)
  assert_eq(tr.zigzag_i64(), 7L)
  let (_, t) = tr.field_header(last)
  assert_true(t is Stop)
  assert_eq(tr.remaining(), 0)
}

///|
test "long-form field headers carry an explicit id" {
  // delta 0 means the id follows as a zigzag varint: field 42, i32 = 3
  let tr = Tr::new(bytes_of([0x05, 0x54, 0x06, 0x00]))
  let (id, t) = tr.field_header(0)
  assert_eq(id, 42)
  assert_true(t is I32T)
  assert_eq(tr.zigzag_i32(), 3)
  assert_true(tr.field_header(id) is (_, Stop))
}

///|
test "unknown fields are skipped without losing alignment" {
  // one struct holding every shape we do not read: binary, list, nested
  // struct, bool, double — after skipping them the STOP must be next
  let tr = Tr::new(
    bytes_of([
      0x18, 0x03, 0x61, 0x62, 0x63, // field 1: binary "abc"
       0x19, 0x25, 0x02, 0x04, // field 2: list<i32> [1, 2]
       0x1C, 0x15, 0x0A, 0x00, // field 3: struct { field 1: i32 = 5 }
       0x11, // field 4: bool true (encoded in the header)
       0x17, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F, // field 5: double 1.0
       0x00, // STOP
    ]),
  )
  let mut last = 0
  let mut fields = 0
  while true {
    let (id, t) = tr.field_header(last)
    last = id
    if t is Stop {
      break
    }
    tr.skip(t)
    fields += 1
  }
  assert_eq(fields, 5)
  assert_eq(tr.remaining(), 0)
}

///|
test "truncated input raises a scan error instead of trapping" {
  let short_varint = try {
    let _ = Tr::new(bytes_of([0x96])).varint()
    false
  } catch {
    _ => true
  }
  assert_true(short_varint)
  let empty = try {
    let _ = Tr::new(bytes_of([])).u8()
    false
  } catch {
    _ => true
  }
  assert_true(empty)
  let truncated_binary = try {
    let _ = Tr::new(bytes_of([0x18, 0x05, 0x61])).binary()
    false
  } catch {
    _ => true
  }
  assert_true(truncated_binary)
}

///|
test "list headers handle short and long forms" {
  // short form: size in the high nibble (3 i64 elements)
  let tr = Tr::new(bytes_of([0x36, 0x02, 0x04, 0x06]))
  let (t, n) = tr.list_header()
  assert_true(t is I64T)
  assert_eq(n, 3)
  assert_eq(tr.zigzag_i64(), 1L)
  assert_eq(tr.zigzag_i64(), 2L)
  assert_eq(tr.zigzag_i64(), 3L)
  // long form: 0xF nibble followed by a varint size
  let tr = Tr::new(bytes_of([0xF5, 0x14]))
  let (t, n) = tr.list_header()
  assert_true(t is I32T)
  assert_eq(n, 20)
}
