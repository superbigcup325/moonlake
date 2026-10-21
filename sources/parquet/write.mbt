// Parquet writing: one data page per column per row group, PLAIN encoding
// produced by colenc, UNCOMPRESSED.
//
// This is the write half the reader never had. It deliberately covers what the
// reader's scope covers: flat columns, v1 data pages, PLAIN, one row group per
// batch.
//
// Every column is written OPTIONAL, with an RLE definition-level section per
// page (4-byte length prefix, 1-bit hybrid levels) and a dense value section.
// That is a deliberate trade, not a default: the schema lives in the footer but
// a page's definition levels have to match the schema it is stored under, so a
// writer that wanted REQUIRED columns for null-free data would have to see the
// whole table before writing its first page — two passes over the input at best,
// the whole table in memory at worst, which is what this writer used to do.
// Optional-always costs about one bit per value on disk and buys a single pass:
// the input streams batch by batch (see `TableEntry::stream`), so peak memory is
// the output buffer plus one batch instead of the whole table plus the archive.
// pyarrow writes optional columns by default for the same reason.

///|
fn write_error(msg : String) -> @types.SqlError {
  @types.SqlError::Scan("parquet write: " + msg)
}

///|
fn colenc_write_error(e : @colenc_types.EncodingError) -> @types.SqlError {
  @types.SqlError::Scan(
    "parquet write: colenc: \{@colenc_types.EncodingError::message(e)}",
  )
}

// -------------------------------------------------------------- thrift writer

///|
const W_I32 : Int32 = 5

///|
const W_I64 : Int32 = 6

///|
const W_BINARY : Int32 = 8

///|
const W_LIST : Int32 = 9

///|
const W_STRUCT : Int32 = 12

///|
const W_TRUE : Int32 = 1

///|
fn w_uvarint(out : Buffer, value : UInt64) -> Unit {
  let mut rest = value
  while rest >= 0x80UL {
    out.write_byte(((rest.to_int() & 0x7F) | 0x80).to_byte())
    rest = rest >> 7
  }
  out.write_byte(rest.to_int().to_byte())
}

///|
fn w_zigzag(out : Buffer, value : Int64) -> Unit {
  w_uvarint(out, ((value << 1) ^ (value >> 63)).reinterpret_as_uint64())
}

///|
fn w_field(out : Buffer, last : Int32, id : Int32, kind : Int32) -> Int32 {
  let delta = id - last
  if delta > 0 && delta <= 15 {
    out.write_byte(((delta << 4) | kind).to_byte())
  } else {
    out.write_byte(kind.to_byte())
    w_zigzag(out, id.to_int64())
  }
  id
}

///|
fn w_list(out : Buffer, size : Int32, element : Int32) -> Unit {
  if size < 15 {
    out.write_byte(((size << 4) | element).to_byte())
  } else {
    out.write_byte((0xF0 | element).to_byte())
    w_uvarint(out, size.to_uint64())
  }
}

///|
fn w_binary(out : Buffer, value : String) -> Unit {
  let raw = @utf8.encode(value)
  w_uvarint(out, raw.length().to_uint64())
  out.write_bytes(raw)
}

///|
/// Length-prefixed raw bytes (statistics bounds are binary, not text).
fn w_raw(out : Buffer, value : Bytes) -> Unit {
  w_uvarint(out, value.length().to_uint64())
  out.write_bytes(value)
}

///|
fn w_stop(out : Buffer) -> Unit {
  out.write_byte(b'\x00')
}

///|
fn w_field_i32(out : Buffer, last : Int32, id : Int32, value : Int32) -> Int32 {
  let next = w_field(out, last, id, W_I32)
  w_zigzag(out, value.to_int64())
  next
}

///|
fn w_field_i64(out : Buffer, last : Int32, id : Int32, value : Int64) -> Int32 {
  let next = w_field(out, last, id, W_I64)
  w_zigzag(out, value)
  next
}

///|
fn w_field_binary(
  out : Buffer,
  last : Int32,
  id : Int32,
  value : String,
) -> Int32 {
  let next = w_field(out, last, id, W_BINARY)
  w_binary(out, value)
  next
}

// ----------------------------------------------------------- parquet metadata

