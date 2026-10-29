// The native half of the census's residency readout: the process's own bytes,
// so a report can say where the peak is instead of implying that its largest
// named point is that peak (contract: docs/ROADMAP.md, measurement §63).
//
// Nothing here reads the engine, and nothing here keeps a structure alive; it
// reads two pseudo-files and returns two numbers. A platform without `/proc`
// compiles mem_rss_other.mbt instead and reports no residency at all.

///|
/// The page size `/proc/self/statm` counts in. Linux on the hosts this project
/// measures is 4096-byte pages; the fallback of a different page size only makes
/// the number wrong by a constant factor, and the contract treats a residency
/// sample as a hint toward where the peak is, not as a byte-exact figure.
const RSS_PAGE_KB : Int32 = 4

///|
/// The process's resident KB right now and its high-water KB, from `/proc`. A
/// zero means "not sampled", and the report prints no resident fields for it.
fn rss_sample() -> (Int32, Int32) {
  let rss = match @io.read_small_file("/proc/self/statm", 256) {
    Some(text) =>
      match statm_resident_pages(text) {
        Some(pages) => pages * RSS_PAGE_KB
        None => 0
      }
    None => 0
  }
  let high = match @io.read_small_file("/proc/self/status", 8192) {
    Some(text) => status_hwm_kb(text)
    None => 0
  }
  (rss, high)
}

///|
/// Field 2 of `/proc/self/statm` (field 1 is the program size in pages).
fn statm_resident_pages(text : String) -> Int32? {
  let mut index = 0
  for field in text.split(" ") {
    let f = field.trim()
    if f == "" {
      continue
    }
    if index == 1 {
      return digits(f.to_owned())
    }
    index += 1
  }
  None
}

///|
/// The `VmHWM:` line of `/proc/self/status`, in kB.
fn status_hwm_kb(text : String) -> Int32 {
  for line in text.split("\n") {
    let l = line.trim()
    if l.has_prefix("VmHWM:") {
      let rest = l[6:].to_owned()
      for field in rest.split(" ") {
        let f = field.trim()
        if f != "" {
          return match digits(f.to_owned()) {
            Some(v) => v
            None => 0
          }
        }
      }
    }
  }
  0
}

///|
/// A run of ASCII digits, or None at the first non-digit.
fn digits(text : String) -> Int32? {
  if text.length() == 0 {
    return None
  }
  let mut v = 0L
  for ch in text {
    let d = ch.to_int() - 48
    if d < 0 || d > 9 {
      return None
    }
    v = v * 10L + d.to_int64()
    if v > 2147483647L {
      return None
    }
  }
  Some(v.to_int())
}
