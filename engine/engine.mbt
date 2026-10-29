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
/// Execute a parsed select and collect the whole result. The preparation and
/// the pipeline below are shared with `run_select_stream`, so a query means
/// the same thing whether its rows are collected or pulled.
fn run_parsed(
  sel : @sql.Select,
  catalog : @catalog.Catalog,
  stats : Array[(String, Int64)],
  opts : ExecOptions,
) -> SelectResult raise @types.SqlError {
  match prepare_select(sel, catalog, opts) {
    Setop(result) => result
    Ready(launch) =>
      match streaming_source(launch.bq, launch.sources) {
        // A single-table scan is pulled even when the caller wants the
        // result whole: the LIMIT window then stops the scan instead of
        // materializing the table and cutting the window out of the result.
        Some(entry) => {
          let result = drain_scan(
            scan_pull(
              launch.bq,
              launch.plan,
              entry,
              launch.schemas[0].table,
              stats,
            ),
            launch.bq,
          )
          if stats.length() > 0 && !(stats[stats.length() - 1].0 == "result") {
            stats.push(("result", result.row_count().to_int64()))
          }
          result
        }
        None => run_pipeline(launch, opts, stats)
      }
  }
}

///|
/// Execute a parsed select and hand the rows out as they come. See
/// `ResultStream` for what a caller may assume.
pub fn run_select_stream(
  sql : String,
  catalog : @catalog.Catalog,
) -> ResultStream raise @types.SqlError {
  run_select_stream_opts(sql, catalog, ExecOptions::in_memory())
}

///|
/// `run_select_stream` under explicit options. Three shapes are pulled rather
/// than materialized: a single table narrowed by a filter, projection and
/// window; a two-table join whose build side is read once and whose probe side
/// arrives a batch at a time; and a spilled ORDER BY, whose runs this stream
/// owns. A global aggregate folds the scan as it arrives but still hands back
/// its one-row answer as one batch. Everything else is computed first and
/// handed back as one batch.
pub fn run_select_stream_opts(
  sql : String,
  catalog : @catalog.Catalog,
  opts : ExecOptions,
) -> ResultStream raise @types.SqlError {
  let sel = @sql.parse_select(sql)
  match prepare_select(sel, catalog, opts) {
    Setop(result) => ResultStream::materialized(result)
    Ready(launch) =>
      // a two-table hash join hands out its output as it probes: the build side
      // is read here, which it has to be, and the probe side is never collected
      match streaming_join_source(launch.bq, launch.sources) {
        Some(src) => ResultStream::joined(src, launch)
        None =>
          // a spilled sort is the one shape that hands out a merge: the runs
          // are built here, and the stream owns them
          match streaming_sort_source(launch.bq, launch.sources, opts) {
            Some(entry) => ResultStream::sorted(entry, launch, opts)
            None =>
              match streaming_source(launch.bq, launch.sources) {
                Some(entry) =>
                  {
                    names: launch.bq.names,
                    types: launch.bq.out_types,
                    pull: Scanned(
                      scan_pull(
                        launch.bq,
                        launch.plan,
                        entry,
                        launch.schemas[0].table,
                        [],
                      ),
                    ),
                    done: false,
                  }
                None =>
                  ResultStream::materialized(run_pipeline(launch, opts, []))
              }
          }
      }
  }
}

///|
/// Everything the executor needs once the query is bound: the query, each FROM
/// item's schema and batches, and — for a base table — the entry that can
/// still be scanned lazily.
priv struct Launch {
  bq : BoundQuery
  plan : PrunePlan
  schemas : Array[@catalog.TableSchema]
  sources : Array[@catalog.TableEntry?]
  tables : Array[Array[@types.DataBatch]]
}

///|
/// A prepared query: ready for the pipeline, or already answered — a set
/// operation runs its two halves itself.
priv enum Prepared {
  Ready(Launch)
  Setop(SelectResult)
}

