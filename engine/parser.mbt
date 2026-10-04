// Recursive-descent parser for the W2 subset:
//   SELECT item [, item]* FROM table [WHERE expr] [GROUP BY expr[, expr]*]
//   [HAVING expr] [ORDER BY key [ASC|DESC][, ...]] [LIMIT n]
// Aggregates parse as function calls (sum/avg/min/max/count, with count(*)
// and count(DISTINCT x) forms). An OVER clause after an aggregate or a
// ranking function (row_number / rank / dense_rank) records a window
// definition and leaves an indexed `__win` marker as the select item.
// Precedence (low to high): OR, AND, NOT, comparison/BETWEEN/IN/LIKE,
// + -, * / %, unary -.

///|
priv struct Parser {
  toks : Array[Tok]
  mut pos : Int
  // WITH cte AS (SELECT ...) name -> body token slice; a reference
  // re-parses the slice into a fresh derived table per occurrence
  ctes : Map[String, Array[Tok]]
  // window definitions in parse order across the whole statement; each
  // select body drains its own suffix (stack discipline: bodies nest
  // strictly inside their items) and renumbers the `__win` markers
  windows : Array[WindowSpec]
}

///|
fn Parser::peek(self : Parser) -> Tok {
  self.toks[self.pos]
}

///|
fn Parser::peek_at(self : Parser, off : Int) -> Tok {
  let i = self.pos + off
  if i < self.toks.length() {
    self.toks[i]
  } else {
    Eof
  }
}

///|
fn Parser::advance(self : Parser) -> Tok {
  let t = self.toks[self.pos]
  if t is Eof {
    return t
  }
  self.pos += 1
  t
}

///|
fn Parser::eat(self : Parser, t : Tok) -> Bool {
  if self.peek() == t {
    self.pos += 1
    true
  } else {
    false
  }
}

///|
fn Parser::expect(self : Parser, t : Tok) -> Unit raise @types.SqlError {
  if !self.eat(t) {
    raise @types.SqlError::Parse(
      "expected \{show_tok(t)} but found \{show_tok(self.peek())}",
    )
  }
}

///|
fn show_tok(t : Tok) -> String {
  match t {
    Ident(s) => "identifier \"\{s}\""
    IntLit(v) => "number \{v}"
    Int64Lit(v) => "number \{v}"
    DoubleLit(v) => "number \{v}"
    StrLit(_) => "string literal"
    BoolLit(_) => "boolean literal"
    LParen => "'('"
    RParen => "')'"
    Comma => "','"
    Semi => "';'"
    Dot => "'.'"
    Star => "'*'"
    Plus => "'+'"
    Minus => "'-'"
    Slash => "'/'"
    Percent => "'%'"
    Eq => "'='"
    Neq => "'<>'"
    PipePipe => "'||'"
    Lt => "'<'"
    Le => "'<='"
    Gt => "'>'"
    Ge => "'>='"
    KwSelect => "SELECT"
    KwWith => "WITH"
    KwFrom => "FROM"
    KwWhere => "WHERE"
    KwAs => "AS"
    KwAnd => "AND"
    KwOr => "OR"
    KwNot => "NOT"
    KwBetween => "BETWEEN"
    KwDate => "DATE"
    KwGroup => "GROUP"
    KwBy => "BY"
    KwHaving => "HAVING"
    KwOrder => "ORDER"
    KwAsc => "ASC"
    KwDesc => "DESC"
    KwLimit => "LIMIT"
    KwCase => "CASE"
    KwWhen => "WHEN"
    KwThen => "THEN"
    KwElse => "ELSE"
    KwEnd => "END"
    KwLike => "LIKE"
    KwIn => "IN"
    KwDistinct => "DISTINCT"
    KwJoin => "JOIN"
    KwInner => "INNER"
    KwLeft => "LEFT"
    KwOuter => "OUTER"
    KwCross => "CROSS"
    KwOn => "ON"
    KwIs => "IS"
    KwNull => "NULL"
    KwExtract => "EXTRACT"
    KwInterval => "INTERVAL"
    KwYear => "YEAR"
    KwMonth => "MONTH"
    KwDay => "DAY"
    KwOver => "OVER"
    KwPartition => "PARTITION"
    Eof => "end of input"
  }
}

///|
pub fn parse_select(sql : String) -> Select raise @types.SqlError {
  let p : Parser = { toks: lex_sql(sql), pos: 0, ctes: Map([]), windows: [], }
  parse_with_clause(p)
  p.expect(KwSelect)
  let sel = parse_setop_expr(p)
  // statement terminators: users end SQL with ';' out of habit
  while p.eat(Semi) {
    ()
  }
  p.expect(Eof)
  sel
}

///|
/// Set operations with standard precedence: INTERSECT binds tighter
/// than UNION / EXCEPT; UNION and EXCEPT are left-associative peers.
/// Per-branch ORDER BY / LIMIT / OFFSET are rejected (they belong to
/// the whole chain).
fn parse_setop_expr(p : Parser) -> Select raise @types.SqlError {
  let mut sel = parse_setop_term(p)
  while p.peek() is Ident(uw) &&
        (ascii_lower(uw) == "union" || ascii_lower(uw) == "except") {
    if sel.order_by.length() > 0 ||
      sel.limit is Some(_) ||
      sel.offset is Some(_) {
      raise @types.SqlError::Parse(
        "ORDER BY / LIMIT / OFFSET on a set-operation branch is not supported; move them to the end of the chain",
      )
    }
    let kind = if ascii_lower(uw) == "union" { Union } else { Except }
    let _ = p.advance()
    let all = parse_setop_all(p)
    p.expect(KwSelect)
    let right_term = parse_setop_term(p)
    // the accumulated chain becomes the LEFT operand of the new op,
    // attached at the term's free left end so an INTERSECT chain inside
    // the term keeps its own links
    sel = attach_setop_left(right_term, kind, all, sel)
  }
  sel
}

