// Logical AST produced by the subset parser. The binder lowers this
// to column-index based physical expressions (see binder.mbt).

///|
pub(all) enum AggFn {
  Sum
  Avg
  Count // count(expr): counts non-null inputs
  CountStar // count(*): counts rows
  CountDistinct
  Min
  Max
} derive(Eq, Debug)

///|
pub extend AggFn with Eq::{equal, not_equal}

///|
pub extend AggFn with @debug.Debug::{to_repr}

///|
pub(all) enum LExpr {
  Col(String)
  Lit(@types.Scalar)
  Arith(@types.ArithOp, LExpr, LExpr)
  Cmp(@types.CmpOp, LExpr, LExpr)
  And(LExpr, LExpr)
  Or(LExpr, LExpr)
  Not(LExpr)
  Between(LExpr, LExpr, LExpr) // value, low, high (both inclusive)
  In(LExpr, Array[LExpr]) // binder desugars into an OR-chain of equalities
  Like(LExpr, LExpr) // pattern must fold to a string constant
  Case(Array[(LExpr, LExpr)], LExpr?) // searched CASE: (when, then)*, else?
  Agg(AggFn, LExpr?) // None only for count(*)
} derive(Eq, Debug)

///|
pub extend LExpr with Eq::{equal, not_equal}

///|
pub extend LExpr with @debug.Debug::{to_repr}

///|
pub(all) struct SelectItem {
  expr : LExpr
  label : String?
} derive(Eq, Debug)

///|
pub extend SelectItem with Eq::{equal, not_equal}

///|
pub extend SelectItem with @debug.Debug::{to_repr}

///|
pub(all) struct OrderItem {
  key : LExpr
  desc : Bool
} derive(Eq, Debug)

///|
pub extend OrderItem with Eq::{equal, not_equal}

///|
pub extend OrderItem with @debug.Debug::{to_repr}

///|
/// How a FROM item attaches to the accumulated rows before it. The
/// first item's kind is meaningless (Inner, ignored).
pub(all) enum JoinKind {
  Inner // comma lists and JOIN ... ON
  Left // LEFT [OUTER] JOIN ... ON
  Cross // CROSS JOIN
} derive(Eq, Debug)

///|
pub extend JoinKind with Eq::{equal, not_equal}

///|
pub extend JoinKind with @debug.Debug::{to_repr}

///|
pub(all) struct FromItem {
  table : String
  join : JoinKind
  on : LExpr? // ON condition for explicit joins
} derive(Eq, Debug)

///|
pub extend FromItem with Eq::{equal, not_equal}

///|
pub extend FromItem with @debug.Debug::{to_repr}

///|
/// W2 subset: the full select pipeline over a FROM chain joined in
/// written order (left-deep; comma lists behave as INNER joins with the
/// join conditions supplied by WHERE).
pub(all) struct Select {
  from : Array[FromItem]
  filter : LExpr?
  group_by : Array[LExpr]
  having : LExpr?
  items : Array[SelectItem]
  order_by : Array[OrderItem]
  limit : Int?
} derive(Eq, Debug)

///|
pub extend Select with Eq::{equal, not_equal}

///|
pub extend Select with @debug.Debug::{to_repr}
