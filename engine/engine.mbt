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
  let entry = match catalog.lookup(sel.table) {
    Some(entry) => entry
    None => raise @types.SqlError::Bind("unknown table \"\{sel.table}\"")
  }
  let bq = bind_select(sel, entry.schema)
  let filtered = filter_batches(entry.batches, bq.filter)
  let grouped = aggregate(filtered, bq.group_exprs, bq.group_types, bq.aggs)
  let kept = match bq.having {
    Some(h) => compact(grouped, eval_mask(h, grouped))
    None => grouped
  }
  let projected = project(kept, bq.out_exprs, bq.out_types)
  let batch = order_limit(projected, bq.order_keys, bq.limit)
  { names: bq.names, types: bq.out_types, batch, }
}
