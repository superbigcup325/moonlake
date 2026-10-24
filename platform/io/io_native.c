// Native file primitives for the Parquet writer, the ranged readers (Parquet and
// CSV) and the spill owner marker.
//
// Deliberately small: an fd sink (create/write/fsync/close), a positioned read
// handle (open/size/pread/close), rename/unlink for atomic replace, process
// identity and the clock for temporary names, an exclusive create and a rename
// that tolerates a vanished source (claiming an abandoned spill directory), and a
// read for pseudo-files that report a size of zero. `moonbitlang/x` 0.5.6
// exposes only whole-file reads and writes, and a published native-only
// dependency cannot be linked into a module that also builds for wasm-gc/js
// (the build plan rejects it before any file is selected), so the binding lives
// here and the contract lives in io_native.mbt.
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "moonbit.h"

// Handles are `fd + 1` so that 0 keeps meaning "no handle", exactly like the
// null pointer it replaces. stdin occupies 0 in practice, but not assuming that
// costs one shift and removes a class of "wrote Parquet into stdin" bugs.

MOONBIT_FFI_EXPORT uint64_t moonlake_io_create(moonbit_bytes_t path) {
  int fd = open((const char *)path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return 0;
  return (uint64_t)(fd + 1);
}

// Bytes accepted (a short write is reported, never hidden) or -1 on failure.
// EINTR is retried here so that the caller's loop only deals with progress.
MOONBIT_FFI_EXPORT int64_t moonlake_io_write(uint64_t handle,
                                             moonbit_bytes_t bytes, int32_t off,
                                             int32_t len) {
  int fd = (int)handle - 1;
  if (len <= 0) return 0;
  ssize_t n;
  do {
    n = write(fd, (const char *)bytes + off, (size_t)len);
  } while (n < 0 && errno == EINTR);
  if (n < 0) return -1;
  return (int64_t)n;
}

// Data durability: everything handed to write() is on the device when this
// returns 0. A failed fsync is reported, because it means the bytes may not be.
MOONBIT_FFI_EXPORT int32_t moonlake_io_sync(uint64_t handle) {
  return fsync((int)handle - 1) == 0 ? 0 : -1;
}

// Read side. A separate handle keeps "written so far" out of the picture: a
// reader never has to know how the file was produced, only where it is.
MOONBIT_FFI_EXPORT uint64_t moonlake_io_open_read(moonbit_bytes_t path) {
  int fd = open((const char *)path, O_RDONLY);
  if (fd < 0) return 0;
  return (uint64_t)(fd + 1);
}

// File size, or -1 on failure. A 0-byte file is a legal file, not an error, so
// the failure value cannot be 0.
MOONBIT_FFI_EXPORT int64_t moonlake_io_size(uint64_t handle) {
  struct stat st;
  if (fstat((int)handle - 1, &st) != 0) return -1;
  return (int64_t)st.st_size;
}

// Positioned read into bytes[off..off+len): bytes read (a short read means the
// caller asked for more than the file holds) or -1. Positioned reads keep the
// descriptor's own offset free, so two ranges can be in flight without a seek.
MOONBIT_FFI_EXPORT int64_t moonlake_io_pread(uint64_t handle, int64_t position,
                                             moonbit_bytes_t bytes, int32_t off,
                                             int32_t len) {
  int fd = (int)handle - 1;
  if (len <= 0) return 0;
  ssize_t n;
  do {
    n = pread(fd, (char *)bytes + off, (size_t)len, (off_t)position);
  } while (n < 0 && errno == EINTR);
  if (n < 0) return -1;
  return (int64_t)n;
}

MOONBIT_FFI_EXPORT int32_t moonlake_io_close(uint64_t handle) {
  return close((int)handle - 1) == 0 ? 0 : -1;
}

MOONBIT_FFI_EXPORT int32_t moonlake_io_rename(moonbit_bytes_t from,
                                              moonbit_bytes_t to) {
  return rename((const char *)from, (const char *)to) == 0 ? 0 : -1;
}

MOONBIT_FFI_EXPORT int32_t moonlake_io_unlink(moonbit_bytes_t path) {
  return unlink((const char *)path) == 0 ? 0 : -1;
}

// strerror(errno) as bytes; callers read it immediately after a failure.
MOONBIT_FFI_EXPORT moonbit_bytes_t moonlake_io_last_error(void) {
  const char *text = strerror(errno);
  size_t len = strlen(text);
  moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)len, 0);
  memcpy(bytes, text, len);
  return bytes;
}

MOONBIT_FFI_EXPORT int32_t moonlake_io_pid(void) { return (int32_t)getpid(); }

static int64_t moonlake_io_seq = 0;

// Monotonic in-process counter: two sinks in one process never pick the same
// temporary name, and the name still says which process made it.
MOONBIT_FFI_EXPORT int64_t moonlake_io_next_seq(void) {
  moonlake_io_seq += 1;
  return moonlake_io_seq;
}

// Claim a name and fill it in one call. 1 = created and written, 0 = the name
// was already taken (that is an answer, not a failure), -1 = real error. The
// half-written file is removed on failure so a later attempt is not blocked by
// a marker nobody can read.
MOONBIT_FFI_EXPORT int32_t moonlake_io_write_new(moonbit_bytes_t path,
                                                 moonbit_bytes_t bytes) {
  int fd = open((const char *)path, O_WRONLY | O_CREAT | O_EXCL, 0644);
  if (fd < 0) return errno == EEXIST ? 0 : -1;
  int32_t len = Moonbit_array_length(bytes);
  int32_t done = 0;
  while (done < len) {
    ssize_t n = write(fd, (const char *)bytes + done, (size_t)(len - done));
    if (n < 0) {
      if (errno == EINTR) continue;
      close(fd);
      unlink((const char *)path);
      return -1;
    }
    done += (int32_t)n;
  }
  if (close(fd) != 0) {
    unlink((const char *)path);
    return -1;
  }
  return 1;
}

// Rename, reporting a vanished source as 0 instead of as an error: reclaiming an
// abandoned directory is a race between reapers, and losing it is fine.
MOONBIT_FFI_EXPORT int32_t moonlake_io_rename_if_exists(moonbit_bytes_t from,
                                                        moonbit_bytes_t to) {
  if (rename((const char *)from, (const char *)to) == 0) return 1;
  return errno == ENOENT ? 0 : -1;
}

// Small text files read by hand: everything under /proc reports a size of 0, so
// a size-driven read (what moonbitlang/x does) comes back empty. Reads until EOF
// or `cap`; returns the byte count, or -1 when the file cannot be opened.
MOONBIT_FFI_EXPORT int64_t moonlake_io_read_small(moonbit_bytes_t path,
                                                  moonbit_bytes_t bytes,
                                                  int32_t cap) {
  int fd = open((const char *)path, O_RDONLY);
  if (fd < 0) return -1;
  int32_t total = 0;
  while (total < cap) {
    ssize_t n = read(fd, (char *)bytes + total, (size_t)(cap - total));
    if (n < 0) {
      if (errno == EINTR) continue;
      close(fd);
      return -1;
    }
    if (n == 0) break;
    total += (int32_t)n;
  }
  close(fd);
  return (int64_t)total;
}

// Wall clock, in seconds. Spill owner markers record when a directory was
// claimed; nothing here times anything.
MOONBIT_FFI_EXPORT int64_t moonlake_io_now(void) { return (int64_t)time(NULL); }
