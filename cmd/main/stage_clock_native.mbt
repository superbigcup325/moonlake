// The clock `--analyze` times its stages with, on a target that has one. The
// engine's report is deterministic on purpose, so the clock is installed by the
// caller that asked for durations and nowhere else.
//
// A platform without a monotonic clock compiles stage_clock_other.mbt instead,
// which installs none: the report then says what it always did.

///|
/// The monotonic clock, in nanoseconds, or `None` on a platform without one.
fn stage_clock() -> (() -> Int64)? {
  Some(fn() { @io.monotonic_nanos() })
}
