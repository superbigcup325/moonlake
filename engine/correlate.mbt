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
  outer_items : Array[@sql.FromItem]
  mut sub_items : Array[@sql.FromItem] // the inner query's FROM, per attempt
  mut counter : Int32
  opts : ExecOptions
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
fn RefSide::same(self : RefSide, other : RefSide) -> Bool {
  match (self, other) {
    (NoneSide, NoneSide) | (Inner, Inner) | (Outer, Outer) => true
    (Mixed, Mixed) | (Unknown, Unknown) => true
    _ => false
  }
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
/// What classifying one semi/anti conjunct produced. `SemiFalse` is a conjunct
/// that is constant FALSE: `NOT IN` against an inner key column that holds a
/// NULL has no true row at all, because every comparison with that NULL is
/// unknown. That is an answer, not a refusal. The other negative outcomes mean
/// "the rewriter cannot take this shape", which the caller answers by naming
/// the limit.
priv enum SemiOutcome {
  SemiJoin(@sql.FromItem)
  SemiFalse
  SemiUnsupported
}

///|
/// Rewrite correlated EXISTS / IN conjuncts into semi/anti joins.
/// Returns the rewritten select plus the synthetic tables (schemas and
/// their pre-executed batches, aligned with the appended FromItems).
fn decorrelate(
  sel : @sql.Select,
  catalog : @catalog.Catalog,
  opts : ExecOptions,
) -> (@sql.Select, Array[@catalog.TableSchema], Array[Array[@types.DataBatch]]) raise @types.SqlError {
  let extra_schemas : Array[@catalog.TableSchema] = []
  let extra_batches : Array[Array[@types.DataBatch]] = []
  let cor : Correlator = {
    catalog,
    outer_items: sel.from,
    sub_items: [],
    counter: 0,
    opts,
  }
  // select items are walked even without a WHERE clause: correlated
  // scalar subqueries live there too
  let scalar_items : Array[@sql.FromItem] = []
  // grouping the outer query pins its select list to the group keys, so a
  // correlated subquery there has no column of its own to land in: it would
  // have to be part of the GROUP BY. Refuse it by name rather than let the
  // synthetic column be the error the user reads.
  if sel.group_by.length() > 0 {
    for it in sel.items {
      if cor.contains_correlated(it.expr) {
        raise @types.SqlError::Bind(
          "a correlated subquery in the select list of a query with GROUP BY cannot be decorrelated: its value would have to appear in the GROUP BY — rewrite it as a join",
        )
      }
    }
  }
  // the rewriter reaches the WHERE clause and the select list; a subquery in a
  // HAVING clause runs against grouped rows and one in a JOIN ON runs before
  // the table it would need, so both are refused by name instead of surfacing
  // as "unknown table or alias <outer> in FROM"
  match sel.having {
    Some(h) =>
      if cor.contains_correlated(h) {
        raise @types.SqlError::Bind(
          "a correlated subquery in a HAVING clause cannot be decorrelated: it would have to be evaluated against grouped rows — rewrite it as a join",
        )
      }
    None => ()
  }
  for it in sel.from {
    match it.on {
      Some(on) =>
        if cor.contains_correlated(on) {
          raise @types.SqlError::Bind(
            "a correlated subquery in a JOIN ON clause cannot be decorrelated: the rewritten table would join after the clause that reads it — rewrite it as a join",
          )
        }
      None => ()
    }
  }
  let new_exprs : Array[@sql.LExpr] = []
  let mut items_rewritten = false
  for it in sel.items {
    // a select item without a correlated subquery needs no walk at all, which
    // is every item of nearly every query
    let rewritten = if cor.contains_correlated(it.expr) {
      rewrite_correlated(
        it.expr,
        cor,
        extra_schemas,
        extra_batches,
        scalar_items,
      )
    } else {
      it.expr
    }
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
  let kept : Array[@sql.LExpr] = []
  let extra_items : Array[@sql.FromItem] = []
  let mut resolved_differs = false
  for cj in conjuncts {
    // NOT EXISTS / NOT IN arrive as Not wrappers: flip the negation
    let lexpr = match cj.lexpr {
      Not(Exists(sub, negated)) => @sql.Exists(sub, !negated)
      Not(InSelect(v, sub, negated)) => @sql.InSelect(v, sub, !negated)
      other => other
    }
    match lexpr {
      Exists(sub, negated) =>
        match cor.try_exists(sub, negated, extra_schemas, extra_batches) {
          SemiJoin(item) => extra_items.push(item)
          SemiFalse => {
            resolved_differs = true
            kept.push(Lit(@types.Boolean(false)))
          }
          SemiUnsupported => {
            cor.reject_unsupported_correlation(sub)
            kept.push(lexpr)
          }
        }
      InSelect(v, sub, negated) =>
        match cor.try_in(v, sub, negated, extra_schemas, extra_batches) {
          SemiJoin(item) => extra_items.push(item)
          // NOT IN against a set that holds a NULL: no outer row can pass
          SemiFalse => {
            resolved_differs = true
            kept.push(Lit(@types.Boolean(false)))
          }
          SemiUnsupported => {
            cor.reject_unsupported_correlation(sub)
            kept.push(lexpr)
          }
        }
      Cmp(op, outer_e, ScalarSub(sub)) =>
        match
          cor.try_scalar(op, outer_e, sub, extra_schemas, extra_batches, kept) {
          Some(item) => extra_items.push(item)
          None => {
            cor.reject_unsupported_correlation(sub)
            kept.push(lexpr)
          }
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
          None => {
            cor.reject_unsupported_correlation(sub)
            kept.push(lexpr)
          }
        }
      _ => kept.push(lexpr)
    }
  }
  // whatever the semi-join pass left behind still may hold a correlated
  // subquery: rewrite those as expressions over their synthetic table, which
  // is what makes a correlation under NOT / OR / a bare boolean work
  let resolved : Array[@sql.LExpr] = []
  for k in kept {
    // the same short-circuit: only a conjunct that actually holds a
    // correlated subquery pays for the walk
    if cor.contains_correlated(k) {
      resolved.push(
        rewrite_correlated(k, cor, extra_schemas, extra_batches, extra_items),
      )
    } else {
      resolved.push(k)
    }
  }
  // a conjunct that became constant false still rewrites the filter, so the
  // early exit below must not hand the original select back
  if extra_items.length() == 0 &&
    scalar_items.length() == 0 &&
    !resolved_differs {
    return (sel, extra_schemas, extra_batches)
  }
  let filter : @sql.LExpr? = match resolved.length() {
    0 => None
    _ => {
      let mut acc = resolved[0]
      for i in 1..<resolved.length() {
        acc = And(acc, resolved[i])
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
    let out : Array[@sql.SelectItem] = []
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
  sub : @sql.Select,
) -> (Array[(@sql.LExpr, @sql.LExpr)], Array[@sql.LExpr], Array[@sql.LExpr])? {
  // a windowed subquery is never rewritten: lifting touches the WHERE
  // conjuncts and the select list, not the window definitions, so a
  // correlated one would silently keep outer references. Uncorrelated
  // windowed subqueries bail here too and run normally via the binder.
  if sub.windows.length() > 0 {
    return None
  }
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
  let pairs : Array[(@sql.LExpr, @sql.LExpr)] = []
  let inner_only : Array[@sql.LExpr] = []
  let residual : Array[@sql.LExpr] = []
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
            // spanning and purely-outer conjuncts fall to the join residual
            // (both sides of a semi/anti ON can read the probe row), and an
            // unresolved name is unsupported
            match (self.side_of(a), self.side_of(b)) {
              (Inner, Inner)
              | (Inner, NoneSide)
              | (NoneSide, Inner)
              | (NoneSide, NoneSide) => inner_only.push(cj)
              (Mixed, _) | (_, Mixed) => residual.push(cj)
              (Outer, Outer) | (Outer, NoneSide) | (NoneSide, Outer) =>
                residual.push(cj)
              (_, _) => return None
            }
        }
      }
      other =>
        match self.side_of(other) {
          Inner => inner_only.push(other)
          // outer-only conjuncts are parameters of the correlation: the
          // join residual (and the theta aggregate) can read the probe row
          Mixed | Outer => residual.push(other)
          _ => return None // unknown: unsupported
        }
    }
  }
  Some((pairs, inner_only, residual))
}

///|
/// Classify an EXISTS subquery. Some(item) replaces the conjunct with
/// a SEMI / ANTI @sql.FromItem against a fresh synthetic table appended to
/// the two arrays; None leaves the conjunct alone.
fn Correlator::try_exists(
  self : Correlator,
  sub : @sql.Select,
  _negated : Bool,
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
) -> SemiOutcome raise @types.SqlError {
  if sub.limit is Some(_) ||
    sub.offset is Some(_) ||
    sub.distinct ||
    sub.setop is Some(_) {
    return SemiUnsupported
  }
  // EXISTS with a HAVING filter: group the inner query by the
  // correlation keys (keeping the HAVING), then the semi/anti join
  // answers "does a satisfying group exist for this outer row?"
  if sub.having is Some(_) {
    // the grouped flavor regroups by the correlation keys, so it can only
    // keep a HAVING that does not have the user's own grouping to run over —
    // unless that grouping is exactly those keys, where regrouping is the
    // identity
    if sub.group_by.length() > 0 {
      let (pairs, _, _) = match self.prepare(sub) {
        Some(triple) => triple
        None => return SemiUnsupported
      }
      if !same_grouping(sub.group_by, pairs) {
        return SemiUnsupported
      }
    }
    return match
      self.try_exists_grouped(sub, _negated, extra_schemas, extra_batches) {
      Some(item) => SemiJoin(item)
      None => SemiUnsupported
    }
  }
  // No HAVING: a GROUP BY cannot change whether a matching row exists
  // (`select 1 from t where ... group by v` has a row iff the filtered input
  // does), so it is dropped rather than refused.
  match self.prepare(sub) {
    Some((pairs, inner_filter, residual)) =>
      // an empty pairing is still a correlation when a spanning conjunct
      // remains: the conjunct becomes the join's whole ON, so the join has
      // no hash keys and pairs every outer row with every inner one
      // (`EXISTS (SELECT 1 FROM i WHERE i.v > o.v)`). With neither part the
      // subquery is uncorrelated and the binder folds it eagerly.
      if pairs.length() == 0 && residual.length() == 0 {
        SemiUnsupported
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
        )
      }
    None => SemiUnsupported
  }
}

