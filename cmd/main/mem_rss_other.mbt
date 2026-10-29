// The census's residency readout on a target without `/proc`: there is nothing
// to read, so the report prints no resident fields. A zero here means "not
// sampled" and never passes for a small residency (contract: docs/ROADMAP.md).

///|
fn rss_sample() -> (Int32, Int32) {
  (0, 0)
}
