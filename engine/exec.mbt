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
/// One running accumulator per aggregate spec. `input` is the
/// pre-evaluated aggregate input for one row; Null inputs are skipped
/// (aggregates ignore NULL).
fn acc_step(acc : Acc, spec : AggSpec, input : @types.Scalar) -> Acc {
  if spec.kind is CountStar {
    match acc {
      CountOf(c) => CountOf(c + 1L)
      other => other
    }
  } else {
    match input {
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
) -> @types.DataBatch raise @types.SqlError {
  let g = group_exprs.length()
  let m = aggs.length()
  let index : Map[String, Int] = Map([])
  let group_keys : Array[Array[@types.Scalar]] = []
  let acc_rows : Array[Array[Acc]] = []
  for batch in batches {
    // evaluate group keys and aggregate inputs once per batch, then the
    // row loop reads the materialized columns
    let key_cols : Array[@types.ColumnVector] = []
    for e in group_exprs {
      key_cols.push(eval_vec(e, batch))
    }
    let input_cols : Array[@types.ColumnVector?] = []
    for spec in aggs {
      match spec.input {
        Some(e) => input_cols.push(Some(eval_vec(e, batch)))
        None => input_cols.push(None)
      }
    }
    for r in 0..<batch.row_count() {
      let kv : Array[@types.Scalar] = []
      for c in key_cols {
        kv.push(c.get(r))
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
        let input = match input_cols[i] {
          Some(col) => col.get(r)
          None => @types.Null
        } // CountStar ignores it
        row[i] = acc_step(row[i], aggs[i], input)
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
                }
              }
            None => ()
          }
        }
        if !matched {
          if step.kind is Left {
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
                }
              }
            None => ()
          }
        }
        if !matched {
          if step.kind is Left {
            left_ids.push(r)
            right_ids.push(-1)
          }
        }
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
      copy_vec_range(dst, w, b.columns()[c])
      w += b.row_count()
    }
    columns.push(dst)
  }
  @types.DataBatch::new(columns, total)
}

///|
/// Copy one vector's rows into another at the given offset. Same dtype
/// by construction (concat batches share a layout); the fallback mirrors
/// ColumnVector::set's silent mismatch ignore.
fn copy_vec_range(
  dst : @types.ColumnVector,
  w : Int,
  src : @types.ColumnVector,
) -> Unit {
  let n = src.len()
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
