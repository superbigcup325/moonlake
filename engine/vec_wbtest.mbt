// Differential tests: eval_vec must agree with the scalar interpreter
// cell for cell on every PhysExpr shape. Fixture rows deliberately
// include NULLs on both sides of every operator; 0/0 (NaN) rows are
// excluded because structural equality cannot compare NaN — the e2e
// suite pins NaN via is_nan() instead.

///|
fn vec_fixture() -> @types.DataBatch {
  let n = 5
  // i1 = [10, -7, 0, NULL, 3], i2 = [3, 0, 4, 2, NULL]
  let i1 = @types.I32(FixedArray::make(n, 0), FixedArray::make(n, true))
  let i2 = @types.I32(FixedArray::make(n, 0), FixedArray::make(n, true))
  let irows : Array[(Int, Int)] = [(10, 3), (-7, 0), (0, 4), (0, 2), (3, 0)]
  for r in 0..<n {
    let (a, b) = irows[r]
    i1.set(r, @types.Int32(a))
    i2.set(r, @types.Int32(b))
  }
  let f1 = @types.F64(FixedArray::make(n, 0.0), FixedArray::make(n, true))
  let fvals = [-2.5, 0.0, 1000.0, 7.25, 0.0]
  for r in 0..<n {
    f1.set(r, @types.Float64(fvals[r]))
  }
  let s1 = @types.StrV(FixedArray::make(n, ""), FixedArray::make(n, true))
  let svals = ["apple", "apricot", "", "banana", "app"]
  for r in 0..<n {
    if svals[r] != "" {
      s1.set(r, @types.Str(svals[r]))
    }
  }
  let b1 = @types.BoolV(FixedArray::make(n, false), FixedArray::make(n, true))
  let bvals = [true, false, true, true, false]
  for r in 0..<n {
    b1.set(r, @types.Boolean(bvals[r]))
  }
  let d1 = @types.DateV(FixedArray::make(n, 0), FixedArray::make(n, true))
  let dvals = [0, 100, -1, 19000, 1]
  for r in 0..<n {
    d1.set(r, @types.Date(dvals[r]))
  }
  // row 2: s1 and b1 NULL; row 3: i1 NULL; row 4: i2 NULL, f1 NULL
  s1.set(2, @types.Null)
  b1.set(2, @types.Null)
  i1.set(3, @types.Null)
  i2.set(4, @types.Null)
  f1.set(4, @types.Null)
  @types.DataBatch::new([i1, i2, f1, s1, b1, d1], n)
}

///|
fn assert_vec_matches(e : PhysExpr, batch : @types.DataBatch) -> Unit raise {
  let v = eval_vec(e, batch)
  assert_eq(v.dtype(), expr_dtype(e))
  assert_eq(v.len(), batch.row_count())
  for r in 0..<batch.row_count() {
    assert_eq(v.get(r), eval_scalar(e, batch, r))
  }
}

///|
test "eval_vec matches eval_scalar on column refs and constants" {
  let b = vec_fixture()
  assert_vec_matches(ColRef(0, @types.Int32), b)
  assert_vec_matches(ColRef(2, @types.Float64), b)
  assert_vec_matches(ColRef(3, @types.Str), b)
  assert_vec_matches(ColRef(4, @types.Bool), b)
  assert_vec_matches(ColRef(5, @types.Date), b)
  assert_vec_matches(Const(@types.Int32(5)), b)
  assert_vec_matches(Const(@types.Float64(2.0)), b)
  assert_vec_matches(Const(@types.Str("x")), b)
  assert_vec_matches(Const(@types.Boolean(true)), b)
  assert_vec_matches(Const(@types.Null), b)
}

///|
test "eval_vec matches eval_scalar on promotions" {
  let b = vec_fixture()
  assert_vec_matches(Promote(ColRef(0, @types.Int32), @types.Int64), b)
  assert_vec_matches(Promote(ColRef(0, @types.Int32), @types.Float64), b)
  // identity promotion shares the column
  assert_vec_matches(Promote(ColRef(2, @types.Float64), @types.Float64), b)
}

///|
test "eval_vec matches eval_scalar on int arithmetic" {
  let b = vec_fixture()
  // binder invariant: int/int is promoted to Float64, so Div always
  // declares Float64 — the raw-operand form below exercises the
  // kernel's defensive path with the dtype the binder would emit
  for op in [@types.Add, @types.Sub, @types.Mul, @types.Mod] {
    assert_vec_matches(
      ArithE(op, ColRef(0, @types.Int32), ColRef(1, @types.Int32), @types.Int32),
      b,
    )
    assert_vec_matches(
      ArithE(
        op,
        Promote(ColRef(0, @types.Int32), @types.Int64),
        Promote(ColRef(1, @types.Int32), @types.Int64),
        @types.Int64,
      ),
      b,
    )
  }
  assert_vec_matches(
    ArithE(
      @types.Div,
      ColRef(0, @types.Int32),
      ColRef(1, @types.Int32),
      @types.Float64,
    ),
    b,
  )
  assert_vec_matches(
    ArithE(
      @types.Div,
      Promote(ColRef(0, @types.Int32), @types.Int64),
      Promote(ColRef(1, @types.Int32), @types.Int64),
      @types.Float64,
    ),
    b,
  )
}

