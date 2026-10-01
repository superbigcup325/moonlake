// Tokenizer for the W1 SQL subset. Keywords are case-insensitive;
// identifiers, numbers (int/double with exponent), single-quoted strings
// (with '' escape), DATE 'yyyy-mm-dd' literals and line comments.

///|
priv enum Tok {
  Ident(String)
  IntLit(Int)
  DoubleLit(Double)
  StrLit(String)
  BoolLit(Bool)
  LParen
  RParen
  Comma
  Star
  Plus
  Minus
  Slash
  Percent
  Eq
  Neq
  Lt
  Le
  Gt
  Ge
  KwSelect
  KwFrom
  KwWhere
  KwAs
  KwAnd
  KwOr
  KwNot
  KwBetween
  KwDate
  KwGroup
  KwBy
  KwHaving
  KwOrder
  KwAsc
  KwDesc
  KwLimit
  KwCase
  KwWhen
  KwThen
  KwElse
  KwEnd
  KwLike
  KwIn
  KwDistinct
  Eof
} derive(Eq)

///|
priv struct Lexer {
  chars : Array[Char]
  mut pos : Int
}

///|
fn Lexer::peek(self : Lexer) -> Char {
  self.chars[self.pos]
}

///|
fn lex_sql(sql : String) -> Array[Tok] raise @types.SqlError {
  let chars : Array[Char] = []
  for ch in sql {
    chars.push(ch)
  }
  let lx : Lexer = { chars, pos: 0, }
  let toks : Array[Tok] = []
  let n = chars.length()
  while lx.pos < n {
    let ch = lx.peek()
    if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
      lx.pos += 1
      continue
    }
    if ch == '-' && lx.pos + 1 < n && chars[lx.pos + 1] == '-' {
      while lx.pos < n && chars[lx.pos] != '\n' {
        lx.pos += 1
      }
      continue
    }
    if is_letter(ch) || ch == '_' {
      let word = lx.lex_word()
      toks.push(keyword_or_ident(word))
      continue
    }
    if ch.to_int() >= 48 && ch.to_int() <= 57 {
      toks.push(lx.lex_number())
      continue
    }
    if ch == '\'' {
      toks.push(lx.lex_string())
      continue
    }
    match ch {
      '(' => {
        toks.push(LParen)
        lx.pos += 1
      }
      ')' => {
        toks.push(RParen)
        lx.pos += 1
      }
      ',' => {
        toks.push(Comma)
        lx.pos += 1
      }
      '*' => {
        toks.push(Star)
        lx.pos += 1
      }
      '+' => {
        toks.push(Plus)
        lx.pos += 1
      }
      '-' => {
        toks.push(Minus)
        lx.pos += 1
      }
      '/' => {
        toks.push(Slash)
        lx.pos += 1
      }
      '%' => {
        toks.push(Percent)
        lx.pos += 1
      }
      '<' => {
        lx.pos += 1
        if lx.pos < n && chars[lx.pos] == '>' {
          toks.push(Neq)
          lx.pos += 1
        } else if lx.pos < n && chars[lx.pos] == '=' {
          toks.push(Le)
          lx.pos += 1
        } else {
          toks.push(Lt)
        }
      }
      '>' => {
        lx.pos += 1
        if lx.pos < n && chars[lx.pos] == '=' {
          toks.push(Ge)
          lx.pos += 1
        } else {
          toks.push(Gt)
        }
      }
      '=' => {
        toks.push(Eq)
        lx.pos += 1
      }
      '!' => {
        lx.pos += 1
        if lx.pos < n && chars[lx.pos] == '=' {
          toks.push(Neq)
          lx.pos += 1
        } else {
          raise @types.SqlError::Parse("unexpected '!' (expected <>)")
        }
      }
      _ =>
        raise @types.SqlError::Parse(
          "unexpected character '\{ch}' at position \{lx.pos}",
        )
    }
  }
  toks.push(Eof)
  toks
}

