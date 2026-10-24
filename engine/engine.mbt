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
  row : Int32,
  col : Int32,
) -> @types.Scalar {
  self.batch.columns()[col].get(row)
}

///|
pub fn SelectResult::row_count(self : SelectResult) -> Int32 {
  self.batch.row_count()
}

///|
pub fn run_select(
  sql : String,
  catalog : @catalog.Catalog,
) -> SelectResult raise @types.SqlError {
  run_select_opts(sql, catalog, ExecOptions::in_memory())
}

///|
/// Execute with explicit options (memory budget + spill store).
pub fn run_select_opts(
  sql : String,
  catalog : @catalog.Catalog,
  opts : ExecOptions,
) -> SelectResult raise @types.SqlError {
  let sel = @sql.parse_select(sql)
  run_parsed(sel, catalog, [], opts)
}

///|
/// Execute a parsed select. FROM items resolve to schemas and batches —
/// base tables come from the catalog, derived tables recurse and
/// materialize (everything in the engine is eager, so this is direct).
fn run_parsed(
  sel : @sql.Select,
  catalog : @catalog.Catalog,
  stats : Array[(String, Int64)],
  opts : ExecOptions,
) -> SelectResult raise @types.SqlError {
  // correlated EXISTS / IN conjuncts become semi/anti joins against
  // pre-executed synthetic tables before anything else runs
  let (sel, extra_schemas, extra_batches) = decorrelate(sel, catalog, opts)
  let schemas : Array[@catalog.TableSchema] = []
  let tables : Array[Array[@types.DataBatch]] = []
  // base tables keep their entry so the scan can go through its source;
  // derived, synthetic and dummy tables are materialized already
  let sources : Array[@catalog.TableEntry?] = []
  match sel.setop {
    Some((kind, all, right_sel)) =>
      return run_setop(sel, kind, all, right_sel, catalog, opts)
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
          sources.push(None)
          continue
        }
        // synthetic semi/anti tables live here, not in the catalog
        let mut hit = false
        for i in 0..<extra_schemas.length() {
          if extra_schemas[i].table == name {
            schemas.push(extra_schemas[i])
            tables.push(extra_batches[i])
            sources.push(None)
            hit = true
          }
        }
        if !hit {
          match catalog.lookup(name) {
            Some(entry) => {
              schemas.push(entry.schema)
              tables.push(entry.batches)
              sources.push(Some(entry))
            }
            None => raise @types.SqlError::Bind("unknown table \"\{name}\"")
          }
        }
      }
      Sub(inner) => {
        let r = run_parsed(inner, catalog, [], opts)
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
        sources.push(None)
      }
    }
  }
  let runner : SubqueryRunner = { catalog, opts, }
  let plan = prune_bound(bind_select(sel, schemas, runner), schemas)
  let bq = plan.bq
  // A LIMIT that needs nothing but the rows it returns stops its scan instead
  // of materializing the table and cutting the window out of the result.
  match streaming_limit_source(bq, sources) {
    Some(entry) => return stream_limit(bq, plan, entry, schemas[0].table, stats)
    None => ()
  }
  // Materialize each FROM item with only the columns the query reads. A base
  // table with a source scans through it (projection + predicate hints), and
  // applies its build filter per batch so unmatched rows never accumulate;
  // prescanned marks those tables so exec_joins does not filter them twice.
  let narrowed : Array[Array[@types.DataBatch]] = []
  let prescanned : Array[Bool] = []
  for k in 0..<tables.length() {
    let cols = plan.table_cols[k]
    let request = scan_request_of(bq, cols, k)
    let batches = match sources[k] {
      Some(entry) =>
        if entry.is_lazy() {
          prescanned.push(true)
          materialize_scan(entry, request, scan_filter_of(bq, k))
        } else {
          prescanned.push(false)
          @catalog.project_batches(tables[k], cols)
        }
      None => {
        prescanned.push(false)
        @catalog.project_batches(tables[k], cols)
      }
    }
    narrowed.push(batches)
    let mut rows = 0
    for bt in batches {
      rows += bt.row_count()
    }
    stats.push(("scan \{schemas[k].table}", rows.to_int64()))
  }
  let joined = exec_joins(
    narrowed,
    bq.steps,
    bq.deferred,
    opts,
    stats,
    prescanned,
  )
  if bq.steps.length() > 1 {
    let mut joined_rows = 0
    for bt in joined {
      joined_rows += bt.row_count()
    }
    stats.push(("joins", joined_rows.to_int64()))
  }
  let kept : Array[@types.DataBatch] = if bq.aggregate {
    let grouped = aggregate_within_budget(
      joined,
      bq.group_exprs,
      bq.group_types,
      bq.aggs,
      opts,
      stats,
    )
    let grouped = match bq.having {
      Some(h) => compact(grouped, eval_mask(h, grouped))
      None => grouped
    }
    stats.push(("aggregate", grouped.row_count().to_int64()))
    [grouped]
  } else {
    joined
  }
  // External sort: a non-aggregate ORDER BY under a budget sorts
  // externally (runs on disk, streaming merge into the projection and
  // the OFFSET/LIMIT window). Aggregate GROUP BY inputs spill through
  // the grace path above; window functions materialize the pre row
  // anyway and stay in-memory.
  if opts.budget > 0 &&
    !bq.aggregate &&
    bq.windows.length() == 0 &&
    bq.order_by.length() > 0 {
    match opts.spill {
      Some(store) => {
        let keys : Array[(PhysExpr, Bool, Bool?)] = []
        for spec in bq.order_by {
          keys.push((spec.expr, spec.desc, spec.nulls_first))
        }
        let batch = external_sort_project(
          kept,
          keys,
          bq.out_exprs,
          bq.out_types,
          bq.distinct,
          bq.offset,
          bq.limit,
          opts.budget,
          store,
          stats,
        )
        if stats.length() > 0 && !(stats[stats.length() - 1].0 == "result") {
          stats.push(("result", batch.row_count().to_int64()))
        }
        return { names: bq.names, types: bq.out_types, batch, }
      }
      None =>
        raise @types.SqlError::Execute(
          "query has a memory budget but no spill store is configured (pass --spill-dir)",
        )
    }
  }
  // Window functions append their output columns before projection;
  // the select list's markers resolve to them.
  let pre = concat_batches(kept, bq.steps[bq.steps.length() - 1].out_dtypes)
  let mut out_exprs = bq.out_exprs
  let pre = if bq.windows.length() > 0 {
    let (pre2, resolved) = exec_windows(pre, bq.windows, out_exprs)
    out_exprs = resolved
    if stats.length() > 0 {
      stats.push(("windows", pre2.row_count().to_int64()))
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
    stats.push(("result", batch.row_count().to_int64()))
  }
  { names: bq.names, types: bq.out_types, batch, }
}

