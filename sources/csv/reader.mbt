// Byte-level CSV reader: RFC-4180 dialect — quoted fields, "" escape,
// newlines and commas inside quotes, LF or CRLF row terminators, blank
// lines skipped. The scan records per-cell byte offsets only; no
// per-cell Strings exist until a column materializes (and numeric,
// boolean and date columns never build one at all).

///|
/// Growable unboxed array: a boxed Array[Int] holds ~10M heap objects
/// for a 600k-row table (SF0.1 lineitem) and the GC churn dominates the
/// scan; FixedArray doubling amortizes to plain memory copies.
priv struct GrowI {
  mut data : FixedArray[Int32]
  mut len : Int32
}

///|
fn GrowI::new() -> GrowI {
  { data: FixedArray::make(65536, 0), len: 0, }
}

///|
fn GrowI::push(self : GrowI, v : Int32) -> Unit {
  if self.len == self.data.length() {
    let grown : FixedArray[Int32] = FixedArray::make(self.len * 2, 0)
    for i in 0..<self.len {
      grown[i] = self.data[i]
    }
    self.data = grown
  }
  self.data.unsafe_set(self.len, v)
  self.len += 1
}

///|
fn GrowI::truncate(self : GrowI, n : Int32) -> Unit {
  self.len = n
}

///|

