// Binder: resolve column names against the table schema, type-check
// expressions, insert numeric promotions, and fold BETWEEN into a
// conjunction of comparisons. Output feeds the evaluator directly.

///|
pub(all) enum PhysExpr {
  ColRef(Int, @types.DataType)
  Const(@types.Scalar)
  Promote(PhysExpr, @types.DataType)
  ArithE(@types.ArithOp, PhysExpr, PhysExpr, @types.DataType)
  CmpE(@types.CmpOp, PhysExpr, PhysExpr)
  AndE(PhysExpr, PhysExpr)
  OrE(PhysExpr, PhysExpr)
  NotE(PhysExpr)
} derive(Debug)

///|
pub extend PhysExpr with @debug.Debug::{to_repr}

///|
/// One aggregate to compute. v1 supports SUM over int32 (into int64),
/// int64 and float64.
priv struct AggSpec {
  input : PhysExpr
  out_type : @types.DataType
  name : String
} derive(Debug)

///|
/// The bound query: optional filter plus the aggregate list with output
/// naming. W1 has no GROUP BY, so the result is a single row.
pub struct BoundQuery {
  priv aggs : Array[AggSpec]
  priv filter : PhysExpr?
  priv names : Array[String]
  priv out_types : Array[@types.DataType]
} derive(Debug)

///|
pub extend BoundQuery with @debug.Debug::{to_repr}

///|
pub fn bind_select(
  sel : Select,
  schema : @catalog.TableSchema,
) -> BoundQuery raise @types.SqlError {
  let filter : PhysExpr? = match sel.filter {
    Some(f) =>
      match bind_expr(f, schema, false) {
        (pe, @types.Bool) => Some(pe)
        (_, other) =>
          raise @types.SqlError::Bind(
            "WHERE must evaluate to bool, got \{other.to_string()}",
          )
      }
    None => None
  }
  let aggs : Array[AggSpec] = []
  let names : Array[String] = []
  let out_types : Array[@types.DataType] = []
  for i, item in sel.items {
    let dt = match item.expr {
      Agg(fn_, inner) => bind_agg(fn_, inner, schema, aggs)
      _ =>
        // v1: no GROUP BY, so a bare column in SELECT cannot be answered
        raise @types.SqlError::Bind(
          "select item \{i + 1} must be an aggregate (GROUP BY is not supported yet)",
        )
    }
    names.push(
      match item.label {
        Some(a) => a
        None => default_name("sum", i)
      },
    )
    out_types.push(dt)
  }
  if aggs.length() == 0 {
    raise @types.SqlError::Bind(
      "query has no aggregate select items (v1 subset)",
    )
  }
  { aggs, filter, names, out_types, }
}

///|
fn default_name(fn_name : String, index : Int) -> String {
  if index == 0 {
    fn_name
  } else {
    "\{fn_name}_\{index + 1}"
  }
}

///|
fn bind_agg(
  fn_ : AggFn,
  inner : LExpr,
  schema : @catalog.TableSchema,
  aggs : Array[AggSpec],
) -> @types.DataType raise @types.SqlError {
  let (pe, dt) = bind_expr(inner, schema, false) // no nested aggregates
  let out_type = match (fn_, dt) {
    (Sum, @types.Int32) => @types.DataType::Int64
    (Sum, @types.Int64) => @types.DataType::Int64
    (Sum, @types.Float64) => @types.DataType::Float64
    (Sum, other) =>
      raise @types.SqlError::Bind(
        "SUM does not support input type \{other.to_string()}",
      )
  }
  aggs.push({ input: pe, out_type, name: "", })
  out_type
}

