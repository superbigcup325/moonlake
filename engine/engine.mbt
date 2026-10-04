// Engine facade: parse, bind and execute a SELECT over a registered
// catalog. The W2 pipeline is scan -> filter -> hash aggregate ->
// having -> projection -> order -> limit.

///|
pub struct SelectResult {
  priv names : Array[String]
  priv types : Array[@types.DataType]
  priv batch : @types.DataBatch
}

///|
pub fn SelectResult::names(self : SelectResult) -> Array[String] {
  self.names
}

///|
pub fn SelectResult::types(self : SelectResult) -> Array[@types.DataType] {
  self.types
}

///|
pub fn SelectResult::batch(self : SelectResult) -> @types.DataBatch {
  self.batch
}

///|
/// Scalar cell accessor for result consumption (row, column).
pub fn SelectResult::get(
  self : SelectResult,
  row : Int,
  col : Int,
) -> @types.Scalar {
  self.batch.columns()[col].get(row)
}

///|
pub fn SelectResult::row_count(self : SelectResult) -> Int {
  self.batch.row_count()
}

///|
pub fn run_select(
  sql : String,
  catalog : @catalog.Catalog,
) -> SelectResult raise @types.SqlError {
  let sel = parse_select(sql)
  run_parsed(sel, catalog, [])
}

