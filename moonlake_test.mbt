///|
/// Blackbox tests for the public engine facade.

///|
test {
  assert_eq(@moonlake.version(), "0.6.0")
  assert_eq(@moonlake.VERSION, "0.6.0")
  assert_false(@moonlake.DESCRIPTION.is_empty())
}
