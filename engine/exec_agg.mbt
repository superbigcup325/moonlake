// Eager aggregation: the accumulator structs and their fold, the two groupers
// (a typed key path for the common shapes, one reusable boxed-key path for the
// rest), and aggregate/aggregate_seq. The pull form takes a BatchSeq, so one
// fold serves both the in-memory batch array and the grace aggregation's spill
// runs -- engine/extagg.mbt is the over-budget caller.

///|
/// One running accumulator per aggregate spec. Mutable state lives in
/// the payload structs so a fold step updates in place — the enum value
/// itself is allocated once per group, not once per step.
priv struct AccSumI {
  mut sum : Int64
  mut seen : Bool
  mut overflowed : Bool
}

///|
priv struct AccSumF {
  mut sum : Double
  mut seen : Bool
}

///|
priv struct AccAvgF {
  mut sum : Double
  mut count : Int64
}

///|
priv struct AccCount {
  mut count : Int64
}

///|
priv struct AccDistinct {
  seen : Map[String, Bool]
}

///|
priv struct AccVar {
  mut mean : Double
  mut m2 : Double
  mut count : Int64
}

///|
priv struct AccMed {
  vals : Array[Double]
}

///|
priv struct AccStrAgg {
  mut text : String
  mut seen : Bool
}

///|
priv struct AccMinMax {
  mut cur : @types.Scalar
  mut seen : Bool
}

///|
priv struct AccHll {
  sketch : @sketches.HllSketch
}

///|
priv struct AccQuant {
  digest : @sketches.TDigest
  mut bad_input : Bool // a NaN or infinity reached the digest
}

///|
priv enum Acc {
  SumI(AccSumI)
  SumF(AccSumF)
  AvgF(AccAvgF)
  CountOf(AccCount)
  Distinct(AccDistinct)
  VarF(AccVar)
  MedV(AccMed)
  StrAgg(AccStrAgg)
  MinMax(AccMinMax)
  Hll(AccHll)
  Quant(AccQuant)
}

///|
fn new_accs(aggs : Array[AggSpec]) -> Array[Acc] {
  let row : Array[Acc] = []
  for spec in aggs {
    row.push(
      match spec.kind {
        Sum =>
          match spec.out_type {
            @types.Int64 => SumI({ sum: 0L, seen: false, overflowed: false, })
            _ => SumF({ sum: 0.0, seen: false, })
          }
        Avg => AvgF({ sum: 0.0, count: 0L, })
        Count | CountStar => CountOf({ count: 0L, })
        CountDistinct => Distinct({ seen: Map([]), })
        StringAgg => StrAgg({ text: "", seen: false, })
        SdSamp | SdPop | VarSamp | VarPop =>
          VarF({ mean: 0.0, m2: 0.0, count: 0L, })
        Median => MedV({ vals: [], })
        Min | Max => MinMax({ cur: @types.Null, seen: false, })
        ApproxCountDistinct =>
          Hll({ sketch: @sketches.HllSketch::new_default(), })
        ApproxQuantile =>
          Quant({ digest: @sketches.TDigest::new_default(), bad_input: false, })
      },
    )
  }
  row
}

///|
fn as_double(v : @types.Scalar) -> Double? {
  match v {
    @types.Int32(x) => Some(x.to_double())
    @types.Int64(x) => Some(x.to_double())
    @types.Float64(x) => Some(x)
    _ => None
  }
}

