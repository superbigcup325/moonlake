// The owner protocol's decision table, without any of the machine.
//
// `judge_owner` takes the boot id and the pid probe as arguments, so every
// combination that decides "delete" or "keep" is exercised here: these tests run
// on all three backends, and a rules test cannot replace the real two-process
// check in `harness/spill_accept.sh` — it pins the reasoning, not the wiring.

///|
fn mark(pid : Int32, boot_id : String, starttime : String) -> OwnerMark {
  { pid, boot_id, starttime, nonce: "1-0", created_at: 1700000000L, }
}

///|
fn reason_of(verdict : OwnerVerdict) -> String {
  match verdict {
    Stale(why) => "stale: \{why}"
    Unreadable(why) => "unreadable: \{why}"
    Unavailable => "unavailable"
    Live => "live"
  }
}

///|
test "a marker round-trips through its text form" {
  let original = mark(4242, "d3adb33f-0000-4000-8000-000000000000", "123456")
  let text = original.text()
  let parsed = match parse_owner(text) {
    Some(m) => m
    None => abort("marker text did not parse")
  }
  assert_eq(parsed.pid, 4242)
  assert_eq(parsed.boot_id, "d3adb33f-0000-4000-8000-000000000000")
  assert_eq(parsed.starttime, "123456")
  assert_eq(parsed.nonce, "1-0")
  assert_eq(parsed.created_at, 1700000000L)
}

///|
test "a marker from a newer version is kept, not guessed at" {
  let text = "version=2\npid=4242\nboot_id=boot\nstarttime=1\n"
  assert_true(parse_owner(text) is None)
}

///|
test "a marker missing its evidence does not parse" {
  // no pid: nothing identifies the owner
  assert_true(parse_owner("version=1\nboot_id=boot\nstarttime=1\n") is None)
  // no boot id: "same boot" cannot be established
  assert_true(parse_owner("version=1\npid=42\nstarttime=1\n") is None)
  // no start time: a live process cannot be told from a reused pid
  assert_true(parse_owner("version=1\npid=42\nboot_id=boot\n") is None)
  // an unparsable pid is the same as no pid
  assert_true(
    parse_owner("version=1\npid=x\nboot_id=boot\nstarttime=1\n") is None,
  )
}

///|
test "an owner from an earlier boot is stale" {
  let m = mark(42, "boot-1", "100")
  let verdict = judge_owner(m, "boot-2", fn(_pid) {
    abort("a rebooted owner is stale without a probe")
  })
  if !(verdict is Stale(_)) {
    abort("expected stale, got \{reason_of(verdict)}")
  }
}

///|
test "an owner whose process is gone is stale" {
  let m = mark(42, "boot", "100")
  let verdict = judge_owner(m, "boot", fn(_pid) { PidGone })
  if !(verdict is Stale(_)) {
    abort("expected stale, got \{reason_of(verdict)}")
  }
}

///|
test "a live owner is not stale" {
  let m = mark(42, "boot", "100")
  let verdict = judge_owner(m, "boot", fn(_pid) { PidRuns("100") })
  if !(verdict is Live) {
    abort("expected live, got \{reason_of(verdict)}")
  }
}

///|
test "a reused pid is stale even though the pid exists" {
  let m = mark(42, "boot", "100")
  let verdict = judge_owner(m, "boot", fn(_pid) { PidRuns("200") })
  if !(verdict is Stale(_)) {
    abort("expected stale, got \{reason_of(verdict)}")
  }
}

///|
test "no boot id on this platform means keep the directory" {
  let m = mark(42, "boot", "100")
  let verdict = judge_owner(m, "", fn(_pid) {
    abort("no probe without a boot id")
  })
  if !(verdict is Unavailable) {
    abort("expected unavailable, got \{reason_of(verdict)}")
  }
}

///|
test "a probe that cannot answer keeps the directory" {
  let m = mark(42, "boot", "100")
  let verdict = judge_owner(m, "boot", fn(_pid) {
    PidOpaque("permission denied")
  })
  if !(verdict is Unreadable(_)) {
    abort("expected unreadable, got \{reason_of(verdict)}")
  }
}
