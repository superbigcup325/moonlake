// Lazy scan sources: a table entry can point at a source instead of holding
// materialized batches, so registering a table costs its schema (which the
// binder needs) and nothing else. The engine asks for a projection plus the
// conjuncts it will apply anyway, then pulls batches until the stream ends.

///|
/// Rows per batch a scan source should aim for. Sources may emit a final
/// smaller batch; a zero-row table emits one empty batch so the engine still
/// sees the column layout.
pub const SCAN_BATCH_ROWS : Int32 = 4096

///|
/// One conjunctive predicate hint, in the table's own column numbering
/// (not the projection's): `column op constant`.
///
/// Hints are advisory. The engine applies the predicate itself, so a source
/// may ignore every hint; a source that uses one must only skip rows that
/// provably cannot satisfy it (that is what Parquet row-group statistics
/// are good for). Column pruning is not a hint: it is the projection.
pub(all) struct ScanPredicate {
  column : Int32
  op : @types.CmpOp
  value : @types.Scalar
}

///|
/// What one scan of a table should produce: the columns the query reads and
/// the predicates it may use to skip data.
pub(all) struct ScanRequest {
  projection : Array[Int32]
  predicates : Array[ScanPredicate]
}

///|
pub fn ScanRequest::new(
  projection : Array[Int32],
  predicates : Array[ScanPredicate],
) -> ScanRequest {
  { projection, predicates, }
}

///|
/// Every column of a `width`-column table, no predicates: what a whole-file
/// read (a writer, `SELECT *`) asks for.
pub fn ScanRequest::all(width : Int32) -> ScanRequest {
  let projection : Array[Int32] = []
  for c in 0..<width {
    projection.push(c)
  }
  { projection, predicates: [], }
}

///|
/// One part of a scan's work that is known before reading any row: how many
/// files and row groups exist, and how many row groups statistics eliminated.
pub(all) struct ScanPlan {
  files : Int32
  row_groups : Int32
  row_groups_skipped : Int32
  rows : Int64? // rows the scan expects to read, when the format knows
}

///|
pub fn ScanPlan::none() -> ScanPlan {
  { files: 1, row_groups: 0, row_groups_skipped: 0, rows: None, }
}

///|
/// A cursor over the batches of one scan. `next` returns `None` exactly once
/// at the end; batches are independent and may be read lazily. Column `i` of
/// every batch is schema column `request.projection[i]`.
pub(open) trait BatchStream {
  fn next(self : Self) -> @types.DataBatch? raise @types.SqlError
}

///|
/// A lazily scanned table: the schema is known up front, the data is not.
pub(open) trait ScanSource {
  /// Open a cursor for `request`. Nothing is decoded before the first `next`.
  fn open(self : Self, request : ScanRequest) -> &BatchStream raise @types.SqlError
  /// What `open` would read, without reading it. Used by EXPLAIN.
  fn plan(self : Self, request : ScanRequest) -> ScanPlan raise @types.SqlError
}

///|
/// Drop all but `columns` (ascending) from each batch, sharing the vectors.
pub fn project_batches(
  batches : Array[@types.DataBatch],
  columns : Array[Int32],
) -> Array[@types.DataBatch] {
  let out : Array[@types.DataBatch] = []
  for batch in batches {
    let kept : Array[@types.ColumnVector] = []
    for c in columns {
      kept.push(batch.columns()[c])
    }
    out.push(@types.DataBatch::new(kept, batch.row_count()))
  }
  out
}

///|
/// Drain a stream to a batch array. The engine stops here because joins,
/// aggregation and sorting are still eager; a source still decides how much
/// it decodes per batch, and a predicate passed to `drain_stream` keeps the
/// materialized row count below the table's own.
pub fn drain_stream(
  stream : &BatchStream,
) -> Array[@types.DataBatch] raise @types.SqlError {
  let out : Array[@types.DataBatch] = []
  while stream.next() is Some(batch) {
    out.push(batch)
  }
  out
}
