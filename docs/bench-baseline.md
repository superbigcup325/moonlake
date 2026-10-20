# Release performance baseline

> Recorded 2026-10-20 from `main` at `90f8f05` (0.3.0 plus the browser/JSON
> fixes), native release build, TPC-H SF0.1. The machine-readable record is
> [`harness/baseline/2026-10-20.json`](../harness/baseline/2026-10-20.json);
> this page is the same record in prose. Regenerate with
> `python3 harness/bench_release.py --json-out harness/baseline/<date>.json`.

A number without its machine, build mode, data and toolchain is not a
measurement, it is a rumour. This baseline pins all four, and hashes each
case's stdout so a later run can tell "same work, faster" from "different
work".

## The environment this record belongs to

| | |
|---|---|
| CPU | 12th Gen Intel Core i5-12500H (16 logical cores), governor `powersave` |
| RAM | 15.4 GB |
| Kernel / OS | 7.2.11-1-cachyos / Linux x86_64, glibc 2.44 |
| Toolchain | `moon 0.1.20261016` (moonc `v0.10.16`) |
| Build | `moon build cmd/main --target native --release` (binary SHA-256 in the JSON) |
| Data | `harness/data/sf01` (TPC-H SF0.1, eight CSVs + `lineitem.parquet`, tracked in the repository) |
| Method | 2 warm-ups, then fastest of 7 runs; wall and CPU (`user+sys`) from the child's own `wait4` rusage; peak RSS likewise; stdout drained and hashed, never stored |
| Load at measurement | 1 min average 2.7 on 16 cores (the host was busy; see the noise floor) |

## The record

| family | case | what | wall ms | median ms | cpu ms | peak RSS MB |
|---|---|---|---|---|---|---|
| scan | `scan/count_csv` | count(*) over lineitem.csv: schema only, no column decoded | 245.8 | 253.3 | 242.1 | 339.1 |
| scan | `scan/filtered_count_csv` | count(*) with a one-column predicate: decode + filter | 266.9 | 274.2 | 264.0 | 339.1 |
| scan | `scan/parquet_count` | count(*) over lineitem.parquet: footer only, no column chunk read | 11.7 | 12.6 | 11.4 | 24.9 |
| scan | `scan/parquet_sum` | sum(l_quantity) over lineitem.parquet: one column chunk per group | 20.2 | 21.0 | 19.8 | 39.0 |
| join | `join/two_table_count` | lineitem x orders hash join, count(*) only | 315.8 | 327.8 | 309.8 | 298.0 |
| join | `join/q3` | TPC-H Q3 official text over three CSV tables (build+probe+group+top-N) | 336.7 | 344.0 | 333.4 | 286.9 |
| gather | `gather/wide_projection` | filter then wide projection inside a derived table: the 16 materialized columns are assembled by per-column gathers, and only one output row is printed | 613.9 | 626.9 | 601.4 | 370.4 |
| gather | `gather/self_join_fanout` | self-join emitting 600k wide rows, counted: join-output assembly gathers 16 columns per output row | 559.0 | 576.0 | 545.9 | 338.6 |
| spill | `spill/order_by_wide` | two-column external sort over 600k rows under a 2 MB budget (must actually spill) | 532.2 | 545.5 | 526.8 | 339.0 |
| spill | `spill/format_write` | MLSPILL3 encode+write of every lineitem batch (release driver) | 1323.8 | - | - | 392.7 |
| spill | `spill/format_read` | MLSPILL3 read+decode of the same file (release driver) | 477.5 | - | - | 227.3 |

Every case's stdout SHA-256 is in the JSON. `spill/order_by_wide` additionally
records how many run files it wrote (7); the harness fails instead of recording
a number if the 2 MB budget stops forcing a spill, so the case cannot silently
become an in-memory sort.

## What each family is and is not

- **scan** is the lazy scan: registration reads footer/schema only, a `count(*)`
  decodes no columns, a filtered count decodes one, and a Parquet aggregate
  touches one column chunk per row group. The CSV cases are dominated by
  ingest (75 MB parsed per query — the engine is scan-to-query, not a loaded
  database), the Parquet cases are milliseconds. `count(*)` over Parquet peaks
  at 25 MB: 0.3.0 reads no payload at all for it.
- **join** is the columnar hash join, from a bare two-table count to full Q3.
  Both include CSV ingest, so treat them as "run this query" numbers rather
  than a join-kernel microbenchmark.
- **gather** is measured end to end because `gather` is package-private. The
  wide-projection case puts `SELECT *` inside a derived table so the engine
  materializes 16 columns through per-column gathers while printing one row;
  the self-join case makes join-output assembly gather 16 columns for each of
  600k output rows. A direct kernel benchmark would need an in-package bench
  harness; that is deliberately not part of the release record yet.
- **spill** covers both the in-query external sort (a real query under
  `--memory 2M`) and the MLSPILL3 file format (write/read through the dev
  driver `harness/spill_bench.py`). The format cases report the driver's own
  best-of, hence no median/CPU columns.

## Comparing against this record

```bash
python3 harness/bench_release.py --compare harness/baseline/2026-10-20.json
```

The comparison prints wall and CPU deltas per case and returns non-zero if a
case's output digest changed — a different result means the workload changed
and the timing comparison is not meaningful.

Read deltas against the measured noise floor, not against zero. Two runs of the
*identical* binary against this record moved wall time by −6.0% … +4.1% and CPU
time by −5.5% … +3.7% on the busy host above (largest: the two gather cases and
the spill driver's read). So: treat anything within ±7% as unchanged, and only
trust a 10%+ delta that reproduces across two runs. SF0.01 was rejected for
this record precisely because its 20–40 ms cases swung ±30% between runs on the
same host; at SF0.1 the same comparison lands inside ±6%.

Comparisons are only valid on the same machine, with the same governor, the
same data and the same build mode. A different CPU or a `performance` governor
turns every delta into a machine comparison.

## Why this exists

`docs/verification.md` records the A/B numbers each optimization was accepted
with (scan 130→94 ms, spill −19% file size, and so on), but those are
before/after snapshots taken against a specific previous binary. They answer
"did this change help then". This record answers "did the release we are about
to ship get slower than the last one", for the four loops that carry the
engine: scan, join, gather, spill.
