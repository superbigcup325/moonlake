// File output on native targets: stream into a sink instead of building the
// whole archive and handing it to a whole-file write.
//
// The encoding flow is the shared one (`write_with`); this file only supplies
// the transport, so a file and a byte buffer differ in where the bytes go, not
// in what they say. The sink writes a temporary name and renames over the
// target on success, so a failed or interrupted write leaves the previous file
// intact.

///|
fn write_file_impl(
  path : String,
  entry : @catalog.TableEntry,
  codec : ParquetCodec,
) -> Unit raise @types.SqlError {
  let sink = @io.FileSink::open(path) catch {
    @io.IOFailure(message) =>
      raise write_error("cannot write file at \{path}: \{message}")
  }
  // Every failure from here on must remove the temporary file; the sink itself
  // cleans up a failed finish/rename, and abort is idempotent.
  errdefer sink.abort()
  write_with(entry, codec, chunk => {
    sink.append(chunk) catch {
      @io.IOFailure(message) => raise write_error(message)
    }
  })
  sink.finish() catch {
    @io.IOFailure(message) => raise write_error(message)
  }
}
