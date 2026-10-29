// The native residency readout is the one part of the census's high-water
// report that touches the machine, so it is checked against the machine.

///|
test "the residency readout sees this process" {
  let (rss, high) = rss_sample()
  assert_true(rss > 0)
  // the high-water is the peak, so it can never be below the current residency
  assert_true(high >= rss)
}
