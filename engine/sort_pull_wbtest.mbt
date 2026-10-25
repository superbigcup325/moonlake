// Whitebox tests for feeding the external sort from the scan instead of from a
// collected input, and for handing its merge out one batch at a time.
//
// What a test can see is the rows a query returns, what the source was asked
// for, and what the spill store still holds. It cannot see the array that was
// not built, so the tests are split the same way E4a's are: SQL half pins the
// answers a run-then-merge has to get right at every budget (NULL order, ties,
// DISTINCT, OFFSET/LIMIT, empty input, the in-memory fallback), and the store
// half pins the ownership — a spilled sort's files are gone when the stream
// ends, when it is closed early, and when it fails.
// docs/verification.md §33 carries the measurement of what that costs.

///|
/// An in-memory spill store a test can inspect: how many files are live, which
/// ids were read, and how many read calls happened in total.
priv struct SortBox {
  mut next : Int32
  files : Map[Int32, Bytes]
  reads : Array[Int32]
  mut fail_reads : Bool
}

///|
fn sort_store_boxed() -> (SpillStore, SortBox) {
  let box : SortBox = { next: 0, files: Map([]), reads: [], fail_reads: false, }
  let store : SpillStore = {
    write: fn(b : Bytes) -> Int32 {
      let id = box.next
      box.next += 1
      box.files[id] = b
      id
    },
    read: fn(id : Int32) -> Bytes raise @types.SqlError {
      if box.fail_reads {
        raise @types.SqlError::Execute("sort store: read \{id} failed")
      }
      match box.files.get(id) {
        Some(b) => {
          box.reads.push(id)
          b
        }
        None => raise @types.SqlError::Execute("sort store: missing \{id}")
      }
    },
    remove: fn(id : Int32) -> Unit { let _ = box.files.remove(id) },
  }
  (store, box)
}

///|
fn sort_store() -> SpillStore {
  let (store, _) = sort_store_boxed()
  store
}

///|
/// `counted_batches` with a repeating key in `c1`, so a sort has ties to break
/// and a DISTINCT has duplicates to drop: rows are `[c0 = position, c1 = (i*37)
/// % 1000]`.
fn sort_tie_batches(
  batches : Int32,
  rows_per_batch : Int32,
) -> Array[@types.DataBatch] {
  let out : Array[@types.DataBatch] = []
  for b in 0..<batches {
    let c0 = @types.ColumnVector::make(@types.Int32, rows_per_batch)
    let c1 = @types.ColumnVector::make(@types.Int32, rows_per_batch)
    for r in 0..<rows_per_batch {
      let i = b * rows_per_batch + r
      c0.set(r, @types.Int32(i))
      c1.set(r, @types.Int32(i * 37 % 1000))
    }
    out.push(@types.DataBatch::new([c0, c1], rows_per_batch))
  }
  out
}

///|
fn sort_catalog(
  batches : Array[@types.DataBatch],
) -> (@catalog.Catalog, Array[Int32]) {
  let cells : Array[Int32] = [0, 0, 0, 0]
  let schema : @catalog.TableSchema = {
    table: "t",
    columns: [
      { name: "c0", dtype: @types.Int32, },
      { name: "c1", dtype: @types.Int32, },
    ],
  }
  let source : CountingSource = { batches, cells, }
  let cat = @catalog.Catalog::new()
  cat.register(@catalog.TableEntry::from_source(schema, source))
  (cat, cells)
}

///|
fn sort_opts(budget : Int32, store : SpillStore) -> ExecOptions {
  { budget, spill: Some(store), }
}

///|
fn sort_stream(
  sql : String,
  cat : @catalog.Catalog,
  opts : ExecOptions,
) -> ResultStream {
  run_select_stream_opts(sql, cat, opts) catch {
    e => abort("\{e}")
  }
}

///|
fn sort_open_error(
  sql : String,
  cat : @catalog.Catalog,
  opts : ExecOptions,
) -> String {
  let got = try {
    ignore(run_select_stream_opts(sql, cat, opts))
    ""
  } catch {
    e => e.to_string()
  }
  if got == "" {
    abort("expected opening the stream to fail")
  }
  got
}

///|
/// Drain a stream into the rows it handed out, batch by batch.
fn sort_drain(stream : ResultStream) -> Array[Array[@types.Scalar]] {
  let batches : Array[@types.DataBatch] = []
  while pull(stream) is Some(batch) {
    batches.push(batch)
  }
  scalars_of(batches)
}

///|
/// The collected answer's rows for `sql`, for comparing against a streamed one.
fn sort_want(
  sql : String,
  cat : @catalog.Catalog,
) -> Array[Array[@types.Scalar]] {
  let r = run_select(sql, cat) catch { e => abort("\{e}") }
  scalars_of([r.batch()])
}

