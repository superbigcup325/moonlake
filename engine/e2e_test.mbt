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

///|
const GROUP_SQL : String = "SELECT a, b, sum(v) AS s, count(*) AS c, avg(v) AS m FROM t GROUP BY a, b ORDER BY a, b"

///|
fn group_catalog() -> @catalog.Catalog {
  // two groups on (a,b) plus one all-NULL-v group
  let content = "a,b,v\n" +
    "1,x,10\n" +
    "1,x,20\n" +
    "1,y,5\n" +
    "2,x,\n" +
    "2,x,7\n"
  let cat = @catalog.Catalog::new()
  cat.register(@csv.scan_string(content, "t") catch { e => abort("\{e}") })
  cat
}

///|
test "group by two keys aggregates, counts and averages" {
  let r = run(GROUP_SQL, group_catalog())
  assert_eq(r.names(), ["a", "b", "s", "c", "m"])
  assert_eq(r.row_count(), 3)
  // group (1,x): sum 30, count 2, avg 15
  assert_eq(r.get(0, 0), @types.Scalar::Int32(1))
  assert_eq(r.get(0, 1), @types.Scalar::Str("x"))
  assert_eq(r.get(0, 2), @types.Scalar::Int64(30L))
  assert_eq(r.get(0, 3), @types.Scalar::Int64(2L))
  match r.get(0, 4) {
    @types.Float64(v) => assert_true(near(v, 15.0))
    other => fail("expected float64 avg, got \{other.to_string()}")
  }
  // group (1,y): sum 5, count 1
  assert_eq(r.get(1, 2), @types.Scalar::Int64(5L))
  assert_eq(r.get(1, 3), @types.Scalar::Int64(1L))
  // group (2,x): NULL v ignored by sum -> 7, count(*) counts both rows
  assert_eq(r.get(2, 2), @types.Scalar::Int64(7L))
  assert_eq(r.get(2, 3), @types.Scalar::Int64(2L))
}

///|
test "count(expr) skips NULLs, count(DISTINCT) deduplicates" {
  let cat = group_catalog()
  let r = run(
    "SELECT a, count(v) AS cv, count(DISTINCT b) AS db FROM t GROUP BY a ORDER BY a",
    cat,
  )
  assert_eq(r.row_count(), 2)
  // group a=1: three non-null v, b values {x,y}
  assert_eq(r.get(0, 1), @types.Scalar::Int64(3L))
  assert_eq(r.get(0, 2), @types.Scalar::Int64(2L))
  // group a=2: one non-null v (NULL skipped), b values {x}
  assert_eq(r.get(1, 1), @types.Scalar::Int64(1L))
  assert_eq(r.get(1, 2), @types.Scalar::Int64(1L))
}

///|
test "having filters groups after aggregation" {
  let cat = group_catalog()
  let r = run(
    "SELECT a, b, count(*) AS c FROM t GROUP BY a, b HAVING count(*) > 1 ORDER BY a, b",
    cat,
  )
  assert_eq(r.row_count(), 2)
  assert_eq(r.get(0, 1), @types.Scalar::Str("x"))
  assert_eq(r.get(0, 0), @types.Scalar::Int32(1))
  assert_eq(r.get(1, 0), @types.Scalar::Int32(2))
}

///|
test "order by desc with limit keeps the top rows" {
  let cat = group_catalog()
  let r = run(
    "SELECT a, b, sum(v) AS s FROM t GROUP BY a, b ORDER BY s DESC LIMIT 2", cat,
  )
  // sums: (1,x)=30, (1,y)=5, (2,x)=7 -> top two are 30 then 7
  assert_eq(r.row_count(), 2)
  assert_eq(r.get(0, 2), @types.Scalar::Int64(30L))
  assert_eq(r.get(1, 2), @types.Scalar::Int64(7L))
}

