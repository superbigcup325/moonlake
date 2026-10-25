// The approximate aggregates: what they must match exactly, the tolerance
// they advertise, and the inputs they refuse.
//
// The whitebox side pins the canonical form the sketch sees; these tests
// go through the parser, the binder and the fold.

///|
fn approx_cat(files : Array[(String, String)]) -> @catalog.Catalog {
  let cat = @catalog.Catalog::new()
  for pair in files {
    cat.register(@csv.scan_string(pair.1, pair.0) catch { e => abort("\{e}") })
  }
  cat
}

///|
/// A one-column CSV of `1..rows`, the fixture the tolerance cases count.
fn ones_csv(rows : Int32) -> String {
  let sb = StringBuilder()
  sb.write_string("v\n")
  for i in 1..<(rows + 1) {
    sb.write_string(i.to_string())
    sb.write_char('\n')
  }
  sb.to_string()
}

///|
fn approx_int(v : @types.Scalar) -> Int64 {
  match v {
    @types.Int64(x) => x
    other => abort("expected int64, got \{other.to_string()}")
  }
}

///|
fn approx_float(v : @types.Scalar) -> Double {
  match v {
    @types.Float64(x) => x
    other => abort("expected float64, got \{other.to_string()}")
  }
}

///|
test "approx_count_distinct answers the exact count of a small input" {
  let cat = approx_cat([("five", "v\n1\n2\n3\n4\n5\n5\n5\n1\n")])
  let r = run("SELECT approx_count_distinct(v) AS a FROM five", cat)
  assert_eq(r.types()[0], @types.Int64)
  let a = approx_int(r.get(0, 0))
  // its standard error is about 0.81%; on five values that is well under one
  assert_true(a >= 4L && a <= 6L)
}

///|
test "approx_count_distinct answers 0 for no rows and for an all-NULL column" {
  let cat = approx_cat([("five", "v\n1\n2\n3\n4\n5\n")])
  let zero = run(
    "SELECT approx_count_distinct(v) AS a FROM five WHERE v > 100", cat,
  )
  assert_eq(zero.get(0, 0), @types.Int64(0L))
  // NULL is not a value: two values, one NULL in the column
  let nulls = approx_cat([("nulls", "v,w\n1,a\n,b\n3,c\n")])
  let r = run(
    "SELECT approx_count_distinct(v) AS a, count(v) AS c FROM nulls", nulls,
  )
  assert_eq(approx_int(r.get(0, 1)), 2L)
  let a = approx_int(r.get(0, 0))
  assert_true(a >= 1L && a <= 3L)
}

///|
test "approx_count_distinct lands within three standard errors on 10,000 values" {
  let cat = approx_cat([("tenk", ones_csv(10_000))])
  let r = run(
    "SELECT approx_count_distinct(v) AS a, count(DISTINCT v) AS e FROM tenk", cat,
  )
  let a = approx_int(r.get(0, 0))
  let e = approx_int(r.get(0, 1))
  assert_eq(e, 10_000L)
  // p = 14 has a relative standard error of about 0.81%; three of those is
  // 243 values at this cardinality
  let slack = 243L
  assert_true(a >= e - slack && a <= e + slack)
}

///|
test "approx_count_distinct folds groups like count(distinct)" {
  let cat = approx_cat([
    ("g", "k,v\na,1\na,1\na,2\nb,3\nb,3\nc,4\nc,4\nc,5\nc,6\n"),
  ])
  let r = run(
    "SELECT k, approx_count_distinct(v) AS a, count(DISTINCT v) AS e FROM g GROUP BY k ORDER BY k",
    cat,
  )
  assert_eq(r.row_count(), 3)
  for row in 0..<3 {
    let a = approx_int(r.get(row, 1))
    let e = approx_int(r.get(row, 2))
    assert_true(a >= e - 1L && a <= e + 1L)
  }
}

///|
test "approx_count_distinct accepts strings and dates" {
  let cat = approx_cat([
    ("s", "s\nx\ny\nx\nz\n"),
    ("d", "d\n1994-01-01\n1994-01-01\n1995-06-30\n"),
  ])
  let a = approx_int(
    run("SELECT approx_count_distinct(s) AS a FROM s", cat).get(0, 0),
  )
  let b = approx_int(
    run("SELECT approx_count_distinct(d) AS a FROM d", cat).get(0, 0),
  )
  assert_true(a >= 2L && a <= 4L)
  assert_true(b >= 1L && b <= 3L)
}

///|
test "approx_quantile follows an exact median closely and hits the ends" {
  let cat = approx_cat([("hundred", ones_csv(100))])
  let r = run(
    "SELECT approx_quantile(v, 0.5) AS m, approx_quantile(v, 0) AS lo, approx_quantile(v, 1) AS hi, median(v) AS exact FROM hundred",
    cat,
  )
  // median of 1..100 is 50.5; the contract allows a 1% rank error in the
  // interior, which at this size is well inside half a value
  let m = approx_float(r.get(0, 0))
  assert_true(m > 50.0 && m < 51.0)
  assert_true(near(approx_float(r.get(0, 1)), 1.0))
  assert_true(near(approx_float(r.get(0, 2)), 100.0))
  assert_true(near(approx_float(r.get(0, 3)), 50.5))
}

///|
test "approx_quantile answers NULL when no value reaches it" {
  let cat = approx_cat([("hundred", ones_csv(100))])
  let r = run(
    "SELECT approx_quantile(v, 0.5) AS m FROM hundred WHERE v > 1000", cat,
  )
  assert_eq(r.row_count(), 1)
  assert_eq(r.get(0, 0), @types.Null)
}

///|
test "approx_quantile validates q before it reads a row" {
  let cat = approx_cat([("hundred", ones_csv(100))])
  // out of range, and non-finite
  assert_true(
    run_err("SELECT approx_quantile(v, 1.5) FROM hundred", cat)
    .to_string()
    .contains("[0, 1]"),
  )
  assert_true(
    run_err("SELECT approx_quantile(v, -0.1) FROM hundred", cat)
    .to_string()
    .contains("[0, 1]"),
  )
  // a column is not a constant q
  assert_true(
    run_err("SELECT approx_quantile(v, v) FROM hundred", cat)
    .to_string()
    .contains("constant literal"),
  )
  // and the check does not depend on the input having rows
  assert_true(
    run_err("SELECT approx_quantile(v, 2.0) FROM hundred WHERE v > 1000", cat)
    .to_string()
    .contains("[0, 1]"),
  )
}

///|
test "approx_quantile refuses a non-numeric input" {
  let cat = approx_cat([("s", "s\nx\ny\n")])
  assert_true(
    run_err("SELECT approx_quantile(s, 0.5) FROM s", cat)
    .to_string()
    .contains("does not support input type"),
  )
}

///|
test "approx_count_distinct also answers as a window aggregate" {
  let cat = approx_cat([("five", "v\n1\n2\n3\n4\n5\n")])
  let r = run(
    "SELECT v, approx_count_distinct(v) OVER () AS a FROM five ORDER BY v", cat,
  )
  assert_eq(r.row_count(), 5)
  for row in 0..<5 {
    let a = approx_int(r.get(row, 1))
    assert_true(a >= 4L && a <= 6L)
  }
}

///|
test "approx_quantile takes an integer literal q" {
  let cat = approx_cat([("hundred", ones_csv(100))])
  let r = run("SELECT approx_quantile(v, 1) AS hi FROM hundred", cat)
  assert_true(near(approx_float(r.get(0, 0)), 100.0))
}
