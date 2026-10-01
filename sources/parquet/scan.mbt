// Parquet scanning: adapt mizchi/parquet's columnar reader to moonlake
// vectors. The upstream API decodes the whole file eagerly (no row
// groups), so the table materializes as a single batch. Nullable
// variants become validity slots; Float upcasts to float64; parquet DATE
// arrives as int32 and is lifted to DATE by naming the column in
// date_columns (registration-time semantics, per the plan). Timestamp
// and binary columns are rejected at registration, not at execution.

///|
/// Scan Parquet bytes into a registered table entry.
pub fn scan_bytes(
  content : Bytes,
  table_name : String,
  date_columns : Array[String],
) -> @catalog.TableEntry raise @types.SqlError {
  let file = @mp.read_bytes_columnar(content) catch {
    err => raise @types.SqlError::Scan("parquet: \{err}")
  }
  build_entry(table_name, file, date_columns)
}

///|
/// Scan a Parquet file from disk (native target; wasm targets load the
/// bytes via the playground bridge and call scan_bytes).
pub fn scan_file(
  path : String,
  table_name : String,
  date_columns : Array[String],
) -> @catalog.TableEntry raise @types.SqlError {
  let content = @fs.read_file_to_bytes(path) catch {
    _ => raise @types.SqlError::Scan("cannot read file at \{path}")
  }
  scan_bytes(content, table_name, date_columns)
}

///|
fn unsupported_error(name : String, ctype : @mp.ColumnType) -> @types.SqlError {
  @types.SqlError::Scan(
    "parquet column \"\{name}\": unsupported type \{ctype.to_string()} (timestamp/binary not supported in v1)",
  )
}

///|
fn build_entry(
  table_name : String,
  file : @mp.ParquetColumnarFile,
  date_columns : Array[String],
) -> @catalog.TableEntry raise @types.SqlError {
  let n = file.row_count()
  let columns : Array[@catalog.Column] = []
  let vectors : Array[@types.ColumnVector] = []
  for i, col in file.columns() {
    if col.repetition() is @mp.Repeated {
      raise @types.SqlError::Scan(
        "parquet column \"\{col.name()}\": repeated fields are not supported",
      )
    }
    let is_date = date_columns.contains(col.name())
    let (vec, dtype) = adapt(
      col.name(),
      col.column_type(),
      file.column_data()[i],
      is_date,
    )
    columns.push({ name: col.name(), dtype, })
    vectors.push(vec)
  }
  let schema : @catalog.TableSchema = { table: table_name, columns, }
  let batch = @types.DataBatch::new(vectors, n)
  { schema, batches: [batch], }
}

///|
fn adapt(
  name : String,
  ctype : @mp.ColumnType,
  data : @mp.ParquetColumnData,
  is_date : Bool,
) -> (@types.ColumnVector, @types.DataType) raise @types.SqlError {
  let n = data.length()
  match data {
    Int32Values(vals) => {
      let dt : @types.DataType = if is_date {
        @types.DataType::Date
      } else {
        @types.DataType::Int32
      }
      let vec = @types.ColumnVector::make(dt, n)
      for i in 0..<n {
        vec.set(
          i,
          if is_date {
            @types.Date(vals[i])
          } else {
            @types.Int32(vals[i])
          },
        )
      }
      (vec, dt)
    }
    NullableInt32Values(vals) => {
      let dt : @types.DataType = if is_date {
        @types.DataType::Date
      } else {
        @types.DataType::Int32
      }
      let vec = @types.ColumnVector::make(dt, n)
      for i in 0..<n {
        match vals[i] {
          Some(v) =>
            vec.set(i, if is_date { @types.Date(v) } else { @types.Int32(v) })
          None => vec.set(i, @types.Null)
        }
      }
      (vec, dt)
    }
    Int64Values(vals) => fill_i64(n, fn(i) { vals[i] })
    NullableInt64Values(vals) => fill_i64_opt(n, fn(i) { vals[i] })
    DoubleValues(vals) => fill_f64(n, fn(i) { vals[i] })
    FloatValues(vals) => fill_f64(n, fn(i) { vals[i].to_double() })
    BooleanValues(vals) => {
      let vec = @types.ColumnVector::make(@types.Bool, n)
      for i in 0..<n {
        vec.set(i, @types.Boolean(vals[i]))
      }
      (vec, @types.Bool)
    }
    Utf8Values(vals) => fill_str(n, fn(i) { @utf8.decode_lossy(vals[i][:]) })
    NullableUtf8Values(vals) =>
      fill_str_opt(n, fn(i) {
        match vals[i] {
          Some(v) => Some(@utf8.decode_lossy(v[:]))
          None => None
        }
      })
    Values(vals) => adapt_values(name, ctype, vals, is_date)
    _ => raise unsupported_error(name, ctype)
  }
}