///|
/// Fold one input value into the accumulator, in place. `input` is the
/// pre-evaluated aggregate input for one row; Null inputs are skipped
/// (aggregates ignore NULL).
fn acc_step(acc : Acc, spec : AggSpec, input : @types.Scalar) -> Unit {
  if spec.kind is CountStar {
    match acc {
      CountOf(a) => a.count += 1L
      _ => ()
    }
    return
  }
  match input {
    @types.Null => () // aggregates ignore NULL inputs
    v =>
      match acc {
        SumI(a) =>
          // checked add: overflow when the operands share a sign that
          // the sum does not (int64 sums wrap silently otherwise)
          match v {
            @types.Int32(x) => {
              let b = x.to_int64()
              let sum = a.sum + b
              if ((a.sum ^ sum) & (b ^ sum)) < 0L {
                a.overflowed = true
              }
              a.sum = sum
              a.seen = true
            }
            @types.Int64(x) => {
              let sum = a.sum + x
              if ((a.sum ^ sum) & (x ^ sum)) < 0L {
                a.overflowed = true
              }
              a.sum = sum
              a.seen = true
            }
            _ => ()
          }
        SumF(a) =>
          match as_double(v) {
            Some(x) => {
              a.sum += x
              a.seen = true
            }
            None => ()
          }
        AvgF(a) =>
          match as_double(v) {
            Some(x) => {
              a.sum += x
              a.count += 1L
            }
            None => ()
          }
        StrAgg(a) =>
          match v {
            @types.Str(s) => {
              let sep = match spec.sep {
                Some(x) => x
                None => ""
              }
              a.text = if a.seen { a.text + sep + s } else { s }
              a.seen = true
            }
            _ => ()
          }
        CountOf(a) => a.count += 1L
        VarF(a) =>
          match as_double(v) {
            Some(x) => {
              // Welford: numerically stable online variance
              let c2 = a.count + 1L
              let delta = x - a.mean
              a.mean += delta / c2.to_double()
              a.m2 += delta * (x - a.mean)
              a.count = c2
            }
            None => ()
          }
        MedV(a) =>
          match as_double(v) {
            Some(x) => a.vals.push(x)
            None => ()
          }
        Distinct(a) => a.seen[scalar_key(v)] = true
        MinMax(a) =>
          if !a.seen {
            a.cur = v
            a.seen = true
          } else {
            let c = @types.Scalar::compare_nn(v, a.cur)
            match spec.kind {
              Min => if c < 0 { a.cur = v }
              Max => if c > 0 { a.cur = v }
              _ => ()
            }
          }
        Hll(a) => hll_add(a.sketch, v)
        Quant(a) =>
          match as_double(v) {
            Some(x) =>
              if x.is_nan() || x.is_inf() {
                // the digest rejects non-finite values; the fold cannot
                // raise, so the finish step reports it for the query
                a.bad_input = true
              } else {
                a.digest.update(x) catch {
                  _ => a.bad_input = true
                }
              }
            None => ()
          }
      }
  }
}

///|
fn acc_finish(acc : Acc, spec : AggSpec) -> @types.Scalar raise @types.SqlError {
  match acc {
    SumI(a) =>
      if a.overflowed {
        raise @types.SqlError::Execute(
          "sum() overflows int64; widen the input or filter values",
        )
      } else if a.seen {
        @types.Int64(a.sum)
      } else {
        @types.Null
      }
    VarF(a) => {
      // samp needs a second observation; pop needs a first
      let samp = spec.kind is SdSamp || spec.kind is VarSamp
      let ok = if samp { a.count >= 2L } else { a.count >= 1L }
      if !ok {
        @types.Null
      } else {
        let denom = if samp {
          (a.count - 1L).to_double()
        } else {
          a.count.to_double()
        }
        let variance = a.m2 / denom
        // the Sd* kinds are the square root; Var* stay as variance
        @types.Float64(
          if spec.kind is SdSamp || spec.kind is SdPop {
            variance.sqrt()
          } else {
            variance
          },
        )
      }
    }
    StrAgg(a) => if a.seen { @types.Str(a.text) } else { @types.Null }
    MedV(a) => {
      if a.vals.length() == 0 {
        return @types.Null
      }
      a.vals.sort()
      let n = a.vals.length()
      if n % 2 == 1 {
        @types.Float64(a.vals[n / 2])
      } else {
        @types.Float64((a.vals[n / 2 - 1] + a.vals[n / 2]) / 2.0)
      }
    }
    SumF(a) => if a.seen { @types.Float64(a.sum) } else { @types.Null }
    AvgF(a) =>
      if a.count > 0L {
        @types.Float64(a.sum / a.count.to_double())
      } else {
        @types.Null
      }
    CountOf(a) => @types.Int64(a.count)
    Distinct(a) => @types.Int64(a.seen.length().to_int64())
    MinMax(a) => if a.seen { a.cur } else { @types.Null }
    Hll(a) => @types.Int64(hll_round(a.sketch.estimate()))
    Quant(a) => {
      if a.bad_input {
        raise @types.SqlError::Execute(
          "approx_quantile() requires finite input; the column holds NaN or infinity",
        )
      }
      let q = match spec.q {
        Some(q) => q
        None =>
          raise @types.SqlError::Execute(
            "internal: approx_quantile() bound without a quantile",
          )
      }
      if a.digest.count() == 0.0 {
        @types.Null
      } else {
        @types.Float64(
          a.digest.quantile(q) catch {
            e =>
              raise @types.SqlError::Execute(
                "approx_quantile(): \{@colenc_types.EncodingError::message(e)}",
              )
          },
        )
      }
    }
  }
}

///|
/// Feed one value to the distinct sketch in the canonical form the exact
/// path's `scalar_key` uses: floats by value (both zeros are one value,
/// every NaN is one value), strings as their UTF-8 bytes, dates as their
/// epoch day.
fn hll_add(sketch : @sketches.HllSketch, v : @types.Scalar) -> Unit {
  match v {
    @types.Boolean(b) => sketch.add_bool(b)
    @types.Int32(x) => sketch.add_int32(x)
    @types.Int64(x) => sketch.add_int64(x)
    @types.Date(d) => sketch.add_int32(d)
    @types.Str(s) => sketch.add_bytes(@utf8.encode(s))
    @types.Float64(x) =>
      if x.is_nan() {
        // one canonical NaN whatever the payload or sign: the exact path
        // compares their text form, which is "NaN" for all of them
        sketch.add_double(0x7FF8000000000001L.reinterpret_as_double())
      } else if x == 0.0 {
        sketch.add_double(0.0) // -0.0 and 0.0 print the same
      } else {
        sketch.add_double(x)
      }
    @types.Null => ()
  }
}

