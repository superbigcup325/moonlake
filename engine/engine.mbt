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
  let bq = bind_select(sel, schemas, runner)
  let joined = exec_joins(tables, bq.steps, bq.deferred)
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
  let projected = project(concat_batches(kept), bq.out_exprs, bq.out_types)
  let batch = order_limit(projected, bq.order_keys, bq.limit)
  { names: bq.names, types: bq.out_types, batch, }
}