///|
/// Execute a parsed select. FROM items resolve to schemas and batches —
/// base tables come from the catalog, derived tables recurse and
/// materialize (everything in the engine is eager, so this is direct).
fn run_parsed(
  sel : Select,
  catalog : @catalog.Catalog,
  stats : Array[(String, Int)],
) -> SelectResult raise @types.SqlError {
  // correlated EXISTS / IN conjuncts become semi/anti joins against
  // pre-executed synthetic tables before anything else runs
  let (sel, extra_schemas, extra_batches) = decorrelate(sel, catalog)
  let schemas : Array[@catalog.TableSchema] = []
  let tables : Array[Array[@types.DataBatch]] = []
  match sel.setop {
    Some((kind, all, right_sel)) =>
      return run_setop(sel, kind, all, right_sel, catalog)
    None => ()
  }
  if sel.from.length() == 0 {
    // SELECT without FROM: a zero-column one-row dummy table drives the
    // pipeline like any single table
    sel.from.push({
      table: Named("__one"),
      tbl_alias: None,
      col_aliases: None,
      join: Inner,
      on: None,
    })
  }
  for item in sel.from {
    match item.table {
      Named(name) => {
        if name == "__one" {
          schemas.push({ table: name, columns: [], })
          let cols : Array[@types.ColumnVector] = []
          tables.push([@types.DataBatch::new(cols, 1)])
          continue
        }
        // synthetic semi/anti tables live here, not in the catalog
        let mut hit = false
        for i in 0..<extra_schemas.length() {
          if extra_schemas[i].table == name {
            schemas.push(extra_schemas[i])
            tables.push(extra_batches[i])
            hit = true
          }
        }
        if !hit {
          match catalog.lookup(name) {
            Some(entry) => {
              schemas.push(entry.schema)
              tables.push(entry.batches)
            }
            None => raise @types.SqlError::Bind("unknown table \"\{name}\"")
          }
        }
      }
      Sub(inner) => {
        let r = run_parsed(inner, catalog, [])
        let names = r.names()
        let types = r.types()
        // an explicit column alias list renames the outputs positionally
        let final_names : Array[String] = match item.col_aliases {
          Some(aliases) => {
            if aliases.length() != names.length() {
              raise @types.SqlError::Bind(
                "derived table has \{names.length()} columns but \{aliases.length()} column aliases were given",
              )
            }
            aliases
          }
          None => names
        }
        let columns : Array[@catalog.Column] = []
        for i, name in final_names {
          for j in 0..<i {
            if final_names[j] == name {
              raise @types.SqlError::Bind(
                "duplicate column \"\{name}\" in derived table",
              )
            }
          }
          columns.push({ name, dtype: types[i], })
        }
        let tname = match item.tbl_alias {
          Some(a) => a
          None => "_subquery"
        }
        schemas.push({ table: tname, columns, })
        tables.push([r.batch()])
      }
    }
  }
  let runner : SubqueryRunner = { catalog, }
  let plan = prune_bound(bind_select(sel, schemas, runner), schemas)
  let bq = plan.bq
  // drop unreferenced columns up front; the kept vectors are shared
  let narrowed : Array[Array[@types.DataBatch]] = []
  for k in 0..<tables.length() {
    narrowed.push(narrow_batches(tables[k], plan.table_cols[k]))
    if stats.length() > 0 || true {
      let mut rows = 0
      for bt in tables[k] {
        rows += bt.row_count()
      }
      stats.push(("scan \{schemas[k].table}", rows))
    }
  }
  let joined = exec_joins(narrowed, bq.steps, bq.deferred)
  if bq.steps.length() > 1 {
    let mut joined_rows = 0
    for bt in joined {
      joined_rows += bt.row_count()
    }
    stats.push(("joins", joined_rows))
  }
  let kept : Array[@types.DataBatch] = if bq.aggregate {
    let grouped = aggregate(joined, bq.group_exprs, bq.group_types, bq.aggs)
    let grouped = match bq.having {
      Some(h) => compact(grouped, eval_mask(h, grouped))
      None => grouped
    }
    stats.push(("aggregate", grouped.row_count()))
    [grouped]
  } else {
    joined
  }
  // Window functions append their output columns before projection;
  // the select list's markers resolve to them.
  let pre = concat_batches(kept, bq.steps[bq.steps.length() - 1].out_dtypes)
  let mut out_exprs = bq.out_exprs
  let pre = if bq.windows.length() > 0 {
    let (pre2, resolved) = exec_windows(pre, bq.windows, out_exprs)
    out_exprs = resolved
    if stats.length() > 0 {
      stats.push(("windows", pre2.row_count()))
    }
    pre2
  } else {
    pre
  }
  // ORDER BY keys sort the pre-projection rows in written order: an
  // output-column key evaluates as its projection expression (the same
  // values the projected column holds), an expression key as bound.
  // Sorting once, jointly, is what makes mixed keys keep their written
  // priority — the previous two-phase sort silently dropped one side.
  let keys : Array[(PhysExpr, Bool, Bool?)] = []
  for spec in bq.order_by {
    let ke = match spec.out_col {
      Some(i) => out_exprs[i]
      None => spec.expr
    }
    keys.push((ke, spec.desc, spec.nulls_first))
  }
  let batch = if keys.length() > 0 {
    let sorted = sort_exprs(pre, keys, None, None)
    let projected = project(sorted, out_exprs, bq.out_types)
    let projected = if bq.distinct { dedupe_rows(projected) } else { projected }
    sort_exprs(projected, [], bq.offset, bq.limit)
  } else {
    let projected = project(pre, out_exprs, bq.out_types)
    let projected = if bq.distinct { dedupe_rows(projected) } else { projected }
    order_limit(projected, [], bq.limit, bq.offset)
  }
  if stats.length() > 0 && !(stats[stats.length() - 1].0 == "result") {
    stats.push(("result", batch.row_count()))
  }
  { names: bq.names, types: bq.out_types, batch, }
}

///|
/// Run the query and render the physical plan annotated with the
/// actual row counts each stage produced — scans, join outputs,
/// aggregate groups and the final result. No clocks: row counts are
/// the deterministic part of ANALYZE.
pub fn explain_analyze(
  sql : String,
  catalog : @catalog.Catalog,
) -> String raise @types.SqlError {
  let stats : Array[(String, Int)] = []
  let result = run_parsed(parse_select(sql), catalog, stats)
  let sb = StringBuilder()
  sb.write_string(explain(sql, catalog))
  sb.write_string("\n-- actual rows")
  for (stage, rows) in stats {
    sb.write_string("\n\{stage}: \{rows}")
  }
  let _ = result
  sb.to_string()
}

