///|
/// End-to-end tests: CSV text in, aggregate result out. The fixture is a
/// hand-built lineitem slice exercising every Q6 predicate boundary.

///|
const Q6_SQL : String = "SELECT sum(l_extendedprice * l_discount) AS revenue FROM lineitem WHERE l_shipdate >= date '1994-01-01' AND l_shipdate < date '1995-01-01' AND l_discount BETWEEN 0.02 AND 0.04 AND l_quantity < 24"

///|
fn near(a : Double, b : Double) -> Bool {
  let d = a - b
  d < 1.0e-9 && d > -1.0e-9
}

///|
fn q6_catalog() -> @catalog.Catalog {
  let content = "l_quantity,l_extendedprice,l_discount,l_shipdate\n" +
    "17.00,21168.23,0.04,1996-03-13\n" + // wrong year: excluded
    "24.00,30000.00,0.03,1994-06-01\n" + // qty not < 24: excluded
    "12.00,10000.50,0.03,1994-06-01\n" + // included: 300.015
    "36.00,50000.00,0.02,1994-08-15\n" + // qty: excluded
    "20.00,20000.00,0.02,1994-12-31\n" + // included: 400.0 (boundary day)
    "10.00,5000.00,0.05,1994-04-01\n" + // discount out of range: excluded
    "5.00,8000.25,0.02,1995-01-01\n" + // shipdate boundary: excluded
    "8.00,2500.00,0.02,1994-01-01\n" // included: 50.0 (boundary day)
  let cat = @catalog.Catalog::new()
  cat.register(
    @csv.scan_string(content, "lineitem") catch {
      e => abort("\{e}")
    },
  )
  cat
}

///|
fn run(sql : String, cat : @catalog.Catalog) -> @engine.SelectResult {
  @engine.run_select(sql, cat) catch {
    e => abort("\{e}")
  }
}

///|
fn run_err(sql : String, cat : @catalog.Catalog) -> @types.SqlError {
  let _ = @engine.run_select(sql, cat) catch { e => return e }
  abort("expected an error")
}

///|
test "Q6 shape query computes revenue over filtered rows" {
  let cat = q6_catalog()
  let result = run(Q6_SQL, cat)
  assert_eq(result.names()[0], "revenue")
  assert_eq(result.types()[0], @types.Float64)
  assert_eq(result.row_count(), 1)
  // 10000.50 * 0.03 + 20000 * 0.02 + 2500 * 0.02 = 300.015 + 400 + 50 = 750.015
  match result.get(0, 0) {
    @types.Float64(v) => assert_true(near(v, 750.015))
    other => fail("expected float64 sum, got \{other.to_string()}")
  }
}

///|
test "all rows filtered out yields one row with NULL revenue" {
  // single row, wrong year: filter eliminates everything, SUM still emits
  // one NULL row per SQL aggregate semantics
  let content = "l_quantity,l_extendedprice,l_discount,l_shipdate\n" +
    "17.00,21168.23,0.04,1996-03-13\n"
  let cat = @catalog.Catalog::new()
  cat.register(
    @csv.scan_string(content, "lineitem") catch {
      e => abort("\{e}")
    },
  )
  let result = run(Q6_SQL, cat)
  assert_eq(result.row_count(), 1)
  assert_eq(result.get(0, 0), @types.Scalar::Null)
}

///|
test "null cells never pass WHERE and are skipped by SUM" {
  let content = "a,b\n1,10\n,20\n2,\n3,30\n"
  let cat = @catalog.Catalog::new()
  cat.register(@csv.scan_string(content, "t") catch { e => abort("\{e}") })
  let r = run("SELECT sum(a * b) AS s FROM t WHERE a > 0", cat)
  // int32 * int32 sums into int64; row2 has NULL a (filtered), row3 has
  // NULL b (product NULL, ignored by SUM)
  assert_eq(r.types()[0], @types.Int64)
  assert_eq(r.get(0, 0), @types.Scalar::Int64(100L))
}

///|
test "binder rejects unknown columns and tables" {
  let cat = q6_catalog()
  assert_true(
    run_err("SELECT sum(nope) AS s FROM lineitem", cat)
    .to_string()
    .contains("unknown column"),
  )
  assert_true(
    run_err("SELECT sum(a) AS s FROM missing", cat)
    .to_string()
    .contains("unknown table"),
  )
}
