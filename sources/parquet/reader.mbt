// Column assembly: decode one column chunk of one row group at a time, so a
// scan can leave unused columns and pruned row groups untouched.

///|
fn leaf_elements(
  meta : FileMeta,
) -> Array[(SchemaElement, Int32)] raise @types.SqlError {
  let leaves : Array[(SchemaElement, Int32)] = []
  for i, el in meta.schema {
    if i == 0 {
      continue
    }
    if el.is_timestamp {
      raise unsupported(
        "column \"\{el.name}\": TIMESTAMP is not supported (it would decode as raw epoch integers; DATE columns are declared with --date-col)",
      )
    }
    if el.num_children > 0 {
      raise unsupported(
        "column \"\{el.name}\": nested schemas are not supported (group node with \{el.num_children} children)",
      )
    }
    match el.physical {
      None =>
        raise unsupported(
          "column \"\{el.name}\": schema element without a physical type",
        )
      Some(_) =>
        match el.repetition {
          Some(Repeated) =>
            raise unsupported(
              "column \"\{el.name}\": repeated fields are not supported",
            )
          Some(Optional) => leaves.push((el, 1))
          Some(Required) => leaves.push((el, 0))
          None =>
            raise unsupported(
              "column \"\{el.name}\": schema element without a repetition type",
            )
        }
    }
  }
  leaves
}

///|
fn encoding_name(e : Encoding) -> String {
  match e {
    Plain => "PLAIN"
    PlainDictionary => "PLAIN_DICTIONARY"
    Rle => "RLE"
    BitPacked => "BIT_PACKED"
    RleDictionaryByPage => "RLE_DICTIONARY"
    DeltaBinaryPacked => "DELTA_BINARY_PACKED"
    DeltaLengthByteArray => "DELTA_LENGTH_BYTE_ARRAY"
    DeltaByteArray => "DELTA_BYTE_ARRAY"
    ByteStreamSplit => "BYTE_STREAM_SPLIT"
    OtherEncoding(id) => "encoding \{id}"
  }
}

///|
fn chunk_range(cm : ColumnMeta) -> (Int32, Int32) raise @types.SqlError {
  // a dictionary_page_offset of 0 is the deprecated "not set" spelling some
  // writers emit (the file starts with PAR1, so no page can live at 0)
  let start = match cm.dictionary_page_offset {
    Some(0L) => cm.data_page_offset
    Some(o) => o
    None => cm.data_page_offset
  }
  if start < 0L {
    raise unsupported("negative page offset")
  }
  let start = start.to_int()
  let size = cm.total_compressed_size.to_int()
  if size < 0 || start + size < start {
    raise unsupported("column chunk size \{size} at \{start} overflows")
  }
  (start, start + size)
}

///|
fn check_codec(cm : ColumnMeta, name : String) -> Unit raise @types.SqlError {
  match cm.codec {
    Uncompressed | Snappy => ()
    Gzip =>
      raise unsupported(
        "column \"\{name}\": GZIP compression is not supported (UNCOMPRESSED and SNAPPY are)",
      )
    OtherCodec(id) =>
      raise unsupported(
        "column \"\{name}\": compression codec \{id} is not supported (UNCOMPRESSED and SNAPPY are)",
      )
  }
  // the chunk lists the encodings its pages use: if none of the supported
  // ones is there, refuse before decoding a page (and say which ones it wants)
  if cm.encodings.length() > 0 {
    let mut supported = false
    for e in cm.encodings {
      match e {
        Plain
        | PlainDictionary
        | Rle
        | RleDictionaryByPage
        | DeltaBinaryPacked
        | DeltaLengthByteArray
        | DeltaByteArray
        | ByteStreamSplit => supported = true
        _ => ()
      }
    }
    if !supported {
      let names : Array[String] = []
      for e in cm.encodings {
        names.push(encoding_name(e))
      }
      let listed = names.join(", ")
      raise unsupported(
        "column \"\{name}\": declares encodings \{listed} and none of them is PLAIN or a dictionary encoding",
      )
    }
  }
}

///|
fn decompress(
  cm : ColumnMeta,
  name : String,
  payload : BytesView,
  uncompressed : Int32,
) -> BytesView raise @types.SqlError {
  match cm.codec {
    Uncompressed => payload
    Snappy => snappy_decompress(payload, uncompressed)[:]
    _ => raise unsupported("column \"\{name}\": unsupported compression")
  }
}