///|
test "min and max track per-group extrema" {
  let cat = group_catalog()
  let r = run(
    "SELECT a, min(v) AS lo, max(v) AS hi FROM t GROUP BY a ORDER BY a", cat,
  )
  // group a=1: v in {10, 20, 5}; group a=2: v in {NULL, 7}
  assert_eq(r.get(0, 1), @types.Scalar::Int32(5))
  assert_eq(r.get(0, 2), @types.Scalar::Int32(20))
  assert_eq(r.get(1, 1), @types.Scalar::Int32(7)) // NULL never becomes min
  assert_eq(r.get(1, 2), @types.Scalar::Int32(7))
}

///|
test "group by over empty input yields zero rows" {
  let content = "a,v\n"
  let cat = @catalog.Catalog::new()
  cat.register(@csv.scan_string(content, "t") catch { e => abort("\{e}") })
  let r = run("SELECT a, count(*) AS c FROM t GROUP BY a", cat)
  assert_eq(r.row_count(), 0)
}

///|
test "ungrouped column next to an aggregate is a bind error" {
  assert_true(
    run_err("SELECT a, sum(v) AS s FROM t", group_catalog())
    .to_string()
    .contains("must appear in GROUP BY"),
  )
  assert_true(
    run_err("SELECT a FROM t HAVING count(*) > 0", group_catalog())
    .to_string()
    .contains("must appear in GROUP BY"),
  )
}

///|
fn str_catalog(content : String) -> @catalog.Catalog {
  let cat = @catalog.Catalog::new()
  cat.register(@csv.scan_string(content, "t") catch { e => abort("\{e}") })
  cat
}

///|
test "like matches prefix, suffix and underscore, case-sensitively" {
  let cat = str_catalog("s\nPROMO x\nECONOMY x\nPROMO\npromo y\n")
  assert_eq(
    run("SELECT count(*) AS c FROM t WHERE s LIKE 'PROMO%'", cat).get(0, 0),
    @types.Scalar::Int64(2L), // 'promo y' differs in case
  )
  assert_eq(
    run("SELECT count(*) AS c FROM t WHERE s LIKE '%x%'", cat).get(0, 0),
    @types.Scalar::Int64(2L),
  )
  assert_eq(
    run("SELECT count(*) AS c FROM t WHERE s LIKE 'PROMO'", cat).get(0, 0),
    @types.Scalar::Int64(1L),
  )
  assert_eq(
    run("SELECT count(*) AS c FROM t WHERE s LIKE '_CONO%'", cat).get(0, 0),
    @types.Scalar::Int64(1L), // _ eats 'E', % eats "MY x"
  )
  assert_eq(
    run("SELECT count(*) AS c FROM t WHERE s LIKE 'ECONOM_ x'", cat).get(0, 0),
    @types.Scalar::Int64(1L),
  )
}

///|
test "case when picks branches and unifies numeric types" {
  let cat = str_catalog("v\n1\n2\n3\n")
  // v*10 (int) and v+100 (int) unify; sum widens to int64
  let r = run(
    "SELECT sum(CASE WHEN v <= 1 THEN v * 10 ELSE v + 100 END) AS s FROM t", cat,
  )
  assert_eq(r.types()[0], @types.Int64)
  assert_eq(r.get(0, 0), @types.Scalar::Int64(215L)) // 10 + 102 + 103
  // missing ELSE yields NULL, which the comparison drops
  assert_eq(
    run(
      "SELECT count(*) AS c FROM t WHERE CASE WHEN v > 2 THEN true END = true", cat,
    ).get(0, 0),
    @types.Scalar::Int64(1L),
  )
  // mixed int/float branches promote to float64
  let r2 = run(
    "SELECT sum(CASE WHEN v <= 1 THEN 0.5 ELSE v END) AS s FROM t", cat,
  )
  assert_eq(r2.types()[0], @types.Float64)
  match r2.get(0, 0) {
    @types.Float64(v) => assert_true(near(v, 5.5))
    other => fail("expected float64 sum, got \{other.to_string()}")
  }
}