///|
/// Attach `prev` as the LEFT operand of `op` at the free left end of a
/// term chain: a term's root may itself carry an INTERSECT link, and
/// overwriting it would orphan the term's left branch.
fn attach_setop_left(
  term : Select,
  kind : SetOpKind,
  all : Bool,
  prev : Select,
) -> Select {
  match term.setop {
    None => { ..term, setop: Some((kind, all, prev)), }
    Some((k, a, left)) =>
      { ..term, setop: Some((k, a, attach_setop_left(left, kind, all, prev))), }
  }
}

///|
/// A term: one select core chained by INTERSECT [ALL|DISTINCT].
fn parse_setop_term(p : Parser) -> Select raise @types.SqlError {
  let mut sel = parse_select_body(p)
  while p.peek() is Ident(iw) && ascii_lower(iw) == "intersect" {
    if sel.order_by.length() > 0 ||
      sel.limit is Some(_) ||
      sel.offset is Some(_) {
      raise @types.SqlError::Parse(
        "ORDER BY / LIMIT / OFFSET on a set-operation branch is not supported; move them to the end of the chain",
      )
    }
    let _ = p.advance()
    let all = parse_setop_all(p)
    p.expect(KwSelect)
    let right_core = parse_select_body(p)
    sel = { ..right_core, setop: Some((Intersect, all, sel)), }
  }
  sel
}

///|
/// The [ALL|DISTINCT] tail of a set operation; DISTINCT is the default.
fn parse_setop_all(p : Parser) -> Bool {
  if p.eat(KwDistinct) {
    return false
  }
  if p.peek() is Ident(al) && ascii_lower(al) == "all" {
    let _ = p.advance()
    return true
  }
  false
}

///|
/// Parse everything after SELECT (no Eof check — the caller may be
/// inside a derived table). Window definitions (`fn(...) OVER (...)`)
/// parse into the shared `p.windows` array; this body drains the suffix
/// accumulated by its own select list and renumbers the item markers to
/// body-local indexes. Window functions are a select-list feature: the
/// other clauses are checked marker-free.
fn parse_select_body(p : Parser) -> Select raise @types.SqlError {
  let win_base = p.windows.length()
  let distinct = p.eat(KwDistinct)
  let items_raw : Array[SelectItem] = []
  items_raw.push(parse_item(p))
  while p.eat(Comma) {
    items_raw.push(parse_item(p))
  }
  // FROM is optional: `SELECT 1` evaluates its items over one dummy row
  let from : Array[FromItem] = []
  if p.eat(KwFrom) {
    from.push(parse_table_item(p))
    let mut joining = true
    while joining {
      if p.eat(Comma) {
        from.push(parse_table_item(p))
      } else {
        let item = parse_join_item(p)
        match item {
          Some(it) => from.push(it)
          None => joining = false
        }
      }
    }
  }
  let filter = if p.eat(KwWhere) { Some(parse_or(p)) } else { None }
  let group_by : Array[LExpr] = if p.eat(KwGroup) {
    p.expect(KwBy)
    parse_expr_list(p)
  } else {
    []
  }
  let having = if p.eat(KwHaving) { Some(parse_or(p)) } else { None }
  let order_by : Array[OrderItem] = if p.eat(KwOrder) {
    p.expect(KwBy)
    parse_order_list(p)
  } else {
    []
  }
  let limit = if p.eat(KwLimit) {
    match p.advance() {
      IntLit(v) => Some(v)
      other => {
        let found = show_tok(other)
        raise @types.SqlError::Parse(
          "expected a number after LIMIT, found \{found}",
        )
      }
    }
  } else {
    None
  }
  let offset : Int? = if p.peek() is Ident(on) && ascii_lower(on) == "offset" {
    let _ = p.advance()
    match p.advance() {
      IntLit(v) => Some(v)
      other => {
        let found = show_tok(other)
        raise @types.SqlError::Parse(
          "expected a number after OFFSET, found \{found}",
        )
      }
    }
  } else {
    None
  }
  // window markers may only appear in the select list; the sub-select
  // bodies of ScalarSub / IN / EXISTS own their markers, so the walk
  // stops at their boundaries
  match filter {
    Some(f) =>
      if contains_win_marker(f) {
        raise @types.SqlError::Parse(
          "window functions are only allowed in the SELECT list",
        )
      }
    None => ()
  }
  for g in group_by {
    if contains_win_marker(g) {
      raise @types.SqlError::Parse(
        "window functions are only allowed in the SELECT list",
      )
    }
  }
  match having {
    Some(h) =>
      if contains_win_marker(h) {
        raise @types.SqlError::Parse(
          "window functions are only allowed in the SELECT list",
        )
      }
    None => ()
  }
  for o in order_by {
    if contains_win_marker(o.key) {
      raise @types.SqlError::Parse(
        "window functions are only allowed in the SELECT list; order by the output alias instead",
      )
    }
  }
  // drain this body's window definitions (truncating the shared array
  // back to this body's base — otherwise a parent body would re-drain a
  // nested subquery's leftovers) and make the item markers body-local
  let windows : Array[WindowSpec] = []
  for i in win_base..<p.windows.length() {
    windows.push(p.windows[i])
  }
  p.windows.truncate(win_base)
  let items : Array[SelectItem] = []
  for it in items_raw {
    items.push({
      expr: reindex_win_markers(it.expr, win_base),
      label: it.label,
    })
  }
  {
    from,
    filter,
    group_by,
    having,
    items,
    windows,
    order_by,
    limit,
    offset,
    distinct,
    setop: None,
  }
}

