// Kernel benchmark driver (dev only, not part of the shipped package).
//
//   moon run --target native --release harness/kernel_bench
//   moon run --target native --release harness/kernel_bench -- --rows 200000 --runs 7
//
// Why this exists: the release record (`bench_release.py`) times whole
// queries, and every join case in it includes CSV ingest — 75 MB parsed before
// the join does anything. That answers "how long does this query take", not
// "what does the join kernel cost". Here the tables are materialized in
// memory (built once, outside the timed region) and split into 4096-row
// batches exactly like a scan produces, so a case measures the operator.
//
// The cases are chosen so that the difference between two of them isolates one
// structural cost:
//
//   join/int_key      single int32 equality key  -> the Map[Int64, ...] path
//   join/two_key      two int32 equality keys    -> the general path, which
//                                                    builds a canonical string
//                                                    key per row
//   join/str_key      one string key             -> string hashing
//   gather/narrow     one column out of eight
//   gather/wide       eight columns out of eight -> per-column gather cost
//   gather/nullable   eight nullable columns     -> the validity channel
//   scan/count        no join, no projection     -> the floor for the above

///|
struct Case {
  name : String
  sql : String
  expect : Expect
}

///|
/// What the case must return, so a stable wrong answer cannot be timed and
/// reported as a kernel cost. `Count` cases emit one row with one Int64; the
/// gather cases must return exactly the registered table's columns.
enum Expect {
  Count
  Rows(String, Int32)
}

///|
/// FNV-1a 64 over every scalar of a row, dtype tag mixed in so a schema
/// mix-up cannot pass. Per-row hashes are summed (order-independent) and the
/// row count is kept, so duplicates and drops both change the bag.
fn mix(h : UInt64, v : UInt64) -> UInt64 {
  (h ^ v) * 1099511628211UL
}

///|
fn dtype_tag(dt : @types.DataType) -> UInt64 {
  match dt {
    Int32 => 0x11UL
    Int64 => 0x12UL
    Float64 => 0x13UL
    Str => 0x14UL
    Bool => 0x15UL
    Date => 0x16UL
  }
}

///|
fn mix_scalar(h : UInt64, s : @types.Scalar) -> UInt64 {
  match s {
    Null => mix(h, 0xFFUL)
    Boolean(v) => mix(h, if v { 2UL } else { 1UL })
    Int32(v) => mix(h, v.to_int64().reinterpret_as_uint64())
    Int64(v) => mix(h, v.reinterpret_as_uint64())
    Float64(v) => mix(h, v.reinterpret_as_uint64())
    Date(v) => mix(h, v.to_int64().reinterpret_as_uint64())
    Str(v) => {
      let mut x = h
      for b in @utf8.encode(v) {
        x = mix(x, b.to_int().to_uint64())
      }
      mix(x, 0xFEUL)
    }
  }
}

///|
/// (row count, sum of per-row hashes) over the first `cols` columns.
fn bag_of_batches(
  batches : Array[@types.DataBatch],
  cols : Int32,
) -> (Int64, UInt64) {
  let mut rows = 0L
  let mut sum = 0UL
  for batch in batches {
    for r in 0..<batch.row_count() {
      let mut h = 14695981039346656037UL
      for c in 0..<cols {
        let column = batch.columns()[c]
        h = mix(h, dtype_tag(column.dtype()))
        h = mix_scalar(h, column.get(r))
      }
      sum = sum + h
    }
    rows += batch.row_count().to_int64()
  }
  (rows, sum)
}

///|
fn entry_bag(
  entry : @catalog.TableEntry,
  cols : Int32,
) -> (Int64, UInt64) raise {
  let batches = entry.scan(@catalog.ScanRequest::all(cols))
  bag_of_batches(batches, cols)
}

///|
fn result_bag(result : @engine.SelectResult) -> (Int64, UInt64) {
  bag_of_batches([result.batch()], result.types().length())
}

