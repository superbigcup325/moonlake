// Correlated-subquery decorrelation: a WHERE conjunct of the form
// EXISTS (SELECT ...) or expr IN (SELECT ...) whose correlation is a
// conjunction of `inner expr = outer expr` equalities becomes a SEMI /
// ANTI join against the inner query pre-executed with the correlation
// stripped. The inner key expressions become the columns of a
// synthetic table; the equalities become its join ON. Leftover
// conjuncts that span both sides stay as the semi-join residual;
// purely inner ones filter the inner batch. Anything else (outer-only
// predicates inside the subquery, aggregates, nesting, mixed references
// inside one expression) is left untouched — the binder keeps its
// plain unsupported-correlation error for those.

///|
priv struct Correlator {
  catalog : @catalog.Catalog
  outer_items : Array[FromItem]
  mut sub_items : Array[FromItem] // the inner query's FROM, per attempt
  mut counter : Int
}

///|
/// Where the references of an expression live. Unqualified names known
/// to both scopes resolve to the inner scope (SQL nearest-scope rule).
priv enum RefSide {
  NoneSide // constant expression
  Inner
  Outer
  Mixed
  Unknown
}

///|
fn RefSide::merge(self : RefSide, other : RefSide) -> RefSide {
  match (self, other) {
    (NoneSide, x) => x
    (x, NoneSide) => x
    (Inner, Inner) => Inner
    (Outer, Outer) => Outer
    _ => Mixed
  }
}

///|
/// Rewrite correlated EXISTS / IN conjuncts into semi/anti joins.
/// Returns the rewritten select plus the synthetic tables (schemas and
/// their pre-executed batches, aligned with the appended FromItems).
fn decorrelate(
  sel : Select,
  catalog : @catalog.Catalog,
) -> (Select, Array[@catalog.TableSchema], Array[Array[@types.DataBatch]]) raise @types.SqlError {
  let extra_schemas : Array[@catalog.TableSchema] = []
  let extra_batches : Array[Array[@types.DataBatch]] = []
  let cor : Correlator = {
    catalog,
    outer_items: sel.from,
    sub_items: [],
    counter: 0,
  }
  // select items are walked even without a WHERE clause: correlated
  // scalar subqueries live there too
  let scalar_items : Array[FromItem] = []
  let new_exprs : Array[LExpr] = []
  let mut items_rewritten = false
  for it in sel.items {
    let rewritten = rewrite_scalar_items(
      it.expr,
      cor,
      extra_schemas,
      extra_batches,
      scalar_items,
    )
    if rewritten != it.expr {
      items_rewritten = true
    }
    new_exprs.push(rewritten)
  }
  let conjuncts : Array[Conjunct] = []
  match sel.filter {
    Some(f) => split_and(f, conjuncts, None)
    None => ()
  }
  let kept : Array[LExpr] = []
  let extra_items : Array[FromItem] = []
  for cj in conjuncts {
    // NOT EXISTS / NOT IN arrive as Not wrappers: flip the negation
    let lexpr = match cj.lexpr {
      Not(Exists(sub, negated)) => Exists(sub, !negated)
      Not(InSelect(v, sub, negated)) => InSelect(v, sub, !negated)
      other => other
    }
    match lexpr {
      Exists(sub, negated) =>
        match cor.try_exists(sub, negated, extra_schemas, extra_batches) {
          Some(item) => extra_items.push(item)
          None => kept.push(lexpr)
        }
      InSelect(v, sub, negated) =>
        match cor.try_in(v, sub, negated, extra_schemas, extra_batches, kept) {
          Some(item) => extra_items.push(item)
          None => kept.push(lexpr)
        }
      Cmp(op, outer_e, ScalarSub(sub)) =>
        match
          cor.try_scalar(op, outer_e, sub, extra_schemas, extra_batches, kept) {
          Some(item) => extra_items.push(item)
          None => kept.push(lexpr)
        }
      Cmp(op, ScalarSub(sub), outer_e) =>
        match
          cor.try_scalar(
            op.flip(),
            outer_e,
            sub,
            extra_schemas,
            extra_batches,
            kept,
          ) {
          Some(item) => extra_items.push(item)
          None => kept.push(lexpr)
        }
      _ => kept.push(lexpr)
    }
  }
  if extra_items.length() == 0 && scalar_items.length() == 0 {
    return (sel, extra_schemas, extra_batches)
  }
  let filter : LExpr? = match kept.length() {
    0 => None
    _ => {
      let mut acc = kept[0]
      for i in 1..<kept.length() {
        acc = And(acc, kept[i])
      }
      Some(acc)
    }
  }
  let from = sel.from
  for item in extra_items {
    from.push(item)
  }
  for item in scalar_items {
    from.push(item)
  }
  let items = if items_rewritten {
    let out : Array[SelectItem] = []
    for i, it in sel.items {
      out.push({ expr: new_exprs[i], label: it.label, })
    }
    out
  } else {
    sel.items
  }
  ({ ..sel, from, filter, items, }, extra_schemas, extra_batches)
}

