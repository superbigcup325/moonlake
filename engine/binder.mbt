// Binder: resolve column names against the FROM tables, type-check
// expressions, insert numeric promotions, and lower sugar (BETWEEN, IN).
// Three binding spaces:
//   Flat    - over the joined row: all FROM tables concatenated in FROM
//             order (WHERE, GROUP BY, aggregate inputs)
//   Slot k - over table k's own columns (build-side filters, right
//             join keys)
//   AggOut  - over the post-aggregation row: group keys first, then
//             aggregate results (SELECT items, HAVING, ORDER BY)
// The join plan is a left-deep chain in FROM order (reordering is out of
// v1 scope). Conjuncts from WHERE and ON are classified per step:
// single-table ones become build/probe filters, equalities spanning the
// accumulated row and the new table become hash keys, everything else
// spanning both sides is a per-pair residual.

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
/// One hash-join step: table `table` joins the accumulated row. keys_l
/// are Flat refs, keys_r Slot refs into the joining table; both are
/// promoted to a common type so canonical keys match.
priv struct JoinStep {
  table : Int
  kind : JoinKind
  keys_l : Array[PhysExpr]
  keys_r : Array[PhysExpr]
  build_filter : PhysExpr? // Slot refs, applied to the joining table
  probe_filter : PhysExpr? // Flat refs, applied to accumulated rows
  residual : PhysExpr? // Flat refs, applied per candidate pair
  right_offset : Int // flat offset of the joining table's first column
  right_width : Int // column count of the joining table
  out_dtypes : Array[@types.DataType] // combined row layout after the step
} derive(Debug)

///|
/// The bound query, ready for the executor.
pub struct BoundQuery {
  priv steps : Array[JoinStep]
  priv deferred : PhysExpr? // Flat refs applied after all joins
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
  slots : Array[@catalog.TableSchema] // FROM order
  offsets : Array[Int] // flat offset of each table's first column
  group_l : Array[LExpr] // GROUP BY exprs as written, for structural match
  group_types : Array[@types.DataType]
  aggs : Array[AggSpec]
  agg_keys : Array[(AggFn, LExpr?)] // written shape of each spec, for dedup
}

///|
priv enum Space {
  Flat
  Slot(Int)
  AggOut
}

///|
priv struct Conjunct {
  lexpr : LExpr
  origin : Int? // Some(item index) for ON conjuncts, None for WHERE
}

