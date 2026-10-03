// Byte-level CSV reader: RFC-4180 dialect — quoted fields, "" escape,
// newlines and commas inside quotes, LF or CRLF row terminators, blank
// lines skipped. The scan records per-cell byte offsets only; no
// per-cell Strings exist until a column materializes (and numeric,
// boolean and date columns never build one at all).

///|
priv struct RawCsv {
  buf : Bytes
  starts : Array[Int] // cell start offset, row-major
  ends : Array[Int] // cell end offset, exclusive
  quoted : Array[Bool] // cell was quoted (escape decoding applies)
  rows : Array[Int] // cell index each row starts at, plus end sentinel
}

///|
fn RawCsv::n_rows(self : RawCsv) -> Int {
  self.rows.length() - 1
}

///|
/// Cells of row r occupy [row_start(r), row_start(r + 1)) in the cell
/// arrays.
fn RawCsv::row_start(self : RawCsv, r : Int) -> Int {
  self.rows[r]
}

///|
/// The cell carries no value: an unquoted empty field or a bare ""
/// (both decode to the empty string, both read back as NULL).
fn RawCsv::is_empty_cell(self : RawCsv, i : Int) -> Bool {
  self.starts[i] == self.ends[i] ||
  (self.quoted[i] && self.ends[i] - self.starts[i] == 2)
}

///|
fn scan_csv(buf : Bytes) -> RawCsv {
  let n = buf.length()
  let starts : Array[Int] = []
  let ends : Array[Int] = []
  let quoted : Array[Bool] = []
  let rows : Array[Int] = [0]
  let mut pos = 0
  while pos < n {
    // scan one row of fields
    let row_cells_start = starts.length()
    let mut row_terminated = false
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
        while pos < n && buf[pos].to_int() != 44 && buf[pos].to_int() != 10 {
          pos += 1
        }
        field_end = pos
      } else {
        while pos < n && buf[pos].to_int() != 44 && buf[pos].to_int() != 10 {
          pos += 1
        }
        field_end = pos
        // CRLF: the \r belongs to the terminator, not the field
        if field_end > field_start && buf[field_end - 1].to_int() == 13 {
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
        }
      } else {
        row_terminated = true
      }
    }
    // skip blank lines (single unquoted empty cell), matching the
    // previous parser's skip_empty_lines behavior
    let blank = starts.length() == row_cells_start + 1 &&
      !quoted[row_cells_start] &&
      starts[row_cells_start] == ends[row_cells_start]
    if blank {
      starts.truncate(row_cells_start)
      ends.truncate(row_cells_start)
      quoted.truncate(row_cells_start)
    } else {
      rows.push(starts.length())
    }
  }
  { buf, starts, ends, quoted, rows, }
}

///|
/// Decode one cell to its String value: quoted fields drop the outer
/// quotes and fold "" escapes; everything else decodes the raw range.
fn RawCsv::decode(self : RawCsv, i : Int) -> String {
  let s = self.starts[i]
  let e = self.ends[i]
  if !self.quoted[i] {
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