///|
/// Shared setup: register the inner FROM and its column names, then
/// split the inner filter. None on anything unclassifiable.
fn Correlator::prepare(
  self : Correlator,
  sub : Select,
) -> (Array[(LExpr, LExpr)], Array[LExpr], Array[LExpr])? {
  for item in sub.from {
    if !(item.table is Named(_)) {
      return None
    }
  }
  let colnames : Array[String] = []
  for item in sub.from {
    match item.table {
      Named(name) =>
        match self.catalog.lookup(name) {
          Some(entry) =>
            for c in entry.schema.columns {
              colnames.push(c.name)
            }
          None => return None
        }
      Sub(_) => return None
    }
  }
  self.sub_items = sub.from
  let pairs : Array[(LExpr, LExpr)] = []
  let inner_only : Array[LExpr] = []
  let residual : Array[LExpr] = []
  let conjuncts : Array[Conjunct] = []
  match sub.filter {
    Some(f) => split_and(f, conjuncts, None)
    None => ()
  }
  for c in conjuncts {
    let cj = c.lexpr
    match cj {
      Cmp(@types.Eq, a, b) => {
        let sa = self.side_of(a)
        let sb = self.side_of(b)
        match (sa, sb) {
          (Inner, Outer) => pairs.push((a, b))
          (Outer, Inner) => pairs.push((b, a))
          (_, _) =>
            // not a clean correlation equality: purely inner conjuncts
            // stay in the inner filter (a literal operand is side-free),
            // spanning conjuncts fall to the semi residual, anything
            // else is unsupported
            match (self.side_of(a), self.side_of(b)) {
              (Inner, Inner)
              | (Inner, NoneSide)
              | (NoneSide, Inner)
              | (NoneSide, NoneSide) => inner_only.push(cj)
              (Mixed, _) | (_, Mixed) => residual.push(cj)
              (_, _) => return None
            }
        }
      }
      other =>
        match self.side_of(other) {
          Inner => inner_only.push(other)
          Mixed => residual.push(other)
          _ => return None // outer-only or unknown: unsupported
        }
    }
  }
  Some((pairs, inner_only, residual))
}

///|
/// Classify an EXISTS subquery. Some(item) replaces the conjunct with
/// a SEMI / ANTI FromItem against a fresh synthetic table appended to
/// the two arrays; None leaves the conjunct alone.
fn Correlator::try_exists(
  self : Correlator,
  sub : Select,
  _negated : Bool,
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
) -> FromItem? raise @types.SqlError {
  if !(sub.group_by.length() == 0) ||
    sub.having is Some(_) ||
    sub.limit is Some(_) ||
    sub.offset is Some(_) ||
    sub.distinct ||
    sub.setop is Some(_) {
    return None
  }
  let sink : Array[LExpr] = []
  match self.prepare(sub) {
    Some((pairs, inner_filter, residual)) =>
      if pairs.length() == 0 {
        None // no correlation: the binder folds it eagerly
      } else {
        self.finish_semi(
          sub.from,
          pairs,
          inner_filter,
          residual,
          _negated,
          extra_schemas,
          extra_batches,
          false,
          true,
          sink,
        )
      }
    None => None
  }
}