///|
/// Whether the user's GROUP BY is exactly the correlation keys. The grouped
/// EXISTS flavor regroups by those keys, which keeps the HAVING's meaning only
/// when the two groupings agree.
fn same_grouping(
  group_by : Array[@sql.LExpr],
  pairs : Array[(@sql.LExpr, @sql.LExpr)],
) -> Bool {
  if group_by.length() != pairs.length() {
    return false
  }
  for g in group_by {
    let mut found = false
    for p in pairs {
      if p.0 == g {
        found = true
      }
    }
    if !found {
      return false
    }
  }
  true
}

///|
/// The HAVING flavor of EXISTS: the inner query groups by the
/// correlation keys with the HAVING kept verbatim; the select list is
/// discarded (EXISTS only asks whether a satisfying group exists).
/// A NULL correlation key never matches any group, so NOT EXISTS
/// keeps those rows (AntiLoose).
fn Correlator::try_exists_grouped(
  self : Correlator,
  sub : @sql.Select,
  negated : Bool,
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
) -> @sql.FromItem? raise @types.SqlError {
  // the select list is discarded: EXISTS only asks whether a group
  // satisfying the HAVING exists, so any arity is fine
  let (pairs, inner_only, residual) = match self.prepare(sub) {
    Some(triple) => triple
    None => return None
  }
  if pairs.length() == 0 || residual.length() > 0 {
    return None
  }
  let items : Array[@sql.SelectItem] = []
  let group_by : Array[@sql.LExpr] = []
  for p in pairs {
    items.push({ expr: p.0, label: Some("__sk\{group_by.length()}"), })
    group_by.push(p.0)
  }
  let filter : @sql.LExpr? = match inner_only.length() {
    0 => None
    _ => {
      let mut acc = inner_only[0]
      for i in 1..<inner_only.length() {
        acc = And(acc, inner_only[i])
      }
      Some(acc)
    }
  }
  let inner_sel : @sql.Select = {
    from: sub.from,
    filter,
    group_by,
    having: sub.having,
    items,
    order_by: [],
    limit: None,
    offset: None,
    distinct: false,
    windows: [],
    setop: None,
  }
  let inner = run_parsed(inner_sel, self.catalog, [], self.opts)
  let name = "__semi\{self.counter}"
  self.counter = self.counter + 1
  let columns : Array[@catalog.Column] = []
  for i, t in inner.types() {
    columns.push({ name: "__sk\{i}", dtype: t, })
  }
  extra_schemas.push({ table: name, columns, })
  extra_batches.push([inner.batch()])
  let mut on : @sql.LExpr = Cmp(@types.Eq, pairs[0].1, ColQ(name, "__sk0"))
  for i in 1..<pairs.length() {
    on = And(on, Cmp(@types.Eq, pairs[i].1, ColQ(name, "__sk\{i}")))
  }
  Some({
    table: Named(name),
    tbl_alias: Some(name),
    col_aliases: None,
    join: if negated {
      AntiLoose
    } else {
      Semi
    },
    on: Some(on),
  })
}

