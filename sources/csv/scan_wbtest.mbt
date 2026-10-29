///|
/// Whitebox tests for ranged CSV scans: what a scan reads, and that a chunk
/// boundary is invisible in the rows it produces.
///
/// A source whose bytes a test can swap, recording every range the scan asks
/// for. The log is how a test observes that a scan is bounded, and that a file
/// which changed under a registered table is noticed.
priv struct Holder {
  mut content : Bytes
  reads : Array[(Int64, Int32)]
}

///|
fn holder(content : Bytes) -> Holder {
  { content, reads: [], }
}

///|
fn recording_input(h : Holder) -> CsvInput {
  {
    label: "",
    size: fn() { h.content.length().to_int64() },
    read_at: (offset, count) => {
      let total = h.content.length().to_int64()
      let end = offset + count.to_int64()
      if offset < 0L || count < 0 || end > total {
        raise @types.SqlError::Scan(
          "test input: read of \{count} bytes at \{offset} outside \{total} bytes",
        )
      }
      h.reads.push((offset, count))
      let start = offset.to_int()
      let out : @buffer.Buffer = @buffer.Buffer::Buffer(size_hint=count)
      out.write_bytes(h.content[start:start + count])
      out.to_bytes()
    },
    reset: fn() { () },
  }
}

///|
fn largest_read(h : Holder) -> Int32 {
  let mut m = 0
  for r in h.reads {
    if r.1 > m {
      m = r.1
    }
  }
  m
}

///|
fn bytes_read(h : Holder) -> Int64 {
  let mut total = 0L
  for r in h.reads {
    total = total + r.1.to_int64()
  }
  total
}

///|
fn drain(entry : @catalog.TableEntry) -> Array[@types.DataBatch] {
  entry.scan(@catalog.ScanRequest::all(entry.schema.columns.length())) catch {
    e => abort("\{e}")
  }
}

///|
fn drain_rows(entry : @catalog.TableEntry) -> Int32 {
  let mut n = 0
  for b in drain(entry) {
    n = n + b.row_count()
  }
  n
}

///|
/// `reps` copies of a 1000-row unit, after a header. The rows are wide enough
/// that a few thousand of them exceed one range, which is what makes a
/// multi-range scan cheap to build in a test.
fn wide_rows(header : String, row : String, reps : Int32) -> String {
  let unit = StringBuilder()
  for _ in 0..<1000 {
    unit.write_string(row)
  }
  let u = unit.to_string()
  let body = StringBuilder()
  body.write_string(header)
  for _ in 0..<reps {
    body.write_string(u)
  }
  body.to_string()
}

///|
test "a large scan reads ranges, not the file" {
  let pad = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let content = wide_rows("i,s\n", "1,\{pad}\n", 100)
  let h = holder(@utf8.encode(content))
  let entry = scan_inputs([recording_input(h)], "big") catch {
    e => abort("\{e}")
  }
  // registration parsed a prefix: the header and the inference sample only
  assert_true(largest_read(h) <= PREFIX_BYTES)
  assert_true(bytes_read(h) <= PREFIX_BYTES.to_int64())
  let batches = drain(entry)
  // 100,000 data rows, BATCH_SIZE per batch, and the ranges stay whole batches
  let full = 100000 / BATCH_SIZE
  let remainder = 100000 - full * BATCH_SIZE
  let expect = if remainder == 0 { full } else { full + 1 }
  assert_eq(batches.length(), expect)
  assert_eq(batches[0].row_count(), BATCH_SIZE)
  let last = batches[batches.length() - 1]
  assert_eq(
    last.row_count(),
    if remainder == 0 {
      BATCH_SIZE
    } else {
      remainder
    },
  )
  assert_eq(
    last.columns()[0].get(last.row_count() - 1),
    @types.Scalar::Int32(1),
  )
  // no read ever asked for the whole file, and the reads were range sized
  assert_eq(largest_read(h), CHUNK_BYTES)
  assert_true(
    bytes_read(h) < content.length().to_int64() + CHUNK_BYTES.to_int64(),
  )
}

///|
test "a quoted newline does not split a row at a range boundary" {
  // every row carries a newline inside quotes, so a range boundary lands
  // inside a quoted field most of the time: no row may be split by it
  let content = wide_rows("s,n\n", "\"aaaaaaaaa\naaaaaaaaaa\",1\n", 165)
  let h = holder(@utf8.encode(content))
  let entry = scan_inputs([recording_input(h)], "quoted") catch {
    e => abort("\{e}")
  }
  assert_eq(drain_rows(entry), 165000)
  let batches = drain(entry)
  assert_eq(
    batches[0].columns()[0].get(0),
    @types.Scalar::Str("aaaaaaaaa\naaaaaaaaaa"),
  )
  assert_true(largest_read(h) <= CHUNK_BYTES)
}

///|
test "a record longer than one range is still one row" {
  let unit = StringBuilder()
  for _ in 0..<1000 {
    unit.write_string("line\n")
  }
  let u = unit.to_string()
  let body = StringBuilder()
  body.write_string("s\n\"")
  for _ in 0..<850 {
    body.write_string(u)
  }
  body.write_string("\"\n")
  let h = holder(@utf8.encode(body.to_string()))
  let entry = scan_inputs([recording_input(h)], "long") catch {
    e => abort("\{e}")
  }
  let batches = drain(entry)
  assert_eq(batches.length(), 1)
  assert_eq(batches[0].row_count(), 1)
  match batches[0].columns()[0].get(0) {
    @types.Scalar::Str(s) => assert_eq(s.length(), 850 * 5000)
    _ => abort("expected the quoted field as one string")
  }
  // the range had to grow: a record that does not fit is read again wider
  assert_true(largest_read(h) > CHUNK_BYTES)
}

///|
test "parse errors report file row numbers across ranges" {
  let pad = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let unit = StringBuilder()
  for _ in 0..<1000 {
    unit.write_string("1,\{pad}\n")
  }
  let u = unit.to_string()
  let body = StringBuilder()
  body.write_string("i,s\n")
  for _ in 0..<99 {
    body.write_string(u)
  }
  body.write_string("oops,\{pad}\n")
  body.write_string(u)
  let h = holder(@utf8.encode(body.to_string()))
  let entry = scan_inputs([recording_input(h)], "broken") catch {
    e => abort("\{e}")
  }
  // data row 99,000 is in the second range: its file row number must still be
  // the one a whole-file scan would report
  let _ = entry.scan(@catalog.ScanRequest::all(2)) catch {
    e => {
      let message = e.to_string()
      assert_true(message.contains("row 99002 column 0"))
      assert_true(message.contains("oops"))
      return
    }
  }
  abort("expected a scan error on the row past the first range")
}

///|
test "a header that changed under a registered table is refused" {
  let h = holder(@utf8.encode("k,v\n1,10\n"))
  let entry = scan_inputs([recording_input(h)], "t") catch {
    e => abort("\{e}")
  }
  h.content = @utf8.encode("k,w\n1,10\n")
  let _ = entry.scan(@catalog.ScanRequest::all(2)) catch {
    e => {
      assert_true(
        e.to_string().contains("header does not match the first file"),
      )
      return
    }
  }
  abort("expected the changed header to be refused")
}
