// Integration tests for the colenc-backed decoders: the fixtures are tiny
// Parquet files written by pyarrow with one required column each (format 2.6,
// data page v1, uncompressed, no statistics), the same settings colenc's
// acceptance rig uses. The bytes are embedded so the test runs on every target
// without touching the file system.

///|
fn hex_digit(ch : Char) -> Int32 {
  let code = ch.to_int()
  if code >= 48 && code <= 57 {
    code - 48
  } else if code >= 97 && code <= 102 {
    code - 87
  } else {
    code - 55
  }
}

///|
fn hex_bytes(text : String) -> Bytes {
  let out = Buffer()
  let mut pending = -1
  for ch in text {
    let value = hex_digit(ch)
    if pending < 0 {
      pending = value
    } else {
      out.write_byte((pending * 16 + value).to_byte())
      pending = -1
    }
  }
  out.to_bytes()
}

///|
fn scan_fixture(text : String, rows : Int32) -> @types.ColumnVector raise {
  let entry = @parquet.scan_bytes(hex_bytes(text), "t", []) catch {
    e => abort("\{e}")
  }
  let batches = entry.scan(@catalog.ScanRequest::all(1)) catch {
    e => abort("\{e}")
  }
  assert_eq(batches.length(), 1)
  let batch = batches[0]
  assert_eq(batch.row_count(), rows)
  batch.columns()[0]
}

///|
const DELTA_INT32 : String = "504152311500153c153c2c1510150a150615061c0000008001040802170500000070457099010000000000000000000000000000001504192c35001806736368656d6115020015022500180163001610191c191c26001c15021925060a1918016315001610166216622608491c1500150a15020000001662161026081662002820706172717565742d6370702d6172726f772076657273696f6e2032362e302e30191c1c0000007200000050415231"

///|
const DELTA_INT64 : String = "504152311500154415442c150a150a150615061c000000800204050e0203000000120a000000000000000000000000000000000000000000001504192c35001806736368656d611502001504250018016300160a191c191c26001c15041925060a191801631500160a166a166a2608491c1500150a1502000000166a160a2608166a002820706172717565742d6370702d6172726f772076657273696f6e2032362e302e30191c1c0000007200000050415231"

///|
const DELTA_LENGTH : String = "504152311500153a153a2c1508150c150615061c00000080010404040503000000440100000000000000000000616162626263631504192c35001806736368656d61150200150c250018016325004c1c0000001608191c191c26001c150c1925060c1918016315001608166016602608491c1500150c1502003c160e190619060000001660160826081660002820706172717565742d6370702d6172726f772076657273696f6e2032362e302e30191c1c0000008000000050415231"

///|
const DELTA_BYTE_ARRAY : String = "5041523115001594011594012c1508150e150615061c00000080010404000d040000000e07000000000000000000000000000080010404100d04000000b00a00000000000000000000000000007368617265642d31326f746865727368617265642d331504192c35001806736368656d61150200150c250018016325004c1c0000001608191c191c26001c150c1925060e191801631500160816be0116be012608491c1500150e1502003c163a1906190600000016be011608260816be01002820706172717565742d6370702d6172726f772076657273696f6e2032362e302e30191c1c0000008400000050415231"

///|
const BSS_FLOAT : String = "504152311500152015202c15081512150615061c0000000000000000000000c01000603fc000401504192c35001806736368656d6115020015082500180163001608191c191c26001c1508192506121918016315001608164616462608491c1500151215020000001646160826081646002820706172717565742d6370702d6172726f772076657273696f6e2032362e302e30191c1c0000007200000050415231"

///|
const BSS_DOUBLE : String = "504152311500154015402c15081512150615061c000000000000000000000000000000000000000000000000000000f802000c3fc000401504192c35001806736368656d61150200150a2500180163001608191c191c26001c150a192506121918016315001608166616662608491c1500151215020000001666160826081666002820706172717565742d6370702d6172726f772076657273696f6e2032362e302e30191c1c0000007200000050415231"

///|
const RLE_BOOL : String = "504152311500150e150e2c15121506150615061c000000030000000573011504192c35001806736368656d6115020015002500180163001612191c191c26001c15001915061918016315001612163416342608491c1500150615020000001634161226081634002820706172717565742d6370702d6172726f772076657273696f6e2032362e302e30191c1c0000007100000050415231"

///|
const DICT_INT32 : String = "504152311504151815184c150615001200000500000007000000090000001500150815082c150a1510150615061c000000020384011504192c35001806736368656d611502001502250018016300160a191c191c26001c15021935000610191801631500160a16621662263c2608292c150415001502001500151015020000001662160a26081662002820706172717565742d6370702d6172726f772076657273696f6e2032362e302e30191c1c0000007c00000050415231"

///|
test "colenc decodes DELTA_BINARY_PACKED int32 pages" {
  let column = scan_fixture(DELTA_INT32, 8)
  assert_eq(column.get(0), @types.Int32(1))
  assert_eq(column.get(3), @types.Int32(9))
  assert_eq(column.get(4), @types.Int32(-3))
  assert_eq(column.get(7), @types.Int32(2))
}

///|
test "colenc decodes DELTA_BINARY_PACKED int64 pages" {
  let column = scan_fixture(DELTA_INT64, 5)
  assert_eq(column.get(0), @types.Int64(7))
  assert_eq(column.get(2), @types.Int64(13))
  assert_eq(column.get(4), @types.Int64(20))
}

///|
test "colenc decodes DELTA_LENGTH_BYTE_ARRAY pages" {
  let column = scan_fixture(DELTA_LENGTH, 4)
  assert_eq(column.get(0), @types.Str("aa"))
  assert_eq(column.get(1), @types.Str("bbb"))
  assert_eq(column.get(2), @types.Str(""))
  assert_eq(column.get(3), @types.Str("cc"))
}

///|
test "colenc decodes DELTA_BYTE_ARRAY pages" {
  let column = scan_fixture(DELTA_BYTE_ARRAY, 4)
  assert_eq(column.get(0), @types.Str("shared-1"))
  assert_eq(column.get(2), @types.Str("other"))
  assert_eq(column.get(3), @types.Str("shared-3"))
}

///|
test "colenc decodes BYTE_STREAM_SPLIT float pages" {
  let column = scan_fixture(BSS_FLOAT, 4)
  assert_eq(column.get(0), @types.Float64(1.5))
  assert_eq(column.get(1), @types.Float64(-2.25))
  assert_eq(column.get(3), @types.Float64(3.5))
}

///|
test "colenc decodes BYTE_STREAM_SPLIT double pages" {
  let column = scan_fixture(BSS_DOUBLE, 4)
  assert_eq(column.get(0), @types.Float64(1.5))
  assert_eq(column.get(2), @types.Float64(0.0))
  assert_eq(column.get(3), @types.Float64(3.5))
}

///|
test "colenc decodes RLE boolean pages" {
  let column = scan_fixture(RLE_BOOL, 9)
  assert_eq(column.get(0), @types.Boolean(true))
  assert_eq(column.get(2), @types.Boolean(false))
  assert_eq(column.get(4), @types.Boolean(true))
  assert_eq(column.get(7), @types.Boolean(false))
}

///|
test "dictionary int32 pages still decode through the existing path" {
  let column = scan_fixture(DICT_INT32, 5)
  assert_eq(column.get(0), @types.Int32(5))
  assert_eq(column.get(1), @types.Int32(7))
  assert_eq(column.get(3), @types.Int32(9))
}