///|
/// Round a cardinality estimate to the nearest integer, never below zero.
fn hll_round(v : Double) -> Int64 {
  if v <= 0.0 {
    0L
  } else {
    (v + 0.5).to_int64()
  }
}

///|
/// Type-tagged, length-prefixed key text so distinct scalars never
/// collide across groups or join lookups.
fn scalar_key(v : @types.Scalar) -> String {
  let sb = StringBuilder()
  match v {
    @types.Null => sb.write_string("0:")
    @types.Boolean(b) => {
      sb.write_string("1:")
      sb.write_string(if b { "T" } else { "F" })
    }
    @types.Int32(x) => {
      sb.write_string("2:")
      sb.write_string(x.to_string())
    }
    @types.Int64(x) => {
      sb.write_string("3:")
      sb.write_string(x.to_string())
    }
    @types.Float64(x) => {
      sb.write_string("4:")
      sb.write_string(x.to_string())
    }
    @types.Str(s) => {
      sb.write_string("5:")
      sb.write_string(s.length().to_string())
      sb.write_char(':')
      sb.write_string(s)
    }
    @types.Date(d) => {
      sb.write_string("6:")
      sb.write_string(d.to_string())
    }
  }
  sb.to_string()
}

///|
fn canonical_key(vals : Array[@types.Scalar]) -> String {
  let sb = StringBuilder()
  for v in vals {
    sb.write_string(scalar_key(v))
    sb.write_char('\u{0001}')
  }
  sb.to_string()
}

///|
/// How the group index maps a row to its group id. Single int and
/// single string keys hash the raw column value — no per-row key
/// building at all (the string key IS the column's string); every other
/// shape shares one reusable key builder and materializes the boxed
/// key row once per group, not once per row. Nulls never enter the
/// maps: the first null-keyed row opens a shared null group.
priv enum Grouper {
  GZero // no GROUP BY: exactly one group
  GI32(Map[Int64, Int32])
  GI64(Map[Int64, Int32])
  GDate(Map[Int64, Int32])
  GStr(Map[String, Int32])
  GText(Map[String, Int32], StringBuilder)
}

///|
/// A numeric aggregate input resolved to its raw typed arrays, so the
/// fold loop skips the boxed Scalar per cell. MinMax (must return the
/// input's own dtype), CountDistinct (needs the boxed key) and
/// non-numeric inputs stay boxed.
priv enum FastInput {
  FBoxed(@types.ColumnVector)
  FI32(FixedArray[Int32], FixedArray[Bool])
  FI64(FixedArray[Int64], FixedArray[Bool])
  FF64(FixedArray[Double], FixedArray[Bool])
}

///|
fn fast_input_of(v : @types.ColumnVector, spec : AggSpec) -> FastInput {
  let numeric_kind = match spec.kind {
    Sum | Avg | Count | SdSamp | SdPop | VarSamp | VarPop | Median => true
    _ => false
  }
  if !numeric_kind {
    return FBoxed(v)
  }
  match v {
    @types.I32(d, valid) => FI32(d, valid)
    @types.I64(d, valid) => FI64(d, valid)
    @types.F64(d, valid) => FF64(d, valid)
    _ => FBoxed(v)
  }
}

///|
/// Fold one valid numeric cell into the accumulator, given in both
/// int64 and double views. Only the numeric fold kinds reach this —
/// the binder never pairs them with a dtype the views cannot carry.
fn acc_step_num(acc : Acc, as_int : Int64, as_f64 : Double) -> Unit {
  match acc {
    SumI(a) => {
      // checked add, same rule as acc_step
      let sum = a.sum + as_int
      if ((a.sum ^ sum) & (as_int ^ sum)) < 0L {
        a.overflowed = true
      }
      a.sum = sum
      a.seen = true
    }
    SumF(a) => {
      a.sum += as_f64
      a.seen = true
    }
    AvgF(a) => {
      a.sum += as_f64
      a.count += 1L
    }
    CountOf(a) => a.count += 1L
    VarF(a) => {
      let c2 = a.count + 1L
      let delta = as_f64 - a.mean
      a.mean += delta / c2.to_double()
      a.m2 += delta * (as_f64 - a.mean)
      a.count = c2
    }
    MedV(a) => a.vals.push(as_f64)
    _ => ()
  }
}

