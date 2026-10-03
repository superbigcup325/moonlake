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
  IsNullE(PhysExpr, Bool) // IS NULL (false) / IS NOT NULL (true)
  ExtractE(PhysExpr, ExtractField)
  InSetE(PhysExpr, Map[String, Bool], Bool, Bool) // value, folded key set, negated, right side had NULL
  CaseE(Array[(PhysExpr, PhysExpr)], PhysExpr?, @types.DataType)
  FuncE(String, Array[PhysExpr], @types.DataType) // scalar function, name lowercased
  CastE(PhysExpr, @types.DataType) // CAST(expr AS type)
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
  priv deferred : PhysExpr?
  priv aggregate : Bool // false: plain projection over the joined rows
  priv group_exprs : Array[PhysExpr]
  priv group_types : Array[@types.DataType]
  priv aggs : Array[AggSpec]
  priv having : PhysExpr? // over post-agg layout
  priv out_exprs : Array[PhysExpr] // over post-agg layout
  priv names : Array[String]
  priv out_types : Array[@types.DataType]
  priv order_keys : Array[(Int, Bool, Bool?)] // output column index, desc, nulls first?
  priv order_exprs : Array[(PhysExpr, Bool, Bool?)] // sort before projection
  priv limit : Int?
  priv offset : Int?
  priv distinct : Bool // SELECT DISTINCT: dedupe projected rows
} derive(Debug)

///|
pub extend BoundQuery with @debug.Debug::{to_repr}

