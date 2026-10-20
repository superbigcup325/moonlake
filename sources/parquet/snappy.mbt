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

// ---------------------------------------------------------------- compressor
//
// A compact LZ77 matcher in the Snappy block format: a 14-bit hash table over
// 4-byte sequences, literals between matches, and `copy2` tags (2-byte
// offset, up to 64 bytes). Not the fastest possible compressor — Snappy's own
// C++ implementation is hand-tuned — but it is the same format, and a Parquet
// reader cannot tell the difference.

///|
/// 4 bytes little-endian at `i` as an unsigned 32-bit integer.
fn snappy_load32(b : Bytes, i : Int32) -> UInt32 {
  let v : Int32 = b[i].to_int() |
    (b[i + 1].to_int() << 8) |
    (b[i + 2].to_int() << 16) |
    (b[i + 3].to_int() << 24)
  v.reinterpret_as_uint()
}

///|
fn snappy_hash(v : UInt32) -> Int32 {
  ((v.to_uint64() * 0x1e35a7bdUL) >> 18).to_int() & 0x3FFF
}

///|
/// Emit `b[start..end)` as a literal run.
fn snappy_literal(out : Buffer, b : Bytes, start : Int32, end : Int32) -> Unit {
  let len = end - start
  if len <= 0 {
    return
  }
  let n = len - 1
  if n < 60 {
    out.write_byte(((n << 2) | 0).to_byte())
  } else if n < 256 {
    out.write_byte((60 << 2).to_byte())
    out.write_byte(n.to_byte())
  } else if n < 65536 {
    out.write_byte((61 << 2).to_byte())
    out.write_byte((n & 0xFF).to_byte())
    out.write_byte(((n >> 8) & 0xFF).to_byte())
  } else {
    out.write_byte((62 << 2).to_byte())
    out.write_byte((n & 0xFF).to_byte())
    out.write_byte(((n >> 8) & 0xFF).to_byte())
    out.write_byte(((n >> 16) & 0xFF).to_byte())
  }
  for i in start..<end {
    out.write_byte(b[i])
  }
}

///|
/// Compress a block into the raw Snappy format (the inverse of
/// `snappy_decompress`). Every reference is a `copy2`, so offsets are limited
/// to 64 KiB and a match to 64 bytes — the two limits the simple matcher
/// below already respects.
fn snappy_compress(src : Bytes) -> Bytes {
  let out = Buffer()
  let mut declared = src.length().to_uint64()
  while declared >= 0x80UL {
    out.write_byte(((declared.to_int() & 0x7F) | 0x80).to_byte())
    declared = declared >> 7
  }
  out.write_byte(declared.to_int().to_byte())
  let n = src.length()
  if n < 4 {
    snappy_literal(out, src, 0, n)
    return out.to_bytes()
  }
  let table : Array[Int32] = Array::make(1 << 14, -1)
  let mut literal_from = 0
  let mut i = 0
  while i + 4 <= n {
    let h = snappy_hash(snappy_load32(src, i))
    let candidate = table[h]
    table[h] = i
    let matched = candidate >= 0 &&
      i - candidate <= 65535 &&
      src[candidate] == src[i] &&
      src[candidate + 1] == src[i + 1] &&
      src[candidate + 2] == src[i + 2] &&
      src[candidate + 3] == src[i + 3]
    if matched {
      snappy_literal(out, src, literal_from, i)
      let mut len = 4
      while len < 64 && i + len < n && src[candidate + len] == src[i + len] {
        len += 1
      }
      let offset = i - candidate
      out.write_byte((((len - 1) << 2) | 2).to_byte())
      out.write_byte((offset & 0xFF).to_byte())
      out.write_byte(((offset >> 8) & 0xFF).to_byte())
      i += len
      literal_from = i
    } else {
      i += 1
    }
  }
  snappy_literal(out, src, literal_from, n)
  out.to_bytes()
}
