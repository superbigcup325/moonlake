// Property tests: randomized, seeded model-based checks over the full
// engine pipeline (parse, join planning, hash join, hash aggregation,
// sort). Each failure reproduces: quickcheck prints the seed, and
// gen_table is deterministic in it.

///|
/// Deterministic small tables: k in 0..3, s in {a,b,c} with occasional
/// NULL (empty CSV cell), v in -5..14 with occasional NULL.
fn gen_table(seed : Int) -> (String, Array[(Int, String?, Int?)]) {
  let rng : Rng = { state: (seed.to_uint64() & 0xFFFFUL) | 0x9E37UL, }
  let n = 1 + rng.next() % 12
  let sb = StringBuilder()
  sb.write_string("k,s,v\n")
  let rows : Array[(Int, String?, Int?)] = []
  for _ in 0..<n {
    let k = rng.next() % 4
    let s : String? = match rng.next() % 8 {
      0 => None
      other => Some(["a", "b", "c"][other % 3])
    }
    let v : Int? = match rng.next() % 8 {
      0 => None
      other => Some(other % 20 - 5)
    }
    rows.push((k, s, v))
    let s_text = match s {
      Some(x) => x
      None => ""
    }
    let v_text = match v {
      Some(x) => x.to_string()
      None => ""
    }
    sb.write_string("\{k},\{s_text},\{v_text}\n")
  }
  (sb.to_string(), rows)
}

///|
priv struct Rng {
  mut state : UInt64
}

///|
fn Rng::next(self : Rng) -> Int {
  self.state = self.state * 6364136223846793005UL + 1442695040888963407UL
  (self.state >> 33).to_int()
}

///|
fn build_catalog(csv : String) -> @catalog.Catalog {
  let cat = @catalog.Catalog::new()
  cat.register(@csv.scan_string(csv, "t") catch { e => abort("\{e}") })
  cat
}

///|
fn run_q(sql : String, cat : @catalog.Catalog) -> @engine.SelectResult {
  @engine.run_select(sql, cat) catch {
    e => abort("\{e}")
  }
}

///|
fn as_int(s : @types.Scalar) -> Int? {
  match s {
    @types.Int32(x) => Some(x)
    @types.Int64(x) => Some(x.to_int())
    _ => None
  }
}

///|
/// Model for: SELECT k, count(*), count(v), sum(v), min(v), max(v)
///            FROM t WHERE s = 'a' GROUP BY k ORDER BY k
fn model_group(
  rows : Array[(Int, String?, Int?)],
) -> Array[(Int, (Int, Int, Int?, Int?, Int?))] {
  let picked : Array[(Int, Int?)] = []
  for row in rows {
    match row.1 {
      Some("a") => picked.push((row.0, row.2))
      _ => () // NULL s and other values never pass WHERE
    }
  }
  picked.sort_by((x, y) => x.0 - y.0)
  let out : Array[(Int, (Int, Int, Int?, Int?, Int?))] = []
  let mut i = 0
  while i < picked.length() {
    let k = picked[i].0
    let mut cnt = 0
    let mut cnt_v = 0
    let mut sum : Int? = Some(0)
    let mut lo : Int? = None
    let mut hi : Int? = None
    while i < picked.length() && picked[i].0 == k {
      cnt += 1
      match picked[i].1 {
        Some(v) => {
          cnt_v += 1
          sum = match sum {
            Some(acc) => Some(acc + v)
            None => None
          }
          match lo {
            Some(x) => if v < x { lo = Some(v) }
            None => lo = Some(v)
          }
          match hi {
            Some(x) => if v > x { hi = Some(v) }
            None => hi = Some(v)
          }
        }
        None => ()
      }
      i += 1
    }
    // a group whose v column is all NULL: sum is NULL, min/max NULL
    let _ = cnt_v
    out.push((k, (cnt, cnt_v, if cnt_v > 0 { sum } else { None }, lo, hi)))
  }
  out
}

