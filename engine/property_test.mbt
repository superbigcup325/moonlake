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
