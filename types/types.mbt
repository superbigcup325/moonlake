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
/// Structured error: one variant per pipeline stage carrying the reason.
pub(all) suberror SqlError {
  Parse(String)
  Bind(String)
  Scan(String)
  Execute(String)
} derive(Eq, Debug)

///|
pub fn SqlError::stage(self : SqlError) -> String {
  match self {
    Parse(_) => "parse"
    Bind(_) => "bind"
    Scan(_) => "scan"
    Execute(_) => "execute"
  }
}

///|
pub fn SqlError::message(self : SqlError) -> String {
  match self {
    Parse(m) => m
    Bind(m) => m
    Scan(m) => m
    Execute(m) => m
  }
}

///|
pub fn SqlError::to_string(self : SqlError) -> String {
  "sql error (\{self.stage()}): \{self.message()}"
}

///|
pub impl Show for SqlError with fn output(self, logger) {
  logger.write_string(self.to_string())
}
