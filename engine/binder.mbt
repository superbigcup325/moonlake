// Binder: resolve column names against the table schema, type-check
// expressions, insert numeric promotions, and lower sugar (BETWEEN, IN).
// Aggregation splits expressions into two spaces: inputs (over the
// scanned batch) and outputs (over the post-aggregation row, laid out as
// group keys first, then aggregate results). Select items, HAVING and
// ORDER BY bind in the output space.

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
  LikeE(PhysExpr, String) // pattern folded at bind time
  CaseE(Array[(PhysExpr, PhysExpr)], PhysExpr?, @types.DataType)
} derive(Debug)

///|
pub extend PhysExpr with @debug.Debug::{to_repr}

///|
priv enum AggKind {
  Sum
  Avg
  Count
  CountStar
  CountDistinct
  Min
  Max
} derive(Debug)

///|
priv struct AggSpec {
  kind : AggKind
  input : PhysExpr? // None only for CountStar
  out_type : @types.DataType
} derive(Debug)

///|
/// The bound query. Post-agg layout: group keys occupy columns
/// 0..group_count-1, aggregate outputs group_count..end.
pub struct BoundQuery {
  priv filter : PhysExpr?
  priv group_exprs : Array[PhysExpr]
  priv group_types : Array[@types.DataType]
  priv aggs : Array[AggSpec]
  priv having : PhysExpr? // over post-agg layout
  priv out_exprs : Array[PhysExpr] // over post-agg layout
  priv names : Array[String]
  priv out_types : Array[@types.DataType]
  priv order_keys : Array[(Int, Bool)] // output column index, desc
  priv limit : Int?
} derive(Debug)

///|
pub extend BoundQuery with @debug.Debug::{to_repr}

///|
priv struct Binder {
  schema : @catalog.TableSchema
  group_l : Array[LExpr] // GROUP BY exprs as written, for structural match
  group_types : Array[@types.DataType]
  aggs : Array[AggSpec]
  agg_keys : Array[(AggFn, LExpr?)] // written shape of each spec, for dedup
}

///|
priv enum Space {
  Input
  AggOut
}

///|
pub fn bind_select(
  sel : Select,
  schema : @catalog.TableSchema,
) -> BoundQuery raise @types.SqlError {
  let b : Binder = {
    schema,
    group_l: sel.group_by,
    group_types: [],
    aggs: [],
    agg_keys: [],
  }
  let filter : PhysExpr? = match sel.filter {
    Some(f) =>
      match b.bind(f, Input) {
        (pe, @types.Bool) => Some(pe)
        (_, other) =>
          raise @types.SqlError::Bind(
            "WHERE must evaluate to bool, got \{other.to_string()}",
          )
      }
    None => None
  }
  let group_exprs : Array[PhysExpr] = []
  for g in sel.group_by {
    let (pe, dt) = b.bind(g, Input)
    group_exprs.push(pe)
    b.group_types.push(dt)
  }
  let out_exprs : Array[PhysExpr] = []
  let names : Array[String] = []
  let out_types : Array[@types.DataType] = []
  for i, item in sel.items {
    let (pe, dt) = b.bind(item.expr, AggOut)
    out_exprs.push(pe)
    names.push(
      match item.label {
        Some(a) => a
        None => default_name(item.expr, i)
      },
    )
    out_types.push(dt)
  }
  let having : PhysExpr? = match sel.having {
    Some(h) =>
      match b.bind(h, AggOut) {
        (pe, @types.Bool) => Some(pe)
        (_, other) =>
          raise @types.SqlError::Bind(
            "HAVING must evaluate to bool, got \{other.to_string()}",
          )
      }
    None => None
  }
  let order_keys : Array[(Int, Bool)] = []
  for item in sel.order_by {
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
      _ => None
    }
    match idx {
      Some(i) => order_keys.push((i, item.desc))
      None =>
        raise @types.SqlError::Bind(
          "ORDER BY must reference an output column (v1 subset)",
        )
    }
  }
  if b.aggs.length() == 0 && sel.group_by.length() == 0 {
    raise @types.SqlError::Bind(
      "query has no aggregate or GROUP BY (v1 subset)",
    )
  }
  {
    filter,
    group_exprs,
    group_types: b.group_types,
    aggs: b.aggs,
    having,
    out_exprs,
    names,
    out_types,
    order_keys,
    limit: sel.limit,
  }
}

