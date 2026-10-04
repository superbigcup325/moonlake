// Operator enums shared by the parser AST, binder and evaluator.

///|
pub(all) enum ArithOp {
  Add
  Sub
  Mul
  Div
  Mod
} derive(Eq, Debug)

///|
pub(all) enum CmpOp {
  Eq
  Neq
  Lt
  Le
  Gt
  Ge
} derive(Eq, Debug)

///|
/// The operator that compares swapped operands: `a < b` is `b.flip > a`.
pub fn CmpOp::flip(self : CmpOp) -> CmpOp {
  match self {
    Eq => Eq
    Neq => Neq
    Lt => Gt
    Le => Ge
    Gt => Lt
    Ge => Le
  }
}

///|
/// Apply a comparison operator to a three-valued ordering result
/// (Scalar::compare output): None ordering stays NULL.
pub fn CmpOp::apply(self : CmpOp, ord : Int?) -> Scalar {
  match ord {
    None => Null
    Some(o) =>
      match self {
        Eq => Boolean(o == 0)
        Neq => Boolean(o != 0)
        Lt => Boolean(o < 0)
        Le => Boolean(o <= 0)
        Gt => Boolean(o > 0)
        Ge => Boolean(o >= 0)
      }
  }
}
