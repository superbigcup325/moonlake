///|
/// This is copied into an independent module by check_consumer.py. It must use
/// only the public library API and in-memory inputs, on every supported target.

///|
/// Drain a stream as the JSON text `to_json` prints for the whole result:
/// `JsonRow` writes the rows of one batch without brackets, so the caller
/// supplies them and the commas between batches.
fn drain(s : @engine.ResultStream) -> String raise {
  let sb = StringBuilder()
  let row = @engine.JsonRow::new(s.names())
  let mut first = true
  sb.write_string("[")
  while s.next() is Some(batch) {
    if first {
      first = false
    } else {
      sb.write_char(',')
    }
    sb.write_string(row.batch(batch))
  }
  sb.write_string("]")
  sb.to_string()
}

///|
/// Stream a query and require the pulled delivery to print exactly what the
/// collected one prints. The shapes cover each pull the engine has: a scan with
/// a filter and a window, a two-table join, a folded aggregate and an order.
fn agree(name : String, sql : String, cat : @catalog.Catalog) -> Unit raise {
  let from_stream = drain(@moonlake.stream(sql, cat))
  let collected = @moonlake.execute(sql, cat).to_json()
  let verdict = if from_stream == collected { "same" } else { from_stream }
  println(name + "|" + verdict)
}

///|
fn main raise {
  println("version|" + @moonlake.version())
  let source = @csv.scan_string(
    "region,amount,event_day,note\nnorth,10,2024-01-01,first\nsouth,20,2024-01-03,\nnorth,5,2024-01-02,last\n",
    "events",
  )
  let cat = @catalog.Catalog::new()
  cat.register(source)
  let sql = "SELECT region, sum(amount) AS total, min(event_day) AS first_day, count(note) AS notes FROM events GROUP BY region ORDER BY region"
  println("csv|" + @moonlake.execute(sql, cat).to_json())
  let raw = @parquet.write_bytes(source)
  let snappy = @parquet.write_bytes_with(source, @parquet.Snappy)
  cat.register(@parquet.scan_bytes(raw, "raw", []))
  cat.register(@parquet.scan_bytes(snappy, "snappy", []))
  for name in ["raw", "snappy"] {
    let sql = "SELECT region, sum(amount) AS total, min(event_day) AS first_day, count(note) AS notes FROM \{name} GROUP BY region ORDER BY region"
    println(name + "|" + @moonlake.execute(sql, cat).to_json())
  }
  cat.drop("raw")
  assert_true(cat.lookup("raw") is None)
  println("drop|ok")
  cat.register(
    @csv.scan_string(
      "region,name\nnorth,Northland\nsouth,Southern\nwest,Western\n", "regions",
    ),
  )
  agree(
    "stream-scan", "SELECT region, amount FROM events WHERE amount > 5 LIMIT 1",
    cat,
  )
  agree(
    "stream-join", "SELECT e.region, r.name, e.amount FROM events AS e JOIN regions AS r ON e.region = r.region",
    cat,
  )
  agree(
    "stream-agg", "SELECT sum(amount) AS total, count(note) AS notes FROM events",
    cat,
  )
  agree(
    "stream-order", "SELECT region, amount FROM events ORDER BY amount DESC", cat,
  )
  // A caller may also stop early: one batch, then `close` and nothing left.
  let window = @moonlake.stream("SELECT * FROM events", cat)
  let mut batches = 0
  if window.next() is Some(_) {
    batches = batches + 1
  }
  window.close()
  println("close|" + batches.to_string())
}