///|
/// UNION [ALL]: flatten the right-nested chain into cores, merge left
/// to right honoring each op (bare UNION dedupes, ALL keeps
/// duplicates), then apply the trailing ORDER BY / OFFSET / LIMIT /
/// DISTINCT, which belongs to the whole union. ORDER BY over a union
/// resolves output names and ordinals only; column counts and types
/// must match exactly.

///|
/// One set operation over two executed branches; the result keeps the
/// left branch's column names. INTERSECT / EXCEPT compare whole rows
/// with NULL-safe keys; ALL variants use multiset counts, DISTINCT
/// dedupes the result.
fn apply_setop(
  kind : SetOpKind,
  all : Bool,
  left : SelectResult,
  right : SelectResult,
) -> SelectResult raise @types.SqlError {
  let names = left.names()
  let types = left.types()
  if names.length() != right.names().length() {
    raise @types.SqlError::Bind(
      "set operation requires equal column counts: \{names.length()} vs \{right.names().length()}",
    )
  }
  for c in 0..<names.length() {
    if types[c] != right.types()[c] {
      raise @types.SqlError::Bind(
        "set operation column \{c + 1} type mismatch: \{types[c].to_string()} vs \{right.types()[c].to_string()}",
      )
    }
  }
  let batch = left.batch()
  match kind {
    Union => {
      let batch = concat_batches([batch, right.batch()], types)
      let batch = if all {
        batch
      } else {
        dedupe_rows(batch) // bare UNION is DISTINCT
      }
      { names, types, batch, }
    }
    Intersect => {
      let counts = row_counts(right.batch())
      let taken : Map[String, Int] = Map([])
      let keep : Array[Int] = []
      for r in 0..<batch.row_count() {
        let k = row_key(batch, r)
        let used = match taken.get(k) {
          Some(v) => v
          None => 0
        }
        let available = match counts.get(k) {
          Some(v) => v
          None => 0
        }
        if used < available {
          keep.push(r)
          taken[k] = used + 1
        }
      }
      let batch = take_rows(batch, keep)
      let batch = if all { batch } else { dedupe_rows(batch) }
      { names, types, batch, }
    }
    Except => {
      let counts = row_counts(right.batch())
      let taken : Map[String, Int] = Map([])
      let keep : Array[Int] = []
      for r in 0..<batch.row_count() {
        let k = row_key(batch, r)
        let used = match taken.get(k) {
          Some(v) => v
          None => 0
        }
        let available = match counts.get(k) {
          Some(v) => v
          None => 0
        }
        taken[k] = used + 1
        if used >= available {
          keep.push(r)
        }
      }
      let batch = take_rows(batch, keep)
      let batch = if all { batch } else { dedupe_rows(batch) }
      { names, types, batch, }
    }
  }
}

