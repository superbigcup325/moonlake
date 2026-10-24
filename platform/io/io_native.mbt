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

///|
#borrow(path)
extern "C" fn open_read_ffi(path : Bytes) -> UInt64 = "moonlake_io_open_read"

///|
extern "C" fn size_ffi(handle : UInt64) -> Int64 = "moonlake_io_size"

///|
#borrow(bytes)
extern "C" fn pread_ffi(
  handle : UInt64,
  position : Int64,
  bytes : Bytes,
  off : Int32,
  len : Int32,
) -> Int64 = "moonlake_io_pread"

///|
/// Positioned reader over an existing file.
///
/// The read side of the same boundary as `FileSink`, and deliberately the same
/// shape: a caller asks for a byte range and gets exactly that range or an
/// error. Nothing here caches or seeks, so a Parquet reader can fetch a footer,
/// then one column chunk at a time, without holding the file.
pub struct FileReader {
  handle : UInt64
  size : Int64
  mut closed : Bool
}

///|
/// Open an existing file for reading. The size is captured here, once, so a
/// later `read_at` can tell "past the end" from "the file changed under me"
/// without a second `stat`.
pub fn FileReader::open(path : String) -> FileReader raise IOFailure {
  let handle = open_read_ffi(cstr(path))
  if handle == 0 {
    raise IOFailure("cannot open \{path}: \{last_error()}")
  }
  let size = size_ffi(handle)
  if size < 0L {
    let detail = last_error()
    ignore(close_ffi(handle))
    raise IOFailure("cannot size \{path}: \{detail}")
  }
  { handle, size, closed: false, }
}

///|
/// Bytes in the file when it was opened.
pub fn FileReader::size(self : FileReader) -> Int64 {
  self.size
}

///|
/// Read exactly `length` bytes starting at `offset`.
///
/// A short read is an error, not a shorter result: in a Parquet file a chunk
/// that ends early means the footer lied, and silently decoding fewer pages
/// would turn that into a wrong answer.
pub fn FileReader::read_at(
  self : FileReader,
  offset : Int64,
  length : Int32,
) -> Bytes raise IOFailure {
  if self.closed {
    raise IOFailure("reader is already closed")
  }
  if offset < 0L || length < 0 {
    raise IOFailure("cannot read \{length} bytes at \{offset}")
  }
  let end = offset + length.to_int64()
  if end > self.size {
    raise IOFailure(
      "cannot read \{length} bytes at \{offset}: the file is \{self.size} bytes",
    )
  }
  let out = Bytes::make(length, 0)
  let mut done = 0
  while done < length {
    let n = pread_ffi(
      self.handle,
      offset + done.to_int64(),
      out,
      done,
      length - done,
    )
    if n <= 0 {
      raise IOFailure(
        "short read at byte \{offset + done.to_int64()}: \{last_error()}",
      )
    }
    done += n.to_int()
  }
  out
}

///|
/// Release the handle. Idempotent, and a failure here does not invalidate bytes
/// already read.
pub fn FileReader::close(self : FileReader) -> Unit raise IOFailure {
  if self.closed {
    return
  }
  self.closed = true
  if close_ffi(self.handle) != 0 {
    raise IOFailure("close failed: \{last_error()}")
  }
}

///|
/// Release a reader without letting a close failure reach the caller.
///
/// For the case where the file has already been read, or is already failing: a
/// failed close there could only replace a useful error with a useless one.
/// Same reason `FileSink::abort` never raises.
pub fn close_quietly(reader : FileReader) -> Unit {
  reader.close() catch {
    _ => ()
  }
}

///|
/// Open a file for the helpers below, wording the failure the way a scan
/// reports it: "cannot read file at <path>: <what went wrong>".
fn open_for_reading(path : String) -> FileReader raise IOFailure {
  FileReader::open(path) catch {
    IOFailure(message) =>
      raise IOFailure("cannot read file at \{path}: \{message}")
  }
}

///|
/// Size of an existing file, without keeping the handle.
pub fn file_size(path : String) -> Int64 raise IOFailure {
  // size() cannot fail, so there is no failing path that could leak the handle
  let reader = open_for_reading(path)
  let size = reader.size()
  close_quietly(reader)
  size
}

///|
/// Read one byte range of a file, opening it for just that range.
///
/// One open per range keeps lifetime trivial -- a reader cannot be left open by
/// an abandoned stream, and nothing has to survive between reads -- and costs
/// nothing at the granularity both formats read at: Parquet issues one per
/// projected column of a row group, CSV one per few MB.
///
/// The range is returned whole or not at all; `FileReader::read_at` owns that
/// rule, so this only adds the open.
pub fn read_range(
  path : String,
  offset : Int64,
  count : Int32,
) -> Bytes raise IOFailure {
  let reader = open_for_reading(path)
  errdefer close_quietly(reader)
  reader.read_at(offset, count)
}

///|
/// The owning process's id: what a spill owner marker records about itself.
pub fn process_id() -> Int32 {
  pid_ffi()
}

///|
extern "C" fn now_ffi() -> Int64 = "moonlake_io_now"

///|
/// Seconds since the epoch, for markers that should be explainable afterwards.
/// Nothing here measures elapsed time with it.
pub fn unix_now() -> Int64 {
  now_ffi()
}

///|
#borrow(path, bytes)
extern "C" fn write_new_ffi(path : Bytes, bytes : Bytes) -> Int32 = "moonlake_io_write_new"

///|
/// Create `path` and write `bytes` into it, refusing to touch a file that is
/// already there.
///
/// `false` means someone else owns the name — a legitimate answer for a claim
/// (`O_CREAT|O_EXCL`), not an error. Every other problem raises, and the
/// half-written file is removed so a later attempt does not find a marker
/// nothing can read.
pub fn write_new_file(path : String, bytes : Bytes) -> Bool raise IOFailure {
  match write_new_ffi(cstr(path), bytes) {
    1 => true
    0 => false
    _ => raise IOFailure("cannot create \{path}: \{last_error()}")
  }
}

///|
#borrow(from, to)
extern "C" fn rename_if_exists_ffi(from : Bytes, to : Bytes) -> Int32 = "moonlake_io_rename_if_exists"

///|
/// Rename `from` to `to`, or report that `from` was already gone.
///
/// Losing that race is a normal outcome: two runs reclaiming the same abandoned
/// directory both want the same end state, and the one that moved the marker is
/// the one that owns the deletion.
pub fn rename_file(from : String, to : String) -> Bool raise IOFailure {
  match rename_if_exists_ffi(cstr(from), cstr(to)) {
    1 => true
    0 => false
    _ => raise IOFailure("cannot rename \{from}: \{last_error()}")
  }
}

///|
#borrow(path, bytes)
extern "C" fn read_small_ffi(path : Bytes, bytes : Bytes, cap : Int32) -> Int64 = "moonlake_io_read_small"

///|
/// Read a small text file whose reported size lies.
///
/// Everything under `/proc` reports a size of 0, so the size-driven read that
/// `moonbitlang/x/fs` does comes back empty; this reads until EOF instead.
/// `None` means the file is absent, unreadable, or longer than `cap`.
pub fn read_small_file(path : String, cap : Int32) -> String? {
  let buf = Bytes::make(cap, 0)
  let n = read_small_ffi(cstr(path), buf, cap)
  if n < 0 || n.to_int() >= cap {
    return None
  }
  Some(@utf8.decode_lossy(buf[0:n.to_int()].to_owned()))
}