///|
test "in list desugars into an equality chain" {
  let cat = str_catalog("v,s\n1,a\n2,b\n3,c\n,~\n")
  assert_eq(
    run("SELECT count(*) AS c FROM t WHERE v IN (1, 3)", cat).get(0, 0),
    @types.Scalar::Int64(2L),
  )
  assert_eq(
    run("SELECT count(*) AS c FROM t WHERE s IN ('a', 'c')", cat).get(0, 0),
    @types.Scalar::Int64(2L),
  )
  assert_eq(
    run("SELECT count(*) AS c FROM t WHERE v IN (9)", cat).get(0, 0),
    @types.Scalar::Int64(0L),
  )
}

///|
fn join_catalog() -> @catalog.Catalog {
  let cat = @catalog.Catalog::new()
  cat.register(
    @csv.scan_string("cid,seg\n1,a\n2,b\n3,a\n", "customers") catch {
      e => abort("\{e}")
    },
  )
  cat.register(
    @csv.scan_string(
      "oid,custkey,amount\n100,1,10\n101,1,20\n102,3,5\n103,,7\n", "orders",
    ) catch {
      e => abort("\{e}")
    },
  )
  cat
}

///|
test "inner join via comma list with WHERE equality" {
  let cat = join_catalog()
  let r = run(
    "SELECT count(*) AS c FROM customers, orders WHERE cid = custkey", cat,
  )
  // order 103 has NULL custkey: never matches
  assert_eq(r.get(0, 0), @types.Scalar::Int64(3L))
  // single-table conjuncts push to the probe/build sides
  let r2 = run(
    "SELECT count(*) AS c FROM customers, orders WHERE cid = custkey AND seg = 'a'",
    cat,
  )
  assert_eq(r2.get(0, 0), @types.Scalar::Int64(3L))
  let r3 = run(
    "SELECT count(*) AS c FROM customers, orders WHERE cid = custkey AND seg = 'b'",
    cat,
  )
  assert_eq(r3.get(0, 0), @types.Scalar::Int64(0L)) // customer 2 has no orders
}

///|
test "join ON syntax matches the comma form" {
  let cat = join_catalog()
  let r = run(
    "SELECT count(*) AS c FROM customers JOIN orders ON cid = custkey", cat,
  )
  assert_eq(r.get(0, 0), @types.Scalar::Int64(3L))
}

///|
test "aggregation over a join with group/order/limit" {
  let cat = join_catalog()
  let r = run(
    "SELECT seg, sum(amount) AS s FROM customers, orders WHERE cid = custkey GROUP BY seg ORDER BY s DESC LIMIT 1",
    cat,
  )
  assert_eq(r.row_count(), 1) // seg b drops out: no matching orders
  assert_eq(r.get(0, 0), @types.Scalar::Str("a"))
  assert_eq(r.get(0, 1), @types.Scalar::Int64(35L)) // 10 + 20 + 5
}

///|
test "left join keeps unmatched probe rows with NULL right side" {
  let cat = join_catalog()
  // count(oid) counts non-null values: the NULL-extended row counts 0,
  // and max(oid) over it is NULL
  let r = run(
    "SELECT cid, count(oid) AS c, max(oid) AS m FROM customers LEFT JOIN orders ON cid = custkey GROUP BY cid ORDER BY cid",
    cat,
  )
  assert_eq(r.row_count(), 3)
  assert_eq(r.get(0, 0), @types.Scalar::Int32(1))
  assert_eq(r.get(0, 1), @types.Scalar::Int64(2L))
  assert_eq(r.get(0, 2), @types.Scalar::Int32(101))
  assert_eq(r.get(1, 0), @types.Scalar::Int32(2))
  assert_eq(r.get(1, 1), @types.Scalar::Int64(0L))
  assert_eq(r.get(1, 2), @types.Scalar::Null)
  assert_eq(r.get(2, 0), @types.Scalar::Int32(3))
  assert_eq(r.get(2, 1), @types.Scalar::Int64(1L))
}

