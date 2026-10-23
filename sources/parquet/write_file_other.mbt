// File output on the non-native backends.
//
// wasm-gc/js have no host file handle, so the transport stays the whole-file
// write the module has always used (`x/fs` buffers the archive); the encoding
// flow and the public signature are still the shared ones. Only the native
// backend streams, which is where the peak-memory problem was measured.

///|
fn write_file_impl(
  path : String,
  entry : @catalog.TableEntry,
  codec : ParquetCodec,
) -> Unit raise @types.SqlError {
  let bytes = write_bytes_with(entry, codec)
  @fs.write_bytes_to_file(path, bytes) catch {
    _ => raise write_error("cannot write file at \{path}")
  }
}
