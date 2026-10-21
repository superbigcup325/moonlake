// Table schema registry. A table entry is either materialized in memory or
// backed by a lazy scan source (see source.mbt); either way the schema is
// available without touching the data, which is all the binder needs.

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
pub fn TableSchema::index_of(self : TableSchema, name : String) -> Int32? {
  for i, col in self.columns {
    if col.name == name {
      return Some(i)
    }
  }
  None
}

///|
/// A registered table: its schema, and either materialized batches or a lazy
/// source. Exactly one of `batches` / `source` carries data — a lazy entry
/// keeps `batches` empty and answers `scan` from `source`.
pub(all) struct TableEntry {
  schema : TableSchema
  batches : Array[@types.DataBatch]
  source : &ScanSource?
}

///|
/// A table already in memory (tests, derived scratch tables, the spill bench).
pub fn TableEntry::new(
  schema : TableSchema,
  batches : Array[@types.DataBatch],
) -> TableEntry {
  { schema, batches, source: None, }
}

///|
/// A table that scans its data on demand. Registering it reads no rows.
pub fn TableEntry::from_source(
  schema : TableSchema,
  source : &ScanSource,
) -> TableEntry {
  { schema, batches: [], source: Some(source), }
}

///|
/// Whether this entry streams from a source instead of holding its batches.
pub fn TableEntry::is_lazy(self : TableEntry) -> Bool {
  self.source is Some(_)
}

///|
/// Produce the batches one query needs: only `request.projection` columns,
/// in that order, from the materialized batches or from a fresh stream.
/// Predicates are advisory (see ScanPredicate); the caller still filters.
pub fn TableEntry::scan(
  self : TableEntry,
  request : ScanRequest,
) -> Array[@types.DataBatch] raise @types.SqlError {
  match self.source {
    Some(src) => drain_stream(src.open(request))
    None => project_batches(self.batches, request.projection)
  }
}

///|
/// The same scan as a cursor instead of an array. `scan` materializes every
/// batch because the engine's operators are still eager; a caller that can
/// consume one batch at a time (the Parquet writer) uses this and never holds
/// the table. The cursor owns its batches either way — a lazy source decodes
/// them as `next` is called.
pub fn TableEntry::stream(
  self : TableEntry,
  request : ScanRequest,
) -> &BatchStream raise @types.SqlError {
  match self.source {
    Some(src) => src.open(request)
    None => {
      let projected = project_batches(self.batches, request.projection)
      (BatchesStream::{ batches: projected, index: 0, } : &BatchStream)
    }
  }
}

///|
/// A cursor over batches that are already in memory, for an entry built with
/// `TableEntry::new`.
priv struct BatchesStream {
  batches : Array[@types.DataBatch]
  mut index : Int32
}

///|
impl BatchStream for BatchesStream with fn next(self) -> @types.DataBatch? raise @types.SqlError {
  if self.index >= self.batches.length() {
    return None
  }
  let batch = self.batches[self.index]
  self.index += 1
  Some(batch)
}

///|
/// Planning information for EXPLAIN: row groups statistics eliminated.
/// Materialized entries have no plan to report.
pub fn TableEntry::plan(
  self : TableEntry,
  request : ScanRequest,
) -> ScanPlan raise @types.SqlError {
  match self.source {
    Some(src) => src.plan(request)
    None =>
      if self.batches.length() == 0 {
        ScanPlan::none()
      } else {
        let mut rows = 0L
        for b in self.batches {
          rows += b.row_count().to_int64()
        }
        { files: 1, row_groups: 0, row_groups_skipped: 0, rows: Some(rows), }
      }
  }
}

///|
/// Drop one table. A missing name is a no-op: the caller that cares whether it
/// existed can `lookup` first, and a drop that fails because the table is
/// already gone is not an error worth reporting.
pub fn Catalog::drop(self : Catalog, name : String) -> Unit {
  let _ = self.tables.remove(name)
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
