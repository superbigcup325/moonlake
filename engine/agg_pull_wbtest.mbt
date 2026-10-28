// Whitebox tests for feeding an aggregate from the scan instead of from a
// collected input.
//
// What a test can see is the rows a query returns and what the source was
// asked for; it cannot see the array that was not built. So the SQL half below
// pins the answers a per-batch fold has to get right — a group whose rows span
// batches, a NULL key group, a NULL aggregate input, an empty input, a DISTINCT
// aggregate, HAVING — and checks the counters the aggregate reports against the
// same query's collected run. The pull half is the one that shows the batches
// arriving one at a time, filters included.
// docs/verification.md §32 carries the measurement of what that costs.

///|
/// A column built from scalars; `@types.Null` marks a null like any other.
fn agg_col(
  dtype : @types.DataType,
  vals : Array[@types.Scalar],
) -> @types.ColumnVector {
  let vec = @types.ColumnVector::make(dtype, vals.length())
  for i, v in vals {
    vec.set(i, v)
  }
  vec
}

///|
/// One batch of `agg_batches`: rows `start ..< start + 3`.
fn agg_batch(start : Int32) -> @types.DataBatch {
  let k : Array[@types.Scalar] = [
    @types.Str("a"),
    @types.Str("a"),
    @types.Str("b"),
    @types.Str("b"),
    @types.Null,
    @types.Str("c"),
    @types.Str("c"),
    @types.Str("a"),
    @types.Null,
    @types.Str("a"),
    @types.Str("c"),
    @types.Str("b"),
  ]
  let g : Array[@types.Scalar] = [
    @types.Int32(1),
    @types.Int32(1),
    @types.Int32(2),
    @types.Null,
    @types.Int32(2),
    @types.Int32(1),
    @types.Int32(1),
    @types.Null,
    @types.Null,
    @types.Int32(1),
    @types.Int32(2),
    @types.Int32(2),
  ]
  let v : Array[@types.Scalar] = [
    @types.Int32(10),
    @types.Int32(20),
    @types.Int32(30),
    @types.Int32(40),
    @types.Int32(50),
    @types.Int32(60),
    @types.Null,
    @types.Int32(70),
    @types.Null,
    @types.Int32(90),
    @types.Int32(100),
    @types.Int32(110),
  ]
  let kk : Array[@types.Scalar] = []
  let gg : Array[@types.Scalar] = []
  let vv : Array[@types.Scalar] = []
  for r in 0..<3 {
    kk.push(k[start + r])
    gg.push(g[start + r])
    vv.push(v[start + r])
  }
  @types.DataBatch::new(
    [
      agg_col(@types.Str, kk),
      agg_col(@types.Int32, gg),
      agg_col(@types.Int32, vv),
    ],
    3,
  )
}

///|
/// Four batches of three rows over three columns: `k` a string key with nulls,
/// `g` an int32 key with nulls, `v` an int32 input with a null. Keys repeat
/// across batches on purpose: a group that is complete after one batch cannot
/// tell a per-batch fold from a collected one.
fn agg_batches() -> Array[@types.DataBatch] {
  [agg_batch(0), agg_batch(3), agg_batch(6), agg_batch(9)]
}

///|
/// A lazy three-column table `t` over `agg_batches` (`counted = false`) or an
/// empty one of the same schema, plus the source's counters:
/// `[opens, pulls, rows, projection width]`.
fn agg_entry(
  batches : Array[@types.DataBatch],
) -> (@catalog.TableEntry, Array[Int32]) {
  let cells : Array[Int32] = [0, 0, 0, 0]
  let schema : @catalog.TableSchema = {
    table: "t",
    columns: [
      { name: "k", dtype: @types.Str, },
      { name: "g", dtype: @types.Int32, },
      { name: "v", dtype: @types.Int32, },
    ],
  }
  let source : CountingSource = { batches, cells, }
  (@catalog.TableEntry::from_source(schema, source), cells)
}

///|
fn agg_catalog(
  batches : Array[@types.DataBatch],
) -> (@catalog.Catalog, Array[Int32]) {
  let (entry, cells) = agg_entry(batches)
  let cat = @catalog.Catalog::new()
  cat.register(entry)
  (cat, cells)
}

///|
fn agg_select(sql : String, cat : @catalog.Catalog) -> SelectResult {
  run_select(sql, cat) catch {
    e => abort("\{e}")
  }
}