///|
/// Regression: a WHERE conjunct on the build (right) side of a LEFT JOIN
/// must stay a post-join filter. Pushing it into the build filter drops
/// build rows, so NULL-extended probe rows would survive a predicate
/// their NULL side cannot satisfy (duckdb-verified expectation).
test "left join keeps WHERE on the build side post-join" {
  let cat = join_catalog()
  // joined rows: (1,10), (1,20), (2,NULL), (3,5) — only (1,20) passes
  let r = run(
    "SELECT c.cid, o.amount FROM customers AS c LEFT JOIN orders AS o ON c.cid = o.custkey WHERE o.amount > 15",
    cat,
  )
  assert_eq(r.row_count(), 1)
  assert_eq(r.get(0, 0), @types.Scalar::Int32(1))
  assert_eq(r.get(0, 1), @types.Scalar::Int32(20))
  // same shape with an equality predicate
  let r2 = run(
    "SELECT c.cid FROM customers AS c LEFT JOIN orders AS o ON c.cid = o.custkey WHERE o.oid = 101",
    cat,
  )
  assert_eq(r2.row_count(), 1)
  assert_eq(r2.get(0, 0), @types.Scalar::Int32(1))
  // the preserved (probe) side still pushes down into the scan
  let r3 = run(
    "SELECT count(*) AS c FROM customers AS c LEFT JOIN orders AS o ON c.cid = o.custkey WHERE c.seg = 'a'",
    cat,
  )
  assert_eq(r3.get(0, 0), @types.Scalar::Int64(3L))
}

///|
test "cross join multiplies row counts" {
  let cat = join_catalog()
  let r = run("SELECT count(*) AS c FROM customers CROSS JOIN orders", cat)
  assert_eq(r.get(0, 0), @types.Scalar::Int64(12L))
}

///|
test "duplicate column names across FROM tables are ambiguous" {
  let cat = @catalog.Catalog::new()
  cat.register(
    @csv.scan_string("id,x\n1,2\n", "t1") catch {
      e => abort("\{e}")
    },
  )
  cat.register(
    @csv.scan_string("id,y\n3,4\n", "t2") catch {
      e => abort("\{e}")
    },
  )
  assert_true(
    run_err("SELECT count(*) AS c FROM t1, t2 WHERE id = id", cat)
    .to_string()
    .contains("ambiguous"),
  )
}

///|
test "plain projection returns rows without aggregation" {
  let cat = str_catalog("a,v\nb,1\na,5\nb,3\n")
  let r = run("SELECT a, v FROM t WHERE v > 1 ORDER BY a, v", cat)
  assert_eq(r.names(), ["a", "v"])
  assert_eq(r.row_count(), 2)
  assert_eq(r.get(0, 0), @types.Scalar::Str("a"))
  assert_eq(r.get(0, 1), @types.Scalar::Int32(5))
  assert_eq(r.get(1, 0), @types.Scalar::Str("b"))
  assert_eq(r.get(1, 1), @types.Scalar::Int32(3))
  // with limit
  let r2 = run("SELECT a FROM t ORDER BY a LIMIT 2", cat)
  assert_eq(r2.row_count(), 2)
  assert_eq(r2.get(0, 0), @types.Scalar::Str("a"))
  assert_eq(r2.get(1, 0), @types.Scalar::Str("b"))
}