///|
/// True when the expression contains a `__win` select-list marker.
/// Subquery boundaries stop the walk: a nested select body numbered its
/// own markers and owns them.
fn contains_win_marker(e : LExpr) -> Bool {
  match e {
    Func("__win", _) => true
    Col(_) | ColQ(_, _) | Lit(_) | Star | IntervalLit(_, _) => false
    Arith(_, l, r) | Cmp(_, l, r) | And(l, r) | Or(l, r) =>
      contains_win_marker(l) || contains_win_marker(r)
    Not(x) => contains_win_marker(x)
    Between(v, lo, hi) =>
      contains_win_marker(v) ||
      contains_win_marker(lo) ||
      contains_win_marker(hi)
    In(v, items) | NotIn(v, items) => {
      let mut found = contains_win_marker(v)
      for item in items {
        if contains_win_marker(item) {
          found = true
        }
      }
      found
    }
    Like(v, _) | NotLike(v, _) => contains_win_marker(v)
    IsNull(v, _) => contains_win_marker(v)
    Extract(_, x) => contains_win_marker(x)
    Cast(x, _) => contains_win_marker(x)
    Agg(_, inner) =>
      match inner {
        Some(x) => contains_win_marker(x)
        None => false
      }
    Case(whens, else_) => {
      let mut found = false
      for w in whens {
        if contains_win_marker(w.0) || contains_win_marker(w.1) {
          found = true
        }
      }
      match else_ {
        Some(x) => found || contains_win_marker(x)
        None => found
      }
    }
    Func(_, args) => {
      let mut found = false
      for a in args {
        if contains_win_marker(a) {
          found = true
        }
      }
      found
    }
    // nested select bodies drain and number their own windows
    ScalarSub(_) | InSelect(_, _, _) | Exists(_, _) => false
  }
}

///|
/// Renumber `__win` markers from statement-wide to select-body-local
/// indexes (`g -> g - base`). Subquery boundaries stop the walk.
fn reindex_win_markers(e : LExpr, base : Int) -> LExpr {
  match e {
    Func("__win", [Lit(@types.Int32(g))]) =>
      Func("__win", [Lit(@types.Scalar::Int32(g - base))])
    Col(_) | ColQ(_, _) | Lit(_) | Star | IntervalLit(_, _) => e
    Arith(op, l, r) =>
      Arith(op, reindex_win_markers(l, base), reindex_win_markers(r, base))
    Cmp(op, l, r) =>
      Cmp(op, reindex_win_markers(l, base), reindex_win_markers(r, base))
    And(l, r) => And(reindex_win_markers(l, base), reindex_win_markers(r, base))
    Or(l, r) => Or(reindex_win_markers(l, base), reindex_win_markers(r, base))
    Not(x) => Not(reindex_win_markers(x, base))
    Between(v, lo, hi) =>
      Between(
        reindex_win_markers(v, base),
        reindex_win_markers(lo, base),
        reindex_win_markers(hi, base),
      )
    In(v, items) => {
      let new_items : Array[LExpr] = []
      for item in items {
        new_items.push(reindex_win_markers(item, base))
      }
      In(reindex_win_markers(v, base), new_items)
    }
    NotIn(v, items) => {
      let new_items : Array[LExpr] = []
      for item in items {
        new_items.push(reindex_win_markers(item, base))
      }
      NotIn(reindex_win_markers(v, base), new_items)
    }
    Like(v, pat) => Like(reindex_win_markers(v, base), pat)
    NotLike(v, pat) => NotLike(reindex_win_markers(v, base), pat)
    IsNull(v, n) => IsNull(reindex_win_markers(v, base), n)
    Extract(f, x) => Extract(f, reindex_win_markers(x, base))
    Cast(x, dt) => Cast(reindex_win_markers(x, base), dt)
    Agg(f, inner) =>
      match inner {
        Some(x) => Agg(f, Some(reindex_win_markers(x, base)))
        None => Agg(f, None)
      }
    Case(whens, else_) => {
      let new_whens : Array[(LExpr, LExpr)] = []
      for w in whens {
        new_whens.push(
          (reindex_win_markers(w.0, base), reindex_win_markers(w.1, base)),
        )
      }
      let new_else = match else_ {
        Some(x) => Some(reindex_win_markers(x, base))
        None => None
      }
      Case(new_whens, new_else)
    }
    Func(name, args) => {
      let new_args : Array[LExpr] = []
      for a in args {
        new_args.push(reindex_win_markers(a, base))
      }
      Func(name, new_args)
    }
    ScalarSub(_) | InSelect(_, _, _) | Exists(_, _) => e
  }
}

///|
fn parse_table_name(p : Parser) -> String raise @types.SqlError {
  let t = p.advance()
  match ident_like_tok(t) {
    Some(name) => name
    None => {
      let found = show_tok(t)
      raise @types.SqlError::Parse(
        "expected table name after FROM, found \{found}",
      )
    }
  }
}

///|
/// A name position (column, table, alias): a plain identifier, or one of
/// the DATE-part keywords year/month/day/date, which a CSV header can
/// realistically collide with. Every other keyword stays reserved —
/// quoting ("left") reaches those.
fn ident_like_tok(t : Tok) -> String? {
  match t {
    Ident(s) => Some(s)
    KwYear => Some("year")
    KwMonth => Some("month")
    KwDay => Some("day")
    KwDate => Some("date")
    _ => None
  }
}

