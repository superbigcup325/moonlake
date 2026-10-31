///|
/// The README's first library snippet as a package: register an in-memory CSV,
/// run SQL, and read the collected result cell by cell.

///|
fn main raise {
  let cat = @catalog.Catalog::new()
  cat.register(
    @csv.scan_string("region,amount\nnorth,100\nsouth,250\n", "events"),
  )
  let result = @moonlake.execute(
    "SELECT region, count(*) AS n, sum(amount) AS total FROM events GROUP BY region ORDER BY region",
    cat,
  )
  println("region|n|total")
  for r in 0..<result.row_count() {
    println(
      result.get(r, 0).to_string() +
      "|" +
      result.get(r, 1).to_string() +
      "|" +
      result.get(r, 2).to_string(),
    )
  }
}
