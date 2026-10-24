// The per-run spill directory: where it goes (`--spill-dir` or TMPDIR), what
// counts as one of its run files, and how it is removed again. Claiming and
// reclaiming ownership of a directory lives in spill_owner*.mbt; this file is
// only the path and the purge.

///|
/// One query's spill directory, and what removing it means.
///
/// `base` is the directory the caller named (`--spill-dir`) or TMPDIR;
/// `created_base` records that this process made `base`, so an empty base can
/// be removed again while a caller's own directory is left alone.
priv struct SpillRun {
  dir : String
  base : String
  created_base : Bool
}

///|
/// The spill directory for one query: a subdirectory of `base`, named
/// `moonlake-spill-<n>`.
///
/// The subdirectory is not decoration:
///
/// * two processes sharing one `--spill-dir` used to start at `run0.bin` in
///   the same directory, overwrite each other, and then each delete the
///   other's run files when it finished; a per-process subdirectory makes that
///   collision impossible without a lock;
/// * the purge then only touches a directory this process created, so a
///   caller's own files in `--spill-dir` are never read or deleted;
/// * `create_dir` is the lock: the `path_exists` check is an optimisation, and
///   a racing process loses the create and moves to the next index.
///
/// A directory left behind by a killed process is reclaimed here, but only when
/// it says who owned it and that owner is provably gone: the marker written by
/// `claim_owner` records a pid, a boot id and the pid's start time, and
/// `judge_owner` accepts exactly three proofs of death (another boot, a pid that
/// no longer exists, a pid whose start time changed). A directory with no
/// marker, an unknown marker, or a live owner is left alone — one of those is a
/// running query's run files.
fn spill_run_dir(spill_dir : String?) -> SpillRun raise @types.SqlError {
  let base = match spill_dir {
    Some(d) => d
    None =>
      match @env.get_env_var("TMPDIR") {
        Some(d) => d
        None => "/tmp"
      }
  }
  let created_base = !@fs.path_exists(base)
  if created_base {
    @fs.create_dir(base) catch {
      @fs.IOError(msg) => raise @types.SqlError::Execute("spill dir: \{msg}")
    }
  }
  let mut n = 0
  let mut noted = 0
  while n < SPILL_RUN_LIMIT {
    let dir = "\{base}/moonlake-spill-\{n}"
    if @fs.path_exists(dir) {
      match inspect_owner(dir) {
        Stale(why) =>
          // The directory is free after this; go around again rather than burn
          // the index, so the numbering stays dense for the next run.
          if reclaim_owner(dir) {
            if noted < SPILL_NOTE_LIMIT {
              noted += 1
              eprintln("moonlake: reclaimed \{dir}: \{why}")
            }
          } else {
            n += 1
          }
        Live => n += 1
        Unreadable(why) => {
          if noted < SPILL_NOTE_LIMIT {
            noted += 1
            eprintln("moonlake: warning: kept spill directory \{dir}: \{why}")
          }
          n += 1
        }
        Unavailable => n += 1
      }
      continue
    }
    @fs.create_dir(dir) catch {
      @fs.IOError(_) => {
        n += 1
        continue
      }
    }
    claim_owner(dir)
    return { dir, base, created_base, }
  }
  raise @types.SqlError::Execute("no free spill directory under \{base}")
}

///|
/// Remove one spill directory: the run files this store names, then the
/// directory. A directory that survives is reported rather than silently
/// ignored — ignoring it is how a leaked temp tree turns into a disk-full
/// failure mid-query.
fn purge_dir(dir : String) -> Unit {
  let entries = @fs.read_dir(dir) catch {
    @fs.IOError(_) => return // already gone: nothing to purge
  }
  for name in entries {
    if is_run_file(name) || is_owner_file(name) {
      @fs.remove_file("\{dir}/\{name}") catch {
        @fs.IOError(_) => ()
      }
    }
  }
  @fs.remove_dir(dir) catch {
    @fs.IOError(msg) =>
      eprintln("moonlake: warning: kept spill directory \{dir}: \{msg}")
  }
}

///|
/// Remove this query's spill directory, and an empty base this process made.
fn purge_spill_run(run : SpillRun) -> Unit {
  purge_dir(run.dir)
  if run.created_base {
    @fs.remove_dir(run.base) catch {
      @fs.IOError(_) => () // not empty: something else lives there now
    }
  }
}

///|
/// `run<n>.bin`: the only file names this store writes.
fn is_run_file(name : String) -> Bool {
  if !(name.has_prefix("run") && name.has_suffix(".bin")) {
    return false
  }
  let n = name.length()
  if n <= 7 {
    return false // "run" + at least one digit + ".bin"
  }
  let mut ok = true
  for i, ch in name {
    if i >= 3 && i < n - 4 && (ch < '0' || ch > '9') {
      ok = false
    }
  }
  ok
}
