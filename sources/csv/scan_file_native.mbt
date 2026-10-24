// The file-backed CSV input on native targets: every read is a byte range
// through the platform binding, so a scan holds one range's bytes and cell
// offsets instead of the whole file's.
//
// The range helpers themselves live in platform/io, shared with the Parquet
// reader; this file only assembles the input record and turns a platform
// failure into the scan error a query reports.

///|
fn file_input(path : String) -> CsvInput {
  {
    label: path,
    size: fn() raise @types.SqlError {
      @io.file_size(path) catch {
        @io.IOFailure(message) => raise @types.SqlError::Scan(message)
      }
    },
    read_at: (offset, count) => {
      @io.read_range(path, offset, count) catch {
        @io.IOFailure(message) => raise @types.SqlError::Scan(message)
      }
    },
    reset: fn() { () },
  }
}
