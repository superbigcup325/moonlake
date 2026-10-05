// Eager execution over materialized batches: filter compacts rows, hash
// aggregation folds every batch into one row per group (a no-GROUP-BY
// query is one group; an empty input still yields that single row with
// NULL/0 aggregates, per SQL), then having, projection, order and limit.

///|
fn filter_batches(
  batches : Array[@types.DataBatch],
  pred : PhysExpr?,
) -> Array[@types.DataBatch] raise @types.SqlError {
  let out : Array[@types.DataBatch] = []
  for batch in batches {
    match pred {
      None => out.push(batch)
      Some(pe) => {
        let kept = compact(batch, eval_mask(pe, batch))
        if kept.row_count() > 0 {
          out.push(kept)
        }
      }
    }
  }
  out
}

///|
fn compact(
  batch : @types.DataBatch,
  mask : FixedArray[Bool],
) -> @types.DataBatch {
  let indices : Array[Int] = []
  for r in 0..<batch.row_count() {
    if mask[r] {
      indices.push(r)
    }
  }
  take_rows(batch, indices)
}

///|
/// Build a new batch holding the selected input rows, preserving order.
/// Each column is one typed gather.
fn take_rows(
  batch : @types.DataBatch,
  indices : Array[Int],
) -> @types.DataBatch {
  let columns : Array[@types.ColumnVector] = []
  for src in batch.columns() {
    columns.push(gather(src, indices))
  }
  @types.DataBatch::new(columns, indices.length())
}

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
            match @types.Scalar::compare(v, a.cur) {
              Some(c) =>
                match spec.kind {
                  Min => if c < 0 { a.cur = v }
                  Max => if c > 0 { a.cur = v }
                  _ => ()
                }
              None => ()
            }
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
  GI32(Map[Int64, Int])
  GI64(Map[Int64, Int])
  GDate(Map[Int64, Int])
  GStr(Map[String, Int])
  GText(Map[String, Int], StringBuilder)
}