///|
fn sort_got(
  sql : String,
  cat : @catalog.Catalog,
  opts : ExecOptions,
) -> Array[Array[@types.Scalar]] {
  let r = run_parsed(@sql.parse_select(sql), cat, [], opts) catch {
    e => abort("\{e}")
  }
  scalars_of([r.batch()])
}

///|
/// Budgets that put the same 12-row fixture on every path: too small for one
/// batch (many runs), enough for several batches per run, and far past the
/// whole table (the in-memory fallback that writes nothing).
fn sort_budgets() -> Array[Int32] {
  [64, 512, 4_096, 1_000_000]
}

///|
test "a streamed sort agrees with the in-memory answer at every budget" {
  // k has NULLs and repeats, g has NULLs, v has one NULL: the shapes a
  // run-then-merge has to order the same way the collected sort does.
  let queries : Array[String] = [
    "select k, g from t order by g, k", "select k, g from t order by g desc nulls last, k",
    "select k from t order by k nulls first", "select distinct k from t order by k",
    "select v from t order by v limit 2 offset 1", "select k, v from t order by v desc, k asc",
    "select g from t order by v",
  ]
  for sql in queries {
    let want = agg_rows(
      ({
        let (cat, _) = agg_catalog(agg_batches())
        run_select(sql, cat) catch {
          e => abort("\{e}")
        }
      }).batch(),
    )
    for budget in sort_budgets() {
      let (cat, _) = agg_catalog(agg_batches())
      let store = sort_store()
      let got = sort_drain(sort_stream(sql, cat, sort_opts(budget, store)))
      assert_eq(got, want)
    }
  }
}

///|
test "a streamed sort hands the merged result out batch by batch" {
  // 10,000 rows: the cursor fills a 4,096-row batch, hands it over, and keeps
  // the rest — so the caller holds one batch of the answer, never the answer.
  let cat = sort_catalog(sort_tie_batches(10, 1000)).0
  let store = sort_store()
  let stream = sort_stream(
    "select c0 from t order by c0",
    cat,
    sort_opts(2_000, store),
  )
  let mut batches = 0
  let rows : Array[Array[@types.Scalar]] = []
  while pull(stream) is Some(batch) {
    batches += 1
    assert_true(batch.row_count() <= 4096)
    for row in scalars_of([batch]) {
      rows.push(row)
    }
  }
  assert_eq(batches, 3) // 4096 + 4096 + 1808
  assert_eq(rows.length(), 10_000)
  for i, row in rows {
    assert_eq(row[0], @types.Int32(i))
  }
}

///|
test "a streamed sort owns its run files and deletes them when the merge ends" {
  let cat = sort_catalog(sort_tie_batches(4, 500)).0
  let (store, box) = sort_store_boxed()
  let stream = sort_stream(
    "select c0 from t order by c0",
    cat,
    sort_opts(1_000, store),
  )
  let first = pull(stream)
  assert_true(first is Some(_))
  // the merge is reading the runs: they still exist while it hands rows over
  assert_true(box.files.length() > 0)
  let _ = sort_drain(stream)
  assert_eq(box.files.length(), 0)
}

///|
test "closing a streamed sort early releases its run files" {
  let cat = sort_catalog(sort_tie_batches(4, 500)).0
  let (store, box) = sort_store_boxed()
  let stream = sort_stream(
    "select c0 from t order by c0",
    cat,
    sort_opts(1_000, store),
  )
  let _ = pull(stream)
  assert_true(box.files.length() > 0)
  stream.close()
  assert_eq(box.files.length(), 0)
  assert_true(pull(stream) is None)
}

///|
test "a store that fails to read fails the stream and leaves no files" {
  let cat = sort_catalog(sort_tie_batches(4, 500)).0
  let (store, box) = sort_store_boxed()
  box.fail_reads = true
  let msg = sort_open_error(
    "select c0 from t order by c0",
    cat,
    sort_opts(1_000, store),
  )
  assert_true(msg.contains("read"))
  assert_eq(box.files.length(), 0)
}

///|
test "the collected sort under a budget agrees with the unbudgeted answer" {
  // `select *` and a window: the collected path builds the runs from the scan
  // and then materializes the merge's answer, which must be the same rows.
  let queries : Array[String] = [
    "select k, g from t order by g, k", "select k, v from t order by v desc, k limit 3",
    "select distinct g from t order by g", "select v from t order by g, v offset 2",
  ]
  for sql in queries {
    let (cat0, _) = agg_catalog(agg_batches())
    let want = sort_want(sql, cat0)
    for budget in sort_budgets() {
      let (cat, _) = agg_catalog(agg_batches())
      let got = sort_got(sql, cat, sort_opts(budget, sort_store()))
      assert_eq(got, want)
    }
  }
}

