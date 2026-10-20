// Scan pushdown: the pruned plan is turned into one ScanRequest per FROM
// table, and a lazy entry is materialized through it. Two things travel to
// the source:
//
// - the projection (`table_cols[t]`), which is not advisory: the source
//   decodes only those columns and the pipeline expects exactly that layout;
// - predicate hints from the table's *build filter* only. That expression is
//   one the engine applies to this table's rows before any join (exec_joins
//   runs `filter_batches(right, step.build_filter)`), so a source may skip
//   rows that cannot satisfy it. Flat-space conjuncts (probe filters,
//   residuals, the deferred WHERE) are deliberately not hints: at an outer
//   join a residual ON condition can leave a row visible as an unmatched
//   side, so it does not filter that table's rows.

///|
/// Map a narrowed local column index back to the table's own column.
fn original_column(cols : Array[Int32], idx : Int32) -> Int32? {
  if idx < 0 || idx >= cols.length() {
    None
  } else {
    Some(cols[idx])
  }
}

///|
/// The projection and hints for FROM table `t`.
fn scan_request_of(
  bq : BoundQuery,
  table_cols : Array[Int32],
  t : Int32,
) -> @catalog.ScanRequest {
  let hints : Array[@catalog.ScanPredicate] = []
  for step in bq.steps {
    if step.table == t {
      match step.build_filter {
        Some(f) => collect_scan_hints(f, table_cols, hints)
        None => ()
      }
    }
  }
  @catalog.ScanRequest::new(table_cols, hints)
}

///|
/// The expression the engine applies to this table's rows before joining it.
/// A lazy scan applies it per batch instead, so rows never accumulate.
fn scan_filter_of(bq : BoundQuery, t : Int32) -> PhysExpr? {
  for step in bq.steps {
    if step.table == t {
      return step.build_filter
    }
  }
  None
}

///|
/// Split a conjunction into `column op constant` hints, dropped when the
/// constant is not a literal this layer can vouch for.
fn collect_scan_hints(
  e : PhysExpr,
  cols : Array[Int32],
  out : Array[@catalog.ScanPredicate],
) -> Unit {
  match e {
    AndE(l, r) => {
      collect_scan_hints(l, cols, out)
      collect_scan_hints(r, cols, out)
    }
    CmpE(op, l, r) =>
      match hint_of(op, l, r) {
        Some((idx, cmp, v)) =>
          match original_column(cols, idx) {
            Some(column) => out.push({ column, op: cmp, value: v, })
            None => ()
          }
        None =>
          // `5 > col` is the same comparison with the operator flipped
          match hint_of(op.flip(), r, l) {
            Some((idx, cmp, v)) =>
              match original_column(cols, idx) {
                Some(column) => out.push({ column, op: cmp, value: v, })
                None => ()
              }
            None => ()
          }
      }
    _ => ()
  }
}

///|
/// (local column, operator, constant) when the pair is a column compared to
/// a constant in that order.
fn hint_of(
  op : @types.CmpOp,
  col : PhysExpr,
  c : PhysExpr,
) -> (Int32, @types.CmpOp, @types.Scalar)? {
  match col {
    ColRef(i, _) =>
      match hint_constant(c) {
        Some(v) => Some((i, op, v))
        None => None
      }
    _ => None
  }
}

///|
/// The literal a comparison is against, including a widened literal
/// (`Promote` wraps an int32 constant compared to an int64 column).
fn hint_constant(e : PhysExpr) -> @types.Scalar? {
  match e {
    Const(v) => Some(v)
    Promote(inner, dt) =>
      match hint_constant(inner) {
        Some(v) => promote_hint(v, dt)
        None => None
      }
    _ => None
  }
}

///|
/// Widen a literal the same way the evaluator does, and only when the wider
/// value is exact: a lossy widening would make a bound comparison unsound.
fn promote_hint(v : @types.Scalar, dt : @types.DataType) -> @types.Scalar? {
  match (v, dt) {
    (Int32(x), Int64) => Some(Int64(x.to_int64()))
    (Int32(x), Float64) => Some(Float64(x.to_double()))
    (Int64(x), Float64) =>
      if x <= 9007199254740992L && x >= -9007199254740992L {
        Some(Float64(x.to_double()))
      } else {
        None
      }
    _ => None
  }
}

///|
/// Drain a lazy table through its source, applying the table's build filter
/// to each batch as it arrives. Filtered-away rows are never accumulated, so
/// a selective scan costs the selected rows, not the table.
fn materialize_scan(
  entry : @catalog.TableEntry,
  request : @catalog.ScanRequest,
  pred : PhysExpr?,
) -> Array[@types.DataBatch] raise @types.SqlError {
  match entry.source {
    None =>
      raise @types.SqlError::Execute(
        "internal: lazy scan requested for a materialized table",
      )
    Some(src) => {
      let stream = src.open(request)
      let out : Array[@types.DataBatch] = []
      while stream.next() is Some(batch) {
        match pred {
          None => out.push(batch)
          Some(p) => {
            let kept = compact(batch, eval_mask(p, batch))
            if kept.row_count() > 0 {
              out.push(kept)
            }
          }
        }
      }
      out
    }
  }
}

///|
/// Operator text as SQL writes it.
fn cmp_op_text(op : @types.CmpOp) -> String {
  match op {
    Eq => "="
    Neq => "<>"
    Lt => "<"
    Le => "<="
    Gt => ">"
    Ge => ">="
  }
}

///|
/// The EXPLAIN lines belonging to one table's scan: the predicates pushed
/// down and, for sources that can plan without reading rows, what the plan
/// will actually read.
fn scan_pushdown_text(
  catalog : @catalog.Catalog,
  schemas : Array[@catalog.TableSchema],
  plan : PrunePlan,
  bq : BoundQuery,
  t : Int32,
) -> String raise @types.SqlError {
  let request = scan_request_of(bq, plan.table_cols[t], t)
  let sb = StringBuilder()
  if request.predicates.length() > 0 {
    sb.write_string("\n  pushed:")
    for i, p in request.predicates {
      if i > 0 {
        sb.write_string(",")
      }
      sb.write_string(" ")
      sb.write_string(schemas[t].columns[p.column].name)
      sb.write_string(" ")
      sb.write_string(cmp_op_text(p.op))
      sb.write_string(" ")
      sb.write_string(p.value.to_string())
    }
  }
  match catalog.lookup(schemas[t].table) {
    Some(entry) =>
      if entry.is_lazy() {
        let info = entry.plan(request)
        if info.files > 1 {
          sb.write_string("\n  files: \{info.files}")
        }
        if info.row_groups > 0 {
          sb.write_string("\n  row groups: ")
          sb.write_string(
            (info.row_groups - info.row_groups_skipped).to_string(),
          )
          sb.write_string(" of \{info.row_groups} read")
          if info.row_groups_skipped > 0 {
            sb.write_string(
              " (\{info.row_groups_skipped} skipped by statistics)",
            )
          }
        }
      }
    None => ()
  }
  sb.to_string()
}
