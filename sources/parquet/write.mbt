// Parquet writing: one data page per column per row group, PLAIN encoding
// produced by colenc, UNCOMPRESSED, required columns only.
//
// This is the write half the reader never had. It deliberately covers what the
// reader's scope covers: flat required columns, v1 data pages, PLAIN, one row
// group per batch. Nulls are refused rather than written wrong; definition
// levels are the next step, not a silent approximation.

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
/// Parquet physical type for an engine data type. DATE rides on INT32; the
/// reader lifts it back when the column is registered with --date-col.
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
fn w_schema_leaf(name : String, type_id : Int32) -> Bytes {
  let out = Buffer()
  let mut last = 0
  last = w_field_i32(out, last, 1, type_id)
  last = w_field_i32(out, last, 3, 0) // REQUIRED
  last = w_field_binary(out, last, 4, name)
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
fn w_page_header(body_len : Int32, num_values : Int32) -> Bytes {
  let page = w_data_page_header(num_values)
  let out = Buffer()
  let mut last = 0
  last = w_field_i32(out, last, 1, 0) // DATA_PAGE
  last = w_field_i32(out, last, 2, body_len)
  last = w_field_i32(out, last, 3, body_len)
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
  total_size : Int32,
  data_page_offset : Int32,
) -> Bytes {
  let out = Buffer()
  let mut last = 0
  last = w_field_i32(out, last, 1, type_id)
  last = w_field(out, last, 2, W_LIST)
  w_list(out, 1, W_I32)
  w_zigzag(out, 0) // PLAIN
  last = w_field(out, last, 3, W_LIST)
  w_list(out, 1, W_BINARY)
  w_binary(out, path)
  last = w_field_i32(out, last, 4, 0) // UNCOMPRESSED
  last = w_field_i64(out, last, 5, num_values.to_int64())
  last = w_field_i64(out, last, 6, total_size.to_int64())
  last = w_field_i64(out, last, 7, total_size.to_int64())
  last = w_field_i64(out, last, 9, data_page_offset.to_int64())
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

// ----------------------------------------------------------------- page bodies

///|
/// Pull one column out of a vector and PLAIN-encode it through colenc.
fn w_column_body(
  vector : @types.ColumnVector,
  name : String,
) -> Bytes raise @types.SqlError {
  let n = vector.len()
  let column = match vector.dtype() {
    Int32 | Date => {
      let values = Array::make(n, 0)
      for i in 0..<n {
        match vector.get(i) {
          Int32(v) | Date(v) => values[i] = v
          Null =>
            raise write_error(
              "column \"\{name}\": NULL values are not supported yet",
            )
          _ =>
            raise write_error("column \"\{name}\": value does not match INT32")
        }
      }
      @colenc_types.ColBuf::Int32s(values)
    }
    Int64 => {
      let values = Array::make(n, 0L)
      for i in 0..<n {
        match vector.get(i) {
          Int64(v) => values[i] = v
          Null =>
            raise write_error(
              "column \"\{name}\": NULL values are not supported yet",
            )
          _ =>
            raise write_error("column \"\{name}\": value does not match INT64")
        }
      }
      @colenc_types.ColBuf::Int64s(values)
    }
    Float64 => {
      let values = Array::make(n, 0.0)
      for i in 0..<n {
        match vector.get(i) {
          Float64(v) => values[i] = v
          Null =>
            raise write_error(
              "column \"\{name}\": NULL values are not supported yet",
            )
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
          Str(v) => values.push(@utf8.encode(v))
          Null =>
            raise write_error(
              "column \"\{name}\": NULL values are not supported yet",
            )
          _ =>
            raise write_error("column \"\{name}\": value does not match STRING")
        }
      }
      @colenc_types.ColBuf::ByteArrays(values)
    }
    Bool => {
      let values = Array::make(n, false)
      for i in 0..<n {
        match vector.get(i) {
          Boolean(v) => values[i] = v
          Null =>
            raise write_error(
              "column \"\{name}\": NULL values are not supported yet",
            )
          _ =>
            raise write_error(
              "column \"\{name}\": value does not match BOOLEAN",
            )
        }
      }
      @colenc_types.ColBuf::Bools(values)
    }
  }
  let out = Buffer()
  let _ = @colenc.encode_column(column, @colenc_types.Plain, out) catch {
    e => raise colenc_write_error(e)
  }
  out.to_bytes()
}

///|
/// Write a table entry as Parquet bytes: one row group per non-empty batch,
/// one data page per column. Every column must be REQUIRED (no NULLs).
pub fn write_bytes(entry : @catalog.TableEntry) -> Bytes raise @types.SqlError {
  let file = Buffer()
  w_magic(file)
  let groups : Array[Bytes] = []
  let mut total_rows : Int64 = 0L
  for batch in entry.batches {
    let rows = batch.row_count()
    if rows == 0 {
      continue
    }
    let columns = batch.columns()
    if columns.length() != entry.schema.columns.length() {
      raise write_error(
        "batch carries \{columns.length()} columns, schema has \{entry.schema.columns.length()}",
      )
    }
    let chunks : Array[Bytes] = []
    let mut group_size = 0
    for index in 0..<columns.length() {
      let name = entry.schema.columns[index].name
      let body = w_column_body(columns[index], name)
      let header = w_page_header(body.length(), rows)
      if file.length() > 2000000000 {
        raise write_error("file would exceed the 2 GiB page offset limit")
      }
      let offset = file.length()
      file.write_bytes(header)
      file.write_bytes(body)
      let size = header.length() + body.length()
      group_size += size
      let meta = w_column_meta_data(
        name,
        w_type_id(columns[index].dtype()),
        rows,
        size,
        offset,
      )
      chunks.push(w_column_chunk(offset, meta))
    }
    groups.push(w_row_group(chunks, group_size, rows))
    total_rows += rows.to_int64()
  }
  let schema : Array[Bytes] = [w_schema_root(entry.schema.columns.length())]
  for column in entry.schema.columns {
    schema.push(w_schema_leaf(column.name, w_type_id(column.dtype)))
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
  let bytes = write_bytes(entry)
  @fs.write_bytes_to_file(path, bytes) catch {
    _ => raise write_error("cannot write file at \{path}")
  }
}
