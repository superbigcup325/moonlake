// Parquet file metadata: the Thrift structures in the footer plus the
// parsing that turns them into something the reader can walk.
//
// Field ids follow parquet-format's parquet.thrift. Anything we do not
// read is skipped, so a writer that adds fields stays readable.

///|
/// Physical (on-disk) column type. INT96 and FIXED_LEN_BYTE_ARRAY parse but
/// are rejected later, by the adapter, with a pointed message.
priv enum PhysicalType {
  BooleanT
  Int32T
  Int64T
  Int96T
  FloatT
  DoubleT
  ByteArrayT
  FixedLenByteArrayT
  UnknownPhysical(Int32)
}

///|
fn physical_type_of(id : Int32) -> PhysicalType {
  match id {
    0 => BooleanT
    1 => Int32T
    2 => Int64T
    3 => Int96T
    4 => FloatT
    5 => DoubleT
    6 => ByteArrayT
    7 => FixedLenByteArrayT
    other => UnknownPhysical(other)
  }
}

///|
priv enum Repetition {
  Required
  Optional
  Repeated
}

///|
priv enum Codec {
  Uncompressed
  Snappy
  Gzip
  OtherCodec(Int32)
}

///|
fn codec_of(id : Int32) -> Codec {
  match id {
    0 => Uncompressed
    1 => Snappy
    2 => Gzip
    other => OtherCodec(other)
  }
}

///|
priv enum Encoding {
  Plain
  PlainDictionary
  Rle
  BitPacked
  RleDictionaryByPage
  DeltaBinaryPacked
  DeltaLengthByteArray
  DeltaByteArray
  ByteStreamSplit
  OtherEncoding(Int32)
}

///|
fn encoding_of(id : Int32) -> Encoding {
  match id {
    0 => Plain
    2 => PlainDictionary
    3 => Rle
    4 => BitPacked
    5 => DeltaBinaryPacked
    6 => DeltaLengthByteArray
    7 => DeltaByteArray
    8 => RleDictionaryByPage
    9 => ByteStreamSplit
    other => OtherEncoding(other)
  }
}

///|
/// One node of the flattened schema tree. Only leaf nodes carry a physical
/// type; the root has no repetition.
priv struct SchemaElement {
  name : String
  physical : PhysicalType?
  repetition : Repetition?
  num_children : Int32
  is_timestamp : Bool
}

///|
priv struct ColumnMeta {
  encodings : Array[Encoding]
  codec : Codec
  num_values : Int64
  total_compressed_size : Int64
  data_page_offset : Int64
  dictionary_page_offset : Int64?
  null_count : Int64?
}

///|
priv struct RowGroupMeta {
  columns : Array[ColumnMeta]
  num_rows : Int64
}

///|
priv struct FileMeta {
  version : Int32
  schema : Array[SchemaElement]
  num_rows : Int64
  row_groups : Array[RowGroupMeta]
}

///|
/// Parse the footer of a Parquet file: the structures after the column data,
/// addressed by the little-endian footer length in the last 8 bytes.
fn parse_footer(data : Bytes) -> FileMeta raise @types.SqlError {
  let len = data.length()
  if len < 12 {
    raise parquet_error("file is \{len} bytes, too short to be Parquet")
  }
  if !(data[len - 4] == b'P' &&
    data[len - 3] == b'A' &&
    data[len - 2] == b'R' &&
    data[len - 1] == b'1') {
    raise parquet_error("missing PAR1 magic at the end of the file")
  }
  let mut footer_len : Int32 = 0
  for i in 0..<4 {
    footer_len = footer_len | (data[len - 8 + i].to_int() << (8 * i))
  }
  if footer_len + 8 > len - 4 {
    raise parquet_error(
      "footer length \{footer_len} does not fit in a \{len} byte file",
    )
  }
  let tr = Tr::new(data[:])
  tr.pos = len - 8 - footer_len
  parse_file_metadata(tr)
}

///|
fn parse_file_metadata(tr : Tr) -> FileMeta raise @types.SqlError {
  let mut version = 0
  let schema : Array[SchemaElement] = []
  let row_groups : Array[RowGroupMeta] = []
  let mut num_rows : Int64 = 0L
  let mut last : Int32 = 0
  while true {
    let (id, t) = tr.field_header(last)
    last = id
    if t is Stop {
      break
    }
    match id {
      1 => if t is I32T { version = tr.zigzag_i32() } else { tr.skip(t) }
      2 =>
        if t is ListT {
          let (et, n) = tr.list_header()
          for _ in 0..<n {
            if et is StructT {
              schema.push(parse_schema_element(tr))
            } else {
              tr.skip(et)
            }
          }
        } else {
          tr.skip(t)
        }
      3 => if t is I64T { num_rows = tr.zigzag_i64() } else { tr.skip(t) }
      4 =>
        if t is ListT {
          let (et, n) = tr.list_header()
          for _ in 0..<n {
            if et is StructT {
              row_groups.push(parse_row_group(tr))
            } else {
              tr.skip(et)
            }
          }
        } else {
          tr.skip(t)
        }
      _ => tr.skip(t)
    }
  }
  { version, schema, num_rows, row_groups, }
}