///|
/// Run the query and render the physical plan annotated with the
/// actual row counts each stage produced — scans, join outputs,
/// aggregate groups and the final result — plus what it spilled, if
/// anything. No clocks: row counts and byte counts are the
/// deterministic part of ANALYZE.
pub fn explain_analyze(
  sql : String,
  catalog : @catalog.Catalog,
) -> String raise @types.SqlError {
  explain_analyze_with(sql, catalog, ExecOptions::in_memory())
}

///|
/// `explain_analyze` under explicit execution options. ANALYZE runs the
/// query, so the budget has to come in here as well: a plan rendered
/// under `ExecOptions::in_memory()` can never show a spill, which is
/// exactly the case a reader of ANALYZE wants to see.
pub fn explain_analyze_with(
  sql : String,
  catalog : @catalog.Catalog,
  opts : ExecOptions,
) -> String raise @types.SqlError {
  let stats : Array[(String, Int64)] = []
  let meter = SpillMeter::new()
  let run_opts = match opts.spill {
    Some(store) => { budget: opts.budget, spill: Some(meter.wrap(store)), }
    None => opts
  }
  let result = run_parsed(@sql.parse_select(sql), catalog, stats, run_opts)
  meter.report(stats)
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
  kind : @sql.SetOpKind,
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
      let taken : Map[String, Int32] = Map([])
      let keep : Array[Int32] = []
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
      let taken : Map[String, Int32] = Map([])
      let keep : Array[Int32] = []
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
  sel : @sql.Select,
  _kind : @sql.SetOpKind,
  _all : Bool,
  _right_sel : @sql.Select,
  catalog : @catalog.Catalog,
  opts : ExecOptions,
) -> SelectResult raise @types.SqlError {
  // the root carries the trailing window (ORDER BY / LIMIT / OFFSET /
  // DISTINCT written after the last core)
  let window_sel = sel
  // walk root -> first: the arrays come out in reverse execution order
  let walked : Array[@sql.Select] = []
  let walked_ops : Array[(@sql.SetOpKind, Bool)] = []
  let mut cur = sel
  while cur.setop is Some((kind2, all2, left)) {
    walked.push({ ..cur, setop: None, })
    walked_ops.push((kind2, all2))
    cur = left
  }
  walked.push({ ..cur, setop: None, })
  let cores : Array[@sql.Select] = walked.rev()
  let ops : Array[(@sql.SetOpKind, Bool)] = walked_ops.rev() // ops[i-1] joins cores i-1, i
  // execute every branch, then apply ops with precedence: INTERSECT
  // binds tighter and collapses first, UNION / EXCEPT run left-to-right
  let work_results : Array[SelectResult] = []
  for c in cores {
    work_results.push(run_parsed(c, catalog, [], opts))
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
    let no : Array[(@sql.SetOpKind, Bool)] = []
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
  let order_keys : Array[(Int32, Bool, Bool?)] = []
  for item in window_sel.order_by {
    let idx : Int32? = match item.key {
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
  let sel = @sql.parse_select(sql)
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
  let runner : SubqueryRunner = { catalog, opts: ExecOptions::in_memory(), }
  // the executed plan includes decorrelated semi/anti joins; explain
  // must render the same thing (the pass executes the inner queries,
  // which the plan depends on anyway)
  let (sel, extra_schemas, _extra_batches) = decorrelate(
    sel,
    catalog,
    ExecOptions::in_memory(),
  )
  for t in extra_schemas {
    schemas.push(t)
  }
  let plan = prune_bound(bind_select(sel, schemas, runner), schemas)
  let bq = plan.bq
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
      sb.write_string(
        scan_pushdown_text(catalog, schemas, plan, bq, step.table),
      )
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
      sb.write_string(
        scan_pushdown_text(catalog, schemas, plan, bq, step.table),
      )
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
/// becomes null. DATE renders as a quoted calendar date (DuckDB's own JSON
/// spelling), not a bare epoch integer. Non-finite FLOAT64 values have no
/// JSON number spelling, so they render as the strings "Infinity",
/// "-Infinity" and "NaN"; that keeps the output parseable while staying
/// distinct from both finite numbers and SQL NULL.
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
        @types.Date(v) => {
          sb.write_char('"')
          sb.write_string(@types.epoch_to_string(v))
          sb.write_char('"')
        }
        @types.Float64(v) =>
          if v.is_nan() {
            sb.write_string("\"NaN\"")
          } else if v.is_inf() {
            if v > 0.0 {
              sb.write_string("\"Infinity\"")
            } else {
              sb.write_string("\"-Infinity\"")
            }
          } else {
            sb.write_string(v.to_string())
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
