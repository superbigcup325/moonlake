// Unit tests for the page decoders: PLAIN value layouts, the RLE/bit-packed
// hybrid stream, and definition levels. All buffers are built by hand so the
// tests run on every target and pin the exact bit order.

///|
fn view_of(values : Array[Int32]) -> BytesView {
  bytes_of(values)[:]
}

///|
test "PLAIN fixed-width layouts are little-endian" {
  assert_eq(plain_i32(view_of([0x01, 0, 0, 0, 0x02, 0, 0, 0]), 2), [1, 2])
  assert_eq(
    plain_i64(view_of([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]), 1),
    [-1L],
  )
  // -1.0 and 1.5 as IEEE 754 bits
  assert_eq(plain_f64(view_of([0, 0, 0, 0, 0, 0, 0xF0, 0xBF]), 1), [-1.0])
  assert_eq(plain_f32(view_of([0, 0, 0xC0, 0x3F]), 1), [1.5])
}

///|
test "PLAIN BYTE_ARRAY reads length-prefixed values including empty ones" {
  let data = view_of([
    0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x61, 0x62, 0x63,
  ])
  assert_eq(plain_strings(data, 2), ["", "abc"])
}

///|
test "PLAIN BOOLEAN is bit-packed least-significant-bit first" {
  // 0xB2 = 1011_0010 -> bits from the LSB up
  assert_eq(plain_booleans(view_of([0xB2]), 8), [
    false, true, false, false, true, true, false, true,
  ])
  // only the bits the page declares are read
  assert_eq(plain_booleans(view_of([0xB2]), 3), [false, true, false])
}

///|
test "hybrid stream decodes an RLE run" {
  // run header 0x06: count 3, RLE mode; one byte of value for bit width 1
  let h = hybrid_new(view_of([0x06, 0x01]), 1)
  assert_eq(h.next(), 1)
  assert_eq(h.next(), 1)
  assert_eq(h.next(), 1)
  // a second run continues the stream: count 2, value 0
  let h = hybrid_new(view_of([0x06, 0x01, 0x04, 0x00]), 1)
  let out : Array[Int32] = []
  for _ in 0..<5 {
    out.push(h.next())
  }
  assert_eq(out, [1, 1, 1, 0, 0])
}

///|
test "hybrid stream decodes bit-packed runs at any width" {
  // width 1, count 1 run -> 8 values from one byte
  let h = hybrid_new(view_of([0x03, 0xB2]), 1)
  let out : Array[Int32] = []
  for _ in 0..<8 {
    out.push(h.next())
  }
  assert_eq(out, [0, 1, 0, 0, 1, 1, 0, 1])
  // width 3, count 1 run -> 8 values packed into three bytes (LSB first)
  let h = hybrid_new(view_of([0x03, 0x88, 0xC6, 0x1A]), 3)
  assert_eq(h.next(), 0)
  assert_eq(h.next(), 1)
  assert_eq(h.next(), 2)
  assert_eq(h.next(), 3)
  assert_eq(h.next(), 4)
  assert_eq(h.next(), 5)
  assert_eq(h.next(), 6)
  assert_eq(h.next(), 0)
}

///|
test "a bit-packed run is left behind at the right byte before the next run" {
  // the real index stream of the dict fixture, truncated to one packed run
  // followed by an RLE run: a decoder that advances by the value count
  // instead of count * bit_width bytes reads the RLE header out of the
  // middle of the packed data
  let h = hybrid_new(
    view_of([
      // packed run: header 0x03 -> 8 values at 3 bits
      0x03, 0x88, 0xC6, 0x1A,
      // RLE run: header 0x02 -> 1 value, then the value byte
       0x02, 0x05,
    ]),
    3,
  )
  let out : Array[Int32] = []
  for _ in 0..<9 {
    out.push(h.next())
  }
  assert_eq(out, [0, 1, 2, 3, 4, 5, 6, 0, 5])
}

///|
test "definition levels are read through the v1 length prefix" {
  // a required column carries no level data at all
  let tr = Tr::new(bytes_of([0xFF]))
  assert_eq(read_def_levels_v1(tr, 0, 3), [true, true, true])
  assert_eq(tr.remaining(), 1)
  // max level 1: 4-byte length, then two RLE runs (0,0) and (1,1)
  let tr = Tr::new(bytes_of([0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x04, 0x01]))
  assert_eq(read_def_levels_v1(tr, 1, 4), [false, false, true, true])
  assert_eq(tr.remaining(), 0)
}

///|
test "malformed page data raises a scan error" {
  let bad_levels = try {
    // the length prefix claims 8 bytes but only one follows
    let _ = read_def_levels_v1(Tr::new(bytes_of([0x08, 0, 0, 0, 0x06])), 1, 3)
    false
  } catch {
    _ => true
  }
  assert_true(bad_levels)
  let short_ints = try {
    let _ = plain_i32(view_of([0x01]), 2)
    false
  } catch {
    _ => true
  }
  assert_true(short_ints)
  let short_string = try {
    // says 5 bytes, has 2
    let _ = plain_strings(view_of([0x05, 0, 0, 0, 0x61, 0x62]), 1)
    false
  } catch {
    _ => true
  }
  assert_true(short_string)
  let exhausted = try {
    let h = hybrid_new(view_of([]), 1)
    let _ = h.next()
    false
  } catch {
    _ => true
  }
  assert_true(exhausted)
}