///|
/// WITH name AS (SELECT ...), name2 AS (SELECT ...) — statement-level,
/// non-recursive. Each CTE body is kept as a token slice and re-parsed
/// fresh at every reference: the engine's decorrelation rewrites the
/// AST in place, so sharing one parsed body between references would
/// double-apply the rewrite.
fn parse_with_clause(p : Parser) -> Unit raise @types.SqlError {
  if !p.eat(KwWith) {
    return
  }
  let mut first = true
  while first || p.eat(Comma) {
    first = false
    let t = p.advance()
    let name = match ident_like_tok(t) {
      Some(n) => n
      None => {
        let found = show_tok(t)
        raise @types.SqlError::Parse(
          "expected CTE name after WITH, found \{found}",
        )
      }
    }
    p.expect(KwAs)
    p.expect(LParen)
    let start = p.pos
    p.expect(KwSelect)
    let _ = parse_select_body(p)
    let body : Array[Tok] = []
    for i in start..<p.pos {
      body.push(p.toks[i])
    }
    body.push(Eof) // the re-parse peek() relies on a terminator
    p.ctes[name] = body
    p.expect(RParen)
  }
}

///|
/// Re-parse a stored CTE body into a fresh derived-table select.
fn Parser::reparse_cte(
  self : Parser,
  name : String,
) -> Select raise @types.SqlError {
  let sub : Parser = {
    toks: self.ctes[name],
    pos: 0,
    ctes: self.ctes,
    windows: [],
  }
  sub.expect(KwSelect)
  parse_select_body(sub)
}

///|
/// One table reference: a parenthesized subquery, a WITH name (which
/// shadows catalog tables and qualifies itself when bare), or a named
/// table — each with its optional alias and derived-column list.
fn parse_table_ref(
  p : Parser,
) -> (TableRef, String?, Array[String]?) raise @types.SqlError {
  let table : TableRef = if p.peek() is LParen {
    let _ = p.advance()
    p.expect(KwSelect)
    let inner = parse_select_body(p)
    p.expect(RParen)
    Sub(inner)
  } else {
    match p.peek() {
      Ident(name) =>
        if p.ctes.contains(name) {
          let _ = p.advance()
          let tbl_alias = match parse_alias_opt(p) {
            Some(a) => Some(a)
            None => Some(name) // the CTE name is its own qualifier
          }
          let tref : TableRef = Sub(p.reparse_cte(name))
          let col_aliases = parse_col_alias_list(p, tref, tbl_alias)
          return (tref, tbl_alias, col_aliases)
        } else {
          Named(parse_table_name(p))
        }
      _ => Named(parse_table_name(p))
    }
  }
  let tbl_alias = parse_alias_opt(p)
  let col_aliases = parse_col_alias_list(p, table, tbl_alias)
  (table, tbl_alias, col_aliases)
}

///|
fn parse_table_item(p : Parser) -> FromItem raise @types.SqlError {
  let (table, tbl_alias, col_aliases) = parse_table_ref(p)
  { table, tbl_alias, col_aliases, join: Inner, on: None, }
}

///|
/// Derived-table column alias list: `AS t (a, b)` or bare `t (a, b)`.
/// Only valid right after a derived table, and it requires the alias.
fn parse_col_alias_list(
  p : Parser,
  table : TableRef,
  tbl_alias : String?,
) -> Array[String]? raise @types.SqlError {
  if !(table is Sub(_)) || !(p.peek() is LParen) {
    return None
  }
  if tbl_alias is None {
    raise @types.SqlError::Parse(
      "derived-table column list needs a table alias",
    )
  }
  let _ = p.advance() // (
  let names : Array[String] = []
  fn parse_col_name(
    p : Parser,
    names : Array[String],
  ) -> Unit raise @types.SqlError {
    let t = p.advance()
    match ident_like_tok(t) {
      Some(name) => names.push(name)
      None => {
        let found = show_tok(t)
        raise @types.SqlError::Parse(
          "expected column name in derived-table column list, found \{found}",
        )
      }
    }
  }

  parse_col_name(p, names)
  while p.eat(Comma) {
    parse_col_name(p, names)
  }
  p.expect(RParen)
  if names.length() == 0 {
    raise @types.SqlError::Parse("empty derived-table column list")
  }
  Some(names)
}

///|
/// Optional table alias: `tbl alias` or `tbl AS alias`. Names follow
/// ident_like_tok (identifiers plus the DATE-part keywords).
fn parse_alias_opt(p : Parser) -> String? raise @types.SqlError {
  if p.eat(KwAs) {
    let t = p.advance()
    match ident_like_tok(t) {
      Some(name) => return Some(name)
      None => {
        let found = show_tok(t)
        raise @types.SqlError::Parse("expected alias after AS, found \{found}")
      }
    }
  }
  match ident_like_tok(p.peek()) {
    // a bare alias must not swallow a connective: UNION or the RIGHT /
    // FULL join keywords (LEFT/CROSS are keywords already)
    Some(name) if ascii_lower(name) != "union" &&
      ascii_lower(name) != "right" &&
      ascii_lower(name) != "full" &&
      ascii_lower(name) != "intersect" &&
      ascii_lower(name) != "except" => {
      let _ = p.advance()
      Some(name)
    }
    _ => None
  }
}

