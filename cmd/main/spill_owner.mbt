// Ownership markers for spill directories.
//
// A query spills into `{base}/moonlake-spill-<n>/` and removes that directory
// when it ends, on the success and on the error path. Nothing runs for a query
// that is killed, so its directory stays behind, and from the outside it looks
// exactly like a directory a live query is writing into. The difference has to
// be recorded at the time the directory is claimed:
//
//   {dir}/owner
//     version=1
//     pid=<n>
//     boot_id=<uuid>
//     starttime=<n>          field 22 of /proc/<pid>/stat
//     nonce=<pid>-<seconds>  which claim this was, readable afterwards
//     created_at=<seconds>
//
// The verdict uses three facts and needs all of them:
//
// * the recorded boot id differs from this boot: the owner died before the
//   machine came back, so the directory is stale;
// * the pid is gone from `/proc`: stale;
// * the pid exists but its start time differs: the number was reused by another
//   process, so the owner is gone and the directory is stale too.
//
// Everything else — no marker, an unknown version, a missing field, no `/proc`,
// no boot id, a probe that cannot answer — is "cannot tell", and a directory
// that cannot be judged is kept and reported. Deleting on a guess is how a live
// query loses its run files, and a leaked directory under TMPDIR is a much
// smaller problem than that.

///|
/// The marker's name inside a spill directory: the only file that says the
/// directory is ours.
const OWNER_FILE : String = "owner"

///|
/// Where a marker is renamed to when its directory is reclaimed:
/// `owner.stale-<nonce>`. The rename is the claim — of two reapers only one
/// moves the name — and it takes the marker out of the world before anything is
/// deleted, so a directory emptied by an interrupted reclaim is never judged
/// again on evidence that is half gone.
const OWNER_STALE_PREFIX : String = "owner.stale-"

///|
/// The only marker format this version judges. A directory written by another
/// version is kept: it may be a newer run with rules this build does not know.
const OWNER_VERSION : Int32 = 1

///|
/// How many `moonlake-spill-<n>` indexes one `--spill-dir` may have before the
/// CLI gives up. Each index is one query, so this is a directory-count limit,
/// not a size limit.
const SPILL_RUN_LIMIT : Int32 = 1000

///|
/// How many directories one query explains on stderr, reclaims included. A
/// hundred leaked directories are one problem, not a hundred lines.
const SPILL_NOTE_LIMIT : Int32 = 2

///|
/// One owner marker. Only `pid`, `boot_id` and `starttime` take part in the
/// verdict; `nonce` and `created_at` are there so a leftover directory can be
/// explained afterwards.
priv struct OwnerMark {
  pid : Int32
  boot_id : String
  starttime : String
  nonce : String
  created_at : Int64
}

///|
fn OwnerMark::text(self : OwnerMark) -> String {
  let mut s = "version=\{OWNER_VERSION}\n"
  s = s + "pid=\{self.pid}\n"
  s = s + "boot_id=\{self.boot_id}\n"
  s = s + "starttime=\{self.starttime}\n"
  s = s + "nonce=\{self.nonce}\n"
  s = s + "created_at=\{self.created_at}\n"
  s
}

///|
/// Parse a marker, or `None` when this version cannot read it: unknown version,
/// missing or unparsable field, or a value that cannot identify a process.
/// `None` is a reason to keep the directory, never a reason to delete it.
fn parse_owner(text : String) -> OwnerMark? {
  let mut version : Int32? = None
  let mut pid : Int32? = None
  let mut boot_id = ""
  let mut starttime = ""
  let mut nonce = ""
  let mut created_at = 0L
  for line in text.split("\n") {
    match line.split_once("=") {
      Some((key, value)) =>
        match key.trim().to_owned() {
          "version" => version = @types.parse_i32(value.trim().to_owned())
          "pid" => pid = @types.parse_i32(value.trim().to_owned())
          "boot_id" => boot_id = value.trim().to_owned()
          "starttime" => starttime = value.trim().to_owned()
          "nonce" => nonce = value.trim().to_owned()
          "created_at" =>
            match @types.parse_i64(value.trim().to_owned()) {
              Some(v) => created_at = v
              None => ()
            }
          _ => ()
        }
      None => ()
    }
  }
  if version != Some(OWNER_VERSION) {
    return None
  }
  match pid {
    Some(p) =>
      if p > 0 && boot_id != "" && starttime != "" {
        Some({ pid: p, boot_id, starttime, nonce, created_at, })
      } else {
        None
      }
    None => None
  }
}

