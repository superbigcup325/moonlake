// Reading a file back: the footer is read through a byte range, so the checks
// that used to live in "parse the whole file" have to hold for the two reads
// that replace it, on every backend.

///|
/// The three ways a footer read can go wrong, all of them cheap to build by
/// patching the trailer of a file this writer just produced: no magic where the
/// tail should end, a footer length that cannot fit, and a file too short to
/// hold a footer at all.
test "a file without its PAR1 tail is refused, not misread" {
  let dir = file_test_dir()
  let path = dir + "/truncated.parquet"
  @parquet.write_file_with(path, file_test_entry(), @parquet.ParquetCodec::Raw) catch {
    e => abort("cannot write the fixture: \{e}")
  }
  let content = read_file_bytes(path)
  // drop the 8-byte trailer: the last four bytes were the magic, so the file now
  // ends inside the footer body
  let cut = Buffer()
  cut.write_bytes(content[:content.length() - 8])
  @fs.write_bytes_to_file(path, cut.to_bytes()) catch {
    _ => abort("cannot truncate \{path}")
  }
  let _ = @parquet.scan_file(path, "t", []) catch {
    e => {
      assert_true(
        e.to_string().contains("missing PAR1 magic at the end of the file"),
      )
      return
    }
  }
  abort("a file that lost its magic should not register")
}

///|
test "a footer length that cannot fit is refused" {
  let dir = file_test_dir()
  let path = dir + "/bad-footer.parquet"
  @parquet.write_file_with(path, file_test_entry(), @parquet.ParquetCodec::Raw) catch {
    e => abort("cannot write the fixture: \{e}")
  }
  let content = read_file_bytes(path)
  let patched = Buffer()
  patched.write_bytes(content[:])
  // 0xFFFFFFFF reads back as a negative Int32; it must be rejected on its own
  // terms rather than turned into a huge offset
  for _ in 0..<4 {
    patched.write_byte(0xFF)
  }
  patched.write_byte(b'P')
  patched.write_byte(b'A')
  patched.write_byte(b'R')
  patched.write_byte(b'1')
  @fs.write_bytes_to_file(path, patched.to_bytes()) catch {
    _ => abort("cannot patch \{path}")
  }
  let _ = @parquet.scan_file(path, "t", []) catch {
    e => {
      assert_true(e.to_string().contains("footer length"))
      return
    }
  }
  abort("a negative footer length should not register")
}

///|
test "a file too short to hold a footer is refused" {
  let dir = file_test_dir()
  let path = dir + "/tiny.parquet"
  @fs.write_bytes_to_file(path, b"PAR1") catch {
    _ => abort("cannot write \{path}")
  }
  let _ = @parquet.scan_file(path, "t", []) catch {
    e => {
      assert_true(e.to_string().contains("too short to be Parquet"))
      return
    }
  }
  abort("a four-byte file should not register")
}

///|
test "a missing file names the path it could not read" {
  let _ = @parquet.scan_file("target/parquet_file_test/no-such.parquet", "t", []) catch {
    e => {
      assert_true(e.to_string().contains("no-such.parquet"))
      return
    }
  }
  abort("a missing file should not register")
}
