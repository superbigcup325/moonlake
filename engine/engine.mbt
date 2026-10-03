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
  run_parsed(sel, catalog)
}

///|
/// Execute a parsed select. FROM items resolve to schemas and batches —
/// base tables come from the catalog, derived tables recurse and
/// materialize (everything in the engine is eager, so this is direct).
fn run_parsed(
  sel : Select,
  catalog : @catalog.Catalog,
) -> SelectResult raise @types.SqlError {
  let schemas : Array[@catalog.TableSchema] = []
  let tables : Array[Array[@types.DataBatch]] = []
  for item in sel.from {
    match item.table {
      Named(name) =>
        match catalog.lookup(name) {
          Some(entry) => {
            schemas.push(entry.schema)
            tables.push(entry.batches)
          }
          None => raise @types.SqlError::Bind("unknown table \"\{name}\"")
        }
      Sub(inner) => {
        let r = run_parsed(inner, catalog)
        let names = r.names()
        let types = r.types()
        let columns : Array[@catalog.Column] = []
        for i, name in names {
          for j in 0..<i {
            if names[j] == name {
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
  }
  let joined = exec_joins(narrowed, bq.steps, bq.deferred)
  let kept : Array[@types.DataBatch] = if bq.aggregate {
    let grouped = aggregate(joined, bq.group_exprs, bq.group_types, bq.aggs)
    [
      match bq.having {
        Some(h) => compact(grouped, eval_mask(h, grouped))
        None => grouped
      },
    ]
  } else {
    joined
  }
  // expression ORDER BY sorts the pre-projection row (Flat for plain
  // queries, AggOut once aggregates are in play); output-column ORDER BY
  // keeps the post-projection path
  let pre = concat_batches(kept, bq.steps[bq.steps.length() - 1].out_dtypes)
  let pre = if bq.order_exprs.length() > 0 {
    sort_exprs(pre, bq.order_exprs, None, None)
  } else {
    pre
  }
  let projected = project(pre, bq.out_exprs, bq.out_types)
  let projected = if bq.distinct { dedupe_rows(projected) } else { projected }
  let batch = if bq.order_exprs.length() > 0 {
    // already sorted; only the window is left to apply
    sort_exprs(projected, [], bq.offset, bq.limit)
  } else {
    order_limit(projected, bq.order_keys, bq.limit, bq.offset)
  }
  { names: bq.names, types: bq.out_types, batch, }
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
  sb.write_string("\nproject: ")
  for i, name in bq.names {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(name)
    sb.write_string(":")
    sb.write_string(bq.out_types[i].to_string())
  }
  if bq.order_keys.length() > 0 {
    sb.write_string("\norder by")
    for kv in bq.order_keys {
      sb.write_string(" ")
      sb.write_string(bq.names[kv.0])
      sb.write_string(if kv.1 { " desc" } else { " asc" })
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
