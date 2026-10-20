// Row-group pruning: Parquet stores per-column-chunk min/max plus a null
// count, so a predicate can rule a whole group out without reading a page.
//
// Two rules keep this safe. Only predicates the engine also applies are
// passed in (see ScanPredicate), and a bound is used only when it is
// provably a bound: the current min_value/max_value fields, not marked
// inexact, decoded from the column's physical type. Anything doubtful
// (no statistics, the deprecated signed-order footer pair on BYTE_ARRAY,
// unresolvable strings) simply keeps the group.

///|
/// One decoded bound. Kept separate from Scalar because it is compared
/// against the predicate's constant with the engine's own ordering.
priv enum Bound {
  BInt(Int64)
  BFloat(Double)
  BStr(String)
  BBool(Bool)
}

///|
/// Decode the strict UTF-8 string a statistics field holds, or None. The
/// reader decodes BYTE_ARRAY values lossily, so a value that is not valid
/// UTF-8 would compare differently from the column's own rows — those
/// statistics are unusable.
fn strict_utf8(bytes : Bytes) -> String? {
  let s = @utf8.decode(bytes) catch { _ => return None }
  Some(s)
}

///|
/// Little-endian 4-byte integer; callers check the length first.
fn le_int32(b : Bytes) -> Int32 {
  let mut v : Int32 = 0
  for i in 0..<4 {
    v = v | (b[i].to_int() << (8 * i))
  }
  v
}

///|
fn le_int64(b : Bytes) -> Int64 {
  let mut v : UInt64 = 0UL
  for i in 0..<8 {
    v = v | (b[i].to_int().to_uint64() << (8 * i))
  }
  v.reinterpret_as_int64()
}

///|
/// One statistics field, decoded according to the column's physical type.
fn bound_of(el : SchemaElement, bytes : Bytes) -> Bound? {
  match el.physical {
    Some(BooleanT) =>
      if bytes.length() == 1 {
        Some(BBool(bytes[0].to_int() != 0))
      } else {
        None
      }
    Some(Int32T) =>
      if bytes.length() == 4 {
        Some(BInt(le_int32(bytes).to_int64()))
      } else {
        None
      }
    Some(Int64T) =>
      if bytes.length() == 8 {
        Some(BInt(le_int64(bytes)))
      } else {
        None
      }
    Some(FloatT) =>
      if bytes.length() == 4 {
        Some(BFloat(Float::reinterpret_from_int(le_int32(bytes)).to_double()))
      } else {
        None
      }
    Some(DoubleT) =>
      if bytes.length() == 8 {
        Some(BFloat(le_int64(bytes).reinterpret_as_double()))
      } else {
        None
      }
    Some(ByteArrayT) =>
      match strict_utf8(bytes) {
        Some(s) => Some(BStr(s))
        None => None
      }
    _ => None
  }
}

///|
/// The (min, max) bound pair of one column chunk, when it can be trusted.
fn bounds_for(el : SchemaElement, stats : Statistics) -> (Bound, Bound)? {
  // an explicitly inexact bound may be a truncation: not a bound we can use
  if stats.is_min_exact is Some(false) || stats.is_max_exact is Some(false) {
    return None
  }
  let (min_bytes, max_bytes) = match (stats.min_value, stats.max_value) {
    (Some(lo), Some(hi)) => (lo, hi)
    _ =>
      // the deprecated pair is safe for numeric types only: for BYTE_ARRAY it
      // was defined in signed byte order, which is not the string order
      match el.physical {
        Some(ByteArrayT) => return None
        _ =>
          match (stats.min_deprecated, stats.max_deprecated) {
            (Some(lo), Some(hi)) => (lo, hi)
            _ => return None
          }
      }
  }
  match (bound_of(el, min_bytes), bound_of(el, max_bytes)) {
    (Some(lo), Some(hi)) => Some((lo, hi))
    _ => None
  }
}

