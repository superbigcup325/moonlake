// The native half of the spill owner protocol: the facts the verdict needs.
//
// Everything here reads the machine and nothing here decides anything — that is
// `spill_owner.mbt`, where the rules are pure and testable. `/proc` is the whole
// source of truth, which is why a platform without it (macOS) gets the previous
// behaviour: no marker, no reclaiming, no guessing.

///|
/// Small ceiling for the pseudo-files read here. `stat` is a few hundred bytes
/// and a boot id is 36; anything longer means the file is not what was expected.
const PROC_READ_CAP : Int32 = 4096

///|
/// This machine's boot id, or `""` when there is no `/proc` to read it from.
/// Comparing boot ids is what makes "the owner died before the reboot" a fact.
fn boot_id_here() -> String {
  match read_proc("/proc/sys/kernel/random/boot_id") {
    Some(text) => text.trim().to_owned() // the file ends with a newline
    None => ""
  }
}

///|
fn read_proc(path : String) -> String? {
  @io.read_small_file(path, PROC_READ_CAP)
}

///|
/// What `/proc` says about `pid`, including its start time (field 22 of
/// `/proc/<pid>/stat`), which is what tells a live owner from a process that
/// merely inherited its number.
fn probe_pid(pid : Int32) -> PidProbe {
  if read_proc("/proc/self/stat") is None {
    return PidOpaque("there is no /proc on this platform")
  }
  match proc_starttime(pid) {
    Some(starttime) => PidRuns(starttime)
    None =>
      if @fs.path_exists("/proc/\{pid}") {
        PidOpaque("cannot read /proc/\{pid}/stat")
      } else {
        PidGone
      }
  }
}

///|
/// Field 22 of `/proc/<pid>/stat`, as written: an integer count of clock ticks
/// since boot, comparable only with another value from the same boot.
///
/// The second field (`comm`) is parenthesised and may itself contain spaces and
/// parentheses, so the fields after it start after the LAST `)`, not the first.
fn proc_starttime(pid : Int32) -> String? {
  let text = match read_proc("/proc/\{pid}/stat") {
    Some(t) => t
    None => return None
  }
  let parts : Array[String] = []
  for part in text.split(")") {
    parts.push(part.to_owned())
  }
  if parts.length() == 0 {
    return None
  }
  let rest = parts[parts.length() - 1]
  // `state` is field 3 and sits where `rest` starts, so field 22 is the 20th
  // non-empty piece after it.
  let mut index = 0
  for field in rest.split(" ") {
    let f = field.trim().to_owned()
    if f == "" {
      continue
    }
    if index == 19 {
      return Some(f)
    }
    index += 1
  }
  None
}

///|
/// This process's marker, or `None` when there is no boot id to record (a
/// directory with no marker is kept, so writing a useless one would only add
/// noise to every directory).
fn self_mark() -> OwnerMark? {
  match read_proc("/proc/self/stat") {
    None => None
    Some(_) => {
      let boot_id = boot_id_here()
      if boot_id == "" {
        return None
      }
      let pid = @io.process_id()
      match proc_starttime(pid) {
        None => None
        Some(starttime) =>
          Some({
            pid,
            boot_id,
            starttime,
            nonce: self_nonce(),
            created_at: @io.unix_now(),
          })
      }
    }
  }
}

///|
/// `<pid>-<seconds>`: unique per claim, safe in a file name, and readable in a
/// postmortem. Nothing depends on it being unguessable.
fn self_nonce() -> String {
  "\{@io.process_id()}-\{@io.unix_now()}"
}

///|
fn read_marker(path : String) -> String? {
  @io.read_small_file(path, PROC_READ_CAP)
}

///|
/// Write a marker, unless the name is already taken.
///
/// A taken name is left as it is — whoever claimed the directory first owns it,
/// and that is not an error worth a line on stderr. Real write errors are
/// reported and swallowed: the marker is bookkeeping, and a query must not fail
/// because of it.
fn write_marker(path : String, text : String) -> Unit {
  let _ = @io.write_new_file(path, @utf8.encode(text)) catch {
    @io.IOFailure(msg) => {
      eprintln("moonlake: warning: cannot write \{path}: \{msg}")
      false
    }
  }
}

///|
fn rename_owner(from : String, to : String) -> Bool {
  @io.rename_file(from, to) catch {
    @io.IOFailure(msg) => {
      eprintln("moonlake: warning: cannot move \{from}: \{msg}")
      false
    }
  }
}