///|
fn default_name(expr : LExpr, index : Int) -> String {
  match expr {
    Col(name) => name
    Agg(fn_, _) => {
      let label = match fn_ {
        Sum => "sum"
        Avg => "avg"
        Count | CountStar | CountDistinct => "count"
        Min => "min"
        Max => "max"
      }
      if index == 0 {
        label
      } else {
        "\{label}_\{index + 1}"
      }
    }
    _ => "col_\{index + 1}"
  }
}

///|
/// Bind an aggregate reference in the output space: reuse an existing
/// spec with the same written shape or create one.
fn Binder::agg_ref(
  self : Binder,
  fn_ : AggFn,
  inner : LExpr?,
) -> (PhysExpr, @types.DataType) raise @types.SqlError {
  for k, key in self.agg_keys {
    let same_inner = match (key.1, inner) {
      (None, None) => true
      (Some(a), Some(c)) => LExpr::equal(a, c)
      _ => false
    }
    if key.0 == fn_ && same_inner {
      let dt = self.aggs[k].out_type
      let col = self.group_types.length() + k
      return (ColRef(col, dt), dt)
    }
  }
  let spec = self.bind_agg(fn_, inner)
  self.aggs.push(spec)
  self.agg_keys.push((fn_, inner))
  let col = self.group_types.length() + self.aggs.length() - 1
  (ColRef(col, spec.out_type), spec.out_type)
}

///|
fn Binder::bind_agg(
  self : Binder,
  fn_ : AggFn,
  inner : LExpr?,
) -> AggSpec raise @types.SqlError {
  if fn_ is CountStar {
    return { kind: CountStar, input: None, out_type: @types.Int64, }
  }
  let lexpr = match inner {
    Some(e) => e
    None =>
      raise @types.SqlError::Bind("aggregate requires an input expression")
  }
  let (pe, dt) = self.bind(lexpr, Input) // no nested aggregates
  let out_type = match fn_ {
    Sum =>
      match dt {
        @types.Int32 | @types.Int64 => @types.DataType::Int64
        @types.Float64 => @types.DataType::Float64
        other =>
          raise @types.SqlError::Bind(
            "SUM does not support input type \{other.to_string()}",
          )
      }
    Avg =>
      match dt {
        @types.Int32 | @types.Int64 | @types.Float64 => @types.DataType::Float64
        other =>
          raise @types.SqlError::Bind(
            "AVG does not support input type \{other.to_string()}",
          )
      }
    Count | CountDistinct => @types.DataType::Int64
    Min | Max =>
      match dt {
        @types.Bool =>
          raise @types.SqlError::Bind(
            "MIN/MAX does not support input type bool",
          )
        other => other
      }
    CountStar => @types.DataType::Int64 // unreachable: handled above
  }
  let kind : AggKind = match fn_ {
    Sum => Sum
    Avg => Avg
    Count => Count
    CountStar => CountStar
    CountDistinct => CountDistinct
    Min => Min
    Max => Max
  }
  { kind, input: Some(pe), out_type, }
}