///|
/// Integer ordering test: can no value in [lo, hi] satisfy `value op ...`?
fn excludes_int(op : @types.CmpOp, v : Int64, lo : Int64, hi : Int64) -> Bool {
  match op {
    @types.Eq => v < lo || v > hi
    // every value equals v: `!= v` matches nothing
    @types.Neq => lo == hi && lo == v
    @types.Lt => lo >= v
    @types.Le => lo > v
    @types.Gt => hi <= v
    @types.Ge => hi < v
  }
}

///|
/// Floats get a narrower rule than the integer types, because this engine's
/// `Scalar::compare` falls through to "equal" for NaN: a NaN row satisfies
/// `= c`, `<= c` and `>= c` and fails `<> c`, so a writer that omitted NaN
/// from its statistics (the common case) would otherwise let those operators
/// drop a group that does hold a match. Only the strict comparisons are
/// NaN-proof, and a bound that is itself NaN never excludes anything.
fn excludes_float(
  op : @types.CmpOp,
  v : Double,
  lo : Double,
  hi : Double,
) -> Bool {
  match op {
    @types.Lt => lo >= v
    @types.Gt => hi <= v
    _ => false
  }
}

///|
fn excludes_str(
  op : @types.CmpOp,
  v : String,
  lo : String,
  hi : String,
) -> Bool {
  let c_lo = String::lexical_compare(lo, v)
  let c_hi = String::lexical_compare(hi, v)
  match op {
    @types.Eq => c_lo > 0 || c_hi < 0
    @types.Neq =>
      String::lexical_compare(lo, hi) == 0 &&
      String::lexical_compare(lo, v) == 0
    @types.Lt => c_lo >= 0
    @types.Le => c_lo > 0
    @types.Gt => c_hi <= 0
    @types.Ge => c_hi < 0
  }
}

///|
/// Can no row of the chunk satisfy this predicate? A NULL never satisfies a
/// comparison, so the answer depends only on the non-null range.
fn excludes(
  dtype : @types.DataType,
  pred : @catalog.ScanPredicate,
  bounds : (Bound, Bound)?,
) -> Bool {
  match bounds {
    None => false
    Some((lo, hi)) =>
      match (pred.value, lo, hi) {
        (Int32(v), BInt(a), BInt(b)) =>
          dtype is @types.Int32 && excludes_int(pred.op, v.to_int64(), a, b)
        (Date(v), BInt(a), BInt(b)) =>
          dtype is @types.Date && excludes_int(pred.op, v.to_int64(), a, b)
        (Int64(v), BInt(a), BInt(b)) =>
          dtype is @types.Int64 && excludes_int(pred.op, v, a, b)
        (Float64(v), BFloat(a), BFloat(b)) =>
          dtype is @types.Float64 && excludes_float(pred.op, v, a, b)
        (Str(v), BStr(a), BStr(b)) =>
          dtype is @types.Str && excludes_str(pred.op, v, a, b)
        (Boolean(v), BBool(a), BBool(b)) =>
          dtype is @types.Bool &&
          ({
            let x = if v { 1L } else { 0L }
            let lo = if a { 1L } else { 0L }
            let hi = if b { 1L } else { 0L }
            excludes_int(pred.op, x, lo, hi)
          })
        _ => false
      }
  }
}

///|
/// Whether one row group can be skipped for the whole request: a single
/// predicate that no row of the group can satisfy is enough.
fn group_skipped(
  rg : RowGroupMeta,
  leaves : Array[(SchemaElement, Int32)],
  dtypes : Array[@types.DataType],
  request : @catalog.ScanRequest,
) -> Bool {
  for pred in request.predicates {
    let c = pred.column
    if c < 0 || c >= rg.columns.length() || c >= leaves.length() {
      continue
    }
    let cm = rg.columns[c]
    let stats = match cm.stats {
      Some(s) => s
      None => continue
    }
    // an all-NULL group satisfies no comparison at all
    match stats.null_count {
      Some(n) => if n >= rg.num_rows { return true }
      None => ()
    }
    let el = leaves[c].0
    if excludes(dtypes[c], pred, bounds_for(el, stats)) {
      return true
    }
  }
  false
}
