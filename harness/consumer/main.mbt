///|
/// This is copied into an independent module by check_consumer.py. It must use
/// only the public library API and in-memory inputs, on every supported target.
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
}