///|
/// Parse one explicit join clause; None when the next token does not
/// start a join (caller falls through to the following clause).
fn parse_join_item(p : Parser) -> FromItem? raise @types.SqlError {
  let kind : JoinKind = if p.eat(KwJoin) {
    Inner
  } else if p.peek() is KwInner {
    let _ = p.advance()
    p.expect(KwJoin)
    Inner
  } else if p.peek() is KwLeft {
    let _ = p.advance()
    let _ = p.eat(KwOuter)
    p.expect(KwJoin)
    Left
  } else if p.peek() is Ident(w) && ascii_lower(w) == "right" {
    let _ = p.advance()
    let _ = p.eat(KwOuter)
    p.expect(KwJoin)
    Right
  } else if p.peek() is Ident(w) && ascii_lower(w) == "full" {
    let _ = p.advance()
    let _ = p.eat(KwOuter)
    p.expect(KwJoin)
    Full
  } else if p.peek() is KwCross {
    let _ = p.advance()
    p.expect(KwJoin)
    Cross
  } else {
    return None
  }
  let (table, tbl_alias, col_aliases) = parse_table_ref(p)
  let on : LExpr? = if kind is Cross {
    None
  } else {
    p.expect(KwOn)
    Some(parse_or(p))
  }
  Some({ table, tbl_alias, col_aliases, join: kind, on, })
}

///|
fn parse_item(p : Parser) -> SelectItem raise @types.SqlError {
  if p.eat(Star) {
    // bare `*` selects every FROM column; no alias attaches to it
    return { expr: Star, label: None, }
  }
  let expr = parse_or(p)
  let label = if p.eat(KwAs) {
    let t = p.advance()
    match ident_like_tok(t) {
      Some(name) => Some(name)
      None => {
        let found = show_tok(t)
        raise @types.SqlError::Parse("expected alias after AS, found \{found}")
      }
    }
  } else {
    match ident_like_tok(p.peek()) {
      // bare alias: SELECT sum(x) revenue FROM ...; never a setop
      // keyword (right/full are keywords already)
      Some(name) if ascii_lower(name) != "union" &&
        ascii_lower(name) != "intersect" &&
        ascii_lower(name) != "except" => {
        let _ = p.advance()
        Some(name)
      }
      _ => None
    }
  }
  { expr, label, }
}

///|
fn parse_expr_list(p : Parser) -> Array[LExpr] raise @types.SqlError {
  let out : Array[LExpr] = []
  out.push(parse_or(p))
  while p.eat(Comma) {
    out.push(parse_or(p))
  }
  out
}

///|
fn parse_order_list(p : Parser) -> Array[OrderItem] raise @types.SqlError {
  let out : Array[OrderItem] = []
  out.push(parse_order_item(p))
  while p.eat(Comma) {
    out.push(parse_order_item(p))
  }
  out
}

///|
fn parse_order_item(p : Parser) -> OrderItem raise @types.SqlError {
  let key = parse_or(p)
  let desc = if p.eat(KwDesc) {
    true
  } else {
    let _ = p.eat(KwAsc)
    false
  }
  // optional NULLS FIRST / NULLS LAST ("nulls" is not a keyword, so a
  // column named nulls stays usable elsewhere)
  let mut nulls_first : Bool? = None
  if p.peek() is Ident(wn) && ascii_lower(wn) == "nulls" {
    let _ = p.advance()
    let d = p.advance()
    match d {
      Ident(dir) =>
        match ascii_lower(dir) {
          "first" => nulls_first = Some(true)
          "last" => nulls_first = Some(false)
          other =>
            raise @types.SqlError::Parse(
              "expected FIRST or LAST after NULLS, found \"\{other}\"",
            )
        }
      other => {
        let found = show_tok(other)
        raise @types.SqlError::Parse(
          "expected FIRST or LAST after NULLS, found \{found}",
        )
      }
    }
  }
  { key, desc, nulls_first, }
}

///|
fn parse_or(p : Parser) -> LExpr raise @types.SqlError {
  let mut left = parse_and(p)
  while p.eat(KwOr) {
    let right = parse_and(p)
    left = Or(left, right)
  }
  left
}

///|
fn parse_and(p : Parser) -> LExpr raise @types.SqlError {
  let mut left = parse_not(p)
  while p.eat(KwAnd) {
    let right = parse_not(p)
    left = And(left, right)
  }
  left
}

///|
fn parse_not(p : Parser) -> LExpr raise @types.SqlError {
  if p.eat(KwNot) {
    Not(parse_not(p))
  } else {
    parse_predicate(p)
  }
}

///|
fn parse_predicate(p : Parser) -> LExpr raise @types.SqlError {
  let left = parse_add(p)
  let op : @types.CmpOp? = match p.peek() {
    Eq => {
      let _ = p.advance()
      Some(@types.Eq)
    }
    Neq => {
      let _ = p.advance()
      Some(@types.Neq)
    }
    Lt => {
      let _ = p.advance()
      Some(@types.Lt)
    }
    Le => {
      let _ = p.advance()
      Some(@types.Le)
    }
    Gt => {
      let _ = p.advance()
      Some(@types.Gt)
    }
    Ge => {
      let _ = p.advance()
      Some(@types.Ge)
    }
    _ => None
  }
  match op {
    Some(o) => {
      let right = parse_add(p)
      Cmp(o, left, right)
    }
    None =>
      if p.eat(KwBetween) {
        // BETWEEN consumes its own AND: a BETWEEN b AND c parses as one
        // predicate, so `a BETWEEN 1 AND 2 AND b` still chains correctly.
        let low = parse_add(p)
        p.expect(KwAnd)
        let high = parse_add(p)
        Between(left, low, high)
      } else if p.eat(KwLike) {
        Like(left, parse_add(p))
      } else if p.eat(KwIn) {
        p.expect(LParen)
        if p.peek() is KwSelect {
          let _ = p.advance()
          let sub = parse_select_body(p)
          p.expect(RParen)
          InSelect(left, sub, false)
        } else {
          let list = parse_expr_list(p)
          p.expect(RParen)
          In(left, list)
        }
      } else if p.peek() is KwNot && p.peek_at(1) is KwBetween {
        // postfix NOT BETWEEN (prefix NOT is handled by parse_not)
        let _ = p.advance()
        let _ = p.advance()
        let low = parse_add(p)
        p.expect(KwAnd)
        let high = parse_add(p)
        Not(Between(left, low, high))
      } else if p.peek() is KwNot && p.peek_at(1) is KwLike {
        // postfix NOT LIKE (prefix NOT is handled by parse_not)
        let _ = p.advance()
        let _ = p.advance()
        NotLike(left, parse_add(p))
      } else if p.peek() is KwNot && p.peek_at(1) is KwIn {
        let _ = p.advance()
        let _ = p.advance()
        p.expect(LParen)
        if p.peek() is KwSelect {
          let _ = p.advance()
          let sub = parse_select_body(p)
          p.expect(RParen)
          InSelect(left, sub, true)
        } else {
          let list = parse_expr_list(p)
          p.expect(RParen)
          NotIn(left, list)
        }
      } else if p.peek() is KwIs {
        // IS NULL / IS NOT NULL: the only NULL test in the subset
        let _ = p.advance()
        let negated = if p.eat(KwNot) { true } else { false }
        p.expect(KwNull)
        IsNull(left, negated)
      } else {
        left
      }
  }
}