///|
/// Decorrelate, dispatch a set operation, resolve every FROM item (base tables
/// keep their source; derived and synthetic tables are materialized here),
/// then bind and prune.
fn prepare_select(
  sel_in : @sql.Select,
  catalog : @catalog.Catalog,
  opts : ExecOptions,
) -> Prepared raise @types.SqlError {
  // correlated EXISTS / IN conjuncts become semi/anti joins against
  // pre-executed synthetic tables before anything else runs
  let (sel, extra_schemas, extra_batches) = decorrelate(sel_in, catalog, opts)
  let schemas : Array[@catalog.TableSchema] = []
  let tables : Array[Array[@types.DataBatch]] = []
  // base tables keep their entry so the scan can go through its source;
  // derived, synthetic and dummy tables are materialized already
  let sources : Array[@catalog.TableEntry?] = []
  match sel.setop {
    Some((kind, all, right_sel)) =>
      return Setop(run_setop(sel, kind, all, right_sel, catalog, opts))
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
  Ready({ bq: plan.bq, plan, schemas, sources, tables, })
}

///|
/// The eager pipeline: materialize what the FROM items need, join, aggregate,
/// sort, project and window. `launch` decided what the query means; nothing
/// here re-reads it.
fn run_pipeline(
  launch : Launch,
  opts : ExecOptions,
  stats : Array[(String, Int64)],
) -> SelectResult raise @types.SqlError {
  let bq = launch.bq
  let plan = launch.plan
  let schemas = launch.schemas
  let sources = launch.sources
  let tables = launch.tables
  // A single-table aggregate is fed from the scan instead of a collected
  // input: the group state is built as batches arrive, so the operator holds
  // its state and one batch rather than its input. A budgeted GROUP BY buffers
  // up to the budget and spills only past it, and an ORDER BY sorts the finished
  // groups once the fold ends. Shapes that need the whole row set first (DISTINCT,
  // a window function) stay on the eager path below.
  match streaming_agg_source(bq, sources) {
    Some(entry) => return run_agg_pull(entry, launch, opts, stats)
    None => ()
  }
  // An ORDER BY under a budget is fed from the scan the same way: the runs are
  // written as the batches arrive, so the input is never an array here either,
  // and a LIMIT stops the merge as soon as its window is full. Without a budget
  // the in-memory sort has to see every row, so the eager path below keeps it.
  match streaming_sort_source(bq, sources, opts) {
    Some(entry) => return run_sort_pull(entry, launch, opts, stats)
    None => ()
  }
  // A join feeding an aggregate is folded from the join's own batches: the build
  // side of every step is read here because it has to be, the probe side arrives
  // a batch at a time, and each joined batch is folded before the next one
  // exists. The build sides are held whole, so a budget too small for them keeps
  // the eager path below, which can partition each join instead; the scans this
  // read already holds are handed to that path, so no table is read twice.
  let mut prebuilt : Array[Array[@types.DataBatch]]? = None
  match streaming_join_agg_source(bq, sources) {
    Some(src) => {
      let scans = join_agg_scans(src, launch)
      let sides = join_agg_sides_bytes(scans)
      if join_agg_composes(sides, opts) {
        return run_join_agg_pull(
          src,
          scans,
          join_agg_sides(scans, bq.steps),
          launch,
          opts,
          stats,
        )
      }
      prebuilt = Some(scans)
    }
    None => ()
  }
  // Materialize each FROM item with only the columns the query reads. A base
  // table with a source scans through it (projection + predicate hints), and
  // applies its build filter per batch so unmatched rows never accumulate;
  // prescanned marks those tables so exec_joins does not filter them twice.
  let narrowed : Array[Array[@types.DataBatch]] = []
  let prescanned : Array[Bool] = []
  for k in 0..<tables.length() {
    // a build side a rejected composition already read is filtered and projected
    // exactly as this loop would have, so the table is not read twice
    let handed : Array[@types.DataBatch]? = match prebuilt {
      Some(scans) =>
        if k >= 1 && k - 1 < scans.length() {
          Some(scans[k - 1])
        } else {
          None
        }
      None => None
    }
    match handed {
      Some(batches) => {
        narrowed.push(batches)
        prescanned.push(true)
        let mut rows = 0
        for bt in batches {
          rows += bt.row_count()
        }
        stats.push(("scan \{schemas[k].table}", rows.to_int64()))
        continue
      }
      None => ()
    }
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
        // the sort takes a source, not an array: here the array is what the
        // join/aggregate above already produced, so the producer is a cursor
        // over it (a single-table ORDER BY never gets this far — E4b feeds it
        // from the scan instead)
        let pre_types : Array[@types.DataType] = []
        for col in kept[0].columns() {
          pre_types.push(col.dtype())
        }
        let mut at = 0
        let produced : () -> @types.DataBatch? raise @types.SqlError = fn() {
          if at < kept.length() {
            let b = kept[at]
            at += 1
            Some(b)
          } else {
            None
          }
        }
        let batch = external_sort_project(
          produced,
          pre_types,
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
  // SELECT without FROM drives the same zero-column one-row dummy table the
  // executor uses; without a FROM item the bound plan carries no step at all
  // and rendering it indexes past the empty step list
  if sel.from.length() == 0 {
    sel.from.push({
      table: Named("__one"),
      tbl_alias: None,
      col_aliases: None,
      join: Inner,
      on: None,
    })
  }
  let schemas : Array[@catalog.TableSchema] = []
  for item in sel.from {
    match item.table {
      Named(name) =>
        if name == "__one" {
          schemas.push({ table: name, columns: [], })
        } else {
          match catalog.lookup(name) {
            Some(entry) => schemas.push(entry.schema)
            None => raise @types.SqlError::Bind("unknown table \"\{name}\"")
          }
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
/// distinct from both finite numbers and SQL NULL. Two output columns can
/// share a label (`SELECT a, b AS a`): object keys must be unique, so repeats
/// get a `_1` suffix (a CSV header's rename) instead of a key that silently
/// overwrites its neighbour in a JSON parser.
pub fn SelectResult::to_json(self : SelectResult) -> String {
  let writer = JsonRow::new(self.names())
  let sb = StringBuilder()
  sb.write_char('[')
  for r in 0..<self.row_count() {
    if r > 0 {
      sb.write_char(',')
    }
    write_json_row(sb, writer.keys, self.batch, r)
  }
  sb.write_char(']')
  sb.to_string()
}

///|
/// A result row as a JSON object, in the layout `to_json` prints. The caller
/// supplies the surrounding `[`, the commas between batches and the `]`, so a
/// result can be written as its batches arrive instead of being collected
/// first. Keys are made unique exactly as `to_json` makes them.
pub struct JsonRow {
  priv keys : Array[String]
}

///|
pub fn JsonRow::new(names : Array[String]) -> JsonRow {
  { keys: unique_keys(names), }
}

///|
/// One row as JSON: `{"a":1,"b":null}`.
pub fn JsonRow::render(
  self : JsonRow,
  batch : @types.DataBatch,
  row : Int32,
) -> String {
  let sb = StringBuilder()
  write_json_row(sb, self.keys, batch, row)
  sb.to_string()
}

///|
/// The rows of `batch` as comma-separated JSON objects, without brackets: a
/// writer that prints `[`, each batch of the stream in turn, and `]` prints
/// exactly what `to_json` prints for the whole result.
pub fn JsonRow::batch(self : JsonRow, batch : @types.DataBatch) -> String {
  let sb = StringBuilder()
  for r in 0..<batch.row_count() {
    if r > 0 {
      sb.write_char(',')
    }
    write_json_row(sb, self.keys, batch, r)
  }
  sb.to_string()
}

///|
/// Append one row's JSON object. `keys` is the unique key list, so the caller
/// computes it once per result rather than per row.
fn write_json_row(
  sb : StringBuilder,
  keys : Array[String],
  batch : @types.DataBatch,
  row : Int32,
) -> Unit {
  sb.write_char('{')
  for c in 0..<keys.length() {
    if c > 0 {
      sb.write_char(',')
    }
    sb.write_char('"')
    sb.write_string(json_escape(keys[c]))
    sb.write_string("\":")
    match batch.columns()[c].get(row) {
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

///|
/// JSON object keys: the result's column names, with a repeated label made
/// unique the way a CSV header is (`a`, `a_1`, `a_2`, skipping names that are
/// already in use).
fn unique_keys(names : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for name in names {
    let mut candidate = name
    let mut n = 0
    while out.contains(candidate) {
      n += 1
      candidate = "\{name}_\{n}"
    }
    out.push(candidate)
  }
  out
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
