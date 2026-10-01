// Explicit method declarations for derived impls.
// On pub types, derive(Debug, Eq) implicitly promotes to_repr / equal /
// not_equal to regular methods; that promotion is deprecated and trips
// the CI --deny-warn gate. Declaring them explicitly keeps check clean.

///|
pub extend DataType with Eq::{equal, not_equal}

///|
pub extend DataType with @debug.Debug::{to_repr}

///|
pub extend Scalar with Eq::{equal, not_equal}

///|
pub extend Scalar with @debug.Debug::{to_repr}

///|
pub extend SqlError with Eq::{equal, not_equal}

///|
pub extend SqlError with @debug.Debug::{to_repr}

///|
pub extend ArithOp with Eq::{equal, not_equal}

///|
pub extend ArithOp with @debug.Debug::{to_repr}

///|
pub extend CmpOp with Eq::{equal, not_equal}

///|
pub extend CmpOp with @debug.Debug::{to_repr}