///|
/// Check one case's answer and return its output row count.
fn verify(
  case : Case,
  result : @engine.SelectResult,
  w : @catalog.TableEntry,
  wn : @catalog.TableEntry,
  rows : Int32,
) -> Int64 raise {
  match case.expect {
    Count => {
      if result.row_count() != 1 || result.types().length() != 1 {
        let msg = "kernel_bench \{case.name}: expected one row of one column, got \{result.row_count()}x\{result.types().length()}"
        eprintln(msg)
        abort(msg)
      }
      if result.get(0, 0) != @types.Scalar::Int64(rows.to_int64()) {
        let msg = "kernel_bench \{case.name}: count is \{result.get(0, 0).to_string()}, expected \{rows}"
        eprintln(msg)
        abort(msg)
      }
      result.row_count().to_int64()
    }
    Rows(table, cols) => {
      let entry = match table {
        "w" => w
        "wn" => wn
        _ => {
          let msg = "kernel_bench \{case.name}: no such table \{table}"
          eprintln(msg)
          abort(msg)
        }
      }
      let (want_rows, want_sum) = entry_bag(entry, cols)
      let (got_rows, got_sum) = result_bag(result)
      if got_rows != want_rows || got_sum != want_sum {
        let msg = "kernel_bench \{case.name}: output does not match the source table (\{got_rows} rows vs \{want_rows}, hash \{got_sum.to_string(radix=16)} vs \{want_sum.to_string(radix=16)})"
        eprintln(msg)
        abort(msg)
      }
      got_rows
    }
  }
}

///|
/// Wall time of one query, in milliseconds, measured in process.
/// `monotonic_clock_end` returns **microseconds** (see core/bench:
/// "Compute elapsed time in microseconds"), so divide before labelling.
fn time_query(sql : String, cat : @catalog.Catalog) -> Double raise {
  let start = @bench.monotonic_clock_start()
  let result = @moonlake.execute(sql, cat)
  let elapsed = @bench.monotonic_clock_end(start) / 1000.0
  // keep the result alive so the optimizer cannot drop the work
  if result.row_count() < 0 {
    println("impossible")
  }
  elapsed
}

///|
/// Build a materialized table of `rows` int32/int64/string columns, split into
/// 4096-row batches the way a scan would hand them over.
fn int_table(name : String, rows : Int32, keys : Int32) -> @catalog.TableEntry {
  let columns : Array[@catalog.Column] = []
  for c in 0..<keys {
    columns.push({ name: "k\{c}", dtype: @types.Int32, })
  }
  columns.push({ name: "payload", dtype: @types.Int32, })
  let batch_rows = @catalog.SCAN_BATCH_ROWS
  let batches : Array[@types.DataBatch] = []
  let mut from = 0
  while from < rows {
    let n = if from + batch_rows < rows { batch_rows } else { rows - from }
    let vectors : Array[@types.ColumnVector] = []
    for _ in 0..<keys {
      let v = @types.ColumnVector::make(@types.Int32, n)
      for i in 0..<n {
        v.set(i, @types.Int32((from + i) % rows))
      }
      vectors.push(v)
    }
    let p = @types.ColumnVector::make(@types.Int32, n)
    for i in 0..<n {
      p.set(i, @types.Int32((from + i) * 3 % 1000))
    }
    vectors.push(p)
    batches.push(@types.DataBatch::new(vectors, n))
    from += n
  }
  @catalog.TableEntry::new({ table: name, columns, }, batches)
}

///|
/// Eight columns of mixed types, `rows` rows, 4096 per batch. `nullable`
/// makes every value NULL on odd rows, which is the worst case for the
/// validity channel (half the rows present).
fn wide_table(
  name : String,
  rows : Int32,
  nullable : Bool,
) -> @catalog.TableEntry {
  let dtypes : Array[@types.DataType] = [
    @types.Int32,
    @types.Int64,
    @types.Float64,
    @types.Str,
    @types.Bool,
    @types.Date,
    @types.Int32,
    @types.Int64,
  ]
  let columns : Array[@catalog.Column] = []
  for c, dt in dtypes {
    columns.push({ name: "c\{c}", dtype: dt, })
  }
  let batch_rows = @catalog.SCAN_BATCH_ROWS
  let batches : Array[@types.DataBatch] = []
  let mut from = 0
  while from < rows {
    let n = if from + batch_rows < rows { batch_rows } else { rows - from }
    let vectors : Array[@types.ColumnVector] = []
    for c, dt in dtypes {
      let v = @types.ColumnVector::make(dt, n)
      for i in 0..<n {
        let absent = nullable && (from + i) % 2 == 1
        v.set(
          i,
          if absent {
            @types.Null
          } else {
            match dt {
              @types.Int32 => @types.Int32(from + i)
              @types.Int64 => @types.Int64((from + i).to_int64() * 7L)
              @types.Float64 => @types.Float64((from + i).to_double() / 3.0)
              @types.Str => @types.Str("row-\{c}-\{(from + i) % 1000}")
              @types.Bool => @types.Boolean((from + i) % 3 == 0)
              @types.Date => @types.Date(18000 + (from + i) % 365)
            }
          },
        )
      }
      vectors.push(v)
    }
    batches.push(@types.DataBatch::new(vectors, n))
    from += n
  }
  @catalog.TableEntry::new({ table: name, columns, }, batches)
}

