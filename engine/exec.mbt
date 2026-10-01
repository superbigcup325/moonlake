// Eager execution over materialized batches: filter compacts rows, hash
// aggregation folds every batch into one row per group (a no-GROUP-BY
// query is one group; an empty input still yields that single row with
// NULL/0 aggregates, per SQL), then having, projection, order and limit.

///|
fn filter_batches(
  batches : Array[@types.DataBatch],
  pred : PhysExpr?,
) -> Array[@types.DataBatch] {
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
fn take_rows(
  batch : @types.DataBatch,
  indices : Array[Int],
) -> @types.DataBatch {
  let n = indices.length()
  let columns : Array[@types.ColumnVector] = []
  for src in batch.columns() {
    let dst = @types.ColumnVector::make(src.dtype(), n)
    for w, i in indices {
      dst.set(w, src.get(i))
    }
    columns.push(dst)
  }
  @types.DataBatch::new(columns, n)
}

///|
/// One running accumulator per aggregate spec.
priv enum Acc {
  SumI(Int64, Bool) // value, has_seen_non_null
  SumF(Double, Bool)
  AvgF(Double, Int64) // sum, count of non-null inputs
  CountOf(Int64)
  Distinct(Map[String, Bool])
  MinMax(@types.Scalar, Bool)
}

///|
fn new_accs(aggs : Array[AggSpec]) -> Array[Acc] {
  let row : Array[Acc] = []
  for spec in aggs {
    row.push(
      match spec.kind {
        Sum =>
          match spec.out_type {
            @types.Int64 => SumI(0L, false)
            _ => SumF(0.0, false)
          }
        Avg => AvgF(0.0, 0L)
        Count | CountStar => CountOf(0L)
        CountDistinct => Distinct({})
        Min | Max => MinMax(@types.Null, false)
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
fn acc_step(
  acc : Acc,
  spec : AggSpec,
  batch : @types.DataBatch,
  r : Int,
) -> Acc {
  if spec.kind is CountStar {
    match acc {
      CountOf(c) => CountOf(c + 1L)
      other => other
    }
  } else {
    let input = match spec.input {
      Some(e) => e
      None => return acc
    }
    match eval_scalar(input, batch, r) {
      @types.Null => acc // aggregates ignore NULL inputs
      v =>
        match acc {
          SumI(s, _) =>
            match v {
              @types.Int32(x) => SumI(s + x.to_int64(), true)
              @types.Int64(x) => SumI(s + x, true)
              _ => acc
            }
          SumF(s, _) =>
            match as_double(v) {
              Some(x) => SumF(s + x, true)
              None => acc
            }
          AvgF(s, c) =>
            match as_double(v) {
              Some(x) => AvgF(s + x, c + 1L)
              None => acc
            }
          CountOf(c) => CountOf(c + 1L)
          Distinct(seen) => {
            seen[scalar_key(v)] = true
            acc
          }
          MinMax(cur, seen) =>
            if !seen {
              MinMax(v, true)
            } else {
              match @types.Scalar::compare(v, cur) {
                Some(c) =>
                  match spec.kind {
                    Min => if c < 0 { MinMax(v, true) } else { acc }
                    Max => if c > 0 { MinMax(v, true) } else { acc }
                    _ => acc
                  }
                None => acc
              }
            }
        }
    }
  }
}

///|
fn acc_finish(acc : Acc) -> @types.Scalar {
  match acc {
    SumI(s, seen) => if seen { @types.Int64(s) } else { @types.Null }
    SumF(s, seen) => if seen { @types.Float64(s) } else { @types.Null }
    AvgF(s, c) =>
      if c > 0L {
        @types.Float64(s / c.to_double())
      } else {
        @types.Null
      }
    CountOf(c) => @types.Int64(c)
    Distinct(seen) => @types.Int64(seen.length().to_int64())
    MinMax(v, seen) => if seen { v } else { @types.Null }
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
/// Hash aggregation: one output row per distinct group key (in first-
/// seen order). With no GROUP BY the result is exactly one row, even for
/// empty input.
fn aggregate(
  batches : Array[@types.DataBatch],
  group_exprs : Array[PhysExpr],
  group_types : Array[@types.DataType],
  aggs : Array[AggSpec],
) -> @types.DataBatch {
  let g = group_exprs.length()
  let m = aggs.length()
  let index : Map[String, Int] = Map([])
  let group_keys : Array[Array[@types.Scalar]] = []
  let acc_rows : Array[Array[Acc]] = []
  for batch in batches {
    for r in 0..<batch.row_count() {
      let kv : Array[@types.Scalar] = []
      for e in group_exprs {
        kv.push(eval_scalar(e, batch, r))
      }
      let key = canonical_key(kv)
      let gi = match index.get(key) {
        Some(i) => i
        None => {
          let i = group_keys.length()
          index[key] = i
          group_keys.push(kv)
          acc_rows.push(new_accs(aggs))
          i
        }
      }
      let row = acc_rows[gi]
      for i in 0..<m {
        row[i] = acc_step(row[i], aggs[i], batch, r)
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
      vec.set(r, acc_finish(acc_rows[r][i]))
    }
    columns.push(vec)
  }
  @types.DataBatch::new(columns, n)
}

///|
/// Evaluate the projection expressions over the post-agg row.
fn project(
  batch : @types.DataBatch,
  out_exprs : Array[PhysExpr],
  out_types : Array[@types.DataType],
) -> @types.DataBatch {
  let n = batch.row_count()
  let columns : Array[@types.ColumnVector] = []
  for i, e in out_exprs {
    let vec = @types.ColumnVector::make(out_types[i], n)
    for r in 0..<n {
      vec.set(r, eval_scalar(e, batch, r))
    }
    columns.push(vec)
  }
  @types.DataBatch::new(columns, n)
}

///|
/// Row comparator over the ORDER BY output columns. NULLs sort last
/// regardless of direction; ties keep input order.
fn cmp_rows(
  batch : @types.DataBatch,
  keys : Array[(Int, Bool)],
  a : Int,
  b : Int,
) -> Int {
  for kv in keys {
    let x = batch.columns()[kv.0].get(a)
    let y = batch.columns()[kv.0].get(b)
    let ord : Int = match (x, y) {
      (@types.Null, @types.Null) => 0
      (@types.Null, _) => 1
      (_, @types.Null) => -1
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
  keys : Array[(Int, Bool)],
  limit : Int?,
) -> @types.DataBatch {
  let n = batch.row_count()
  let indices : Array[Int] = []
  for i in 0..<n {
    indices.push(i)
  }
  if keys.length() > 0 {
    indices.sort_by((a, b) => cmp_rows(batch, keys, a, b))
  }
  let sel : Array[Int] = match limit {
    Some(k) => {
      let out : Array[Int] = []
      for i in 0..<n {
        if i < k {
          out.push(indices[i])
        }
      }
      out
    }
    None => indices
  }
  take_rows(batch, sel)
}

///|
/// Execute the planned join chain left-deep over the FROM tables.
fn exec_joins(
  tables : Array[Array[@types.DataBatch]],
  steps : Array[JoinStep],
  deferred : PhysExpr?,
) -> Array[@types.DataBatch] {
  let mut acc = tables[0]
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
fn concat_rows(
  a : Array[@types.Scalar],
  b : Array[@types.Scalar],
) -> Array[@types.Scalar] {
  let out : Array[@types.Scalar] = []
  for x in a {
    out.push(x)
  }
  for x in b {
    out.push(x)
  }
  out
}

///|
fn null_row(width : Int) -> Array[@types.Scalar] {
  let row : Array[@types.Scalar] = []
  for _ in 0..<width {
    row.push(@types.Null)
  }
  row
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
/// Turn row arrays into a columnar batch (join output).
fn columnarize(
  dtypes : Array[@types.DataType],
  rows : Array[Array[@types.Scalar]],
) -> @types.DataBatch {
  let n = rows.length()
  let columns : Array[@types.ColumnVector] = []
  for c, dt in dtypes {
    let vec = @types.ColumnVector::make(dt, n)
    for r in 0..<n {
      vec.set(r, rows[r][c])
    }
    columns.push(vec)
  }
  @types.DataBatch::new(columns, n)
}

///|
/// One hash join: build a key -> rows map on the (filtered) right table,
/// probe with every accumulated row. NULL keys never match; LEFT keeps
/// unmatched probe rows with a NULL right side; the residual filters
/// candidate pairs before the match counts (so LEFT NULL-extension sees
/// the post-residual match set, per ON semantics).
fn join_step(
  acc : Array[@types.DataBatch],
  right : Array[@types.DataBatch],
  step : JoinStep,
) -> @types.DataBatch {
  let right_width = step.right_width
  // build
  let build_rows : Array[Array[@types.Scalar]] = []
  let map : Map[String, Array[Int]] = Map([])
  for rb in right {
    for r in 0..<rb.row_count() {
      let row : Array[@types.Scalar] = []
      for c in 0..<rb.columns().length() {
        row.push(rb.columns()[c].get(r))
      }
      let kv : Array[@types.Scalar] = []
      for e in step.keys_r {
        kv.push(eval_row(e, row))
      }
      if key_has_null(kv) {
        continue // NULL join keys never match
      }
      let key = canonical_key(kv)
      match map.get(key) {
        Some(ids) => ids.push(build_rows.length())
        None => map[key] = [build_rows.length()]
      }
      build_rows.push(row)
    }
  }
  // probe
  let out : Array[Array[@types.Scalar]] = []
  for ab in acc {
    for r in 0..<ab.row_count() {
      let lrow : Array[@types.Scalar] = []
      for c in 0..<ab.columns().length() {
        lrow.push(ab.columns()[c].get(r))
      }
      let kv : Array[@types.Scalar] = []
      for e in step.keys_l {
        kv.push(eval_row(e, lrow))
      }
      let mut matched = false
      if !key_has_null(kv) {
        match map.get(canonical_key(kv)) {
          Some(ids) =>
            for id in ids {
              let combined = concat_rows(lrow, build_rows[id])
              let pass = match step.residual {
                Some(re) => eval_row(re, combined) is @types.Boolean(true)
                None => true
              }
              if pass {
                out.push(combined)
                matched = true
              }
            }
          None => ()
        }
      }
      if !matched {
        if step.kind is Left {
          out.push(concat_rows(lrow, null_row(right_width)))
        }
      }
    }
  }
  columnarize(step.out_dtypes, out)
}