///|
fn agg_rows(batch : @types.DataBatch) -> Array[Array[@types.Scalar]] {
  scalars_of([batch])
}

///|
/// The row whose column `col` equals `key`, in whatever order the aggregate
/// emitted its groups: a GROUP BY promises no order, so the tests must not
/// depend on one.
fn agg_row_for(
  rows : Array[Array[@types.Scalar]],
  col : Int32,
  key : @types.Scalar,
) -> Array[@types.Scalar] {
  for row in rows {
    if row[col] == key {
      return row
    }
  }
  abort("no row with the requested key")
}

///|
fn agg_error(sql : String, cat : @catalog.Catalog) -> String {
  let got = try {
    ignore(run_select(sql, cat))
    ""
  } catch {
    e => e.to_string()
  }
  if got == "" {
    abort("expected the aggregate to fail")
  }
  got
}

///|
/// The launch a query prepares, for tests that need the pull itself.
fn agg_launch(sql : String, cat : @catalog.Catalog) -> Launch {
  let opts = ExecOptions::in_memory()
  let prepared = prepare_select(
    @sql.parse_select(sql) catch {
      e => abort("\{e}")
    },
    cat,
    opts,
  ) catch {
    e => abort("\{e}")
  }
  match prepared {
    Ready(launch) => launch
    Setop(_) => abort("expected a ready launch, not a set operation")
  }
}

///|
test "an aggregate pull hands over one batch at a time" {
  // Every batch that survives the filters is handed on whole, and the count
  // the pull keeps is what the collected path reports as this table's scan.
  let (cat, _cells) = agg_catalog(agg_batches())
  let launch = agg_launch("select count(*) as n from t", cat)
  let entry = match streaming_agg_source(launch.bq, launch.sources) {
    Some(entry) => entry
    None => abort("a single-table aggregate must be fed from its scan")
  }
  let pull = input_pull(launch.bq, launch.plan, entry) catch {
    e => abort("\{e}")
  }
  let mut batches = 0
  while (pull.next() catch { e => abort("\{e}") }) is Some(batch) {
    assert_eq(batch.row_count(), 3)
    batches += 1
  }
  assert_eq(batches, 4)
  assert_eq(pull.scanned, 12L)
}

///|
test "an aggregate pull skips the batches its filters empty" {
  // A WHERE that keeps nothing in a batch must not hand an empty batch on: the
  // contract forbids it, and the fold of nothing would add nothing anyway. Only
  // the last batch holds a `v` above 90, so the first three are read and
  // dropped.
  let (cat, _cells) = agg_catalog(agg_batches())
  let launch = agg_launch("select count(*) as n from t where v > 90", cat)
  let entry = match streaming_agg_source(launch.bq, launch.sources) {
    Some(entry) => entry
    None => abort("a single-table aggregate must be fed from its scan")
  }
  let pull = input_pull(launch.bq, launch.plan, entry) catch {
    e => abort("\{e}")
  }
  let mut rows = 0
  let mut batches = 0
  while (pull.next() catch { e => abort("\{e}") }) is Some(batch) {
    rows += batch.row_count()
    batches += 1
  }
  assert_eq(batches, 1)
  assert_eq(rows, 2)
  assert_eq(pull.scanned, 2L)
}

///|
test "a string key group with a null key is folded across batches" {
  let (cat, cells) = agg_catalog(agg_batches())
  let r = agg_select(
    "select k, count(*) as n, sum(v) as s from t group by k", cat,
  )
  let rows = agg_rows(r.batch())
  assert_eq(rows.length(), 4)
  assert_eq(agg_row_for(rows, 0, @types.Str("a")), [
    @types.Str("a"),
    @types.Int64(4),
    @types.Int64(190),
  ])
  assert_eq(agg_row_for(rows, 0, @types.Str("b")), [
    @types.Str("b"),
    @types.Int64(3),
    @types.Int64(180),
  ])
  assert_eq(agg_row_for(rows, 0, @types.Str("c")), [
    @types.Str("c"),
    @types.Int64(3),
    @types.Int64(160),
  ])
  // the null key is its own group, and the null input adds nothing to the sum
  assert_eq(agg_row_for(rows, 0, @types.Null), [
    @types.Null,
    @types.Int64(2),
    @types.Int64(50),
  ])
  // one open, every batch pulled once, every row counted once
  assert_eq(cells[0], 1)
  assert_eq(cells[1], 4)
  assert_eq(cells[2], 12)
}

