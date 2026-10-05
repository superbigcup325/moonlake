// Window-function stage: runs once the aggregate/HAVING batch exists
// and before pre-projection sorting and projection. Each window sorts
// the row ids by (partition keys, order keys, original position), walks
// the sorted runs, and writes each row's value back by original id —
// the batch's row order never changes, so downstream stages stay
// oblivious. The computed columns are appended in marker order and the
// select list's WinRef markers resolve to plain column refs over them.

///|
/// Compute every window definition over the pre-projection batch and
/// append one output column per window. Returns the extended batch and
/// the select-list expressions with WinRef resolved to ColRef.
///
/// Semantics: partition keys group rows (NULL-safe equality); order
/// keys rank rows inside a partition, NULLS LAST by default like the
/// engine's ORDER BY. Ranking functions number rows. Aggregate windows
/// use the standard default frame — RANGE UNBOUNDED PRECEDING TO
/// CURRENT ROW: a running aggregate whose value at each row extends
/// through the end of its peer group (rows with equal order keys share
/// one value); without ORDER BY the frame spans the whole partition.
fn exec_windows(
  batch : @types.DataBatch,
  windows : Array[BoundWin],
  out_exprs : Array[PhysExpr],
) -> (@types.DataBatch, Array[PhysExpr]) raise @types.SqlError {
  let n = batch.row_count()
  let base = batch.columns().length()
  let columns : Array[@types.ColumnVector] = []
  for src in batch.columns() {
    columns.push(src)
  }
  for w in windows {
    // evaluate keys and input once, materialized row-major for the
    // comparator and the value walk
    let part_vals : Array[Array[@types.Scalar]] = []
    for e in w.partition {
      part_vals.push(materialize(eval_vec(e, batch), n))
    }
    let ord_vals : Array[Array[@types.Scalar]] = []
    for k in w.order {
      ord_vals.push(materialize(eval_vec(k.0, batch), n))
    }
    let input_col : @types.ColumnVector? = match w.spec.input {
      Some(e) => Some(eval_vec(e, batch))
      None => None
    }
    // stable argsort: partition keys keep partitions contiguous (any
    // consistent NULL placement works), order keys rank inside them,
    // the final id tiebreak keeps the original order
    let sorted : Array[Int] = []
    for i in 0..<n {
      sorted.push(i)
    }
    if n > 1 {
      let key_cols : Array[Array[@types.Scalar]] = []
      let kds : Array[(Int, Bool, Bool?)] = []
      let nfs : Array[Bool?] = []
      for pv in part_vals {
        kds.push((key_cols.length(), false, None))
        nfs.push(None)
        key_cols.push(pv)
      }
      for oi, ov in ord_vals {
        kds.push((key_cols.length(), w.order[oi].1, w.order[oi].2))
        nfs.push(w.order[oi].2)
        key_cols.push(ov)
      }
      sorted.sort_by((a, b) => cmp_decorated(key_cols, kds, nfs, a, b))
    }
    let vals : Array[@types.Scalar] = Array::make(n, @types.Null)
    match w.kind {
      WRowNumber => {
        let mut rn = 0
        for pos in 0..<n {
          if pos == 0 || !same_keys(part_vals, sorted[pos], sorted[pos - 1]) {
            rn = 0
          }
          rn += 1
          vals[sorted[pos]] = @types.Int64(rn.to_int64())
        }
      }
      WRank => {
        let mut rn = 0
        let mut rank = 0
        for pos in 0..<n {
          let i = sorted[pos]
          let new_part = pos == 0 || !same_keys(part_vals, i, sorted[pos - 1])
          if new_part {
            rn = 0
          }
          rn += 1
          // peers (equal order keys) share the rank of their group's
          // first row; the next distinct key jumps to the row count
          if new_part || !same_keys(ord_vals, i, sorted[pos - 1]) {
            rank = rn
          }
          vals[i] = @types.Int64(rank.to_int64())
        }
      }
      WDenseRank => {
        let mut dr = 0
        for pos in 0..<n {
          let i = sorted[pos]
          if pos == 0 || !same_keys(part_vals, i, sorted[pos - 1]) {
            dr = 1
          } else if !same_keys(ord_vals, i, sorted[pos - 1]) {
            dr += 1
          }
          vals[i] = @types.Int64(dr.to_int64())
        }
      }
      WAgg => {
        // running frame: accumulate in sorted order; a peer group's
        // value is the aggregate through its last row. acc_finish
        // snapshots the running state (sorting a median copy, reading
        // the sum) without disturbing the accumulator.
        let spec = w.spec
        let mut acc = new_accs([spec])[0]
        let mut pos = 0
        while pos < n {
          if pos == 0 || !same_keys(part_vals, sorted[pos], sorted[pos - 1]) {
            acc = new_accs([spec])[0]
          }
          let mut end = pos + 1
          while end < n &&
                same_keys(part_vals, sorted[end], sorted[pos]) &&
                same_keys(ord_vals, sorted[end], sorted[end - 1]) {
            end += 1
          }
          for g in pos..<end {
            let input = match input_col {
              Some(col) => col.get(sorted[g])
              None => @types.Null
            } // count(*)
            acc_step(acc, spec, input)
          }
          let v = acc_finish(acc, spec)
          for g in pos..<end {
            vals[sorted[g]] = v
          }
          pos = end
        }
      }
    }
    let vec = @types.ColumnVector::make(w.out_type(), n)
    for r in 0..<n {
      vec.set(r, vals[r])
    }
    columns.push(vec)
  }
  (@types.DataBatch::new(columns, n), resolve_win_refs_all(out_exprs, base))
}

