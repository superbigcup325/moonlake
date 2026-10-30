// Execution options: the memory budget and the spill store injection.
//
// The engine never touches the filesystem (wasm/js must keep
// compiling): a caller that wants out-of-core behavior provides a
// SpillStore — the native CLI injects a directory-backed store from
// the spill package; the playground simply omits it. Function fields
// instead of a trait: MoonBit traits are not types, and the store is
// always injected as a value.

///|
/// Storage for spilled intermediate state (sorted runs today). Ids are
/// opaque and scoped to one query; the engine removes everything it
/// wrote when the query ends, successfully or not.
pub(all) struct SpillStore {
  write : (Bytes) -> Int32 raise @types.SqlError
  read : (Int32) -> Bytes raise @types.SqlError
  remove : (Int32) -> Unit raise @types.SqlError
}

///|
pub(all) struct ExecOptions {
  budget : Int32 // approximate byte budget for blocking operators; <= 0 = unlimited (in-memory)
  spill : SpillStore? // required once budget > 0; without a store an over-budget query is an error
}

///|
/// Default options: unlimited memory, no spill store — the historical
/// in-memory behavior.
pub fn ExecOptions::in_memory() -> ExecOptions {
  { budget: 0, spill: None, }
}

///|
/// What a query actually pushed through its spill store. Counted at the
/// store boundary (one wrapper around the caller's `SpillStore`) rather
/// than inside each operator, so a new spilling operator cannot forget
/// to report itself, and so the numbers are what the filesystem saw.
priv struct SpillMeter {
  mut files : Int32
  mut written : Int64
  mut read : Int64
}

///|
fn SpillMeter::new() -> SpillMeter {
  { files: 0, written: 0L, read: 0L, }
}

///|
/// Wrap a store so every byte that crosses it is counted. Ids pass
/// through unchanged, so the wrapped store is a drop-in replacement.
fn SpillMeter::wrap(self : SpillMeter, base : SpillStore) -> SpillStore {
  {
    write: fn(bytes : Bytes) -> Int32 raise @types.SqlError {
      let id = (base.write)(bytes)
      self.files += 1
      self.written += bytes.length().to_int64()
      id
    },
    read: fn(id : Int32) -> Bytes raise @types.SqlError {
      let bytes = (base.read)(id)
      self.read += bytes.length().to_int64()
      bytes
    },
    remove: fn(id : Int32) -> Unit raise @types.SqlError { (base.remove)(id) },
  }
}

///|
/// The meter's lines for `explain_analyze`: only when something was
/// actually spilled, so an in-memory plan stays as short as before.
fn SpillMeter::report(
  self : SpillMeter,
  stats : Array[(String, Int64)],
) -> Unit {
  if self.files == 0 {
    return
  }
  stats.push(("spill files", self.files.to_int64()))
  stats.push(("spill bytes written", self.written))
  stats.push(("spill bytes read", self.read))
}

///|
/// One declared point in a profiling run: the label, the structures that were
/// alive there, and their sum.

///|
/// The residency reader a profiling run may inject: it returns the process's
/// resident KB right now and its high-water KB. The native CLI supplies one
/// that reads `/proc`; a target without it supplies none, and the report then
/// prints no resident fields at all rather than a zero that would pass for a
/// small residency (contract: docs/ROADMAP.md).
pub(all) struct Residency {
  read : () -> (Int32, Int32)
}

///|
priv struct MemPoint {
  label : String
  entries : Array[(String, Int64)]
  total : Int64
  rss : Int32 // resident KB sampled when this point was kept, 0 = not sampled
  high : Int32 // process high-water KB at that moment, 0 = not sampled
}

///|
/// The structure census a `--mem` run keeps: the largest point of each declared
/// label, and how many points were seen. A checkpoint is a named set of roots
/// the engine holds at that moment (the contract is in docs/ROADMAP.md), sized
/// from the structures themselves, so the report names bytes the executor can
/// point at instead of inferring them from RSS. Ordinary runs build no census
/// and pay nothing for it.
priv struct MemCensus {
  points : Array[MemPoint] // one per label: the largest point there
  mut seen : Int32
  sample : Residency? // residency reader, injected by the caller
  // structures a query holds across several points, each asked for its bytes at
  // the moment a point is kept: a root names itself at every point while it is
  // alive and reads zero once it has been let go (contract: docs/ROADMAP.md, "The
  // census names the shared scan cache contract")
  roots : Array[(String, () -> Int64)]
}

///|
fn MemCensus::new(sample~ : Residency? = None) -> MemCensus {
  { points: [], seen: 0, sample, roots: [], }
}

///|
/// Record one point, keeping the largest at its label. The point totals say
/// which part of a query the peak is in; the entries inside a point say what
/// that part is made of.
fn MemCensus::observe(
  self : MemCensus,
  label : String,
  entries : Array[(String, Int64)],
) -> Unit {
  // the live roots are read now, so a cache is named exactly between its fill and
  // its drop and nothing here keeps it alive
  let entries = entries.copy()
  for r in self.roots {
    let bytes = (r.1)()
    if bytes > 0L {
      entries.push((r.0, bytes))
    }
  }
  let mut total = 0L
  for e in entries {
    total += e.1
  }
  self.seen += 1
  // the process's own residency, read here and never from an engine root: the
  // readout may not keep anything alive (contract: docs/ROADMAP.md)
  let (rss, high) = match self.sample {
    Some(r) => (r.read)()
    None => (0, 0)
  }
  for i, p in self.points {
    if p.label == label {
      if total > p.total {
        self.points[i] = { label, entries, total, rss, high, }
      }
      return
    }
  }
  self.points.push({ label, entries, total, rss, high, })
}

///|
/// The census as it prints: one block per declared label, largest point first,
/// and the structures inside it largest first. Empty when no point was
/// observed.
fn MemCensus::render(self : MemCensus) -> String {
  let sb = StringBuilder()
  if self.points.length() == 0 {
    return sb.to_string()
  }
  // the high-water and the point whose sample was the largest: the named totals
  // alone cannot say where the process peaked (§62)
  let mut high = 0
  let mut peak_label = ""
  let mut peak_rss = 0
  for p in self.points {
    if p.high > high {
      high = p.high
    }
    if p.rss > peak_rss {
      peak_rss = p.rss
      peak_label = p.label
    }
  }
  sb.write_string(
    "-- resident by structure (largest point of each of \{self.points.length()} labels, \{self.seen} points seen",
  )
  if high > 0 {
    sb.write_string(", high \{high} KB, peak at \{peak_label}")
  }
  sb.write_string(")")
  let sorted = self.points.copy()
  sorted.sort_by(fn(x, y) {
    if x.total > y.total {
      -1
    } else if x.total < y.total {
      1
    } else {
      0
    }
  })
  for p in sorted {
    sb.write_string("\n# \{p.label}: \{p.total} bytes")
    if p.high > 0 {
      sb.write_string(" (rss \{p.rss} KB, high \{p.high} KB)")
    }
    let entries = p.entries.copy()
    entries.sort_by(fn(x, y) {
      if x.1 > y.1 {
        -1
      } else if x.1 < y.1 {
        1
      } else {
        0
      }
    })
    for e in entries {
      sb.write_string("\n\{e.0}: \{e.1}")
    }
  }
  sb.to_string()
}