///|
test "an int32 key group with a null key is folded across batches" {
  let (cat, _cells) = agg_catalog(agg_batches())
  let r = agg_select(
    "select g, count(*) as n, sum(v) as s from t group by g", cat,
  )
  let rows = agg_rows(r.batch())
  assert_eq(rows.length(), 3)
  assert_eq(agg_row_for(rows, 0, @types.Int32(1)), [
    @types.Int32(1),
    @types.Int64(5),
    @types.Int64(180),
  ])
  assert_eq(agg_row_for(rows, 0, @types.Int32(2)), [
    @types.Int32(2),
    @types.Int64(4),
    @types.Int64(290),
  ])
  assert_eq(agg_row_for(rows, 0, @types.Null), [
    @types.Null,
    @types.Int64(3),
    @types.Int64(110),
  ])
}

///|
test "HAVING runs on the finished groups" {
  let (cat, _cells) = agg_catalog(agg_batches())
  let r = agg_select(
    "select k, count(*) as n from t group by k having count(*) > 2", cat,
  )
  let rows = agg_rows(r.batch())
  assert_eq(rows.length(), 3)
  assert_eq(agg_row_for(rows, 0, @types.Str("a"))[1], @types.Int64(4))
  assert_eq(agg_row_for(rows, 0, @types.Str("b"))[1], @types.Int64(3))
  assert_eq(agg_row_for(rows, 0, @types.Str("c"))[1], @types.Int64(3))
}

///|
test "a DISTINCT aggregate counts a value once across batches" {
  // `g = 1` and `g = 2` appear in several batches; the set has to outlive the
  // batch it was first seen in.
  let (cat, _cells) = agg_catalog(agg_batches())
  let r = agg_select(
    "select count(distinct g) as d, count(distinct v) as dv, sum(v) as s from t",
    cat,
  )
  assert_eq(agg_rows(r.batch()), [
    [@types.Int64(2), @types.Int64(10), @types.Int64(580)],
  ])
}

///|
test "an empty input still answers one row globally and none grouped" {
  let (cat, cells) = agg_catalog([])
  let one = agg_select("select count(*) as n, sum(v) as s from t", cat)
  assert_eq(agg_rows(one.batch()), [[@types.Int64(0), @types.Null]])
  let none = agg_select("select k, count(*) as n from t group by k", cat)
  assert_eq(agg_rows(none.batch()).length(), 0)
  assert_eq(none.batch().row_count(), 0)
  // the empty table still opened once and pulled nothing
  assert_eq(cells[0], 2)
  assert_eq(cells[1], 0)
}

///|
test "the pulled and collected aggregates report the same counters" {
  // A budgeted GROUP BY that fits its budget is aggregated from the buffered
  // batches, so the counters must not depend on whether a budget was set.
  let sql = "select k, count(*) as n from t group by k"
  let (cat1, _c1) = agg_catalog(agg_batches())
  let pulled_stats : Array[(String, Int64)] = []
  let collected_stats : Array[(String, Int64)] = []
  let (r1, r2) = (
    run_parsed(
      @sql.parse_select(sql),
      cat1,
      pulled_stats,
      ExecOptions::in_memory(),
    ) catch {
      e => abort("\{e}")
    },
    {
      let (cat2, _c2) = agg_catalog(agg_batches())
      run_parsed(@sql.parse_select(sql), cat2, collected_stats, {
        budget: 1_000_000,
        spill: None,
      }) catch {
        e => abort("\{e}")
      }
    },
  )
  assert_eq(r1.row_count(), r2.row_count())
  assert_eq(scalars_of([r1.batch()]), scalars_of([r2.batch()]))
  assert_eq(pulled_stats, collected_stats)
  assert_eq(pulled_stats, [("scan t", 12L), ("aggregate", 4L), ("result", 4L)])
}

///|
test "a source that fails mid-input fails the aggregate" {
  // A partial row would be worse than an error: the fold has seen some of the
  // input and cannot know the rest.
  let msg = agg_error("select count(*) as n from f", failing_catalog())
  assert_true(msg.contains("boom"))
}

