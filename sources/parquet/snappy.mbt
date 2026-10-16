// Raw Snappy decompression — the only codec Parquet writers reach for by
// default (DuckDB, Arrow and pandas all default to it), and there is no
// Snappy package in the MoonBit ecosystem to lean on.
//
// The block format is small enough to implement directly: a varint holding
// the uncompressed length, then a sequence of tags that are either literals
// or back-references. Copies may overlap the bytes they produce, so the copy
// runs byte by byte.

///|
fn snappy_error(msg : String) -> @types.SqlError {
  @types.SqlError::Scan("parquet: snappy: " + msg)
}

///|
/// Decompress a raw Snappy block. `expected` is the page's uncompressed size
/// from the page header; a mismatch means the input is not a valid block and
/// is reported rather than silently truncated.
fn snappy_decompress(
  src : BytesView,
  expected : Int32,
) -> Bytes raise @types.SqlError {
  let mut pos = 0
  let len = src.length()
  let mut declared = 0UL
  let mut shift = 0
  while true {
    if pos >= len {
      raise snappy_error("truncated length header")
    }
    let b = src[pos].to_int()
    pos += 1
    declared = declared | ((b & 0x7F).to_uint64() << shift)
    if (b & 0x80) == 0 {
      break
    }
    shift += 7
    if shift > 28 {
      raise snappy_error("length header longer than 5 bytes")
    }
  }
  let declared_size = declared.to_int()
  if declared_size != expected {
    raise snappy_error(
      "block declares \{declared_size} bytes, page header says \{expected}",
    )
  }
  let out : FixedArray[Byte] = FixedArray::make(declared_size, b'\x00')
  let mut written = 0
  while pos < len {
    let tag = src[pos].to_int()
    pos += 1
    let kind = tag & 3
    if kind == 0 {
      // literal: length is inline for small values, else 1-4 following bytes
      let mut n = (tag >> 2) + 1
      if n > 60 {
        let extra = n - 60
        if pos + extra > len {
          raise snappy_error("truncated literal length")
        }
        let mut v = 0
        for i in 0..<extra {
          v = v | (src[pos + i].to_int() << (8 * i))
        }
        pos += extra
        n = v + 1
      }
      if pos + n > len {
        raise snappy_error("literal of \{n} bytes runs past the block")
      }
      if written + n > declared_size {
        raise snappy_error("literal overruns the output buffer")
      }
      for i in 0..<n {
        out[written + i] = src[pos + i]
      }
      pos += n
      written += n
    } else {
      // copy: offset width depends on the tag kind
      let mut n = 0
      let mut offset = 0
      if kind == 1 {
        if pos >= len {
          raise snappy_error("truncated copy offset")
        }
        n = ((tag >> 2) & 0x7) + 4
        offset = (tag >> 5 << 8) | src[pos].to_int()
        pos += 1
      } else if kind == 2 {
        if pos + 2 > len {
          raise snappy_error("truncated copy offset")
        }
        n = (tag >> 2) + 1
        offset = src[pos].to_int() | (src[pos + 1].to_int() << 8)
        pos += 2
      } else {
        if pos + 4 > len {
          raise snappy_error("truncated copy offset")
        }
        n = (tag >> 2) + 1
        offset = src[pos].to_int() |
          (src[pos + 1].to_int() << 8) |
          (src[pos + 2].to_int() << 16) |
          (src[pos + 3].to_int() << 24)
        pos += 4
      }
      if offset <= 0 || offset > written {
        raise snappy_error(
          "copy offset \{offset} points outside the \{written} bytes written so far",
        )
      }
      if written + n > declared_size {
        raise snappy_error("copy overruns the output buffer")
      }
      // byte-by-byte: a copy may overlap the bytes it is producing
      for _ in 0..<n {
        out[written] = out[written - offset]
        written += 1
      }
    }
  }
  if written != declared_size {
    raise snappy_error("produced \{written} bytes, expected \{declared_size}")
  }
  Bytes::from_array(out[:])
}