///|
fn run_setop(
  sel : Select,
  _kind : SetOpKind,
  _all : Bool,
  _right_sel : Select,
  catalog : @catalog.Catalog,
) -> SelectResult raise @types.SqlError {
  // the root carries the trailing window (ORDER BY / LIMIT / OFFSET /
  // DISTINCT written after the last core)
  let window_sel = sel
  // walk root -> first: the arrays come out in reverse execution order
  let walked : Array[Select] = []
  let walked_ops : Array[(SetOpKind, Bool)] = []
  let mut cur = sel
  while cur.setop is Some((kind2, all2, left)) {
    walked.push({ ..cur, setop: None, })
    walked_ops.push((kind2, all2))
    cur = left
  }
  walked.push({ ..cur, setop: None, })
  let cores : Array[Select] = walked.rev()
  let ops : Array[(SetOpKind, Bool)] = walked_ops.rev() // ops[i-1] joins cores i-1, i
  // execute every branch, then apply ops with precedence: INTERSECT
  // binds tighter and collapses first, UNION / EXCEPT run left-to-right
  let work_results : Array[SelectResult] = []
  for c in cores {
    work_results.push(run_parsed(c, catalog, []))
  }
  let mut work_results = work_results
  let mut work_ops = ops
  while work_ops.length() > 0 {
    let mut j = -1
    for i, op in work_ops {
      if j == -1 && op.0 is Intersect {
        j = i
      }
    }
    if j == -1 {
      j = 0
    }
    let (kind, all) = work_ops[j]
    let left = work_results[j]
    let right = work_results[j + 1]
    let merged = apply_setop(kind, all, left, right)
    let nr : Array[SelectResult] = []
    for i, r in work_results {
      if i != j + 1 {
        nr.push(r)
      }
    }
    work_results = nr
    let no : Array[(SetOpKind, Bool)] = []
    for i, o in work_ops {
      if i != j {
        no.push(o)
      }
    }
    work_ops = no
    work_results[j] = merged
  }
  let first_result = work_results[0]
  let names = first_result.names()
  let types = first_result.types()
  let batch = first_result.batch()
  let order_keys : Array[(Int, Bool, Bool?)] = []
  for item in window_sel.order_by {
    let idx : Int? = match item.key {
      Col(name) => {
        let mut found = None
        for i, name2 in names {
          if name2 == name {
            found = Some(i)
          }
        }
        found
      }
      Lit(@types.Int32(v)) =>
        if v >= 1 && v <= names.length() {
          Some(v - 1)
        } else {
          raise @types.SqlError::Bind("ORDER BY position \{v} is out of range")
        }
      _ => None
    }
    match idx {
      Some(i) => order_keys.push((i, item.desc, item.nulls_first))
      None =>
        raise @types.SqlError::Bind(
          "ORDER BY over UNION must reference an output column (v1 subset)",
        )
    }
  }
  let batch = order_limit(
    batch,
    order_keys,
    window_sel.limit,
    window_sel.offset,
  )
  let batch = if window_sel.distinct { dedupe_rows(batch) } else { batch }
  { names, types, batch, }
}

