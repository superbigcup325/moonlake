// Table schema registry. W1 keeps table data materialized in memory next
// to its schema; lazy per-file scans arrive with the parquet source.

///|
pub(all) struct Column {
  name : String
  dtype : @types.DataType
} derive(Eq, Debug)

///|
pub extend Column with Eq::{equal, not_equal}

///|
pub extend Column with @debug.Debug::{to_repr}

///|
pub(all) struct TableSchema {
  table : String
  columns : Array[Column]
} derive(Eq, Debug)

///|
pub extend TableSchema with Eq::{equal, not_equal}

///|
pub extend TableSchema with @debug.Debug::{to_repr}

///|
pub fn TableSchema::index_of(self : TableSchema, name : String) -> Int? {
  for i, col in self.columns {
    if col.name == name {
      return Some(i)
    }
  }
  None
}

///|
/// Materialized table: schema plus its data in batch form.
pub(all) struct TableEntry {
  schema : TableSchema
  batches : Array[@types.DataBatch]
}

///|
pub struct Catalog {
  tables : Map[String, TableEntry]
}

///|
pub fn Catalog::new() -> Catalog {
  { tables: {}, }
}

///|
/// Register (or replace) a table entry.
pub fn Catalog::register(self : Catalog, entry : TableEntry) -> Unit {
  self.tables[entry.schema.table] = entry
}

///|
pub fn Catalog::lookup(self : Catalog, name : String) -> TableEntry? {
  self.tables.get(name)
}