///|
/// Drop the entries that are `>= threshold`: the caller cut the cells those
/// entries describe, so they are no longer part of the index.
fn GrowI::truncate_from(self : GrowI, threshold : Int32) -> Unit {
  let mut lo = 0
  let mut hi = self.len
  while lo < hi {
    let mid = (lo + hi) >> 1
    if self.data.unsafe_get(mid) < threshold {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  self.len = lo
}

///|
/// Copy back to exact capacity: the scan over-allocates by up to 2x
/// while doubling, and the raw arrays outlive the scan in RawCsv.
fn GrowI::trim(self : GrowI) -> Unit {
  if self.len != self.data.length() {
    let exact : FixedArray[Int32] = FixedArray::make(self.len, 0)
    for i in 0..<self.len {
      exact[i] = self.data[i]
    }
    self.data = exact
  }
}

///|
priv struct RawCsv {
  buf : Bytes
  starts : GrowI // cell start offset, row-major
  ends : GrowI // cell end offset, exclusive
  // the cells that were quoted, ascending: escape decoding applies to those
  // and only those. A list rather than a flag per cell because most CSV
  // fields are unquoted, and the flag array cost a write on every cell of
  // every file to answer a question almost always answered "no".
  quoted : GrowI
  rows : GrowI // cell index each row starts at, plus end sentinel
}

///|
fn RawCsv::n_rows(self : RawCsv) -> Int32 {
  self.rows.len - 1
}

///|
/// Cells of row r occupy [row_start(r), row_start(r + 1)) in the cell
/// arrays.
fn RawCsv::row_start(self : RawCsv, r : Int32) -> Int32 {
  self.rows.data[r]
}

///|
/// Was cell `i` quoted? The list is ascending and usually empty, so this is a
/// binary search over zero entries in the common case.
fn RawCsv::is_quoted(self : RawCsv, i : Int32) -> Bool {
  let q = self.quoted.data
  let n = self.quoted.len
  let mut lo = 0
  let mut hi = n
  while lo < hi {
    let mid = (lo + hi) >> 1
    if q.unsafe_get(mid) < i {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  lo < n && q.unsafe_get(lo) == i
}

///|
/// The cell carries no value: an unquoted empty field or a bare ""
/// (both decode to the empty string, both read back as NULL).
fn RawCsv::is_empty_cell(self : RawCsv, i : Int32) -> Bool {
  let s = self.starts.data[i]
  let e = self.ends.data[i]
  s == e || (e - s == 2 && self.is_quoted(i))
}

///|
/// Cells in row `r` (row 0 is the header). A short row is a data defect, not a
/// shape: its cell offsets would run into the next row's cells, so every
/// reader checks this before touching a row's cells column by column.
fn RawCsv::n_cells(self : RawCsv, r : Int32) -> Int32 {
  self.rows.data[r + 1] - self.rows.data[r]
}

///|
/// Scan only the first `max_rows` rows (header included) of a buffer that is
/// either a whole small CSV or a prefix of a large one. The buffer is treated
/// as if it ended there, so a trailing fragment counts as a row.
fn scan_csv_prefix(buf : Bytes, max_rows : Int32) -> RawCsv {
  scan_rows(buf, Some(max_rows), true).0
}

///|
/// The offset of the first `,` or newline at or after `from`, or the length of
/// `buf` when it holds neither. Unquoted field bodies end exactly there.
///
/// Eight bytes per iteration: `(w ^ sep) - 1` borrows out of a byte that
/// matches `sep`, and `~b` keeps only bytes that were not 0x01, so the high bit
/// of a matching byte is set in the mask. A byte above a match can also show a
/// high bit, which is harmless here: the lowest set bit is a real match, and
/// that is the one the caller wants.
fn find_sep(buf : Bytes, from : Int32) -> Int32 {
  let n = buf.length()
  let ones = 0x0101010101010101UL
  let highs = 0x8080808080808080UL
  let commask = 0x2C2C2C2C2C2C2C2CUL
  let nl = 0x0A0A0A0A0A0A0A0AUL
  let mut p = from
  while p + 8 <= n {
    let w = buf.unsafe_read_uint64_le(p)
    let a = w ^ commask
    let b = w ^ nl
    let mask = ((a - ones) & a.lnot() & highs) | ((b - ones) & b.lnot() & highs)
    if mask != 0UL {
      return p + (mask.ctz() >> 3)
    }
    p += 8
  }
  while p < n {
    let c = buf.unsafe_get(p).to_int()
    if c == 44 || c == 10 {
      return p
    }
    p += 1
  }
  n
}

///|
/// Scan one chunk of a larger file and report where the last complete record
/// ends. A record ends at a newline outside quotes, so a chunk can end inside
/// one: unless `at_eof`, that trailing fragment is left out of the index and
/// `consumed` is the offset of the record it belongs to, which is where the
/// next chunk starts. Cell offsets in the result are relative to `buf`, and no
/// record is ever split across two chunks.
fn scan_chunk(buf : Bytes, at_eof : Bool) -> (RawCsv, Int32) {
  scan_rows(buf, None, at_eof)
}

///|
/// Keep rows `0..<n` of the index and report the byte offset where row `n`
/// starts, so a caller can make the next chunk begin on that record.
fn RawCsv::cut_rows(self : RawCsv, n : Int32) -> Int32 {
  let cell = self.row_start(n)
  let offset = self.starts.data[cell]
  self.starts.truncate(cell)
  self.ends.truncate(cell)
  self.quoted.truncate_from(cell)
  self.rows.truncate(n + 1)
  offset
}

///|
/// Worker behind `scan_csv_prefix` and `scan_chunk`: index every record in
/// `buf` and report where the last complete one ends (`consumed`).
fn scan_rows(buf : Bytes, limit : Int32?, at_eof : Bool) -> (RawCsv, Int32) {
  let n = buf.length()
  let starts = GrowI::new()
  let ends = GrowI::new()
  let quoted = GrowI::new() // cell indexes, ascending
  let rows = GrowI::new()
  rows.push(0)
  let mut pos = 0
  let mut complete = 0 // end offset of the last newline-terminated record
  while pos < n {
    // scan one row of fields
    let row_cells_start = starts.len
    let mut row_terminated = false
    let mut ended_at_newline = false
    while !row_terminated {
      let field_start = pos
      let mut is_quoted = false
      let mut field_end = pos
      if pos < n && buf[pos].to_int() == 34 {
        // '"': quoted field
        is_quoted = true
        pos += 1
        while pos < n {
          if buf[pos].to_int() == 34 {
            if pos + 1 < n && buf[pos + 1].to_int() == 34 {
              pos += 2 // "" escape stays inside the field
            } else {
              pos += 1 // closing quote
              break
            }
          } else {
            pos += 1 // newlines and commas are content in quotes
          }
        }
        // literal characters between the closing quote and the field
        // separator stay part of the field (lenient on malformed input)
        while pos < n {
          let b = buf[pos].to_int()
          if b == 44 || b == 10 {
            break
          }
          pos += 1
        }
        field_end = pos
      } else {
        // the field body ends at the first ',' or '\n': eight bytes a word,
        // because a per-byte loop over the whole file was the scan's largest
        // cost and a word is the same bytes for an eighth of the loop
        pos = find_sep(buf, pos)
        field_end = pos
        // CRLF: the \r belongs to the terminator, not the field
        if field_end > field_start &&
          buf.unsafe_get(field_end - 1).to_int() == 13 {
          field_end -= 1
        }
      }
      if is_quoted {
        quoted.push(starts.len)
      }
      starts.push(field_start)
      ends.push(field_end)
      // field separator or row terminator
      if pos < n {
        if buf[pos].to_int() == 44 {
          pos += 1
        } else {
          pos += 1 // '\n'
          row_terminated = true
          ended_at_newline = true
        }
      } else {
        row_terminated = true
      }
    }
    // skip blank lines (single unquoted empty cell), matching the
    // previous parser's skip_empty_lines behavior
    let blank = starts.len == row_cells_start + 1 &&
      starts.data[row_cells_start] == ends.data[row_cells_start]
    if blank {
      starts.truncate(row_cells_start)
      ends.truncate(row_cells_start)
      quoted.truncate_from(row_cells_start)
      if ended_at_newline {
        complete = pos
      }
    } else {
      rows.push(starts.len)
      if ended_at_newline {
        complete = pos
      }
      // `limit` counts the header row plus data rows: once it is reached the
      // rest of the buffer can stay unread
      if limit is Some(k) && rows.len > k {
        break
      }
    }
  }
  // a chunk that did not reach EOF may hold a record cut in half: drop it and
  // report where it started, so the next chunk begins on a record boundary
  let mut consumed = n
  if !at_eof {
    if rows.len > 1 && complete < n {
      rows.truncate(rows.len - 1)
      let cells = rows.data[rows.len - 1]
      starts.truncate(cells)
      ends.truncate(cells)
      quoted.truncate_from(cells)
      consumed = complete
    } else if rows.len == 1 {
      consumed = 0
    }
  }
  starts.trim()
  ends.trim()
  quoted.trim()
  rows.trim()
  ({ buf, starts, ends, quoted, rows, }, consumed)
}

///|
/// Decode one cell to its String value: quoted fields drop the outer
/// quotes and fold "" escapes; everything else decodes the raw range.
fn RawCsv::decode(self : RawCsv, i : Int32) -> String {
  let s = self.starts.data[i]
  let e = self.ends.data[i]
  if !self.is_quoted(i) {
    return @utf8.decode_lossy(self.buf[s:e])
  }
  // quoted: strip the opening quote, fold "" into ", drop the closing
  // quote; anything after it stays verbatim (lenient)
  let out : @buffer.Buffer = @buffer.Buffer::Buffer(size_hint=e - s)
  let mut p = s + 1
  while p < e {
    let b = self.buf[p]
    if b.to_int() == 34 {
      if p + 1 < e && self.buf[p + 1].to_int() == 34 {
        out.write_byte(b) // "" -> "
        p += 2
      } else {
        p += 1 // closing quote: dropped
      }
    } else {
      out.write_byte(b)
      p += 1
    }
  }
  @utf8.decode_lossy(out.to_bytes()[:])
}