///|
/// Classify an IN subquery: the select list must be a single
/// expression, which pairs with the outer value expression.
fn Correlator::try_in(
  self : Correlator,
  v : LExpr,
  sub : Select,
  negated : Bool,
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
  kept : Array[LExpr],
) -> FromItem? raise @types.SqlError {
  if !(sub.group_by.length() == 0) ||
    sub.having is Some(_) ||
    sub.limit is Some(_) ||
    sub.offset is Some(_) ||
    sub.distinct ||
    sub.setop is Some(_) {
    return None
  }
  if sub.items.length() != 1 {
    return None
  }
  // the outer value must not reference the inner tables
  match self.side_of(v) {
    Outer | NoneSide => ()
    _ => return None
  }
  match self.prepare(sub) {
    Some((pairs, inner_filter, residual)) => {
      // the select expression pairs with the outer value
      pairs.insert(0, (sub.items[0].expr, v))
      self.finish_semi(
        sub.from,
        pairs,
        inner_filter,
        residual,
        negated,
        extra_schemas,
        extra_batches,
        true,
        false,
        kept,
      )
    }
    None => None
  }
}

///|
/// Classify a correlated scalar-subquery comparison
/// `outer_expr <op> (SELECT agg-expr FROM ... WHERE corr = outer.col ...)`:
/// the inner query runs grouped by the correlation keys as a LEFT join
/// synthetic table (an empty group NULL-extends, and the rewritten
/// comparison then filters the row — scalar-subquery NULL semantics).
/// The select item must contain an aggregate, so every group yields
/// exactly one row and the multiplicity of a plain scalar subquery
/// cannot arise. Non-correlated subqueries stay on the runner path.
fn Correlator::try_scalar(
  self : Correlator,
  op : @types.CmpOp,
  outer_e : LExpr,
  sub : Select,
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
  kept : Array[LExpr],
) -> FromItem? raise @types.SqlError {
  if !(sub.group_by.length() == 0) ||
    sub.having is Some(_) ||
    sub.limit is Some(_) ||
    sub.offset is Some(_) ||
    sub.distinct ||
    sub.setop is Some(_) {
    return None
  }
  // the outer value must not reference the inner tables
  match self.side_of(outer_e) {
    Outer | NoneSide => ()
    _ => return None
  }
  let (pairs, inner_only, residual) = match self.prepare(sub) {
    Some(triple) => triple
    None => return None
  }
  if pairs.length() == 0 {
    return None // non-correlated: the runner folds it eagerly
  }
  // a correlated scalar without an aggregate cannot decorrelate (its
  // groups would multiply outer rows); fail with a name that says why
  // instead of letting the runner surface a confusing inner-scope error
  if sub.items.length() != 1 || !contains_agg(sub.items[0].expr) {
    raise @types.SqlError::Bind(
      "correlated scalar subquery must select an aggregate (e.g. min/max/avg/count)",
    )
  }
  if residual.length() > 0 {
    return None
  }
  let (item, name) = self.build_scalar_table(
    sub, pairs, inner_only, extra_schemas, extra_batches,
  )
  // the rewritten comparison stays in the WHERE pool and classifies as
  // the step residual (or a hash key when the comparison is an equality)
  kept.push(Cmp(op, outer_e, ColQ(name, "__sk\{pairs.length()}")))
  Some(item)
}

