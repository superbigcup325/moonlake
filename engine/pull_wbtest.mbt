// Whitebox tests for how much of a source a query actually pulls. The counts
// say what the query cost its source, which is not the same thing as what it
// returned: `scan pulls` and `scan rows` are the price, and the tests below
// pin both the shapes that may stop early and the shapes that must keep
// reading everything, so a later change cannot shrink one count by dropping
// rows it still owes.
//
// The first half goes through the collected API, the second through
// `ResultStream`. They share one pull, so the point of the second half is not
// that its rows agree — that follows — but that a caller who stops after one
// batch really does stop the source, and that a window taken per batch returns
// the same rows a window taken from the whole result would.

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
/// A lazy two-column table `name` over in-memory batches, plus its counters:
/// `[opens, pulls, rows, projection width]`.
fn counting_entry(
  name : String,
  batches : Int32,
  rows_per_batch : Int32,
) -> (@catalog.TableEntry, Array[Int32]) {
  let cells : Array[Int32] = [0, 0, 0, 0]
  let schema : @catalog.TableSchema = {
    table: name,
    columns: [
      { name: "c0", dtype: @types.Int32, },
      { name: "c1", dtype: @types.Int32, },
    ],
  }
  let source : CountingSource = {
    batches: counted_batches(batches, rows_per_batch),
    cells,
  }
  (@catalog.TableEntry::from_source(schema, source), cells)
}

///|
fn counting_catalog(
  batches : Int32,
  rows_per_batch : Int32,
) -> (@catalog.Catalog, Array[Int32]) {
  let (entry, cells) = counting_entry("t", batches, rows_per_batch)
  let cat = @catalog.Catalog::new()
  cat.register(entry)
  (cat, cells)
}

///|
fn run_counted(sql : String, cat : @catalog.Catalog) -> SelectResult {
  run_select(sql, cat) catch {
    e => abort("\{e}")
  }
}

///|
test "a LIMIT stops the scan after the batch that fills its window" {
  // 8 batches of 100 rows; LIMIT 10 needs the first batch and nothing after it.
  // Before the streamed window this pulled all 8 batches to return 10 rows.
  let (cat, cells) = counting_catalog(8, 100)
  let r = run_counted("SELECT c0 FROM t LIMIT 10", cat)
  assert_eq(r.row_count(), 10)
  assert_eq(r.get(0, 0), @types.Scalar::Int32(0))
  assert_eq(cells[1], 1) // pulls
  assert_eq(cells[2], 100) // rows pulled, not rows returned
  assert_eq(cells[3], 1) // projection width: only c0 was decoded
}

///|
test "a LIMIT that spans batches pulls only the batches it needs" {
  let (cat, cells) = counting_catalog(8, 100)
  let r = run_counted("SELECT c0 FROM t LIMIT 250", cat)
  assert_eq(r.row_count(), 250)
  assert_eq(r.get(249, 0), @types.Scalar::Int32(249))
  assert_eq(cells[1], 3) // 300 rows are enough for 250
  assert_eq(cells[2], 300)
}

///|
test "an OFFSET deep into the table pulls only up to its window" {
  // 495 rows of offset plus 5 of limit: five batches fill it, the last three
  // are never touched.
  let (cat, cells) = counting_catalog(8, 100)
  let r = run_counted("SELECT c0 FROM t LIMIT 5 OFFSET 495", cat)
  assert_eq(r.row_count(), 5)
  assert_eq(r.get(0, 0), @types.Scalar::Int32(495))
  assert_eq(cells[1], 5)
  assert_eq(cells[2], 500)
}

///|
test "limit 0 opens the scan and pulls nothing" {
  let (cat, cells) = counting_catalog(8, 100)
  let r = run_counted("SELECT c0 FROM t LIMIT 0", cat)
  assert_eq(r.row_count(), 0)
  assert_eq(cells[1], 0)
  assert_eq(cells[2], 0)
}

///|
test "a filter that matches nothing cannot stop the scan, and must not" {
  // The source cannot evaluate this predicate (it is not pushed down as a
  // hint by the test source), so the scan has to look at every row to know
  // that none qualify. A count here that fell would be a wrong answer.
  let (cat, cells) = counting_catalog(8, 100)
  let r = run_counted("SELECT c0 FROM t WHERE c0 < 0 LIMIT 10", cat)
  assert_eq(r.row_count(), 0)
  assert_eq(cells[1], 8)
}

