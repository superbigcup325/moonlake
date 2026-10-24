// Whitebox tests for how much of a source a query actually pulls. The scan
// materializes every batch of a table before anything downstream — a filter,
// a LIMIT, an aggregate — gets to look at a row, so the counts below are the
// baseline a batched executor has to move: `scan pulls` and `scan rows` say
// what the query cost its source, which is not the same thing as what it
// returned. The `limit` case is the one that should flip; the rest say which
// shapes must keep reading everything, so a later change cannot shrink one
// count by dropping rows it still owes.

///|
/// A lazy table over in-memory batches that counts what the engine asks of it.
/// `cells` is `[opens, pulls, rows, projection width]`, shared by reference with
/// the source, the stream and the test.
priv struct CountingSource {
  batches : Array[@types.DataBatch]
  cells : Array[Int32]
}

///|
priv struct CountingStream {
  batches : Array[@types.DataBatch]
  cells : Array[Int32]
  mut pos : Int32
}

///|
impl @catalog.BatchStream for CountingStream with fn next(self) -> @types.DataBatch? raise @types.SqlError {
  if self.pos >= self.batches.length() {
    None
  } else {
    let batch = self.batches[self.pos]
    self.pos = self.pos + 1
    self.cells.set(1, self.cells[1] + 1)
    self.cells.set(2, self.cells[2] + batch.row_count())
    Some(batch)
  }
}

///|
impl @catalog.ScanSource for CountingSource with fn open(
  self,
  request : @catalog.ScanRequest,
) -> &@catalog.BatchStream raise @types.SqlError {
  self.cells.set(0, self.cells[0] + 1)
  self.cells.set(3, request.projection.length())
  // A real source decodes only the projected columns; the pipeline expects
  // exactly that layout, so the test source projects the same way.
  let kept : Array[@types.DataBatch] = []
  for batch in self.batches {
    let cols : Array[@types.ColumnVector] = []
    for c in request.projection {
      cols.push(batch.columns()[c])
    }
    kept.push(@types.DataBatch::new(cols, batch.row_count()))
  }
  CountingStream::{ batches: kept, cells: self.cells, pos: 0, }
}

///|
impl @catalog.ScanSource for CountingSource with fn plan(
  self,
  _request : @catalog.ScanRequest,
) -> @catalog.ScanPlan {
  let mut rows = 0L
  for batch in self.batches {
    rows += batch.row_count().to_int64()
  }
  {
    files: 1,
    row_groups: self.batches.length(),
    row_groups_skipped: 0,
    rows: Some(rows),
  }
}

///|
/// `batches` batches of `rows_per_batch` rows over two int32 columns: `c0` is
/// the row's position in the table, `c1` its position within the batch.
fn counted_batches(
  batches : Int32,
  rows_per_batch : Int32,
) -> Array[@types.DataBatch] {
  let out : Array[@types.DataBatch] = []
  for b in 0..<batches {
    let c0 = @types.ColumnVector::make(@types.Int32, rows_per_batch)
    let c1 = @types.ColumnVector::make(@types.Int32, rows_per_batch)
    for r in 0..<rows_per_batch {
      c0.set(r, @types.Int32(b * rows_per_batch + r))
      c1.set(r, @types.Int32(r))
    }
    out.push(@types.DataBatch::new([c0, c1], rows_per_batch))
  }
  out
}

///|
/// A catalog holding one lazy table `t`, plus the counters its source updates:
/// `[opens, pulls, rows, projection width]`.
fn counting_catalog(
  batches : Int32,
  rows_per_batch : Int32,
) -> (@catalog.Catalog, Array[Int32]) {
  let cells : Array[Int32] = [0, 0, 0, 0]
  let schema : @catalog.TableSchema = {
    table: "t",
    columns: [
      { name: "c0", dtype: @types.Int32, },
      { name: "c1", dtype: @types.Int32, },
    ],
  }
  let source : CountingSource = {
    batches: counted_batches(batches, rows_per_batch),
    cells,
  }
  let cat = @catalog.Catalog::new()
  cat.register(@catalog.TableEntry::from_source(schema, source))
  (cat, cells)
}