///|
/// Translate a colenc decoding error into the scan error the reader reports.
fn colenc_scan_error(e : @colenc_types.EncodingError) -> @types.SqlError {
  @types.SqlError::Scan(
    "parquet: colenc: \{@colenc_types.EncodingError::message(e)}",
  )
}

///|
fn extended_bool(
  payload : BytesView,
  n : Int32,
  enc : Encoding,
) -> Array[Bool] raise @types.SqlError {
  match enc {
    Rle =>
      @colenc_encoders.decode_bool_rle(payload, n) catch {
        e => raise colenc_scan_error(e)
      }
    _ =>
      raise unsupported(
        "encoding \{encoding_name(enc)} does not apply to BOOLEAN",
      )
  }
}

///|
fn extended_i32(
  payload : BytesView,
  n : Int32,
  enc : Encoding,
) -> Array[Int32] raise @types.SqlError {
  match enc {
    DeltaBinaryPacked =>
      @colenc_encoders.decode_delta_int32(payload, n).0 catch {
        e => raise colenc_scan_error(e)
      }
    _ =>
      raise unsupported(
        "encoding \{encoding_name(enc)} does not apply to INT32",
      )
  }
}

///|
fn extended_i64(
  payload : BytesView,
  n : Int32,
  enc : Encoding,
) -> Array[Int64] raise @types.SqlError {
  match enc {
    DeltaBinaryPacked =>
      @colenc_encoders.decode_delta_int64(payload, n).0 catch {
        e => raise colenc_scan_error(e)
      }
    _ =>
      raise unsupported(
        "encoding \{encoding_name(enc)} does not apply to INT64",
      )
  }
}

///|
fn extended_f32(
  payload : BytesView,
  n : Int32,
  enc : Encoding,
) -> Array[Float] raise @types.SqlError {
  match enc {
    ByteStreamSplit =>
      @colenc_encoders.decode_byte_stream_split_float(payload, n) catch {
        e => raise colenc_scan_error(e)
      }
    _ =>
      raise unsupported(
        "encoding \{encoding_name(enc)} does not apply to FLOAT",
      )
  }
}

///|
fn extended_f64(
  payload : BytesView,
  n : Int32,
  enc : Encoding,
) -> Array[Double] raise @types.SqlError {
  match enc {
    ByteStreamSplit =>
      @colenc_encoders.decode_byte_stream_split_double(payload, n) catch {
        e => raise colenc_scan_error(e)
      }
    _ =>
      raise unsupported(
        "encoding \{encoding_name(enc)} does not apply to DOUBLE",
      )
  }
}

///|
fn extended_strings(
  payload : BytesView,
  n : Int32,
  enc : Encoding,
) -> Array[String] raise @types.SqlError {
  let raw = match enc {
    DeltaLengthByteArray =>
      @colenc_encoders.decode_delta_length_byte_array(payload, n).0 catch {
        e => raise colenc_scan_error(e)
      }
    DeltaByteArray =>
      @colenc_encoders.decode_delta_byte_array(payload, n).0 catch {
        e => raise colenc_scan_error(e)
      }
    _ =>
      raise unsupported(
        "encoding \{encoding_name(enc)} does not apply to BYTE_ARRAY",
      )
  }
  raw.map(fn(value) { @utf8.decode_lossy(value[:]) })
}

///|
/// Decode one column chunk into a value array. The page walk is shared: each
/// physical type supplies the two closures that turn page bytes into values
/// (dictionary page and data page), and the walk owns the level decoding.
fn[T] decode_values(
  payload : BytesView,
  n : Int32,
  enc : Encoding,
  dict : Array[T],
  values : Array[T],
  name : String,
  plain : (BytesView, Int32) -> Array[T] raise @types.SqlError,
  extended : (BytesView, Int32, Encoding) -> Array[T] raise @types.SqlError,
  dict_seen : Bool,
) -> Unit raise @types.SqlError {
  match enc {
    Plain =>
      for v in plain(payload, n) {
        values.push(v)
      }
    PlainDictionary | RleDictionaryByPage => {
      if !dict_seen {
        raise unsupported(
          "column \"\{name}\": dictionary-encoded page before any dictionary page",
        )
      }
      if dict.length() == 0 {
        raise unsupported(
          "column \"\{name}\": the dictionary page holds no entries",
        )
      }
      for idx in read_dict_indices(payload, n, dict.length()) {
        values.push(dict[idx])
      }
    }
    Rle
    | DeltaBinaryPacked
    | DeltaLengthByteArray
    | DeltaByteArray
    | ByteStreamSplit =>
      for v in extended(payload, n, enc) {
        values.push(v)
      }
    BitPacked | OtherEncoding(_) =>
      raise unsupported(
        "column \"{name}\": encoding \{encoding_name(enc)} is not supported",
      )
  }
}