///|
test "table alias is a column qualifier" {
  let cat = @catalog.Catalog::new()
  cat.register(
    @csv.scan_string("id,x\n1,10\n2,20\n", "t1") catch {
      e => abort("\{e}")
    },
  )
  cat.register(
    @csv.scan_string("id,tx\n1,7\n2,9\n", "t2") catch {
      e => abort("\{e}")
    },
  )
  let r = run(
    "SELECT a.id, b.tx FROM t1 a, t2 b WHERE a.id = b.id ORDER BY a.id", cat,
  )
  assert_eq(r.row_count(), 2)
  assert_eq(r.get(0, 0), @types.Scalar::Int32(1))
  assert_eq(r.get(0, 1), @types.Scalar::Int32(7))
  assert_eq(r.get(1, 1), @types.Scalar::Int32(9))
  assert_true(
    run_err("SELECT zzz.id FROM t1 a", cat)
    .to_string()
    .contains("unknown table or alias"),
  )
}

///|
test "extract year/month/day from dates" {
  let cat = str_catalog("d\n1996-03-13\n1995-01-29\n")
  let r = run(
    "SELECT extract(year from d) AS y, extract(month from d) AS m, extract(day from d) AS dd FROM t ORDER BY y, m, dd",
    cat,
  )
  assert_eq(r.types()[0], @types.Int32)
  assert_eq(r.get(0, 0), @types.Scalar::Int32(1995))
  assert_eq(r.get(0, 1), @types.Scalar::Int32(1))
  assert_eq(r.get(0, 2), @types.Scalar::Int32(29))
  assert_eq(r.get(1, 0), @types.Scalar::Int32(1996))
  // an empty cell among date rows is NULL and extracts to NULL
  let cat2 = str_catalog("d,tag\n,keep\n1996-03-13,keep\n")
  let r2 = run(
    "SELECT extract(year from d) AS y FROM t WHERE tag = 'keep' ORDER BY y", cat2,
  )
  assert_eq(r2.row_count(), 2)
  assert_eq(r2.get(0, 0), @types.Scalar::Int32(1996)) // NULLS LAST
  assert_eq(r2.get(1, 0), @types.Scalar::Null)
}

///|
test "not like and not in filter correctly with NULLs" {
  let cat = str_catalog("s,n\nalpha,1\nbeta,2\ngamma,3\n")
  assert_eq(
    run("SELECT count(*) AS c FROM t WHERE s NOT LIKE 'a%'", cat).get(0, 0),
    @types.Scalar::Int64(2L),
  )
  assert_eq(
    run("SELECT count(*) AS c FROM t WHERE n NOT IN (1, 3)", cat).get(0, 0),
    @types.Scalar::Int64(1L),
  )
  // NULL never passes NOT LIKE in either direction
  let cat2 = str_catalog("s,x\nalpha,1\n,2\nbeta,3\n")
  assert_eq(
    run("SELECT count(*) AS c FROM t WHERE s NOT LIKE 'a%'", cat2).get(0, 0),
    @types.Scalar::Int64(1L),
  )
}

///|
test "in and not in subqueries fold to sets" {
  let cat = @catalog.Catalog::new()
  cat.register(
    @csv.scan_string("k,v\n1,a\n2,b\n3,c\n", "t") catch {
      e => abort("\{e}")
    },
  )
  cat.register(
    @csv.scan_string("k\n1\n3\n5\n", "u") catch {
      e => abort("\{e}")
    },
  )
  assert_eq(
    run("SELECT count(*) AS c FROM t WHERE k IN (SELECT k FROM u)", cat).get(
      0, 0,
    ),
    @types.Scalar::Int64(2L),
  )
  assert_eq(
    run("SELECT count(*) AS c FROM t WHERE k NOT IN (SELECT k FROM u)", cat).get(
      0, 0,
    ),
    @types.Scalar::Int64(1L),
  )
  // a NULL in the subquery result makes NOT IN drop every row (SQL
  // three-valued semantics); IN is unaffected
  let cat2 = @catalog.Catalog::new()
  cat2.register(
    @csv.scan_string("k,v\n1,a\n2,b\n3,c\n", "t") catch {
      e => abort("\{e}")
    },
  )
  cat2.register(
    @csv.scan_string("k,tag\n1,x\n3,x\n,x\n5,x\n", "u") catch {
      e => abort("\{e}")
    },
  )
  assert_eq(
    run("SELECT count(*) AS c FROM t WHERE k IN (SELECT k FROM u)", cat2).get(
      0, 0,
    ),
    @types.Scalar::Int64(2L),
  )
  assert_eq(
    run("SELECT count(*) AS c FROM t WHERE k NOT IN (SELECT k FROM u)", cat2).get(
      0, 0,
    ),
    @types.Scalar::Int64(0L),
  )
}

