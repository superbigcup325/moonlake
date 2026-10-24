// The file-backed CSV input everywhere the platform binding does not compile
// (wasm, wasm-gc, js). Those hosts expose whole-file reads only, so the file is
// read once and ranges are slices of it — the same cost as before range reads
// existed. The cell index is still per range, so only the bytes, not the
// offsets, grow with the file.
//
// The snapshot is dropped when a scan starts, so a table sees the file as it is
// when the scan opens, exactly as the ranged native input does.

///|
priv struct FileCache {
  mut content : Bytes
  mut loaded : Bool
}

///|
fn read_file(path : String) -> Bytes raise @types.SqlError {
  @fs.read_file_to_bytes(path) catch {
    _ => raise @types.SqlError::Scan("cannot read file at \{path}")
  }
}

///|
fn load_file(cache : FileCache, path : String) -> Unit raise @types.SqlError {
  if !cache.loaded {
    cache.content = read_file(path)
    cache.loaded = true
  }
}

///|
fn file_input(path : String) -> CsvInput raise @types.SqlError {
  let cache : FileCache = { content: read_file(path), loaded: true, }
  {
    label: path,
    size: fn() raise @types.SqlError {
      load_file(cache, path)
      cache.content.length().to_int64()
    },
    read_at: (offset, count) => {
      load_file(cache, path)
      (memory_input(cache.content).read_at)(offset, count)
    },
    reset: fn() {
      cache.loaded = false
      cache.content = b""
    },
  }
}