///|
test "eval_vec matches eval_scalar on float arithmetic" {
  let b = vec_fixture()
  for op in [@types.Add, @types.Sub, @types.Mul, @types.Div, @types.Mod] {
    assert_vec_matches(
      ArithE(
        op,
        ColRef(2, @types.Float64),
        Const(@types.Float64(3.0)),
        @types.Float64,
      ),
      b,
    )
  }
  // float % 0 is NULL, fmod keeps the dividend's sign
  assert_vec_matches(
    ArithE(
      @types.Mod,
      ColRef(2, @types.Float64),
      Const(@types.Float64(0.0)),
      @types.Float64,
    ),
    b,
  )
  assert_vec_matches(
    ArithE(
      @types.Mod,
      Const(@types.Float64(-10.5)),
      Const(@types.Float64(3.0)),
      @types.Float64,
    ),
    b,
  )
}

///|
test "eval_vec matches eval_scalar on comparisons" {
  let b = vec_fixture()
  for op in [@types.Eq, @types.Neq, @types.Lt, @types.Le, @types.Gt, @types.Ge] {
    assert_vec_matches(
      CmpE(op, ColRef(0, @types.Int32), ColRef(1, @types.Int32)),
      b,
    )
    assert_vec_matches(
      CmpE(op, ColRef(0, @types.Int32), Const(@types.Int32(3))),
      b,
    )
    assert_vec_matches(
      CmpE(op, ColRef(2, @types.Float64), Const(@types.Float64(0.0))),
      b,
    )
    assert_vec_matches(
      CmpE(op, ColRef(5, @types.Date), Const(@types.Date(100))),
      b,
    )
    assert_vec_matches(
      CmpE(op, ColRef(4, @types.Bool), Const(@types.Boolean(true))),
      b,
    )
  }
  // dictionary order, not length-first: "app" < "apple" < "apricot"
  assert_vec_matches(
    CmpE(@types.Gt, ColRef(3, @types.Str), Const(@types.Str("app"))),
    b,
  )
  assert_vec_matches(
    CmpE(@types.Lt, ColRef(3, @types.Str), Const(@types.Str("azz"))),
    b,
  )
}

///|
test "eval_vec matches eval_scalar on three-valued logic" {
  let b = vec_fixture()
  let bl = ColRef(4, @types.Bool)
  // row 2 is NULL: NULL AND true -> NULL, NULL AND false -> false
  // (false dominates), NULL OR true -> true, NULL OR false -> NULL
  assert_vec_matches(AndE(bl, Const(@types.Boolean(true))), b)
  assert_vec_matches(AndE(bl, Const(@types.Boolean(false))), b)
  assert_vec_matches(OrE(bl, Const(@types.Boolean(true))), b)
  assert_vec_matches(OrE(bl, Const(@types.Boolean(false))), b)
  assert_vec_matches(NotE(bl), b)
  assert_vec_matches(
    AndE(
      CmpE(@types.Lt, ColRef(0, @types.Int32), Const(@types.Int32(5))),
      OrE(
        CmpE(@types.Gt, ColRef(1, @types.Int32), Const(@types.Int32(0))),
        IsNullE(ColRef(3, @types.Str), false),
      ),
    ),
    b,
  )
}

///|
test "eval_vec matches eval_scalar on IS NULL" {
  let b = vec_fixture()
  assert_vec_matches(IsNullE(ColRef(0, @types.Int32), false), b)
  assert_vec_matches(IsNullE(ColRef(0, @types.Int32), true), b)
  assert_vec_matches(IsNullE(ColRef(3, @types.Str), false), b)
}

///|
test "eval_vec matches eval_scalar on the fallback shapes" {
  let b = vec_fixture()
  assert_vec_matches(ExtractE(ColRef(5, @types.Date), Year), b)
  assert_vec_matches(ExtractE(ColRef(5, @types.Date), Month), b)
  assert_vec_matches(ExtractE(ColRef(5, @types.Date), Day), b)
  assert_vec_matches(LikeE(ColRef(3, @types.Str), "app%"), b)
  assert_vec_matches(LikeE(ColRef(3, @types.Str), "_pple"), b)
  assert_vec_matches(LikeE(ColRef(3, @types.Str), "%a%"), b)
  let set : Map[String, Bool] = { "2:10": true, "2:-7": true }
  assert_vec_matches(InSetE(ColRef(0, @types.Int32), set, false, false), b)
  assert_vec_matches(InSetE(ColRef(0, @types.Int32), set, true, false), b)
  let null_set : Map[String, Bool] = { "2:99": true }
  assert_vec_matches(InSetE(ColRef(0, @types.Int32), null_set, true, true), b)
  assert_vec_matches(
    CaseE(
      [
        (
          CmpE(@types.Gt, ColRef(0, @types.Int32), Const(@types.Int32(0))),
          Const(@types.Int32(1)),
        ),
      ],
      Some(Const(@types.Int32(2))),
      @types.Int32,
    ),
    b,
  )
  assert_vec_matches(
    CaseE(
      [
        (
          CmpE(@types.Gt, ColRef(0, @types.Int32), Const(@types.Int32(0))),
          Const(@types.Int32(1)),
        ),
      ],
      None,
      @types.Int32,
    ),
    b,
  )
}

///|
test "eval_vec matches eval_scalar on nested filter shapes" {
  let b = vec_fixture()
  assert_vec_matches(
    ArithE(
      @types.Add,
      ArithE(
        @types.Mul,
        ColRef(0, @types.Int32),
        ColRef(0, @types.Int32),
        @types.Int32,
      ),
      ColRef(0, @types.Int32),
      @types.Int32,
    ),
    b,
  )
  assert_vec_matches(
    ArithE(
      @types.Div,
      Promote(ColRef(0, @types.Int32), @types.Float64),
      Promote(ColRef(1, @types.Int32), @types.Float64),
      @types.Float64,
    ),
    b,
  )
}