///|
test "scalar subquery folds to a constant" {
  let cat = @catalog.Catalog::new()
  cat.register(
    @csv.scan_string("k,v\n1,10\n2,20\n3,30\n", "t") catch {
      e => abort("\{e}")
    },
  )
  let r = run("SELECT k, v FROM t WHERE v = (SELECT max(v) FROM t)", cat)
  assert_eq(r.row_count(), 1)
  assert_eq(r.get(0, 0), @types.Scalar::Int32(3))
  // in HAVING with aggregation
  let r2 = run(
    "SELECT k, count(*) AS c FROM t GROUP BY k HAVING sum(v) > (SELECT sum(v) FROM t) - 35",
    cat,
  )
  assert_eq(r2.row_count(), 1)
  assert_eq(r2.get(0, 0), @types.Scalar::Int32(3))
}

///|
test "is null and is not null select and filter NULL rows" {
  let cat = join_catalog()
  let r = run("SELECT count(*) AS c FROM orders WHERE custkey IS NULL", cat)
  assert_eq(r.get(0, 0), @types.Scalar::Int64(1L))
  let r2 = run(
    "SELECT oid FROM orders WHERE custkey IS NOT NULL ORDER BY oid", cat,
  )
  assert_eq(r2.row_count(), 3)
  assert_eq(r2.get(2, 0), @types.Scalar::Int32(102))
  // the only way to test NULL-ness inside a CASE condition
  let r3 = run(
    "SELECT count(*) AS c FROM orders WHERE CASE WHEN custkey IS NULL THEN 1 ELSE 0 END = 1",
    cat,
  )
  assert_eq(r3.get(0, 0), @types.Scalar::Int64(1L))
  // IS NULL is never true for non-null values under NOT (three-valued)
  let r4 = run(
    "SELECT count(*) AS c FROM orders WHERE NOT custkey IS NULL", cat,
  )
  assert_eq(r4.get(0, 0), @types.Scalar::Int64(3L))
}

///|
test "not between is the three-valued negation" {
  let cat = str_catalog("a,v\nb,1\na,5\nb,3\n")
  let r = run("SELECT count(*) AS c FROM t WHERE v NOT BETWEEN 2 AND 4", cat)
  assert_eq(r.get(0, 0), @types.Scalar::Int64(2L)) // 1 and 5
  // a NULL low bound makes BETWEEN unknown; for rows past the high bound
  // the AND folds to FALSE, so NOT flips them back to true (three-valued)
  let r2 = run(
    "SELECT count(*) AS c FROM t WHERE v NOT BETWEEN NULL AND 4", cat,
  )
  assert_eq(r2.get(0, 0), @types.Scalar::Int64(1L)) // only v = 5
}