///|
fn parse_add(p : Parser) -> LExpr raise @types.SqlError {
  let mut left = parse_mul(p)
  let mut running = true
  while running {
    match p.peek() {
      Plus => {
        let _ = p.advance()
        left = Arith(@types.Add, left, parse_mul(p))
      }
      Minus => {
        let _ = p.advance()
        left = Arith(@types.Sub, left, parse_mul(p))
      }
      PipePipe => {
        // string concatenation; the binder requires string operands
        let _ = p.advance()
        left = Func("concat", [left, parse_mul(p)])
      }
      _ => running = false
    }
  }
  left
}

///|
fn parse_mul(p : Parser) -> LExpr raise @types.SqlError {
  let mut left = parse_unary(p)
  let mut running = true
  while running {
    match p.peek() {
      Star => {
        let _ = p.advance()
        left = Arith(@types.Mul, left, parse_unary(p))
      }
      Slash => {
        let _ = p.advance()
        left = Arith(@types.Div, left, parse_unary(p))
      }
      Percent => {
        let _ = p.advance()
        left = Arith(@types.Mod, left, parse_unary(p))
      }
      _ => running = false
    }
  }
  left
}

///|
fn parse_unary(p : Parser) -> LExpr raise @types.SqlError {
  if p.eat(Minus) {
    match parse_unary(p) {
      Lit(@types.Int32(v)) => Lit(@types.Int32(-v))
      Lit(@types.Float64(v)) => Lit(@types.Float64(-v))
      other => Arith(@types.Sub, Lit(@types.Int32(0)), other)
    }
  } else {
    parse_primary(p)
  }
}

///|
fn parse_primary(p : Parser) -> LExpr raise @types.SqlError {
  match p.advance() {
    Ident(name) =>
      if ascii_lower(name) == "exists" && p.peek() is LParen {
        let _ = p.advance() // (
        p.expect(KwSelect)
        let sub = parse_select_body(p)
        p.expect(RParen)
        Exists(sub, false) // NOT EXISTS arrives as Not(Exists)
      } else if p.peek() is LParen {
        // OVER binds at call level: `sum(x) OVER () + 1` chains on the
        // window result
        parse_over_opt(p, parse_function(p, name))
      } else if p.peek() is Dot {
        parse_qualified(p, name)
      } else {
        Col(name)
      }
    // the DATE-part keywords resolve as bare column names; DATE itself
    // only starts a literal when a string literal follows
    KwYear => Col("year")
    KwMonth => Col("month")
    KwDay => Col("day")
    KwDate =>
      if p.peek() is StrLit(_) {
        parse_date_literal(p)
      } else {
        Col("date")
      }
    IntLit(v) => Lit(@types.Scalar::Int32(v))
    Int64Lit(v) => Lit(@types.Scalar::Int64(v))
    DoubleLit(v) => Lit(@types.Scalar::Float64(v))
    StrLit(s) => Lit(@types.Scalar::Str(s))
    BoolLit(b) => Lit(@types.Scalar::Boolean(b))
    KwNull => Lit(@types.Null)
    LParen =>
      // ( SELECT ... ) is a scalar subquery; anything else is a grouping
      if p.peek() is KwSelect {
        let _ = p.advance()
        let sub = parse_select_body(p)
        p.expect(RParen)
        ScalarSub(sub)
      } else {
        let e = parse_or(p)
        p.expect(RParen)
        e
      }
    KwCase => parse_case(p)
    KwExtract => {
      p.expect(LParen)
      let field = match p.advance() {
        KwYear => Year
        KwMonth => Month
        KwDay => Day
        other => {
          let found = show_tok(other)
          raise @types.SqlError::Parse(
            "expected YEAR, MONTH or DAY in EXTRACT, found \{found}",
          )
        }
      }
      p.expect(KwFrom)
      let inner = parse_or(p)
      p.expect(RParen)
      Extract(field, inner)
    }
    KwInterval => parse_interval(p)
    other => {
      let found = show_tok(other)
      raise @types.SqlError::Parse("unexpected \{found} in expression")
    }
  }
}