///|
/// Render the physical plan without executing it: join steps with
/// pushdown classification, aggregation, projection, ordering.
pub fn explain(
  sql : String,
  catalog : @catalog.Catalog,
) -> String raise @types.SqlError {
  let sel = parse_select(sql)
  let schemas : Array[@catalog.TableSchema] = []
  for item in sel.from {
    match item.table {
      Named(name) =>
        match catalog.lookup(name) {
          Some(entry) => schemas.push(entry.schema)
          None => raise @types.SqlError::Bind("unknown table \"\{name}\"")
        }
      Sub(_) =>
        raise @types.SqlError::Bind(
          "EXPLAIN does not descend into derived tables yet",
        )
    }
  }
  let runner : SubqueryRunner = { catalog, }
  // the executed plan includes decorrelated semi/anti joins; explain
  // must render the same thing (the pass executes the inner queries,
  // which the plan depends on anyway)
  let (sel, extra_schemas, _extra_batches) = decorrelate(sel, catalog)
  for t in extra_schemas {
    schemas.push(t)
  }
  let bq = prune_bound(bind_select(sel, schemas, runner), schemas).bq
  let sb = StringBuilder()
  for i, step in bq.steps {
    if i == 0 {
      sb.write_string("scan ")
      sb.write_string(schemas[step.table].table)
      sb.write_string(" (")
      sb.write_string(step.out_dtypes.length().to_string())
      sb.write_string(" cols)")
      match step.build_filter {
        Some(f) => {
          sb.write_string("\n  filter: ")
          sb.write_string(f.to_repr().to_string())
        }
        None => ()
      }
    } else {
      sb.write_string("\nhash join ")
      sb.write_string(
        match step.kind {
          Inner => "inner"
          Left => "left"
          Right => "right"
          Full => "full"
          Semi => "semi"
          Anti => "anti"
          AntiLoose => "anti"
          Cross => "cross"
        },
      )
      sb.write_string(" with ")
      sb.write_string(schemas[step.table].table)
      for k in 0..<step.keys_l.length() {
        sb.write_string("\n  key: ")
        sb.write_string(step.keys_l[k].to_repr().to_string())
        sb.write_string(" = ")
        sb.write_string(step.keys_r[k].to_repr().to_string())
      }
      match step.build_filter {
        Some(f) => {
          sb.write_string("\n  build filter: ")
          sb.write_string(f.to_repr().to_string())
        }
        None => ()
      }
      match step.probe_filter {
        Some(f) => {
          sb.write_string("\n  probe filter: ")
          sb.write_string(f.to_repr().to_string())
        }
        None => ()
      }
      match step.residual {
        Some(f) => {
          sb.write_string("\n  residual: ")
          sb.write_string(f.to_repr().to_string())
        }
        None => ()
      }
    }
  }
  match bq.deferred {
    Some(f) => {
      sb.write_string("\ndeferred filter: ")
      sb.write_string(f.to_repr().to_string())
    }
    None => ()
  }
  if bq.aggregate {
    sb.write_string("\naggregate")
    if bq.group_exprs.length() > 0 {
      sb.write_string(" by")
      for e in bq.group_exprs {
        sb.write_string(" ")
        sb.write_string(e.to_repr().to_string())
      }
    }
    for spec in bq.aggs {
      sb.write_string("\n  agg -> ")
      sb.write_string(spec.out_type.to_string())
    }
    match bq.having {
      Some(h) => {
        sb.write_string("\nhaving: ")
        sb.write_string(h.to_repr().to_string())
      }
      None => ()
    }
  }
  for w in bq.windows {
    sb.write_string("\nwindow ")
    sb.write_string(
      match w.kind {
        WRowNumber => "row_number()"
        WRank => "rank()"
        WDenseRank => "dense_rank()"
        WAgg => {
          let lbl = agg_label_of_kind(w.spec.kind)
          "\{lbl}(...)"
        }
      },
    )
    if w.partition.length() > 0 {
      sb.write_string(" partition by")
      for e in w.partition {
        sb.write_string(" ")
        sb.write_string(e.to_repr().to_string())
      }
    }
    if w.order.length() > 0 {
      sb.write_string(" order by")
      for k in w.order {
        sb.write_string(" ")
        sb.write_string(k.0.to_repr().to_string())
        if k.1 {
          sb.write_string(" desc")
        }
      }
    }
  }
  sb.write_string("\nproject: ")
  for i, name in bq.names {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(name)
    sb.write_string(":")
    sb.write_string(bq.out_types[i].to_string())
  }
  if bq.order_by.length() > 0 {
    sb.write_string("\norder by")
    for spec in bq.order_by {
      sb.write_string(" ")
      match spec.out_col {
        Some(i) => sb.write_string(bq.names[i])
        None => sb.write_string(spec.expr.to_repr().to_string())
      }
      if spec.desc {
        sb.write_string(" desc")
      }
    }
  }
  match bq.limit {
    Some(k) => {
      sb.write_string("\nlimit: ")
      sb.write_string(k.to_string())
    }
    None => ()
  }
  sb.write_string("\n")
  sb.to_string()
}

///|
/// Whole result as one JSON array line. Strings are escaped; SQL NULL
/// becomes null.
pub fn SelectResult::to_json(self : SelectResult) -> String {
  let sb = StringBuilder()
  sb.write_char('[')
  for r in 0..<self.row_count() {
    if r > 0 {
      sb.write_char(',')
    }
    sb.write_char('{')
    for c in 0..<self.names().length() {
      if c > 0 {
        sb.write_char(',')
      }
      sb.write_char('"')
      sb.write_string(json_escape(self.names()[c]))
      sb.write_string("\":")
      match self.get(r, c) {
        @types.Null => sb.write_string("null")
        @types.Str(v) => {
          sb.write_char('"')
          sb.write_string(json_escape(v))
          sb.write_char('"')
        }
        other => sb.write_string(other.to_string())
      }
    }
    sb.write_char('}')
  }
  sb.write_char(']')
  sb.to_string()
}

///|
fn json_escape(s : String) -> String {
  let sb = StringBuilder()
  for ch in s {
    match ch {
      '"' => sb.write_string("\\\"")
      '\\' => sb.write_string("\\\\")
      '\n' => sb.write_string("\\n")
      '\r' => sb.write_string("\\r")
      '\t' => sb.write_string("\\t")
      _ => sb.write_char(ch)
    }
  }
  sb.to_string()
}