///|
test "a global aggregate answers under a budget without a spill store" {
  // One row is one row: a global aggregate never needs partitions, so a budget
  // does not force it onto the collected path, and no store is required.
  let (cat, _cells) = agg_catalog(agg_batches())
  let r = run_select_opts("select count(*) as n from t", cat, {
    budget: 64,
    spill: None,
  }) catch {
    e => abort("\{e}")
  }
  assert_eq(agg_rows(r.batch()), [[@types.Int64(12)]])
}

///|
/// A hermetic spill store and the files it still holds.
fn agg_mem_store() -> (SpillStore, Map[Int32, Bytes]) {
  let files : Map[Int32, Bytes] = Map([])
  let next : Array[Int32] = [0]
  let store : SpillStore = {
    write: fn(b : Bytes) -> Int32 {
      let id = next[0]
      next[0] = id + 1
      files[id] = b
      id
    },
    read: fn(id : Int32) -> Bytes raise @types.SqlError {
      match files.get(id) {
        Some(b) => b
        None => raise @types.SqlError::Execute("mem store: missing \{id}")
      }
    },
    remove: fn(id : Int32) -> Unit { let _ = files.remove(id) },
  }
  (store, files)
}

///|
test "a budgeted GROUP BY folds the scan, spills and answers as the unbudgeted run" {
  let sql = "select k, g, count(*) as n, sum(v) as s, median(v) as m, count(distinct v) as d from t group by k, g"
  let (cat1, _c1) = agg_catalog(agg_batches())
  let plain = run_parsed(
    @sql.parse_select(sql),
    cat1,
    [],
    ExecOptions::in_memory(),
  ) catch {
    e => abort("\{e}")
  }
  let (cat2, _c2) = agg_catalog(agg_batches())
  let (store, files) = agg_mem_store()
  let stats : Array[(String, Int64)] = []
  let spilled = run_parsed(@sql.parse_select(sql), cat2, stats, {
    budget: 64,
    spill: Some(store),
  }) catch {
    e => abort("\{e}")
  }
  let want = agg_rows(plain.batch())
  let got = agg_rows(spilled.batch())
  assert_eq(got.length(), want.length())
  for row in got {
    assert_true(want.contains(row))
  }
  assert_eq(stats[0], ("scan t", 12L))
  assert_eq(stats.filter(fn(p) { p.0 == "spill partitions" }), [
    ("spill partitions", 2L),
  ])
  // every run the query wrote is gone when it returns
  assert_eq(files.length(), 0)
}

///|
test "a budgeted GROUP BY that overflows without a spill store is a clean error" {
  let (cat, _cells) = agg_catalog(agg_batches())
  let msg = try {
    ignore(
      run_select_opts("select k, count(*) as n from t group by k", cat, {
        budget: 64,
        spill: None,
      }),
    )
    ""
  } catch {
    e => e.to_string()
  }
  assert_true(msg.contains("provide a spill store"))
}

///|
test "a spill write that fails leaves no run behind" {
  let (base, files) = agg_mem_store()
  let writes : Array[Int32] = [0]
  let store : SpillStore = {
    write: fn(b : Bytes) -> Int32 raise @types.SqlError {
      writes[0] += 1
      if writes[0] == 2 {
        raise @types.SqlError::Execute("disk full")
      }
      (base.write)(b)
    },
    read: base.read,
    remove: base.remove,
  }
  let (cat, _cells) = agg_catalog(agg_batches())
  let msg = try {
    ignore(
      run_select_opts("select k, count(*) as n from t group by k", cat, {
        budget: 64,
        spill: Some(store),
      }),
    )
    ""
  } catch {
    e => e.to_string()
  }
  assert_true(msg.contains("disk full"))
  assert_eq(files.length(), 0)
}

///|
/// Run `sql` over `batches` unbudgeted and under a 64-byte budget with a store:
/// both row sets, the stats of the budgeted run and how many spill files it left.
fn agg_both(
  sql : String,
  batches : Array[@types.DataBatch],
) -> (
  Array[Array[@types.Scalar]],
  Array[Array[@types.Scalar]],
  Array[(String, Int64)],
  Int32,
) {
  let (cat1, _c1) = agg_catalog(batches)
  let plain = run_parsed(
    @sql.parse_select(sql),
    cat1,
    [],
    ExecOptions::in_memory(),
  ) catch {
    e => abort("\{e}")
  }
  let (cat2, _c2) = agg_catalog(batches)
  let (store, files) = agg_mem_store()
  let stats : Array[(String, Int64)] = []
  let spilled = run_parsed(@sql.parse_select(sql), cat2, stats, {
    budget: 64,
    spill: Some(store),
  }) catch {
    e => abort("\{e}")
  }
  (agg_rows(plain.batch()), agg_rows(spilled.batch()), stats, files.length())
}