///|
test "property: filter + group + aggregates match the model" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let (csv, rows) = gen_table(seed)
      let r = run_q(
        "SELECT k, count(*) AS c, count(v) AS cv, sum(v) AS s, min(v) AS lo, max(v) AS hi FROM t WHERE s = 'a' GROUP BY k ORDER BY k",
        build_catalog(csv),
      )
      let model = model_group(rows)
      let mut ok = r.row_count() == model.length()
      if ok {
        for i in 0..<model.length() {
          let m = model[i]
          ok = ok &&
            r.get(i, 0) == @types.Int32(m.0) &&
            r.get(i, 1) == @types.Int64(m.1.0.to_int64()) &&
            r.get(i, 2) == @types.Int64(m.1.1.to_int64()) &&
            r.get(i, 3) ==
            (match m.1.2 {
              Some(x) => @types.Int64(x.to_int64())
              None => @types.Null
            }) &&
            r.get(i, 4) ==
            (match m.1.3 {
              Some(x) => @types.Int32(x)
              None => @types.Null
            }) &&
            r.get(i, 5) ==
            (match m.1.4 {
              Some(x) => @types.Int32(x)
              None => @types.Null
            })
        }
      }
      ok
    }),
    max_success=80,
  )
}

///|
test "property: join is symmetric in sum(a.v + b.w)" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng : Rng = { state: (seed.to_uint64() & 0xFFFFUL) | 0xBEEFUL, }
      let build = fn(table : String) -> String {
        let sb = StringBuilder()
        sb.write_string("k,\{table}\n")
        for _ in 0..<(1 + rng.next() % 10) {
          sb.write_string("\{rng.next() % 4},\{rng.next() % 15}\n")
        }
        sb.to_string()
      }
      let cat = @catalog.Catalog::new()
      cat.register(
        @csv.scan_string(build("v"), "a") catch {
          e => abort("\{e}")
        },
      )
      cat.register(
        @csv.scan_string(build("w"), "b") catch {
          e => abort("\{e}")
        },
      )
      let left = as_int(
        run_q("SELECT sum(a.v + b.w) AS s FROM a, b WHERE a.k = b.k", cat).get(
          0, 0,
        ),
      )
      let right = as_int(
        run_q("SELECT sum(b.w + a.v) AS s FROM b, a WHERE b.k = a.k", cat).get(
          0, 0,
        ),
      )
      left == right
    }),
    max_success=80,
  )
}

///|
test "property: pushdown equals join-then-filter" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let (csv_a, _) = gen_table(seed)
      let rng : Rng = { state: (seed.to_uint64() & 0xFFFFUL) | 0x5EEDUL, }
      let sb = StringBuilder()
      sb.write_string("k,w\n")
      for _ in 0..<(1 + rng.next() % 10) {
        sb.write_string("\{rng.next() % 4},\{rng.next() % 9}\n")
      }
      let threshold = rng.next() % 10
      let cat = @catalog.Catalog::new()
      cat.register(@csv.scan_string(csv_a, "a") catch { e => abort("\{e}") })
      cat.register(
        @csv.scan_string(sb.to_string(), "b") catch {
          e => abort("\{e}")
        },
      )
      let pushed = as_int(
        run_q(
          "SELECT count(*) AS c FROM (SELECT k, v FROM a WHERE v > \{threshold}) a, b WHERE a.k = b.k",
          cat,
        ).get(0, 0),
      )
      let joined = as_int(
        run_q(
          "SELECT count(*) AS c FROM a, b WHERE a.k = b.k AND a.v > \{threshold}",
          cat,
        ).get(0, 0),
      )
      pushed == joined
    }),
    max_success=80,
  )
}

///|
test "property: sum over groups equals the whole-table sum" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let (csv, _) = gen_table(seed)
      let cat = build_catalog(csv)
      let total = as_int(run_q("SELECT sum(v) AS s FROM t", cat).get(0, 0))
      let grouped = run_q("SELECT k, sum(v) AS s FROM t GROUP BY k", cat)
      let mut acc : Int? = None
      for r in 0..<grouped.row_count() {
        match as_int(grouped.get(r, 1)) {
          Some(x) =>
            acc = match acc {
              Some(a) => Some(a + x)
              None => Some(x)
            }
          None => () // all-NULL group contributes nothing
        }
      }
      total == acc
    }),
    max_success=80,
  )
}