///|
test "a filter that passes rows still stops at the window" {
  let (cat, cells) = counting_catalog(8, 100)
  let r = run_counted("SELECT c0 FROM t WHERE c0 >= 0 LIMIT 10", cat)
  assert_eq(r.row_count(), 10)
  assert_eq(cells[1], 1) // first batch already has ten rows past the filter
}

///|
test "an aggregate pulls every batch, which is honest" {
  // COUNT(*) has to see the rows: this count must not shrink.
  let (cat, cells) = counting_catalog(8, 100)
  let r = run_counted("SELECT count(*), sum(c0) FROM t", cat)
  assert_eq(r.get(0, 0), @types.Scalar::Int64(800L))
  assert_eq(r.get(0, 1), @types.Scalar::Int64(319600L))
  assert_eq(cells[1], 8)
}

///|
test "ORDER BY LIMIT still reads the whole table, which is honest" {
  // A top-10 over an unsorted table cannot know it has the top 10 before the
  // last batch arrives.
  let (cat, cells) = counting_catalog(8, 100)
  let r = run_counted("SELECT c0 FROM t ORDER BY c0 DESC LIMIT 10", cat)
  assert_eq(r.row_count(), 10)
  assert_eq(r.get(0, 0), @types.Scalar::Int32(799))
  assert_eq(cells[1], 8)
}

///|
test "SELECT DISTINCT LIMIT still reads the whole table" {
  // DISTINCT has to see every row before it knows which rows are distinct.
  let (cat, cells) = counting_catalog(8, 100)
  let r = run_counted("SELECT DISTINCT c1 FROM t LIMIT 2", cat)
  assert_eq(r.row_count(), 2)
  assert_eq(cells[1], 8)
}

///|
test "a LIMIT over a join cannot stop either scan" {
  let (left, cells_l) = counting_entry("l", 2, 10)
  let (right, cells_r) = counting_entry("r", 2, 10)
  let cat = @catalog.Catalog::new()
  cat.register(left)
  cat.register(right)
  let r = run_counted("SELECT l.c0 FROM l, r LIMIT 10", cat)
  assert_eq(r.row_count(), 10)
  assert_eq(cells_l[1], 2) // the build side is read whole
  assert_eq(cells_r[1], 2)
}

