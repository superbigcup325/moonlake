// moonlake types: data types, scalars with three-valued NULL logic, and
// structured errors. Everything else in the module builds on this package.

///|
/// Column data types supported by the engine (v1).
pub(all) enum DataType {
  Int32
  Int64
  Float64
  Str
  Bool
  Date
} derive(Eq, Debug)

///|
pub fn DataType::to_string(self : DataType) -> String {
  match self {
    Int32 => "int32"
    Int64 => "int64"
    Float64 => "float64"
    Str => "string"
    Bool => "bool"
    Date => "date"
  }
}

///|
/// A single value. Null participates in three-valued logic (see compare
/// and logic helpers below).
pub(all) enum Scalar {
  Null
  Boolean(Bool)
  Int32(Int)
  Int64(Int64)
  Float64(Double)
  Str(String)
  Date(Int) // days since 1970-01-01
} derive(Eq, Debug)

///|
pub fn Scalar::to_string(self : Scalar) -> String {
  match self {
    Null => "null"
    Boolean(b) => if b { "true" } else { "false" }
    Int32(v) => v.to_string()
    Int64(v) => v.to_string()
    Float64(v) => v.to_string()
    Str(v) => v
    Date(d) => epoch_to_string(d)
  }
}

///|
/// Structured error carrying the pipeline stage it originated from.
pub struct SqlError {
  stage : String // "parse" | "bind" | "scan" | "execute"
  message : String
} derive(Eq, Debug)

///|
pub fn SqlError::to_string(self : SqlError) -> String {
  "sql error (\{self.stage}): \{self.message}"
}

///|
pub fn SqlError::new(stage : String, message : String) -> SqlError {
  { stage, message }
}
