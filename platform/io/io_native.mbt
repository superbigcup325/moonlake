// Native file sink: the write side of the platform binding.
//
// Why this exists at all is recorded in `.internal/native-io-decision.md`: the
// locked `moonbitlang/x` (0.5.6, also the latest release) offers whole-file
// reads and writes only, and a native-only dependency cannot be linked into a
// module that also builds for wasm-gc/js. This package is therefore the whole
// platform boundary: native targets get a real file handle, the other backends
// do not compile it, and no shared package imports it except through a
// target-stable wrapper (see `sources/parquet/write_file_*.mbt`).

///|
pub(all) suberror IOFailure {
  IOFailure(String)
}

///|
#borrow(path)
extern "C" fn create_ffi(path : Bytes) -> UInt64 = "moonlake_io_create"

///|
#borrow(bytes)
extern "C" fn write_ffi(
  handle : UInt64,
  bytes : Bytes,
  off : Int32,
  len : Int32,
) -> Int64 = "moonlake_io_write"

///|
extern "C" fn sync_ffi(handle : UInt64) -> Int32 = "moonlake_io_sync"

///|
extern "C" fn close_ffi(handle : UInt64) -> Int32 = "moonlake_io_close"

///|
#borrow(from, to)
extern "C" fn rename_ffi(from : Bytes, to : Bytes) -> Int32 = "moonlake_io_rename"

///|
#borrow(path)
extern "C" fn unlink_ffi(path : Bytes) -> Int32 = "moonlake_io_unlink"

///|
extern "C" fn last_error_ffi() -> Bytes = "moonlake_io_last_error"

///|
extern "C" fn pid_ffi() -> Int32 = "moonlake_io_pid"

///|
extern "C" fn next_seq_ffi() -> Int64 = "moonlake_io_next_seq"

///|
fn cstr(path : String) -> Bytes {
  @utf8.encode(path) + b"\x00"
}

///|
/// `strerror` text of the last failed call. Read it right after the failure:
/// the next libc call may overwrite `errno`.
fn last_error() -> String {
  @utf8.decode_lossy(last_error_ffi())
}

///|
/// The temporary name a sink writes into before it replaces its target.
///
/// Same directory as the target (so the final `rename` stays inside one file
/// system and is atomic), and unique per process and per sink. A crashed
/// process leaves a `.moonlake-tmp-*` file behind instead of a half-written
/// Parquet file at the path a reader would open.
fn tmp_path_for(target : String) -> String {
  let pid = pid_ffi().to_int64()
  let seq = next_seq_ffi()
  "\{target}.moonlake-tmp-\{pid}-\{seq}"
}

///|
/// Append-only file sink with an explicit lifecycle.
///
/// The handle is private and only these methods touch it: no finaliser is
/// trusted to close a file, because a lost `close` on a full disk is exactly
/// how a truncated Parquet file gets published.
pub struct FileSink {
  handle : UInt64
  target : String
  tmp_path : String
  mut position : Int64
  mut closed : Bool
}

///|
/// Create the sink's temporary file. The target is not touched until `finish`.
pub fn FileSink::open(path : String) -> FileSink raise IOFailure {
  let tmp_path = tmp_path_for(path)
  let handle = create_ffi(cstr(tmp_path))
  if handle == 0 {
    raise IOFailure("cannot create \{tmp_path}: \{last_error()}")
  }
  { handle, target: path, tmp_path, position: 0L, closed: false, }
}

///|
/// Write the whole buffer or raise. A short write is retried; a sink that
/// silently drops bytes would leave the footer pointing past the data.
pub fn FileSink::append(self : FileSink, bytes : Bytes) -> Unit raise IOFailure {
  if self.closed {
    raise IOFailure("sink for \{self.target} is already closed")
  }
  let total = bytes.length()
  let end = self.position + total.to_int64()
  let mut done = 0
  while done < total {
    let n = write_ffi(self.handle, bytes, done, total - done)
    if n <= 0 {
      raise IOFailure(
        "short write at byte \{self.position + done.to_int64()} of \{self.target}: \{last_error()}",
      )
    }
    done += n.to_int()
  }
  self.position = end
}

///|
/// Bytes accepted so far, tracked by this sink rather than read back from the
/// descriptor: a short write must not make the Parquet offsets disagree with
/// what the file actually holds.
pub fn FileSink::position(self : FileSink) -> Int64 {
  self.position
}

///|
/// Durability boundary before the rename: everything appended is on the device
/// when this returns.
pub fn FileSink::sync(self : FileSink) -> Unit raise IOFailure {
  if self.closed {
    raise IOFailure("sink for \{self.target} is already closed")
  }
  if sync_ffi(self.handle) != 0 {
    raise IOFailure("fsync failed for \{self.tmp_path}: \{last_error()}")
  }
}

///|
/// Publish: sync, close, then `rename` over the target. Any failure removes the
/// temporary file and leaves the target exactly as it was.
pub fn FileSink::finish(self : FileSink) -> Unit raise IOFailure {
  if self.closed {
    raise IOFailure("sink for \{self.target} is already closed")
  }
  errdefer self.abort()
  self.sync()
  self.closed = true
  if close_ffi(self.handle) != 0 {
    let detail = last_error()
    ignore(unlink_ffi(cstr(self.tmp_path)))
    raise IOFailure("close failed for \{self.tmp_path}: \{detail}")
  }
  if rename_ffi(cstr(self.tmp_path), cstr(self.target)) != 0 {
    let detail = last_error()
    ignore(unlink_ffi(cstr(self.tmp_path)))
    raise IOFailure("cannot replace \{self.target}: \{detail}")
  }
}

///|
/// Give up: close and remove the temporary file. Never raises — this runs on
/// failure paths, where a second error would hide the first one. Idempotent.
pub fn FileSink::abort(self : FileSink) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  ignore(close_ffi(self.handle))
  ignore(unlink_ffi(cstr(self.tmp_path)))
}
