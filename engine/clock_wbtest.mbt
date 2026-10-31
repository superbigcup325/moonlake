///|
/// The stage clock is opt-in: without one the ANALYZE report is the row and byte
/// count report it always was, and with one it names each stage's milliseconds.
/// The fake clock advances a millisecond per read, so every duration is the
/// number of reads between a stage's start and end rather than wall time.
test "a stage report names time only when a clock is installed" {
  let cat = join_pair_catalog()
  let sql = "select l.k, r.v from l join r on l.k = r.k"
  let plain = explain_analyze(sql, cat) catch { e => abort("\{e}") }
  assert_false(plain.contains("time "))
  let cell : Array[Int64] = [0L]
  set_stage_clock(
    Some(fn() {
      cell[0] += 1000000L
      cell[0]
    }),
  )
  let timed = explain_analyze(sql, cat) catch { e => abort("\{e}") }
  assert_true(timed.contains("time collect (ms): 1"))
  assert_true(timed.contains("time join step 1 (ms): 1"))
  assert_true(timed.contains("time join (ms): "))
  assert_true(timed.contains("time sort+project (ms): "))
  // the clock is a report switch, not a change to the answer
  assert_true(timed.contains("joins: 7"))
  set_stage_clock(None)
  let again = explain_analyze(sql, cat) catch { e => abort("\{e}") }
  assert_eq(again, plain)
}