///|
/// Randomized differential property: for generated expressions over all
/// six column types (NULLs sprinkled on every column), eval_vec must
/// agree with eval_scalar cell for cell — value and NULL position — at
/// every batch size, including the scan batch size (4096) and its +-1
/// neighbors. Both-paths-NaN counts as equal (e.g. 0/0); everything
/// else must match exactly.

///|
priv enum VT {
  VI32
  VI64
  VF64
  VStr
  VBool
  VDate
}

///|
priv struct Rng2 {
  mut state : UInt64
}

///|
fn Rng2::next(self : Rng2) -> Int {
  self.state = self.state * 6364136223846793005UL + 1442695040888963407UL
  (self.state >> 33).to_int()
}

///|
fn vprop_seed(seed : Int) -> UInt64 {
  ((seed.to_uint64() & 0xFFFFFFFFUL) * 2654435761UL) | 0x9E3779B9UL
}

///|
/// Columns: 0=i32a(mag 100) 1=i32b(mag 5) 2=i64a 3=f64a 4=str 5=bool
/// 6=date. A NULL roughly every 9th (7th for str/bool) cell.
fn vprop_batch(n : Int, seed : Int) -> @types.DataBatch {
  let r : Rng2 = { state: vprop_seed(seed * 17 + 3), }
  let cols : Array[@types.ColumnVector] = []
  for spec in [(0, 100), (1, 5)] {
    let c = @types.ColumnVector::make(@types.Int32, n)
    for i in 0..<n {
      if r.next() % 9 == 0 {
        c.set(i, @types.Null)
      } else {
        c.set(i, @types.Int32(r.next() % (2 * spec.1 + 1) - spec.1))
      }
    }
    cols.push(c)
  }
  let ci = @types.ColumnVector::make(@types.Int64, n)
  for i in 0..<n {
    if r.next() % 9 == 0 {
      ci.set(i, @types.Null)
    } else {
      ci.set(i, @types.Int64((r.next() % 200 - 100).to_int64() * 1000000L))
    }
  }
  cols.push(ci)
  let cf = @types.ColumnVector::make(@types.Float64, n)
  for i in 0..<n {
    if r.next() % 9 == 0 {
      cf.set(i, @types.Null)
    } else {
      cf.set(i, @types.Float64((r.next() % 400 - 200).to_double() / 8.0))
    }
  }
  cols.push(cf)
  let cs = @types.ColumnVector::make(@types.Str, n)
  let words = ["apple", "apricot", "banana", "app", "Band", "band"]
  for i in 0..<n {
    if r.next() % 7 == 0 {
      cs.set(i, @types.Null)
    } else {
      cs.set(i, @types.Str(words[r.next() % words.length()]))
    }
  }
  cols.push(cs)
  let cb = @types.ColumnVector::make(@types.Bool, n)
  for i in 0..<n {
    if r.next() % 7 == 0 {
      cb.set(i, @types.Null)
    } else {
      cb.set(i, @types.Boolean(r.next() % 2 == 0))
    }
  }
  cols.push(cb)
  let cd = @types.ColumnVector::make(@types.Date, n)
  for i in 0..<n {
    if r.next() % 9 == 0 {
      cd.set(i, @types.Null)
    } else {
      cd.set(i, @types.Date(r.next() % 25000 - 2000))
    }
  }
  cols.push(cd)
  @types.DataBatch::new(cols, n)
}

///|
/// NaN-aware cell equality: NULL==NULL, both-NaN floats equal (both
/// paths may legitimately produce NaN via 0/0), else structural.
fn vprop_eq(a : @types.Scalar, b : @types.Scalar) -> Bool {
  match (a, b) {
    (@types.Null, @types.Null) => true
    (@types.Null, _) | (_, @types.Null) => false
    (@types.Float64(x), @types.Float64(y)) =>
      (x.is_nan() && y.is_nan()) || x == y
    _ => a == b
  }
}

///|
fn vprop_arith(r : Rng2) -> @types.ArithOp {
  match r.next() % 3 {
    0 => @types.Add
    1 => @types.Sub
    _ => @types.Mul
  }
}