///|
/// OVER clause: `fn(args) OVER ( [PARTITION BY expr, ...]
/// [ORDER BY key [ASC|DESC] [NULLS FIRST|LAST], ...] )`. Records the
/// window definition in `p.windows` and returns an indexed `__win`
/// marker for the select item. Only aggregates and the three ranking
/// functions take OVER; explicit frame clauses are rejected (the
/// default frame is implied and supported for aggregates).
fn parse_over_opt(p : Parser, expr : LExpr) -> LExpr raise @types.SqlError {
  if !p.eat(KwOver) {
    return expr
  }
  let fn_ : WinFn = match expr {
    Agg(f, inner) => WinFn::Agg(f, inner)
    Func(nm, args) =>
      match ascii_lower(nm) {
        "row_number" =>
          if args.length() == 0 {
            RowNumber
          } else {
            raise @types.SqlError::Parse("row_number() takes no arguments")
          }
        "rank" =>
          if args.length() == 0 {
            Rank
          } else {
            raise @types.SqlError::Parse("rank() takes no arguments")
          }
        "dense_rank" =>
          if args.length() == 0 {
            DenseRank
          } else {
            raise @types.SqlError::Parse("dense_rank() takes no arguments")
          }
        _ =>
          raise @types.SqlError::Parse(
            "only aggregates and ranking functions (row_number, rank, dense_rank) support OVER, found \"\{nm}\"",
          )
      }
    _ =>
      raise @types.SqlError::Parse(
        "OVER must follow an aggregate or ranking function call",
      )
  }
  p.expect(LParen)
  let mut partition : Array[LExpr] = []
  let order : Array[(LExpr, Bool, Bool?)] = []
  if p.eat(KwPartition) {
    p.expect(KwBy)
    partition = parse_expr_list(p)
  }
  if p.eat(KwOrder) {
    p.expect(KwBy)
    for o in parse_order_list(p) {
      order.push((o.key, o.desc, o.nulls_first))
    }
  }
  match p.peek() {
    Ident(w) =>
      match ascii_lower(w) {
        "rows" | "range" | "groups" =>
          raise @types.SqlError::Parse(
            "window frame clauses (ROWS/RANGE) are not supported; the default frame (RANGE UNBOUNDED PRECEDING TO CURRENT ROW) is used",
          )
        _ => ()
      }
    _ => ()
  }
  p.expect(RParen)
  let idx = p.windows.length()
  p.windows.push({ fn_, partition, order, })
  Func("__win", [Lit(@types.Scalar::Int32(idx))])
}

///|
fn parse_qualified(p : Parser, table : String) -> LExpr raise @types.SqlError {
  // assumes p.peek() is Dot and `table` is already consumed
  let _ = p.advance()
  let t = p.advance()
  match ident_like_tok(t) {
    Some(col) => ColQ(table, col)
    None => {
      let found = show_tok(t)
      raise @types.SqlError::Parse(
        "expected column name after '.', found \{found}",
      )
    }
  }
}

///|
fn parse_date_literal(p : Parser) -> LExpr raise @types.SqlError {
  match p.advance() {
    StrLit(s) =>
      match @types.parse_date(s) {
        Some(days) => Lit(@types.Scalar::Date(days))
        None =>
          raise @types.SqlError::Parse(
            "bad DATE literal \"\{s}\" (expected yyyy-mm-dd)",
          )
      }
    other => {
      let found = show_tok(other)
      raise @types.SqlError::Parse("expected string after DATE, found \{found}")
    }
  }
}

///|
/// INTERVAL <string|int> <day|month|year> [ ( precision ) ]. The
/// parenthesized precision suffix comes from the TPC-H dbgen texts
/// (`interval ':1' day (3)`); it carries no meaning here and is parsed
/// and dropped.
fn parse_interval(p : Parser) -> LExpr raise @types.SqlError {
  // a leading MINUS negates a bare-number quantity (`interval -90 day`)
  let neg = p.eat(Minus)
  let qty : Int64 = match p.advance() {
    StrLit(s) =>
      match parse_interval_qty(s) {
        Some(v) => v
        None =>
          raise @types.SqlError::Parse(
            "bad INTERVAL quantity \"\{s}\" (expected an integer)",
          )
      }
    IntLit(v) => v.to_int64()
    Int64Lit(v) => v
    other => {
      let found = show_tok(other)
      raise @types.SqlError::Parse(
        "expected quantity after INTERVAL, found \{found}",
      )
    }
  }
  let qty = if neg { -qty } else { qty }
  let unit = match p.advance() {
    KwDay => Days
    KwMonth => Months
    KwYear => Years
    other => {
      let found = show_tok(other)
      raise @types.SqlError::Parse(
        "expected DAY, MONTH or YEAR in INTERVAL, found \{found}",
      )
    }
  }
  if p.eat(LParen) {
    match p.advance() {
      IntLit(_) | Int64Lit(_) => ()
      other => {
        let found = show_tok(other)
        raise @types.SqlError::Parse(
          "expected precision after '(', found \{found}",
        )
      }
    }
    p.expect(RParen)
  }
  IntervalLit(qty, unit)
}

///|
fn parse_interval_qty(s : String) -> Int64? {
  let chars : Array[Char] = []
  for ch in s {
    chars.push(ch)
  }
  if chars.length() == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if chars[0] == '-' || chars[0] == '+' {
    neg = chars[0] == '-'
    i = 1
  }
  if i >= chars.length() {
    return None
  }
  let mut v : Int64 = 0L
  while i < chars.length() {
    let d = chars[i].to_int() - 48
    if d < 0 || d > 9 {
      return None
    }
    v = v * 10L + d.to_int64()
    i = i + 1
  }
  Some(if neg { -v } else { v })
}

