// File output is the same archive as byte output, just streamed: these tests
// pin that the two transports agree byte for byte and that a failed write
// never leaves anything at the path a reader would open.

///|
fn file_test_dir() -> String {
  // create_dir is non-recursive on the native backend.
  @fs.create_dir("target") catch {
    _ => ()
  }
  let dir = "target/parquet_file_test"
  @fs.create_dir(dir) catch {
    _ => ()
  }
  dir
}

///|
fn file_test_entry() -> @catalog.TableEntry {
  make_entry(
    [
      ("a", @types.Int32, [@types.Int32(1), @types.Int32(-2), @types.Int32(3)]),
      ("b", @types.Str, [@types.Str("alpha"), @types.Str(""), @types.Str("x")]),
    ],
    [
      [
        make_vector(@types.Int32, [
          @types.Int32(1),
          @types.Int32(-2),
          @types.Int32(3),
        ]),
        make_vector(@types.Str, [
          @types.Str("alpha"),
          @types.Str(""),
          @types.Str("x"),
        ]),
      ],
    ],
  )
}

///|
fn read_file_bytes(path : String) -> Bytes {
  @fs.read_file_to_bytes(path) catch {
    _ => abort("cannot read \{path}")
  }
}

///|
fn temp_names(dir : String) -> Array[String] {
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
/// Byte equality without depending on Bytes' equality semantics.
fn same_bytes(left : Bytes, right : Bytes) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for index in 0..<left.length() {
    if left[index] != right[index] {
      return false
    }
  }
  true
}

///|
test "file output is byte-identical to byte output for both codecs" {
  let entry = file_test_entry()
  let cases : Array[(String, @parquet.ParquetCodec)] = [
    ("raw", @parquet.ParquetCodec::Raw),
    ("snappy", @parquet.ParquetCodec::Snappy),
  ]
  for pair in cases {
    let name = pair.0
    let codec = pair.1
    let expected = @parquet.write_bytes_with(entry, codec) catch {
      e => abort("byte output failed: \{e}")
    }
    let path = file_test_dir() + "/identical-" + name + ".parquet"
    @parquet.write_file_with(path, entry, codec) catch {
      e => abort("file output failed: \{e}")
    }
    let written = read_file_bytes(path)
    assert_eq(written.length(), expected.length())
    assert_true(same_bytes(written, expected))
    // and the archive still reads back through the in-house reader
    let scanned = @parquet.scan_file(path, "t", []) catch {
      e => abort("scan failed: \{e}")
    }
    let mut rows = 0
    for batch in read_all(scanned) {
      rows += batch.row_count()
    }
    assert_eq(rows, 3)
  }
  assert_eq(temp_names(file_test_dir()).length(), 0)
}

///|
test "writing over an existing file replaces it completely" {
  let dir = file_test_dir()
  let path = dir + "/replace.parquet"
  @fs.write_bytes_to_file(
    path, b"a much longer previous body that must not survive",
  )
  @parquet.write_file_with(path, file_test_entry(), @parquet.ParquetCodec::Raw) catch {
    e => abort("write failed: \{e}")
  }
  let written = read_file_bytes(path)
  // the Parquet magic bookends the archive, so what is on disk is the new file
  // rather than a prefix of the old body with new bytes on top
  assert_eq(written[0], b'P')
  assert_eq(written[1], b'A')
  assert_eq(written[2], b'R')
  assert_eq(written[3], b'1')
  let tail = written.length() - 4
  assert_eq(written[tail], b'P')
  assert_eq(written[tail + 3], b'1')
  assert_true(written.length() > 8)
  assert_eq(temp_names(dir).length(), 0)
}

///|
/// Run a write that must fail and return its message ("no error" if it did not).
fn write_failure_message(path : String) -> String {
  @parquet.write_file_with(path, file_test_entry(), @parquet.ParquetCodec::Raw) catch {
    e => return e.to_string()
  }
  "no error"
}

///|
test "a write into a missing directory fails and names the path" {
  let path = file_test_dir() + "/no-such-dir/out.parquet"
  let message = write_failure_message(path)
  assert_true(message.contains("out.parquet"))
  let exists = @fs.path_exists(path)
  assert_false(exists)
  assert_eq(temp_names(file_test_dir()).length(), 0)
}
