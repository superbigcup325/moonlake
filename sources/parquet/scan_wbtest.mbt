// Whitebox tests for the range discipline: what a scan actually asks for.
//
// A Parquet reader that reads the whole file is still correct, so no round-trip
// test can tell the two apart. These tests install an input that records every
// read, which is also the only place where "the file is never held" is
// observable: `ParquetInput` is private, so this has to be whitebox.

///|
fn wb_vector(
  dtype : @types.DataType,
  values : Array[@types.Scalar],
) -> @types.ColumnVector {
  let vector = @types.ColumnVector::make(dtype, values.length())
  for index in 0..<values.length() {
    vector.set(index, values[index])
  }
  vector
}

///|
/// Four columns of three rows in one batch, so the archive has one row group
/// and four similarly sized column chunks: "one of four chunks" is then a
/// comparison the assertions below can make without knowing writer internals.
fn wb_entry() -> @catalog.TableEntry {
  let names = ["a", "b", "c", "d"]
  let dtypes : Array[@types.DataType] = [
    @types.Int32,
    @types.Int64,
    @types.Float64,
    @types.Str,
  ]
  let columns : Array[@catalog.Column] = []
  for index in 0..<names.length() {
    columns.push({ name: names[index], dtype: dtypes[index], })
  }
  let rows = 256
  let ints : Array[@types.Scalar] = []
  let longs : Array[@types.Scalar] = []
  let floats : Array[@types.Scalar] = []
  let texts : Array[@types.Scalar] = []
  for i in 0..<rows {
    ints.push(@types.Int32(i))
    longs.push(@types.Int64(i.to_int64() * 1000L))
    floats.push(@types.Float64(i.to_double() * 0.5))
    texts.push(@types.Str("value-\{i}"))
  }
  let vectors : Array[@types.ColumnVector] = [
    wb_vector(@types.Int32, ints),
    wb_vector(@types.Int64, longs),
    wb_vector(@types.Float64, floats),
    wb_vector(@types.Str, texts),
  ]
  let table : @catalog.TableSchema = { table: "wb", columns, }
  @catalog.TableEntry::new(table, [@types.DataBatch::new(vectors, rows)])
}

///|
fn wb_archive() -> Bytes {
  write_bytes_with(wb_entry(), ParquetCodec::Raw) catch {
    e => abort("cannot write the fixture: \{e}")
  }
}

///|
/// The real in-memory input, plus a log of every range asked for.
fn recording_input(
  content : Bytes,
  log : Array[(Int64, Int32)],
) -> ParquetInput {
  let base = memory_input(content)
  {
    size: fn() raise @types.SqlError { (base.size)() },
    read_at: (offset, count) => {
      log.push((offset, count))
      (base.read_at)(offset, count)
    },
  }
}

///|
/// The reads that are not footer reads: the tail, and the body that ends where
/// the 8-byte tail begins. Everything else is a column chunk.
fn chunk_reads(
  log : Array[(Int64, Int32)],
  size : Int64,
) -> Array[(Int64, Int32)] {
  let out : Array[(Int64, Int32)] = []
  for entry in log {
    let is_tail = entry.0 == size - 8L && entry.1 == 8
    let is_footer = entry.0 + entry.1.to_int64() == size - 8L
    if !(is_tail || is_footer) {
      out.push(entry)
    }
  }
  out
}

///|
fn bytes_requested(log : Array[(Int64, Int32)]) -> Int64 {
  let mut total = 0L
  for entry in log {
    total += entry.1.to_int64()
  }
  total
}

///|
test "registration reads the tail and the footer, nothing else" {
  let content = wb_archive()
  let size = content.length().to_int64()
  let log : Array[(Int64, Int32)] = []
  let meta = read_footer(recording_input(content, log)) catch {
    e => abort("cannot read the fixture footer: \{e}")
  }
  assert_eq(meta.num_rows, 256L)
  // exactly two reads: the 8-byte tail, then the footer it points at
  assert_eq(log.length(), 2)
  assert_eq(log[0].0, size - 8L)
  assert_eq(log[0].1, 8)
  assert_eq(log[1].0 + log[1].1.to_int64(), size - 8L)
  // the column data is not part of either read
  assert_eq(chunk_reads(log, size).length(), 0)
  assert_true(bytes_requested(log) * 4L < size)
}

///|
test "a scan reads one column chunk per projected column, not the file" {
  let content = wb_archive()
  let size = content.length().to_int64()
  let log : Array[(Int64, Int32)] = []
  let entry = scan_input(recording_input(content, log), "wb", []) catch {
    e => abort("cannot register the fixture: \{e}")
  }
  assert_eq(log.length(), 2)
  let batches = entry.scan(@catalog.ScanRequest::new([0], [])) catch {
    e => abort("cannot scan the fixture: \{e}")
  }
  // one row group, one projected column: exactly one chunk is fetched, and it
  // is the one that starts right after the 4-byte magic
  let chunks = chunk_reads(log, size)
  assert_eq(chunks.length(), 1)
  assert_eq(chunks[0].0, 4L)
  assert_true(bytes_requested(log) * 2L < size)
  let mut rows = 0
  for batch in batches {
    rows += batch.row_count()
  }
  assert_eq(rows, 256)
}

///|
test "each projected column is its own range, in file order" {
  let content = wb_archive()
  let size = content.length().to_int64()
  let log : Array[(Int64, Int32)] = []
  let entry = scan_input(recording_input(content, log), "wb", []) catch {
    e => abort("cannot register the fixture: \{e}")
  }
  ignore(
    entry.scan(@catalog.ScanRequest::new([0, 2], [])) catch {
      e => abort("cannot scan the fixture: \{e}")
    },
  )
  // one range per projected column
  let chunks = chunk_reads(log, size)
  assert_eq(chunks.length(), 2)
  assert_eq(chunks[0].0, 4L)
  // column 2 lives after column 0's chunk: the reader seeks, it does not
  // stream the file through
  assert_true(chunks[1].0 > chunks[0].0 + chunks[0].1.to_int64())
}

///|
test "a chunk that does not fit in memory is refused by column name" {
  let log : Array[(Int64, Int32)] = []
  let input = recording_input(b"", log)
  let mut message = ""
  ignore(
    read_chunk(input, 0L, 2000000001L, "big") catch {
      e => {
        message = "\{e}"
        b""
      }
    },
  )
  assert_true(message.contains("big"))
  assert_true(message.contains("2 GiB"))
  // the refusal happens before any read is attempted
  assert_eq(log.length(), 0)
}

///|
test "a chunk read past the end of the input names the column and the range" {
  let log : Array[(Int64, Int32)] = []
  let input = recording_input(b"0123456789", log)
  let mut message = ""
  ignore(
    read_chunk(input, 4L, 20L, "c2") catch {
      e => {
        message = "\{e}"
        b""
      }
    },
  )
  assert_true(message.contains("c2"))
  assert_true(message.contains("cannot read 20 bytes at 4"))
}
