// Projection pruning: after binding, compute which columns of each FROM
// table the query actually references, drop the rest from the pipeline
// layout, and rewrite every column reference to the narrowed indexes.
// Base tables materialize all their columns, so dropping a column is a
// zero-copy subset of each batch; joins, aggregation and projection
// then run over narrower rows. SELECT * references everything and
// degenerates to an identity rewrite.

///|
priv struct PrunePlan {
  bq : BoundQuery
  table_cols : Array[Array[Int]] // kept columns per FROM table, new order
}

///|
fn prune_bound(
  bq : BoundQuery,
  schemas : Array[@catalog.TableSchema],
) -> PrunePlan {
  let ntab = schemas.length()
  let widths : Array[Int] = []
  for s in schemas {
    widths.push(s.columns.length())
  }
  // referenced[t][local] over the pre-prune layout
  let needed : Array[Array[Bool]] = []
  for t in 0..<ntab {
    needed.push(Array::make(widths[t], false))
  }
  // slot-space expressions (right keys, build filters) reference their
  // own table by local index
  for step in bq.steps {
    for e in step.keys_r {
      collect_refs(e, fn(i) { (step.table, i) }, needed)
    }
    match step.build_filter {
      Some(f) => collect_refs(f, fn(i) { (step.table, i) }, needed)
      None => ()
    }
  }
  // flat-space expressions resolve through the join layout
  let total = bq.steps[bq.steps.length() - 1].right_offset +
    bq.steps[bq.steps.length() - 1].right_width
  let slot_of : Array[Int] = Array::make(total, 0)
  let local_of : Array[Int] = Array::make(total, 0)
  for step in bq.steps {
    for l in 0..<step.right_width {
      slot_of[step.right_offset + l] = step.table
      local_of[step.right_offset + l] = l
    }
  }
  fn mark_flat(e : PhysExpr) -> Unit {
    collect_refs(e, fn(i) { (slot_of[i], local_of[i]) }, needed)
  }
  for step in bq.steps {
    for e in step.keys_l {
      mark_flat(e)
    }
    match step.probe_filter {
      Some(f) => mark_flat(f)
      None => ()
    }
    match step.residual {
      Some(f) => mark_flat(f)
      None => ()
    }
  }
  match bq.deferred {
    Some(f) => mark_flat(f)
    None => ()
  }
  for e in bq.group_exprs {
    mark_flat(e)
  }
  for spec in bq.aggs {
    match spec.input {
      Some(e) => mark_flat(e)
      None => ()
    }
  }
  if !bq.aggregate {
    // AggOut-space projections reference the post-agg row, whose base
    // columns are already covered by group_exprs/aggs above
    for e in bq.out_exprs {
      mark_flat(e)
    }
  }
  // fast path: every column of every table is referenced
  let mut all_needed = true
  for t in 0..<ntab {
    let mut c = 0
    for l in 0..<widths[t] {
      if needed[t][l] {
        c += 1
      }
    }
    if c != widths[t] {
      all_needed = false
    }
  }
  if all_needed {
    let cols : Array[Array[Int]] = []
    for t in 0..<ntab {
      let full : Array[Int] = []
      for l in 0..<widths[t] {
        full.push(l)
      }
      cols.push(full)
    }
    return { bq, table_cols: cols, }
  }
  // per-table new local index (kept columns keep their relative order)
  let new_local : Array[Array[Int]] = []
  let table_cols : Array[Array[Int]] = []
  let new_width : Array[Int] = []
  for t in 0..<ntab {
    let map : Array[Int] = Array::make(widths[t], -1)
    let cols : Array[Int] = []
    for l in 0..<widths[t] {
      if needed[t][l] {
        map[l] = cols.length()
        cols.push(l)
      }
    }
    new_local.push(map)
    table_cols.push(cols)
    new_width.push(cols.length())
  }
  // new offsets in join order, and the old-flat -> new-flat map
  let new_off : Array[Int] = Array::make(ntab, 0)
  let flat_map : Array[Int] = Array::make(total, -1)
  let mut acc_w = 0
  for step in bq.steps {
    let t = step.table
    new_off[t] = acc_w
    for l in 0..<widths[t] {
      if new_local[t][l] >= 0 {
        flat_map[step.right_offset + l] = acc_w + new_local[t][l]
      }
    }
    acc_w += new_width[t]
  }
  // per-table kept dtypes, then rebuilt steps with cumulative layouts
  let slot_dtypes : Array[Array[@types.DataType]] = []
  for t in 0..<ntab {
    let dts : Array[@types.DataType] = []
    for c in table_cols[t] {
      dts.push(schemas[t].columns[c].dtype)
    }
    slot_dtypes.push(dts)
  }
  let steps : Array[JoinStep] = []
  let combined : Array[@types.DataType] = []
  for step in bq.steps {
    let t = step.table
    for dt in slot_dtypes[t] {
      combined.push(dt)
    }
    steps.push({
      table: step.table,
      kind: step.kind,
      keys_l: rewrite_all(step.keys_l, fn(i) { flat_map[i] }),
      keys_r: rewrite_all(step.keys_r, fn(i) { new_local[t][i] }),
      build_filter: rewrite_opt(step.build_filter, fn(i) { new_local[t][i] }),
      probe_filter: rewrite_opt(step.probe_filter, fn(i) { flat_map[i] }),
      residual: rewrite_opt(step.residual, fn(i) { flat_map[i] }),
      right_offset: new_off[t],
      right_width: new_width[t],
      out_dtypes: copy_dtypes(combined),
    })
  }
  let deferred = rewrite_opt(bq.deferred, fn(i) { flat_map[i] })
  let group_exprs = rewrite_all(bq.group_exprs, fn(i) { flat_map[i] })
  let aggs : Array[AggSpec] = []
  for spec in bq.aggs {
    aggs.push({
      kind: spec.kind,
      input: match spec.input {
        Some(e) => Some(rewrite_refs(e, fn(i) { flat_map[i] }))
        None => None
      },
      out_type: spec.out_type,
    })
  }
  let out_exprs = if bq.aggregate {
    bq.out_exprs
  } else {
    rewrite_all(bq.out_exprs, fn(i) { flat_map[i] })
  }
  {
    bq: {
      steps,
      deferred,
      aggregate: bq.aggregate,
      group_exprs,
      group_types: bq.group_types,
      aggs,
      having: bq.having,
      out_exprs,
      names: bq.names,
      out_types: bq.out_types,
      order_keys: bq.order_keys,
      limit: bq.limit,
    },
    table_cols,
  }
}