///|
/// Bind a logical expression. In the Input space columns resolve against
/// the table schema and aggregates are rejected; in the AggOut space
/// expressions must be built from GROUP BY keys and aggregates.
fn Binder::bind(
  self : Binder,
  e : LExpr,
  space : Space,
) -> (PhysExpr, @types.DataType) raise @types.SqlError {
  if space is AggOut {
    for i, g in self.group_l {
      if LExpr::equal(e, g) {
        let dt = self.group_types[i]
        return (ColRef(i, dt), dt)
      }
    }
  }
  match e {
    Col(name) =>
      match space {
        Input =>
          match self.schema.index_of(name) {
            Some(i) => {
              let dt = self.schema.columns[i].dtype
              (ColRef(i, dt), dt)
            }
            None =>
              raise @types.SqlError::Bind(
                "unknown column \"\{name}\" in table \"\{self.schema.table}\"",
              )
          }
        AggOut =>
          raise @types.SqlError::Bind(
            "column \"\{name}\" must appear in GROUP BY or inside an aggregate",
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
    Agg(fn_, inner) =>
      match space {
        Input =>
          raise @types.SqlError::Bind(
            "aggregate is only allowed in SELECT, HAVING or ORDER BY",
          )
        AggOut => self.agg_ref(fn_, inner)
      }
    Arith(op, l, r) => {
      let (lpe, ldt) = self.bind(l, space)
      let (rpe, rdt) = self.bind(r, space)
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
      let (lpe, ldt) = self.bind(l, space)
      let (rpe, rdt) = self.bind(r, space)
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
      let (lpe, ldt) = self.bind(l, space)
      let (rpe, rdt) = self.bind(r, space)
      expect_bool(lpe, ldt, "AND")
      expect_bool(rpe, rdt, "AND")
      (AndE(lpe, rpe), @types.Bool)
    }
    Or(l, r) => {
      let (lpe, ldt) = self.bind(l, space)
      let (rpe, rdt) = self.bind(r, space)
      expect_bool(lpe, ldt, "OR")
      expect_bool(rpe, rdt, "OR")
      (OrE(lpe, rpe), @types.Bool)
    }
    Not(inner) => {
      let (pe, dt) = self.bind(inner, space)
      expect_bool(pe, dt, "NOT")
      (NotE(pe), @types.Bool)
    }
    Between(v, low, high) => {
      // desugar: v >= low AND v <= high
      let conj = And(Cmp(@types.Ge, v, low), Cmp(@types.Le, v, high))
      self.bind(conj, space)
    }
    In(v, items) => {
      // desugar: v = item1 OR v = item2 ... (empty list: FALSE)
      let mut acc : LExpr = Lit(@types.Boolean(false))
      for item in items {
        acc = Or(Cmp(@types.Eq, v, item), acc)
      }
      self.bind(acc, space)
    }
    Like(v, pat) => {
      let (vpe, vdt) = self.bind(v, space)
      if vdt != @types.Str {
        raise @types.SqlError::Bind(
          "LIKE requires a string value, got \{vdt.to_string()}",
        )
      }
      let pattern : String = match pat {
        Lit(@types.Str(s)) => s
        _ =>
          raise @types.SqlError::Bind(
            "LIKE pattern must be a string literal (v1 subset)",
          )
      }
      (LikeE(vpe, pattern), @types.Bool)
    }
    Case(whens, else_) => {
      let bound : Array[(PhysExpr, @types.DataType)] = []
      let conds : Array[PhysExpr] = []
      let mut dt : @types.DataType? = None
      for when in whens {
        let (cond, cond_dt) = self.bind(when.0, space)
        expect_bool(cond, cond_dt, "CASE WHEN")
        let (res, res_dt) = self.bind(when.1, space)
        match dt {
          None => dt = Some(res_dt)
          Some(prev) =>
            dt = match unify(prev, res_dt) {
              Some(u) => Some(u)
              None =>
                raise @types.SqlError::Bind(
                  "CASE branches disagree: \{prev.to_string()} vs \{res_dt.to_string()}",
                )
            }
        }
        conds.push(cond)
        bound.push((res, res_dt))
      }
      if bound.length() == 0 {
        raise @types.SqlError::Bind("CASE requires a WHEN branch")
      }
      let out_dt = match dt {
        Some(d) => d
        None => raise @types.SqlError::Bind("CASE requires a WHEN branch")
      }
      let bound_else : (PhysExpr, @types.DataType)? = match else_ {
        Some(e) => {
          let (epe, edt) = self.bind(e, space)
          Some((epe, edt))
        }
        None => None
      }
      let out_dt = match bound_else {
        Some((_, edt)) =>
          match unify(out_dt, edt) {
            Some(u) => u
            None =>
              raise @types.SqlError::Bind(
                "CASE ELSE disagrees with branches: \{out_dt.to_string()} vs \{edt.to_string()}",
              )
          }
        None => out_dt
      }
      let whens_p : Array[(PhysExpr, PhysExpr)] = []
      for i in 0..<bound.length() {
        whens_p.push((conds[i], promote_to(bound[i].0, bound[i].1, out_dt)))
      }
      let else_p : PhysExpr? = match bound_else {
        Some((epe, edt)) => Some(promote_to(epe, edt, out_dt))
        None => None
      }
      (CaseE(whens_p, else_p, out_dt), out_dt)
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