///|
/// What `/proc` says about a pid.
///
/// `PidRuns` and `PidGone` are unreachable on backends without `/proc`, where
/// `probe_pid` can only ever answer `PidOpaque`; the constructors stay because
/// the rules are shared, so the warning is switched off here rather than letting
/// a backend-specific gap reshape the rules.
#warnings("-6")
priv enum PidProbe {
  PidRuns(String) // it exists, and this is its start time
  PidGone // it does not exist in this boot and this pid namespace
  PidOpaque(String) // cannot tell, and this is why
}

///|
/// What to do with a directory, and why. `Stale` is the only verdict that
/// authorises deletion; `Unreadable` is reported because a marker that cannot be
/// read is an anomaly somebody should see, while `Unavailable` is the quiet
/// case: no marker, or no platform facility, which is the old behaviour.
priv enum OwnerVerdict {
  Live
  Stale(String)
  Unreadable(String)
  Unavailable
}

///|
/// Decide whether a marker's owner can still be running.
///
/// Pure on purpose: every fact about the machine comes in as an argument, so the
/// combinations that matter are tested without forking processes or rebooting.
/// `Live` is returned only on positive evidence that the recorded process is
/// still the one that wrote the marker.
fn judge_owner(
  mark : OwnerMark,
  boot_id_here : String,
  probe : (Int32) -> PidProbe,
) -> OwnerVerdict {
  if boot_id_here == "" {
    return Unavailable
  }
  if mark.boot_id != boot_id_here {
    return Stale("it was written before the last boot")
  }
  match probe(mark.pid) {
    PidGone => Stale("its process (\{mark.pid}) is gone")
    PidRuns(starttime) =>
      if starttime == mark.starttime {
        Live
      } else {
        Stale("pid \{mark.pid} now belongs to another process")
      }
    PidOpaque(why) => Unreadable(why)
  }
}

///|
/// Judge a directory's marker without touching it.
fn inspect_owner(dir : String) -> OwnerVerdict {
  match read_marker("\{dir}/\{OWNER_FILE}") {
    None => Unavailable
    Some(text) =>
      match parse_owner(text) {
        None =>
          Unreadable("its owner marker is not one this version understands")
        Some(mark) => judge_owner(mark, boot_id_here(), probe_pid)
      }
  }
}

///|
/// Record this process as the directory's owner, unless a marker is already
/// there.
///
/// The marker is bookkeeping for a later run, never a precondition for this one:
/// a query that cannot write it still spills, and still cleans up after itself.
fn claim_owner(dir : String) -> Unit {
  match self_mark() {
    None => () // no boot id to record: the directory is simply not reclaimable
    Some(mark) => write_marker("\{dir}/\{OWNER_FILE}", mark.text())
  }
}

///|
/// Remove a directory whose owner is provably gone. `false` means it is still
/// there, and the caller leaves it alone.
///
/// The order matters: claim the marker by renaming it, then empty the directory
/// of the only names this protocol writes, then remove it. A reclaim that dies
/// in the middle leaves a directory with no marker, which is kept by the rule
/// above instead of being half-deleted again and again.
fn reclaim_owner(dir : String) -> Bool {
  let names = @fs.read_dir(dir) catch {
    @fs.IOError(msg) => {
      eprintln("moonlake: warning: cannot list \{dir}: \{msg}")
      return false
    }
  }
  // Look before deleting: a directory holding anything this protocol did not
  // write is not ours to empty, and the only cost of refusing is one more leaked
  // directory (which the next run will refuse again, and report).
  for name in names {
    if !(is_run_file(name) || is_owner_file(name)) {
      eprintln(
        "moonlake: warning: kept spill directory \{dir}: it holds \{name}, which this protocol did not write",
      )
      return false
    }
  }
  let stale = "\{dir}/\{OWNER_STALE_PREFIX}\{self_nonce()}"
  if !rename_owner("\{dir}/\{OWNER_FILE}", stale) {
    return false // the listing above was stale; leave the winner its claim
  }
  let after = @fs.read_dir(dir) catch { @fs.IOError(_) => [] }
  for name in after {
    if is_run_file(name) || is_owner_file(name) {
      @fs.remove_file("\{dir}/\{name}") catch {
        @fs.IOError(_) => ()
      }
    }
  }
  @fs.remove_dir(dir) catch {
    @fs.IOError(msg) => {
      eprintln("moonlake: warning: kept spill directory \{dir}: \{msg}")
      return false
    }
  }
  true
}

///|
/// `owner`, `owner.stale-<nonce>`: the marker names a directory of ours holds.
fn is_owner_file(name : String) -> Bool {
  name == OWNER_FILE || name.has_prefix(OWNER_STALE_PREFIX)
}
