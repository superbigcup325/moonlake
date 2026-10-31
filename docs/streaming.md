# Streaming results

`@moonlake.stream` (or `stream_with` for `ExecOptions`) returns an
`@engine.ResultStream` whose `names()` and `types()` describe the columns and
whose `next()` yields one `@types.DataBatch` per call until it returns `None`.

Both deliveries run the same plan, so a streamed row and a collected row are the
same row.

```moonbit
///|
fn main raise {
  let cat = @catalog.Catalog::new()
  cat.register(@csv.scan_string("id,name\n1,ada\n2,grace\n", "people"))
  let stream = @moonlake.stream("SELECT id FROM people", cat)
  for name in stream.names() {
    println(name) // the column is "id"
  }
  while stream.next() is Some(batch) {
    for r in 0..<batch.row_count() {
      println(batch.columns()[0].get(r).to_string())
    }
  }
}
```

## The shapes that are pulled

Four shapes are pulled rather than collected — the ones whose input can be
consumed as it arrives:

- a single-table scan, where the WHERE, the projection and the OFFSET/LIMIT
  window run per batch, so a windowed query stops reading once it is full
- an aggregate, because the group table is a running hash table: its answer is
  one batch but its input never is (2,000,000 rows over 16 columns: 109.7 MB →
  35.3 MB of peak RSS). A `GROUP BY` under a budget is fed the same way: its
  batches are buffered up to `--memory` and partitioned only past it, so retained
  input stops growing with the rows (100 groups, 8,000,000 rows, 4M budget:
  195 MB → 63 MB) while the group state and the finished result stay unbounded.
  It is also fed a two-table keyed INNER/LEFT/FULL join's batches directly,
  without collecting the joined rows first (4,000,000 joined rows: 39 MB against
  191 MB, verification §49), and an `ORDER BY` above either shape is sorted after
  the fold, so the ordered shapes stay pulled too (TPC-H q1: 543 MB → 35 MB, q12:
  113 MB → 35 MB, verification §50), and it is still delivered as one finished
  batch
- an `ORDER BY` under a memory budget, which builds its sorted runs from the scan
  and hands out the merge a batch at a time (506.8 MB → 178.8 MB for
  `select * … order by id`, and it stops merging once a window is full)
- a two-table INNER/LEFT/FULL join, whose build side is read once and stays
  resident while the probe side arrives a batch at a time (a 2,000,000-row probe
  against a 1,000-row build: 270.8 MB → 35.3 MB, and under `--memory 8M` it
  stops spilling entirely, 1.99 s → 0.41 s)

## The shapes that are collected

Everything else is computed first and handed back as one batch, because its
answer does not exist until every row has been seen: a chain of joins, a RIGHT or
SEMI/ANTI join, a cross join, and DISTINCT or a window above a join.

An aggregate is the case the distinction is about: its answer is one finished
batch even when its input is pulled, with or without an `ORDER BY` above it.

## Lifecycle

`close()` stops the pull before the end, dropping the stream releases the scan
cursor, and a pull that raises ends the stream rather than leaving it resumable.

The spilled sort is the one stream that owns files — the runs are removed when
the merge ends, when `close` stops it, and when it raises — so exhaust it or
close it; a stream dropped unfinished leaves them to the store's owner (the CLI
deletes its per-query directory at exit). A join owns nothing of its own: closing
it only stops probing.
