// A target without a monotonic clock installs none, so `--analyze` reports the
// row and byte counts it always did and no stage durations.

///|
fn stage_clock() -> (() -> Int64)? {
  None
}
