///|
/// Parser unit tests: precedence, BETWEEN chaining, DATE literals, errors.

///|
test "parse precedence and between" {
  // a BETWEEN 1 AND 2 AND b > 0: BETWEEN consumes its own AND first
  let sel = @engine.parse_select(
    "SELECT sum(x) AS s FROM t WHERE a BETWEEN 1 AND 2 AND b > 0",
  )
  match sel.filter {
    Some(And(_, _)) => ()
    _ => fail("expected top-level AND")
  }
  match sel.filter {
    Some(And(Between(Col("a"), _, _), Cmp(@types.Gt, Col("b"), _))) => ()
    _ => fail("expected BETWEEN chained with comparison")
  }
}

///|
test "arithmetic precedence: multiplication binds tighter" {
  let sel = @engine.parse_select(
    "SELECT sum(a) AS s FROM t WHERE a = 1 + 2 * 3",
  )
  match sel.filter {
    Some(
      Cmp(
        @types.Eq,
        Col("a"),
        Arith(
          @types.Add,
          Lit(@types.Scalar::Int32(1)),
          Arith(
            @types.Mul,
            Lit(@types.Scalar::Int32(2)),
            Lit(@types.Scalar::Int32(3))
          )
        )
      )
    ) => ()
    _ => fail("precedence shape mismatch")
  }
}

///|
test "case insensitive keywords" {
  let sel = @engine.parse_select("select SUM(a) revenue from t where x <> 1")
  assert_eq(sel.from[0].table, "t")
  assert_eq(sel.items[0].label, Some("revenue")) // bare alias (no AS)
  match sel.filter {
    Some(Cmp(@types.Neq, Col("x"), _)) => ()
    _ => fail("expected <> comparison")
  }
}

///|
test "parse errors carry stage info" {
  let err = parse_or_die("SELECT sum(a) FROM t WHERE")
  assert_true(err.to_string().contains("parse"))
}

///|
test "bad date literal is a parse error" {
  let err = parse_or_die("SELECT sum(a) FROM t WHERE d > date '1994-13-99'")
  assert_true(err.to_string().contains("DATE"))
}

///|
fn parse_or_die(sql : String) -> @types.SqlError {
  let _ = @engine.parse_select(sql) catch { e => return e }
  abort("expected a parse error")
}