///|
/// String-keyed table for the string-hash path.
fn str_key_table(name : String, rows : Int32) -> @catalog.TableEntry {
  let columns : Array[@catalog.Column] = [
    { name: "s", dtype: @types.Str, },
    { name: "v", dtype: @types.Int32, },
  ]
  let batch_rows = @catalog.SCAN_BATCH_ROWS
  let batches : Array[@types.DataBatch] = []
  let mut from = 0
  while from < rows {
    let n = if from + batch_rows < rows { batch_rows } else { rows - from }
    let s = @types.ColumnVector::make(@types.Str, n)
    let v = @types.ColumnVector::make(@types.Int32, n)
    for i in 0..<n {
      s.set(i, @types.Str("key-\{(from + i) % rows}-suffix"))
      v.set(i, @types.Int32((from + i) % 97))
    }
    batches.push(@types.DataBatch::new([s, v], n))
    from += n
  }
  @catalog.TableEntry::new({ table: name, columns, }, batches)
}

///|
fn best_of(runs : Int32, sql : String, cat : @catalog.Catalog) -> Double raise {
  let mut best = 1.0e18
  for _ in 0..<runs {
    let t = time_query(sql, cat)
    if t < best {
      best = t
    }
  }
  best
}

///|
fn main raise {
  let mut rows = 100000
  let mut runs = 7
  let args = @env.args()
  let mut i = 1
  while i + 1 < args.length() {
    if args[i] == "--rows" {
      rows = @string.parse_int(args[i + 1]) catch { _ => rows }
      i += 2
    } else if args[i] == "--runs" {
      runs = @string.parse_int(args[i + 1]) catch { _ => runs }
      i += 2
    } else {
      i += 1
    }
  }
  let cat = @catalog.Catalog::new()
  cat.register(int_table("a", rows, 1))
  cat.register(int_table("b", rows, 1))
  cat.register(int_table("a2", rows, 2))
  cat.register(int_table("b2", rows, 2))
  cat.register(str_key_table("sa", rows))
  cat.register(str_key_table("sb", rows))
  let w = wide_table("w", rows, false)
  let wn = wide_table("wn", rows, true)
  cat.register(w)
  cat.register(wn)

  let cases : Array[Case] = [
    { name: "scan/count", sql: "SELECT count(*) FROM w", expect: Count, },
    { name: "scan/count_a", sql: "SELECT count(*) FROM a", expect: Count, },
    {
      name: "join/comma_where",
      sql: "SELECT count(*) FROM a, b WHERE a.k0 = b.k0",
      expect: Count,
    },
    {
      name: "join/int_key",
      sql: "SELECT count(*) FROM a JOIN b ON a.k0 = b.k0",
      expect: Count,
    },
    {
      name: "join/two_key",
      sql: "SELECT count(*) FROM a2 JOIN b2 ON a2.k0 = b2.k0 AND a2.k1 = b2.k1",
      expect: Count,
    },
    {
      name: "join/str_key",
      sql: "SELECT count(*) FROM sa JOIN sb ON sa.s = sb.s",
      expect: Count,
    },
    { name: "gather/narrow", sql: "SELECT c0 FROM w", expect: Rows("w", 1), },
    { name: "gather/wide", sql: "SELECT * FROM w", expect: Rows("w", 8), },
    { name: "gather/nullable", sql: "SELECT * FROM wn", expect: Rows("wn", 8), },
  ]
  println("# kernel bench: \{rows} rows, best of \{runs}, native release")
  println("case\tbest_ms\trows_out")
  for c in cases {
    // one untimed run first: the first call allocates and touches every page
    let out_rows = time_query(c.sql, cat)
    let _ = out_rows
    let best = best_of(runs, c.sql, cat) catch {
      e => {
        println("\{c.name}\tFAILED\t\{e}")
        continue
      }
    }
    // The answer is checked outside the timed region against the table the
    // driver built, so a stable wrong answer cannot be reported as a cost.
    let result = @moonlake.execute(c.sql, cat) catch {
      e => abort("kernel_bench \{c.name}: \{e}")
    }
    let out_rows = verify(c, result, w, wn, rows)
    let rounded = (best * 1000.0).round() / 1000.0
    println("\{c.name}\t\{rounded}\t\{out_rows}")
  }
}
