// The file-backed Parquet input on native targets: every read is a byte range
// through the platform binding, so a scan holds the footer plus one column
// chunk per projected column instead of the whole file.
//
// One open per range keeps lifetime trivial (a reader cannot be left open by an
// abandoned stream) and costs nothing at Parquet's granularity: a row group
// issues one read per projected column.

///|
fn file_input(path : String) -> ParquetInput {
  {
    size: fn() raise @types.SqlError { file_size(path) },
    read_at: (offset, count) => read_file_range(path, offset, count),
  }
}

///|
fn close_quietly(reader : @io.FileReader) -> Unit {
  reader.close() catch {
    _ => ()
  }
}

///|
fn file_size(path : String) -> Int64 raise @types.SqlError {
  // size() cannot fail, so there is no failing path that could leak the handle
  let reader = open_reader(path)
  let size = reader.size()
  close_quietly(reader)
  size
}

///|
fn read_file_range(
  path : String,
  offset : Int64,
  count : Int32,
) -> Bytes raise @types.SqlError {
  let reader = open_reader(path)
  errdefer close_quietly(reader)
  reader.read_at(offset, count) catch {
    @io.IOFailure(message) => raise @types.SqlError::Scan(message)
  }
}

///|
fn open_reader(path : String) -> @io.FileReader raise @types.SqlError {
  @io.FileReader::open(path) catch {
    @io.IOFailure(message) =>
      raise @types.SqlError::Scan("cannot read file at \{path}: \{message}")
  }
}