///|
fn w_magic(out : Buffer) -> Unit {
  out.write_byte(b'P')
  out.write_byte(b'A')
  out.write_byte(b'R')
  out.write_byte(b'1')
}

///|
/// The compression a written file uses. UNCOMPRESSED stays the default: a
/// written file is meant to be readable by anything, and Snappy is a choice
/// the caller makes knowing the size/CPU trade-off.
pub(all) enum ParquetCodec {
  Raw // stored as written; the reader's SNAPPY/UNCOMPRESSED both accept it
  Snappy
}

///|
fn w_codec_id(codec : ParquetCodec) -> Int32 {
  match codec {
    Raw => 0
    Snappy => 1
  }
}

///|
/// Parquet physical type for an engine data type. DATE rides on INT32 and
/// carries a DATE annotation (see `w_annotation`).
fn w_type_id(dt : @types.DataType) -> Int32 {
  match dt {
    Int32 | Date => 1
    Int64 => 2
    Float64 => 5
    Str => 6
    Bool => 0
  }
}

///|
fn w_schema_root(children : Int32) -> Bytes {
  let out = Buffer()
  let mut last = 0
  last = w_field_binary(out, last, 4, "schema")
  last = w_field_i32(out, last, 5, children)
  w_stop(out)
  out.to_bytes()
}

///|
/// The annotation a column carries on top of its physical type: text is
/// BYTE_ARRAY + UTF8/STRING, a DATE is INT32 + DATE. Both spellings are
/// written — the spec asks writers to, and consumers disagree on which one
/// they look at (DuckDB and pyarrow accept either, some tools only the
/// deprecated `converted_type`). Without it a written DATE is an INT32 and a
/// written string is an untyped byte array, i.e. a BLOB to DuckDB.
fn w_annotation(dt : @types.DataType) -> (Int32?, Int32?) {
  match dt {
    Str => (Some(CONVERTED_UTF8), Some(LOGICAL_STRING))
    Date => (Some(CONVERTED_DATE), Some(LOGICAL_DATE))
    _ => (None, None)
  }
}

///|
/// A LogicalType union holding one empty arm (`StringType` / `DateType`), as
/// a complete Thrift struct including its STOP byte.
fn w_logical_type(arm : Int32) -> Bytes {
  let out = Buffer()
  let mut last = 0
  last = w_field(out, last, arm, W_STRUCT)
  w_stop(out) // the arm's own empty struct
  w_stop(out) // the LogicalType union
  out.to_bytes()
}

///|
fn w_schema_leaf(name : String, type_id : Int32, dt : @types.DataType) -> Bytes {
  let out = Buffer()
  let mut last = 0
  last = w_field_i32(out, last, 1, type_id)
  last = w_field_i32(out, last, 3, 1) // OPTIONAL: every written column carries levels
  last = w_field_binary(out, last, 4, name)
  let (converted, logical) = w_annotation(dt)
  match converted {
    Some(id) => last = w_field_i32(out, last, 6, id)
    None => ()
  }
  match logical {
    Some(arm) => {
      last = w_field(out, last, 10, W_STRUCT)
      out.write_bytes(w_logical_type(arm))
    }
    None => ()
  }
  w_stop(out)
  out.to_bytes()
}

///|
fn w_data_page_header(num_values : Int32) -> Bytes {
  let out = Buffer()
  let mut last = 0
  last = w_field_i32(out, last, 1, num_values)
  last = w_field_i32(out, last, 2, 0) // PLAIN
  last = w_field_i32(out, last, 3, 3) // RLE
  last = w_field_i32(out, last, 4, 3) // RLE
  w_stop(out)
  out.to_bytes()
}

///|
/// `body_len` is what the reader has to produce, `stored_len` what the file
/// holds (the same number when the page is not compressed).
fn w_page_header(
  body_len : Int32,
  stored_len : Int32,
  num_values : Int32,
) -> Bytes {
  let page = w_data_page_header(num_values)
  let out = Buffer()
  let mut last = 0
  last = w_field_i32(out, last, 1, 0) // DATA_PAGE
  last = w_field_i32(out, last, 2, body_len)
  last = w_field_i32(out, last, 3, stored_len)
  last = w_field(out, last, 5, W_STRUCT)
  out.write_bytes(page)
  w_stop(out)
  out.to_bytes()
}

