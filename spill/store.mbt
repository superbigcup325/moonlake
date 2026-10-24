// Directory-backed SpillStore for the native CLI: run files land in a
// per-run directory as run0.bin, run1.bin, ... The engine drives the
// lifecycle (write during sort, remove when the query ends); the
// directory itself is the CLI's to create and best-effort delete.
//
// The file name is part of that hand-over: the CLI deletes a directory it
// owns by dropping the files it recognises, so the name is written down once,
// here, and the purge asks instead of spelling the pattern out again.

///|
/// The name this store writes spill object `id` under in its directory.
pub fn run_file_name(id : Int32) -> String {
  "run\{id}.bin"
}

///|
/// Whether `name` is a file this store writes: `run`, one or more digits,
/// `.bin`.
///
/// Everything else in a run directory belongs to somebody else, including the
/// ownership marker the CLI leaves there, so a purge decides by this answer and
/// not by "the directory is mine".
pub fn is_run_file_name(name : String) -> Bool {
  if !(name.has_prefix("run") && name.has_suffix(".bin")) {
    return false
  }
  let n = name.length()
  if n <= 7 {
    return false // "run" + at least one digit + ".bin"
  }
  let mut digits = true
  for i, ch in name {
    if i >= 3 && i < n - 4 && (ch < '0' || ch > '9') {
      digits = false
    }
  }
  digits
}

///|
pub struct FsStore {
  dir : String
  mut next : Int32
}

///|
/// Create a store rooted at `dir`, creating the directory when missing.
pub fn FsStore::new(dir : String) -> FsStore raise {
  if !@fs.path_exists(dir) {
    @fs.create_dir(dir) catch {
      @fs.IOError(msg) => raise @types.SqlError::Execute("spill dir: \{msg}")
    }
  }
  { dir, next: 0, }
}

///|
/// The engine-facing store value; closures capture this FsStore.
pub fn FsStore::store(self : FsStore) -> @engine.SpillStore {
  {
    write: fn(bytes : Bytes) -> Int32 raise @types.SqlError {
      let id = self.next
      self.next += 1
      let path = "\{self.dir}/\{run_file_name(id)}"
      @fs.write_bytes_to_file(path, bytes) catch {
        @fs.IOError(msg) =>
          raise @types.SqlError::Execute("spill write: \{msg}")
      }
      id
    },
    read: fn(id : Int32) -> Bytes raise @types.SqlError {
      @fs.read_file_to_bytes("\{self.dir}/\{run_file_name(id)}") catch {
        @fs.IOError(msg) => raise @types.SqlError::Execute("spill read: \{msg}")
      }
    },
    remove: fn(id : Int32) -> Unit {
      // best-effort: a missing file is already the goal
      @fs.remove_file("\{self.dir}/\{run_file_name(id)}") catch {
        @fs.IOError(_) => ()
      }
    },
  }
}

///|
test "run file names are the ones the purge recognises" {
  assert_eq(run_file_name(0), "run0.bin")
  assert_eq(run_file_name(12), "run12.bin")
  for id in [0, 1, 9, 10, 1234] {
    assert_true(is_run_file_name(run_file_name(id)))
  }
  for name in ["run.bin", "run1.bin.bak", "run-1.bin", "run1x.bin", "", "1.bin"] {
    assert_true(!is_run_file_name(name))
  }
  assert_true(is_run_file_name("run00.bin")) // the CLI accepts what the store wrote
}

///|
test "fs store round-trips bytes and removes them" {
  let store = FsStore::new("/tmp/moonlake-spill-test").store()
  let id = (store.write)(b"hello spill")
  assert_eq((store.read)(id), b"hello spill")
  (store.remove)(id)
  let gone = try {
    let _ = (store.read)(id)
    false
  } catch {
    _ => true
  }
  assert_true(gone)
}