///|
/// Shared by the WHERE-conjunct and select-item scalar rewrites: run
/// the subquery grouped by the correlation keys as a synthetic LEFT
/// join table; returns the FromItem and the synthetic table name (the
/// value column is __sk<pairs.length()>).
fn Correlator::build_scalar_table(
  self : Correlator,
  sub : Select,
  pairs : Array[(LExpr, LExpr)],
  inner_only : Array[LExpr],
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
) -> (FromItem, String) raise @types.SqlError {
  let items : Array[SelectItem] = []
  let group_by : Array[LExpr] = []
  for p in pairs {
    items.push({ expr: p.0, label: Some("__sk\{group_by.length()}"), })
    group_by.push(p.0)
  }
  items.push({ expr: sub.items[0].expr, label: Some("__sk\{pairs.length()}"), })
  let filter : LExpr? = match inner_only.length() {
    0 => None
    _ => {
      let mut acc = inner_only[0]
      for i in 1..<inner_only.length() {
        acc = And(acc, inner_only[i])
      }
      Some(acc)
    }
  }
  let inner_sel : Select = {
    from: sub.from,
    filter,
    group_by,
    having: None,
    items,
    order_by: [],
    limit: None,
    offset: None,
    distinct: false,
    setop: None,
  }
  let inner = run_parsed(inner_sel, self.catalog)
  let name = "__scalar\{self.counter}"
  self.counter = self.counter + 1
  let columns : Array[@catalog.Column] = []
  for i, t in inner.types() {
    columns.push({ name: "__sk\{i}", dtype: t, })
  }
  extra_schemas.push({ table: name, columns, })
  extra_batches.push([inner.batch()])
  let mut on : LExpr = Cmp(@types.Eq, pairs[0].1, ColQ(name, "__sk0"))
  for i in 1..<pairs.length() {
    on = And(on, Cmp(@types.Eq, pairs[i].1, ColQ(name, "__sk\{i}")))
  }
  let item : FromItem = {
    table: Named(name),
    tbl_alias: Some(name),
    col_aliases: None,
    join: Left,
    on: Some(on),
  }
  (item, name)
}

///|
/// Classify one correlated scalar subquery appearing in a select item.
/// Same rules as try_scalar; on bail the subquery stays untouched (the
/// runner keeps its unsupported-correlation error).
fn Correlator::try_scalar_item(
  self : Correlator,
  sub : Select,
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
  extra_items : Array[FromItem],
) -> LExpr? raise @types.SqlError {
  if !(sub.group_by.length() == 0) ||
    sub.having is Some(_) ||
    sub.limit is Some(_) ||
    sub.offset is Some(_) ||
    sub.distinct ||
    sub.setop is Some(_) {
    return None
  }
  if sub.items.length() != 1 || !contains_agg(sub.items[0].expr) {
    return None
  }
  let (pairs, inner_only, residual) = match self.prepare(sub) {
    Some(triple) => triple
    None => return None
  }
  if pairs.length() == 0 || residual.length() > 0 {
    return None
  }
  let (item, name) = self.build_scalar_table(
    sub, pairs, inner_only, extra_schemas, extra_batches,
  )
  extra_items.push(item)
  Some(ColQ(name, "__sk\{pairs.length()}"))
}

