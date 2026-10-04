// Directory-backed SpillStore for the native CLI: run files land in a
// per-run directory as run0.bin, run1.bin, ... The engine drives the
// lifecycle (write during sort, remove when the query ends); the
// directory itself is the CLI's to create and best-effort delete.

///|
pub struct FsStore {
  dir : String
  mut next : Int
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
    write: fn(bytes : Bytes) -> Int raise @types.SqlError {
      let id = self.next
      self.next += 1
      let path = "\{self.dir}/run\{id}.bin"
      @fs.write_bytes_to_file(path, bytes) catch {
        @fs.IOError(msg) =>
          raise @types.SqlError::Execute("spill write: \{msg}")
      }
      id
    },
    read: fn(id : Int) -> Bytes raise @types.SqlError {
      @fs.read_file_to_bytes("\{self.dir}/run\{id}.bin") catch {
        @fs.IOError(msg) => raise @types.SqlError::Execute("spill read: \{msg}")
      }
    },
    remove: fn(id : Int) -> Unit {
      // best-effort: a missing file is already the goal
      @fs.remove_file("\{self.dir}/run\{id}.bin") catch {
        @fs.IOError(_) => ()
      }
    },
  }
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
