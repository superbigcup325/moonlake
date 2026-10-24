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
priv struct GrowB {
  mut data : FixedArray[Bool]
  mut len : Int32
}

///|
fn GrowB::new() -> GrowB {
  { data: FixedArray::make(65536, false), len: 0, }
}

///|
fn GrowB::push(self : GrowB, v : Bool) -> Unit {
  if self.len == self.data.length() {
    let grown : FixedArray[Bool] = FixedArray::make(self.len * 2, false)
    for i in 0..<self.len {
      grown[i] = self.data[i]
    }
    self.data = grown
  }
  self.data.unsafe_set(self.len, v)
  self.len += 1
}

///|
fn GrowB::truncate(self : GrowB, n : Int32) -> Unit {
  self.len = n
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
fn GrowB::trim(self : GrowB) -> Unit {
  if self.len != self.data.length() {
    let exact : FixedArray[Bool] = FixedArray::make(self.len, false)
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
  quoted : GrowB // cell was quoted (escape decoding applies)
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
/// The cell carries no value: an unquoted empty field or a bare ""
/// (both decode to the empty string, both read back as NULL).
fn RawCsv::is_empty_cell(self : RawCsv, i : Int32) -> Bool {
  self.starts.data[i] == self.ends.data[i] ||
  (self.quoted.data[i] && self.ends.data[i] - self.starts.data[i] == 2)
}

///|
/// Scan only the first `max_rows` rows (header included) of a buffer that is
/// either a whole small CSV or a prefix of a large one. The buffer is treated
/// as if it ended there, so a trailing fragment counts as a row.
fn scan_csv_prefix(buf : Bytes, max_rows : Int32) -> RawCsv {
  scan_rows(buf, Some(max_rows), true).0
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
  self.quoted.truncate(cell)
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
  let quoted = GrowB::new()
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
        // read each byte once: the field body touches it a single time
        while pos < n {
          let b = buf.unsafe_get(pos).to_int()
          if b == 44 || b == 10 {
            break
          }
          pos += 1
        }
        field_end = pos
        // CRLF: the \r belongs to the terminator, not the field
        if field_end > field_start &&
          buf.unsafe_get(field_end - 1).to_int() == 13 {
          field_end -= 1
        }
      }
      starts.push(field_start)
      ends.push(field_end)
      quoted.push(is_quoted)
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
      !quoted.data[row_cells_start] &&
      starts.data[row_cells_start] == ends.data[row_cells_start]
    if blank {
      starts.truncate(row_cells_start)
      ends.truncate(row_cells_start)
      quoted.truncate(row_cells_start)
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
      quoted.truncate(cells)
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
  if !self.quoted.data[i] {
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
