// `write --out` refuses a target that is one of its inputs; these pin the
// lexical comparison behind that refusal.

///|
test "same_path folds . and .. segments" {
  assert_true(same_path("t.csv", "t.csv"))
  assert_true(same_path("t.csv", "./t.csv"))
  assert_true(same_path("a/t.csv", "a/./t.csv"))
  assert_true(same_path("a/b/../t.csv", "a/t.csv"))
  assert_true(same_path("/x/t.csv", "//x/t.csv"))
  assert_true(same_path("/x/./y/../t.csv", "/x/t.csv"))
  assert_false(same_path("a/t.csv", "b/t.csv"))
  assert_false(same_path("/t.csv", "t.csv"))
  assert_false(same_path("t.csv", "t.parquet"))
}
