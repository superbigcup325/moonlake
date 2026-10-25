// Whitebox tests for pulling a two-table join instead of collecting it. The
// build side has to be resident — a probe row has to find its matches — so what
// is under test is the other half of the promise: the probe side arrives a
// batch at a time, the output leaves in batches, and a caller that stops early
// stops the probe. Every test compares the streamed rows against `execute` for
// the same query, because a stream may group rows differently but may never
// return different ones.
//
// The shapes that must stay collected are pinned here too: a chain of joins, a
// RIGHT join, a SEMI/ANTI join, and anything with an ORDER BY or a GROUP BY
// above the join still yield one batch, which is what makes their absence from
// `streaming_join_source` a decision rather than an oversight.

///|
/// A lazy two-column table over in-memory batches, counting what the engine
/// asks of it: `cells` is `[opens, pulls, rows, projection width]`.
priv struct JoinTableSource {
  batches : Array[@types.DataBatch]
  cells : Array[Int32]
}

///|
priv struct JoinTableStream {
  batches : Array[@types.DataBatch]
  cells : Array[Int32]
  mut pos : Int32
}

///|
impl @catalog.BatchStream for JoinTableStream with fn next(self) -> @types.DataBatch? raise @types.SqlError {
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
impl @catalog.ScanSource for JoinTableSource with fn open(
  self,
  request : @catalog.ScanRequest,
) -> &@catalog.BatchStream raise @types.SqlError {
  self.cells.set(0, self.cells[0] + 1)
  self.cells.set(3, request.projection.length())
  let kept : Array[@types.DataBatch] = []
  for batch in self.batches {
    let cols : Array[@types.ColumnVector] = []
    for c in request.projection {
      cols.push(batch.columns()[c])
    }
    kept.push(@types.DataBatch::new(cols, batch.row_count()))
  }
  JoinTableStream::{ batches: kept, cells: self.cells, pos: 0, }
}

///|
impl @catalog.ScanSource for JoinTableSource with fn plan(
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
/// `Some x` becomes the int32 scalar `x`, `None` a NULL: the fixtures below are
/// written as key/value lists and turned into columns here.
fn join_vals(xs : Array[Int32?]) -> Array[@types.Scalar] {
  let out : Array[@types.Scalar] = []
  for x in xs {
    out.push(
      match x {
        Some(v) => @types.Int32(v)
        None => @types.Null
      },
    )
  }
  out
}

///|
/// Two int32 columns split into batches of `per_batch` rows.
fn join_rows(
  keys : Array[@types.Scalar],
  vals : Array[@types.Scalar],
  per_batch : Int32,
) -> Array[@types.DataBatch] {
  let n = keys.length()
  let out : Array[@types.DataBatch] = []
  let mut at = 0
  while at < n {
    let mut len = per_batch
    if at + len > n {
      len = n - at
    }
    let k = @types.ColumnVector::make(@types.Int32, len)
    let v = @types.ColumnVector::make(@types.Int32, len)
    for r in 0..<len {
      k.set(r, keys[at + r])
      v.set(r, vals[at + r])
    }
    out.push(@types.DataBatch::new([k, v], len))
    at += len
  }
  out
}

///|
/// A lazy table `name` with `k`/`v` int32 columns, plus its counters.
fn join_entry(
  name : String,
  keys : Array[@types.Scalar],
  vals : Array[@types.Scalar],
  per_batch : Int32,
) -> (@catalog.TableEntry, Array[Int32]) {
  let cells : Array[Int32] = [0, 0, 0, 0]
  let schema : @catalog.TableSchema = {
    table: name,
    columns: [
      { name: "k", dtype: @types.Int32, },
      { name: "v", dtype: @types.Int32, },
    ],
  }
  let source : JoinTableSource = {
    batches: join_rows(keys, vals, per_batch),
    cells,
  }
  (@catalog.TableEntry::from_source(schema, source), cells)
}

///|
fn join_keyed(
  name : String,
  keys : Array[Int32?],
  vals : Array[Int32?],
  per_batch : Int32,
  cat : @catalog.Catalog,
) -> Array[Int32] {
  let (entry, cells) = join_entry(
    name,
    join_vals(keys),
    join_vals(vals),
    per_batch,
  )
  cat.register(entry)
  cells
}

///|
/// The small fixture every differential test uses: `l` has a duplicate key, a
/// NULL key and a key with no partner; `r` has duplicates of its own, a NULL
/// key and a key that no probe row carries.
fn join_pair_catalog() -> @catalog.Catalog {
  let cat = @catalog.Catalog::new()
  // l: k = 1,1,2,3,NULL ; v = 10,11,20,30,40
  join_keyed(
    "l",
    [Some(1), Some(1), Some(2), Some(3), None],
    [Some(10), Some(11), Some(20), Some(30), Some(40)],
    2,
    cat,
  )
  |> ignore
  // r: k = 1,1,1,2,NULL,9 ; v = 100,101,102,200,500,900
  join_keyed(
    "r",
    [Some(1), Some(1), Some(1), Some(2), None, Some(9)],
    [Some(100), Some(101), Some(102), Some(200), Some(500), Some(900)],
    4,
    cat,
  )
  |> ignore
  cat
}

///|
/// Rows rendered one per string and sorted, so two deliveries can be compared
/// as multisets: batch grouping and join order cannot make them differ.
fn join_sorted_rows(rows : Array[Array[@types.Scalar]]) -> Array[String] {
  let text : Array[String] = []
  for row in rows {
    let mut s = ""
    for v in row {
      s = s + v.to_string() + "|"
    }
    text.push(s)
  }
  text.sort()
  text
}

///|
fn join_collect(
  sql : String,
  cat : @catalog.Catalog,
) -> Array[Array[@types.Scalar]] {
  let r = run_select(sql, cat) catch { e => abort("\{e}") }
  scalars_of([r.batch()])
}

///|
/// The streamed rows, plus how many batches they arrived in.
fn join_stream(
  sql : String,
  cat : @catalog.Catalog,
) -> (Array[Array[@types.Scalar]], Array[Int32]) {
  let stream = open_stream(sql, cat)
  let chunks : Array[@types.DataBatch] = []
  let sizes : Array[Int32] = []
  while pull(stream) is Some(batch) {
    chunks.push(batch)
    sizes.push(batch.row_count())
  }
  stream.close()
  (scalars_of(chunks), sizes)
}

///|
/// Compare the streamed answer with the collected one for one query: the rows
/// are the same multiset, and no streamed batch is empty or over the cap.
fn join_agrees(sql : String, cat : @catalog.Catalog) -> Unit raise {
  let (streamed, sizes) = join_stream(sql, cat)
  let collected = join_collect(sql, cat)
  assert_eq(streamed.length(), collected.length())
  assert_eq(join_sorted_rows(streamed), join_sorted_rows(collected))
  for n in sizes {
    assert_true(n > 0)
    assert_true(n <= 4096)
  }
}

///|
test "streamed join agrees with the collected one on every kind" {
  let shapes = [
    "select l.k, l.v, r.v from l join r on l.k = r.k", "select l.k, l.v, r.v from l left join r on l.k = r.k",
    "select l.k, l.v, r.v from l full join r on l.k = r.k", "select l.k, l.v, r.v from l right join r on l.k = r.k",
    "select l.k, l.v from l semi join r on l.k = r.k", "select l.k, l.v from l anti join r on l.k = r.k",
    "select l.k, l.v, r.v from l join r on l.k = r.k and l.v > r.v", "select l.k, l.v, r.v from l left join r on l.k = r.k and l.v > r.v",
    "select l.k, l.v, r.v from l full join r on l.k = r.k and r.v > l.v", "select l.k, r.k from l join r on l.k = r.k where r.v > 100",
    "select l.k, r.v from l join r on l.k = r.k where l.k > 1", "select * from l join r on l.k = r.k",
  ]
  for sql in shapes {
    join_agrees(sql, join_pair_catalog())
  }
}

///|
test "a duplicated key splits the output into batches under the size cap" {
  // 5000 probe rows all sharing one key against a build side holding it: the
  // joined rows for a single probe batch exceed the output cap, so the cursor
  // must slice them and never hand out an empty or oversized batch
  let keys : Array[Int32?] = []
  let vals : Array[Int32?] = []
  for i in 0..<5000 {
    keys.push(Some(1))
    vals.push(Some(i))
  }
  let cat = @catalog.Catalog::new()
  join_keyed("l", keys, vals, 4096, cat) |> ignore
  join_keyed("r", [Some(1), Some(1)], [Some(100), Some(101)], 4, cat) |> ignore
  let (rows, sizes) = join_stream(
    "select l.v, r.v from l join r on l.k = r.k", cat,
  )
  assert_eq(rows.length(), 10000)
  assert_eq(sizes.length(), 3)
  assert_eq(sizes[0], 4096)
  assert_eq(sizes[1], 4096)
  assert_eq(sizes[2], 10000 - 8192)
}

///|
test "duplicate keys on both sides cross-multiply" {
  let cat = @catalog.Catalog::new()
  join_keyed("l", [Some(7), Some(7)], [Some(1), Some(2)], 4, cat) |> ignore
  join_keyed(
    "r",
    [Some(7), Some(7), Some(7)],
    [Some(10), Some(20), Some(30)],
    4,
    cat,
  )
  |> ignore
  let (rows, _) = join_stream("select l.v, r.v from l join r on l.k = r.k", cat)
  assert_eq(rows.length(), 6)
}

///|
test "an empty build side leaves an inner join with nothing" {
  let cat = @catalog.Catalog::new()
  join_keyed("l", [Some(1), Some(2)], [Some(10), Some(20)], 4, cat) |> ignore
  join_keyed("r", [], [], 4, cat) |> ignore
  let (rows, sizes) = join_stream(
    "select l.k, r.v from l join r on l.k = r.k", cat,
  )
  assert_eq(rows.length(), 0)
  assert_eq(sizes.length(), 0)
  // LEFT keeps every probe row with a NULL right side
  let (rows, sizes) = join_stream(
    "select l.k, r.v from l left join r on l.k = r.k", cat,
  )
  assert_eq(rows.length(), 2)
  assert_eq(sizes.length(), 1)
  assert_true(rows[0][1] is @types.Null)
  // FULL without a build side is just the LEFT answer
  let (rows, _) = join_stream(
    "select l.k, r.v from l full join r on l.k = r.k", cat,
  )
  assert_eq(rows.length(), 2)
}

///|
test "an empty probe side still emits a FULL tail once" {
  let cat = @catalog.Catalog::new()
  join_keyed("l", [], [], 4, cat) |> ignore
  join_keyed("r", [Some(1), Some(2)], [Some(10), Some(20)], 4, cat) |> ignore
  let (rows, sizes) = join_stream(
    "select l.k, r.v from l full join r on l.k = r.k", cat,
  )
  assert_eq(rows.length(), 2)
  assert_eq(sizes.length(), 1)
  assert_true(rows[0][0] is @types.Null)
  // INNER still has nothing, and the build side never becomes a row
  let (rows, sizes) = join_stream(
    "select l.k, r.v from l join r on l.k = r.k", cat,
  )
  assert_eq(rows.length(), 0)
  assert_eq(sizes.length(), 0)
}

///|
test "NULL keys match nothing and LEFT keeps the probe row" {
  let cat = @catalog.Catalog::new()
  join_keyed("l", [None, Some(1)], [Some(10), Some(20)], 4, cat) |> ignore
  join_keyed("r", [None, Some(1)], [Some(100), Some(200)], 4, cat) |> ignore
  let (rows, _) = join_stream("select l.v, r.v from l join r on l.k = r.k", cat)
  assert_eq(rows.length(), 1)
  let (rows, _) = join_stream(
    "select l.v, r.v from l left join r on l.k = r.k", cat,
  )
  assert_eq(rows.length(), 2)
  // the NULL-key probe row survives, the NULL-key build row does not
  let (rows, _) = join_stream(
    "select l.v, r.v from l full join r on l.k = r.k", cat,
  )
  assert_eq(rows.length(), 3)
}

///|
test "a residual decides pairs, and LEFT keeps a row with no passing pair" {
  let cat = @catalog.Catalog::new()
  join_keyed("l", [Some(1), Some(1)], [Some(10), Some(50)], 4, cat) |> ignore
  join_keyed("r", [Some(1), Some(1)], [Some(20), Some(30)], 4, cat) |> ignore
  // on the same key, only the 50 beats both build rows; the 10 beats neither
  let (rows, _) = join_stream(
    "select l.v, r.v from l join r on l.k = r.k and l.v > r.v", cat,
  )
  assert_eq(rows.length(), 2)
  let (rows, _) = join_stream(
    "select l.v, r.v from l left join r on l.k = r.k and l.v > r.v", cat,
  )
  assert_eq(rows.length(), 3)
}

///|
test "closing after one batch stops the probe side" {
  let keys : Array[Int32?] = []
  let vals : Array[Int32?] = []
  for i in 0..<800 {
    keys.push(Some(1))
    vals.push(Some(i))
  }
  let cat = @catalog.Catalog::new()
  join_keyed("l", keys, vals, 100, cat) |> ignore
  let cells = join_keyed("r", [Some(1)], [Some(7)], 4, cat)
  let stream = open_stream("select l.v, r.v from l join r on l.k = r.k", cat)
  let first = pull(stream)
  assert_true(first is Some(_))
  stream.close()
  assert_true(pull(stream) is None)
  // 800 probe rows in batches of 100: one probe batch fills the first output
  // batch, so closing after it cannot have read the other seven
  assert_eq(cells[1], 1)
}

///|
test "a LIMIT over a join stops probing when its window fills" {
  let keys : Array[Int32?] = []
  let vals : Array[Int32?] = []
  for i in 0..<1000 {
    keys.push(Some(1))
    vals.push(Some(i))
  }
  let cat = @catalog.Catalog::new()
  let cells = join_keyed("l", keys, vals, 10, cat)
  join_keyed("r", [Some(1)], [Some(7)], 4, cat) |> ignore
  let (rows, sizes) = join_stream(
    "select l.v, r.v from l join r on l.k = r.k limit 3", cat,
  )
  assert_eq(rows.length(), 3)
  assert_eq(sizes.length(), 1)
  // 100 probe batches hold 1000 rows; three rows do not need all of them
  assert_true(cells[1] < 100)
  assert_true(cells[1] >= 1)
  // OFFSET is carried across batches the same way
  let (rows, _) = join_stream(
    "select l.v, r.v from l join r on l.k = r.k limit 2 offset 998", cat,
  )
  assert_eq(rows.length(), 2)
}

///|
test "the probe side is filtered before the join, the deferred one after" {
  let cat = @catalog.Catalog::new()
  join_keyed(
    "l",
    [Some(1), Some(2), Some(3)],
    [Some(10), Some(20), Some(30)],
    4,
    cat,
  )
  |> ignore
  join_keyed(
    "r",
    [Some(1), Some(2), Some(3)],
    [Some(100), Some(200), Some(300)],
    4,
    cat,
  )
  |> ignore
  // a build filter on the probe table: k > 1 leaves two rows
  let (rows, _) = join_stream(
    "select l.k, r.v from l join r on l.k = r.k where l.k > 1", cat,
  )
  assert_eq(rows.length(), 2)
  assert_eq(rows[0][0], @types.Int32(2))
  // a deferred predicate only the joined layout can evaluate
  let (rows, _) = join_stream(
    "select l.k, r.v from l join r on l.k = r.k where r.v > 150", cat,
  )
  assert_eq(rows.length(), 2)
  // the same query with an ORDER BY above it goes back to the collected path
  let (rows, sizes) = join_stream(
    "select l.k, r.v from l join r on l.k = r.k where l.k > 1 order by l.k desc",
    cat,
  )
  assert_eq(rows.length(), 2)
  assert_eq(sizes.length(), 1)
  assert_eq(rows[0][0], @types.Int32(3))
}

///|
test "shapes that are not streamed return one batch and the same rows" {
  let cat = join_pair_catalog()
  let shapes = [
    // a chain of joins has a join as its probe side
    "select a.k from l join r on l.k = r.k join l as a on a.k = r.k",
    // RIGHT is a swapped LEFT: its build side is the probe table
     "select l.k, r.v from l right join r on l.k = r.k",
    // an aggregate, a sort, a window and DISTINCT all sit above the join
     "select count(*) from l join r on l.k = r.k", "select l.k, r.v from l join r on l.k = r.k order by r.v",
    "select distinct l.k from l join r on l.k = r.k", "select l.k, rank() over (order by l.k) from l join r on l.k = r.k",
    // a keyless join is a cross join, which the budget path refuses by design
     "select l.k, r.v from l cross join r",
  ]
  for sql in shapes {
    let (streamed, sizes) = join_stream(sql, cat)
    assert_true(
      sizes.length() == 1,
      msg="\{sql} returned \{sizes.length()} batches",
    )
    let collected = join_collect(sql, cat)
    assert_eq(streamed.length(), collected.length())
  }
}

///|
test "a semi/anti join is decorrelated into a scan, and still agrees" {
  // EXISTS / IN become a synthetic semi or anti table joined from the probe
  // side, so what reaches the executor is a single-table scan with a deferred
  // filter: it streams as a scan, not as a join, and that is why its batch
  // count is not pinned to one here
  let cat = join_pair_catalog()
  join_agrees("select l.k, l.v from l semi join r on l.k = r.k", cat)
  join_agrees("select l.k, l.v from l anti join r on l.k = r.k", cat)
  join_agrees("select l.k from l where l.k in (select r.k from r)", cat)
  join_agrees("select l.k from l where l.k not in (select r.k from r)", cat)
}

///|
test "a two-table join opens each table once and reads the build side whole" {
  let cat = @catalog.Catalog::new()
  let lc = join_keyed("l", [Some(1), Some(2)], [Some(10), Some(20)], 4, cat)
  let rc = join_keyed("r", [Some(1), Some(2)], [Some(100), Some(200)], 4, cat)
  let (rows, _) = join_stream("select l.v, r.v from l join r on l.k = r.k", cat)
  assert_eq(rows.length(), 2)
  assert_eq(lc[0], 1) // one open on the probe side
  assert_eq(rc[0], 1) // one open on the build side
  assert_eq(rc[2], 2) // the build side is read whole, before the probe starts
}

///|
test "the collected path is unchanged: one batch and the same counters" {
  let cat = join_pair_catalog()
  let sql = "select l.k, r.v from l join r on l.k = r.k"
  let direct = run_select(sql, cat) catch { e => abort("\{e}") }
  assert_eq(direct.batch().row_count(), 7)
  // ANALYZE runs the collected path, so the stream must not have replaced it
  let text = explain_analyze(sql, cat) catch { e => abort("\{e}") }
  assert_true(text.contains("scan l: 5"))
  assert_true(text.contains("scan r: 6"))
  assert_true(text.contains("joins: 7"))
  assert_true(text.contains("result: 7"))
}