///|
/// Rewrite every correlated scalar subquery of a select-item expression
/// into a reference on its synthetic grouped table.
fn rewrite_scalar_items(
  e : LExpr,
  cor : Correlator,
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
  extra_items : Array[FromItem],
) -> LExpr raise @types.SqlError {
  fn walk(e : LExpr) -> LExpr raise @types.SqlError {
    match e {
      ScalarSub(sub) =>
        match
          cor.try_scalar_item(sub, extra_schemas, extra_batches, extra_items) {
          Some(col) => col
          None => e
        }
      Arith(op, l, r) => Arith(op, walk(l), walk(r))
      Cmp(op, l, r) => Cmp(op, walk(l), walk(r))
      And(l, r) => And(walk(l), walk(r))
      Or(l, r) => Or(walk(l), walk(r))
      Not(x) => Not(walk(x))
      Between(v, lo, hi) => Between(walk(v), walk(lo), walk(hi))
      In(v, items) => {
        let new_items : Array[LExpr] = []
        for item in items {
          new_items.push(walk(item))
        }
        In(walk(v), new_items)
      }
      NotIn(v, items) => {
        let new_items : Array[LExpr] = []
        for item in items {
          new_items.push(walk(item))
        }
        NotIn(walk(v), new_items)
      }
      Like(v, pat) => Like(walk(v), pat)
      NotLike(v, pat) => NotLike(walk(v), pat)
      IsNull(v, n) => IsNull(walk(v), n)
      Extract(f, x) => Extract(f, walk(x))
      Case(whens, else_) => {
        let new_whens : Array[(LExpr, LExpr)] = []
        for w in whens {
          new_whens.push((walk(w.0), walk(w.1)))
        }
        let new_else = match else_ {
          Some(x) => Some(walk(x))
          None => None
        }
        Case(new_whens, new_else)
      }
      Func(name, args) => {
        let new_args : Array[LExpr] = []
        for a in args {
          new_args.push(walk(a))
        }
        Func(name, new_args)
      }
      Cast(x, dt) => Cast(walk(x), dt)
      IntervalLit(_, _) => e
      Col(_) | ColQ(_, _) | Lit(_) | Star => e
      Agg(f, inner) =>
        match inner {
          Some(x) => Agg(f, Some(walk(x)))
          None => Agg(f, None)
        }
      InSelect(_, _, _) | Exists(_, _) => e
    }
  }

  walk(e)
}

///|
/// Build the synthetic table, run the decorrelated inner query, and
/// return the semi/anti FromItem. When check_null_in_key is set (NOT
/// IN) a NULL in the inner key column poisons the whole conjunct into
/// a constant false.
fn Correlator::finish_semi(
  self : Correlator,
  inner_from : Array[FromItem],
  pairs : Array[(LExpr, LExpr)],
  inner_filter : Array[LExpr],
  residual : Array[LExpr],
  negated : Bool,
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
  check_null_in_key : Bool,
  from_exists : Bool,
  kept : Array[LExpr],
) -> FromItem? raise @types.SqlError {
  let name = "__semi\{self.counter}"
  self.counter = self.counter + 1
  // residual conjuncts may reference inner columns: lift every distinct
  // inner reference into its own synthetic column so the residual can
  // be evaluated over (outer row, inner row)
  let ref_names : Array[String] = [] // synthetic column per lifted ref
  let ref_exprs : Array[LExpr] = [] // the inner expression behind it
  let ref_keys : Array[String] = [] // canonical "qual.col" / "col" key
  for r in residual {
    lift_inner_refs(r, self, pairs.length(), ref_names, ref_exprs, ref_keys)
  }
  // the inner side of every pair becomes one output column
  let items : Array[SelectItem] = []
  for i, p in pairs {
    items.push({ expr: p.0, label: Some("__sk\{i}"), })
  }
  for i, e in ref_exprs {
    items.push({ expr: e, label: Some("__sk\{pairs.length() + i}"), })
  }
  let filter : LExpr? = match inner_filter.length() {
    0 => None
    _ => {
      let mut acc = inner_filter[0]
      for i in 1..<inner_filter.length() {
        acc = And(acc, inner_filter[i])
      }
      Some(acc)
    }
  }
  let inner_sel : Select = {
    from: inner_from,
    filter,
    group_by: [],
    having: None,
    items,
    order_by: [],
    limit: None,
    offset: None,
    distinct: false,
    setop: None,
  }
  let inner = run_parsed(inner_sel, self.catalog)
  // NOT IN poison: a NULL anywhere in the inner key column makes every
  // comparison unknown, so the whole conjunct becomes constant false
  if check_null_in_key && negated {
    for r in 0..<inner.row_count() {
      if inner.get(r, 0) is @types.Null {
        kept.push(Lit(@types.Boolean(false)))
        return None
      }
    }
  }
  // rewrite the residual's inner references onto the pseudo columns
  let rewritten : Array[LExpr] = []
  for r in residual {
    rewritten.push(substitute_inner_refs(r, name, ref_keys, ref_names))
  }
  // ON: outer expr = pseudo column, AND-chained; the rewritten residual
  // rides along — plan_step classifies it as the step residual
  let on : LExpr = if pairs.length() == 1 && rewritten.length() == 0 {
    Cmp(@types.Eq, pairs[0].1, ColQ(name, "__sk0"))
  } else {
    let mut acc : LExpr = Cmp(@types.Eq, pairs[0].1, ColQ(name, "__sk0"))
    for i in 1..<pairs.length() {
      acc = And(acc, Cmp(@types.Eq, pairs[i].1, ColQ(name, "__sk\{i}")))
    }
    for r in rewritten {
      acc = And(acc, r)
    }
    acc
  }
  let columns : Array[@catalog.Column] = []
  for i, t in inner.types() {
    columns.push({ name: "__sk\{i}", dtype: t, })
  }
  extra_schemas.push({ table: name, columns, })
  extra_batches.push([inner.batch()])
  Some({
    table: Named(name),
    tbl_alias: Some(name),
    col_aliases: None,
    join: match (negated, from_exists) {
      (true, true) => AntiLoose // NOT EXISTS: only a match drops the row
      (true, false) => Anti // NOT IN: a null probe key is UNKNOWN
      (false, _) => Semi
    },
    on: Some(on),
  })
}