///|
fn w_column_meta_data(
  path : String,
  type_id : Int32,
  num_values : Int32,
  total_uncompressed : Int32,
  total_compressed : Int32,
  data_page_offset : Int32,
  codec : ParquetCodec,
  stats : ColStats,
) -> Bytes {
  let out = Buffer()
  let mut last = 0
  last = w_field_i32(out, last, 1, type_id)
  last = w_field(out, last, 2, W_LIST)
  // PLAIN values, RLE definition levels: every written column is OPTIONAL
  w_list(out, 2, W_I32)
  w_zigzag(out, 0) // PLAIN
  w_zigzag(out, 3) // RLE
  last = w_field(out, last, 3, W_LIST)
  w_list(out, 1, W_BINARY)
  w_binary(out, path)
  last = w_field_i32(out, last, 4, w_codec_id(codec))
  last = w_field_i64(out, last, 5, num_values.to_int64())
  last = w_field_i64(out, last, 6, total_uncompressed.to_int64())
  last = w_field_i64(out, last, 7, total_compressed.to_int64())
  last = w_field_i64(out, last, 9, data_page_offset.to_int64())
  last = w_field(out, last, 12, W_STRUCT)
  out.write_bytes(w_statistics(stats))
  w_stop(out)
  out.to_bytes()
}

///|
fn w_column_chunk(file_offset : Int32, meta_data : Bytes) -> Bytes {
  let out = Buffer()
  let mut last = 0
  last = w_field_i64(out, last, 2, file_offset.to_int64())
  last = w_field(out, last, 3, W_STRUCT)
  out.write_bytes(meta_data)
  w_stop(out)
  out.to_bytes()
}

///|
fn w_row_group(
  columns : Array[Bytes],
  total_size : Int32,
  num_rows : Int32,
) -> Bytes {
  let out = Buffer()
  let mut last = 0
  last = w_field(out, last, 1, W_LIST)
  w_list(out, columns.length(), W_STRUCT)
  for column in columns {
    out.write_bytes(column)
  }
  last = w_field_i64(out, last, 2, total_size.to_int64())
  last = w_field_i64(out, last, 3, num_rows.to_int64())
  w_stop(out)
  out.to_bytes()
}

///|
fn w_file_meta_data(
  schema : Array[Bytes],
  num_rows : Int64,
  row_groups : Array[Bytes],
) -> Bytes {
  let out = Buffer()
  let mut last = 0
  last = w_field_i32(out, last, 1, 1)
  last = w_field(out, last, 2, W_LIST)
  w_list(out, schema.length(), W_STRUCT)
  for element in schema {
    out.write_bytes(element)
  }
  last = w_field_i64(out, last, 3, num_rows)
  last = w_field(out, last, 4, W_LIST)
  w_list(out, row_groups.length(), W_STRUCT)
  for group in row_groups {
    out.write_bytes(group)
  }
  last = w_field_binary(out, last, 6, "moonlake parquet writer")
  w_stop(out)
  out.to_bytes()
}

// ------------------------------------------------------------- statistics

///|
/// One column chunk's statistics: the NULL count and the PLAIN-encoded
/// bounds. `min`/`max` are None when the column cannot carry a trustworthy
/// bound — a NaN in a float column makes min/max meaningless, and text whose
/// bytes are not ASCII could be ordered differently by a reader that compares
/// decoded strings (this engine) and one that compares bytes (the spec).
/// A column without bounds still gets its NULL count.
priv struct ColStats {
  nulls : Int64
  min : Bytes?
  max : Bytes?
}

///|
fn no_bounds(nulls : Int64) -> ColStats {
  { nulls, min: None, max: None, }
}

///|
fn le_i64(out : Buffer, value : Int64) -> Unit {
  let bits = value.reinterpret_as_uint64()
  for i in 0..<8 {
    out.write_byte(((bits >> (8 * i)).to_int() & 0xFF).to_byte())
  }
}

///|
fn le_double(out : Buffer, value : Double) -> Unit {
  let bits = value.reinterpret_as_uint64()
  for i in 0..<8 {
    out.write_byte(((bits >> (8 * i)).to_int() & 0xFF).to_byte())
  }
}

