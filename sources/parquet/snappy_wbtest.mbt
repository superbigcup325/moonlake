// Whitebox tests for the Snappy block codec: the compressor is new, the
// decompressor is the reference the reader already trusts, so the contract is
// compress -> decompress -> the same bytes, for the shapes that matter
// (empty, shorter than a match, long runs, incompressible data, and a block
// large enough to exercise both 64 KiB offsets and multi-byte length tags).

///|
fn snappy_roundtrip(src : Bytes) -> Unit raise {
  let packed = snappy_compress(src)
  let back = snappy_decompress(packed[:], src.length())
  assert_eq(back, src)
}

///|
test "snappy round trips the shapes a page can have" {
  snappy_roundtrip(b"")
  snappy_roundtrip(b"a")
  snappy_roundtrip(b"abc")
  snappy_roundtrip(b"abcd")
  snappy_roundtrip(b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  // a match that runs past the 64-byte copy limit has to become two copies
  let long = StringBuilder()
  for _ in 0..<200 {
    long.write_string("moonlake ")
  }
  snappy_roundtrip(@utf8.encode(long.to_string()))
  // 61/62-style literals: a single run longer than 60 bytes with no repeats
  let noisy = Buffer()
  for i in 0..<300 {
    noisy.write_byte((i * 7 + 3).to_byte())
  }
  snappy_roundtrip(noisy.to_bytes())
}

///|
test "snappy round trips a block past the 64 KiB offset window" {
  // 200 KiB of two alternating patterns: matches are far-far-away or close
  // depending on the hash table, which is what the offset guard protects
  let big = Buffer()
  for i in 0..<200000 {
    big.write_byte((i % 251 * 3).to_byte())
  }
  snappy_roundtrip(big.to_bytes())
}

///|
/// Walk a compressed block and count literals, two-byte `copy1` tags and wider
/// copies, so a test can pin the tag choice without depending on exact byte
/// counts.
fn snappy_tag_counts(packed : Bytes) -> (Int32, Int32, Int32) {
  let mut pos = 0
  while true {
    let b = packed[pos].to_int()
    pos += 1
    if (b & 0x80) == 0 {
      break
    }
  }
  let mut literals = 0
  let mut copy1 = 0
  let mut wide = 0
  while pos < packed.length() {
    let tag = packed[pos].to_int()
    pos += 1
    if (tag & 3) == 0 {
      let mut n = (tag >> 2) + 1
      if n > 60 {
        let extra = n - 60
        let mut v = 0
        for i in 0..<extra {
          v = v | (packed[pos + i].to_int() << (8 * i))
        }
        pos += extra
        n = v + 1
      }
      pos += n
      literals += 1
    } else if (tag & 3) == 1 {
      copy1 += 1
      pos += 1
    } else if (tag & 3) == 2 {
      wide += 1
      pos += 2
    } else {
      wide += 1
      pos += 4
    }
  }
  (literals, copy1, wide)
}

///|
test "a short match close behind is a two-byte copy" {
  // Every eight bytes repeat "abcd" with varying bytes after it, so the
  // matcher finds length-4 matches at offset 8: the shape most text pages
  // are made of, and the one a `copy2` overpays for.
  let out = Buffer()
  for i in 0..<100 {
    out.write_byte(b'a')
    out.write_byte(b'b')
    out.write_byte(b'c')
    out.write_byte(b'd')
    out.write_byte((i % 7).to_byte())
    out.write_byte((i % 3).to_byte())
    out.write_byte((i % 11).to_byte())
    out.write_byte(b'x')
  }
  let src = out.to_bytes()
  snappy_roundtrip(src)
  let (_, copy1, wide) = snappy_tag_counts(snappy_compress(src))
  assert_true(copy1 > 90)
  assert_eq(wide, 0)
}