///|
/// A pull-based batch source for aggregation. `next` returns `None`
/// exactly once, at the end.
priv struct BatchSeq {
  next : () -> @types.DataBatch? raise @types.SqlError
}

///|
/// A sequence over batches the caller already holds.
fn BatchSeq::of_batches(batches : Array[@types.DataBatch]) -> BatchSeq {
  let mut i = 0
  {
    next: fn() {
      if i < batches.length() {
        let b = batches[i]
        i += 1
        Some(b)
      } else {
        None
      }
    },
  }
}

///|
/// A sequence over spill files: each file is decoded when the cursor
/// reaches it and dropped once its batches have been consumed, so a
/// partition made of many runs stays bounded by one run file.
fn BatchSeq::of_runs(store : SpillStore, ids : Array[Int32]) -> BatchSeq {
  let mut file = 0
  let mut decoded : Array[@types.DataBatch] = []
  let mut inner = 0
  {
    next: fn() -> @types.DataBatch? raise @types.SqlError {
      let mut out : @types.DataBatch? = None
      let mut done = false
      while !done {
        if inner < decoded.length() {
          out = Some(decoded[inner])
          inner += 1
          done = true
        } else if file < ids.length() {
          decoded = @types.DataBatch::from_spill_bytes((store.read)(ids[file]))
          inner = 0
          file += 1
        } else {
          done = true
        }
      }
      out
    },
  }
}

///|
/// Hash aggregation: one output row per distinct group key (in first-
/// seen order). With no GROUP BY the result is exactly one row, even for
/// empty input.
fn aggregate(
  batches : Array[@types.DataBatch],
  group_exprs : Array[PhysExpr],
  group_types : Array[@types.DataType],
  aggs : Array[AggSpec],
) -> @types.DataBatch raise @types.SqlError {
  aggregate_seq(BatchSeq::of_batches(batches), group_exprs, group_types, aggs)
}