///|
fn vprop_cmp(r : Rng2) -> @types.CmpOp {
  match r.next() % 6 {
    0 => @types.Eq
    1 => @types.Neq
    2 => @types.Lt
    3 => @types.Le
    4 => @types.Gt
    _ => @types.Ge
  }
}

///|
fn vprop_val_type(r : Rng2) -> VT {
  match r.next() % 6 {
    0 => VI32
    1 => VI64
    2 => VF64
    3 => VStr
    4 => VBool
    _ => VDate
  }
}

///|
fn vprop_leaf(r : Rng2, ty : VT) -> @engine.PhysExpr {
  match ty {
    VI32 =>
      match r.next() % 4 {
        0 => @engine.ColRef(0, @types.Int32)
        1 => @engine.ColRef(1, @types.Int32)
        2 => @engine.Const(@types.Int32(r.next() % 9 - 4))
        _ => @engine.Const(@types.Null)
      }
    VI64 =>
      match r.next() % 3 {
        0 => @engine.ColRef(2, @types.Int64)
        1 =>
          @engine.Const(@types.Int64((r.next() % 9 - 4).to_int64() * 1000000L))
        _ => @engine.Const(@types.Null)
      }
    VF64 =>
      match r.next() % 3 {
        0 => @engine.ColRef(3, @types.Float64)
        1 =>
          @engine.Const(@types.Float64((r.next() % 18 - 9).to_double() / 4.0))
        _ => @engine.Const(@types.Null)
      }
    VStr =>
      match r.next() % 3 {
        0 => @engine.ColRef(4, @types.Str)
        1 => @engine.Const(@types.Str("apple"))
        _ => @engine.Const(@types.Null)
      }
    VBool =>
      match r.next() % 3 {
        0 => @engine.ColRef(5, @types.Bool)
        1 => @engine.Const(@types.Boolean(true))
        _ => @engine.Const(@types.Null)
      }
    VDate =>
      match r.next() % 3 {
        0 => @engine.ColRef(6, @types.Date)
        1 => @engine.Const(@types.Date(19000))
        _ => @engine.Const(@types.Null)
      }
  }
}