///|
test "a derived table materializes before the outer LIMIT sees a row" {
  // The inner SELECT is a full query: the outer LIMIT arrives after the
  // derived result exists, so the count is the whole table.
  let (cat, cells) = counting_catalog(8, 100)
  let r = run_counted("SELECT c0 FROM (SELECT c0 FROM t) s LIMIT 10", cat)
  assert_eq(r.row_count(), 10)
  assert_eq(cells[0], 1) // the inner scan opened once
  assert_eq(cells[1], 8)
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

///|
/// Open the pulled delivery for `sql`, aborting on error: a test that raises
/// reports nothing useful.
fn open_stream(sql : String, cat : @catalog.Catalog) -> ResultStream {
  run_select_stream(sql, cat) catch {
    e => abort("\{e}")
  }
}

///|
fn pull(stream : ResultStream) -> @types.DataBatch? {
  stream.next() catch {
    e => abort("\{e}")
  }
}

///|
/// The rows of a batch array as scalars, so two deliveries can be compared
/// row by row without caring how the rows were grouped into batches.
fn scalars_of(batches : Array[@types.DataBatch]) -> Array[Array[@types.Scalar]] {
  let out : Array[Array[@types.Scalar]] = []
  for b in batches {
    let cols = b.columns()
    for r in 0..<b.row_count() {
      let row : Array[@types.Scalar] = []
      for c in 0..<cols.length() {
        row.push(cols[c].get(r))
      }
      out.push(row)
    }
  }
  out
}

///|
test "a pulled scan hands out one batch at a time and stops when closed" {
  let (cat, cells) = counting_catalog(8, 100)
  let stream = open_stream("SELECT c0 FROM t", cat)
  let first = pull(stream)
  assert_true(first is Some(_))
  assert_eq(first.unwrap().row_count(), 100)
  assert_eq(cells[1], 1) // one pull: the consumer has 100 of 800 rows
  let second = pull(stream)
  assert_true(second is Some(_))
  assert_eq(cells[1], 2)
  // the caller has what it needed; the remaining six batches are never read
  stream.close()
  assert_true(pull(stream) is None)
  assert_eq(cells[1], 2)
}

///|
test "a pulled LIMIT takes its window batch by batch and stops at the end" {
  // 250 rows over batches of 100: 100 + 100 + 50, and the last batch is short
  // because the window ends inside it. A zero-row tail is not returned.
  let (cat, cells) = counting_catalog(8, 100)
  let stream = open_stream("SELECT c0 FROM t LIMIT 250", cat)
  let chunks : Array[@types.DataBatch] = []
  while pull(stream) is Some(batch) {
    chunks.push(batch)
  }
  assert_eq(chunks.length(), 3)
  assert_eq(chunks[0].row_count(), 100)
  assert_eq(chunks[1].row_count(), 100)
  assert_eq(chunks[2].row_count(), 50)
  let rows = scalars_of(chunks)
  assert_eq(rows.length(), 250)
  assert_eq(rows[0][0], @types.Scalar::Int32(0))
  assert_eq(rows[249][0], @types.Scalar::Int32(249))
  assert_eq(cells[1], 3) // three batches read, five never touched
}

///|
test "a pulled OFFSET skips whole batches without returning them" {
  // 495 rows of offset then 5: four whole batches are dropped and the fifth
  // contributes five rows, so the consumer never sees the skipped rows.
  let (cat, cells) = counting_catalog(8, 100)
  let stream = open_stream("SELECT c0 FROM t LIMIT 5 OFFSET 495", cat)
  let batch = pull(stream).unwrap()
  assert_eq(batch.row_count(), 5)
  assert_eq(batch.columns()[0].get(0), @types.Scalar::Int32(495))
  assert_true(pull(stream) is None)
  assert_eq(cells[1], 5)
}

///|
test "an empty pulled result reads the whole table and returns nothing" {
  let (cat, cells) = counting_catalog(8, 100)
  let stream = open_stream("SELECT c0 FROM t WHERE c0 < 0", cat)
  assert_true(pull(stream) is None)
  assert_eq(cells[1], 8)
}

///|
test "pulled and collected deliveries return the same rows" {
  let shapes = [
    "SELECT c0 FROM t", "SELECT c0, c1 FROM t WHERE c0 >= 650", "SELECT c0 FROM t LIMIT 7 OFFSET 393",
    "SELECT c1, count(*) FROM t GROUP BY c1", "SELECT c0 FROM t ORDER BY c0 DESC LIMIT 4",
    "SELECT DISTINCT c1 FROM t", "SELECT c0 FROM (SELECT c0 FROM t) s LIMIT 3",
  ]
  for sql in shapes {
    let (pulled_cat, _) = counting_catalog(8, 100)
    let (collected_cat, _) = counting_catalog(8, 100)
    let stream = open_stream(sql, pulled_cat)
    let pulled : Array[@types.DataBatch] = []
    while pull(stream) is Some(batch) {
      pulled.push(batch)
    }
    let collected = run_counted(sql, collected_cat)
    assert_eq(scalars_of(pulled), scalars_of([collected.batch()]))
  }
}

///|
test "a shape that cannot stream arrives as one batch, which is the answer" {
  // An aggregate has to see every row before it produces one, so the pulled
  // delivery is the eager result: one batch, then the end.
  let (cat, cells) = counting_catalog(8, 100)
  let stream = open_stream("SELECT count(*), sum(c0) FROM t", cat)
  let batch = pull(stream).unwrap()
  assert_eq(batch.row_count(), 1)
  assert_eq(batch.columns()[0].get(0), @types.Scalar::Int64(800L))
  assert_true(pull(stream) is None)
  assert_eq(cells[1], 8)
}

///|
test "an empty answer is no batch at all when pulled, one empty batch when materialized" {
  // The batch contract says `Some` carries a live row and a zero-row batch may
  // arrive from a source. A pulled scan therefore ends at once, while an eager
  // result hands back the empty batch it computed — and the caller learns the
  // shape from `names`/`types` either way.
  let (cat, cells) = counting_catalog(8, 100)
  let pulled = open_stream("SELECT c0 FROM t WHERE c0 < 0 LIMIT 10", cat)
  assert_true(pull(pulled) is None)
  assert_true(pull(pulled) is None) // still the end, not an error
  assert_eq(cells[1], 8) // the table was read to know it is empty
  let (derived_cat, _) = counting_catalog(8, 100)
  let materialized = open_stream(
    "SELECT c0 FROM (SELECT c0 FROM t WHERE c0 < 0) s", derived_cat,
  )
  let empty = pull(materialized).unwrap()
  assert_eq(empty.row_count(), 0)
  assert_true(pull(materialized) is None)
}

///|
/// A lazy table whose second batch fails to decode. The failure matters
/// because a batch has already been handed out when it arrives: the stream
/// must end there rather than pretend the scan can be resumed.
priv struct FailingStream {
  batches : Array[@types.DataBatch]
  mut pos : Int32
}

///|
impl @catalog.BatchStream for FailingStream with fn next(self) -> @types.DataBatch? raise @types.SqlError {
  if self.pos >= self.batches.length() {
    None
  } else if self.pos == 1 {
    raise @types.SqlError::Execute("boom: the second batch could not be read")
  } else {
    let batch = self.batches[self.pos]
    self.pos = self.pos + 1
    Some(batch)
  }
}

///|
priv struct FailingSource {
  batches : Array[@types.DataBatch]
}

///|
impl @catalog.ScanSource for FailingSource with fn open(
  self,
  request : @catalog.ScanRequest,
) -> &@catalog.BatchStream raise @types.SqlError {
  let kept : Array[@types.DataBatch] = []
  for batch in self.batches {
    let cols : Array[@types.ColumnVector] = []
    for c in request.projection {
      cols.push(batch.columns()[c])
    }
    kept.push(@types.DataBatch::new(cols, batch.row_count()))
  }
  FailingStream::{ batches: kept, pos: 0, }
}

///|
impl @catalog.ScanSource for FailingSource with fn plan(
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
fn failing_catalog() -> @catalog.Catalog {
  let schema : @catalog.TableSchema = {
    table: "f",
    columns: [{ name: "c0", dtype: @types.Int32, }],
  }
  let source : FailingSource = { batches: counted_batches(3, 10), }
  let cat = @catalog.Catalog::new()
  cat.register(@catalog.TableEntry::from_source(schema, source))
  cat
}

///|
/// The error message of a pull that is expected to raise, aborting when it
/// does not: `catch` here keeps the abort out of the expression's type.
fn pull_error(stream : ResultStream) -> String {
  let mut message = ""
  let got = stream.next() catch {
    e => {
      message = e.to_string()
      None
    }
  }
  ignore(got) // only the message matters; a `None` here means the pull was the end
  if message == "" {
    abort("expected the pull to fail")
  }
  message
}

///|
test "a failing pull ends the stream, and closing it stays safe" {
  let stream = open_stream("SELECT c0 FROM f", failing_catalog())
  let first = pull(stream).unwrap()
  assert_eq(first.row_count(), 10) // the batch that arrived before the failure
  let message = pull_error(stream)
  assert_true(message.contains("boom"))
  // the scan's state after a partial read is not known, so the stream must not
  // offer a resumed read: it is finished, and says so
  assert_true(pull(stream) is None)
  stream.close()
  assert_true(pull(stream) is None)
}

///|
/// Open a stream and throw it away, so a caller can observe whether opening it
/// raised without holding on to a result type.
fn open_and_drop(
  sql : String,
  cat : @catalog.Catalog,
) -> Unit raise @types.SqlError {
  let stream = run_select_stream(sql, cat)
  stream.close()
}

///|
test "a bind error arrives at the call, not at the first pulled batch" {
  // A LIMIT that would stop the scan early must not delay a type error to the
  // tail it never reads: the query is bound before any row is pulled.
  let (cat, cells) = counting_catalog(8, 100)
  let mut message = ""
  open_and_drop("SELECT nope FROM t LIMIT 1", cat) catch {
    e => message = e.to_string()
  }
  assert_true(message.contains("nope"))
  assert_eq(cells[1], 0) // nothing was read to find out
}
