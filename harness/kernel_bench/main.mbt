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
  cat.register(wide_table("w", rows, false))
  cat.register(wide_table("wn", rows, true))

  let cases : Array[Case] = [
    { name: "scan/count", sql: "SELECT count(*) FROM w", },
    { name: "scan/count_a", sql: "SELECT count(*) FROM a", },
    {
      name: "join/comma_where",
      sql: "SELECT count(*) FROM a, b WHERE a.k0 = b.k0",
    },
    {
      name: "join/int_key",
      sql: "SELECT count(*) FROM a JOIN b ON a.k0 = b.k0",
    },
    {
      name: "join/two_key",
      sql: "SELECT count(*) FROM a2 JOIN b2 ON a2.k0 = b2.k0 AND a2.k1 = b2.k1",
    },
    {
      name: "join/str_key",
      sql: "SELECT count(*) FROM sa JOIN sb ON sa.s = sb.s",
    },
    { name: "gather/narrow", sql: "SELECT c0 FROM w", },
    { name: "gather/wide", sql: "SELECT * FROM w", },
    { name: "gather/nullable", sql: "SELECT * FROM wn", },
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
    let n = @moonlake.execute(c.sql, cat) catch { _ => abort("") }
    let rounded = (best * 1000.0).round() / 1000.0
    println("\{c.name}\t\{rounded}\t\{n.row_count()}")
  }
}