///|
test "NULL literal compares as unknown and poisons NOT IN lists" {
  let cat = join_catalog()
  // v = NULL is UNKNOWN for every row, never true
  let r = run("SELECT count(*) AS c FROM orders WHERE amount = NULL", cat)
  assert_eq(r.get(0, 0), @types.Scalar::Int64(0L))
  let r2 = run("SELECT count(*) AS c FROM orders WHERE oid > NULL", cat)
  assert_eq(r2.get(0, 0), @types.Scalar::Int64(0L))
  // classic SQL trap: NOT IN against a list containing NULL is UNKNOWN
  // unless the value matches
  let r3 = run(
    "SELECT count(*) AS c FROM orders WHERE oid NOT IN (100, NULL)", cat,
  )
  assert_eq(r3.get(0, 0), @types.Scalar::Int64(0L))
  let r4 = run("SELECT count(*) AS c FROM orders WHERE oid IN (100, NULL)", cat)
  assert_eq(r4.get(0, 0), @types.Scalar::Int64(1L))
  // arithmetic with a NULL literal propagates; IS NULL observes it
  let r5 = run(
    "SELECT count(*) AS c FROM orders WHERE amount + NULL IS NULL", cat,
  )
  assert_eq(r5.get(0, 0), @types.Scalar::Int64(4L))
  // the live side defines the type, so a string column compares fine
  let r6 = run("SELECT count(*) AS c FROM customers WHERE seg = NULL", cat)
  assert_eq(r6.get(0, 0), @types.Scalar::Int64(0L))
}

///|
test "select star expands to every FROM column" {
  let cat = join_catalog()
  let r = run("SELECT * FROM customers ORDER BY cid", cat)
  assert_eq(r.names(), ["cid", "seg"])
  assert_eq(r.row_count(), 3)
  assert_eq(r.get(2, 0), @types.Scalar::Int32(3))
  // over a join: both tables' columns, probe side first
  let r2 = run("SELECT * FROM customers, orders WHERE cid = custkey", cat)
  assert_eq(r2.names(), ["cid", "seg", "oid", "custkey", "amount"])
  assert_eq(r2.row_count(), 3)
  // inside a derived table the expansion is the subquery's projection
  let r3 = run(
    "SELECT * FROM (SELECT cid FROM customers WHERE cid = 2) AS t", cat,
  )
  assert_eq(r3.names(), ["cid"])
  assert_eq(r3.row_count(), 1)
  // bare columns cannot be selected next to an aggregate
  assert_true(
    run_err("SELECT * FROM customers GROUP BY seg", cat)
    .to_string()
    .contains("GROUP BY"),
  )
}

///|
test "division is DuckDB true division: int/int is DOUBLE, /0 is inf/nan" {
  let cat = q6_catalog()
  // int32 / int32 promotes to Float64 with the exact quotient
  let r = run(
    "SELECT l_quantity / 2 AS half, l_quantity / 0 AS inf, l_quantity % 3 AS m, 10 % 3 AS im FROM lineitem WHERE l_quantity = 10",
    cat,
  )
  assert_eq(r.types(), [
    @types.Float64,
    @types.Float64,
    @types.Float64,
    @types.Int32,
  ])
  assert_eq(r.get(0, 0), @types.Scalar::Float64(5.0))
  assert_eq(r.get(0, 1), @types.Scalar::Float64(1.0 / 0.0))
  // 10.0 % 3.0 is fmod (sign of the dividend); literal ints stay Int32
  assert_eq(r.get(0, 2), @types.Scalar::Float64(1.0))
  assert_eq(r.get(0, 3), @types.Scalar::Int32(1))
  // 0.0/0.0 is nan (the /0 inf case is covered above), and the
  // NULL-literal operand gets the Div promotion too
  let r2 = run(
    "SELECT (l_quantity - 10) / (l_quantity - 10) AS nan, l_quantity / NULL AS nd FROM lineitem WHERE l_quantity = 10",
    cat,
  )
  assert_eq(r2.types()[0], @types.Float64)
  assert_true(r2.get(0, 0) is @types.Float64(v) && v.is_nan())
  assert_eq(r2.types()[1], @types.Float64)
  assert_eq(r2.get(0, 1), @types.Scalar::Null)
}

///|
/// Fixture for name-resolution tests: a table whose columns collide with
/// the DATE-part keywords, plus one column named like a join keyword.
fn kw_catalog() -> @catalog.Catalog {
  let cat = @catalog.Catalog::new()
  cat.register(
    @csv.scan_string(
      "day,month,year,date,left\nday-01,1,2024,2024-01-15,10\nday-02,2,2024,2024-02-01,20\n",
      "events",
    ) catch {
      e => abort("\{e}")
    },
  )
  cat
}