///|
fn adapt_values(
  name : String,
  ctype : @mp.ColumnType,
  vals : Array[@mp.Value],
  is_date : Bool,
) -> (@types.ColumnVector, @types.DataType) raise @types.SqlError {
  let n = vals.length()
  let vec = match ctype {
    Boolean => {
      let v = @types.ColumnVector::make(@types.Bool, n)
      for i in 0..<n {
        match vals[i] {
          @mp.Boolean(b) => v.set(i, @types.Boolean(b))
          @mp.Null => v.set(i, @types.Null)
          _ => raise unsupported_error(name, ctype)
        }
      }
      (v, @types.Bool)
    }
    Int32 => {
      let dt : @types.DataType = if is_date {
        @types.DataType::Date
      } else {
        @types.DataType::Int32
      }
      let v = @types.ColumnVector::make(dt, n)
      for i in 0..<n {
        match vals[i] {
          @mp.Int32(x) =>
            v.set(i, if is_date { @types.Date(x) } else { @types.Int32(x) })
          @mp.Null => v.set(i, @types.Null)
          _ => raise unsupported_error(name, ctype)
        }
      }
      (v, dt)
    }
    Int64 => {
      let v = @types.ColumnVector::make(@types.Int64, n)
      for i in 0..<n {
        match vals[i] {
          @mp.Int64(x) => v.set(i, @types.Int64(x))
          @mp.Int32(x) => v.set(i, @types.Int64(x.to_int64()))
          @mp.Null => v.set(i, @types.Null)
          _ => raise unsupported_error(name, ctype)
        }
      }
      (v, @types.Int64)
    }
    Double | Float => {
      let v = @types.ColumnVector::make(@types.Float64, n)
      for i in 0..<n {
        match vals[i] {
          @mp.Double(x) => v.set(i, @types.Float64(x))
          @mp.Float(x) => v.set(i, @types.Float64(x.to_double()))
          @mp.Null => v.set(i, @types.Null)
          _ => raise unsupported_error(name, ctype)
        }
      }
      (v, @types.Float64)
    }
    String => {
      let v = @types.ColumnVector::make(@types.Str, n)
      for i in 0..<n {
        match vals[i] {
          @mp.String(s) => v.set(i, @types.Str(s))
          @mp.Null => v.set(i, @types.Null)
          _ => raise unsupported_error(name, ctype)
        }
      }
      (v, @types.Str)
    }
    _ => raise unsupported_error(name, ctype)
  }
  vec
}

///|
fn fill_i64(
  n : Int,
  get : (Int) -> Int64,
) -> (@types.ColumnVector, @types.DataType) {
  let vec = @types.ColumnVector::make(@types.Int64, n)
  for i in 0..<n {
    vec.set(i, @types.Int64(get(i)))
  }
  (vec, @types.Int64)
}

///|
fn fill_i64_opt(
  n : Int,
  get : (Int) -> Int64?,
) -> (@types.ColumnVector, @types.DataType) {
  let vec = @types.ColumnVector::make(@types.Int64, n)
  for i in 0..<n {
    match get(i) {
      Some(v) => vec.set(i, @types.Int64(v))
      None => vec.set(i, @types.Null)
    }
  }
  (vec, @types.Int64)
}

///|
fn fill_f64(
  n : Int,
  get : (Int) -> Double,
) -> (@types.ColumnVector, @types.DataType) {
  let vec = @types.ColumnVector::make(@types.Float64, n)
  for i in 0..<n {
    vec.set(i, @types.Float64(get(i)))
  }
  (vec, @types.Float64)
}

///|
fn fill_str(
  n : Int,
  get : (Int) -> String,
) -> (@types.ColumnVector, @types.DataType) {
  let vec = @types.ColumnVector::make(@types.Str, n)
  for i in 0..<n {
    vec.set(i, @types.Str(get(i)))
  }
  (vec, @types.Str)
}

///|
fn fill_str_opt(
  n : Int,
  get : (Int) -> String?,
) -> (@types.ColumnVector, @types.DataType) {
  let vec = @types.ColumnVector::make(@types.Str, n)
  for i in 0..<n {
    match get(i) {
      Some(s) => vec.set(i, @types.Str(s))
      None => vec.set(i, @types.Null)
    }
  }
  (vec, @types.Str)
}
