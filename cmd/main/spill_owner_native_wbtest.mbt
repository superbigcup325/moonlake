// The owner protocol against this machine: a real `/proc`, a real claim, and a
// real reclaim.
//
// The rules are covered on every backend by `spill_owner_wbtest.mbt`; what is
// checked here is the wiring only a native build has — that a marker this
// process writes reads back as `Live`, that a marker for a pid which cannot
// exist reads back as `Stale` and is removed, and that a marker whose start time
// does not match the pid's reads back as `Stale` too (the reused-pid case).

///|
fn temp_dir(name : String) -> String {
  let path = "/tmp/moonlake-owner-\{name}-\{@io.process_id()}"
  @fs.remove_dir(path) catch {
    @fs.IOError(_) => ()
  }
  @fs.create_dir(path) catch {
    @fs.IOError(msg) => abort("cannot create \{path}: \{msg}")
  }
  path
}

///|
fn drop_dir(path : String) -> Unit {
  @fs.remove_dir(path) catch {
    @fs.IOError(_) => ()
  }
}

///|
fn read_owner(dir : String) -> String {
  match read_marker("\{dir}/\{OWNER_FILE}") {
    Some(text) => text
    None => abort("no owner marker in \{dir}")
  }
}

///|
fn write_owner(dir : String, text : String) -> Unit {
  // Test setup, so a marker that cannot be created must fail loudly rather than
  // be skipped like a claim race in `write_marker`.
  let written = @io.write_new_file("\{dir}/\{OWNER_FILE}", @utf8.encode(text)) catch {
    @io.IOFailure(msg) => abort("cannot write a marker in \{dir}: \{msg}")
  }
  if !written {
    drop_dir(dir)
    abort("a marker in \{dir} was already there")
  }
}

///|
test "a marker this process writes judges live" {
  let dir = temp_dir("live")
  claim_owner(dir)
  let text = read_owner(dir)
  let mark = match parse_owner(text) {
    Some(mark) => mark
    None => abort("the marker this process wrote does not parse: \{text}")
  }
  assert_eq(mark.pid, @io.process_id())
  if !(inspect_owner(dir) is Live) {
    drop_dir(dir)
    abort("a marker this process just wrote did not judge live")
  }
  // A second claim must not overwrite the first: the directory already has an
  // owner, and that owner is the one that created it.
  claim_owner(dir)
  assert_eq(read_owner(dir), text)
  assert_true(reclaim_owner(dir))
  if @fs.path_exists(dir) {
    abort("reclaiming \{dir} left it behind")
  }
  drop_dir(dir)
}

///|
test "a marker for a process that cannot exist judges stale and is reclaimed" {
  let dir = temp_dir("gone")
  // Above any /proc/sys/kernel/pid_max setting, so the pid cannot be running.
  write_owner(
    dir,
    "version=1\npid=999999999\nboot_id=\{boot_id_here()}\nstarttime=1\nnonce=1-0\ncreated_at=0\n",
  )
  if !(inspect_owner(dir) is Stale(_)) {
    drop_dir(dir)
    abort("a marker for pid 999999999 was not judged stale")
  }
  assert_true(reclaim_owner(dir))
  if @fs.path_exists(dir) {
    abort("reclaiming \{dir} left it behind")
  }
  drop_dir(dir)
}

///|
test "a marker for a live pid with another start time judges stale" {
  let dir = temp_dir("reused")
  // This pid does exist — it is this test — but the recorded start time is not
  // the one /proc reports, which is exactly what a reused pid number looks like.
  write_owner(
    dir,
    "version=1\npid=\{@io.process_id()}\nboot_id=\{boot_id_here()}\nstarttime=0\nnonce=1-0\ncreated_at=0\n",
  )
  let verdict = inspect_owner(dir)
  if !(verdict is Stale(_)) {
    drop_dir(dir)
    abort(
      "a marker whose start time does not match the pid was not judged stale",
    )
  }
  drop_dir(dir)
}

///|
test "a directory with no marker is kept and says so" {
  let dir = temp_dir("unmarked")
  if !(inspect_owner(dir) is Unavailable) {
    drop_dir(dir)
    abort("a directory without a marker was not reported as unavailable")
  }
  drop_dir(dir)
}