///|
test "DATE-part keywords resolve as column names" {
  let cat = kw_catalog()
  // bare reference in projection
  let r = run("SELECT day FROM events ORDER BY day", cat)
  assert_eq(r.row_count(), 2)
  assert_eq(r.get(1, 0), @types.Str("day-02"))
  // qualified and aliased references
  let r2 = run("SELECT e.day, e.year FROM events AS e WHERE e.month = 2", cat)
  assert_eq(r2.row_count(), 1)
  assert_eq(r2.get(0, 0), @types.Str("day-02"))
  assert_eq(r2.get(0, 1), @types.Int32(2024))
  // date-part column compared against a DATE literal (CSV auto-infers Date);
  // `left` is a JOIN keyword so it needs quoting, unlike the DATE parts
  let r3 = run(
    "SELECT \"left\" FROM events WHERE date >= date '2024-02-01'", cat,
  )
  assert_eq(r3.get(0, 0), @types.Int32(20))
  // EXTRACT keeps working alongside the keyword columns
  let r4 = run(
    "SELECT EXTRACT(year FROM date) AS y, \"left\" FROM events ORDER BY \"left\"",
    cat,
  )
  assert_eq(r4.row_count(), 2)
  assert_eq(r4.get(0, 0), @types.Int32(2024))
}

///|
test "double-quoted identifiers reach keyword names" {
  let cat = kw_catalog()
  let r = run("SELECT \"left\" FROM events WHERE \"day\" LIKE 'day-01%'", cat)
  assert_eq(r.row_count(), 1)
  assert_eq(r.get(0, 0), @types.Int32(10))
  // a fully reserved word is reachable only through quoting
  let cat2 = @catalog.Catalog::new()
  cat2.register(
    @csv.scan_string("select,from\n1,2\n", "kw") catch {
      e => abort("\{e}")
    },
  )
  let r2 = run("SELECT \"select\" + \"from\" FROM kw", cat2)
  assert_eq(r2.get(0, 0), @types.Int32(3))
  let err = run_err("SELECT \"unterminated FROM kw", cat2)
  assert_true(err.to_string().contains("unterminated quoted identifier"))
}

///|
test "integer literals widen: int32, int64, float64" {
  let cat = kw_catalog()
  let r = run(
    "SELECT 2147483648 AS big, 2147483647 AS fits32, \"left\" + 2147483648 AS s FROM events LIMIT 1",
    cat,
  )
  assert_eq(r.get(0, 0), @types.Scalar::Int64(2147483648L))
  assert_eq(r.get(0, 1), @types.Scalar::Int32(2147483647))
  assert_eq(r.get(0, 2), @types.Scalar::Int64(2147483658L)) // int32 col + int64 lit
  assert_eq(r.types()[2], @types.Int64)
}

///|
test "empty scalar subquery folds to NULL" {
  let cat = q6_catalog()
  // zero rows: comparison with NULL is UNKNOWN for every row -> empty, not an error
  let r = run(
    "SELECT l_quantity FROM lineitem WHERE l_extendedprice = (SELECT l_extendedprice FROM lineitem WHERE l_shipdate = date '1999-01-01')",
    cat,
  )
  assert_eq(r.row_count(), 0)
  let r2 = run(
    "SELECT l_quantity FROM lineitem WHERE l_extendedprice > (SELECT l_extendedprice FROM lineitem WHERE l_shipdate = date '1999-01-01')",
    cat,
  )
  assert_eq(r2.row_count(), 0)
  // more than one row is still a bind error
  let err = run_err(
    "SELECT l_quantity FROM lineitem WHERE l_extendedprice = (SELECT l_extendedprice FROM lineitem)",
    cat,
  )
  assert_true(err.to_string().contains("at most one row"))
}
