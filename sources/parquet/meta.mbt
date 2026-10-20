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
  converted : Int32? // ConvertedType (deprecated but still written by every writer)
  logical : Int32? // LogicalType union field id
  int_bit_width : Int32 // INTEGER annotation, when present
  int_signed : Bool
}

///|
/// ConvertedType ids this reader acts on: the ones that change what the
/// physical bytes mean.
const CONVERTED_UTF8 : Int32 = 0

///|
const CONVERTED_DECIMAL : Int32 = 5

///|
const CONVERTED_DATE : Int32 = 6

///|
const CONVERTED_UINT_32 : Int32 = 13

///|
const CONVERTED_UINT_64 : Int32 = 14

///|
/// LogicalType union field ids, same purpose.
const LOGICAL_STRING : Int32 = 1

///|
const LOGICAL_DECIMAL : Int32 = 5

///|
const LOGICAL_DATE : Int32 = 6

///|
const LOGICAL_TIMESTAMP : Int32 = 8

///|
const LOGICAL_INTEGER : Int32 = 9

///|
/// What a LogicalType union carried: which arm, plus the INTEGER details
/// when that is the arm.
priv struct LogicalInfo {
  id : Int32?
  bit_width : Int32
  signed : Bool
}

///|
priv struct ColumnMeta {
  encodings : Array[Encoding]
  codec : Codec
  num_values : Int64
  total_compressed_size : Int64
  data_page_offset : Int64
  dictionary_page_offset : Int64?
  stats : Statistics?
}

///|
/// Column-chunk statistics. `min_value`/`max_value` are the current fields;
/// the deprecated `min`/`max` pair is kept as a fallback for writers that
/// predate them (it is only usable for numeric physical types — for
/// BYTE_ARRAY the deprecated pair uses signed byte order).
priv struct Statistics {
  null_count : Int64?
  min_value : Bytes?
  max_value : Bytes?
  min_deprecated : Bytes?
  max_deprecated : Bytes?
  is_min_exact : Bool?
  is_max_exact : Bool?
}

///|
fn ColumnMeta::null_count(self : ColumnMeta) -> Int64? {
  match self.stats {
    Some(s) => s.null_count
    None => None
  }
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
  let mut converted : Int32? = None
  let mut logical : Int32? = None
  let mut int_bit_width = 0
  let mut int_signed = true
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
      6 =>
        if t is I32T {
          converted = Some(tr.zigzag_i32())
        } else {
          tr.skip(t)
        }
      10 =>
        if t is StructT {
          let info = parse_logical_type(tr)
          logical = info.id
          int_bit_width = info.bit_width
          int_signed = info.signed
          if info.id is Some(LOGICAL_TIMESTAMP) {
            is_timestamp = true
          }
        } else {
          tr.skip(t)
        }
      _ => tr.skip(t)
    }
  }
  {
    name,
    physical,
    repetition,
    num_children,
    is_timestamp,
    converted,
    logical,
    int_bit_width,
    int_signed,
  }
}

///|
/// LogicalType is a Thrift union: the arm that is set says which logical type
/// applies. The ones that matter here are the arms that change what the
/// physical bytes mean — a TIMESTAMP decoded as a plain INT64 hands the engine
/// epoch numbers that look like data, a UINT_32 read as INT32 turns large
/// values negative, a DECIMAL byte array is not text at all.
fn parse_logical_type(tr : Tr) -> LogicalInfo raise @types.SqlError {
  let mut id : Int32? = None
  let mut bit_width = 0
  let mut signed = true
  let mut last : Int32 = 0
  while true {
    let (field, t) = tr.field_header(last)
    last = field
    if t is Stop {
      break
    }
    id = Some(field)
    if field == LOGICAL_INTEGER && t is StructT {
      let mut inner_last : Int32 = 0
      while true {
        let (fid, ft) = tr.field_header(inner_last)
        inner_last = fid
        if ft is Stop {
          break
        }
        match fid {
          // IntType.bitWidth is a thrift BYTE (signed, one raw byte)
          1 => if ft is ByteType { bit_width = tr.u8() } else { tr.skip(ft) }
          2 =>
            match ft {
              BoolTrue => signed = true
              BoolFalse => signed = false
              _ => tr.skip(ft)
            }
          _ => tr.skip(ft)
        }
      }
    } else {
      tr.skip(t)
    }
  }
  { id, bit_width, signed, }
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
  let mut stats : Statistics? = None
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
          stats = Some(parse_statistics(tr))
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
    stats,
  }
}

///|
fn parse_statistics(tr : Tr) -> Statistics raise @types.SqlError {
  let mut null_count : Int64? = None
  let mut min_value : Bytes? = None
  let mut max_value : Bytes? = None
  let mut min_deprecated : Bytes? = None
  let mut max_deprecated : Bytes? = None
  let mut is_min_exact : Bool? = None
  let mut is_max_exact : Bool? = None
  let mut last : Int32 = 0
  while true {
    let (id, t) = tr.field_header(last)
    last = id
    if t is Stop {
      break
    }
    match id {
      1 =>
        if t is BinaryT {
          max_deprecated = Some(tr.binary().to_owned())
        } else {
          tr.skip(t)
        }
      2 =>
        if t is BinaryT {
          min_deprecated = Some(tr.binary().to_owned())
        } else {
          tr.skip(t)
        }
      3 =>
        if t is I64T {
          null_count = Some(tr.zigzag_i64())
        } else {
          tr.skip(t)
        }
      5 =>
        if t is BinaryT {
          max_value = Some(tr.binary().to_owned())
        } else {
          tr.skip(t)
        }
      6 =>
        if t is BinaryT {
          min_value = Some(tr.binary().to_owned())
        } else {
          tr.skip(t)
        }
      7 =>
        match t {
          BoolTrue => is_max_exact = Some(true)
          BoolFalse => is_max_exact = Some(false)
          _ => tr.skip(t)
        }
      8 =>
        match t {
          BoolTrue => is_min_exact = Some(true)
          BoolFalse => is_min_exact = Some(false)
          _ => tr.skip(t)
        }
      _ => tr.skip(t)
    }
  }
  {
    null_count,
    min_value,
    max_value,
    min_deprecated,
    max_deprecated,
    is_min_exact,
    is_max_exact,
  }
}

///|
/// Explicit declarations for the derived impls: on pub types the promotion to
/// regular methods is deprecated and trips the CI --deny-warn gate.