///|
/// Classify an IN subquery: the select list must be a single
/// expression, which pairs with the outer value expression.
fn Correlator::try_in(
  self : Correlator,
  v : @sql.LExpr,
  sub : @sql.Select,
  negated : Bool,
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
) -> SemiOutcome raise @types.SqlError {
  if !(sub.group_by.length() == 0) ||
    sub.having is Some(_) ||
    sub.limit is Some(_) ||
    sub.offset is Some(_) ||
    sub.distinct ||
    sub.setop is Some(_) {
    return SemiUnsupported
  }
  if sub.items.length() != 1 {
    return SemiUnsupported
  }
  // the outer value must not reference the inner tables
  match self.side_of(v) {
    Outer | NoneSide => ()
    _ => return SemiUnsupported
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
      )
    }
    None => SemiUnsupported
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
  outer_e : @sql.LExpr,
  sub : @sql.Select,
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
  kept : Array[@sql.LExpr],
) -> @sql.FromItem? raise @types.SqlError {
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
  if pairs.length() == 0 && residual.length() == 0 {
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
  // a correlation that is not a conjunction of equalities has no keys to
  // group by, so its aggregate is keyed by the outer row's identity instead
  let general = residual.length() > 0 || pairs.length() == 0
  let (item, name) = if general {
    match
      self.build_theta_scalar_table(
        sub, pairs, inner_only, residual, extra_schemas, extra_batches,
      ) {
      Some(pair) => pair
      None => return None
    }
  } else {
    self.build_scalar_table(
      sub, pairs, inner_only, extra_schemas, extra_batches,
    )
  }
  // the rewritten comparison stays in the WHERE pool and classifies as
  // the step residual (or a hash key when the comparison is an equality)
  let idx = if general { 1 } else { pairs.length() }
  kept.push(Cmp(op, outer_e, scalar_value(name, idx, sub.items[0].expr)))
  Some(item)
}

///|
/// What a decorrelated scalar subquery stands for at its use site. The
/// synthetic table is attached with a LEFT JOIN, so an outer row the inner
/// query had no group for probes NULL — but a scalar aggregate over an empty
/// group is not NULL for the count family: `(SELECT count(*) FROM t WHERE
/// t.k = x.k)` is 0 when nothing matches, as in SQL and DuckDB. Every other
/// aggregate's empty value is NULL, which the join already yields.
fn scalar_value(
  name : String,
  idx : Int32,
  item_expr : @sql.LExpr,
) -> @sql.LExpr {
  let col : @sql.LExpr = ColQ(name, "__sk\{idx}")
  match item_expr {
    Agg(Count | CountStar | CountDistinct, _) =>
      Func("coalesce", [col, Lit(@types.Int64(0L))])
    _ => col
  }
}

///|
/// Shared by the WHERE-conjunct and select-item scalar rewrites: run
/// the subquery grouped by the correlation keys as a synthetic LEFT
/// join table; returns the @sql.FromItem and the synthetic table name (the
/// value column is __sk<pairs.length()>).
fn Correlator::build_scalar_table(
  self : Correlator,
  sub : @sql.Select,
  pairs : Array[(@sql.LExpr, @sql.LExpr)],
  inner_only : Array[@sql.LExpr],
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
) -> (@sql.FromItem, String) raise @types.SqlError {
  let items : Array[@sql.SelectItem] = []
  let group_by : Array[@sql.LExpr] = []
  for p in pairs {
    items.push({ expr: p.0, label: Some("__sk\{group_by.length()}"), })
    group_by.push(p.0)
  }
  items.push({ expr: sub.items[0].expr, label: Some("__sk\{pairs.length()}"), })
  let filter : @sql.LExpr? = match inner_only.length() {
    0 => None
    _ => {
      let mut acc = inner_only[0]
      for i in 1..<inner_only.length() {
        acc = And(acc, inner_only[i])
      }
      Some(acc)
    }
  }
  let inner_sel : @sql.Select = {
    from: sub.from,
    filter,
    group_by,
    having: None,
    items,
    order_by: [],
    limit: None,
    offset: None,
    distinct: false,
    windows: [],
    setop: None,
  }
  let inner = run_parsed(inner_sel, self.catalog, [], self.opts)
  let name = "__scalar\{self.counter}"
  self.counter = self.counter + 1
  let columns : Array[@catalog.Column] = []
  for i, t in inner.types() {
    columns.push({ name: "__sk\{i}", dtype: t, })
  }
  extra_schemas.push({ table: name, columns, })
  extra_batches.push([inner.batch()])
  let mut on : @sql.LExpr = Cmp(@types.Eq, pairs[0].1, ColQ(name, "__sk0"))
  for i in 1..<pairs.length() {
    on = And(on, Cmp(@types.Eq, pairs[i].1, ColQ(name, "__sk\{i}")))
  }
  let item : @sql.FromItem = {
    table: Named(name),
    tbl_alias: Some(name),
    col_aliases: None,
    join: Left,
    on: Some(on),
  }
  (item, name)
}

///|
/// The internal function that renders a row of values as one canonical,
/// NULL-safe string: type-tagged and length-prefixed per column, so two rows
/// compare equal by plain `=` exactly when their values are equal (a NULL is
/// its own tag, not an unknown). It is the only identity machinery the
/// general correlation needs; binder and evaluator know the name.
const ROW_KEY : String = "__row_key"

///|
fn conjoin_lexprs(xs : Array[@sql.LExpr]) -> @sql.LExpr? {
  match xs.length() {
    0 => None
    _ => {
      let mut acc = xs[0]
      for i in 1..<xs.length() {
        acc = And(acc, xs[i])
      }
      Some(acc)
    }
  }
}

///|
/// The general-correlation table. A subquery whose linking predicate is not a
/// conjunction of equalities has no key the inner side could be grouped by, so
/// nothing can be precomputed per correlation key the way
/// `build_scalar_table` does it: the aggregate genuinely depends on the outer
/// row's numbers. Instead the aggregates run once, eagerly, over the *distinct*
/// combinations of the outer expressions the subquery reads, and that table is
/// left-joined back on one canonical row key. Deduplication is what keeps the
/// result honest — without it a repeated outer row would multiply the inner
/// matches and a `count(*)` would double. The join inside is a theta join (a
/// nested loop over the distinct outer combinations), which is the price of
/// the general shape; the equality flavor stays on the hash-keyed path.
///
/// `values` are the aggregate expressions to compute per group; value `i`
/// lands in synthetic column `__sk<i + 1>` and column `__sk0` carries the key.
fn Correlator::build_theta_table(
  self : Correlator,
  sub : @sql.Select,
  pairs : Array[(@sql.LExpr, @sql.LExpr)],
  inner_only : Array[@sql.LExpr],
  residual : Array[@sql.LExpr],
  values : Array[@sql.LExpr],
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
) -> (@sql.FromItem, String)? raise @types.SqlError {
  if sub.from.length() == 0 || values.length() == 0 {
    return None // a FROM-less subquery cannot be correlated
  }
  // the outer expressions the predicate and the aggregates read: together they
  // tell two outer rows apart as far as this subquery is concerned, so they are
  // the identity the eager table is grouped and joined by
  let ref_keys : Array[String] = []
  let ref_exprs : Array[@sql.LExpr] = []
  let ref_names : Array[String] = []
  for p in pairs {
    lift_refs(p.1, self, Outer, "__c", 0, ref_names, ref_exprs, ref_keys)
  }
  for r in residual {
    lift_refs(r, self, Outer, "__c", 0, ref_names, ref_exprs, ref_keys)
  }
  for v in values {
    lift_refs(v, self, Outer, "__c", 0, ref_names, ref_exprs, ref_keys)
  }
  if ref_exprs.length() == 0 {
    return None
  }
  let tag = self.counter
  self.counter = self.counter + 1
  let dname = "__d\{tag}"
  let name = "__theta\{tag}"
  // the distinct outer combinations the inner rows are matched against
  let dedup_items : Array[@sql.SelectItem] = []
  for i, e in ref_exprs {
    dedup_items.push({ expr: e, label: Some(ref_names[i]), })
  }
  let outer_from : Array[@sql.FromItem] = []
  for it in self.outer_items {
    outer_from.push(it)
  }
  let dedup : @sql.Select = {
    from: outer_from,
    filter: None,
    group_by: [],
    having: None,
    items: dedup_items,
    order_by: [],
    limit: None,
    offset: None,
    distinct: true,
    windows: [],
    setop: None,
  }
  // from here the correlation reads the deduplicated table: the spanning
  // conjuncts and the value expressions wipe their outer references over to it
  let key_args : Array[@sql.LExpr] = []
  for n in ref_names {
    key_args.push(ColQ(dname, n))
  }
  let key_expr : @sql.LExpr = Func(ROW_KEY, key_args)
  let conj : Array[@sql.LExpr] = []
  for p in pairs {
    conj.push(Cmp(@types.Eq, p.0, p.1))
  }
  for r in residual {
    conj.push(r)
  }
  for c in inner_only {
    conj.push(c)
  }
  let rewritten : Array[@sql.LExpr] = []
  for c in conj {
    rewritten.push(substitute_refs(c, dname, ref_keys, ref_names))
  }
  let filter : @sql.LExpr? = conjoin_lexprs(rewritten)
  let eager_items : Array[@sql.SelectItem] = [
    { expr: key_expr, label: Some("__ok"), },
  ]
  for i, v in values {
    eager_items.push({
      expr: substitute_refs(v, dname, ref_keys, ref_names),
      label: Some("__sk\{i + 1}"),
    })
  }
  // the inner FROM joins as written (its own joins and ONs kept); the
  // deduplicated outer side is the first item, so it probes the inner side
  let eager_from : Array[@sql.FromItem] = [
    {
      table: Sub(dedup),
      tbl_alias: Some(dname),
      col_aliases: None,
      join: Inner,
      on: None,
    },
  ]
  for it in sub.from {
    eager_from.push(it)
  }
  let eager : @sql.Select = {
    from: eager_from,
    filter,
    group_by: [key_expr],
    having: None,
    items: eager_items,
    order_by: [],
    limit: None,
    offset: None,
    distinct: false,
    windows: [],
    setop: None,
  }
  let inner = run_parsed(eager, self.catalog, [], self.opts)
  if inner.types().length() != 1 + values.length() {
    return None // no schema to attach: leave the subquery to the runner
  }
  let columns : Array[@catalog.Column] = []
  for i, t in inner.types() {
    columns.push({ name: "__sk\{i}", dtype: t, })
  }
  extra_schemas.push({ table: name, columns, })
  extra_batches.push([inner.batch()])
  // an inner join above leaves no row for an outer combination the inner side
  // never matched, and the LEFT join here then extends it with NULLs — which
  // is exactly the scalar aggregate's empty value (0 for the count family)
  let join_on : @sql.LExpr = Cmp(
    @types.Eq,
    Func(ROW_KEY, ref_exprs),
    ColQ(name, "__sk0"),
  )
  let item : @sql.FromItem = {
    table: Named(name),
    tbl_alias: Some(name),
    col_aliases: None,
    join: Left,
    on: Some(join_on),
  }
  Some((item, name))
}

///|
/// The scalar aggregate of a correlation that is not a conjunction of
/// equalities — one value expression, in column `__sk1`.
fn Correlator::build_theta_scalar_table(
  self : Correlator,
  sub : @sql.Select,
  pairs : Array[(@sql.LExpr, @sql.LExpr)],
  inner_only : Array[@sql.LExpr],
  residual : Array[@sql.LExpr],
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
) -> (@sql.FromItem, String)? raise @types.SqlError {
  self.build_theta_table(
    sub,
    pairs,
    inner_only,
    residual,
    [sub.items[0].expr],
    extra_schemas,
    extra_batches,
  )
}

///|
/// A correlation value that is only meaningful as an aggregate: refuse the
/// subquery shapes whose semantics the eager aggregate would not keep.
fn plain_agg_sub(sub : @sql.Select) -> Bool {
  sub.group_by.length() == 0 &&
  sub.having is None &&
  sub.limit is None &&
  sub.offset is None &&
  !sub.distinct &&
  sub.setop is None
}

///|
/// `EXISTS (sub)` as a value: the count of satisfying inner rows, `> 0`.
/// The `sum`/`count` of an empty group is NULL and coalesces to 0, so an outer
/// row with no match reads FALSE rather than NULL — as EXISTS must.
fn Correlator::theta_exists(
  self : Correlator,
  sub : @sql.Select,
  negated : Bool,
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
  extra_items : Array[@sql.FromItem],
) -> @sql.LExpr? raise @types.SqlError {
  // a HAVING filter needs the grouped flavor (the WHERE path has it); a
  // LIMIT/DISTINCT/set operation changes which rows exist at all
  if !plain_agg_sub(sub) {
    return None
  }
  let (pairs, inner_only, residual) = match self.prepare(sub) {
    Some(triple) => triple
    None => return None
  }
  if pairs.length() == 0 && residual.length() == 0 {
    return None // uncorrelated: the runner folds it eagerly
  }
  let (item, name) = match
    self.build_theta_table(
      sub,
      pairs,
      inner_only,
      residual,
      [Agg(CountStar, None)],
      extra_schemas,
      extra_batches,
    ) {
    Some(pair) => pair
    None => return None
  }
  extra_items.push(item)
  let count : @sql.LExpr = Func("coalesce", [
    ColQ(name, "__sk1"),
    Lit(@types.Int64(0L)),
  ])
  let found : @sql.LExpr = Cmp(
    if negated {
      @types.Eq
    } else {
      @types.Gt
    },
    count,
    Lit(@types.Int64(0L)),
  )
  Some(found)
}

///|
/// `probe IN (sub)` as a value, with SQL's three-valued semantics: TRUE on a
/// match, FALSE on no match over a set that is empty or null-free, NULL when
/// the set holds a NULL or the probe itself is NULL. The eager table counts
/// matching rows, all rows, and rows whose value is NULL; the CASE below turns
/// those three counts into the boolean — `NOT IN` is its mirror image.
fn Correlator::theta_in(
  self : Correlator,
  probe : @sql.LExpr,
  sub : @sql.Select,
  negated : Bool,
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
  extra_items : Array[@sql.FromItem],
) -> @sql.LExpr? raise @types.SqlError {
  if !plain_agg_sub(sub) {
    return None
  }
  if sub.items.length() != 1 || contains_agg(sub.items[0].expr) {
    return None
  }
  // `SELECT *` over one one-column table is the same value the IN compares
  // against; anything wider is not a single value at all, so it is left alone
  let value_expr : @sql.LExpr = match sub.items[0].expr {
    Star =>
      match (sub.from.length(), sub.from[0].table) {
        (1, Named(t)) =>
          match self.catalog.lookup(t) {
            Some(entry) =>
              match entry.schema.columns.length() {
                1 =>
                  match sub.from[0].tbl_alias {
                    Some(q) => ColQ(q, entry.schema.columns[0].name)
                    None => ColQ(t, entry.schema.columns[0].name)
                  }
                _ => return None
              }
            None => return None
          }
        _ => return None
      }
    e => e
  }
  let (pairs, inner_only, residual) = match self.prepare(sub) {
    Some(triple) => triple
    None => return None
  }
  if pairs.length() == 0 && residual.length() == 0 {
    return None // uncorrelated: the runner folds it eagerly
  }
  let matches : @sql.LExpr = Agg(
    Sum,
    Some(
      Case(
        [(Cmp(@types.Eq, value_expr, probe), Lit(@types.Int32(1)))],
        Some(Lit(@types.Int32(0))),
      ),
    ),
  )
  let nulls : @sql.LExpr = Agg(
    Sum,
    Some(
      Case(
        [(IsNull(value_expr, false), Lit(@types.Int32(1)))],
        Some(Lit(@types.Int32(0))),
      ),
    ),
  )
  let (item, name) = match
    self.build_theta_table(
      sub,
      pairs,
      inner_only,
      residual,
      [matches, Agg(CountStar, None), nulls],
      extra_schemas,
      extra_batches,
    ) {
    Some(pair) => pair
    None => return None
  }
  extra_items.push(item)
  let zero : @sql.LExpr = Lit(@types.Int64(0L))
  let hit : @sql.LExpr = Cmp(
    @types.Gt,
    Func("coalesce", [ColQ(name, "__sk1"), zero]),
    zero,
  )
  let rows : @sql.LExpr = Cmp(
    @types.Eq,
    Func("coalesce", [ColQ(name, "__sk2"), zero]),
    zero,
  )
  let has_null : @sql.LExpr = Cmp(
    @types.Gt,
    Func("coalesce", [ColQ(name, "__sk3"), zero]),
    zero,
  )
  let probe_null : @sql.LExpr = IsNull(probe, false)
  let unknown : @sql.LExpr = Or(probe_null, has_null)
  let known : @sql.LExpr = Not(unknown)
  let yes : @sql.LExpr = Lit(@types.Boolean(true))
  let no : @sql.LExpr = Lit(@types.Boolean(false))
  // no ELSE: falling off the end yields NULL, which is the unknown answer —
  // the previous branch settles every case that has a definite one
  let value : @sql.LExpr = if negated {
    Case([(rows, yes), (hit, no), (known, yes)], None)
  } else {
    Case([(hit, yes), (rows, no), (known, no)], None)
  }
  Some(value)
}

///|
/// Does the subquery reference a column of the enclosing query? A shape the
/// decorrelator gives up on then reaches the inner bind, which fails with
/// "unknown table or alias <outer> in FROM" — a message that reads as if the
/// outer table were missing rather than as the limit it is, which is why the
/// positions the rewriter cannot reach (HAVING, JOIN ON) and the shapes it
/// cannot handle are named before that happens.
fn Correlator::refs_outer(self : Correlator, sub : @sql.Select) -> Bool {
  let saved = self.sub_items
  self.sub_items = sub.from
  let mut hit = false
  for item in sub.items {
    if self.mentions_outer(item.expr) {
      hit = true
    }
  }
  match sub.filter {
    Some(f) => if self.mentions_outer(f) { hit = true }
    None => ()
  }
  for g in sub.group_by {
    if self.mentions_outer(g) {
      hit = true
    }
  }
  match sub.having {
    Some(h) => if self.mentions_outer(h) { hit = true }
    None => ()
  }
  for o in sub.order_by {
    if self.mentions_outer(o.key) {
      hit = true
    }
  }
  self.sub_items = saved
  hit
}

///|
/// Does the expression itself reference a column of the enclosing query?
/// Recurses into subexpressions; a nested subquery is its own scope and is
/// judged when it is reached. `side_of(e)` alone cannot answer this: it merges
/// a mixed expression into `Mixed`, which is also what an unresolved name next
/// to an outer reference produces.
fn Correlator::mentions_outer(self : Correlator, e : @sql.LExpr) -> Bool {
  match e {
    Col(_) | ColQ(_, _) =>
      match self.side_of(e) {
        Outer => true
        _ => false
      }
    Lit(_) | IntervalLit(_, _) | Star => false
    Arith(_, l, r) | Cmp(_, l, r) | And(l, r) | Or(l, r) =>
      self.mentions_outer(l) || self.mentions_outer(r)
    Not(x) | IsNull(x, _) | Extract(_, x) | Cast(x, _) => self.mentions_outer(x)
    Between(v, lo, hi) =>
      self.mentions_outer(v) ||
      self.mentions_outer(lo) ||
      self.mentions_outer(hi)
    In(v, items) | NotIn(v, items) =>
      self.mentions_outer(v) || self.any_outer(items)
    Like(v, _) | NotLike(v, _) => self.mentions_outer(v)
    Case(whens, else_) => {
      let mut hit = false
      for w in whens {
        if self.mentions_outer(w.0) || self.mentions_outer(w.1) {
          hit = true
        }
      }
      match else_ {
        Some(x) => hit || self.mentions_outer(x)
        None => hit
      }
    }
    Func(_, args) => self.any_outer(args)
    Agg(_, arg) =>
      match arg {
        Some(x) => self.mentions_outer(x)
        None => false
      }
    ScalarSub(_) | InSelect(_, _, _) | Exists(_, _) => false
  }
}

///|
fn Correlator::any_outer(self : Correlator, xs : Array[@sql.LExpr]) -> Bool {
  let mut hit = false
  for x in xs {
    if self.mentions_outer(x) {
      hit = true
    }
  }
  hit
}

///|
/// Replace the bare "unknown table or alias" a left-alone correlated subquery
/// would raise with the actual limit: decorrelation pairs inner and outer
/// columns by equality, so a correlation reaching the outer query through any
/// other operator cannot be attached at all.
fn Correlator::reject_unsupported_correlation(
  self : Correlator,
  sub : @sql.Select,
) -> Unit raise @types.SqlError {
  // a windowed subquery is refused for its own reason; do not relabel it
  if sub.windows.length() > 0 {
    return
  }
  if self.refs_outer(sub) {
    raise @types.SqlError::Bind(
      "this correlated subquery cannot be decorrelated: it must read plain tables (a derived table in its FROM is refused) and may not carry DISTINCT, LIMIT, OFFSET, a set operation, a grouping or HAVING that is not the correlation keys, or a reference to a table outside the immediately enclosing query — rewrite it as a join",
    )
  }
}

///|
/// Does the expression hold a correlated subquery anywhere inside it?
fn Correlator::contains_correlated(self : Correlator, e : @sql.LExpr) -> Bool {
  match e {
    ScalarSub(sub) | Exists(sub, _) | InSelect(_, sub, _) =>
      self.refs_outer(sub)
    Lit(_) | IntervalLit(_, _) | Col(_) | ColQ(_, _) | Star => false
    Arith(_, l, r) | Cmp(_, l, r) | And(l, r) | Or(l, r) =>
      self.contains_correlated(l) || self.contains_correlated(r)
    Not(x) | IsNull(x, _) | Extract(_, x) | Cast(x, _) =>
      self.contains_correlated(x)
    Between(v, lo, hi) =>
      self.contains_correlated(v) ||
      self.contains_correlated(lo) ||
      self.contains_correlated(hi)
    In(v, items) | NotIn(v, items) => {
      let mut hit = self.contains_correlated(v)
      for x in items {
        if self.contains_correlated(x) {
          hit = true
        }
      }
      hit
    }
    Like(v, _) | NotLike(v, _) => self.contains_correlated(v)
    Case(whens, else_) => {
      let mut hit = false
      for w in whens {
        if self.contains_correlated(w.0) || self.contains_correlated(w.1) {
          hit = true
        }
      }
      match else_ {
        Some(x) => if self.contains_correlated(x) { hit = true }
        None => ()
      }
      hit
    }
    Func(_, args) => {
      let mut hit = false
      for a in args {
        if self.contains_correlated(a) {
          hit = true
        }
      }
      hit
    }
    Agg(_, inner) =>
      match inner {
        Some(x) => self.contains_correlated(x)
        None => false
      }
  }
}

///|
/// Classify one correlated scalar subquery appearing in a select item.
/// Same rules as try_scalar; on bail the subquery stays untouched (the
/// runner keeps its unsupported-correlation error).
fn Correlator::try_scalar_item(
  self : Correlator,
  sub : @sql.Select,
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
  extra_items : Array[@sql.FromItem],
) -> @sql.LExpr? raise @types.SqlError {
  if !(sub.group_by.length() == 0) ||
    sub.having is Some(_) ||
    sub.limit is Some(_) ||
    sub.offset is Some(_) ||
    sub.distinct ||
    sub.setop is Some(_) {
    return None
  }
  let (pairs, inner_only, residual) = match self.prepare(sub) {
    Some(triple) => triple
    None => return None
  }
  // same refusal as try_scalar: a correlated scalar subquery without an
  // aggregate would multiply outer rows
  if sub.items.length() != 1 || !contains_agg(sub.items[0].expr) {
    if pairs.length() > 0 {
      raise @types.SqlError::Bind(
        "correlated scalar subquery must select an aggregate (e.g. min/max/avg/count)",
      )
    }
    return None
  }
  if residual.length() > 0 || pairs.length() == 0 {
    if pairs.length() == 0 && residual.length() == 0 {
      return None
    }
    match
      self.build_theta_scalar_table(
        sub, pairs, inner_only, residual, extra_schemas, extra_batches,
      ) {
      Some((item, name)) => {
        extra_items.push(item)
        return Some(scalar_value(name, 1, sub.items[0].expr))
      }
      None => return None
    }
  }
  let (item, name) = self.build_scalar_table(
    sub, pairs, inner_only, extra_schemas, extra_batches,
  )
  extra_items.push(item)
  Some(scalar_value(name, pairs.length(), sub.items[0].expr))
}

///|
/// Rewrite every correlated subquery of an expression into one that reads
/// its synthetic table: a scalar subquery becomes a column reference, and a
/// correlated EXISTS / IN becomes a boolean built from counts, so it works in
/// any position (select item, WHERE, inside NOT / OR / CASE) — not just as a
/// top-level conjunct the semi-join path can claim. Subqueries this cannot
/// claim are left alone for the runner (or refused, with a message).
fn rewrite_correlated(
  e : @sql.LExpr,
  cor : Correlator,
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
  extra_items : Array[@sql.FromItem],
) -> @sql.LExpr raise @types.SqlError {
  fn walk(e : @sql.LExpr) -> @sql.LExpr raise @types.SqlError {
    match e {
      ScalarSub(sub) =>
        match
          cor.try_scalar_item(sub, extra_schemas, extra_batches, extra_items) {
          Some(col) => col
          None => {
            cor.reject_unsupported_correlation(sub)
            e
          }
        }
      Exists(sub, negated) =>
        match
          cor.theta_exists(
            sub, negated, extra_schemas, extra_batches, extra_items,
          ) {
          Some(v) => v
          None => {
            cor.reject_unsupported_correlation(sub)
            e
          }
        }
      InSelect(v, sub, negated) =>
        match
          cor.theta_in(
            v, sub, negated, extra_schemas, extra_batches, extra_items,
          ) {
          Some(x) => x
          None => {
            cor.reject_unsupported_correlation(sub)
            e
          }
        }
      Arith(op, l, r) => Arith(op, walk(l), walk(r))
      Cmp(op, l, r) => Cmp(op, walk(l), walk(r))
      And(l, r) => And(walk(l), walk(r))
      Or(l, r) => Or(walk(l), walk(r))
      Not(x) => Not(walk(x))
      Between(v, lo, hi) => Between(walk(v), walk(lo), walk(hi))
      In(v, items) => {
        let new_items : Array[@sql.LExpr] = []
        for item in items {
          new_items.push(walk(item))
        }
        In(walk(v), new_items)
      }
      NotIn(v, items) => {
        let new_items : Array[@sql.LExpr] = []
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
        let new_whens : Array[(@sql.LExpr, @sql.LExpr)] = []
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
        let new_args : Array[@sql.LExpr] = []
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
    }
  }

  walk(e)
}

///|
/// Build the synthetic table, run the decorrelated inner query, and
/// return the semi/anti @sql.FromItem. When check_null_in_key is set (NOT
/// IN) a NULL in the inner key column poisons the whole conjunct into
/// a constant false.
fn Correlator::finish_semi(
  self : Correlator,
  inner_from : Array[@sql.FromItem],
  pairs : Array[(@sql.LExpr, @sql.LExpr)],
  inner_filter : Array[@sql.LExpr],
  residual : Array[@sql.LExpr],
  negated : Bool,
  extra_schemas : Array[@catalog.TableSchema],
  extra_batches : Array[Array[@types.DataBatch]],
  check_null_in_key : Bool,
  from_exists : Bool,
) -> SemiOutcome raise @types.SqlError {
  let name = "__semi\{self.counter}"
  self.counter = self.counter + 1
  // residual conjuncts may reference inner columns: lift every distinct
  // inner reference into its own synthetic column so the residual can
  // be evaluated over (outer row, inner row)
  let ref_names : Array[String] = [] // synthetic column per lifted ref
  let ref_exprs : Array[@sql.LExpr] = [] // the inner expression behind it
  let ref_keys : Array[String] = [] // canonical "qual.col" / "col" key
  for r in residual {
    lift_refs(
      r,
      self,
      Inner,
      "__sk",
      pairs.length(),
      ref_names,
      ref_exprs,
      ref_keys,
    )
  }
  // the inner side of every pair becomes one output column
  let items : Array[@sql.SelectItem] = []
  for i, p in pairs {
    items.push({ expr: p.0, label: Some("__sk\{i}"), })
  }
  for i, e in ref_exprs {
    items.push({ expr: e, label: Some("__sk\{pairs.length() + i}"), })
  }
  let filter : @sql.LExpr? = match inner_filter.length() {
    0 => None
    _ => {
      let mut acc = inner_filter[0]
      for i in 1..<inner_filter.length() {
        acc = And(acc, inner_filter[i])
      }
      Some(acc)
    }
  }
  let inner_sel : @sql.Select = {
    from: inner_from,
    filter,
    group_by: [],
    having: None,
    items,
    order_by: [],
    limit: None,
    offset: None,
    distinct: false,
    windows: [],
    setop: None,
  }
  let inner = run_parsed(inner_sel, self.catalog, [], self.opts)
  // NOT IN poison: a NULL in an inner key column makes every comparison
  // against it unknown, so an outer row whose set holds that NULL cannot pass
  // — but which rows those are depends on what narrows the set per outer row.
  // With the probe equality alone the set is the whole inner batch, so the
  // conjunct is false for every outer row; a key equality or a spanning
  // residual may keep the NULL out of a given row's set, and the anti join
  // compares keys rather than counting the NULLs it did not compare. E4c's
  // join contract is where the per-row version belongs; until then that shape
  // keeps the generic refusal instead of guessing.
  if check_null_in_key && negated {
    for r in 0..<inner.row_count() {
      if inner.get(r, 0) is @types.Null {
        if pairs.length() == 1 && residual.length() == 0 {
          return SemiFalse
        }
        return SemiUnsupported
      }
    }
  }
  // rewrite the residual's inner references onto the pseudo columns
  let rewritten : Array[@sql.LExpr] = []
  for r in residual {
    rewritten.push(substitute_refs(r, name, ref_keys, ref_names))
  }
  // ON: outer expr = pseudo column, AND-chained; the rewritten residual
  // rides along — plan_step classifies it as the step residual
  let on : @sql.LExpr = if pairs.length() == 0 {
    // no equality to hash on: the spanning conjuncts are the entire ON,
    // which the semi/anti join evaluates pair by pair
    let mut acc = rewritten[0]
    for i in 1..<rewritten.length() {
      acc = And(acc, rewritten[i])
    }
    acc
  } else if pairs.length() == 1 && rewritten.length() == 0 {
    Cmp(@types.Eq, pairs[0].1, ColQ(name, "__sk0"))
  } else {
    let mut acc : @sql.LExpr = Cmp(@types.Eq, pairs[0].1, ColQ(name, "__sk0"))
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
  SemiJoin({
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
fn Correlator::side_of(self : Correlator, e : @sql.LExpr) -> RefSide {
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
/// Recursively collect distinct column references of one scope. Names are
/// `prefix` + (base + ordinal), so the semi-join lifts line up with the items
/// finish_semi appends after the keys and the theta-scalar lifts line up with
/// the columns of the deduplicated outer table.
fn lift_refs(
  e : @sql.LExpr,
  cor : Correlator,
  side : RefSide,
  prefix : String,
  base : Int32,
  ref_names : Array[String],
  ref_exprs : Array[@sql.LExpr],
  ref_keys : Array[String],
) -> Unit {
  fn visit(e : @sql.LExpr) -> Unit {
    match e {
      Col(name) => {
        let key = ref_key(None, name)
        let mut seen = false
        for k in ref_keys {
          if k == key {
            seen = true
          }
        }
        if !seen && cor.side_of(Col(name)).same(side) {
          ref_names.push("\{prefix}\{base + ref_keys.length()}")
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
        if !seen && cor.side_of(ColQ(q, c)).same(side) {
          ref_names.push("\{prefix}\{base + ref_keys.length()}")
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
/// Recursively replace lifted column references with their pseudo-table
/// columns. References whose key is not in the table pass through untouched,
/// which is what lets one walker carry a scope's own refs into its table.
fn substitute_refs(
  e : @sql.LExpr,
  pseudo : String,
  ref_keys : Array[String],
  ref_names : Array[String],
) -> @sql.LExpr {
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
        substitute_refs(l, pseudo, ref_keys, ref_names),
        substitute_refs(r, pseudo, ref_keys, ref_names),
      )
    Cmp(op, l, r) =>
      Cmp(
        op,
        substitute_refs(l, pseudo, ref_keys, ref_names),
        substitute_refs(r, pseudo, ref_keys, ref_names),
      )
    And(l, r) =>
      And(
        substitute_refs(l, pseudo, ref_keys, ref_names),
        substitute_refs(r, pseudo, ref_keys, ref_names),
      )
    Or(l, r) =>
      Or(
        substitute_refs(l, pseudo, ref_keys, ref_names),
        substitute_refs(r, pseudo, ref_keys, ref_names),
      )
    Not(x) => Not(substitute_refs(x, pseudo, ref_keys, ref_names))
    Between(v, lo, hi) =>
      Between(
        substitute_refs(v, pseudo, ref_keys, ref_names),
        substitute_refs(lo, pseudo, ref_keys, ref_names),
        substitute_refs(hi, pseudo, ref_keys, ref_names),
      )
    In(v, items) => {
      let new_items : Array[@sql.LExpr] = []
      for item in items {
        new_items.push(substitute_refs(item, pseudo, ref_keys, ref_names))
      }
      In(substitute_refs(v, pseudo, ref_keys, ref_names), new_items)
    }
    NotIn(v, items) => {
      let new_items : Array[@sql.LExpr] = []
      for item in items {
        new_items.push(substitute_refs(item, pseudo, ref_keys, ref_names))
      }
      NotIn(substitute_refs(v, pseudo, ref_keys, ref_names), new_items)
    }
    Like(v, p) => Like(substitute_refs(v, pseudo, ref_keys, ref_names), p)
    NotLike(v, p) => NotLike(substitute_refs(v, pseudo, ref_keys, ref_names), p)
    IsNull(v, n) => IsNull(substitute_refs(v, pseudo, ref_keys, ref_names), n)
    Extract(f, x) => Extract(f, substitute_refs(x, pseudo, ref_keys, ref_names))
    Case(whens, else_) => {
      let new_whens : Array[(@sql.LExpr, @sql.LExpr)] = []
      for w in whens {
        new_whens.push(
          (
            substitute_refs(w.0, pseudo, ref_keys, ref_names),
            substitute_refs(w.1, pseudo, ref_keys, ref_names),
          ),
        )
      }
      let new_else = match else_ {
        Some(x) => Some(substitute_refs(x, pseudo, ref_keys, ref_names))
        None => None
      }
      Case(new_whens, new_else)
    }
    Func(name, args) => {
      let new_args : Array[@sql.LExpr] = []
      for a in args {
        new_args.push(substitute_refs(a, pseudo, ref_keys, ref_names))
      }
      Func(name, new_args)
    }
    Cast(x, dt) => Cast(substitute_refs(x, pseudo, ref_keys, ref_names), dt)
    ScalarSub(_) | InSelect(_, _, _) | Exists(_, _) => e
    Agg(f, inner) =>
      match inner {
        Some(x) => Agg(f, Some(substitute_refs(x, pseudo, ref_keys, ref_names)))
        None => Agg(f, None)
      }
    Star => e
  }
}