///|
fn materialize(vec : @types.ColumnVector, n : Int) -> Array[@types.Scalar] {
  let out : Array[@types.Scalar] = []
  for r in 0..<n {
    out.push(vec.get(r))
  }
  out
}

///|
/// NULL-safe scalar equality: NULL equals NULL (peers, same partition),
/// otherwise SQL compare, with a key-text fallback for types the
/// ordering compare does not cover (bool).
fn scalar_eq(a : @types.Scalar, b : @types.Scalar) -> Bool {
  match (a, b) {
    (@types.Null, @types.Null) => true
    (@types.Null, _) | (_, @types.Null) => false
    _ =>
      match @types.Scalar::compare(a, b) {
        Some(c) => c == 0
        None => scalar_key(a) == scalar_key(b)
      }
  }
}

///|
/// All key columns equal for rows a and b (row ids into the original
/// batch; each column holds one key value per row).
fn same_keys(cols : Array[Array[@types.Scalar]], a : Int, b : Int) -> Bool {
  for col in cols {
    if !scalar_eq(col[a], col[b]) {
      return false
    }
  }
  true
}

///|
fn resolve_win_refs_all(exprs : Array[PhysExpr], base : Int) -> Array[PhysExpr] {
  let out : Array[PhysExpr] = []
  for e in exprs {
    out.push(resolve_win_refs(e, base))
  }
  out
}

///|
/// Rewrite WinRef(k) markers into ColRef(base + k) once the window
/// columns exist. Everything else deep-copies unchanged.
fn resolve_win_refs(e : PhysExpr, base : Int) -> PhysExpr {
  match e {
    WinRef(k, dt) => ColRef(base + k, dt)
    ColRef(_, _) | Const(_) => e
    Promote(inner, dt) => Promote(resolve_win_refs(inner, base), dt)
    ArithE(op, l, r, dt) =>
      ArithE(op, resolve_win_refs(l, base), resolve_win_refs(r, base), dt)
    CmpE(op, l, r) =>
      CmpE(op, resolve_win_refs(l, base), resolve_win_refs(r, base))
    AndE(l, r) => AndE(resolve_win_refs(l, base), resolve_win_refs(r, base))
    OrE(l, r) => OrE(resolve_win_refs(l, base), resolve_win_refs(r, base))
    NotE(inner) => NotE(resolve_win_refs(inner, base))
    LikeE(inner, pattern) => LikeE(resolve_win_refs(inner, base), pattern)
    IsNullE(inner, negated) => IsNullE(resolve_win_refs(inner, base), negated)
    ExtractE(inner, field) => ExtractE(resolve_win_refs(inner, base), field)
    InSetE(inner, set, negated, has_null) =>
      InSetE(resolve_win_refs(inner, base), set, negated, has_null)
    FuncE(name, args, dt) => {
      let new_args : Array[PhysExpr] = []
      for a in args {
        new_args.push(resolve_win_refs(a, base))
      }
      FuncE(name, new_args, dt)
    }
    CastE(inner, dt) => CastE(resolve_win_refs(inner, base), dt)
    DateArithE(inner, qty, unit) =>
      DateArithE(resolve_win_refs(inner, base), qty, unit)
    CaseE(whens, else_, dt) => {
      let new_whens : Array[(PhysExpr, PhysExpr)] = []
      for w in whens {
        new_whens.push(
          (resolve_win_refs(w.0, base), resolve_win_refs(w.1, base)),
        )
      }
      let new_else = match else_ {
        Some(e) => Some(resolve_win_refs(e, base))
        None => None
      }
      CaseE(new_whens, new_else, dt)
    }
  }
}