///|
fn copy_dtypes(dts : Array[@types.DataType]) -> Array[@types.DataType] {
  let out : Array[@types.DataType] = []
  for dt in dts {
    out.push(dt)
  }
  out
}

///|
/// Mark every column a PhysExpr references. `resolve` maps a ColRef
/// index to (table, local column).
fn collect_refs(
  e : PhysExpr,
  resolve : (Int) -> (Int, Int),
  needed : Array[Array[Bool]],
) -> Unit {
  match e {
    ColRef(i, _) => {
      let (t, l) = resolve(i)
      needed[t][l] = true
    }
    Const(_) => ()
    Promote(inner, _) => collect_refs(inner, resolve, needed)
    ArithE(_, l, r, _) => {
      collect_refs(l, resolve, needed)
      collect_refs(r, resolve, needed)
    }
    CmpE(_, l, r) => {
      collect_refs(l, resolve, needed)
      collect_refs(r, resolve, needed)
    }
    AndE(l, r) => {
      collect_refs(l, resolve, needed)
      collect_refs(r, resolve, needed)
    }
    OrE(l, r) => {
      collect_refs(l, resolve, needed)
      collect_refs(r, resolve, needed)
    }
    NotE(inner) => collect_refs(inner, resolve, needed)
    LikeE(inner, _) => collect_refs(inner, resolve, needed)
    IsNullE(inner, _) => collect_refs(inner, resolve, needed)
    ExtractE(inner, _) => collect_refs(inner, resolve, needed)
    InSetE(inner, _, _, _) => collect_refs(inner, resolve, needed)
    CaseE(whens, else_, _) => {
      for w in whens {
        collect_refs(w.0, resolve, needed)
        collect_refs(w.1, resolve, needed)
      }
      match else_ {
        Some(e) => collect_refs(e, resolve, needed)
        None => ()
      }
    }
  }
}

///|
/// Deep-copy an expression list with every ColRef index remapped.
fn rewrite_all(exprs : Array[PhysExpr], m : (Int) -> Int) -> Array[PhysExpr] {
  let out : Array[PhysExpr] = []
  for e in exprs {
    out.push(rewrite_refs(e, m))
  }
  out
}

///|
fn rewrite_opt(e : PhysExpr?, m : (Int) -> Int) -> PhysExpr? {
  match e {
    Some(inner) => Some(rewrite_refs(inner, m))
    None => None
  }
}

///|
fn rewrite_refs(e : PhysExpr, m : (Int) -> Int) -> PhysExpr {
  match e {
    ColRef(i, dt) => ColRef(m(i), dt)
    Const(v) => Const(v)
    Promote(inner, dt) => Promote(rewrite_refs(inner, m), dt)
    ArithE(op, l, r, dt) =>
      ArithE(op, rewrite_refs(l, m), rewrite_refs(r, m), dt)
    CmpE(op, l, r) => CmpE(op, rewrite_refs(l, m), rewrite_refs(r, m))
    AndE(l, r) => AndE(rewrite_refs(l, m), rewrite_refs(r, m))
    OrE(l, r) => OrE(rewrite_refs(l, m), rewrite_refs(r, m))
    NotE(inner) => NotE(rewrite_refs(inner, m))
    LikeE(inner, pattern) => LikeE(rewrite_refs(inner, m), pattern)
    IsNullE(inner, negated) => IsNullE(rewrite_refs(inner, m), negated)
    ExtractE(inner, field) => ExtractE(rewrite_refs(inner, m), field)
    InSetE(inner, set, negated, has_null) =>
      InSetE(rewrite_refs(inner, m), set, negated, has_null)
    CaseE(whens, else_, dt) => {
      let new_whens : Array[(PhysExpr, PhysExpr)] = []
      for w in whens {
        new_whens.push((rewrite_refs(w.0, m), rewrite_refs(w.1, m)))
      }
      let new_else = match else_ {
        Some(e) => Some(rewrite_refs(e, m))
        None => None
      }
      CaseE(new_whens, new_else, dt)
    }
  }
}
