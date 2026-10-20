// Whitebox tests for the statistics layer: what is trusted as a bound and
// what is refused, and how one row group is ruled out. These pin the guards
// that no fixture can reach (inexact bounds, non-UTF-8 bounds).

///|
fn stats_el(physical : PhysicalType?) -> SchemaElement {
  {
    name: "c",
    physical,
    repetition: Some(Optional),
    num_children: 0,
    is_timestamp: false,
    converted: None,
    logical: None,
    int_bit_width: 0,
    int_signed: true,
  }
}

///|
fn stats_of(
  min : Bytes?,
  max : Bytes?,
  min_exact : Bool?,
  max_exact : Bool?,
  null_count : Int64?,
) -> Statistics {
  {
    null_count,
    min_value: min,
    max_value: max,
    min_deprecated: None,
    max_deprecated: None,
    is_min_exact: min_exact,
    is_max_exact: max_exact,
  }
}

///|
test "inexact bounds are refused" {
  let el = stats_el(Some(ByteArrayT))
  // the writer truncated the strings: the stored value may not be a bound
  let inexact = stats_of(
    Some(b"aaa"),
    Some(b"zzz"),
    Some(true),
    Some(false),
    None,
  )
  assert_true(bounds_for(el, inexact) is None)
  let exact = stats_of(Some(b"aaa"), Some(b"zzz"), Some(true), Some(true), None)
  assert_true(bounds_for(el, exact) is Some(_))
  // flags absent (older writers): the bounds are used
  let unflagged = stats_of(Some(b"aaa"), Some(b"zzz"), None, None, None)
  assert_true(bounds_for(el, unflagged) is Some(_))
}

///|
test "non-UTF-8 string bounds are refused" {
  // the reader decodes BYTE_ARRAY lossily, so a bound that is not valid UTF-8
  // describes a different string than the column's rows
  let el = stats_el(Some(ByteArrayT))
  let bad = stats_of(Some(b"\xff\xfe"), Some(b"\xff\xff"), None, None, None)
  assert_true(bounds_for(el, bad) is None)
}

///|
test "the deprecated min/max pair is used for numbers, refused for byte arrays" {
  let int_el = stats_el(Some(Int32T))
  let deprecated : Statistics = {
    null_count: None,
    min_value: None,
    max_value: None,
    min_deprecated: Some(b"\x01\x00\x00\x00"),
    max_deprecated: Some(b"\x0a\x00\x00\x00"),
    is_min_exact: None,
    is_max_exact: None,
  }
  assert_true(bounds_for(int_el, deprecated) is Some(_))
  // signed byte order makes the deprecated pair meaningless for strings
  let str_el = stats_el(Some(ByteArrayT))
  let deprecated_str : Statistics = {
    null_count: None,
    min_value: None,
    max_value: None,
    min_deprecated: Some(b"aaa"),
    max_deprecated: Some(b"zzz"),
    is_min_exact: None,
    is_max_exact: None,
  }
  assert_true(bounds_for(str_el, deprecated_str) is None)
}

///|
test "a row group is ruled out by an all-NULL chunk and by usable bounds" {
  let el = stats_el(Some(Int32T))
  let leaves : Array[(SchemaElement, Int32)] = [(el, 1)]
  let dtypes : Array[@types.DataType] = [@types.Int32]
  let all_null : ColumnMeta = {
    encodings: [Plain],
    codec: Uncompressed,
    num_values: 3L,
    total_compressed_size: 0L,
    data_page_offset: 0L,
    dictionary_page_offset: None,
    stats: Some(stats_of(None, None, None, None, Some(3L))),
  }
  let rg : RowGroupMeta = { columns: [all_null], num_rows: 3L, }
  let predicate = @catalog.ScanRequest::new([0], [
    { column: 0, op: @types.Eq, value: @types.Int32(1), },
  ])
  // every row is NULL, so `= 1` can never be true
  assert_true(group_skipped(rg, leaves, dtypes, predicate))
  // without statistics nothing can be ruled out
  let no_stats : ColumnMeta = {
    encodings: [Plain],
    codec: Uncompressed,
    num_values: 3L,
    total_compressed_size: 0L,
    data_page_offset: 0L,
    dictionary_page_offset: None,
    stats: None,
  }
  let rg2 : RowGroupMeta = { columns: [no_stats], num_rows: 3L, }
  assert_false(group_skipped(rg2, leaves, dtypes, predicate))
}