///|
test "a budgeted GROUP BY over an empty input answers no rows and writes nothing" {
  let (want, got, stats, left) = agg_both(
    "select k, count(*) as n from t group by k",
    [],
  )
  assert_eq(want.length(), 0)
  assert_eq(got.length(), 0)
  assert_eq(left, 0)
  assert_true(stats.filter(fn(p) { p.0 == "spill partitions" }).is_empty())
}

///|
test "a budgeted GROUP BY applies HAVING to the finished groups after spilling" {
  // only group 'a' has more than three rows, and its rows arrive in all four
  // batches, so the count is only right if every partition folded them all
  let (want, got, stats, left) = agg_both(
    "select k, count(*) as n from t group by k having count(*) > 3",
    agg_batches(),
  )
  assert_eq(want.length(), 1)
  assert_eq(got, want)
  assert_eq(stats.filter(fn(p) { p.0 == "spill partitions" }).length(), 1)
  assert_eq(left, 0)
}

///|
test "a budgeted GROUP BY keeps duplicate keys of a multi-column key together" {
  let (want, got, stats, left) = agg_both(
    "select g, k, count(*) as n, sum(v) as s, min(v) as lo, max(v) as hi from t group by g, k",
    agg_batches(),
  )
  assert_true(want.length() > 4)
  assert_eq(got.length(), want.length())
  for row in got {
    assert_true(want.contains(row))
  }
  assert_eq(stats.filter(fn(p) { p.0 == "spill partitions" }).length(), 1)
  assert_eq(left, 0)
}

///|
test "a spilled GROUP BY reports its buffered and spilled byte estimates" {
  let (cat, _cells) = agg_catalog(agg_batches())
  let (store, _files) = agg_mem_store()
  let stats : Array[(String, Int64)] = []
  let _ = run_parsed(
    @sql.parse_select("select k, count(*) as n from t group by k"),
    cat,
    stats,
    { budget: 64, spill: Some(store), },
  ) catch {
    e => abort("\{e}")
  }
  let peak = stats.filter(fn(p) { p.0 == "buffered bytes peak (estimated)" })
  let largest = stats.filter(fn(p) {
    p.0 == "largest partition spilled (estimated)"
  })
  assert_eq(peak.length(), 1)
  assert_eq(largest.length(), 1)
  // the pull overflowed, so more than the budget was held at once
  assert_true(peak[0].1 > 64L)
  assert_true(largest[0].1 > 0L)
  // one partition cannot have written more than the whole input
  assert_true(largest[0].1 <= batches_bytes(agg_batches()).to_int64())
}

///|
test "an ORDER BY over a pulled aggregate sorts the finished groups" {
  // E6b's follow-up widened this predicate: an ordered aggregate is fed from the
  // scan the same way, and the sort runs once the fold ends. The fixture's four
  // groups sum to 190, 180, 160 and 50, so descending order is unambiguous.
  let (cat, _cells) = agg_catalog(agg_batches())
  let sql = "select k, sum(v) as s from t group by k order by s desc"
  let launch = agg_launch(sql, cat)
  assert_true(streaming_agg_source(launch.bq, launch.sources) is Some(_))
  let rows = agg_rows(agg_select(sql, cat).batch())
  assert_eq(rows[0][0].to_string(), "a")
  assert_eq(rows[0][1].to_string(), "190")
  assert_eq(rows[1][1].to_string(), "180")
  assert_eq(rows[2][1].to_string(), "160")
  assert_eq(rows[3][1].to_string(), "50")
  // the group with the NULL key is the last one, in whatever position its NULL
  // comparison puts it, and the row count is the group count
  assert_eq(rows[3][0].to_string(), "null")
  // DISTINCT still keeps the shape on the eager path: the dedupe needs every
  // projected row before it can emit one
  let ordered = "select distinct k from t group by k"
  let launch = agg_launch(ordered, cat)
  match streaming_agg_source(launch.bq, launch.sources) {
    Some(_) => abort("DISTINCT must stay on the eager path")
    None => ()
  }
}