///|
fn parse_function(p : Parser, name : String) -> LExpr raise @types.SqlError {
  p.expect(LParen)
  let expr = match ascii_lower(name) {
    "sum" => {
      let inner = parse_or(p)
      p.expect(RParen)
      LExpr::Agg(AggFn::Sum, Some(inner))
    }
    "avg" => {
      let inner = parse_or(p)
      p.expect(RParen)
      LExpr::Agg(AggFn::Avg, Some(inner))
    }
    "min" => {
      let inner = parse_or(p)
      p.expect(RParen)
      LExpr::Agg(AggFn::Min, Some(inner))
    }
    "max" => {
      let inner = parse_or(p)
      p.expect(RParen)
      LExpr::Agg(AggFn::Max, Some(inner))
    }
    "stddev" | "stddev_samp" => {
      let inner = parse_or(p)
      p.expect(RParen)
      LExpr::Agg(AggFn::SdSamp, Some(inner))
    }
    "variance" | "var_samp" => {
      let inner = parse_or(p)
      p.expect(RParen)
      LExpr::Agg(AggFn::VarSamp, Some(inner))
    }
    "stddev_pop" => {
      let inner = parse_or(p)
      p.expect(RParen)
      LExpr::Agg(AggFn::SdPop, Some(inner))
    }
    "var_pop" => {
      let inner = parse_or(p)
      p.expect(RParen)
      LExpr::Agg(AggFn::VarPop, Some(inner))
    }
    "median" => {
      let inner = parse_or(p)
      p.expect(RParen)
      LExpr::Agg(AggFn::Median, Some(inner))
    }
    "string_agg" => {
      // two arguments; the separator must be a string literal and is
      // carried inside a marker call for the binder to fold
      let value = parse_or(p)
      p.expect(Comma)
      let sep = parse_or(p)
      p.expect(RParen)
      LExpr::Agg(AggFn::StringAgg, Some(Func("__string_agg", [value, sep])))
    }
    "count" =>
      if p.eat(Star) {
        p.expect(RParen)
        LExpr::Agg(AggFn::CountStar, None)
      } else if p.eat(KwDistinct) {
        let inner = parse_or(p)
        p.expect(RParen)
        LExpr::Agg(AggFn::CountDistinct, Some(inner))
      } else {
        let inner = parse_or(p)
        p.expect(RParen)
        LExpr::Agg(AggFn::Count, Some(inner))
      }
    "cast" => {
      // CAST(expr AS type): AS binds inside the call
      let e = parse_or(p)
      p.expect(KwAs)
      let dt = parse_type_name(p)
      p.expect(RParen)
      Cast(e, dt)
    }
    "substring" => {
      // both SQL forms: SUBSTRING(x, start, len) and the positional
      // SUBSTRING(x FROM start [FOR len])
      let args : Array[LExpr] = []
      args.push(parse_or(p))
      if p.eat(KwFrom) {
        args.push(parse_or(p))
        if p.peek() is Ident(fw) && ascii_lower(fw) == "for" {
          let _ = p.advance()
          args.push(parse_or(p))
        }
      } else {
        while p.eat(Comma) {
          args.push(parse_or(p))
        }
      }
      p.expect(RParen)
      Func("substring", args)
    }
    "length"
    | "upper"
    | "lower"
    | "trim"
    | "ltrim"
    | "rtrim"
    | "concat"
    | "abs"
    | "sqrt"
    | "floor"
    | "ceil"
    | "round"
    | "coalesce"
    | "greatest"
    | "least"
    | "nullif"
    | "date_trunc"
    | "date_diff"
    // ranking functions parse as plain calls; a binder error explains
    // the missing OVER when one never follows
    | "row_number"
    | "rank"
    | "dense_rank" => {
      let args : Array[LExpr] = []
      if !(p.peek() is RParen) {
        args.push(parse_or(p))
        while p.eat(Comma) {
          args.push(parse_or(p))
        }
      }
      p.expect(RParen)
      Func(ascii_lower(name), args)
    }
    _ => {
      p.pos -= 1 // rewind for a stable error position report
      raise @types.SqlError::Parse("unknown function \"\{name}\"")
    }
  }
  expr
}

///|
/// Type names accepted by CAST. INT32 is the default integer width.
fn parse_type_name(p : Parser) -> @types.DataType raise @types.SqlError {
  let t = p.advance()
  match t {
    Ident(name) =>
      match ascii_lower(name) {
        "int32" | "int" | "integer" => @types.Int32
        "int64" | "bigint" | "long" => @types.Int64
        "float64" | "double" | "float" => @types.Float64
        "bool" | "boolean" => @types.Bool
        "string" | "text" | "varchar" | "char" => @types.Str
        "date" => @types.Date
        other => raise @types.SqlError::Parse("unknown type name \"\{other}\"")
      }
    // DATE is a keyword (date literals) but a perfectly good cast target
    KwDate => @types.Date
    other => {
      let found = show_tok(other)
      raise @types.SqlError::Parse("expected type name, found \{found}")
    }
  }
}

///|
fn parse_case(p : Parser) -> LExpr raise @types.SqlError {
  // CASE WHEN c THEN r [WHEN ...] [ELSE e] END, plus the simple form
  // CASE expr WHEN v THEN r ... which desugars to equality comparisons
  let base : LExpr? = if p.peek() is KwWhen {
    None
  } else {
    Some(parse_or(p)) // the loop below consumes the first WHEN
  }
  let whens : Array[(LExpr, LExpr)] = []
  while p.eat(KwWhen) {
    let cond = parse_or(p)
    let cond = match base {
      Some(b) => Cmp(@types.Eq, b, cond)
      None => cond
    }
    p.expect(KwThen)
    let res = parse_or(p)
    whens.push((cond, res))
  }
  if whens.length() == 0 {
    raise @types.SqlError::Parse("CASE requires at least one WHEN branch")
  }
  let else_ = if p.eat(KwElse) { Some(parse_or(p)) } else { None }
  p.expect(KwEnd)
  Case(whens, else_)
}
