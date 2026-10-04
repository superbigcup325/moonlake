// Execution options: the memory budget and the spill store injection.
//
// The engine never touches the filesystem (wasm/js must keep
// compiling): a caller that wants out-of-core behavior provides a
// SpillStore — the native CLI injects a directory-backed store from
// the spill package; the playground simply omits it. Function fields
// instead of a trait: MoonBit traits are not types, and the store is
// always injected as a value.

///|
/// Storage for spilled intermediate state (sorted runs today). Ids are
/// opaque and scoped to one query; the engine removes everything it
/// wrote when the query ends, successfully or not.
pub(all) struct SpillStore {
  write : (Bytes) -> Int raise @types.SqlError
  read : (Int) -> Bytes raise @types.SqlError
  remove : (Int) -> Unit raise @types.SqlError
}

///|
pub(all) struct ExecOptions {
  budget : Int // approximate byte budget for blocking operators; <= 0 = unlimited (in-memory)
  spill : SpillStore? // required once budget > 0; without a store an over-budget query is an error
}

///|
/// Default options: unlimited memory, no spill store — the historical
/// in-memory behavior.
pub fn ExecOptions::in_memory() -> ExecOptions {
  { budget: 0, spill: None, }
}
