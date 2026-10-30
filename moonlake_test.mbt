///|
/// Blackbox tests for the public engine facade.

///|
test {
  assert_eq(@moonlake.version(), "0.6.2")
  assert_eq(@moonlake.VERSION, "0.6.2")
  assert_false(@moonlake.DESCRIPTION.is_empty())
}