///|
/// A numeric aggregate input resolved to its raw typed arrays, so the
/// fold loop skips the boxed Scalar per cell. MinMax (must return the
/// input's own dtype), CountDistinct (needs the boxed key) and
/// non-numeric inputs stay boxed.
priv enum FastInput {
  FBoxed(@types.ColumnVector)
  FI32(FixedArray[Int], FixedArray[Bool])
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
/// Hash aggregation: one output row per distinct group key (in first-
/// seen order). With no GROUP BY the result is exactly one row, even for
/// empty input.
fn aggregate(
  batches : Array[@types.DataBatch],
  group_exprs : Array[PhysExpr],
  group_types : Array[@types.DataType],
  aggs : Array[AggSpec],
) -> @types.DataBatch raise @types.SqlError {
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
  for batch in batches {
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
/// SELECT DISTINCT: keep the first row for every distinct projected row
/// (first-seen order, so ORDER BY ties stay stable).
fn dedupe_rows(batch : @types.DataBatch) -> @types.DataBatch {
  let seen : Map[String, Bool] = Map([])
  let indices : Array[Int] = []
  for r in 0..<batch.row_count() {
    let kv : Array[@types.Scalar] = []
    for c in batch.columns() {
      kv.push(c.get(r))
    }
    let key = canonical_key(kv)
    match seen.get(key) {
      Some(_) => ()
      None => {
        seen[key] = true
        indices.push(r)
      }
    }
  }
  take_rows(batch, indices)
}

///|
/// Evaluate the projection expressions over the post-agg row. Each
/// output column comes from one vectorized pass; a column whose vector
/// dtype already matches the declared output type is shared, not copied.
fn project(
  batch : @types.DataBatch,
  out_exprs : Array[PhysExpr],
  out_types : Array[@types.DataType],
) -> @types.DataBatch raise @types.SqlError {
  let columns : Array[@types.ColumnVector] = []
  for i, e in out_exprs {
    let v = eval_vec(e, batch)
    if v.dtype() == out_types[i] {
      columns.push(v)
    } else {
      // unreachable: the binder derives out_types from the same exprs
      let n = batch.row_count()
      let vec = @types.ColumnVector::make(out_types[i], n)
      for r in 0..<n {
        vec.set(r, v.get(r))
      }
      columns.push(vec)
    }
  }
  @types.DataBatch::new(columns, batch.row_count())
}

///|
/// Row comparator over pre-materialized ORDER BY key columns. NULLs
/// sort last by default, or first when the key says so; ties keep
/// input order.
fn cmp_decorated(
  key_cols : Array[Array[@types.Scalar]],
  keys : Array[(Int, Bool, Bool?)],
  nulls_first : Array[Bool?],
  a : Int,
  b : Int,
) -> Int {
  for k, kv in keys {
    let x = key_cols[k][a]
    let y = key_cols[k][b]
    let nf = match nulls_first[k] {
      Some(f) => f
      None => false
    }
    let ord : Int = match (x, y) {
      (@types.Null, @types.Null) => 0
      (@types.Null, _) => if nf { -1 } else { 1 }
      (_, @types.Null) => if nf { 1 } else { -1 }
      _ =>
        match @types.Scalar::compare(x, y) {
          Some(c) => if kv.1 { -c } else { c }
          None => 0
        }
    }
    if ord != 0 {
      return ord
    }
  }
  a - b
}

///|
fn order_limit(
  batch : @types.DataBatch,
  keys : Array[(Int, Bool, Bool?)],
  limit : Int?,
  offset : Int?,
) -> @types.DataBatch {
  let n = batch.row_count()
  let indices : Array[Int] = []
  for i in 0..<n {
    indices.push(i)
  }
  if keys.length() > 0 {
    // decorate: read each sort key column once, then compare arrays
    let key_cols : Array[Array[@types.Scalar]] = []
    for kv in keys {
      let col = batch.columns()[kv.0]
      let vals : Array[@types.Scalar] = []
      for r in 0..<n {
        vals.push(col.get(r))
      }
      key_cols.push(vals)
    }
    let nfs : Array[Bool?] = []
    for kv in keys {
      nfs.push(kv.2)
    }
    indices.sort_by((a, b) => cmp_decorated(key_cols, keys, nfs, a, b))
  }
  take_rows(batch, window(indices, offset, limit))
}

///|
/// Sort by key expressions over the pre-projection row, then apply the
/// offset/limit window. Decorates via the vectorized evaluator.
fn sort_exprs(
  batch : @types.DataBatch,
  keys : Array[(PhysExpr, Bool, Bool?)],
  offset : Int?,
  limit : Int?,
) -> @types.DataBatch raise @types.SqlError {
  let n = batch.row_count()
  let indices : Array[Int] = []
  for i in 0..<n {
    indices.push(i)
  }
  if keys.length() > 0 {
    let key_cols : Array[Array[@types.Scalar]] = []
    let nfs : Array[Bool?] = []
    for k in keys {
      let vec = eval_vec(k.0, batch)
      let vals : Array[@types.Scalar] = []
      for r in 0..<n {
        vals.push(vec.get(r))
      }
      key_cols.push(vals)
      nfs.push(k.2)
    }
    // cmp_decorated keys on column indexes
    let kds : Array[(Int, Bool, Bool?)] = []
    for i, k in keys {
      kds.push((i, k.1, k.2))
    }
    indices.sort_by((a, b) => cmp_decorated(key_cols, kds, nfs, a, b))
  }
  take_rows(batch, window(indices, offset, limit))
}

///|
/// The offset/limit window of a row-id list: skip `offset`, then take
/// at most `limit`.
fn window(indices : Array[Int], offset : Int?, limit : Int?) -> Array[Int] {
  let skip = match offset {
    Some(o) => o
    None => 0
  }
  let mut taken = 0
  let out : Array[Int] = []
  for i in indices {
    if taken >= skip {
      match limit {
        Some(k) =>
          if taken - skip < k {
            out.push(i)
            taken += 1
          }
        None => {
          out.push(i)
          taken += 1
        }
      }
    } else {
      taken += 1
    }
  }
  out
}

///|
/// Drop unreferenced columns from every batch of a table. The kept
/// ColumnVectors are shared with the source batch, not copied.
fn narrow_batches(
  batches : Array[@types.DataBatch],
  cols : Array[Int],
) -> Array[@types.DataBatch] {
  batches.map(fn(b) {
    let columns : Array[@types.ColumnVector] = []
    for c in cols {
      columns.push(b.columns()[c])
    }
    @types.DataBatch::new(columns, b.row_count())
  })
}

///|
/// Execute the planned join chain left-deep over the FROM tables.
fn exec_joins(
  tables : Array[Array[@types.DataBatch]],
  steps : Array[JoinStep],
  deferred : PhysExpr?,
) -> Array[@types.DataBatch] raise @types.SqlError {
  if steps.length() == 0 {
    let cols : Array[@types.ColumnVector] = []
    return filter_batches([@types.DataBatch::new(cols, 1)], deferred)
  }
  let mut acc = tables[steps[0].table]
  for i, step in steps {
    if i == 0 {
      acc = filter_batches(acc, step.build_filter)
    } else {
      acc = filter_batches(acc, step.probe_filter)
      let right = filter_batches(tables[step.table], step.build_filter)
      acc = [join_step(acc, right, step)]
    }
  }
  filter_batches(acc, deferred)
}

///|
fn key_has_null(vals : Array[@types.Scalar]) -> Bool {
  for v in vals {
    if v is @types.Null {
      return true
    }
  }
  false
}

///|
/// One hash join: build a key -> row-ids map on the (filtered) right
/// side, probe with every accumulated row. NULL keys never match; LEFT
/// keeps unmatched probe rows with a NULL right side; the residual
/// filters candidate pairs before the match counts (so LEFT
/// NULL-extension sees the post-residual match set, per ON semantics).
///
/// Both sides are concatenated into single columnar batches, keys are
/// evaluated once per side, probe hits collect (left row, build row)
/// integer pairs, and the output is assembled by per-column gathers —
/// no boxed row arrays in the hot path. A single int join key (the
/// TPC-H shape) hashes Int64s directly instead of building key strings.
fn join_step(
  acc : Array[@types.DataBatch],
  right : Array[@types.DataBatch],
  step : JoinStep,
) -> @types.DataBatch raise @types.SqlError {
  if step.kind is Right {
    return join_swapped(acc, right, step)
  }
  if step.kind is Semi || step.kind is Anti || step.kind is AntiLoose {
    return join_semi(acc, right, step)
  }
  let right_width = step.right_width
  let left_width = step.out_dtypes.length() - right_width
  // build: one columnar batch, keys evaluated once over it
  let build = concat_batches(right, tail_dtypes(step.out_dtypes, right_width))
  let n_build = build.row_count()
  // probe: keys evaluated once over the concatenated left side
  let left = concat_batches(acc, head_dtypes(step.out_dtypes, left_width))
  let n_left = left.row_count()
  let build_keys : Array[@types.ColumnVector] = []
  for e in step.keys_r {
    build_keys.push(eval_vec(e, build))
  }
  let left_keys : Array[@types.ColumnVector] = []
  for e in step.keys_l {
    left_keys.push(eval_vec(e, left))
  }
  let left_ids : Array[Int] = []
  let right_ids : Array[Int] = [] // -1 marks a LEFT NULL extension
  // FULL also preserves unmatched build rows: remember who matched
  let matched_build : FixedArray[Bool] = FixedArray::make(n_build, false)
  let track = step.kind is Full
  // single-int-key fast path: hash Int64s, no key strings per row
  let int_keys = if step.keys_l.length() == 1 && step.keys_r.length() == 1 {
    int_key_cols(build_keys[0], left_keys[0])
  } else {
    None
  }
  match int_keys {
    Some((bd, bv, ld, lv)) => {
      let map : Map[Int64, Array[Int]] = Map([])
      for r in 0..<n_build {
        if bv[r] {
          // NULL join keys never match
          let k = bd[r]
          match map.get(k) {
            Some(ids) => ids.push(r)
            None => map[k] = [r]
          }
        }
      }
      for r in 0..<n_left {
        let mut matched = false
        if lv[r] {
          match map.get(ld[r]) {
            Some(ids) =>
              for id in ids {
                if residual_passes(step.residual, left, r, build, id) {
                  left_ids.push(r)
                  right_ids.push(id)
                  matched = true
                  matched_build[id] = true
                }
              }
            None => ()
          }
        }
        if !matched {
          if step.kind is Left || step.kind is Full {
            left_ids.push(r)
            right_ids.push(-1)
          }
        }
      }
    }
    None => {
      let map : Map[String, Array[Int]] = Map([])
      for r in 0..<n_build {
        let kv : Array[@types.Scalar] = []
        for c in build_keys {
          kv.push(c.get(r))
        }
        if key_has_null(kv) {
          continue // NULL join keys never match
        }
        let key = canonical_key(kv)
        match map.get(key) {
          Some(ids) => ids.push(r)
          None => map[key] = [r]
        }
      }
      for r in 0..<n_left {
        let kv : Array[@types.Scalar] = []
        for c in left_keys {
          kv.push(c.get(r))
        }
        let mut matched = false
        if !key_has_null(kv) {
          match map.get(canonical_key(kv)) {
            Some(ids) =>
              for id in ids {
                if residual_passes(step.residual, left, r, build, id) {
                  left_ids.push(r)
                  right_ids.push(id)
                  matched = true
                  matched_build[id] = true
                }
              }
            None => ()
          }
        }
        if !matched {
          if step.kind is Left || step.kind is Full {
            left_ids.push(r)
            right_ids.push(-1)
          }
        }
      }
    }
  }
  // FULL: unmatched build rows survive with a NULL accumulated side
  if track {
    for id in 0..<n_build {
      if !matched_build[id] {
        left_ids.push(-1)
        right_ids.push(id)
      }
    }
  }
  // assemble by per-column gather
  let columns : Array[@types.ColumnVector] = []
  for c in 0..<left_width {
    columns.push(gather(left.columns()[c], left_ids))
  }
  for c in 0..<right_width {
    columns.push(gather(build.columns()[c], right_ids))
  }
  @types.DataBatch::new(columns, left_ids.length())
}

///|
/// Residual evaluation for one candidate pair.
fn residual_passes(
  residual : PhysExpr?,
  left : @types.DataBatch,
  lrow : Int,
  build : @types.DataBatch,
  brow : Int,
) -> Bool raise @types.SqlError {
  match residual {
    Some(re) =>
      eval_row(re, combined_row(left, lrow, build, brow))
      is @types.Boolean(true)
    None => true
  }
}

///|
/// Normalize a single-int join key pair to (Int64 data, validity) for
/// both sides; None when either key is not a 32/64-bit int column (the
/// binder promotes both sides to one type, so mixed int widths do not
/// reach the executor, but staying type-exact costs one check).
fn int_key_cols(
  build_key : @types.ColumnVector,
  left_key : @types.ColumnVector,
) -> (FixedArray[Int64], FixedArray[Bool], FixedArray[Int64], FixedArray[Bool])? {
  fn norm(v : @types.ColumnVector) -> (FixedArray[Int64], FixedArray[Bool])? {
    match v {
      @types.I32(d, valid) => {
        let n = v.len()
        let od : FixedArray[Int64] = FixedArray::make(n, 0L)
        for i in 0..<n {
          od[i] = d[i].to_int64()
        }
        Some((od, valid))
      }
      @types.I64(d, valid) => Some((d, valid))
      _ => None
    }
  }
  match (norm(build_key), norm(left_key)) {
    (Some((bd, bv)), Some((ld, lv))) => Some((bd, bv, ld, lv))
    _ => None
  }
}

///|
/// The first `count` dtypes of the combined join layout.
fn head_dtypes(
  dtypes : Array[@types.DataType],
  count : Int,
) -> Array[@types.DataType] {
  let out : Array[@types.DataType] = []
  for i in 0..<count {
    out.push(dtypes[i])
  }
  out
}

///|
/// The last `count` dtypes of the combined join layout.
fn tail_dtypes(
  dtypes : Array[@types.DataType],
  count : Int,
) -> Array[@types.DataType] {
  let out : Array[@types.DataType] = []
  let start = dtypes.length() - count
  for i in start..<dtypes.length() {
    out.push(dtypes[i])
  }
  out
}

///|
/// The combined flat row for one candidate pair (residual evaluation).
fn combined_row(
  left : @types.DataBatch,
  lrow : Int,
  build : @types.DataBatch,
  brow : Int,
) -> Array[@types.Scalar] {
  let row : Array[@types.Scalar] = []
  for c in 0..<left.columns().length() {
    row.push(left.columns()[c].get(lrow))
  }
  for c in 0..<build.columns().length() {
    row.push(build.columns()[c].get(brow))
  }
  row
}

///|
/// Semi/anti join against a pre-executed inner batch (the
/// decorrelation of a correlated EXISTS / [NOT] IN): probe rows pass a
/// SEMI when some inner row shares the (non-null) key and satisfies the
/// residual. Anti flavors differ on a NULL probe key: NOT IN's
/// comparison is UNKNOWN and drops the row, NOT EXISTS's subquery is
/// simply empty so only an actual match drops it. The inner side
/// contributes no output columns.
fn join_semi(
  acc : Array[@types.DataBatch],
  inner : Array[@types.DataBatch],
  step : JoinStep,
) -> @types.DataBatch raise @types.SqlError {
  let anti = step.kind is Anti || step.kind is AntiLoose
  let null_key_excludes = step.kind is Anti
  let inner_batch = concat_batches(inner, [])
  let n_inner = inner_batch.row_count()
  let int_map : Map[Int64, Array[Int]] = Map([])
  let str_map : Map[String, Array[Int]] = Map([])
  let inner_keys : Array[@types.ColumnVector] = []
  for e in step.keys_r {
    inner_keys.push(eval_vec(e, inner_batch))
  }
  let single_int = step.keys_r.length() == 1 &&
    inner_keys[0] is (@types.I32(_, _) | @types.I64(_, _))
  if single_int {
    let d : FixedArray[Int64] = match inner_keys[0] {
      @types.I32(d, _) => {
        let od : FixedArray[Int64] = FixedArray::make(n_inner, 0L)
        for i in 0..<n_inner {
          od[i] = d[i].to_int64()
        }
        od
      }
      @types.I64(d, _) => d
      _ => abort("unreachable: single_int checked above")
    }
    let valid = v_validity(inner_keys[0])
    for r in 0..<n_inner {
      if valid[r] {
        // NULL inner keys match nothing
        let k = d[r]
        match int_map.get(k) {
          Some(ids) => ids.push(r)
          None => int_map[k] = [r]
        }
      }
    }
  } else {
    for r in 0..<n_inner {
      let kv : Array[@types.Scalar] = []
      for c in inner_keys {
        kv.push(c.get(r))
      }
      if key_has_null(kv) {
        continue
      }
      let key = canonical_key(kv)
      match str_map.get(key) {
        Some(ids) => ids.push(r)
        None => str_map[key] = [r]
      }
    }
  }
  let left = concat_batches(
    acc,
    head_dtypes(step.out_dtypes, step.out_dtypes.length() - step.right_width),
  )
  let n_left = left.row_count()
  let left_keys : Array[@types.ColumnVector] = []
  for e in step.keys_l {
    left_keys.push(eval_vec(e, left))
  }
  let left_ids : Array[Int] = []
  for r in 0..<n_left {
    let kv : Array[@types.Scalar] = []
    for c in left_keys {
      kv.push(c.get(r))
    }
    let null_key = key_has_null(kv)
    let mut matched = false
    if !null_key {
      if single_int {
        let k = match left_keys[0].get(r) {
          @types.Int32(v) => v.to_int64()
          @types.Int64(v) => v
          _ => 0L
        }
        match int_map.get(k) {
          Some(ids) =>
            for id in ids {
              if residual_passes(step.residual, left, r, inner_batch, id) {
                matched = true
              }
            }
          None => ()
        }
      } else {
        let key = canonical_key(kv)
        match str_map.get(key) {
          Some(ids) =>
            for id in ids {
              if residual_passes(step.residual, left, r, inner_batch, id) {
                matched = true
              }
            }
          None => ()
        }
      }
    }
    // SEMI: keep matches. ANTI: keep non-matches — NOT IN additionally
    // drops a null correlation key (UNKNOWN), NOT EXISTS keeps it (the
    // subquery is empty regardless)
    let keep = if anti {
      !matched && (!null_key || !null_key_excludes)
    } else {
      matched
    }
    if keep {
      left_ids.push(r)
    }
  }
  // full-width assembly like a plain join: the layout stays flat so the
  // residual and projection see every column; the projection drops the
  // inner columns naturally. No single inner row belongs to a semi/anti
  // match, so the inner columns gather id -1 (all-NULL placeholders);
  // gathering row 0 would also index out of an empty inner batch.
  let columns : Array[@types.ColumnVector] = []
  for c in 0..<left.columns().length() {
    columns.push(gather(left.columns()[c], left_ids))
  }
  for c in 0..<inner_batch.columns().length() {
    let right_ids : Array[Int] = Array::make(left_ids.length(), -1)
    columns.push(gather(inner_batch.columns()[c], right_ids))
  }
  @types.DataBatch::new(columns, left_ids.length())
}

///|
/// RIGHT JOIN with roles swapped: the accumulated (optional) side
/// becomes the hash map, the joining (preserved) side probes, and every
/// unmatched probe row keeps its values with a NULL accumulated side.
/// Output column order stays (accumulated, joining) as the layout
/// requires.
fn join_swapped(
  acc : Array[@types.DataBatch],
  right : Array[@types.DataBatch],
  step : JoinStep,
) -> @types.DataBatch raise @types.SqlError {
  let right_width = step.right_width
  let left_width = step.out_dtypes.length() - right_width
  // build: the accumulated (optional) side; keys are the Flat left keys
  let build = concat_batches(acc, head_dtypes(step.out_dtypes, left_width))
  let n_build = build.row_count()
  // probe: the preserved joining table; keys are its Slot keys
  let probe = concat_batches(right, tail_dtypes(step.out_dtypes, right_width))
  let n_probe = probe.row_count()
  let build_keys : Array[@types.ColumnVector] = []
  for e in step.keys_l {
    build_keys.push(eval_vec(e, build))
  }
  let probe_keys : Array[@types.ColumnVector] = []
  for e in step.keys_r {
    probe_keys.push(eval_vec(e, probe))
  }
  let acc_ids : Array[Int] = []
  let right_ids : Array[Int] = [] // -1 marks a NULL accumulated side
  let int_keys = if step.keys_l.length() == 1 && step.keys_r.length() == 1 {
    int_key_cols(build_keys[0], probe_keys[0])
  } else {
    None
  }
  match int_keys {
    Some((bd, bv, pd, pv)) => {
      let map : Map[Int64, Array[Int]] = Map([])
      for r in 0..<n_build {
        if bv[r] {
          let k = bd[r]
          match map.get(k) {
            Some(ids) => ids.push(r)
            None => map[k] = [r]
          }
        }
      }
      for r in 0..<n_probe {
        let mut matched = false
        if pv[r] {
          match map.get(pd[r]) {
            Some(ids) =>
              for id in ids {
                if residual_passes(step.residual, build, id, probe, r) {
                  acc_ids.push(id)
                  right_ids.push(r)
                  matched = true
                }
              }
            None => ()
          }
        }
        if !matched {
          acc_ids.push(-1)
          right_ids.push(r)
        }
      }
    }
    None => {
      let map : Map[String, Array[Int]] = Map([])
      for r in 0..<n_build {
        let kv : Array[@types.Scalar] = []
        for c in build_keys {
          kv.push(c.get(r))
        }
        if key_has_null(kv) {
          continue
        }
        let key = canonical_key(kv)
        match map.get(key) {
          Some(ids) => ids.push(r)
          None => map[key] = [r]
        }
      }
      for r in 0..<n_probe {
        let kv : Array[@types.Scalar] = []
        for c in probe_keys {
          kv.push(c.get(r))
        }
        let mut matched = false
        if !key_has_null(kv) {
          match map.get(canonical_key(kv)) {
            Some(ids) =>
              for id in ids {
                if residual_passes(step.residual, build, id, probe, r) {
                  acc_ids.push(id)
                  right_ids.push(r)
                  matched = true
                }
              }
            None => ()
          }
        }
        if !matched {
          acc_ids.push(-1)
          right_ids.push(r)
        }
      }
    }
  }
  // assemble: accumulated columns first, then the joining table
  let columns : Array[@types.ColumnVector] = []
  for c in 0..<left_width {
    columns.push(gather(build.columns()[c], acc_ids))
  }
  for c in 0..<right_width {
    columns.push(gather(probe.columns()[c], right_ids))
  }
  @types.DataBatch::new(columns, acc_ids.length())
}

///|
/// Gather rows by id into a fresh vector. A negative id writes an
/// invalid slot (LEFT join NULL extension). Typed per variant so the
/// gather writes plain arrays, no boxed Scalars.
fn gather(src : @types.ColumnVector, ids : Array[Int]) -> @types.ColumnVector {
  let n = ids.length()
  match src {
    @types.I32(d, valid) => {
      let od : FixedArray[Int] = FixedArray::make(n, 0)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for w, i in ids {
        if i >= 0 && valid[i] {
          od[w] = d[i]
          ovalid[w] = true
        }
      }
      @types.I32(od, ovalid)
    }
    @types.I64(d, valid) => {
      let od : FixedArray[Int64] = FixedArray::make(n, 0L)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for w, i in ids {
        if i >= 0 && valid[i] {
          od[w] = d[i]
          ovalid[w] = true
        }
      }
      @types.I64(od, ovalid)
    }
    @types.F64(d, valid) => {
      let od : FixedArray[Double] = FixedArray::make(n, 0.0)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for w, i in ids {
        if i >= 0 && valid[i] {
          od[w] = d[i]
          ovalid[w] = true
        }
      }
      @types.F64(od, ovalid)
    }
    @types.BoolV(d, valid) => {
      let od : FixedArray[Bool] = FixedArray::make(n, false)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for w, i in ids {
        if i >= 0 && valid[i] {
          od[w] = d[i]
          ovalid[w] = true
        }
      }
      @types.BoolV(od, ovalid)
    }
    @types.StrV(d, valid) => {
      let od : FixedArray[String] = FixedArray::make(n, "")
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for w, i in ids {
        if i >= 0 && valid[i] {
          od[w] = d[i]
          ovalid[w] = true
        }
      }
      @types.StrV(od, ovalid)
    }
    @types.DateV(d, valid) => {
      let od : FixedArray[Int] = FixedArray::make(n, 0)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for w, i in ids {
        if i >= 0 && valid[i] {
          od[w] = d[i]
          ovalid[w] = true
        }
      }
      @types.DateV(od, ovalid)
    }
  }
}

///|
/// Columnar concatenation of batches sharing one layout. An empty input
/// yields a zero-row batch with the given layout (dtypes of the flat
/// row), so downstream expressions still see every column.
fn concat_batches(
  batches : Array[@types.DataBatch],
  dtypes : Array[@types.DataType],
) -> @types.DataBatch {
  if batches.length() == 1 {
    return batches[0]
  }
  if batches.length() == 0 {
    let columns : Array[@types.ColumnVector] = []
    for dt in dtypes {
      columns.push(@types.ColumnVector::make(dt, 0))
    }
    return @types.DataBatch::new(columns, 0)
  }
  let mut total = 0
  for b in batches {
    total += b.row_count()
  }
  let ncols = batches[0].columns().length()
  let columns : Array[@types.ColumnVector] = []
  for c in 0..<ncols {
    let dt = batches[0].columns()[c].dtype()
    let dst = @types.ColumnVector::make(dt, total)
    let mut w = 0
    for b in batches {
      // copy exactly the batch's live rows: builder-produced batches
      // carry capacity-sized vectors (4096) whose length exceeds
      // row_count — copying by vector length overruns the destination
      copy_vec_range(dst, w, b.columns()[c], b.row_count())
      w += b.row_count()
    }
    columns.push(dst)
  }
  @types.DataBatch::new(columns, total)
}

///|
/// Copy `n` rows of one vector into another at the given offset. Same
/// dtype by construction (concat batches share a layout); the fallback
/// mirrors ColumnVector::set's silent mismatch ignore.
fn copy_vec_range(
  dst : @types.ColumnVector,
  w : Int,
  src : @types.ColumnVector,
  n : Int,
) -> Unit {
  match (dst, src) {
    (@types.I32(dd, dv), @types.I32(sd, sv)) =>
      for i in 0..<n {
        dd[w + i] = sd[i]
        dv[w + i] = sv[i]
      }
    (@types.I64(dd, dv), @types.I64(sd, sv)) =>
      for i in 0..<n {
        dd[w + i] = sd[i]
        dv[w + i] = sv[i]
      }
    (@types.F64(dd, dv), @types.F64(sd, sv)) =>
      for i in 0..<n {
        dd[w + i] = sd[i]
        dv[w + i] = sv[i]
      }
    (@types.BoolV(dd, dv), @types.BoolV(sd, sv)) =>
      for i in 0..<n {
        dd[w + i] = sd[i]
        dv[w + i] = sv[i]
      }
    (@types.StrV(dd, dv), @types.StrV(sd, sv)) =>
      for i in 0..<n {
        dd[w + i] = sd[i]
        dv[w + i] = sv[i]
      }
    (@types.DateV(dd, dv), @types.DateV(sd, sv)) =>
      for i in 0..<n {
        dd[w + i] = sd[i]
        dv[w + i] = sv[i]
      }
    _ => ()
  }
}

///|
/// NULL-safe multiset key of a whole row (set operations compare rows,
/// so unlike join keys a NULL here is a value that equals itself).
fn row_key(batch : @types.DataBatch, r : Int) -> String {
  let kv : Array[@types.Scalar] = []
  for c in batch.columns() {
    kv.push(c.get(r))
  }
  canonical_key(kv)
}

///|
fn row_counts(batch : @types.DataBatch) -> Map[String, Int] {
  let counts : Map[String, Int] = Map([])
  for r in 0..<batch.row_count() {
    let k = row_key(batch, r)
    match counts.get(k) {
      Some(v) => counts[k] = v + 1
      None => counts[k] = 1
    }
  }
  counts
}
