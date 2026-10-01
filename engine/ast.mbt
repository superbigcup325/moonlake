// Logical AST produced by the W1 subset parser. The binder lowers this
// to column-index based physical expressions (see binder.mbt).

///|
pub(all) enum AggFn {
  Sum
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
  Agg(AggFn, LExpr)
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
/// W1 subset: one table, optional WHERE, aggregate-only select items.
pub(all) struct Select {
  table : String
  filter : LExpr?
  items : Array[SelectItem]
} derive(Eq, Debug)

///|
pub extend Select with Eq::{equal, not_equal}

///|
pub extend Select with @debug.Debug::{to_repr}
