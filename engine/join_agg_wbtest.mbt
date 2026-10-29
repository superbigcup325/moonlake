// Whitebox tests for folding a join's own batches into an aggregate.
//
// The shape is one join step over two lazy tables with an aggregate above it:
// the build side is read once and stays resident, the probe side arrives a batch
// at a time, and each joined batch is folded before the next one exists, so the
// joined rows are never an array. What the tests below can see is the answer, the
// counters and the plan the counters describe; the point of the first half is
// that this path answers exactly what the collected join answered, including the
// cases a batch boundary could break (a group spanning batches, a NULL key, a
// NULL value, a duplicated build key, an unmatched LEFT row, an empty side).
// The second half pins the routing: which shapes compose, which keep the eager
// path, and that a budget too small for the build side hands that side over
// instead of reading the table twice.
// docs/verification.md §49 carries the measurement.

///|
/// A column from scalars, a null written as `@types.Null`.
fn ja_col(
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
/// Two batches of `probe(k, v)`: a NULL key, a NULL value, a duplicated key and a
/// key the build side does not have. Groups therefore span batches and contain
/// nulls, which is what a per-batch fold has to get right.
fn ja_probe_batches() -> Array[@types.DataBatch] {
  let k1 = ja_col(@types.Int32, [
    @types.Int32(1),
    @types.Int32(1),
    @types.Int32(2),
    @types.Null,
    @types.Int32(3),
  ])
  let v1 = ja_col(@types.Int32, [
    @types.Int32(10),
    @types.Null,
    @types.Int32(20),
    @types.Int32(30),
    @types.Int32(40),
  ])
  let k2 = ja_col(@types.Int32, [@types.Int32(2), @types.Int32(1)])
  let v2 = ja_col(@types.Int32, [@types.Int32(50), @types.Int32(60)])
  [@types.DataBatch::new([k1, v1], 5), @types.DataBatch::new([k2, v2], 2)]
}

///|
/// `build(k, w)` in two batches: key 1 twice (so one probe row matches twice), a
/// key only one probe row has, and a NULL key that never matches.
fn ja_build_batches() -> Array[@types.DataBatch] {
  let k1 = ja_col(@types.Int32, [@types.Int32(1), @types.Int32(1)])
  let w1 = ja_col(@types.Int32, [@types.Int32(100), @types.Int32(200)])
  let k2 = ja_col(@types.Int32, [@types.Int32(2), @types.Null])
  let w2 = ja_col(@types.Int32, [@types.Int32(300), @types.Int32(400)])
  [@types.DataBatch::new([k1, w1], 2), @types.DataBatch::new([k2, w2], 2)]
}

///|
fn ja_entry(
  name : String,
  cols : Array[(String, @types.DataType)],
  batches : Array[@types.DataBatch],
) -> @catalog.TableEntry {
  let columns : Array[@catalog.Column] = []
  for c in cols {
    columns.push({ name: c.0, dtype: c.1, })
  }
  let schema : @catalog.TableSchema = { table: name, columns, }
  let source : CountingSource = { batches, cells: [0, 0, 0, 0], }
  @catalog.TableEntry::from_source(schema, source)
}

///|
/// `probe(k, v)`, `build(k, w)` and, for the shapes that must not compose, one
/// more lazy table `extra(k, w)`.
fn ja_catalog(
  probe : Array[@types.DataBatch],
  build : Array[@types.DataBatch],
) -> @catalog.Catalog {
  let cat = @catalog.Catalog::new()
  cat.register(
    ja_entry("probe", [("k", @types.Int32), ("v", @types.Int32)], probe),
  )
  cat.register(
    ja_entry("build", [("k", @types.Int32), ("w", @types.Int32)], build),
  )
  cat.register(
    ja_entry("extra", [("k", @types.Int32), ("w", @types.Int32)], build),
  )
  cat
}

///|
/// A row's identity for ordering: these fixtures group by an integer column and
/// a NULL group sorts last.
fn ja_row_key(row : Array[@types.Scalar]) -> (Int32, Int64) {
  match row[0] {
    @types.Null => (1, 0L)
    @types.Int32(v) => (0, v.to_int64())
    @types.Int64(v) => (0, v)
    _ => (2, 0L)
  }
}

///|
/// The rows of a result as `"cell|cell"` text in group-key order, so a test does
/// not depend on the order a GROUP BY emits. (A plain string sort would not do:
/// MoonBit orders strings shortlex, shortest first.)
fn ja_show(rows : Array[Array[@types.Scalar]]) -> Array[String] {
  let sorted = rows.copy()
  sorted.sort_by(fn(a, b) {
    let ka = ja_row_key(a)
    let kb = ja_row_key(b)
    if ka.0 != kb.0 {
      ka.0 - kb.0
    } else if ka.1 < kb.1 {
      -1
    } else if ka.1 > kb.1 {
      1
    } else {
      0
    }
  })
  let out : Array[String] = []
  for row in sorted {
    let mut line = ""
    let mut first = true
    for cell in row {
      if !first {
        line = line + "|"
      }
      line = line + cell.to_string()
      first = false
    }
    out.push(line)
  }
  out
}

///|
fn ja_run(
  sql : String,
  cat : @catalog.Catalog,
  opts : ExecOptions,
  stats : Array[(String, Int64)],
) -> SelectResult raise @types.SqlError {
  run_parsed(@sql.parse_select(sql), cat, stats, opts)
}

///|
fn ja_show_sql(
  sql : String,
  cat : @catalog.Catalog,
  opts : ExecOptions,
) -> Array[String] {
  let result = ja_run(sql, cat, opts, []) catch { e => abort("\{e}") }
  ja_show(scalars_of([result.batch()]))
}

///|
fn ja_stat(stats : Array[(String, Int64)], name : String) -> Int64 {
  for pair in stats {
    if pair.0 == name {
      return pair.1
    }
  }
  abort("no counter named \{name}")
}

///|
/// The first index of `name` in `stats`, or `-1`: the counters are pushed in the
/// order the plan runs, which is how a test tells the composed plan from the
/// eager one.
fn ja_index(stats : Array[(String, Int64)], name : String) -> Int32 {
  for i, pair in stats {
    if pair.0 == name {
      return i
    }
  }
  -1
}

///|
/// A hermetic spill store and the files it still holds.
fn ja_mem_store() -> (SpillStore, Map[Int32, Bytes]) {
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
fn ja_launch(sql : String, cat : @catalog.Catalog) -> Launch {
  let prepared = prepare_select(
    @sql.parse_select(sql) catch {
      e => abort("\{e}")
    },
    cat,
    ExecOptions::in_memory(),
  ) catch {
    e => abort("\{e}")
  }
  match prepared {
    Ready(launch) => launch
    Setop(_) => abort("expected a ready launch, not a set operation")
  }
}

///|
const JA_INNER : String = "select b.k as k, count(*) as n, sum(p.v) as s from probe p join build b on p.k = b.k group by b.k"

///|
const JA_LEFT : String = "select b.k as k, count(*) as n, sum(p.v) as s from probe p left join build b on p.k = b.k group by b.k"

///|
const JA_FULL : String = "select b.k as k, count(*) as n, sum(p.v) as s from probe p full join build b on p.k = b.k group by b.k"

///|
test "an inner join under an aggregate folds its own batches" {
  // key 1 matches two build rows for each of its three probe rows (6 rows, the
  // NULL value ignored by sum), key 2 matches once for two probe rows, and the
  // NULL and unmatched probe keys never match
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  assert_eq(ja_show_sql(JA_INNER, cat, ExecOptions::in_memory()), [
    "1|6|140", "2|2|70",
  ])
}

///|
test "the composed plan reports the counters the collected plan reported" {
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let stats : Array[(String, Int64)] = []
  ignore(ja_run(JA_INNER, cat, ExecOptions::in_memory(), stats))
  // rows the probe pull was handed, rows the build scan kept, rows the deferred
  // filter passed to the fold, groups, result
  assert_eq(stats.map(fn(p) { p }), [
    ("scan probe", 7L),
    ("scan build", 4L),
    ("joins", 8L),
    ("aggregate", 2L),
    ("result", 2L),
  ])
}

///|
test "an unmatched LEFT row lands in the NULL group under a build-side group" {
  // the two probe rows with no match (keys NULL and 3) have no build row, so
  // b.k is NULL for both and count/S sum over the pair
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  assert_eq(ja_show_sql(JA_LEFT, cat, ExecOptions::in_memory()), [
    "1|6|140", "2|2|70", "null|2|70",
  ])
}

///|
test "a full join also folds the unmatched build rows" {
  // the NULL-keyed build row (w = 400) matches nothing and is emitted once at the
  // end, so the NULL group gains a row with a NULL aggregate input
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  assert_eq(ja_show_sql(JA_FULL, cat, ExecOptions::in_memory()), [
    "1|6|140", "2|2|70", "null|3|70",
  ])
}

///|
test "grouping by a build-side column groups the unmatched rows too" {
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let sql = "select b.w as w, count(*) as n, sum(p.v) as s from probe p left join build b on p.k = b.k group by b.w"
  assert_eq(ja_show_sql(sql, cat, ExecOptions::in_memory()), [
    "100|3|70", "200|3|70", "300|2|70", "null|2|70",
  ])
}

///|
test "an empty build side answers the inner and left plans without a match" {
  let inner = ja_catalog(ja_probe_batches(), [])
  assert_eq(ja_show_sql(JA_INNER, inner, ExecOptions::in_memory()), [])
  // every probe row is unmatched, so they all land in the one NULL group
  let left = ja_catalog(ja_probe_batches(), [])
  assert_eq(ja_show_sql(JA_LEFT, left, ExecOptions::in_memory()), ["null|7|210"])
}

///|
test "an empty probe side answers a full join from the build side" {
  let cat = ja_catalog([], ja_build_batches())
  assert_eq(ja_show_sql(JA_INNER, cat, ExecOptions::in_memory()), [])
  let full = ja_catalog([], ja_build_batches())
  assert_eq(ja_show_sql(JA_FULL, full, ExecOptions::in_memory()), [
    "1|2|null", "2|1|null", "null|1|null",
  ])
}

///|
test "HAVING runs on the finished groups of a composed join" {
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let sql = "select b.k as k, count(*) as n, sum(p.v) as s from probe p join build b on p.k = b.k group by b.k having count(*) > 2"
  assert_eq(ja_show_sql(sql, cat, ExecOptions::in_memory()), ["1|6|140"])
}

///|
test "a global aggregate folds a joined pull as one state" {
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let sql = "select count(*) as n, sum(p.v) as s from probe p join build b on p.k = b.k"
  let stats : Array[(String, Int64)] = []
  let result = ja_run(sql, cat, ExecOptions::in_memory(), stats) catch {
    e => abort("\{e}")
  }
  assert_eq(ja_show(scalars_of([result.batch()])), ["8|210"])
  assert_eq(ja_stat(stats, "joins"), 8L)
  assert_eq(ja_stat(stats, "result"), 1L)
}

///|
test "min and max and a distinct count fold once per group across batches" {
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let sql = "select b.k as k, min(p.v) as lo, max(p.v) as hi, count(distinct p.v) as d from probe p join build b on p.k = b.k group by b.k"
  assert_eq(ja_show_sql(sql, cat, ExecOptions::in_memory()), [
    "1|10|60|2", "2|20|50|2",
  ])
}

///|
test "a budgeted composed join spills, answers the same rows and leaves no run" {
  let sql = "select b.k as k, count(*) as n, sum(p.v) as s, min(p.v) as lo from probe p left join build b on p.k = b.k group by b.k"
  let plain = ja_catalog(ja_probe_batches(), ja_build_batches())
  let want = ja_show_sql(sql, plain, ExecOptions::in_memory())
  let budgeted = ja_catalog(ja_probe_batches(), ja_build_batches())
  let (store, files) = ja_mem_store()
  let stats : Array[(String, Int64)] = []
  let result = ja_run(sql, budgeted, { budget: 64, spill: Some(store), }, stats) catch {
    e => abort("\{e}")
  }
  assert_eq(ja_show(scalars_of([result.batch()])), want)
  // the fold buffered, hit its budget, partitioned and spilled; every run it
  // wrote was removed again
  assert_true(stats.any(fn(p) { p.0 == "spill partitions" }))
  assert_true(stats.any(fn(p) { p.0 == "buffered bytes peak (estimated)" }))
  assert_eq(files.length(), 0)
}

///|
test "the build side, not the whole join, decides whether a shape composes" {
  // The routing asks one question: does the side this plan has to hold whole fit
  // the budget? Below it the query keeps the eager path, which can partition the
  // join; at it and above, the join is folded. A tiny budget that fails this
  // test on this fixture is the eager plan's business, not this rule's.
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let launch = ja_launch(JA_INNER, cat)
  let src = match streaming_join_agg_source(launch.bq, launch.sources) {
    Some(src) => src
    None =>
      abort("the shape must be accepted before its build side is measured")
  }
  let scans = join_agg_scans(src, launch) catch { e => abort("\{e}") }
  let build_batches = join_agg_sides(scans, launch.bq.steps)
  // the scan handed to the eager path is the same rows, before the step's
  // layout concat
  let mut scan_rows = 0
  for side in scans {
    for batch in side {
      scan_rows += batch.row_count()
    }
  }
  let mut build_rows = 0
  for batch in build_batches {
    build_rows += batch.row_count()
  }
  assert_eq(scan_rows, build_rows)
  // the check runs on the charge its own function makes, before the copies
  // exist, so a query that keeps the eager path never pays for them
  let bytes = join_agg_sides_bytes(scans)
  assert_true(bytes >= batches_bytes(scans[0]))
  assert_false(join_agg_composes(bytes, { budget: bytes - 1, spill: None, }))
  assert_true(join_agg_composes(bytes, { budget: bytes, spill: None, }))
  // unbounded is the same answer as "fits": nothing is refused for lack of a
  // budget, and the fold above it stays unbounded too
  assert_true(join_agg_composes(bytes, ExecOptions::in_memory()))
}

///|
test "a chain's fit check sums every build side" {
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let launch = ja_launch(JA_CHAIN, cat)
  let src = match streaming_join_agg_source(launch.bq, launch.sources) {
    Some(src) => src
    None => abort("the chain must be accepted before its sides are measured")
  }
  let scans = join_agg_scans(src, launch) catch { e => abort("\{e}") }
  assert_eq(scans.length(), 2)
  let bytes = join_agg_sides_bytes(scans)
  assert_true(bytes > batches_bytes(scans[0]))
  assert_true(join_agg_sides(scans, launch.bq.steps).length() == 2)
  // a budget one byte under the sum keeps the eager path
  assert_false(join_agg_composes(bytes, { budget: bytes - 1, spill: None, }))
  assert_true(join_agg_composes(bytes, { budget: bytes, spill: None, }))
  // without a budget the sides are the price and the fold is unbounded, so the
  // chain composes whatever they weigh
  assert_true(join_agg_composes(bytes, ExecOptions::in_memory()))
}

///|
test "a budget the build side fits keeps the composed plan" {
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let (store, files) = ja_mem_store()
  let stats : Array[(String, Int64)] = []
  let result = ja_run(
    JA_INNER,
    cat,
    { budget: 4096, spill: Some(store), },
    stats,
  ) catch {
    e => abort("\{e}")
  }
  assert_eq(ja_show(scalars_of([result.batch()])), ["1|6|140", "2|2|70"])
  // small enough to fit: no partition, and nothing written
  assert_eq(ja_index(stats, "spill partitions"), -1)
  assert_eq(files.length(), 0)
  assert_eq(ja_stat(stats, "joins"), 8L)
}

///|
test "a composed plan with an over-budget fold spills after the join count" {
  let sql = "select b.k as k, count(*) as n from probe p join build b on p.k = b.k group by b.k"
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let (store, files) = ja_mem_store()
  let stats : Array[(String, Int64)] = []
  let result = ja_run(sql, cat, { budget: 64, spill: Some(store), }, stats) catch {
    e => abort("\{e}")
  }
  assert_eq(ja_show(scalars_of([result.batch()])), ["1|6", "2|2"])
  let joins = ja_index(stats, "joins")
  let spill = ja_index(stats, "spill partitions")
  assert_true(spill >= 0 && joins >= 0)
  assert_true(spill > joins)
  assert_eq(files.length(), 0)
}

///|
test "the composed shape is not one of the stream's shapes" {
  // The answer is one batch, so the stream still hands it back materialized:
  // neither stream source may claim this query.
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let launch = ja_launch(JA_INNER, cat)
  assert_true(streaming_join_agg_source(launch.bq, launch.sources) is Some(_))
  assert_true(streaming_agg_source(launch.bq, launch.sources) is None)
  assert_true(streaming_join_source(launch.bq, launch.sources) is None)
}

///|
test "an ORDER BY over the composed join sorts the finished groups" {
  // The sort runs on the grouped batch once the fold ends, so the ordered shape
  // composes and the answer is what the eager path's sort produces.
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let sql = JA_INNER + " order by n desc, k"
  let launch = ja_launch(sql, cat)
  assert_true(streaming_join_agg_source(launch.bq, launch.sources) is Some(_))
  let run = fn(
    sql2 : String,
    opts : ExecOptions,
  ) -> Array[Array[@types.Scalar]] {
    let result = ja_run(sql2, cat, opts, []) catch { e => abort("\{e}") }
    scalars_of([result.batch()])
  }
  // k=1 matches six joined rows and k=2 two, so the count orders them and the
  // written second key only breaks ties
  let desc = run(sql, ExecOptions::in_memory())
  assert_eq(desc[0][0].to_string(), "1")
  assert_eq(desc[0][1].to_string(), "6")
  assert_eq(desc[1][0].to_string(), "2")
  assert_eq(desc[1][1].to_string(), "2")
  // the key order decides, not the order the fold finished its groups in
  let by_key = run(JA_INNER + " order by k desc", ExecOptions::in_memory())
  assert_eq(by_key[0][0].to_string(), "2")
  assert_eq(by_key[1][0].to_string(), "1")
  // a budget spills the fold's input without changing what is ordered
  let (store, files) = ja_mem_store()
  let budgeted = run(sql, { budget: 64, spill: Some(store), })
  assert_eq(budgeted[0][1].to_string(), "6")
  assert_eq(budgeted[1][1].to_string(), "2")
  assert_eq(files.length(), 0)
}

///|
test "the shapes outside the composition do not compose" {
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let shapes = [
    // a RIGHT step anywhere in a chain is a swapped LEFT, which drops a side
    "select count(*) as n from probe p join build b on p.k = b.k right join extra e on b.k = e.k",
    // a second step over a derived table is not a chain of lazy tables
     "select count(*) as n from probe p join build b on p.k = b.k join (select k, w from extra) e on b.k = e.k",
    // a RIGHT join is a swapped LEFT
     "select count(*) as n from probe p right join build b on p.k = b.k",
    // DISTINCT and a window both need every row before they emit one
     "select distinct b.k as k from probe p join build b on p.k = b.k", "select b.k as k, row_number() over (order by b.k) as r from probe p join build b on p.k = b.k",
    // a derived table is not a lazy base table
     "select count(*) as n from (select k, v from probe) p join build b on p.k = b.k",
    // and one table is the single-table shape
     "select k, count(*) as n from probe group by k",
  ]
  for sql in shapes {
    let launch = ja_launch(sql, cat)
    assert_true(streaming_join_agg_source(launch.bq, launch.sources) is None)
  }
}

///|
/// A chain of two steps: `probe ⋈ build` (the same eight rows `JA_INNER` folds)
/// flows into a second hash join against `extra`, so the aggregate sees the
/// second step's output and neither joined row set is ever an array.
const JA_CHAIN : String = "select e.w as w, count(*) as n from probe p join build b on p.k = b.k join extra e on b.k = e.k group by e.w"

///|
test "a chain of joins folds its own batches" {
  // step 1 makes 8 rows (keys 1 and 2), step 2 multiplies them by the matching
  // `extra` rows: key 1 has two (w 100, 200) and key 2 one (w 300)
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  assert_eq(ja_show_sql(JA_CHAIN, cat, ExecOptions::in_memory()), [
    "100|6", "200|6", "300|2",
  ])
}

///|
/// The eager control for a chain query: `DISTINCT` over a plan that groups by
/// the same key changes no answer and keeps the eager path, so the counters a
/// test reads from it describe the collected chain.
const JA_CHAIN_EAGER : String = "select distinct e.w as w, count(*) as n from probe p join build b on p.k = b.k join extra e on b.k = e.k group by e.w"

///|
test "the composed chain reports the counters the collected chain reported" {
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let composed : Array[(String, Int64)] = []
  ignore(ja_run(JA_CHAIN, cat, ExecOptions::in_memory(), composed))
  // one scan line per table, in FROM order, then the rows the fold received
  assert_eq(composed, [
    ("scan probe", 7L),
    ("scan build", 4L),
    ("scan extra", 4L),
    ("joins", 14L),
    ("aggregate", 3L),
    ("result", 3L),
  ])
  // the eager path reports the same six lines in the same order
  let eager : Array[(String, Int64)] = []
  ignore(ja_run(JA_CHAIN_EAGER, cat, ExecOptions::in_memory(), eager))
  assert_eq(eager, composed)
}

///|
test "a chain answers what the collected chain answered, budgets included" {
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let composed = ja_show_sql(JA_CHAIN, cat, ExecOptions::in_memory())
  // the eager control collects every joined row and still answers this
  assert_eq(
    ja_show_sql(JA_CHAIN_EAGER, cat, ExecOptions::in_memory()),
    composed,
  )
  // a budget the build sides fit keeps the composed plan and writes nothing
  let (store, files) = ja_mem_store()
  let stats : Array[(String, Int64)] = []
  let result = ja_run(
    JA_CHAIN,
    cat,
    { budget: 64 * 1024, spill: Some(store), },
    stats,
  ) catch {
    e => abort("\{e}")
  }
  assert_eq(ja_show(scalars_of([result.batch()])), composed)
  assert_eq(files.length(), 0)
  assert_eq(ja_index(stats, "spill partitions"), -1)
}

///|
test "a second step's probe filter trims the first step's output" {
  // `b.w = 300` is the step-2 probe filter over the joined rows: only the key-2
  // rows survive it, so the fold sees 2 rows instead of 8
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let sql = "select e.w as w, count(*) as n from probe p join build b on p.k = b.k join extra e on b.k = e.k and b.w = 300 group by e.w"
  let stats : Array[(String, Int64)] = []
  assert_eq(ja_show_sql(sql, cat, ExecOptions::in_memory()), ["300|2"])
  ignore(ja_run(sql, cat, ExecOptions::in_memory(), stats))
  assert_eq(ja_stat(stats, "joins"), 2L)
}

///|
test "a FULL step mid-chain still emits its unmatched build rows" {
  // `extra`'s NULL-keyed row (w 400) matches nothing, is emitted once by the
  // second step, and then matches nothing in the third because its key is NULL
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let sql = "select e.w as w, count(*) as n from probe p join build b on p.k = b.k full join extra e on b.k = e.k group by e.w"
  let eager_sql = "select distinct e.w as w, count(*) as n from probe p join build b on p.k = b.k full join extra e on b.k = e.k group by e.w"
  let composed = ja_show_sql(sql, cat, ExecOptions::in_memory())
  assert_eq(composed, ja_show_sql(eager_sql, cat, ExecOptions::in_memory()))
  // the unmatched `extra` row is emitted once, with its own w = 400
  assert_eq(composed, ["100|6", "200|6", "300|2", "400|1"])
}

///|
test "an ORDER BY over a chain sorts the finished groups" {
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let rows = ja_run(
    JA_CHAIN + " order by n desc, w",
    cat,
    ExecOptions::in_memory(),
    [],
  ) catch {
    e => abort("\{e}")
  }
  let shown = scalars_of([rows.batch()])
  assert_eq(shown[0][1].to_string(), "6")
  assert_eq(shown[1][1].to_string(), "6")
  assert_eq(shown[2][1].to_string(), "2")
  // the ordered chain still folds rather than collects
  assert_eq(shown.length(), 3)
}

///|
test "a LIMIT over a composed join counts against the grouped rows" {
  let cat = ja_catalog(ja_probe_batches(), ja_build_batches())
  let stats : Array[(String, Int64)] = []
  let result = ja_run(
    JA_INNER + " limit 1",
    cat,
    ExecOptions::in_memory(),
    stats,
  ) catch {
    e => abort("\{e}")
  }
  assert_eq(result.batch().row_count(), 1)
  assert_eq(ja_stat(stats, "result"), 1L)
  // the fold cannot stop early: every joined row still decides a group
  assert_eq(ja_stat(stats, "joins"), 8L)
  assert_eq(ja_stat(stats, "scan probe"), 7L)
}