///|
fn parse_schema_element(tr : Tr) -> SchemaElement raise @types.SqlError {
  let mut physical : PhysicalType? = None
  let mut repetition : Repetition? = None
  let mut name = ""
  let mut num_children = 0
  let mut is_timestamp = false
  let mut last : Int32 = 0
  while true {
    let (id, t) = tr.field_header(last)
    last = id
    if t is Stop {
      break
    }
    match id {
      1 =>
        if t is I32T {
          physical = Some(physical_type_of(tr.zigzag_i32()))
        } else {
          tr.skip(t)
        }
      3 =>
        if t is I32T {
          repetition = Some(
            match tr.zigzag_i32() {
              0 => Required
              1 => Optional
              _ => Repeated
            },
          )
        } else {
          tr.skip(t)
        }
      4 => if t is BinaryT { name = tr.string() } else { tr.skip(t) }
      5 => if t is I32T { num_children = tr.zigzag_i32() } else { tr.skip(t) }
      6 => tr.skip(t)
      10 =>
        if t is StructT {
          // only TIMESTAMP is acted on (it is refused at registration);
          // everything else keeps the pre-existing behaviour of treating
          // the physical type as the whole story
          is_timestamp = is_timestamp || parse_logical_type_is_timestamp(tr)
        } else {
          tr.skip(t)
        }
      _ => tr.skip(t)
    }
  }
  { name, physical, repetition, num_children, is_timestamp, }
}

///|
/// LogicalType is a Thrift union: the set field says which logical type
/// applies. TIMESTAMP is the one that matters here, because decoding it as a
/// plain INT64 would hand the engine epoch numbers that look like data.
fn parse_logical_type_is_timestamp(tr : Tr) -> Bool raise @types.SqlError {
  let mut timestamp = false
  let mut last : Int32 = 0
  while true {
    let (id, t) = tr.field_header(last)
    last = id
    if t is Stop {
      break
    }
    match id {
      8 => {
        timestamp = true
        tr.skip(t)
      }
      _ => tr.skip(t)
    }
  }
  timestamp
}

///|
fn parse_row_group(tr : Tr) -> RowGroupMeta raise @types.SqlError {
  let columns : Array[ColumnMeta] = []
  let mut num_rows : Int64 = 0L
  let mut last : Int32 = 0
  while true {
    let (id, t) = tr.field_header(last)
    last = id
    if t is Stop {
      break
    }
    match id {
      1 =>
        if t is ListT {
          let (et, n) = tr.list_header()
          for _ in 0..<n {
            if et is StructT {
              match parse_column_chunk(tr) {
                Some(c) => columns.push(c)
                None => ()
              }
            } else {
              tr.skip(et)
            }
          }
        } else {
          tr.skip(t)
        }
      3 => if t is I64T { num_rows = tr.zigzag_i64() } else { tr.skip(t) }
      _ => tr.skip(t)
    }
  }
  { columns, num_rows, }
}

///|
fn parse_column_chunk(tr : Tr) -> ColumnMeta? raise @types.SqlError {
  let mut meta : ColumnMeta? = None
  let mut last : Int32 = 0
  while true {
    let (id, t) = tr.field_header(last)
    last = id
    if t is Stop {
      break
    }
    match id {
      3 =>
        if t is StructT {
          meta = Some(parse_column_metadata(tr))
        } else {
          tr.skip(t)
        }
      _ => tr.skip(t)
    }
  }
  meta
}

///|
fn parse_column_metadata(tr : Tr) -> ColumnMeta raise @types.SqlError {
  let encodings : Array[Encoding] = []
  let mut codec = Uncompressed
  let mut num_values : Int64 = 0L
  let mut total_compressed_size : Int64 = 0L
  let mut data_page_offset : Int64 = 0L
  let mut dictionary_page_offset : Int64? = None
  let mut null_count : Int64? = None
  let mut last : Int32 = 0
  while true {
    let (id, t) = tr.field_header(last)
    last = id
    if t is Stop {
      break
    }
    match id {
      2 =>
        if t is ListT {
          let (et, n) = tr.list_header()
          for _ in 0..<n {
            if et is I32T {
              encodings.push(encoding_of(tr.zigzag_i32()))
            } else {
              tr.skip(et)
            }
          }
        } else {
          tr.skip(t)
        }
      4 =>
        if t is I32T {
          codec = codec_of(tr.zigzag_i32())
        } else {
          tr.skip(t)
        }
      5 => if t is I64T { num_values = tr.zigzag_i64() } else { tr.skip(t) }
      7 =>
        if t is I64T {
          total_compressed_size = tr.zigzag_i64()
        } else {
          tr.skip(t)
        }
      9 =>
        if t is I64T {
          data_page_offset = tr.zigzag_i64()
        } else {
          tr.skip(t)
        }
      11 =>
        if t is I64T {
          dictionary_page_offset = Some(tr.zigzag_i64())
        } else {
          tr.skip(t)
        }
      12 =>
        if t is StructT {
          null_count = parse_statistics(tr)
        } else {
          tr.skip(t)
        }
      _ => tr.skip(t)
    }
  }
  {
    encodings,
    codec,
    num_values,
    total_compressed_size,
    data_page_offset,
    dictionary_page_offset,
    null_count,
  }
}

///|
fn parse_statistics(tr : Tr) -> Int64? raise @types.SqlError {
  let mut null_count : Int64? = None
  let mut last : Int32 = 0
  while true {
    let (id, t) = tr.field_header(last)
    last = id
    if t is Stop {
      break
    }
    match id {
      3 =>
        if t is I64T {
          null_count = Some(tr.zigzag_i64())
        } else {
          tr.skip(t)
        }
      _ => tr.skip(t)
    }
  }
  null_count
}

///|
/// Explicit declarations for the derived impls: on pub types the promotion to
/// regular methods is deprecated and trips the CI --deny-warn gate.