///|
/// The pull form of `aggregate`: the group state is built batch by batch,
/// so a caller that decodes spill runs (grace aggregation) never holds a
/// whole partition in memory — one run file plus the state at most.
fn aggregate_seq(
  seq : BatchSeq,
  group_exprs : Array[PhysExpr],
  group_types : Array[@types.DataType],
  aggs : Array[AggSpec],
  census~ : MemCensus? = None,
) -> @types.DataBatch raise @types.SqlError {
  if col_agg_plan(group_types, aggs) is Some(kinds) {
    return aggregate_cols(seq, group_exprs, group_types, kinds, aggs, census~)
  }
  let g = group_exprs.length()
  let m = aggs.length()
  let grouper : Grouper = if g == 0 {
    GZero
  } else if g == 1 {
    match group_types[0] {
      @types.Int32 => GI32(Map([]))
      @types.Int64 => GI64(Map([]))
      @types.Date => GDate(Map([]))
      @types.Str => GStr(Map([]))
      _ => GText(Map([]), StringBuilder())
    }
  } else {
    GText(Map([]), StringBuilder())
  }
  let group_keys : Array[Array[@types.Scalar]] = []
  let acc_rows : Array[Array[Acc]] = []
  let mut null_gi = -1
  let mut zero_created = false
  while (seq.next)() is Some(batch) {
    // evaluate group keys and aggregate inputs once per batch, then the
    // row loop reads the materialized columns
    let key_cols : Array[@types.ColumnVector] = []
    for e in group_exprs {
      key_cols.push(eval_vec(e, batch))
    }
    let input_cols : Array[FastInput] = []
    for spec in aggs {
      match spec.input {
        Some(e) => input_cols.push(fast_input_of(eval_vec(e, batch), spec))
        None =>
          input_cols.push(FBoxed(@types.ColumnVector::make(@types.Int32, 0)))
      }
    }
    for r in 0..<batch.row_count() {
      let gi = match grouper {
        GZero =>
          if zero_created {
            0
          } else {
            zero_created = true
            group_keys.push([])
            acc_rows.push(new_accs(aggs))
            0
          }
        GI32(map) =>
          match key_cols[0] {
            @types.I32(d, valid) =>
              if valid[r] {
                let k = d[r].to_int64()
                match map.get(k) {
                  Some(i) => i
                  None => {
                    let i = group_keys.length()
                    map[k] = i
                    group_keys.push([@types.Int32(d[r])])
                    acc_rows.push(new_accs(aggs))
                    i
                  }
                }
              } else {
                if null_gi < 0 {
                  null_gi = group_keys.length()
                  group_keys.push([@types.Null])
                  acc_rows.push(new_accs(aggs))
                }
                null_gi
              }
            _ =>
              raise @types.SqlError::Execute(
                "internal: group key dtype drift (int32)",
              )
          }
        GI64(map) =>
          match key_cols[0] {
            @types.I64(d, valid) =>
              if valid[r] {
                let k = d[r]
                match map.get(k) {
                  Some(i) => i
                  None => {
                    let i = group_keys.length()
                    map[k] = i
                    group_keys.push([@types.Int64(d[r])])
                    acc_rows.push(new_accs(aggs))
                    i
                  }
                }
              } else {
                if null_gi < 0 {
                  null_gi = group_keys.length()
                  group_keys.push([@types.Null])
                  acc_rows.push(new_accs(aggs))
                }
                null_gi
              }
            _ =>
              raise @types.SqlError::Execute(
                "internal: group key dtype drift (int64)",
              )
          }
        GDate(map) =>
          match key_cols[0] {
            @types.DateV(d, valid) =>
              if valid[r] {
                let k = d[r].to_int64()
                match map.get(k) {
                  Some(i) => i
                  None => {
                    let i = group_keys.length()
                    map[k] = i
                    group_keys.push([@types.Date(d[r])])
                    acc_rows.push(new_accs(aggs))
                    i
                  }
                }
              } else {
                if null_gi < 0 {
                  null_gi = group_keys.length()
                  group_keys.push([@types.Null])
                  acc_rows.push(new_accs(aggs))
                }
                null_gi
              }
            _ =>
              raise @types.SqlError::Execute(
                "internal: group key dtype drift (date)",
              )
          }
        GStr(map) =>
          match key_cols[0] {
            @types.StrV(d, valid) =>
              if valid[r] {
                let k = d[r]
                match map.get(k) {
                  Some(i) => i
                  None => {
                    let i = group_keys.length()
                    map[k] = i
                    group_keys.push([@types.Str(d[r])])
                    acc_rows.push(new_accs(aggs))
                    i
                  }
                }
              } else {
                if null_gi < 0 {
                  null_gi = group_keys.length()
                  group_keys.push([@types.Null])
                  acc_rows.push(new_accs(aggs))
                }
                null_gi
              }
            _ =>
              raise @types.SqlError::Execute(
                "internal: group key dtype drift (string)",
              )
          }
        GText(map, sb) => {
          sb.reset()
          // injective per position: null is 'N', strings are
          // length-prefixed, the \u{0001} separator ends each component;
          // dtypes are fixed per position so no type tags are needed
          for c in 0..<g {
            let vec = key_cols[c]
            match vec {
              @types.I32(d, valid) =>
                if valid[r] {
                  sb.write_string(d[r].to_string())
                } else {
                  sb.write_char('N')
                }
              @types.I64(d, valid) =>
                if valid[r] {
                  sb.write_string(d[r].to_string())
                } else {
                  sb.write_char('N')
                }
              @types.F64(d, valid) =>
                if valid[r] {
                  sb.write_string(d[r].to_string())
                } else {
                  sb.write_char('N')
                }
              @types.BoolV(d, valid) =>
                if valid[r] {
                  sb.write_string(if d[r] { "T" } else { "F" })
                } else {
                  sb.write_char('N')
                }
              @types.StrV(d, valid) =>
                if valid[r] {
                  sb.write_string(d[r].length().to_string())
                  sb.write_char(':')
                  sb.write_string(d[r])
                } else {
                  sb.write_char('N')
                }
              @types.DateV(d, valid) =>
                if valid[r] {
                  sb.write_string(d[r].to_string())
                } else {
                  sb.write_char('N')
                }
            }
            sb.write_char('\u{0001}')
          }
          let key = sb.to_string()
          match map.get(key) {
            Some(i) => i
            None => {
              let kv : Array[@types.Scalar] = []
              for c in 0..<g {
                kv.push(key_cols[c].get(r))
              }
              let i = group_keys.length()
              map[key] = i
              group_keys.push(kv)
              acc_rows.push(new_accs(aggs))
              i
            }
          }
        }
      }
      let row = acc_rows[gi]
      for i in 0..<m {
        // CountStar has no input column; its FBoxed placeholder is
        // never read because acc_step short-circuits on CountStar
        match input_cols[i] {
          FI32(d, valid) =>
            if valid[r] {
              acc_step_num(row[i], d[r].to_int64(), d[r].to_double())
            }
          FI64(d, valid) =>
            if valid[r] {
              acc_step_num(row[i], d[r], d[r].to_double())
            }
          FF64(d, valid) => if valid[r] { acc_step_num(row[i], 0L, d[r]) }
          FBoxed(col) => {
            // CountStar has no input column: pass a placeholder rather
            // than reading its empty vector; acc_step ignores it
            let input = if aggs[i].kind is CountStar {
              @types.Null
            } else {
              col.get(r)
            }
            acc_step(row[i], aggs[i], input)
          }
        }
      }
    }
    match census {
      Some(c) =>
        c.observe(
          "group state (fold)",
          boxed_state_entries(group_keys, acc_rows, batch),
        )
      None => ()
    }
  }
  if g == 0 && group_keys.length() == 0 {
    // a no-GROUP-BY aggregate over empty input still yields one row
    group_keys.push([])
    acc_rows.push(new_accs(aggs))
  }
  let n = group_keys.length()
  let columns : Array[@types.ColumnVector] = []
  for c in 0..<g {
    let vec = @types.ColumnVector::make(group_types[c], n)
    for r in 0..<n {
      vec.set(r, group_keys[r][c])
    }
    columns.push(vec)
  }
  for i in 0..<m {
    let vec = @types.ColumnVector::make(aggs[i].out_type, n)
    for r in 0..<n {
      vec.set(r, acc_finish(acc_rows[r][i], aggs[i]))
    }
    columns.push(vec)
  }
  @types.DataBatch::new(columns, n)
}