///|
/// Typed random PhysExpr generator (depth-bounded). Every arm yields
/// exactly its target type: comparisons and IS NULL are Bool-only,
/// EXTRACT is Int32-only, and leaves fill the rest.
fn vprop_expr(r : Rng2, ty : VT, depth : Int) -> @engine.PhysExpr raise {
  if depth <= 0 {
    return vprop_leaf(r, ty)
  }
  match ty {
    VBool =>
      match r.next() % 8 {
        0 => vprop_leaf(r, ty)
        1 =>
          @engine.AndE(
            vprop_expr(r, VBool, depth - 1),
            vprop_expr(r, VBool, depth - 1),
          )
        2 =>
          @engine.OrE(
            vprop_expr(r, VBool, depth - 1),
            vprop_expr(r, VBool, depth - 1),
          )
        3 => @engine.NotE(vprop_expr(r, VBool, depth - 1))
        4 => @engine.LikeE(vprop_expr(r, VStr, depth - 1), vprop_pattern(r))
        5 =>
          @engine.IsNullE(
            vprop_expr(r, vprop_val_type(r), depth - 1),
            r.next() % 2 == 0,
          )
        6 => {
          let vt = vprop_val_type(r)
          @engine.CmpE(
            vprop_cmp(r),
            vprop_expr(r, vt, depth - 1),
            vprop_expr(r, vt, depth - 1),
          )
        }
        _ =>
          @engine.CaseE(
            [(vprop_expr(r, VBool, depth - 1), vprop_expr(r, VBool, depth - 1))],
            Some(vprop_expr(r, VBool, depth - 1)),
            @types.Bool,
          )
      }
    VI32 =>
      match r.next() % 6 {
        0 => vprop_leaf(r, ty)
        1 | 2 =>
          @engine.ArithE(
            vprop_arith(r),
            vprop_expr(r, VI32, depth - 1),
            vprop_expr(r, VI32, depth - 1),
            @types.Int32,
          )
        3 =>
          @engine.ExtractE(
            vprop_expr(r, VDate, depth - 1),
            if r.next() % 2 == 0 {
              Year
            } else {
              Day
            },
          )
        4 =>
          @engine.CaseE(
            [(vprop_expr(r, VBool, depth - 1), vprop_expr(r, VI32, depth - 1))],
            Some(vprop_expr(r, VI32, depth - 1)),
            @types.Int32,
          )
        _ =>
          @engine.ArithE(
            vprop_arith(r),
            vprop_expr(r, VI32, depth - 1),
            vprop_expr(r, VI32, depth - 1),
            @types.Int32,
          )
      }
    VI64 =>
      match r.next() % 4 {
        0 => vprop_leaf(r, ty)
        1 | 2 =>
          @engine.ArithE(
            vprop_arith(r),
            vprop_expr(r, VI64, depth - 1),
            vprop_expr(r, VI64, depth - 1),
            @types.Int64,
          )
        _ =>
          @engine.CaseE(
            [(vprop_expr(r, VBool, depth - 1), vprop_expr(r, VI64, depth - 1))],
            Some(vprop_expr(r, VI64, depth - 1)),
            @types.Int64,
          )
      }
    VF64 =>
      match r.next() % 5 {
        0 => vprop_leaf(r, ty)
        1 | 2 =>
          @engine.ArithE(
            if r.next() % 4 == 3 {
              @types.Div
            } else {
              vprop_arith(r)
            },
            vprop_expr(r, VF64, depth - 1),
            vprop_expr(r, VF64, depth - 1),
            @types.Float64,
          )
        3 =>
          @engine.CaseE(
            [(vprop_expr(r, VBool, depth - 1), vprop_expr(r, VF64, depth - 1))],
            Some(vprop_expr(r, VF64, depth - 1)),
            @types.Float64,
          )
        _ => vprop_leaf(r, ty)
      }
    VStr =>
      match r.next() % 5 {
        0 => vprop_leaf(r, ty)
        1 =>
          @engine.FuncE("upper", [vprop_expr(r, VStr, depth - 1)], @types.Str)
        2 =>
          @engine.FuncE(
            "concat",
            [vprop_expr(r, VStr, depth - 1), vprop_expr(r, VStr, depth - 1)],
            @types.Str,
          )
        3 =>
          @engine.FuncE(
            "substring",
            [
              vprop_expr(r, VStr, depth - 1),
              @engine.Const(@types.Int32(r.next() % 4)),
              @engine.Const(@types.Int32(r.next() % 5)),
            ],
            @types.Str,
          )
        _ =>
          @engine.CaseE(
            [(vprop_expr(r, VBool, depth - 1), vprop_expr(r, VStr, depth - 1))],
            Some(vprop_expr(r, VStr, depth - 1)),
            @types.Str,
          )
      }
    VDate =>
      match r.next() % 3 {
        0 => vprop_leaf(r, ty)
        _ =>
          @engine.DateArithE(
            vprop_expr(r, VDate, depth - 1),
            (r.next() % 400 - 200).to_int64(),
            match r.next() % 3 {
              0 => Days
              1 => Months
              _ => Years
            },
          )
      }
  }
}

///|
fn vprop_pattern(r : Rng2) -> String {
  let patterns = ["app%", "%an%", "b_nd", "%", "band", "%a%c%"]
  patterns[r.next() % patterns.length()]
}

///|
fn vprop_case(seed : Int) -> Bool raise {
  let r : Rng2 = { state: vprop_seed(seed * 31 + 7), }
  let sizes = [0, 1, 2, 3, 5, 17, 4095, 4096, 4097]
  let n = sizes[r.next() % sizes.length()]
  let batch = vprop_batch(n, seed)
  let types = [VI32, VI64, VF64, VStr, VBool, VDate]
  let mut ok = true
  for _ in 0..<4 {
    let e = vprop_expr(r, types[r.next() % 6], 1 + r.next() % 3)
    let v = @engine.eval_vec(e, batch)
    ok = ok && v.len() == n
    for row in 0..<n {
      if !vprop_eq(v.get(row), @engine.eval_scalar(e, batch, row)) {
        return false
      }
    }
  }
  ok
}

///|
test "property: eval_vec agrees with eval_scalar on random expressions" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      vprop_case(seed) catch {
        _ => false
      }
    }),
    max_success=60,
  )
}