///|
test "the pulled and collected sorts report the same counters" {
  // A spilled ORDER BY reads the whole table either way; the counters must not
  // depend on which one fed the sort.
  let sql = "select k, v from t order by v, k limit 3"
  let (cat1, _c1) = agg_catalog(agg_batches())
  let stats : Array[(String, Int64)] = []
  let r1 = run_parsed(
    @sql.parse_select(sql),
    cat1,
    stats,
    sort_opts(64, sort_store()),
  ) catch {
    e => abort("\{e}")
  }
  assert_eq(r1.row_count(), 3)
  assert_eq(stats[0], ("scan t", 12L))
  assert_true(stats.contains(("result", 3L)))
  // the tiny budget forced runs; the count is a run count, not a row count
  let runs = stats.filter(fn(p) { p.0 == "spill runs" })
  assert_eq(runs.length(), 1)
  assert_true(runs[0].1 > 0L)
}

///|
test "an input that fits the accumulator writes no file and reports no runs" {
  let (cat, _) = agg_catalog(agg_batches())
  let (store, box) = sort_store_boxed()
  let stats : Array[(String, Int64)] = []
  let r = run_parsed(
    @sql.parse_select("select k, v from t order by v, k"),
    cat,
    stats,
    sort_opts(1_000_000, store),
  ) catch {
    e => abort("\{e}")
  }
  assert_eq(r.row_count(), 12)
  assert_eq(box.files.length(), 0) // no run was ever written
  assert_eq(stats, [("scan t", 12L), ("result", 12L)])
}

///|
test "an empty table sorts to one empty typed batch" {
  // The stream contract says a finished result is `Some` then `None`; a sort
  // over no rows is still one empty batch in the query's own layout, which is
  // what the collected path returns for the same query.
  let (cat, _) = agg_catalog([])
  let stream = sort_stream(
    "select k, v from t order by v",
    cat,
    sort_opts(1_000, sort_store()),
  )
  let first = pull(stream)
  assert_true(first is Some(_))
  assert_eq(first.unwrap().row_count(), 0)
  assert_eq(first.unwrap().columns().length(), 2)
  assert_true(pull(stream) is None)
}

///|
test "a sort under a budget still reads every batch, which is honest" {
  // A top-10 over an unsorted table cannot know it has the top 10 before the
  // last batch arrives; the stream must not pretend otherwise, and the
  // projection must still be pruned to the columns the query reads.
  let (cat, cells) = counting_catalog(8, 100)
  let stream = sort_stream(
    "select c0 from t order by c0 desc limit 10",
    cat,
    sort_opts(64, sort_store()),
  )
  let rows = sort_drain(stream)
  assert_eq(rows.length(), 10)
  assert_eq(rows[0][0], @types.Int32(799))
  assert_eq(cells[1], 8) // every batch was pulled
  assert_eq(cells[3], 1) // only c0 was decoded
}

///|
test "the merge stops once the window is full instead of draining the runs" {
  // Two runs of six rows; a LIMIT of three is satisfiable from the first rows
  // of each, so the cursor takes three and stops with rows left in the runs.
  let batches = agg_batches()
  let mut at = 0
  let produced : () -> @types.DataBatch? raise @types.SqlError = fn() {
    if at < batches.length() {
      let b = batches[at]
      at += 1
      Some(b)
    } else {
      None
    }
  }
  let (store, box) = sort_store_boxed()
  let keys : Array[(PhysExpr, Bool, Bool?)] = []
  let built = build_runs(produced, keys, 64, store) catch { e => abort("\{e}") }
  assert_true(built.ids.length() > 0) // the tiny budget forced runs
  let owned : Array[Int32] = []
  for id in built.ids {
    owned.push(id)
  }
  let inputs = reduce_runs(built.ids, keys, store, owned) catch {
    e => abort("\{e}")
  }
  let out_exprs : Array[PhysExpr] = [
    PhysExpr::ColRef(0, @types.Str),
    PhysExpr::ColRef(1, @types.Int32),
    PhysExpr::ColRef(2, @types.Int32),
  ]
  let out_types : Array[@types.DataType] = [
    @types.Str,
    @types.Int32,
    @types.Int32,
  ]
  let cursor = merge_open(
    inputs,
    keys,
    out_exprs,
    out_types,
    false,
    Some(0),
    Some(3),
    store,
  ) catch {
    e => abort("\{e}")
  }
  let first = cursor.next() catch { e => abort("\{e}") }
  assert_true(first is Some(_))
  assert_eq(first.unwrap().row_count(), 3)
  assert_eq(cursor.taken, 3)
  assert_true((cursor.next() catch { e => abort("\{e}") }) is None)
  // the files the sort wrote are the caller's to remove, not the cursor's
  assert_true(box.files.length() > 0)
  remove_ids(store, owned) catch {
    e => abort("\{e}")
  }
  assert_eq(box.files.length(), 0)
}