///|
fn decode_chunk(
  data : Bytes,
  cm : ColumnMeta,
  max_def : Int32,
  el : SchemaElement,
) -> ColumnValues raise @types.SqlError {
  let name = el.name
  check_codec(cm, name)
  let (start, end) = chunk_range(cm)
  let valid : Array[Bool] = []
  match el.physical {
    Some(BooleanT) => {
      let values : Array[Bool] = []
      let dict : Array[Bool] = []
      walk_chunk(
        data,
        start,
        end,
        cm,
        name,
        max_def,
        valid,
        (payload, n) => {
          for v in plain_booleans(payload, n) {
            dict.push(v)
          }
        },
        (payload, n, enc, dict_seen) => {
          decode_values(
            payload, n, enc, dict, values, name, plain_booleans, extended_bool, dict_seen,
          )
        },
      )
      Bools(values, valid)
    }
    Some(Int32T) => {
      let values : Array[Int32] = []
      let dict : Array[Int32] = []
      walk_chunk(
        data,
        start,
        end,
        cm,
        name,
        max_def,
        valid,
        (payload, n) => {
          for v in plain_i32(payload, n) {
            dict.push(v)
          }
        },
        (payload, n, enc, dict_seen) => {
          decode_values(
            payload, n, enc, dict, values, name, plain_i32, extended_i32, dict_seen,
          )
        },
      )
      Int32s(values, valid)
    }
    Some(Int64T) => {
      let values : Array[Int64] = []
      let dict : Array[Int64] = []
      walk_chunk(
        data,
        start,
        end,
        cm,
        name,
        max_def,
        valid,
        (payload, n) => {
          for v in plain_i64(payload, n) {
            dict.push(v)
          }
        },
        (payload, n, enc, dict_seen) => {
          decode_values(
            payload, n, enc, dict, values, name, plain_i64, extended_i64, dict_seen,
          )
        },
      )
      Int64s(values, valid)
    }
    Some(FloatT) => {
      let values : Array[Float] = []
      let dict : Array[Float] = []
      walk_chunk(
        data,
        start,
        end,
        cm,
        name,
        max_def,
        valid,
        (payload, n) => {
          for v in plain_f32(payload, n) {
            dict.push(v)
          }
        },
        (payload, n, enc, dict_seen) => {
          decode_values(
            payload, n, enc, dict, values, name, plain_f32, extended_f32, dict_seen,
          )
        },
      )
      Floats(values, valid)
    }
    Some(DoubleT) => {
      let values : Array[Double] = []
      let dict : Array[Double] = []
      walk_chunk(
        data,
        start,
        end,
        cm,
        name,
        max_def,
        valid,
        (payload, n) => {
          for v in plain_f64(payload, n) {
            dict.push(v)
          }
        },
        (payload, n, enc, dict_seen) => {
          decode_values(
            payload, n, enc, dict, values, name, plain_f64, extended_f64, dict_seen,
          )
        },
      )
      Doubles(values, valid)
    }
    Some(ByteArrayT) => {
      let values : Array[String] = []
      let dict : Array[String] = []
      walk_chunk(
        data,
        start,
        end,
        cm,
        name,
        max_def,
        valid,
        (payload, n) => {
          for v in plain_strings(payload, n) {
            dict.push(v)
          }
        },
        (payload, n, enc, dict_seen) => {
          decode_values(
            payload, n, enc, dict, values, name, plain_strings, extended_strings,
            dict_seen,
          )
        },
      )
      Strings(values, valid)
    }
    Some(Int96T) =>
      raise unsupported(
        "column \"\{name}\": INT96 timestamps are not supported",
      )
    Some(FixedLenByteArrayT) =>
      raise unsupported(
        "column \"\{name}\": FIXED_LEN_BYTE_ARRAY is not supported",
      )
    Some(UnknownPhysical(id)) =>
      raise unsupported("column \"\{name}\": unknown physical type \{id}")
    None => raise unsupported("column \"\{name}\": missing physical type")
  }
}