///|
/// The aggregates the column-wise fold keeps as plain arrays: a sum over an
/// integer or a float input, a count of non-null inputs, and `count(*)`.
priv enum ColAggKind {
  SumInt
  SumFlt
  CountVals
  CountAll
}

///|
/// One aggregate's state for every group, as arrays indexed by group id instead
/// of an accumulator object per group. `flags` carries bit 0 (a non-null input
/// was seen) and bit 1 (an integer sum overflowed) for the two sums.
priv struct ColAgg {
  kind : ColAggKind
  ints : Array[Int64]
  dbls : Array[Double]
  flags : Array[Int32]
}

///|
/// Make room for one new group.
fn ColAgg::open(self : ColAgg) -> Unit {
  match self.kind {
    SumInt => {
      self.ints.push(0L)
      self.flags.push(0)
    }
    SumFlt => {
      self.dbls.push(0.0)
      self.flags.push(0)
    }
    CountVals | CountAll => self.ints.push(0L)
  }
}

///|
/// The checked add `acc_step_num` makes: an int64 sum overflows when the
/// operands share a sign that the result does not.
fn ColAgg::add_int(self : ColAgg, gi : Int32, x : Int64) -> Unit {
  let sum = self.ints[gi] + x
  let mut f = self.flags[gi] | 1
  if ((self.ints[gi] ^ sum) & (x ^ sum)) < 0L {
    f = f | 2
  }
  self.ints[gi] = sum
  self.flags[gi] = f
}

///|
fn ColAgg::add_flt(self : ColAgg, gi : Int32, x : Double) -> Unit {
  self.dbls[gi] = self.dbls[gi] + x
  self.flags[gi] = self.flags[gi] | 1
}

///|
fn col_agg_kind(spec : AggSpec) -> ColAggKind? {
  match spec.kind {
    Sum =>
      if spec.input is Some(_) {
        match spec.out_type {
          @types.Int64 => Some(SumInt)
          @types.Float64 => Some(SumFlt)
          _ => None
        }
      } else {
        None
      }
    Count => if spec.input is Some(_) { Some(CountVals) } else { None }
    CountStar => Some(CountAll)
    _ => None
  }
}

///|
/// The column-wise fold applies to one Int32 or Int64 group key, or to a pair of
/// Int32 keys, over aggregates that are all of the kinds above; any other shape
/// keeps the general fold.
fn col_agg_plan(
  group_types : Array[@types.DataType],
  aggs : Array[AggSpec],
) -> Array[ColAggKind]? {
  if aggs.length() == 0 {
    return None
  }
  match group_types.length() {
    1 =>
      match group_types[0] {
        @types.Int32 | @types.Int64 => ()
        _ => return None
      }
    2 =>
      match (group_types[0], group_types[1]) {
        (@types.Int32, @types.Int32) => ()
        _ => return None
      }
    _ => return None
  }
  let kinds : Array[ColAggKind] = []
  for spec in aggs {
    match col_agg_kind(spec) {
      Some(k) => kinds.push(k)
      None => return None
    }
  }
  Some(kinds)
}

