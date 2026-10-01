// Recursive-descent parser for the W1 subset:
//   SELECT item [, item]* FROM table [WHERE expr]
// Precedence (low to high): OR, AND, NOT, comparison/BETWEEN, + -, * / %, unary -.

///|
priv struct Parser {
  toks : Array[Tok]
  mut pos : Int
}

///|
fn Parser::peek(self : Parser) -> Tok {
  self.toks[self.pos]
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
    DoubleLit(v) => "number \{v}"
    StrLit(_) => "string literal"
    LParen => "'('"
    RParen => "')'"
    Comma => "','"
    Star => "'*'"
    Plus => "'+'"
    Minus => "'-'"
    Slash => "'/'"
    Percent => "'%'"
    Eq => "'='"
    Neq => "'<>'"
    Lt => "'<'"
    Le => "'<='"
    Gt => "'>'"
    Ge => "'>='"
    KwSelect => "SELECT"
    KwFrom => "FROM"
    KwWhere => "WHERE"
    KwAs => "AS"
    KwAnd => "AND"
    KwOr => "OR"
    KwNot => "NOT"
    KwBetween => "BETWEEN"
    KwDate => "DATE"
    KwSum => "SUM"
    Eof => "end of input"
  }
}

///|
pub fn parse_select(sql : String) -> Select raise @types.SqlError {
  let p : Parser = { toks: lex_sql(sql), pos: 0, }
  p.expect(KwSelect)
  let items : Array[SelectItem] = []
  items.push(parse_item(p))
  while p.eat(Comma) {
    items.push(parse_item(p))
  }
  p.expect(KwFrom)
  let table = match p.advance() {
    Ident(name) => name
    other => {
      let found = show_tok(other)
      raise @types.SqlError::Parse(
        "expected table name after FROM, found \{found}",
      )
    }
  }
  let filter = if p.eat(KwWhere) { Some(parse_or(p)) } else { None }
  p.expect(Eof)
  { table, filter, items, }
}

///|
fn parse_item(p : Parser) -> SelectItem raise @types.SqlError {
  let expr = parse_or(p)
  let label = if p.eat(KwAs) {
    match p.advance() {
      Ident(name) => Some(name)
      other => {
        let found = show_tok(other)
        raise @types.SqlError::Parse("expected alias after AS, found \{found}")
      }
    }
  } else if p.peek() is Ident(name) {
    // bare alias: SELECT sum(x) revenue FROM ...
    let _ = p.advance()
    Some(name)
  } else {
    None
  }
  { expr, label, }
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
  let op = match p.peek() {
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
    Ident(name) => Col(name)
    IntLit(v) => Lit(@types.Scalar::Int32(v))
    DoubleLit(v) => Lit(@types.Scalar::Float64(v))
    StrLit(s) => Lit(@types.Scalar::Str(s))
    LParen => {
      let e = parse_or(p)
      p.expect(RParen)
      e
    }
    KwDate =>
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
          raise @types.SqlError::Parse(
            "expected string after DATE, found \{found}",
          )
        }
      }
    KwSum => {
      p.expect(LParen)
      let inner = parse_or(p)
      p.expect(RParen)
      Agg(Sum, inner)
    }
    other => {
      let found = show_tok(other)
      raise @types.SqlError::Parse("unexpected \{found} in expression")
    }
  }
}
