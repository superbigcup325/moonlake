// Recursive-descent parser for the W2 subset:
//   SELECT item [, item]* FROM table [WHERE expr] [GROUP BY expr[, expr]*]
//   [HAVING expr] [ORDER BY key [ASC|DESC][, ...]] [LIMIT n]
// Aggregates parse as function calls (sum/avg/min/max/count, with count(*)
// and count(DISTINCT x) forms).
// Precedence (low to high): OR, AND, NOT, comparison/BETWEEN/IN/LIKE,
// + -, * / %, unary -.

///|
priv struct Parser {
  toks : Array[Tok]
  mut pos : Int
  // WITH cte AS (SELECT ...) name -> body token slice; a reference
  // re-parses the slice into a fresh derived table per occurrence
  ctes : Map[String, Array[Tok]]
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
    Eof => "end of input"
  }
}

///|
pub fn parse_select(sql : String) -> Select raise @types.SqlError {
  let p : Parser = { toks: lex_sql(sql), pos: 0, ctes: Map([]), }
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
/// inside a derived table).
fn parse_select_body(p : Parser) -> Select raise @types.SqlError {
  let distinct = p.eat(KwDistinct)
  let items : Array[SelectItem] = []
  items.push(parse_item(p))
  while p.eat(Comma) {
    items.push(parse_item(p))
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
  {
    from,
    filter,
    group_by,
    having,
    items,
    order_by,
    limit,
    offset,
    distinct,
    setop: None,
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
  let sub : Parser = { toks: self.ctes[name], pos: 0, ctes: self.ctes, }
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
        parse_function(p, name)
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
      Agg(Sum, Some(inner))
    }
    "avg" => {
      let inner = parse_or(p)
      p.expect(RParen)
      Agg(Avg, Some(inner))
    }
    "min" => {
      let inner = parse_or(p)
      p.expect(RParen)
      Agg(Min, Some(inner))
    }
    "max" => {
      let inner = parse_or(p)
      p.expect(RParen)
      Agg(Max, Some(inner))
    }
    "count" =>
      if p.eat(Star) {
        p.expect(RParen)
        Agg(CountStar, None)
      } else if p.eat(KwDistinct) {
        let inner = parse_or(p)
        p.expect(RParen)
        Agg(CountDistinct, Some(inner))
      } else {
        let inner = parse_or(p)
        p.expect(RParen)
        Agg(Count, Some(inner))
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
    | "nullif" => {
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
