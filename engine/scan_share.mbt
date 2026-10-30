// Sharing a table's decoded columns between the scans of one query (contract:
// docs/ROADMAP.md, "The shared table scan contract"). A query that names a lazy
// table more than once (q21 names lineitem three times, two of them as
// decorrelated EXISTS sides) used to index and decode the file once per name.

///|
/// Every column name and table name a statement mentions, so a caller can tell
/// which table is scanned more than once and which of its columns any of those
/// scans may ask for. The column match is by name and deliberately wide: naming a
/// column the query never reads only costs memory, never an answer.
priv struct NameWalk {
  columns : Map[String, Bool]
  tables : Map[String, Int32]
  mut unsafe_ : Bool // a shape this walk does not describe: share nothing
}

///|
fn NameWalk::expr(self : NameWalk, e : @sql.LExpr) -> Unit {
  match e {
    Col(n) => self.columns[n.to_lower()] = true
    ColQ(_, n) => self.columns[n.to_lower()] = true
    Lit(_) | IntervalLit(_, _) => ()
    Arith(_, a, b)
    | Cmp(_, a, b)
    | And(a, b)
    | Or(a, b)
    | Like(a, b)
    | NotLike(a, b) => {
      self.expr(a)
      self.expr(b)
    }
    Not(a) | IsNull(a, _) | Extract(_, a) | Cast(a, _) => self.expr(a)
    Between(a, b, c) => {
      self.expr(a)
      self.expr(b)
      self.expr(c)
    }
    In(a, xs) | NotIn(a, xs) => {
      self.expr(a)
      for x in xs {
        self.expr(x)
      }
    }
    Star => self.unsafe_ = true
    Case(whens, els) => {
      for w in whens {
        self.expr(w.0)
        self.expr(w.1)
      }
      match els {
        Some(x) => self.expr(x)
        None => ()
      }
    }
    Agg(_, arg) =>
      match arg {
        Some(x) => self.expr(x)
        None => ()
      }
    ScalarSub(s) => self.select(s)
    InSelect(a, s, _) => {
      self.expr(a)
      self.select(s)
    }
    // an EXISTS never reads its select list, so `select *` there names nothing
    Exists(s, _) => self.select_with(s, false)
    Func(_, args) =>
      for x in args {
        self.expr(x)
      }
  }
}

///|
fn NameWalk::select(self : NameWalk, s : @sql.Select) -> Unit {
  self.select_with(s, true)
}

///|
fn NameWalk::select_with(
  self : NameWalk,
  s : @sql.Select,
  items : Bool,
) -> Unit {
  if s.windows.length() > 0 {
    self.unsafe_ = true
  }
  for f in s.from {
    match f.table {
      Named(n) => self.tables[n] = self.tables.get(n).unwrap_or(0) + 1
      Sub(q) => self.select(q)
    }
    match f.on {
      Some(x) => self.expr(x)
      None => ()
    }
  }
  match s.filter {
    Some(x) => self.expr(x)
    None => ()
  }
  for g in s.group_by {
    self.expr(g)
  }
  match s.having {
    Some(x) => self.expr(x)
    None => ()
  }
  if items {
    for item in s.items {
      self.expr(item.expr)
    }
  }
  for o in s.order_by {
    self.expr(o.key)
  }
  match s.setop {
    Some((_, _, right)) => self.select(right)
    None => ()
  }
}

///|
/// One lazy table whose scans share their decoded columns. `union` is the columns
/// any scan of the query may ask for (ascending); the first scan decodes all of
/// them once, later scans project the cached batches, and the cache is let go when
/// the last expected scan has opened. A scan that asks for a column outside the
/// union, or in another order, is simply passed through.
priv struct SharedScan {
  inner : &@catalog.ScanSource
  union : Array[Int32]
  mut opens_left : Int32
  mut cache : Array[@types.DataBatch]?
}

///|
priv struct SharedStream {
  batches : Array[@types.DataBatch]
  mut index : Int32
}

///|
impl @catalog.BatchStream for SharedStream with fn next(self) -> @types.DataBatch? raise @types.SqlError {
  if self.index >= self.batches.length() {
    return None
  }
  let batch = self.batches[self.index]
  self.index += 1
  Some(batch)
}

///|
impl @catalog.ScanSource for SharedScan with fn open(
  self,
  request : @catalog.ScanRequest,
) -> &@catalog.BatchStream raise @types.SqlError {
  // The expected scans are used up and the cache is gone: a further open is a
  // scan the walk did not count (the engine can open a table more often than
  // the statement names it), and refilling the cache for it would decode the
  // whole union and hold every batch for a reader that gains nothing.
  if self.opens_left <= 0 {
    return self.inner.open(request)
  }
  let positions : Array[Int32] = []
  for c in request.projection {
    let mut found = -1
    for i, u in self.union {
      if u == c {
        found = i
      }
    }
    if found < 0 ||
      (positions.length() > 0 && found <= positions[positions.length() - 1]) {
      return self.inner.open(request)
    }
    positions.push(found)
  }
  // The hints are advisory, so the cache is filled with every row.
  let batches = match self.cache {
    Some(b) => b
    None => {
      let stream = self.inner.open(@catalog.ScanRequest::new(self.union, []))
      let all : Array[@types.DataBatch] = []
      while stream.next() is Some(b) {
        all.push(b)
      }
      self.cache = Some(all)
      all
    }
  }
  self.opens_left -= 1
  if self.opens_left <= 0 {
    self.cache = None
  }
  let projected = @catalog.project_batches(batches, positions)
  (SharedStream::{ batches: projected, index: 0, } : &@catalog.BatchStream)
}

///|
impl @catalog.ScanSource for SharedScan with fn plan(
  self,
  request : @catalog.ScanRequest,
) -> @catalog.ScanPlan raise @types.SqlError {
  self.inner.plan(request)
}

///|
/// The catalog one query should run against: the same tables, except that a lazy
/// table the statement names more than once shares its decoded columns between
/// those scans. Without a budget only (a budgeted run holds nothing it can avoid),
/// and only for statements this walk fully describes.
fn share_repeated_scans(
  sel : @sql.Select,
  catalog : @catalog.Catalog,
  opts : ExecOptions,
) -> @catalog.Catalog {
  if opts.budget > 0 {
    return catalog
  }
  let walk : NameWalk = { columns: {}, tables: {}, unsafe_: false, }
  walk.select(sel)
  if walk.unsafe_ {
    return catalog
  }
  let shared = @catalog.Catalog::new()
  let mut any = false
  for name, n in walk.tables {
    match catalog.lookup(name) {
      None => ()
      Some(entry) => {
        if entry.schema.table != name {
          return catalog
        }
        match entry.source {
          Some(src) if n >= 2 => {
            let width = entry.schema.columns.length()
            let union : Array[Int32] = []
            for c in 0..<width {
              if walk.columns.get(entry.schema.columns[c].name.to_lower())
                is Some(_) {
                union.push(c)
              }
            }
            if union.length() > 0 && union.length() < width {
              shared.register(
                @catalog.TableEntry::from_source(
                  entry.schema,
                  (
                    SharedScan::{
                      inner: src,
                      union,
                      opens_left: n,
                      cache: None,
                    } : &@catalog.ScanSource),
                ),
              )
              any = true
            } else {
              shared.register(entry)
            }
          }
          _ => shared.register(entry)
        }
      }
    }
  }
  if any {
    shared
  } else {
    catalog
  }
}