///|
fn is_letter(ch : Char) -> Bool {
  let v = ch.to_int()
  (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
}

///|
fn is_digit_ch(ch : Char) -> Bool {
  let v = ch.to_int()
  v >= 48 && v <= 57
}

///|
fn Lexer::lex_word(self : Lexer) -> String {
  let sb = StringBuilder()
  let n = self.chars.length()
  while self.pos < n {
    let ch = self.chars[self.pos]
    if is_letter(ch) || ch == '_' || is_digit_ch(ch) {
      sb.write_char(ch)
      self.pos += 1
    } else {
      break
    }
  }
  sb.to_string()
}

///|
fn ascii_lower(word : String) -> String {
  let sb = StringBuilder()
  for ch in word {
    let v = ch.to_int()
    if v >= 65 && v <= 90 {
      sb.write_char((v + 32).to_char().unwrap())
    } else {
      sb.write_char(ch)
    }
  }
  sb.to_string()
}

///|
fn keyword_or_ident(word : String) -> Tok {
  match ascii_lower(word) {
    "select" => KwSelect
    "from" => KwFrom
    "where" => KwWhere
    "as" => KwAs
    "and" => KwAnd
    "or" => KwOr
    "not" => KwNot
    "between" => KwBetween
    "date" => KwDate
    "group" => KwGroup
    "by" => KwBy
    "having" => KwHaving
    "order" => KwOrder
    "asc" => KwAsc
    "desc" => KwDesc
    "limit" => KwLimit
    "case" => KwCase
    "when" => KwWhen
    "then" => KwThen
    "else" => KwElse
    "end" => KwEnd
    "like" => KwLike
    "in" => KwIn
    "distinct" => KwDistinct
    "true" => BoolLit(true)
    "false" => BoolLit(false)
    _ => Ident(word)
  }
}

///|
fn Lexer::lex_number(self : Lexer) -> Tok raise @types.SqlError {
  let sb = StringBuilder()
  let n = self.chars.length()
  let mut is_double = false
  while self.pos < n {
    let ch = self.chars[self.pos]
    let v = ch.to_int()
    if v >= 48 && v <= 57 {
      sb.write_char(ch)
      self.pos += 1
    } else if ch == '.' {
      is_double = true
      sb.write_char(ch)
      self.pos += 1
    } else if ch == 'e' || ch == 'E' {
      is_double = true
      sb.write_char(ch)
      self.pos += 1
      if self.pos < n &&
        (self.chars[self.pos] == '-' || self.chars[self.pos] == '+') {
        sb.write_char(self.chars[self.pos])
        self.pos += 1
      }
    } else {
      break
    }
  }
  let text = sb.to_string()
  if is_double {
    match @types.parse_f64(text) {
      Some(v) => DoubleLit(v)
      None => raise @types.SqlError::Parse("bad number literal \"\{text}\"")
    }
  } else {
    match @types.parse_i32(text) {
      Some(v) => IntLit(v)
      None => raise @types.SqlError::Parse("bad integer literal \"\{text}\"")
    }
  }
}

///|
fn Lexer::lex_string(self : Lexer) -> Tok raise @types.SqlError {
  // assumes chars[self.pos] == '\''
  self.pos += 1
  let sb = StringBuilder()
  let n = self.chars.length()
  let mut closed = false
  while self.pos < n {
    let ch = self.chars[self.pos]
    if ch == '\'' {
      if self.pos + 1 < n && self.chars[self.pos + 1] == '\'' {
        sb.write_char('\'') // '' escape
        self.pos += 2
      } else {
        self.pos += 1
        closed = true
        break
      }
    } else {
      sb.write_char(ch)
      self.pos += 1
    }
  }
  if !closed {
    raise @types.SqlError::Parse("unterminated string literal")
  }
  StrLit(sb.to_string())
}
