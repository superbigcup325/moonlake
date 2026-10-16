// Parquet scanning: adapt the in-house reader's decoded columns to moonlake
// vectors.
//
// The reader decodes a whole file eagerly and concatenates its row groups,
// so a table materializes as a single batch (same shape as before). Nullable
// columns carry a validity array; FLOAT upcasts to float64; a column named
// in `date_columns` lifts its INT32 payload to DATE at registration time,
// which keeps DATE semantics in the catalog rather than in the decoder.

///|
/// Scan Parquet bytes into a registered table entry.
pub fn scan_bytes(
  content : Bytes,
  table_name : String,
  date_columns : Array[String],
) -> @catalog.TableEntry raise @types.SqlError {
  let (columns, rows) = read_columns(content)
  let vectors : Array[@types.ColumnVector] = []
  let schema_cols : Array[@catalog.Column] = []
  for col in columns {
    let is_date = date_columns.contains(col.name)
    let vec = adapt(col, is_date)
    schema_cols.push({ name: col.name, dtype: vec.dtype(), })
    vectors.push(vec)
  }
  let schema : @catalog.TableSchema = {
    table: table_name,
    columns: schema_cols,
  }
  let batch = @types.DataBatch::new(vectors, rows)
  { schema, batches: [batch], }
}

///|
/// Scan a Parquet file from disk (native target; wasm targets load the bytes
/// via the playground bridge and call scan_bytes).
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
fn adapt(col : DecodedColumn, is_date : Bool) -> @types.ColumnVector {
  let n = col.rows()
  match col.values {
    Bools(values, valid) => {
      let vec = @types.ColumnVector::make(@types.Bool, n)
      let mut k = 0
      for i in 0..<n {
        if valid[i] {
          vec.set(i, @types.Boolean(values[k]))
          k += 1
        } else {
          vec.set(i, @types.Null)
        }
      }
      vec
    }
    Int32s(values, valid) => {
      let dt : @types.DataType = if is_date {
        @types.DataType::Date
      } else {
        @types.DataType::Int32
      }
      let vec = @types.ColumnVector::make(dt, n)
      let mut k = 0
      for i in 0..<n {
        if valid[i] {
          vec.set(
            i,
            if is_date {
              @types.Date(values[k])
            } else {
              @types.Int32(values[k])
            },
          )
          k += 1
        } else {
          vec.set(i, @types.Null)
        }
      }
      vec
    }
    Int64s(values, valid) => {
      let vec = @types.ColumnVector::make(@types.Int64, n)
      let mut k = 0
      for i in 0..<n {
        if valid[i] {
          vec.set(i, @types.Int64(values[k]))
          k += 1
        } else {
          vec.set(i, @types.Null)
        }
      }
      vec
    }
    Floats(values, valid) => {
      let vec = @types.ColumnVector::make(@types.Float64, n)
      let mut k = 0
      for i in 0..<n {
        if valid[i] {
          vec.set(i, @types.Float64(values[k].to_double()))
          k += 1
        } else {
          vec.set(i, @types.Null)
        }
      }
      vec
    }
    Doubles(values, valid) => {
      let vec = @types.ColumnVector::make(@types.Float64, n)
      let mut k = 0
      for i in 0..<n {
        if valid[i] {
          vec.set(i, @types.Float64(values[k]))
          k += 1
        } else {
          vec.set(i, @types.Null)
        }
      }
      vec
    }
    Strings(values, valid) => {
      let vec = @types.ColumnVector::make(@types.Str, n)
      let mut k = 0
      for i in 0..<n {
        if valid[i] {
          vec.set(i, @types.Str(values[k]))
          k += 1
        } else {
          vec.set(i, @types.Null)
        }
      }
      vec
    }
  }
}