///|
/// Where an expression's references live. Unqualified names resolve to
/// the inner scope first (SQL nearest-scope rule).
fn Correlator::side_of(self : Correlator, e : LExpr) -> RefSide {
  match e {
    Col(name) => self.side_of_name(name)
    ColQ(q, c) => {
      // the qualifier picks the scope outright
      let mut inner_qual = false
      let mut outer_qual = false
      for item in self.sub_items {
        let qual = match item.tbl_alias {
          Some(a) => a
          None =>
            match item.table {
              Named(n) => n
              Sub(_) => ""
            }
        }
        if qual == q {
          inner_qual = true
        }
      }
      for item in self.outer_items {
        let qual = match item.tbl_alias {
          Some(a) => a
          None =>
            match item.table {
              Named(n) => n
              Sub(_) => ""
            }
        }
        if qual == q {
          outer_qual = true
        }
      }
      let _ = c
      if inner_qual {
        Inner
      } else if outer_qual {
        Outer
      } else {
        Unknown
      }
    }
    Lit(_) => NoneSide
    IntervalLit(_, _) => NoneSide
    Arith(_, l, r) => self.side_of(l).merge(self.side_of(r))
    Cmp(_, l, r) => self.side_of(l).merge(self.side_of(r))
    And(l, r) => self.side_of(l).merge(self.side_of(r))
    Or(l, r) => self.side_of(l).merge(self.side_of(r))
    Not(x) => self.side_of(x)
    Between(v, lo, hi) =>
      self.side_of(v).merge(self.side_of(lo)).merge(self.side_of(hi))
    In(v, items) | NotIn(v, items) => {
      let mut s = self.side_of(v)
      for item in items {
        s = s.merge(self.side_of(item))
      }
      s
    }
    Like(v, _) | NotLike(v, _) => self.side_of(v)
    IsNull(v, _) => self.side_of(v)
    Extract(_, x) => self.side_of(x)
    Case(whens, else_) => {
      let mut s : RefSide = NoneSide
      for w in whens {
        s = s.merge(self.side_of(w.0))
        s = s.merge(self.side_of(w.1))
      }
      match else_ {
        Some(e) => s.merge(self.side_of(e))
        None => s
      }
    }
    Func(_, args) => {
      let mut s : RefSide = NoneSide
      for a in args {
        s = s.merge(self.side_of(a))
      }
      s
    }
    Cast(x, _) => self.side_of(x)
    // subqueries inside the inner query are its own business
    ScalarSub(_) => NoneSide
    InSelect(_, _, _) => NoneSide
    Exists(_, _) => NoneSide
    Agg(_, _) => Inner // an aggregate ranges over inner columns
    Star => Unknown
  }
}