///|
pub fn bind_select(
  sel : Select,
  schemas : Array[@catalog.TableSchema],
) -> BoundQuery raise @types.SqlError {
  if schemas.length() > 30 {
    raise @types.SqlError::Bind("too many tables in FROM (max 30)")
  }
  let offsets : Array[Int] = []
  let mut off = 0
  for s in schemas {
    offsets.push(off)
    off += s.columns.length()
  }
  let b : Binder = {
    slots: schemas,
    offsets,
    group_l: sel.group_by,
    group_types: [],
    aggs: [],
    agg_keys: [],
  }
  let (steps, deferred) = b.plan_joins(sel)
  let group_exprs : Array[PhysExpr] = []
  for g in sel.group_by {
    let (pe, dt) = b.bind(g, Flat)
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
    steps,
    deferred,
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
/// Resolve a column name to its table slot; ambiguity and unknown names
/// are bind errors (TPC-H tables use globally unique column names).
fn Binder::lookup_slot(
  self : Binder,
  name : String,
) -> Int raise @types.SqlError {
  let mut hit : Int? = None
  let mut dup = false
  for k, s in self.slots {
    if s.index_of(name) is Some(_) {
      match hit {
        Some(_) => dup = true
        None => hit = Some(k)
      }
    }
  }
  match (hit, dup) {
    (Some(k), false) => k
    (_, true) =>
      raise @types.SqlError::Bind("ambiguous column \"\{name}\" in FROM")
    (None, _) =>
      raise @types.SqlError::Bind("unknown column \"\{name}\" in FROM")
  }
}

///|
/// Table mask of every column an expression references, resolved before
/// binding (drives join conjunct classification).
fn Binder::col_mask(self : Binder, e : LExpr) -> Int raise @types.SqlError {
  match e {
    Col(name) => 1 << self.lookup_slot(name)
    Lit(_) => 0
    Arith(_, l, r) => self.col_mask(l) | self.col_mask(r)
    Cmp(_, l, r) => self.col_mask(l) | self.col_mask(r)
    And(l, r) => self.col_mask(l) | self.col_mask(r)
    Or(l, r) => self.col_mask(l) | self.col_mask(r)
    Not(x) => self.col_mask(x)
    Between(v, lo, hi) =>
      self.col_mask(v) | self.col_mask(lo) | self.col_mask(hi)
    In(v, items) => {
      let mut m = self.col_mask(v)
      for item in items {
        m = m | self.col_mask(item)
      }
      m
    }
    Like(v, _) => self.col_mask(v)
    Case(whens, else_) => {
      let mut m = 0
      for when in whens {
        m = m | self.col_mask(when.0) | self.col_mask(when.1)
      }
      match else_ {
        Some(e) => m | self.col_mask(e)
        None => m
      }
    }
    Agg(_, _) =>
      raise @types.SqlError::Bind("aggregate not allowed in a join condition")
  }
}

///|
fn split_and(e : LExpr, out : Array[Conjunct], origin : Int?) -> Unit {
  match e {
    And(l, r) => {
      split_and(l, out, origin)
      split_and(r, out, origin)
    }
    other => out.push({ lexpr: other, origin, })
  }
}

///|
/// Plan the left-deep join chain in FROM order and bind every classified
/// conjunct. WHERE conjuncts that span tables but never become keys or
/// residuals (possible at LEFT JOIN steps) come back as a deferred
/// post-join filter.
fn Binder::plan_joins(
  self : Binder,
  sel : Select,
) -> (Array[JoinStep], PhysExpr?) raise @types.SqlError {
  let pool : Array[Conjunct] = []
  match sel.filter {
    Some(f) => split_and(f, pool, None)
    None => ()
  }
  for i, item in sel.from {
    match item.on {
      Some(on) => split_and(on, pool, Some(i))
      None => ()
    }
  }
  let consumed : Array[Bool] = []
  for _ in 0..<pool.length() {
    consumed.push(false)
  }
  let steps : Array[JoinStep] = []
  let mut acc_mask = 0
  for i, item in sel.from {
    steps.push(self.plan_step(i, item, acc_mask, pool, consumed))
    acc_mask = acc_mask | (1 << i)
  }
  let leftover : Array[LExpr] = []
  for j, c in pool {
    if !consumed[j] {
      leftover.push(c.lexpr)
    }
  }
  let deferred : PhysExpr? = if leftover.length() == 0 {
    None
  } else {
    let mut acc : LExpr = leftover[0]
    for j in 1..<leftover.length() {
      acc = And(acc, leftover[j])
    }
    match self.bind(acc, Flat) {
      (pe, @types.Bool) => Some(pe)
      (_, other) =>
        raise @types.SqlError::Bind(
          "filter must evaluate to bool, got \{other.to_string()}",
        )
    }
  }
  (steps, deferred)
}

///|
fn Binder::plan_step(
  self : Binder,
  i : Int,
  item : FromItem,
  acc_mask : Int,
  pool : Array[Conjunct],
  consumed : Array[Bool],
) -> JoinStep raise @types.SqlError {
  let cur_mask = 1 << i
  let both_masks = acc_mask | cur_mask
  let build_l : Array[LExpr] = []
  let probe_l : Array[LExpr] = []
  let key_l : Array[LExpr] = []
  let key_r : Array[LExpr] = []
  let residual_l : Array[LExpr] = []
  for j, cj in pool {
    if consumed[j] {
      continue
    }
    // ON conjuncts belong to their own step only
    match cj.origin {
      Some(o) => if o != i { continue }
      None => ()
    }
    let m = self.col_mask(cj.lexpr)
    if m == cur_mask {
      build_l.push(cj.lexpr)
      consumed[j] = true
    } else if m == 0 {
      // constant predicate: probe side from step 1 on, build at step 0
      if i == 0 {
        build_l.push(cj.lexpr)
      } else {
        probe_l.push(cj.lexpr)
      }
      consumed[j] = true
    } else if (m & both_masks.lnot()) == 0 && (m & cur_mask) == 0 {
      // references only accumulated tables; at a LEFT step this is a
      // WHERE pushdown, still sound
      probe_l.push(cj.lexpr)
      consumed[j] = true
    } else if (m & both_masks.lnot()) == 0 && (m & cur_mask) != 0 {
      // spans the accumulated row and the joining table
      let key = match cj.lexpr {
        Cmp(@types.Eq, l, r) => {
          let lm = self.col_mask(l)
          let rm = self.col_mask(r)
          if (lm & acc_mask.lnot()) == 0 && lm != 0 && rm == cur_mask {
            key_l.push(l)
            key_r.push(r)
            consumed[j] = true
            true
          } else if (rm & acc_mask.lnot()) == 0 && rm != 0 && lm == cur_mask {
            key_l.push(r)
            key_r.push(l)
            consumed[j] = true
            true
          } else {
            false
          }
        }
        _ => false
      }
      if !key {
        // residual per candidate pair; at a LEFT step only ON conjuncts
        // may act as residuals (WHERE keeps SQL semantics: filter the
        // join output, never change NULL-extension)
        if item.join is Left && cj.origin is None {
          let _ = m // stay unconsumed; deferred below
        } else {
          residual_l.push(cj.lexpr)
          consumed[j] = true
        }
      }
    }
    // else: references tables joined later; leave in the pool
  }
  let step = i
  let build_filter = self.conjoin_bind(build_l, Slot(step), "build filter")
  let probe_filter = self.conjoin_bind(probe_l, Flat, "probe filter")
  let residual = self.conjoin_bind(residual_l, Flat, "join residual")
  let keys_l : Array[PhysExpr] = []
  let keys_r : Array[PhysExpr] = []
  for k in 0..<key_l.length() {
    let (lpe, ldt) = self.bind(key_l[k], Flat)
    let (rpe, rdt) = self.bind(key_r[k], Slot(step))
    match unify(ldt, rdt) {
      Some(dt) => {
        keys_l.push(promote_to(lpe, ldt, dt))
        keys_r.push(promote_to(rpe, rdt, dt))
      }
      None =>
        raise @types.SqlError::Bind(
          "join key type mismatch: \{ldt.to_string()} vs \{rdt.to_string()}",
        )
    }
  }
  let out_dtypes : Array[@types.DataType] = []
  for k in 0..<i {
    for c in self.slots[k].columns {
      out_dtypes.push(c.dtype)
    }
  }
  for c in self.slots[i].columns {
    out_dtypes.push(c.dtype)
  }
  {
    table: i,
    kind: item.join,
    keys_l,
    keys_r,
    build_filter,
    probe_filter,
    residual,
    right_offset: self.offsets[i],
    right_width: self.slots[i].columns.length(),
    out_dtypes,
  }
}

///|
fn Binder::conjoin_bind(
  self : Binder,
  lexprs : Array[LExpr],
  space : Space,
  what : String,
) -> PhysExpr? raise @types.SqlError {
  if lexprs.length() == 0 {
    return None
  }
  let mut acc : LExpr = lexprs[0]
  for j in 1..<lexprs.length() {
    acc = And(acc, lexprs[j])
  }
  match self.bind(acc, space) {
    (pe, @types.Bool) => Some(pe)
    (_, other) =>
      raise @types.SqlError::Bind(
        "\{what} must evaluate to bool, got \{other.to_string()}",
      )
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
  let (pe, dt) = self.bind(lexpr, Flat) // no nested aggregates
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
/// Bind a logical expression in the given space.
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
        Flat => {
          let k = self.lookup_slot(name)
          let col_idx = self.slots[k].index_of(name).unwrap()
          let dt = self.slots[k].columns[col_idx].dtype
          (ColRef(self.offsets[k] + col_idx, dt), dt)
        }
        Slot(k) =>
          match self.slots[k].index_of(name) {
            Some(col_idx) => {
              let dt = self.slots[k].columns[col_idx].dtype
              (ColRef(col_idx, dt), dt)
            }
            None =>
              raise @types.SqlError::Bind(
                "unknown column \"\{name}\" in table \"\{self.slots[k].table}\"",
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
        AggOut => self.agg_ref(fn_, inner)
        _ =>
          raise @types.SqlError::Bind(
            "aggregate is only allowed in SELECT, HAVING or ORDER BY",
          )
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