///|
/// Compare two byte arrays as unsigned bytes (the Parquet order for
/// BYTE_ARRAY statistics).
fn bytes_less(a : Bytes, b : Bytes) -> Bool {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  let mut i = 0
  while i < n {
    let av = a[i].to_int()
    let bv = b[i].to_int()
    if av != bv {
      return av < bv
    }
    i += 1
  }
  a.length() < b.length()
}

///|
/// Compute a column's bounds for one row group. One extra pass over the
/// vectors: the writer is not the hot path, and a bound it cannot prove is
/// worse than no bound at all (the reader trusts exact bounds to skip groups).
fn column_stats(vector : @types.ColumnVector) -> ColStats {
  let n = vector.len()
  match vector.dtype() {
    Int32 | Date => {
      let mut lo : Int32? = None
      let mut hi : Int32? = None
      let mut nulls = 0L
      for i in 0..<n {
        match vector.get(i) {
          Int32(v) | Date(v) => {
            match lo {
              Some(x) => if v < x { lo = Some(v) }
              None => lo = Some(v)
            }
            match hi {
              Some(x) => if v > x { hi = Some(v) }
              None => hi = Some(v)
            }
          }
          Null => nulls += 1L
          _ => ()
        }
      }
      match (lo, hi) {
        (Some(lo), Some(hi)) => {
          let minb = Buffer()
          minb.write_int_le(lo)
          let maxb = Buffer()
          maxb.write_int_le(hi)
          { nulls, min: Some(minb.to_bytes()), max: Some(maxb.to_bytes()), }
        }
        _ => no_bounds(nulls)
      }
    }
    Int64 => {
      let mut lo : Int64? = None
      let mut hi : Int64? = None
      let mut nulls = 0L
      for i in 0..<n {
        match vector.get(i) {
          Int64(v) => {
            match lo {
              Some(x) => if v < x { lo = Some(v) }
              None => lo = Some(v)
            }
            match hi {
              Some(x) => if v > x { hi = Some(v) }
              None => hi = Some(v)
            }
          }
          Null => nulls += 1L
          _ => ()
        }
      }
      match (lo, hi) {
        (Some(lo), Some(hi)) => {
          let minb = Buffer()
          le_i64(minb, lo)
          let maxb = Buffer()
          le_i64(maxb, hi)
          { nulls, min: Some(minb.to_bytes()), max: Some(maxb.to_bytes()), }
        }
        _ => no_bounds(nulls)
      }
    }
    Float64 => {
      let mut lo : Double? = None
      let mut hi : Double? = None
      let mut nulls = 0L
      let mut nan = false
      for i in 0..<n {
        match vector.get(i) {
          Float64(v) =>
            if v.is_nan() {
              nan = true
            } else {
              match lo {
                Some(x) => if v < x { lo = Some(v) }
                None => lo = Some(v)
              }
              match hi {
                Some(x) => if v > x { hi = Some(v) }
                None => hi = Some(v)
              }
            }
          Null => nulls += 1L
          _ => ()
        }
      }
      if nan {
        // the spec leaves NaN ordering undefined: a bound would be a guess
        return no_bounds(nulls)
      }
      match (lo, hi) {
        (Some(lo), Some(hi)) => {
          let minb = Buffer()
          le_double(minb, lo)
          let maxb = Buffer()
          le_double(maxb, hi)
          { nulls, min: Some(minb.to_bytes()), max: Some(maxb.to_bytes()), }
        }
        _ => no_bounds(nulls)
      }
    }
    Str => {
      let mut lo : Bytes? = None
      let mut hi : Bytes? = None
      let mut nulls = 0L
      let mut ascii = true
      for i in 0..<n {
        match vector.get(i) {
          Str(v) => {
            for ch in v {
              if ch > '\u{7F}' {
                ascii = false
              }
            }
            let raw = @utf8.encode(v)
            match lo {
              Some(x) => if bytes_less(raw, x) { lo = Some(raw) }
              None => lo = Some(raw)
            }
            match hi {
              Some(x) => if bytes_less(x, raw) { hi = Some(raw) }
              None => hi = Some(raw)
            }
          }
          Null => nulls += 1L
          _ => ()
        }
      }
      if !ascii {
        return no_bounds(nulls)
      }
      { nulls, min: lo, max: hi, }
    }
    Bool => {
      let mut any_false = false
      let mut any_true = false
      let mut nulls = 0L
      for i in 0..<n {
        match vector.get(i) {
          Boolean(v) => if v { any_true = true } else { any_false = true }
          Null => nulls += 1L
          _ => ()
        }
      }
      if !any_false || !any_true {
        return no_bounds(nulls)
      }
      { nulls, min: Some(b"\x00"), max: Some(b"\x01"), }
    }
  }
}