///|
fn Correlator::side_of_name(self : Correlator, name : String) -> RefSide {
  for item in self.sub_items {
    match item.table {
      Named(tname) =>
        match self.catalog.lookup(tname) {
          Some(entry) =>
            for c in entry.schema.columns {
              if c.name == name {
                return Inner
              }
            }
          None => ()
        }
      Sub(_) => ()
    }
  }
  for item in self.outer_items {
    match item.table {
      Named(tname) =>
        match self.catalog.lookup(tname) {
          Some(entry) =>
            for c in entry.schema.columns {
              if c.name == name {
                return Outer
              }
            }
          None => ()
        }
      Sub(_) => ()
    }
  }
  Unknown
}

///|
/// Canonical key of a column reference for the lift table.
fn ref_key(qual : String?, name : String) -> String {
  match qual {
    Some(q) => "\{q}.\{name}"
    None => name
  }
}

///|
/// Recursively collect distinct inner-scope column references. The
/// synthetic names start at `base` = the pair-key column count, so they
/// line up with the items finish_semi appends after the keys.
fn lift_inner_refs(
  e : LExpr,
  cor : Correlator,
  base : Int,
  ref_names : Array[String],
  ref_exprs : Array[LExpr],
  ref_keys : Array[String],
) -> Unit {
  fn visit(e : LExpr) -> Unit {
    match e {
      Col(name) => {
        let key = ref_key(None, name)
        let mut seen = false
        for k in ref_keys {
          if k == key {
            seen = true
          }
        }
        if !seen && cor.side_of(Col(name)) is Inner {
          ref_names.push("__sk\{base + ref_keys.length()}")
          ref_exprs.push(Col(name))
          ref_keys.push(key)
        }
      }
      ColQ(q, c) => {
        let key = ref_key(Some(q), c)
        let mut seen = false
        for k in ref_keys {
          if k == key {
            seen = true
          }
        }
        if !seen && cor.side_of(ColQ(q, c)) is Inner {
          ref_names.push("__sk\{base + ref_keys.length()}")
          ref_exprs.push(ColQ(q, c))
          ref_keys.push(key)
        }
      }
      Lit(_) => ()
      IntervalLit(_, _) => ()
      Arith(_, l, r) => {
        visit(l)
        visit(r)
      }
      Cmp(_, l, r) => {
        visit(l)
        visit(r)
      }
      And(l, r) => {
        visit(l)
        visit(r)
      }
      Or(l, r) => {
        visit(l)
        visit(r)
      }
      Not(x) => visit(x)
      Between(v, lo, hi) => {
        visit(v)
        visit(lo)
        visit(hi)
      }
      In(v, items) | NotIn(v, items) => {
        visit(v)
        for item in items {
          visit(item)
        }
      }
      Like(v, _) | NotLike(v, _) => visit(v)
      IsNull(v, _) => visit(v)
      Extract(_, x) => visit(x)
      Case(whens, else_) => {
        for w in whens {
          visit(w.0)
          visit(w.1)
        }
        match else_ {
          Some(x) => visit(x)
          None => ()
        }
      }
      Func(_, args) =>
        for a in args {
          visit(a)
        }
      Cast(x, _) => visit(x)
      ScalarSub(_) => ()
      InSelect(_, _, _) => ()
      Exists(_, _) => ()
      Agg(_, inner) =>
        match inner {
          Some(x) => visit(x)
          None => ()
        }
      Star => ()
    }
  }
  visit(e)
}

