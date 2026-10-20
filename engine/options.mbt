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
  write : (Bytes) -> Int32 raise @types.SqlError
  read : (Int32) -> Bytes raise @types.SqlError
  remove : (Int32) -> Unit raise @types.SqlError
}

///|
pub(all) struct ExecOptions {
  budget : Int32 // approximate byte budget for blocking operators; <= 0 = unlimited (in-memory)
  spill : SpillStore? // required once budget > 0; without a store an over-budget query is an error
}

///|
/// Default options: unlimited memory, no spill store — the historical
/// in-memory behavior.
pub fn ExecOptions::in_memory() -> ExecOptions {
  { budget: 0, spill: None, }
}

///|
/// What a query actually pushed through its spill store. Counted at the
/// store boundary (one wrapper around the caller's `SpillStore`) rather
/// than inside each operator, so a new spilling operator cannot forget
/// to report itself, and so the numbers are what the filesystem saw.
priv struct SpillMeter {
  mut files : Int32
  mut written : Int64
  mut read : Int64
}

///|
fn SpillMeter::new() -> SpillMeter {
  { files: 0, written: 0L, read: 0L, }
}

///|
/// Wrap a store so every byte that crosses it is counted. Ids pass
/// through unchanged, so the wrapped store is a drop-in replacement.
fn SpillMeter::wrap(self : SpillMeter, base : SpillStore) -> SpillStore {
  {
    write: fn(bytes : Bytes) -> Int32 raise @types.SqlError {
      let id = (base.write)(bytes)
      self.files += 1
      self.written += bytes.length().to_int64()
      id
    },
    read: fn(id : Int32) -> Bytes raise @types.SqlError {
      let bytes = (base.read)(id)
      self.read += bytes.length().to_int64()
      bytes
    },
    remove: fn(id : Int32) -> Unit raise @types.SqlError { (base.remove)(id) },
  }
}

///|
/// The meter's lines for `explain_analyze`: only when something was
/// actually spilled, so an in-memory plan stays as short as before.
fn SpillMeter::report(
  self : SpillMeter,
  stats : Array[(String, Int64)],
) -> Unit {
  if self.files == 0 {
    return
  }
  stats.push(("spill files", self.files.to_int64()))
  stats.push(("spill bytes written", self.written))
  stats.push(("spill bytes read", self.read))
}
