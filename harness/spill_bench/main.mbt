// Spill-format benchmark driver (dev only).
//
//   moon run --target native harness/spill_bench -- \
//     --mode both --csv harness/data/sf001/lineitem.csv --out /tmp/spill.bin
//
// `write` scans the CSV, serializes every batch with the spill encoder and
// writes the bytes; `read` deserializes the file; `both` does both and checks
// the checksums match. Timing and RSS live in the Python wrapper, which runs
// the release binary.
//
// The checksum is FNV-1a 64 over every scalar in row order, mixing the dtype
// tag so a schema mix-up cannot pass.

///|
fn mix(h : UInt64, v : UInt64) -> UInt64 {
  (h ^ v) * 1099511628211UL
}

///|
fn dtype_tag(dt : @types.DataType) -> UInt64 {
  match dt {
    Int32 => 0x11UL
    Int64 => 0x12UL
    Float64 => 0x13UL
    Str => 0x14UL
    Bool => 0x15UL
    Date => 0x16UL
  }
}

///|
fn hash_scalar(h : UInt64, s : @types.Scalar) -> UInt64 {
  match s {
    Null => mix(h, 0xFFUL)
    Boolean(v) => mix(h, if v { 2UL } else { 1UL })
    Int32(v) => mix(h, v.to_int64().reinterpret_as_uint64())
    Int64(v) => mix(h, v.reinterpret_as_uint64())
    Float64(v) => mix(h, v.reinterpret_as_uint64())
    Date(v) => mix(h, v.to_int64().reinterpret_as_uint64())
    Str(v) => {
      let mut x = h
      for b in @utf8.encode(v) {
        x = mix(x, b.to_int().to_uint64())
      }
      mix(x, 0xFEUL)
    }
  }
}

///|
fn checksum(batches : Array[@types.DataBatch]) -> UInt64 {
  let mut h = 14695981039346656037UL
  for batch in batches {
    h = mix(h, batch.row_count().to_int64().reinterpret_as_uint64())
    for col in batch.columns() {
      h = mix(h, dtype_tag(col.dtype()))
      for r in 0..<batch.row_count() {
        h = hash_scalar(h, col.get(r))
      }
    }
  }
  h
}

///|
fn rows(batches : Array[@types.DataBatch]) -> Int64 {
  let mut n = 0L
  for batch in batches {
    n += batch.row_count().to_int64()
  }
  n
}

///|
fn usage() -> Unit {
  println(
    "usage: moon run --target native harness/spill_bench -- --mode <write|read|both> [--csv <file>] [--out <file>] [--in <file>]",
  )
}

///|
fn main raise {
  let args = @env.args()
  let mut mode = "both"
  let mut csv = "harness/data/sf001/lineitem.csv"
  let mut out = "/tmp/moonlake-spill-bench.bin"
  let mut input = ""
  let mut i = 1
  while i < args.length() {
    if args[i] == "--mode" && i + 1 < args.length() {
      mode = args[i + 1]
      i += 2
    } else if args[i] == "--csv" && i + 1 < args.length() {
      csv = args[i + 1]
      i += 2
    } else if args[i] == "--out" && i + 1 < args.length() {
      out = args[i + 1]
      i += 2
    } else if args[i] == "--in" && i + 1 < args.length() {
      input = args[i + 1]
      i += 2
    } else {
      eprintln("spill_bench: unexpected argument \{args[i]}")
      usage()
      return
    }
  }

  let mut write_sum = 0UL
  let mut read_sum = 0UL
  if mode == "write" || mode == "both" {
    let entry = @csv.scan_file(csv, "lineitem")
    let bytes = @types.DataBatch::to_spill_bytes(entry.batches)
    @fs.write_bytes_to_file(out, bytes)
    write_sum = checksum(entry.batches)
    println(
      "write bytes=\{bytes.length()} rows=\{rows(entry.batches)} checksum=\{write_sum.to_string(radix=16)}",
    )
  }
  let source = if input != "" { input } else { out }
  if mode == "read" || mode == "both" {
    let bytes = @fs.read_file_to_bytes(source)
    let batches = @types.DataBatch::from_spill_bytes(bytes)
    read_sum = checksum(batches)
    println(
      "read rows=\{rows(batches)} checksum=\{read_sum.to_string(radix=16)}",
    )
  }
  if mode == "both" && write_sum != read_sum {
    abort("spill_bench: checksum mismatch between write and read")
  }
}
