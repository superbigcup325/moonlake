///|
/// The clock a caller may install before an ANALYZE run. Nothing else sets it:
/// the library's ANALYZE report is deterministic on purpose (row and byte
/// counts, no durations), so a stage report names time only when the caller
/// brought a clock. One query runs on one thread, so a module-level cell is
/// enough, and `None` turns every timing site into a no-op.
priv struct ClockCell {
  mut clock : (() -> Int64)?
}

///|
let stage_clock : ClockCell = { clock: None, }

///|
/// Install the clock stage timings read (nanoseconds, monotonic), or `None` to
/// leave them out of the report. The CLI sets it for `--analyze` alone; a
/// library caller that does not set it sees the same deterministic report it
/// always did.
pub fn set_stage_clock(clock : (() -> Int64)?) -> Unit {
  stage_clock.clock = clock
}

///|
/// Nanoseconds from the installed clock. Without one this returns 0, so a stage
/// that takes a start stamp and ends up reporting nothing is also doing no work
/// to measure.
fn stage_ticks() -> Int64 {
  match stage_clock.clock {
    Some(now) => now()
    None => 0L
  }
}

///|
/// Record one stage's elapsed milliseconds, if a clock is installed. A stage
/// under a millisecond is reported as 0 rather than hidden: its presence still
/// says the stage ran.
fn stage_timed(
  label : String,
  stats : Array[(String, Int64)],
  start : Int64,
) -> Unit {
  if stage_clock.clock is Some(_) {
    stats.push(("time \{label} (ms)", (stage_ticks() - start) / 1000000L))
  }
}