///|
priv struct Binder {
  slots : Array[@catalog.TableSchema] // FROM order
  quals : Array[String] // alias (or table name) per slot, for ColQ lookup
  mut offsets : Array[Int] // flat offset of each slot in JOIN order (set by plan_joins)
  runner : SubqueryRunner // executes non-correlated subqueries during binding
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
/// Executes non-correlated subqueries during binding. Everything in the
/// engine is eager, so folding them to constants / key sets is direct.
/// Correlation is not supported: an inner select can only see its own
/// FROM tables (an outer name resolves as an error or an inner column,
/// never as the outer row).
priv struct SubqueryRunner {
  catalog : @catalog.Catalog
}

///|
fn SubqueryRunner::run_scalar(
  self : SubqueryRunner,
  sel : Select,
) -> (@types.Scalar, @types.DataType) raise @types.SqlError {
  let r = run_parsed(sel, self.catalog)
  if r.names().length() != 1 {
    raise @types.SqlError::Bind(
      "scalar subquery must return exactly one column",
    )
  }
  // SQL semantics: a scalar subquery over zero rows yields NULL; only
  // more than one row is an error
  if r.row_count() > 1 {
    raise @types.SqlError::Bind(
      "scalar subquery must return at most one row, got \{r.row_count()}",
    )
  }
  if r.row_count() == 0 {
    return (@types.Null, r.types()[0])
  }
  (r.get(0, 0), r.types()[0])
}

///|
/// EXISTS folds to a boolean constant: true when the subquery returns
/// any row. Correlation is not supported (the inner select binds
/// against its own FROM only).
fn SubqueryRunner::run_exists(
  self : SubqueryRunner,
  sel : Select,
) -> Bool raise @types.SqlError {
  let r = run_parsed(sel, self.catalog)
  r.row_count() > 0
}

///|
fn SubqueryRunner::run_key_set(
  self : SubqueryRunner,
  sel : Select,
) -> (Map[String, Bool], Bool, @types.DataType) raise @types.SqlError {
  let r = run_parsed(sel, self.catalog)
  if r.names().length() != 1 {
    raise @types.SqlError::Bind("IN subquery must return exactly one column")
  }
  let set : Map[String, Bool] = Map([])
  let mut has_null = false
  for row in 0..<r.row_count() {
    match r.get(row, 0) {
      @types.Null => has_null = true
      v => set[scalar_key(v)] = true
    }
  }
  (set, has_null, r.types()[0])
}

///|
fn bind_select(
  sel : Select,
  schemas : Array[@catalog.TableSchema],
  runner : SubqueryRunner,
) -> BoundQuery raise @types.SqlError {
  if schemas.length() > 30 {
    raise @types.SqlError::Bind("too many tables in FROM (max 30)")
  }
  let quals : Array[String] = []
  for item in sel.from {
    quals.push(
      match item.tbl_alias {
        Some(a) => a
        None =>
          match item.table {
            Named(n) => n
            Sub(_) => "_subquery"
          }
      },
    )
  }
  let b : Binder = {
    slots: schemas,
    quals,
    offsets: [],
    runner,
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
  // A query aggregates when it has GROUP BY, an aggregate anywhere in
  // the select list, or an aggregate in HAVING; otherwise it is a plain
  // projection over the joined rows.
  let mut agg_mode = sel.group_by.length() > 0
  if !agg_mode {
    for item in sel.items {
      if contains_agg(item.expr) {
        agg_mode = true
      }
    }
    if !agg_mode {
      match sel.having {
        Some(h) => if contains_agg(h) { agg_mode = true }
        None => ()
      }
    }
  }
  let item_space : Space = if agg_mode { AggOut } else { Flat }
  // expand a bare `*` select item into every FROM column, each table in
  // FROM order (qualified refs keep duplicate names resolvable); in
  // aggregate mode the plain columns then fail binding with the usual
  // "must appear in GROUP BY" error, which is the right answer there too
  let items : Array[SelectItem] = []
  for item in sel.items {
    if item.expr is Star {
      for k, schema in schemas {
        for col in schema.columns {
          items.push({ expr: ColQ(quals[k], col.name), label: None, })
        }
      }
    } else {
      items.push(item)
    }
  }
  let out_exprs : Array[PhysExpr] = []
  let names : Array[String] = []
  let out_types : Array[@types.DataType] = []
  for i, item in items {
    let (pe, dt) = b.bind(item.expr, item_space)
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
    Some(h) => {
      if !agg_mode {
        raise @types.SqlError::Bind(
          "HAVING requires GROUP BY or an aggregate (v1 subset)",
        )
      }
      match b.bind(h, AggOut) {
        (pe, @types.Bool) => Some(pe)
        (_, other) =>
          raise @types.SqlError::Bind(
            "HAVING must evaluate to bool, got \{other.to_string()}",
          )
      }
    }
    None => None
  }
  let order_keys : Array[(Int, Bool, Bool?)] = []
  let order_exprs : Array[(PhysExpr, Bool, Bool?)] = []
  for item in sel.order_by {
    // ORDER BY references output columns by name or ordinal; anything
    // else binds as an expression over the pre-projection row (Flat for
    // plain queries, AggOut once aggregates are involved), and sorting
    // happens before projection.
    let key_name : String? = match item.key {
      Col(name) => Some(name)
      ColQ(_, name) => Some(name)
      _ => None
    }
    let mut idx : Int? = match key_name {
      Some(name) => {
        let mut found = None
        for i, name2 in names {
          if name2 == name {
            found = Some(i)
          }
        }
        found
      }
      None => None
    }
    if idx is None {
      match item.key {
        Lit(@types.Int32(v)) =>
          if v >= 1 && v <= names.length() {
            idx = Some(v - 1)
          } else {
            raise @types.SqlError::Bind(
              "ORDER BY position \{v} is out of range (1..\{names.length()})",
            )
          }
        _ => ()
      }
    }
    match idx {
      Some(i) => order_keys.push((i, item.desc, item.nulls_first))
      None => {
        let (pe, _) = b.bind(item.key, if agg_mode { AggOut } else { Flat })
        order_exprs.push((pe, item.desc, item.nulls_first))
      }
    }
  }
  {
    steps,
    deferred,
    aggregate: agg_mode,
    group_exprs,
    group_types: b.group_types,
    aggs: b.aggs,
    having,
    out_exprs,
    names,
    out_types,
    order_keys,
    order_exprs,
    limit: sel.limit,
    offset: sel.offset,
    distinct: sel.distinct,
  }
}

///|
fn contains_agg(e : LExpr) -> Bool {
  match e {
    Col(_) | ColQ(_, _) | Lit(_) => ()
    Agg(_, _) => return true
    Func(_, args) =>
      for a in args {
        if contains_agg(a) {
          return true
        }
      }
    Cast(e, _) => if contains_agg(e) { return true }
    Exists(_, _) => ()
    Arith(_, l, r) | Cmp(_, l, r) | And(l, r) | Or(l, r) =>
      return contains_agg(l) || contains_agg(r)
    Not(x) => return contains_agg(x)
    Between(v, lo, hi) =>
      return contains_agg(v) || contains_agg(lo) || contains_agg(hi)
    In(v, items) | NotIn(v, items) => {
      let mut found = contains_agg(v)
      for item in items {
        if contains_agg(item) {
          found = true
        }
      }
      return found
    }
    Like(v, _) | NotLike(v, _) => return contains_agg(v)
    IsNull(v, _) => return contains_agg(v)
    Star => return false
    Extract(_, x) => return contains_agg(x)
    Case(whens, else_) => {
      let mut found = false
      for when in whens {
        if contains_agg(when.0) || contains_agg(when.1) {
          found = true
        }
      }
      match else_ {
        Some(e) => return found || contains_agg(e)
        None => return found
      }
    }
    ScalarSub(_) | InSelect(_, _, _) => return false // inner query aggregates are its own
  }
  false
}

///|
fn default_name(expr : LExpr, index : Int) -> String {
  match expr {
    Col(name) => name
    ColQ(_, name) => name
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
/// Resolve a FROM qualifier (alias or table name) to its slot.
fn Binder::lookup_slot_by_qual(
  self : Binder,
  q : String,
) -> Int raise @types.SqlError {
  for k, s in self.slots {
    if self.quals[k] == q || s.table == q {
      return k
    }
  }
  raise @types.SqlError::Bind("unknown table or alias \"\{q}\" in FROM")
}

///|
/// Table mask of every column an expression references, resolved before
/// binding (drives join conjunct classification).
fn Binder::col_mask(self : Binder, e : LExpr) -> Int raise @types.SqlError {
  match e {
    Col(name) => 1 << self.lookup_slot(name)
    ColQ(q, _) => 1 << self.lookup_slot_by_qual(q)
    Lit(_) => 0
    Arith(_, l, r) => self.col_mask(l) | self.col_mask(r)
    Cmp(_, l, r) => self.col_mask(l) | self.col_mask(r)
    And(l, r) => self.col_mask(l) | self.col_mask(r)
    Or(l, r) => self.col_mask(l) | self.col_mask(r)
    Not(x) => self.col_mask(x)
    Between(v, lo, hi) =>
      self.col_mask(v) | self.col_mask(lo) | self.col_mask(hi)
    In(v, items) | NotIn(v, items) => {
      let mut m = self.col_mask(v)
      for item in items {
        m = m | self.col_mask(item)
      }
      m
    }
    Like(v, _) | NotLike(v, _) => self.col_mask(v)
    IsNull(v, _) => self.col_mask(v)
    Star => raise @types.SqlError::Bind("'*' is only allowed as a select item")
    Extract(_, x) => self.col_mask(x)
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
    // subqueries are self-contained: only the outer value expression counts
    ScalarSub(_) => 0
    InSelect(v, _, _) => self.col_mask(v)
    Exists(_, _) => 0
    Func(_, args) => {
      let mut m = 0
      for a in args {
        m = m | self.col_mask(a)
      }
      m
    }
    Cast(e, _) => self.col_mask(e)
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
/// Top-level OR branches of a conjunct.
fn or_branches(e : LExpr, out : Array[LExpr]) -> Unit {
  match e {
    Or(l, r) => {
      or_branches(l, out)
      or_branches(r, out)
    }
    other => out.push(other)
  }
}

///|
/// Equality pairs inside a (possibly AND-chained) branch.
fn and_eqs(e : LExpr, out : Array[(LExpr, LExpr)]) -> Unit {
  match e {
    And(l, r) => {
      and_eqs(l, out)
      and_eqs(r, out)
    }
    Cmp(@types.Eq, l, r) => out.push((l, r))
    _ => ()
  }
}

///|
/// If every OR branch implies the same equi pair split across the
/// accumulated row and the joining table, return it (left, right).
fn Binder::implied_eq(
  self : Binder,
  e : LExpr,
  acc_mask : Int,
  cur_mask : Int,
) -> (LExpr, LExpr)? raise @types.SqlError {
  let disjuncts : Array[LExpr] = []
  or_branches(e, disjuncts)
  if disjuncts.length() < 2 {
    return None
  }
  let first : Array[(LExpr, LExpr)] = []
  and_eqs(disjuncts[0], first)
  let mut common : (LExpr, LExpr)? = None
  for cand in first {
    let mut all = true
    for k in 1..<disjuncts.length() {
      let eqs : Array[(LExpr, LExpr)] = []
      and_eqs(disjuncts[k], eqs)
      let mut found = false
      for pair in eqs {
        if (LExpr::equal(cand.0, pair.0) && LExpr::equal(cand.1, pair.1)) ||
          (LExpr::equal(cand.0, pair.1) && LExpr::equal(cand.1, pair.0)) {
          found = true
        }
      }
      if !found {
        all = false
      }
    }
    if all {
      common = Some(cand)
      break
    }
  }
  match common {
    Some((l, r)) => {
      let lm = self.col_mask(l)
      let rm = self.col_mask(r)
      if (lm & acc_mask.lnot()) == 0 && lm != 0 && rm == cur_mask {
        Some((l, r))
      } else if (rm & acc_mask.lnot()) == 0 && rm != 0 && lm == cur_mask {
        Some((r, l))
      } else {
        None
      }
    }
    None => None
  }
}

///|
/// Plan the join chain and bind every classified conjunct. Chains with
/// any LEFT JOIN keep written order (LEFT fixes row preservation);
/// inner-only chains join greedily connected-first so a written order
/// like `part, supplier, lineitem, ...` does not cross-product early.
/// The flat column layout follows the JOIN order (that is how the
/// executor accumulates rows). WHERE conjuncts that span tables but
/// never become keys or residuals (possible at LEFT JOIN steps) come
/// back as a deferred post-join filter.
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
  // join order
  let order : Array[Int] = []
  let mut has_left = false
  for item in sel.from {
    // any row-preserving join fixes the written order
    if !(item.join is Inner) {
      has_left = true
    }
  }
  if has_left {
    for i in 0..<sel.from.length() {
      order.push(i)
    }
  } else {
    let remaining : Array[Int] = []
    for i in 0..<sel.from.length() {
      remaining.push(i)
    }
    let mut acc_mask = 0
    while remaining.length() > 0 {
      // first remaining table with an equi conjunct into the accumulated
      // row; written order breaks ties; no connection -> cross with the
      // first remaining table
      let mut pick = remaining[0]
      let mut connected = false
      for t in remaining {
        if self.connects(t, acc_mask, pool, consumed) {
          pick = t
          connected = true
          break
        }
      }
      if !connected {
        pick = remaining[0]
      }
      order.push(pick)
      acc_mask = acc_mask | (1 << pick)
      let mut idx = 0
      for k, t in remaining {
        if t == pick {
          idx = k
        }
      }
      let _ = remaining.remove(idx)
    }
  }
  // flat layout follows the join order
  let offsets : Array[Int] = []
  for _ in 0..<sel.from.length() {
    offsets.push(0)
  }
  let mut off = 0
  for t in order {
    offsets[t] = off
    off += self.slots[t].columns.length()
  }
  self.offsets = offsets
  let steps : Array[JoinStep] = []
  let acc_tables : Array[Int] = []
  let mut acc_mask = 0
  for i in order {
    steps.push(
      self.plan_step(i, sel.from[i], acc_tables, acc_mask, pool, consumed),
    )
    acc_tables.push(i)
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
/// Is there an unconsumed conjunct whose equality sides split exactly
/// across the accumulated row and table t?
fn Binder::connects(
  self : Binder,
  t : Int,
  acc_mask : Int,
  pool : Array[Conjunct],
  consumed : Array[Bool],
) -> Bool raise @types.SqlError {
  let cur = 1 << t
  for j, cj in pool {
    if consumed[j] {
      continue
    }
    match cj.origin {
      Some(o) => if o != t { continue }
      None => ()
    }
    match cj.lexpr {
      Cmp(@types.Eq, l, r) => {
        let lm = self.col_mask(l)
        let rm = self.col_mask(r)
        if (lm & acc_mask.lnot()) == 0 && lm != 0 && rm == cur {
          return true
        }
        if (rm & acc_mask.lnot()) == 0 && rm != 0 && lm == cur {
          return true
        }
      }
      _ => ()
    }
  }
  false
}

///|
fn Binder::plan_step(
  self : Binder,
  i : Int,
  item : FromItem,
  acc_tables : Array[Int], // slots joined so far, in join order
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
      // a WHERE conjunct on the joining table must not filter build rows
      // when the accumulated side is preserved (LEFT): removing build
      // rows changes which probe rows find a match, so the NULL-extended
      // output would lose the restriction (WHERE applies to the
      // post-join row, NULL side included). It stays unconsumed and
      // comes back as the deferred post-join filter. At a RIGHT step the
      // joining table is the preserved side, so the filter is sound
      // there; at FULL both sides are preserved, so it defers too.
      // ON conjuncts keep build placement: dropping candidates is exactly
      // their semantics, NULL-extension sees the same match set.
      if (item.join is Left || item.join is Full) && cj.origin is None {
        let _ = m
      } else {
        build_l.push(cj.lexpr)
        consumed[j] = true
      }
    } else if m == 0 {
      // constant predicate: probe side from step 1 on, build at step 0
      if i == 0 {
        build_l.push(cj.lexpr)
      } else {
        probe_l.push(cj.lexpr)
      }
      consumed[j] = true
    } else if (m & both_masks.lnot()) == 0 && (m & cur_mask) == 0 {
      // references only accumulated tables: a WHERE pushdown is sound
      // while the accumulated side is preserved (Inner/Left). At RIGHT
      // and FULL the accumulated side is NULL-extendable, so a WHERE
      // conjunct must stay a deferred post-join filter (ON conjuncts
      // keep candidate filtering — that is their semantics)
      if (item.join is Right || item.join is Full) && cj.origin is None {
        let _ = m // stay unconsumed; deferred below
      } else {
        probe_l.push(cj.lexpr)
        consumed[j] = true
      }
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
      if !key && (m & both_masks.lnot()) == 0 {
        // a disjunction may imply an equality: Q19-style OR branches that
        // all contain the same equi pair (e.g. p_partkey = l_partkey)
        // yield a hash key while the full OR stays as the residual
        let implied : (LExpr, LExpr)? = match cj.lexpr {
          Or(_, _) => self.implied_eq(cj.lexpr, acc_mask, cur_mask)
          _ => None
        }
        match implied {
          Some((l, r)) => {
            key_l.push(l)
            key_r.push(r)
            residual_l.push(cj.lexpr)
            consumed[j] = true
          }
          None =>
            // residual per candidate pair; at a LEFT step only ON
            // conjuncts may act as residuals (WHERE keeps SQL semantics:
            // filter the join output, never change NULL-extension)
            if item.join is Left && cj.origin is None {
              let _ = m // stay unconsumed; deferred below
            } else {
              residual_l.push(cj.lexpr)
              consumed[j] = true
            }
        }
      } else if !key {
        let _ = m // conjunct references tables joined later
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
  for k in acc_tables {
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
    ColQ(q, name) =>
      match space {
        AggOut =>
          raise @types.SqlError::Bind(
            "column \"\{q}.\{name}\" must appear in GROUP BY or inside an aggregate",
          )
        _ => {
          let k = self.lookup_slot_by_qual(q)
          let col_idx : Int? = self.slots[k].index_of(name)
          match col_idx {
            Some(col_idx) => {
              let dt = self.slots[k].columns[col_idx].dtype
              let base = match space {
                Flat => self.offsets[k]
                Slot(_) => 0 // local refs index the table itself
                AggOut => 0 // unreachable: handled above
              }
              (ColRef(base + col_idx, dt), dt)
            }
            None =>
              raise @types.SqlError::Bind(
                "unknown column \"\{name}\" in table \"\{self.slots[k].table}\"",
              )
          }
        }
      }
    Lit(s) =>
      match s {
        @types.Null =>
          raise @types.SqlError::Bind(
            "untyped NULL is only supported as a comparison or arithmetic operand (v1 subset)",
          )
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
    Arith(op, l, r) =>
      // NULL literal operand: the live side fixes the arithmetic type and
      // the result is NULL for every row (Scalar::arith propagates it)
      if l is Lit(@types.Null) || r is Lit(@types.Null) {
        if l is Lit(@types.Null) && r is Lit(@types.Null) {
          raise @types.SqlError::Bind(
            "type of NULL cannot be inferred from NULL",
          )
        }
        let (live_pe, live_dt) = self.bind(
          if l is Lit(@types.Null) {
            r
          } else {
            l
          },
          space,
        )
        if live_dt is @types.Bool {
          raise @types.SqlError::Bind("bool operand in arithmetic")
        }
        // `/` is true division per DuckDB even against NULL: int/int is DOUBLE
        let out = arith_output(op, live_dt)
        let null_pe : PhysExpr = Const(@types.Null)
        (
          if l is Lit(@types.Null) {
            ArithE(op, null_pe, live_pe, out)
          } else {
            ArithE(op, live_pe, null_pe, out)
          },
          out,
        )
      } else {
        let (lpe, ldt) = self.bind(l, space)
        let (rpe, rdt) = self.bind(r, space)
        match unify(ldt, rdt) {
          Some(dt) =>
            match dt {
              @types.Bool =>
                raise @types.SqlError::Bind("bool operand in arithmetic")
              _ => {
                // `/` is true division per DuckDB: int/int yields DOUBLE,
                // so both sides promote even when unify agreed on an integer
                let out = arith_output(op, dt)
                let lp = promote_to(lpe, ldt, out)
                let rp = promote_to(rpe, rdt, out)
                (ArithE(op, lp, rp, out), out)
              }
            }
          None =>
            raise @types.SqlError::Bind(
              "type mismatch in arithmetic: \{ldt.to_string()} vs \{rdt.to_string()}",
            )
        }
      }
    Cmp(op, l, r) =>
      // NULL literal operand: v <op> NULL is UNKNOWN for every row (the
      // evaluator turns a NULL side into a NULL ordering); the live side
      // still binds so unknown columns and type errors surface
      if l is Lit(@types.Null) || r is Lit(@types.Null) {
        if l is Lit(@types.Null) && r is Lit(@types.Null) {
          let null_pe : PhysExpr = Const(@types.Null)
          return (CmpE(op, null_pe, null_pe), @types.Bool)
        }
        let (live_pe, _) = self.bind(
          if l is Lit(@types.Null) {
            r
          } else {
            l
          },
          space,
        )
        let null_pe : PhysExpr = Const(@types.Null)
        (
          if l is Lit(@types.Null) {
            CmpE(op, null_pe, live_pe)
          } else {
            CmpE(op, live_pe, null_pe)
          },
          @types.Bool,
        )
      } else {
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
    NotLike(v, pat) => {
      // desugar: NOT (v LIKE pat) — three-valued NOT keeps NULL semantics
      let (pe, dt) = self.bind(Not(Like(v, pat)), space)
      (pe, dt)
    }
    NotIn(v, items) => {
      // desugar: NOT (v IN (item1, item2 ...))
      let (pe, dt) = self.bind(Not(In(v, items)), space)
      (pe, dt)
    }
    IsNull(v, negated) => {
      let (pe, _) = self.bind(v, space)
      (IsNullE(pe, negated), @types.Bool)
    }
    Star => raise @types.SqlError::Bind("'*' is only allowed as a select item")
    Extract(field, inner) => {
      let (pe, dt) = self.bind(inner, space)
      if dt != @types.Date {
        raise @types.SqlError::Bind(
          "EXTRACT requires a date value, got \{dt.to_string()}",
        )
      }
      (ExtractE(pe, field), @types.Int32)
    }
    ScalarSub(sub) => {
      let (value, dt) = self.runner.run_scalar(sub)
      (Const(value), dt)
    }
    InSelect(v, sub, negated) => {
      let (vpe, vdt) = self.bind(v, space)
      let (set, has_null, sub_dt) = self.runner.run_key_set(sub)
      if sub_dt != vdt {
        raise @types.SqlError::Bind(
          "IN subquery column type mismatch: \{vdt.to_string()} vs \{sub_dt.to_string()}",
        )
      }
      (InSetE(vpe, set, negated, has_null), @types.Bool)
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
    Exists(sub, negated) => {
      let has_rows = self.runner.run_exists(sub)
      (
        Const(@types.Boolean(if negated { !has_rows } else { has_rows })),
        @types.Bool,
      )
    }
    Func(name, args) => self.bind_func(name, args, space)
    Cast(e, dt) =>
      // CAST(NULL AS t) is a typed NULL like Cmp/Arith's NULL operands
      if e is Lit(@types.Null) {
        (Const(@types.Null), dt)
      } else {
        let (pe, src_dt) = self.bind(e, space)
        castable(src_dt, dt)
        (CastE(pe, dt), dt)
      }
  }
}

///|
/// Type-check a scalar function call and lower it to FuncE. Operand
/// types must match the signature exactly (no implicit casts besides
/// the binder's numeric promotions, which do not apply to strings).
fn Binder::bind_func(
  self : Binder,
  name : String,
  args : Array[LExpr],
  space : Space,
) -> (PhysExpr, @types.DataType) raise @types.SqlError {
  let arity = args.length()
  fn want(
    e : LExpr,
    dt : @types.DataType,
    what : String,
  ) -> (PhysExpr, @types.DataType) raise @types.SqlError {
    let (pe, got) = self.bind(e, space)
    if got != dt {
      raise @types.SqlError::Bind(
        "\{name}() requires a \{what} argument, got \{got.to_string()}",
      )
    }
    (pe, got)
  }
  fn want_num(e : LExpr) -> (PhysExpr, @types.DataType) raise @types.SqlError {
    let (pe, got) = self.bind(e, space)
    match got {
      @types.Int32 | @types.Int64 | @types.Float64 => ()
      other =>
        raise @types.SqlError::Bind(
          "\{name}() requires a numeric argument, got \{other.to_string()}",
        )
    }
    (pe, got)
  }
  match name {
    "length" => {
      if arity != 1 {
        raise @types.SqlError::Bind("length() takes exactly one argument")
      }
      let (pe, _) = want(args[0], @types.Str, "string")
      (FuncE("length", [pe], @types.Int32), @types.Int32)
    }
    "upper" | "lower" | "trim" | "ltrim" | "rtrim" => {
      if arity != 1 {
        raise @types.SqlError::Bind("\{name}() takes exactly one argument")
      }
      let (pe, _) = want(args[0], @types.Str, "string")
      (FuncE(name, [pe], @types.Str), @types.Str)
    }
    "substring" => {
      if arity != 2 && arity != 3 {
        raise @types.SqlError::Bind(
          "substring() takes (string, start) or (string, start, length)",
        )
      }
      let (spe, _) = want(args[0], @types.Str, "string")
      let pes = [spe]
      for i in 1..<arity {
        let (pe, _) = want(args[i], @types.Int32, "int32")
        pes.push(pe)
      }
      (FuncE("substring", pes, @types.Str), @types.Str)
    }
    "concat" => {
      if arity != 2 {
        raise @types.SqlError::Bind("concat() takes exactly two arguments")
      }
      let (l, _) = want(args[0], @types.Str, "string")
      let (r, _) = want(args[1], @types.Str, "string")
      (FuncE("concat", [l, r], @types.Str), @types.Str)
    }
    "abs" => {
      if arity != 1 {
        raise @types.SqlError::Bind("abs() takes exactly one argument")
      }
      let (pe, dt) = want_num(args[0])
      (FuncE("abs", [pe], dt), dt)
    }
    "sqrt" => {
      if arity != 1 {
        raise @types.SqlError::Bind("sqrt() takes exactly one argument")
      }
      let (pe, _) = want_num(args[0])
      (FuncE("sqrt", [pe], @types.Float64), @types.Float64)
    }
    "floor" | "ceil" => {
      if arity != 1 {
        raise @types.SqlError::Bind("\{name}() takes exactly one argument")
      }
      let (pe, _) = want_num(args[0])
      (FuncE(name, [pe], @types.Float64), @types.Float64)
    }
    "round" => {
      if arity != 1 && arity != 2 {
        raise @types.SqlError::Bind("round() takes (x) or (x, digits)")
      }
      let (pe, _) = want_num(args[0])
      let pes = [pe]
      if arity == 2 {
        let (dpe, _) = want(args[1], @types.Int32, "int32")
        pes.push(dpe)
      }
      (FuncE("round", pes, @types.Float64), @types.Float64)
    }
    other => raise @types.SqlError::Bind("unknown function \"\{other}\"")
  }
}

///|
/// Allowed CAST paths; anything else is a bind error.
fn castable(
  src : @types.DataType,
  dst : @types.DataType,
) -> Unit raise @types.SqlError {
  let ok = if src == dst {
    true
  } else {
    match src {
      @types.Int32 | @types.Int64 | @types.Float64 =>
        dst
        is (@types.Int32
        | @types.Int64
        | @types.Float64
        | @types.Str
        | @types.Bool)
      @types.Bool =>
        dst is (@types.Str | @types.Int32 | @types.Int64 | @types.Float64)
      @types.Str =>
        dst
        is (@types.Int32
        | @types.Int64
        | @types.Float64
        | @types.Bool
        | @types.Date
        | @types.Str)
      @types.Date => dst is (@types.Str | @types.Int32)
    }
  }
  if !ok {
    raise @types.SqlError::Bind(
      "cannot cast \{src.to_string()} to \{dst.to_string()}",
    )
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
/// Result type of an arithmetic node. `/` is true division per DuckDB:
/// numeric operands always yield DOUBLE (zero divisor becomes IEEE
/// inf/nan at evaluation). Non-numeric operand types (Date) keep the
/// unified type and stay on the evaluator's NULL-propagation path.
fn arith_output(op : @types.ArithOp, dt : @types.DataType) -> @types.DataType {
  if op is @types.Div && dt is (@types.Int32 | @types.Int64 | @types.Float64) {
    @types.Float64
  } else {
    dt
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