///|
/// Indices of a dictionary-encoded data page: one byte of bit width, then
/// the RLE/bit-packed hybrid stream, one index per non-null value.
fn read_dict_indices(
  payload : BytesView,
  n : Int32,
  dict_size : Int32,
) -> Array[Int32] raise @types.SqlError {
  if payload.length() == 0 {
    raise unsupported("dictionary-encoded page carries no index data")
  }
  let width = payload[0].to_int()
  if width == 0 {
    // a single-entry dictionary: every index is 0
    return Array::make(n, 0)
  }
  if width > 32 {
    raise unsupported("dictionary index bit width \{width} is out of range")
  }
  let hybrid = hybrid_new(
    payload.exact_view(start=1, end=payload.length()),
    width,
  )
  let out : Array[Int32] = []
  for _ in 0..<n {
    let idx = hybrid.next()
    if idx < 0 || idx >= dict_size {
      raise unsupported(
        "dictionary index \{idx} is outside the \{dict_size} entry dictionary",
      )
    }
    out.push(idx)
  }
  out
}

///|
/// Walk the pages of a column chunk in order, decoding definition levels
/// into `valid` and handing value bytes to the caller's decoders.
///
/// `on_dictionary` receives the dictionary page payload, `on_values` the
/// value section of each data page together with the number of non-null
/// values it holds.
fn walk_chunk(
  data : Bytes,
  start : Int32,
  end : Int32,
  cm : ColumnMeta,
  name : String,
  max_def : Int32,
  valid : Array[Bool],
  on_dictionary : (BytesView, Int32) -> Unit raise @types.SqlError,
  on_values : (BytesView, Int32, Encoding, Bool) -> Unit raise @types.SqlError,
) -> Unit raise @types.SqlError {
  let mut pos = start
  let mut values_seen : Int64 = 0L
  let mut pages = 0
  let mut dict_seen = false
  while pos < end {
    let tr = Tr::new(data)
    tr.pos = pos
    let header = parse_page_header(tr) catch {
      e =>
        raise unsupported(
          "column \"\{name}\": page header at offset \{pos} is unreadable (\{e})",
        )
    }
    let header_len = tr.pos - pos
    let payload_len = header.compressed_size
    if payload_len < 0 || pos + header_len + payload_len > data.length() {
      raise unsupported(
        "page at offset \{pos} claims \{payload_len} payload bytes, past the end of the file",
      )
    }
    let raw = data.exact_view(
      start=pos + header_len,
      end=pos + header_len + payload_len,
    )
    pos += header_len + payload_len
    pages += 1
    if pages > 1000000 {
      raise unsupported("too many pages in one column chunk")
    }
    match header.page_type {
      2 => {
        // dictionary page
        let payload = decompress(cm, "", raw, header.uncompressed_size)
        dict_seen = true
        on_dictionary(payload, header.dict_num_values)
      }
      0 => {
        if header.def_encoding is Plain ||
          header.def_encoding is OtherEncoding(_) {
          raise unsupported(
            "column \"\{name}\": definition levels use encoding \{encoding_name(header.def_encoding)}: only RLE is supported",
          )
        }
        let payload = decompress(cm, "", raw, header.uncompressed_size)
        let ptr = Tr::new(payload)
        let levels = read_def_levels_v1(ptr, max_def, header.num_values)
        let values_view = payload.exact_view(
          start=ptr.pos,
          end=payload.length(),
        )
        let mut non_null = 0
        for v in levels {
          if v {
            non_null += 1
          }
        }
        for v in levels {
          valid.push(v)
        }
        on_values(values_view, non_null, header.encoding, dict_seen)
        values_seen += header.num_values.to_int64()
      }
      3 =>
        raise unsupported("column \"\{name}\": data page v2 is not supported")
      _ => () // index page: nothing to decode
    }
  }
  match cm.null_count() {
    Some(n) =>
      if n >= 0L {
        let mut valid_count = 0
        for v in valid {
          if v {
            valid_count += 1
          }
        }
        if valid_count.to_int64() != cm.num_values - n {
          raise unsupported(
            "column \"\{name}\": decoded \{valid_count} non-null values, the column metadata says \{cm.num_values - n}",
          )
        }
      }
    None => ()
  }
  if values_seen != cm.num_values {
    raise unsupported(
      "column chunk has \{values_seen} values, metadata says \{cm.num_values}",
    )
  }
}