///|
fn run_counted(sql : String, cat : @catalog.Catalog) -> SelectResult {
  run_select(sql, cat) catch {
    e => abort("\{e}")
  }
}

///|
test "a scan pulls every batch, and a LIMIT cannot stop it" {
  // 8 batches of 100 rows; LIMIT 10 needs the first 10 rows of the first
  // batch. Today the scan materializes all 800 rows and the LIMIT slices the
  // result afterwards, which is the cost the batched executor removes.
  let (cat, cells) = counting_catalog(8, 100)
  let r = run_counted("SELECT c0 FROM t LIMIT 10", cat)
  assert_eq(r.row_count(), 10)
  assert_eq(r.get(0, 0), @types.Scalar::Int32(0))
  assert_eq(cells[1], 8) // pulls
  assert_eq(cells[2], 800) // rows pulled, not rows returned
  assert_eq(cells[3], 1) // projection width: only c0 was decoded
}

///|
test "a selective filter reads the whole table and keeps almost nothing" {
  // WHERE eliminates every row; the scan still pays for all of them, because
  // the filter runs batch by batch but nothing tells the source to stop.
  let (cat, cells) = counting_catalog(8, 100)
  let r = run_counted("SELECT c0 FROM t WHERE c0 < 0", cat)
  assert_eq(r.row_count(), 0)
  assert_eq(cells[1], 8)
  assert_eq(cells[2], 800)
}

///|
test "OFFSET past the first batch still pulls every batch" {
  let (cat, cells) = counting_catalog(8, 100)
  let r = run_counted("SELECT c0 FROM t LIMIT 5 OFFSET 495", cat)
  assert_eq(r.row_count(), 5)
  assert_eq(r.get(0, 0), @types.Scalar::Int32(495))
  assert_eq(cells[1], 8)
  assert_eq(cells[2], 800)
}

///|
test "an aggregate pulls every batch, which is honest" {
  // COUNT(*) has to see the rows: this count must not shrink when the
  // executor learns to stop early.
  let (cat, cells) = counting_catalog(8, 100)
  let r = run_counted("SELECT count(*), sum(c0) FROM t", cat)
  assert_eq(r.get(0, 0), @types.Scalar::Int64(800L))
  assert_eq(r.get(0, 1), @types.Scalar::Int64(319600L))
  assert_eq(cells[1], 8)
  assert_eq(cells[2], 800)
}

///|
test "ORDER BY LIMIT still reads the whole table, which is honest" {
  // A top-10 over an unsorted table cannot know it has the top 10 before the
  // last batch arrives, so this count stays at 8 after any early-stop work.
  let (cat, cells) = counting_catalog(8, 100)
  let r = run_counted("SELECT c0 FROM t ORDER BY c0 DESC LIMIT 10", cat)
  assert_eq(r.row_count(), 10)
  assert_eq(r.get(0, 0), @types.Scalar::Int32(799))
  assert_eq(cells[1], 8)
  assert_eq(cells[2], 800)
}

///|
test "a derived table materializes before the outer LIMIT sees a row" {
  // The inner SELECT is a full query: the outer LIMIT arrives after the
  // derived result exists, so both counts are the whole table.
  let (cat, cells) = counting_catalog(8, 100)
  let r = run_counted("SELECT c0 FROM (SELECT c0 FROM t) s LIMIT 10", cat)
  assert_eq(r.row_count(), 10)
  assert_eq(cells[0], 1) // the inner scan opened once
  assert_eq(cells[1], 8)
  assert_eq(cells[2], 800)
}

///|
test "a batch-at-a-time source is what the counts above are counting" {
  // Guard for the tests themselves: a 1-batch table pulls 1 batch, so the
  // counts above measure the scan and not some fixed overhead.
  let (cat, cells) = counting_catalog(1, 10)
  let r = run_counted("SELECT c0 FROM t", cat)
  assert_eq(r.row_count(), 10)
  assert_eq(cells[1], 1)
  assert_eq(cells[2], 10)
}
