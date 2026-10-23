// Native file primitives for the Parquet writer and, later, the range reader.
//
// Deliberately small: an fd sink (create/write/fsync/close), rename/unlink for
// atomic replace, and process identity for temporary names. `moonbitlang/x`
// 0.5.6 exposes only whole-file reads and writes, and a published native-only
// dependency cannot be linked into a module that also builds for wasm-gc/js
// (the build plan rejects it before any file is selected), so the binding lives
// here and the contract lives in io_native.mbt.
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
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
