// Column vectors and data batches: the engine's physical data units.
// A vector is a fixed array of values plus a validity bitmap-like array;
// batch size for scans is set by the CSV source (4096 rows).

///|
pub(all) enum ColumnVector {
  I32(FixedArray[Int32], FixedArray[Bool])
  I64(FixedArray[Int64], FixedArray[Bool])
  F64(FixedArray[Double], FixedArray[Bool])
  BoolV(FixedArray[Bool], FixedArray[Bool])
  StrV(FixedArray[String], FixedArray[Bool])
  DateV(FixedArray[Int32], FixedArray[Bool]) // epoch days
}

///|
pub fn ColumnVector::len(self : ColumnVector) -> Int32 {
  match self {
    I32(d, _) => d.length()
    I64(d, _) => d.length()
    F64(d, _) => d.length()
    BoolV(d, _) => d.length()
    StrV(d, _) => d.length()
    DateV(d, _) => d.length()
  }
}

///|
pub fn ColumnVector::dtype(self : ColumnVector) -> DataType {
  match self {
    I32(_, _) => Int32
    I64(_, _) => Int64
    F64(_, _) => Float64
    BoolV(_, _) => Bool
    StrV(_, _) => Str
    DateV(_, _) => Date
  }
}

///|
/// What a string column's cells cost, in the unit `estimate_batch_bytes` counts:
/// four proxy bytes plus the characters for a valid cell, one for a NULL. Reads
/// the column's own array instead of building a `Scalar` per row through `get`,
/// which is what a byte check in the middle of a join loop needs — a budgeted
/// step asks for this on every side of every step.
pub fn ColumnVector::str_cell_bytes(self : ColumnVector) -> Int32 {
  match self {
    StrV(d, v) => {
      let mut total = 0
      for i in 0..<d.length() {
        if v[i] {
          total += 4 + d[i].length()
        } else {
          total += 1
        }
      }
      total
    }
    _ => 0
  }
}

///|
/// Element access with validity: invalid slots come back as Null.
pub fn ColumnVector::get(self : ColumnVector, i : Int32) -> Scalar {
  let valid = match self {
    I32(_, v) => v[i]
    I64(_, v) => v[i]
    F64(_, v) => v[i]
    BoolV(_, v) => v[i]
    StrV(_, v) => v[i]
    DateV(_, v) => v[i]
  }
  if !valid {
    return Null
  }
  match self {
    I32(d, _) => Int32(d[i])
    I64(d, _) => Int64(d[i])
    F64(d, _) => Float64(d[i])
    BoolV(d, _) => Boolean(d[i])
    StrV(d, _) => Str(d[i])
    DateV(d, _) => Date(d[i])
  }
}

///|
/// Allocate an all-valid vector of the given type and length.
pub fn ColumnVector::make(dtype : DataType, n : Int32) -> ColumnVector {
  let valid = FixedArray::make(n, true)
  match dtype {
    Int32 => I32(FixedArray::make(n, 0), valid)
    Int64 => I64(FixedArray::make(n, 0L), valid)
    Float64 => F64(FixedArray::make(n, 0.0), valid)
    Bool => BoolV(FixedArray::make(n, false), valid)
    Str => StrV(FixedArray::make(n, ""), valid)
    Date => DateV(FixedArray::make(n, 0), valid)
  }
}

///|
/// Write a scalar at position i. Writing Null marks the slot invalid.
/// Type must match the vector (caller responsibility, binder-checked).
pub fn ColumnVector::set(self : ColumnVector, i : Int32, v : Scalar) -> Unit {
  match (self, v) {
    (I32(d, valid), Int32(x)) => {
      d[i] = x
      valid[i] = true
    }
    (I64(d, valid), Int64(x)) => {
      d[i] = x
      valid[i] = true
    }
    (F64(d, valid), Float64(x)) => {
      d[i] = x
      valid[i] = true
    }
    (BoolV(d, valid), Boolean(x)) => {
      d[i] = x
      valid[i] = true
    }
    (StrV(d, valid), Str(x)) => {
      d[i] = x
      valid[i] = true
    }
    (DateV(d, valid), Date(x)) => {
      d[i] = x
      valid[i] = true
    }
    (_, Null) =>
      match self {
        I32(_, valid) => valid[i] = false
        I64(_, valid) => valid[i] = false
        F64(_, valid) => valid[i] = false
        BoolV(_, valid) => valid[i] = false
        StrV(_, valid) => valid[i] = false
        DateV(_, valid) => valid[i] = false
      }
    _ => () // type mismatch: unreachable from binder-checked paths
  }
}

///|
/// A chunk of rows in column form.
pub struct DataBatch {
  columns : Array[ColumnVector]
  row_count : Int32
}

///|
pub fn DataBatch::columns(self : DataBatch) -> Array[ColumnVector] {
  self.columns
}

///|
pub fn DataBatch::row_count(self : DataBatch) -> Int32 {
  self.row_count
}

///|
pub fn DataBatch::new(
  columns : Array[ColumnVector],
  row_count : Int32,
) -> DataBatch {
  { columns, row_count, }
}
