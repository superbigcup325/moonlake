///|
/// Spill-format bake-off harness: one process per phase so wall time
/// and maxRSS are attributable.
///   spillbench write <csv> <out>   scan CSV, serialize, print stats
///   spillbench read  <out>         deserialize, print stats
fn main raise {
  let args = @env.args()
  if args.length() < 3 {
    eprintln("usage: spillbench write <csv> <out> | spillbench read <out>")
    @sys.exit(2)
  }
  match args[1] {
    "write" => {
      if args.length() != 4 {
        eprintln("usage: spillbench write <csv> <out>")
        @sys.exit(2)
      }
      let entry = @csv.scan_file(args[2], "t") catch {
        err => {
          eprintln("scan: \{err}")
          @sys.exit(1)
          abort("unreachable")
        }
      }
      let mut rows = 0
      for b in entry.batches {
        rows += b.row_count()
      }
      let bytes = @spill.write_batches(args[3], entry.batches)
      println("rows=\{rows} bytes=\{bytes} checksum=\{checksum(entry.batches)}")
    }
    "read" => {
      let batches = @spill.read_batches(args[2]) catch {
        err => {
          eprintln("read: \{err}")
          @sys.exit(1)
          abort("unreachable")
        }
      }
      let mut rows = 0
      for b in batches {
        rows += b.row_count()
      }
      println("rows=\{rows} checksum=\{checksum(batches)}")
    }
    other => {
      eprintln("unknown phase \{other}")
      @sys.exit(2)
    }
  }
}

///|
/// Deterministic fold over the whole scalar stream (row-major FNV-1a
/// over each scalar's key text): both bake-off arms print the same
/// shape of number, and write/read phases must agree.
fn checksum(batches : Array[@types.DataBatch]) -> String {
  let mut h : UInt64 = 0xcbf29ce484222325UL
  for batch in batches {
    let cols = batch.columns()
    for r in 0..<batch.row_count() {
      for c in 0..<cols.length() {
        let key = scalar_text(cols[c].get(r))
        for ch in key {
          h = (h ^ ch.to_int().to_uint64()) * 0x100000001b3UL
        }
        h = h * 0x100000001b3UL // separator fold
      }
    }
  }
  hex64(h)
}

///|
fn hex64(v : UInt64) -> String {
  let digits : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  let sb = StringBuilder()
  for k in 0..<16 {
    let nibble = ((v >> ((15 - k) * 4)) & 0xFUL).to_int()
    sb.write_char(digits[nibble])
  }
  sb.to_string()
}

///|
fn scalar_text(v : @types.Scalar) -> String {
  match v {
    @types.Null => "0:"
    @types.Boolean(b) => if b { "1:T" } else { "1:F" }
    @types.Int32(x) => "2:\{x}"
    @types.Int64(x) => "3:\{x}"
    @types.Float64(x) => "4:\{x}"
    @types.Str(s) => "5:\{s}"
    @types.Date(d) => "6:\{d}"
  }
}