///|
/// Hash aggregation for one integer key, or a pair of Int32 keys, with the group
/// state held column-wise: the keys of each group are slots in `Int64` arrays and
/// every aggregate is one array (two for a sum), so a group costs its map slot
/// and a few bytes rather than a key row, an accumulator row and an object per
/// aggregate. A pair of Int32 keys packs into one `Int64` slot key, which loses
/// nothing; a row with a NULL in either key goes through a small side map keyed
/// by its text, so each NULL pattern is its own group as in the general fold.
/// Group order (first seen), the shared NULL group of a single key, sums in row
/// order and the overflow error are the general fold's.
fn aggregate_cols(
  seq : BatchSeq,
  group_exprs : Array[PhysExpr],
  group_types : Array[@types.DataType],
  kinds : Array[ColAggKind],
  aggs : Array[AggSpec],
  census~ : MemCensus? = None,
) -> @types.DataBatch raise @types.SqlError {
  let m = aggs.length()
  let nk = group_exprs.length()
  let slots : Map[Int64, Int32] = Map([])
  let nullkeys : Map[String, Int32] = Map([])
  let ka : Array[Int64] = []
  let kb : Array[Int64] = [] // second key, pairs only
  let kf : Array[Int32] = [] // pairs only: bit 0 first key NULL, bit 1 second
  let cols : Array[ColAgg] = []
  for k in kinds {
    cols.push({ kind: k, ints: [], dbls: [], flags: [], })
  }
  let mut null_gi = -1
  while (seq.next)() is Some(batch) {
    let rows = batch.row_count()
    let kds : Array[FixedArray[Int64]] = []
    let kvs : Array[FixedArray[Bool]] = []
    for e in group_exprs {
      let key_col = eval_vec(e, batch)
      kvs.push(v_validity(key_col))
      kds.push(
        match key_col {
          @types.I32(d, _) => {
            let o : FixedArray[Int64] = FixedArray::make(rows, 0L)
            for i in 0..<rows {
              o[i] = d[i].to_int64()
            }
            o
          }
          @types.I64(d, _) => d
          _ =>
            raise @types.SqlError::Execute(
              "internal: group key dtype drift (int)",
            )
        },
      )
    }
    let valid = kvs[0]
    let kd = kds[0]
    let ins : Array[FastInput] = []
    for spec in aggs {
      match spec.input {
        Some(e) => ins.push(fast_input_of(eval_vec(e, batch), spec))
        None => ins.push(FBoxed(@types.ColumnVector::make(@types.Int32, 0)))
      }
    }
    for r in 0..<rows {
      let gi = if nk == 2 {
        let v0 = kvs[0][r]
        let v1 = kvs[1][r]
        let a = kds[0][r]
        let b = kds[1][r]
        if v0 && v1 {
          let k = (a << 32) | (b & 0xFFFFFFFFL)
          match slots.get(k) {
            Some(i) => i
            None => {
              let i = ka.length()
              slots[k] = i
              ka.push(a)
              kb.push(b)
              kf.push(0)
              for c in cols {
                c.open()
              }
              i
            }
          }
        } else {
          let key = (if v0 { a.to_string() } else { "N" }) +
            "," +
            (if v1 { b.to_string() } else { "N" })
          match nullkeys.get(key) {
            Some(i) => i
            None => {
              let i = ka.length()
              nullkeys[key] = i
              ka.push(if v0 { a } else { 0L })
              kb.push(if v1 { b } else { 0L })
              kf.push((if v0 { 0 } else { 1 }) | (if v1 { 0 } else { 2 }))
              for c in cols {
                c.open()
              }
              i
            }
          }
        }
      } else if valid[r] {
        let k = kd[r]
        match slots.get(k) {
          Some(i) => i
          None => {
            let i = ka.length()
            slots[k] = i
            ka.push(k)
            for c in cols {
              c.open()
            }
            i
          }
        }
      } else {
        if null_gi < 0 {
          null_gi = ka.length()
          ka.push(0L)
          for c in cols {
            c.open()
          }
        }
        null_gi
      }
      for i in 0..<m {
        let c = cols[i]
        match c.kind {
          CountAll => c.ints[gi] = c.ints[gi] + 1L
          CountVals => {
            let present = match ins[i] {
              FI32(_, v) => v[r]
              FI64(_, v) => v[r]
              FF64(_, v) => v[r]
              FBoxed(col) => v_validity(col)[r]
            }
            if present {
              c.ints[gi] = c.ints[gi] + 1L
            }
          }
          SumInt =>
            match ins[i] {
              FI32(d, v) => if v[r] { c.add_int(gi, d[r].to_int64()) }
              FI64(d, v) => if v[r] { c.add_int(gi, d[r]) }
              FBoxed(col) =>
                match col.get(r) {
                  @types.Int32(x) => c.add_int(gi, x.to_int64())
                  @types.Int64(x) => c.add_int(gi, x)
                  _ => ()
                }
              FF64(_, _) => ()
            }
          SumFlt =>
            match ins[i] {
              FI32(d, v) => if v[r] { c.add_flt(gi, d[r].to_double()) }
              FI64(d, v) => if v[r] { c.add_flt(gi, d[r].to_double()) }
              FF64(d, v) => if v[r] { c.add_flt(gi, d[r]) }
              FBoxed(col) =>
                match as_double(col.get(r)) {
                  Some(x) => c.add_flt(gi, x)
                  None => ()
                }
            }
        }
      }
    }
    match census {
      Some(c) =>
        c.observe(
          "group state (fold)",
          col_state_entries(ka, kb, kf, cols, batch),
        )
      None => ()
    }
  }
  let n = ka.length()
  let columns : Array[@types.ColumnVector] = []
  if nk == 2 {
    let da : FixedArray[Int32] = FixedArray::make(n, 0)
    let db : FixedArray[Int32] = FixedArray::make(n, 0)
    let va : FixedArray[Bool] = FixedArray::make(n, true)
    let vb : FixedArray[Bool] = FixedArray::make(n, true)
    for i in 0..<n {
      da[i] = ka[i].to_int()
      db[i] = kb[i].to_int()
      va[i] = (kf[i] & 1) == 0
      vb[i] = (kf[i] & 2) == 0
    }
    columns.push(@types.I32(da, va))
    columns.push(@types.I32(db, vb))
  } else {
    let key_valid : FixedArray[Bool] = FixedArray::make(n, true)
    if null_gi >= 0 {
      key_valid[null_gi] = false
    }
    match group_types[0] {
      @types.Int32 => {
        let d : FixedArray[Int32] = FixedArray::make(n, 0)
        for i in 0..<n {
          d[i] = ka[i].to_int()
        }
        columns.push(@types.I32(d, key_valid))
      }
      _ => {
        let d : FixedArray[Int64] = FixedArray::make(n, 0L)
        for i in 0..<n {
          d[i] = ka[i]
        }
        columns.push(@types.I64(d, key_valid))
      }
    }
  }
  for c in cols {
    let v : FixedArray[Bool] = FixedArray::make(n, true)
    match c.kind {
      SumInt => {
        let d : FixedArray[Int64] = FixedArray::make(n, 0L)
        for gi in 0..<n {
          let f = c.flags[gi]
          if (f & 2) != 0 {
            raise @types.SqlError::Execute(
              "sum() overflows int64; widen the input or filter values",
            )
          }
          if (f & 1) != 0 {
            d[gi] = c.ints[gi]
          } else {
            v[gi] = false
          }
        }
        columns.push(@types.I64(d, v))
      }
      SumFlt => {
        let d : FixedArray[Double] = FixedArray::make(n, 0.0)
        for gi in 0..<n {
          if (c.flags[gi] & 1) != 0 {
            d[gi] = c.dbls[gi]
          } else {
            v[gi] = false
          }
        }
        columns.push(@types.F64(d, v))
      }
      CountVals | CountAll => {
        let d : FixedArray[Int64] = FixedArray::make(n, 0L)
        for gi in 0..<n {
          d[gi] = c.ints[gi]
        }
        columns.push(@types.I64(d, v))
      }
    }
  }
  @types.DataBatch::new(columns, n)
}

