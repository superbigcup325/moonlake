///|
/// Blackbox tests for the public engine facade.

///|
test {
  assert_eq(@moonlake.version(), "0.4.0-dev")
  assert_eq(@moonlake.VERSION, "0.4.0-dev")
  assert_false(@moonlake.DESCRIPTION.is_empty())
}
