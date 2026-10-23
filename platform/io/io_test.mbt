// Blackbox tests for the native sink: they use only the public contract, which
// is also what the Parquet writer relies on — a published file is the whole
// file, and a failed write never touches the path a reader would open.

///|
fn test_dir() -> String {
  // create_dir is non-recursive on the native backend, so the parent has to
  // exist first: CI checks out a clean tree with no target/ directory.
  @fs.create_dir("target") catch {
    _ => ()
  }
  let dir = "target/io_sink_test"
  @fs.create_dir(dir) catch {
    _ => ()
  }
  dir
}

///|
fn read_back(path : String) -> String {
  @utf8.decode_lossy(@fs.read_file_to_bytes(path)) catch {
    _ => abort("cannot read back \{path}")
  }
}

///|
fn tmp_files(dir : String) -> Array[String] {
  let found : Array[String] = []
  let names = @fs.read_dir(dir) catch { _ => abort("cannot list \{dir}") }
  for name in names {
    if name.contains(".moonlake-tmp-") {
      found.push(name)
    }
  }
  found
}

///|
fn must_open(path : String) -> @io.FileSink {
  @io.FileSink::open(path) catch {
    @io.IOFailure(message) => abort(message)
  }
}

///|
test "finish publishes every appended byte and removes the temporary name" {
  let dir = test_dir()
  let path = dir + "/publish.parquet"
  let sink = must_open(path)
  assert_eq(sink.position(), 0L)
  sink.append(b"PAR1") catch {
    @io.IOFailure(message) => abort(message)
  }
  assert_eq(sink.position(), 4L)
  sink.append(b"payload") catch {
    @io.IOFailure(message) => abort(message)
  }
  assert_eq(sink.position(), 11L)
  sink.finish() catch {
    @io.IOFailure(message) => abort(message)
  }
  assert_eq(read_back(path), "PAR1payload")
  assert_eq(tmp_files(dir).length(), 0)
}

///|
test "append after finish is an error, not a silent write" {
  let dir = test_dir()
  let sink = must_open(dir + "/closed.bin")
  sink.append(b"x") catch {
    @io.IOFailure(message) => abort(message)
  }
  sink.finish() catch {
    @io.IOFailure(message) => abort(message)
  }
  let mut raised = false
  sink.append(b"y") catch {
    @io.IOFailure(message) => {
      assert_true(message.contains("already closed"))
      raised = true
    }
  }
  assert_true(raised)
}

///|
test "abort leaves an existing target untouched and removes the temporary file" {
  let dir = test_dir()
  let path = dir + "/atomic.bin"
  @fs.write_bytes_to_file(path, b"old-contents")
  let sink = must_open(path)
  sink.append(b"new-bytes") catch {
    @io.IOFailure(message) => abort(message)
  }
  // the sink only ever wrote into its temporary file at this point
  assert_eq(read_back(path), "old-contents")
  sink.abort()
  assert_eq(read_back(path), "old-contents")
  assert_eq(tmp_files(dir).length(), 0)
}

///|
test "finish refuses to publish over a directory and cleans up" {
  let dir = test_dir()
  let target = dir + "/a-directory"
  @fs.create_dir(target) catch {
    _ => ()
  }
  let sink = must_open(target)
  sink.append(b"PAR1") catch {
    @io.IOFailure(message) => abort(message)
  }
  let mut raised = false
  sink.finish() catch {
    @io.IOFailure(message) => {
      assert_true(message.contains("cannot replace"))
      raised = true
    }
  }
  assert_true(raised)
  assert_true(@fs.is_dir(target))
  assert_eq(tmp_files(dir).length(), 0)
}

///|
/// Opens a path that must fail, returning the message (or "no error", which
/// makes the assertion below fail loudly).
fn open_failure(path : String) -> String {
  let sink = @io.FileSink::open(path) catch {
    @io.IOFailure(message) => return message
  }
  sink.abort()
  "no error"
}

///|
test "open in a missing directory fails and names the path" {
  let message = open_failure("target/io_sink_test/no-such-dir/x.bin")
  assert_true(message.contains("cannot create"))
}

///|
fn must_read(path : String) -> @io.FileReader {
  @io.FileReader::open(path) catch {
    @io.IOFailure(message) => abort(message)
  }
}

///|
test "a reader returns exactly the requested range and the file size" {
  let dir = test_dir()
  let path = dir + "/range.bin"
  @fs.write_bytes_to_file(path, b"0123456789")
  let reader = must_read(path)
  assert_eq(reader.size(), 10L)
  let head = reader.read_at(0L, 4) catch {
    @io.IOFailure(message) => abort(message)
  }
  assert_eq(@utf8.decode_lossy(head), "0123")
  let middle = reader.read_at(3L, 4) catch {
    @io.IOFailure(message) => abort(message)
  }
  assert_eq(@utf8.decode_lossy(middle), "3456")
  let tail = reader.read_at(8L, 2) catch {
    @io.IOFailure(message) => abort(message)
  }
  assert_eq(@utf8.decode_lossy(tail), "89")
  // two ranges in a row must not disturb each other: positioned reads, not a
  // seek and a read
  let again = reader.read_at(0L, 2) catch {
    @io.IOFailure(message) => abort(message)
  }
  assert_eq(@utf8.decode_lossy(again), "01")
  reader.close() catch {
    @io.IOFailure(message) => abort(message)
  }
}

///|
test "a range that runs past the end is an error, not a short read" {
  let dir = test_dir()
  let path = dir + "/short.bin"
  @fs.write_bytes_to_file(path, b"abc")
  let reader = must_read(path)
  let mut raised = false
  ignore(
    reader.read_at(2L, 4) catch {
      @io.IOFailure(message) => {
        assert_true(message.contains("cannot read 4 bytes at 2"))
        raised = true
        b""
      }
    },
  )
  assert_true(raised)
  reader.close() catch {
    @io.IOFailure(message) => abort(message)
  }
}

///|
test "a reader refuses to work after it is closed" {
  let dir = test_dir()
  let path = dir + "/closed-read.bin"
  @fs.write_bytes_to_file(path, b"abc")
  let reader = must_read(path)
  reader.close() catch {
    @io.IOFailure(message) => abort(message)
  }
  let mut raised = false
  ignore(
    reader.read_at(0L, 1) catch {
      @io.IOFailure(message) => {
        assert_true(message.contains("already closed"))
        raised = true
        b""
      }
    },
  )
  assert_true(raised)
}

///|
test "opening a path that does not exist fails and names it" {
  let message = @io.FileReader::open("target/io_sink_test/no-such-file.bin") catch {
    @io.IOFailure(message) =>
      return assert_true(message.contains("cannot open"))
  }
  ignore(message)
  abort("opening a missing file should have failed")
}
