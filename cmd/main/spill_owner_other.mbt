// The other half of the spill owner protocol, for the backends without a native
// filesystem: wasm-gc, wasm and js.
//
// There is no `/proc` and no `O_EXCL` to build a claim on, so nothing is
// recorded and nothing is reclaimed — exactly the behaviour before the protocol
// existed. The functions keep their native signatures so that the rules in
// `spill_owner.mbt` compile unchanged on every backend, and so that the answer
// such a build gives is "cannot tell" rather than "stale": an unverifiable
// directory is kept.

///|
fn boot_id_here() -> String {
  ""
}

///|
fn probe_pid(_pid : Int32) -> PidProbe {
  PidOpaque("this backend has no /proc")
}

///|
fn self_mark() -> OwnerMark? {
  None
}

///|
fn self_nonce() -> String {
  "0"
}

///|
fn read_marker(_path : String) -> String? {
  None
}

///|
fn write_marker(_path : String, _text : String) -> Unit {
  ()
}

///|
fn rename_owner(_from : String, _to : String) -> Bool {
  false
}
