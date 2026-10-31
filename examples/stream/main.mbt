///|
/// The README's streaming snippet as a package: pull result batches instead of
/// collecting the whole result.

///|
fn main raise {
  let cat = @catalog.Catalog::new()
  cat.register(@csv.scan_string("id,name\n1,ada\n2,grace\n", "people"))
  let stream = @moonlake.stream("SELECT id FROM people", cat)
  for name in stream.names() {
    println(name)
  }
  while stream.next() is Some(batch) {
    for r in 0..<batch.row_count() {
      println(batch.columns()[0].get(r).to_string())
    }
  }
}