///|
/// Recursively replace lifted inner references with their pseudo-table
/// columns. Outer references pass through untouched.
fn substitute_inner_refs(
  e : LExpr,
  pseudo : String,
  ref_keys : Array[String],
  ref_names : Array[String],
) -> LExpr {
  match e {
    Col(c) => {
      let key = ref_key(None, c)
      for i, k in ref_keys {
        if k == key {
          return ColQ(pseudo, ref_names[i])
        }
      }
      e
    }
    ColQ(q, c) => {
      let key = ref_key(Some(q), c)
      for i, k in ref_keys {
        if k == key {
          return ColQ(pseudo, ref_names[i])
        }
      }
      e
    }
    Lit(_) => e
    IntervalLit(_, _) => e
    Arith(op, l, r) =>
      Arith(
        op,
        substitute_inner_refs(l, pseudo, ref_keys, ref_names),
        substitute_inner_refs(r, pseudo, ref_keys, ref_names),
      )
    Cmp(op, l, r) =>
      Cmp(
        op,
        substitute_inner_refs(l, pseudo, ref_keys, ref_names),
        substitute_inner_refs(r, pseudo, ref_keys, ref_names),
      )
    And(l, r) =>
      And(
        substitute_inner_refs(l, pseudo, ref_keys, ref_names),
        substitute_inner_refs(r, pseudo, ref_keys, ref_names),
      )
    Or(l, r) =>
      Or(
        substitute_inner_refs(l, pseudo, ref_keys, ref_names),
        substitute_inner_refs(r, pseudo, ref_keys, ref_names),
      )
    Not(x) => Not(substitute_inner_refs(x, pseudo, ref_keys, ref_names))
    Between(v, lo, hi) =>
      Between(
        substitute_inner_refs(v, pseudo, ref_keys, ref_names),
        substitute_inner_refs(lo, pseudo, ref_keys, ref_names),
        substitute_inner_refs(hi, pseudo, ref_keys, ref_names),
      )
    In(v, items) => {
      let new_items : Array[LExpr] = []
      for item in items {
        new_items.push(substitute_inner_refs(item, pseudo, ref_keys, ref_names))
      }
      In(substitute_inner_refs(v, pseudo, ref_keys, ref_names), new_items)
    }
    NotIn(v, items) => {
      let new_items : Array[LExpr] = []
      for item in items {
        new_items.push(substitute_inner_refs(item, pseudo, ref_keys, ref_names))
      }
      NotIn(substitute_inner_refs(v, pseudo, ref_keys, ref_names), new_items)
    }
    Like(v, p) => Like(substitute_inner_refs(v, pseudo, ref_keys, ref_names), p)
    NotLike(v, p) =>
      NotLike(substitute_inner_refs(v, pseudo, ref_keys, ref_names), p)
    IsNull(v, n) =>
      IsNull(substitute_inner_refs(v, pseudo, ref_keys, ref_names), n)
    Extract(f, x) =>
      Extract(f, substitute_inner_refs(x, pseudo, ref_keys, ref_names))
    Case(whens, else_) => {
      let new_whens : Array[(LExpr, LExpr)] = []
      for w in whens {
        new_whens.push(
          (
            substitute_inner_refs(w.0, pseudo, ref_keys, ref_names),
            substitute_inner_refs(w.1, pseudo, ref_keys, ref_names),
          ),
        )
      }
      let new_else = match else_ {
        Some(x) => Some(substitute_inner_refs(x, pseudo, ref_keys, ref_names))
        None => None
      }
      Case(new_whens, new_else)
    }
    Func(name, args) => {
      let new_args : Array[LExpr] = []
      for a in args {
        new_args.push(substitute_inner_refs(a, pseudo, ref_keys, ref_names))
      }
      Func(name, new_args)
    }
    Cast(x, dt) =>
      Cast(substitute_inner_refs(x, pseudo, ref_keys, ref_names), dt)
    ScalarSub(_) | InSelect(_, _, _) | Exists(_, _) => e
    Agg(f, inner) =>
      match inner {
        Some(x) =>
          Agg(f, Some(substitute_inner_refs(x, pseudo, ref_keys, ref_names)))
        None => Agg(f, None)
      }
    Star => e
  }
}
