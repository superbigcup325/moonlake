// The file-backed Parquet input everywhere the platform binding does not
// compile (wasm, wasm-gc, js). Those hosts expose whole-file reads only, so the
// bytes are read once when the input is made and ranges are slices of them —
// the same cost as before range reads existed, and the same behaviour the
// browser playground already had.

///|
fn file_input(path : String) -> ParquetInput raise @types.SqlError {
  let content = @fs.read_file_to_bytes(path) catch {
    _ => raise @types.SqlError::Scan("cannot read file at \{path}")
  }
  memory_input(content)
}
