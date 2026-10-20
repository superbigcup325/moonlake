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