///|
/// The Thrift `Statistics` struct: null count plus the current-spelling
/// bounds (`min_value`/`max_value`), marked exact. The deprecated
/// `min`/`max` pair is deliberately not written: for BYTE_ARRAY it was
/// defined in signed byte order, which is a trap this reader refuses to trust
/// on the way in, so writing it on the way out would be inconsistent.
fn w_statistics(st : ColStats) -> Bytes {
  let out = Buffer()
  let mut last = 0
  if st.nulls > 0L {
    last = w_field_i64(out, last, 3, st.nulls)
  }
  match st.max {
    Some(b) => {
      last = w_field(out, last, 5, W_BINARY)
      w_raw(out, b)
    }
    None => ()
  }
  match st.min {
    Some(b) => {
      last = w_field(out, last, 6, W_BINARY)
      w_raw(out, b)
    }
    None => ()
  }
  if st.min is Some(_) && st.max is Some(_) {
    last = w_field(out, last, 7, W_TRUE)
    last = w_field(out, last, 8, W_TRUE)
  }
  w_stop(out)
  out.to_bytes()
}

// ----------------------------------------------------------------- page bodies

///|
/// Pull one column out of a vector and PLAIN-encode it through colenc. The body
/// is prefixed with the page's definition-level section: a 4-byte length, then
/// the hybrid RLE stream (bit width 1) over the present/absent flag of every
/// row. Level 1 is present, level 0 is NULL, because every written column is
/// OPTIONAL (see the file header for why).
fn w_column_body(
  vector : @types.ColumnVector,
  name : String,
) -> Bytes raise @types.SqlError {
  let n = vector.len()
  let levels : Array[Int64] = Array::make(n, 0L)
  let column = match vector.dtype() {
    Int32 | Date => {
      let values : Array[Int32] = []
      for i in 0..<n {
        match vector.get(i) {
          Int32(v) | Date(v) => {
            values.push(v)
            levels[i] = 1L
          }
          Null => ()
          _ =>
            raise write_error("column \"\{name}\": value does not match INT32")
        }
      }
      @colenc_types.ColBuf::Int32s(values)
    }
    Int64 => {
      let values : Array[Int64] = []
      for i in 0..<n {
        match vector.get(i) {
          Int64(v) => {
            values.push(v)
            levels[i] = 1L
          }
          Null => ()
          _ =>
            raise write_error("column \"\{name}\": value does not match INT64")
        }
      }
      @colenc_types.ColBuf::Int64s(values)
    }
    Float64 => {
      let values : Array[Double] = []
      for i in 0..<n {
        match vector.get(i) {
          Float64(v) => {
            values.push(v)
            levels[i] = 1L
          }
          Null => ()
          _ =>
            raise write_error(
              "column \"\{name}\": value does not match FLOAT64",
            )
        }
      }
      @colenc_types.ColBuf::Doubles(values)
    }
    Str => {
      let values : Array[Bytes] = []
      for i in 0..<n {
        match vector.get(i) {
          Str(v) => {
            values.push(@utf8.encode(v))
            levels[i] = 1L
          }
          Null => ()
          _ =>
            raise write_error("column \"\{name}\": value does not match STRING")
        }
      }
      @colenc_types.ColBuf::ByteArrays(values)
    }
    Bool => {
      let values : Array[Bool] = []
      for i in 0..<n {
        match vector.get(i) {
          Boolean(v) => {
            values.push(v)
            levels[i] = 1L
          }
          Null => ()
          _ =>
            raise write_error(
              "column \"\{name}\": value does not match BOOLEAN",
            )
        }
      }
      @colenc_types.ColBuf::Bools(values)
    }
  }
  let payload = Buffer()
  let _ = @colenc.encode_column(column, @colenc_types.Plain, payload) catch {
    e => raise colenc_write_error(e)
  }
  let level_bytes = Buffer()
  @colenc_encoders.encode_rle_hybrid(levels, 1, level_bytes) catch {
    e => raise colenc_write_error(e)
  }
  let body = Buffer()
  body.write_int_le(level_bytes.length())
  body.write_bytes(level_bytes.to_bytes())
  body.write_bytes(payload.to_bytes())
  body.to_bytes()
}