///|
/// What a column-wise fold holds at the end of one batch: the group slot table, the
/// key arrays, and every aggregate's arrays. The slot table is an estimate at the
/// join census's twenty-four bytes an entry; the arrays are counted by element size.
/// The bytes are computed here and handed on as numbers, so a census point never
/// holds the fold (contract: docs/ROADMAP.md, "The group state is sized while a fold
/// grows").
fn col_state_entries(
  ka : Array[Int64],
  kb : Array[Int64],
  kf : Array[Int32],
  cols : Array[ColAgg],
  batch : @types.DataBatch,
) -> Array[(String, Int64)] {
  let groups = ka.length().to_int64()
  let entries : Array[(String, Int64)] = []
  entries.push(("key slots (estimate)", SLOT_MAP_BYTES * groups))
  entries.push(
    (
      "group keys",
      8L * ka.length().to_int64() +
      8L * kb.length().to_int64() +
      4L * kf.length().to_int64(),
    ),
  )
  let mut accs = 0L
  for c in cols {
    accs = accs +
      8L * c.ints.length().to_int64() +
      8L * c.dbls.length().to_int64() +
      4L * c.flags.length().to_int64()
  }
  entries.push(("accumulators", accs))
  entries.push(
    ("input batch (estimate)", estimate_batch_bytes(batch).to_int64()),
  )
  entries
}

///|
/// The same for the general fold, whose state is one key array and one accumulator
/// array per group: both are estimates, because what an array of scalars or of
/// accumulators costs per element is the runtime's business and not measured here.
fn boxed_state_entries(
  group_keys : Array[Array[@types.Scalar]],
  acc_rows : Array[Array[Acc]],
  batch : @types.DataBatch,
) -> Array[(String, Int64)] {
  let groups = group_keys.length().to_int64()
  let g = if group_keys.length() > 0 { group_keys[0].length() } else { 0 }
  let m = if acc_rows.length() > 0 { acc_rows[0].length() } else { 0 }
  let entries : Array[(String, Int64)] = []
  entries.push(("key slots (estimate)", SLOT_MAP_BYTES * groups))
  entries.push(("group keys (estimate)", groups * (24L + 16L * g.to_int64())))
  entries.push(("accumulators (estimate)", groups * (24L + 16L * m.to_int64())))
  entries.push(
    ("input batch (estimate)", estimate_batch_bytes(batch).to_int64()),
  )
  entries
}