///|
/// Bind a logical expression to a physical one; returns the physical
/// expression and its result type. `allow_agg` must be false: aggregates
/// may only appear as top-level select items (v1).
fn bind_expr(
  e : LExpr,
  schema : @catalog.TableSchema,
  allow_agg : Bool,
) -> (PhysExpr, @types.DataType) raise @types.SqlError {
  match e {
    Col(name) =>
      match schema.index_of(name) {
        Some(i) => {
          let dt = schema.columns[i].dtype
          (ColRef(i, dt), dt)
        }
        None =>
          raise @types.SqlError::Bind(
            "unknown column \"\{name}\" in table \"\{schema.table}\"",
          )
      }
    Lit(s) =>
      match s {
        @types.Null =>
          raise @types.SqlError::Bind("untyped NULL is not supported yet")
        other => {
          let dt = scalar_type(other)
          (Const(other), dt)
        }
      }
    Agg(_, _) =>
      raise @types.SqlError::Bind("aggregate is only allowed as a select item")
    Arith(op, l, r) => {
      let (lpe, ldt) = bind_expr(l, schema, allow_agg)
      let (rpe, rdt) = bind_expr(r, schema, allow_agg)
      match unify(ldt, rdt) {
        Some(dt) =>
          match dt {
            @types.Bool =>
              raise @types.SqlError::Bind("bool operand in arithmetic")
            _ => {
              let lp = promote_to(lpe, ldt, dt)
              let rp = promote_to(rpe, rdt, dt)
              (ArithE(op, lp, rp, dt), dt)
            }
          }
        None =>
          raise @types.SqlError::Bind(
            "type mismatch in arithmetic: \{ldt.to_string()} vs \{rdt.to_string()}",
          )
      }
    }
    Cmp(op, l, r) => {
      let (lpe, ldt) = bind_expr(l, schema, allow_agg)
      let (rpe, rdt) = bind_expr(r, schema, allow_agg)
      match unify(ldt, rdt) {
        Some(dt) => {
          let lp = promote_to(lpe, ldt, dt)
          let rp = promote_to(rpe, rdt, dt)
          (CmpE(op, lp, rp), @types.Bool)
        }
        None =>
          raise @types.SqlError::Bind(
            "type mismatch in comparison: \{ldt.to_string()} vs \{rdt.to_string()}",
          )
      }
    }
    And(l, r) => {
      let (lpe, ldt) = bind_expr(l, schema, allow_agg)
      let (rpe, rdt) = bind_expr(r, schema, allow_agg)
      expect_bool(lpe, ldt, "AND")
      expect_bool(rpe, rdt, "AND")
      (AndE(lpe, rpe), @types.Bool)
    }
    Or(l, r) => {
      let (lpe, ldt) = bind_expr(l, schema, allow_agg)
      let (rpe, rdt) = bind_expr(r, schema, allow_agg)
      expect_bool(lpe, ldt, "OR")
      expect_bool(rpe, rdt, "OR")
      (OrE(lpe, rpe), @types.Bool)
    }
    Not(inner) => {
      let (pe, dt) = bind_expr(inner, schema, allow_agg)
      expect_bool(pe, dt, "NOT")
      (NotE(pe), @types.Bool)
    }
    Between(v, low, high) => {
      // desugar: v >= low AND v <= high
      let conj = And(Cmp(@types.Ge, v, low), Cmp(@types.Le, v, high))
      bind_expr(conj, schema, allow_agg)
    }
  }
}

///|
fn expect_bool(
  _pe : PhysExpr,
  dt : @types.DataType,
  context : String,
) -> Unit raise @types.SqlError {
  if dt != @types.Bool {
    raise @types.SqlError::Bind(
      "\{context} requires bool operands, got \{dt.to_string()}",
    )
  }
}

///|
fn scalar_type(s : @types.Scalar) -> @types.DataType {
  match s {
    @types.Null => @types.DataType::Str // unreachable: NULL literal is rejected first
    @types.Boolean(_) => @types.Bool
    @types.Int32(_) => @types.Int32
    @types.Int64(_) => @types.Int64
    @types.Float64(_) => @types.Float64
    @types.Str(_) => @types.Str
    @types.Date(_) => @types.Date
  }
}

///|
/// Numeric type unification: same type wins, int32 widens to int64 then
/// to float64. Non-numeric mixes (and bool) do not unify, except equal
/// date/string/bool pairs which return themselves for comparison.
fn unify(l : @types.DataType, r : @types.DataType) -> @types.DataType? {
  if l == r {
    return Some(l)
  }
  match (l, r) {
    (@types.Int32, @types.Int64) | (@types.Int64, @types.Int32) =>
      Some(@types.Int64)
    (@types.Int32, @types.Float64) | (@types.Float64, @types.Int32) =>
      Some(@types.Float64)
    (@types.Int64, @types.Float64) | (@types.Float64, @types.Int64) =>
      Some(@types.Float64)
    _ => None
  }
}

///|
/// Wrap an expression in a Promote node when its type differs from the
/// unified target (numeric widening only).
fn promote_to(
  pe : PhysExpr,
  from : @types.DataType,
  to : @types.DataType,
) -> PhysExpr {
  if from == to {
    pe
  } else {
    Promote(pe, to)
  }
}
