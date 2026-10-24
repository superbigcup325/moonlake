// Ordering and slicing: DISTINCT dedupe, projection, the row comparators,
// ORDER BY (sort_exprs) with its offset/limit window. Sorting that does not fit
// the budget lives in engine/extsort.mbt; what is here is the in-memory path it
// has to agree with.

///|
/// SELECT DISTINCT: keep the first row for every distinct projected row
/// (first-seen order, so ORDER BY ties stay stable).
fn dedupe_rows(batch : @types.DataBatch) -> @types.DataBatch {
  let seen : Map[String, Bool] = Map([])
  let indices : Array[Int32] = []
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
  keys : Array[(Int32, Bool, Bool?)],
  nulls_first : Array[Bool?],
  a : Int32,
  b : Int32,
) -> Int32 {
  for k, kv in keys {
    let x = key_cols[k][a]
    let y = key_cols[k][b]
    let nf = match nulls_first[k] {
      Some(f) => f
      None => false
    }
    let ord : Int32 = match (x, y) {
      (@types.Null, @types.Null) => 0
      (@types.Null, _) => if nf { -1 } else { 1 }
      (_, @types.Null) => if nf { 1 } else { -1 }
      _ => {
        let c = @types.Scalar::compare_nn(x, y)
        if kv.1 {
          -c
        } else {
          c
        }
      }
    }
    if ord != 0 {
      return ord
    }
  }
  a - b
}

///|
/// NULL placement for one key comparison: Some(ord) when a null is
/// involved (NULLS LAST by default, first when the key says so), None
/// when both values are present.
fn null_ord(xnull : Bool, ynull : Bool, nf : Bool) -> Int32? {
  if xnull && ynull {
    Some(0)
  } else if xnull {
    Some(if nf { -1 } else { 1 })
  } else if ynull {
    Some(if nf { 1 } else { -1 })
  } else {
    None
  }
}

///|
/// Typed two-row comparison over one ORDER BY key column: reads the
/// raw arrays — no boxed Scalars, no Option per comparison. Desc and
/// NULLS FIRST/LAST are applied here, mirroring cmp_decorated.
fn cmp_vec_rows(
  key : @types.ColumnVector,
  ia : Int32,
  ib : Int32,
  desc : Bool,
  nf : Bool,
) -> Int32 {
  fn finish(c : Int32) -> Int32 {
    if desc {
      -c
    } else {
      c
    }
  }

  match key {
    @types.I32(d, valid) =>
      match null_ord(!valid[ia], !valid[ib], nf) {
        Some(o) => o
        None => finish(ord_i(d[ia], d[ib]))
      }
    @types.I64(d, valid) =>
      match null_ord(!valid[ia], !valid[ib], nf) {
        Some(o) => o
        None => finish(ord_i64(d[ia], d[ib]))
      }
    @types.F64(d, valid) =>
      match null_ord(!valid[ia], !valid[ib], nf) {
        Some(o) => o
        None => finish(ord_f(d[ia], d[ib]))
      }
    @types.BoolV(d, valid) =>
      match null_ord(!valid[ia], !valid[ib], nf) {
        Some(o) => o
        None =>
          finish(
            match (d[ia], d[ib]) {
              (false, true) => -1
              (true, false) => 1
              _ => 0
            },
          )
      }
    @types.StrV(d, valid) =>
      match null_ord(!valid[ia], !valid[ib], nf) {
        Some(o) => o
        None => finish(d[ia].lexical_compare(d[ib]))
      }
    @types.DateV(d, valid) =>
      match null_ord(!valid[ia], !valid[ib], nf) {
        Some(o) => o
        None => finish(ord_i(d[ia], d[ib]))
      }
  }
}

///|
fn order_limit(
  batch : @types.DataBatch,
  keys : Array[(Int32, Bool, Bool?)],
  limit : Int32?,
  offset : Int32?,
) -> @types.DataBatch {
  let n = batch.row_count()
  let indices : Array[Int32] = []
  for i in 0..<n {
    indices.push(i)
  }
  if keys.length() > 0 {
    // sort against the key columns themselves: raw typed reads in the
    // comparator, no per-row Scalar decoration
    let key_vecs : Array[@types.ColumnVector] = []
    let descs : Array[Bool] = []
    let nfs : Array[Bool] = []
    for kv in keys {
      key_vecs.push(batch.columns()[kv.0])
      descs.push(kv.1)
      nfs.push(
        match kv.2 {
          Some(f) => f
          None => false
        },
      )
    }
    fn cmp_rows(a : Int32, b : Int32) -> Int32 {
      for k in 0..<key_vecs.length() {
        let ord = cmp_vec_rows(key_vecs[k], a, b, descs[k], nfs[k])
        if ord != 0 {
          return ord
        }
      }
      a - b
    }

    indices.sort_by(cmp_rows)
  }
  take_rows(batch, window(indices, offset, limit))
}

///|
/// Sort by key expressions over the pre-projection row, then apply the
/// offset/limit window. Key expressions evaluate once via the
/// vectorized evaluator; the comparator reads their vectors raw.
fn sort_exprs(
  batch : @types.DataBatch,
  keys : Array[(PhysExpr, Bool, Bool?)],
  offset : Int32?,
  limit : Int32?,
) -> @types.DataBatch raise @types.SqlError {
  let n = batch.row_count()
  let indices : Array[Int32] = []
  for i in 0..<n {
    indices.push(i)
  }
  if keys.length() > 0 {
    let key_vecs : Array[@types.ColumnVector] = []
    let descs : Array[Bool] = []
    let nfs : Array[Bool] = []
    for k in keys {
      key_vecs.push(eval_vec(k.0, batch))
      descs.push(k.1)
      nfs.push(
        match k.2 {
          Some(f) => f
          None => false
        },
      )
    }
    fn cmp_rows(a : Int32, b : Int32) -> Int32 {
      for k in 0..<key_vecs.length() {
        let ord = cmp_vec_rows(key_vecs[k], a, b, descs[k], nfs[k])
        if ord != 0 {
          return ord
        }
      }
      a - b
    }

    indices.sort_by(cmp_rows)
  }
  take_rows(batch, window(indices, offset, limit))
}

///|
/// The offset/limit window of a row-id list: skip `offset`, then take
/// at most `limit`.
fn window(
  indices : Array[Int32],
  offset : Int32?,
  limit : Int32?,
) -> Array[Int32] {
  let skip = match offset {
    Some(o) => o
    None => 0
  }
  let mut taken = 0
  let out : Array[Int32] = []
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