///|
/// Write a table entry as Parquet bytes: one row group per non-empty batch,
/// one data page per column. Every column is written OPTIONAL with definition
/// levels per page (see the file header), which lets the input stream instead of
/// being materialized.
pub fn write_bytes(entry : @catalog.TableEntry) -> Bytes raise @types.SqlError {
  write_bytes_with(entry, ParquetCodec::Raw)
}

///|
/// Write a table entry as Parquet bytes with an explicit codec.
pub fn write_bytes_with(
  entry : @catalog.TableEntry,
  codec : ParquetCodec,
) -> Bytes raise @types.SqlError {
  let file = Buffer()
  w_magic(file)
  let groups : Array[Bytes] = []
  let mut total_rows : Int64 = 0L
  let width = entry.schema.columns.length()
  // One pass over the input: a lazy entry (CSV, another Parquet file) decodes
  // batch by batch as this loop asks for it, so the table is never held whole.
  let stream = entry.stream(@catalog.ScanRequest::all(width))
  let mut pulled = stream.next()
  while pulled is Some(batch) {
    let rows = batch.row_count()
    if rows == 0 {
      pulled = stream.next()
      continue
    }
    let columns = batch.columns()
    if columns.length() != width {
      raise write_error(
        "batch carries \{columns.length()} columns, schema has \{width}",
      )
    }
    let chunks : Array[Bytes] = []
    let mut group_size = 0
    for index in 0..<width {
      let name = entry.schema.columns[index].name
      let body = w_column_body(columns[index], name)
      let stored = match codec {
        Raw => body
        Snappy => snappy_compress(body)
      }
      let header = w_page_header(body.length(), stored.length(), rows)
      if file.length() > 2000000000 {
        raise write_error("file would exceed the 2 GiB page offset limit")
      }
      let offset = file.length()
      file.write_bytes(header)
      file.write_bytes(stored)
      // the row group's size is what the reader will hold, the column chunk
      // records both so a reader can size its buffer before decompressing
      group_size += header.length() + body.length()
      let meta = w_column_meta_data(
        name,
        w_type_id(columns[index].dtype()),
        rows,
        body.length(),
        header.length() + stored.length(),
        offset,
        codec,
        column_stats(columns[index]),
      )
      chunks.push(w_column_chunk(offset, meta))
    }
    groups.push(w_row_group(chunks, group_size, rows))
    total_rows += rows.to_int64()
    pulled = stream.next()
  }
  let schema : Array[Bytes] = [w_schema_root(width)]
  for column in entry.schema.columns {
    schema.push(
      w_schema_leaf(column.name, w_type_id(column.dtype), column.dtype),
    )
  }
  let footer = w_file_meta_data(schema, total_rows, groups)
  file.write_bytes(footer)
  file.write_int_le(footer.length())
  w_magic(file)
  file.to_bytes()
}

///|
/// Write a table entry to a file (native target).
pub fn write_file(
  path : String,
  entry : @catalog.TableEntry,
) -> Unit raise @types.SqlError {
  write_file_with(path, entry, ParquetCodec::Raw)
}

///|
/// Write a table entry to a file with an explicit codec (native target).
pub fn write_file_with(
  path : String,
  entry : @catalog.TableEntry,
  codec : ParquetCodec,
) -> Unit raise @types.SqlError {
  let bytes = write_bytes_with(entry, codec)
  @fs.write_bytes_to_file(path, bytes) catch {
    _ => raise write_error("cannot write file at \{path}")
  }
}
