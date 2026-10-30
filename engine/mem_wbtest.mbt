// Whitebox tests for the structure census (`moonlake exec --mem`).
//
// The contract is in docs/ROADMAP.md, §61 measures it on q21. What the tests
// below can see is the mechanism: one point per label, the largest kept, the
// blocks and their entries in descending order, nothing at all when nothing was
// observed, the scanned tables reported at the exact size the budget uses, and
// a census run answering exactly what the plain run answers.

///|
/// A column from scalars, a null written as `@types.Null`.
fn mw_col(
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
fn mw_entry(
  name : String,
  cols : Array[(String, @types.DataType)],
  batches : Array[@types.DataBatch],
) -> @catalog.TableEntry {
  let columns : Array[@catalog.Column] = []
  for c in cols {
    columns.push({ name: c.0, dtype: c.1, })
  }
  @catalog.TableEntry::new({ table: name, columns, }, batches)
}

///|
/// `big(k, s)` twice the size of `small(k, w)`: every column of both is used by
/// the query below, so the scan projection keeps them all and the tables' bytes
/// are the batches' own bytes.
fn mw_catalog() -> @catalog.Catalog {
  let cat = @catalog.Catalog::new()
  let big_keys = [1, 2, 3, 4, 5]
  let big_batches : Array[@types.DataBatch] = []
  for b in 0..<2 {
    let ks : Array[@types.Scalar] = []
    let ss : Array[@types.Scalar] = []
    for i in 0..<2 {
      let k = big_keys[b * 2 + i]
      ks.push(@types.Int32(k))
      ss.push(@types.Str("row\{k}"))
    }
    big_batches.push(
      @types.DataBatch::new(
        [mw_col(@types.Int32, ks), mw_col(@types.Str, ss)],
        ks.length(),
      ),
    )
  }
  big_batches.push(
    @types.DataBatch::new(
      [
        mw_col(@types.Int32, [@types.Int32(5)]),
        mw_col(@types.Str, [@types.Str("row5")]),
      ],
      1,
    ),
  )
  cat.register(
    mw_entry("big", [("k", @types.Int32), ("s", @types.Str)], big_batches),
  )
  cat.register(
    mw_entry("tiny", [("k", @types.Int32), ("z", @types.Int32)], [
      @types.DataBatch::new(
        [
          mw_col(@types.Int32, [@types.Int32(1), @types.Int32(2)]),
          mw_col(@types.Int32, [@types.Int32(10), @types.Int32(20)]),
        ],
        2,
      ),
    ]),
  )
  cat.register(
    mw_entry("small", [("k", @types.Int32), ("w", @types.Int32)], [
      @types.DataBatch::new(
        [
          mw_col(@types.Int32, [@types.Int32(1), @types.Int32(3)]),
          mw_col(@types.Int32, [@types.Int32(7), @types.Int32(9)]),
        ],
        2,
      ),
    ]),
  )
  cat
}

///|
test "the census keeps the largest point at each label" {
  let c = MemCensus::new()
  c.observe("a", [("x", 10L), ("y", 5L)])
  c.observe("a", [("x", 4L)])
  c.observe("b", [("z", 30L)])
  let text = c.render()
  assert_true(text.contains("largest point of each of 2 labels, 3 points seen"))
  // largest label first, and inside a label the entries largest first
  let b_at = match text.find("b: 30") {
    Some(i) => i
    None => -1
  }
  let a_at = match text.find("a: 15") {
    Some(i) => i
    None => -1
  }
  assert_true(b_at >= 0)
  assert_true(a_at > b_at)
  assert_true(text.contains("x: 10\ny: 5"))
  // the smaller point at a label is dropped, not the label
  assert_true(!text.contains("x: 4"))
}

///|
test "a census with a sampler says where the peak was" {
  let census = MemCensus::new(sample=Some({ read: fn() { (1000, 2000) }, }))
  census.observe("small", [("a", 10L)])
  census.observe("big", [("b", 20L)])
  let out = census.render()
  // both samples report the same residency, so the first point seen holds the peak
  assert_true(out.contains(", high 2000 KB, peak at small"))
  assert_true(out.contains("# big: 20 bytes (rss 1000 KB, high 2000 KB)"))
}

///|
test "a census without a sampler prints no residency" {
  let census = MemCensus::new()
  census.observe("only", [("a", 10L)])
  let out = census.render()
  assert_true(out.contains("# only: 10 bytes"))
  assert_true(!out.contains("rss"))
  assert_true(!out.contains("high"))
}

///|
test "an empty census renders nothing" {
  assert_eq(MemCensus::new().render(), "")
}

///|
test "a join point names the scanned tables at their own size" {
  let cat = mw_catalog()
  let plain = MemCensus::new()
  let _ = run_parsed(
    @sql.parse_select(
      "SELECT big.k, big.s, small.w FROM big, small WHERE big.k = small.k",
    ),
    cat,
    [],
    ExecOptions::in_memory(),
    census=Some(plain),
  )
  // every column is used, so the narrowed tables are the batches' own bytes
  let big = cat.lookup("big").unwrap().batches
  let small = cat.lookup("small").unwrap().batches
  let expected = resident_batches_bytes(big) + resident_batches_bytes(small)
  let text = plain.render()
  assert_true(text.contains("# collected FROM tables: \{expected} bytes"))
  assert_true(text.contains("scan big: "))
  assert_true(text.contains("scan small: "))
  // the step's own copies and index make its point larger than the tables',
  // and the collected output is the last point of a step: there is no collapse
  // to name any more
  assert_true(text.contains("# hash join collected its output (step 1): "))
  assert_true(!text.contains("collapsed"))
}

///|
test "a semi side is its own point" {
  let cat = mw_catalog()
  let census = MemCensus::new()
  let _ = run_parsed(
    @sql.parse_select(
      "SELECT count(*) AS c FROM big, small WHERE big.k = small.k AND EXISTS (SELECT 1 FROM small t WHERE t.k = big.k)",
    ),
    cat,
    [],
    ExecOptions::in_memory(),
    census=Some(census),
  )
  let text = census.render()
  assert_true(text.contains("# semi/anti join's inner side (step 2)"))
  assert_true(text.contains("probe copy: "))
}

///|
test "a step releases the tables whose last step it was" {
  let cat = mw_catalog()
  let census = MemCensus::new()
  // every column of every table is read, so a narrowed table is its own size
  let sql = "SELECT big.k, big.s, small.k, small.w, tiny.k, tiny.z FROM big, small, tiny WHERE big.k = small.k AND big.k = tiny.k"
  let with_census = run_parsed(
    @sql.parse_select(sql),
    cat,
    [],
    ExecOptions::in_memory(),
    census=Some(census),
  )
  let big = cat.lookup("big").unwrap().batches
  let small = cat.lookup("small").unwrap().batches
  let tiny = cat.lookup("tiny").unwrap().batches
  let all = resident_batches_bytes(big) +
    resident_batches_bytes(small) +
    resident_batches_bytes(tiny)
  let text = census.render()
  // step 2 stands on no table but its own: step 1 finished big and small
  assert_true(text.contains("collected FROM tables: \{all}"))
  assert_true(
    text.contains("collected FROM tables: \{resident_batches_bytes(tiny)}"),
  )
  // and letting go of them answers what holding them answered
  let plain = run_select(sql, mw_catalog())
  assert_eq(with_census.row_count(), plain.row_count())
  for r in 0..<plain.row_count() {
    for c in 0..<plain.batch.columns().length() {
      assert_eq(with_census.get(r, c).to_string(), plain.get(r, c).to_string())
    }
  }
}

///|
test "a table named by two steps is released after the later one" {
  let steps : Array[JoinStep] = [
    step_of_table(0),
    step_of_table(1),
    step_of_table(0),
  ]
  assert_eq(tables_finished_at(steps, 0).length(), 0)
  assert_eq(tables_finished_at(steps, 1).length(), 1)
  assert_eq(tables_finished_at(steps, 1)[0], 1)
  assert_eq(tables_finished_at(steps, 2).length(), 1)
  assert_eq(tables_finished_at(steps, 2)[0], 0)
  let chain : Array[JoinStep] = [step_of_table(0), step_of_table(1)]
  assert_eq(tables_finished_at(chain, 0)[0], 0)
  assert_eq(tables_finished_at(chain, 1)[0], 1)
}

///|
/// A join step that names only a table: enough for the lifetime rule.
fn step_of_table(table : Int32) -> JoinStep {
  {
    table,
    kind: @sql.JoinKind::Inner,
    keys_l: [],
    keys_r: [],
    build_filter: None,
    probe_filter: None,
    residual: None,
    right_offset: 0,
    right_width: 0,
    out_dtypes: [],
  }
}

///|
test "a census run answers what the plain run answers" {
  let cat = mw_catalog()
  let sql = "SELECT big.k, big.s, small.w FROM big, small WHERE big.k = small.k"
  let plain = run_select(sql, cat)
  let census = MemCensus::new()
  let measured = run_parsed(
    @sql.parse_select(sql),
    cat,
    [],
    ExecOptions::in_memory(),
    census=Some(census),
  )
  assert_eq(measured.row_count(), plain.row_count())
  for r in 0..<plain.row_count() {
    for c in 0..<plain.batch.columns().length() {
      assert_eq(measured.get(r, c).to_string(), plain.get(r, c).to_string())
    }
  }
  assert_true(census.render().length() > 0)
}
