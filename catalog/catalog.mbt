// Table schema registry. W1 keeps table data materialized in memory next
// to its schema; lazy per-file scans arrive with the parquet source.

///|
/// One column of a table schema: its name and columnar type.
pub(all) struct Column {
  name : String
  dtype : @types.DataType
} derive(Eq, Debug)

///|
pub extend Column with Eq::{equal, not_equal}

///|
pub extend Column with @debug.Debug::{to_repr}

///|

///|
/// A table's schema: its name and ordered columns. Field names are the
/// user-facing SQL identifiers.
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
/// The registry `execute` reads from: map table name to its entry.
/// Plain values everywhere — build one per execution (or share one
/// across threads that never mutate it).
pub struct Catalog {
  tables : Map[String, TableEntry]
}

///|
/// An empty catalog; register scanned tables into it.
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
