# Release performance baseline

> Recorded 2026-10-20 for the 0.3.1 release (native release build, TPC-H SF0.1,
> measured at `3d766de`). The machine-readable record is
> [`harness/baseline/2026-10-20-0.3.1.json`](../harness/baseline/2026-10-20-0.3.1.json);
> the earlier 0.3.0-era record is
> [`harness/baseline/2026-10-20-0.3.0.json`](../harness/baseline/2026-10-20-0.3.0.json)
> and is kept because the difference between the two is a lesson. Regenerate
> with `python3 harness/bench_release.py --json-out harness/baseline/<date>-<version>.json`.

A number without its machine, build mode, data and toolchain is not a
measurement, it is a rumour. This baseline pins all four, and hashes each
case's stdout so a later run can tell "same work, faster" from "different
work".

## The environment this record belongs to

| | |
|---|---|
| CPU | 12th Gen Intel Core i5-12500H (16 logical cores), governor `powersave`, 1731 MHz at start |
| RAM | 15.4 GB |
| Kernel / OS | 7.2.11-1-cachyos / Linux x86_64, glibc 2.44 |
| Toolchain | `moon 0.1.20261016` (moonc `v0.10.16`) |
| Build | `moon build cmd/main --target native --release` (binary SHA-256 in the JSON) |
| Data | `harness/data/sf01` (TPC-H SF0.1, eight CSVs + `lineitem.parquet`, tracked in the repository) |
| Method | 2 warm-ups, then fastest of 7 runs; wall and CPU (`user+sys`) from the child's own `wait4` rusage; peak RSS likewise; stdout drained and hashed, never stored |
| Load at measurement | 1 min average 1.9 on 16 cores |

## The record (0.3.1)

| family | case | what | wall ms | median ms | cpu ms | peak RSS MB |
|---|---|---|---|---|---|---|
| scan | `scan/count_csv` | count(*) over lineitem.csv: schema only, no column decoded | 204.6 | 207.1 | 202.5 | 340.9 |
| scan | `scan/filtered_count_csv` | count(*) with a one-column predicate: decode + filter | 211.0 | 212.9 | 209.8 | 345.1 |
| scan | `scan/parquet_count` | count(*) over lineitem.parquet: footer only, no column chunk read | 10.9 | 12.0 | 10.6 | 24.9 |
| scan | `scan/parquet_sum` | sum(l_quantity) over lineitem.parquet: one column chunk per group | 18.5 | 22.8 | 18.1 | 39.1 |
| join | `join/two_table_count` | lineitem x orders hash join, count(*) only | 263.0 | 275.6 | 261.4 | 344.9 |
| join | `join/q3` | TPC-H Q3 official text over three CSV tables (build+probe+group+top-N) | 286.8 | 296.6 | 285.2 | 290.9 |
| gather | `gather/wide_projection` | filter then wide projection inside a derived table: the 16 materialized columns are assembled by per-column gathers, and only one output row is printed | 488.8 | 493.3 | 485.4 | 372.7 |
| gather | `gather/self_join_fanout` | self-join emitting 600k wide rows, counted: join-output assembly gathers 16 columns per output row | 418.4 | 428.8 | 416.0 | 386.9 |
| spill | `spill/order_by_wide` | two-column external sort over 600k rows under a 2 MB budget (must actually spill) | 469.5 | 476.2 | 467.8 | 344.9 |
| spill | `spill/format_write` | MLSPILL3 encode+write of every lineitem batch (release driver) | 1191.7 | - | - | 404.3 |
| spill | `spill/format_read` | MLSPILL3 read+decode of the same file (release driver) | 429.4 | - | - | 230.4 |

Every case's stdout SHA-256 is in the JSON. `spill/order_by_wide` additionally
records how many run files it wrote (7); the harness fails instead of recording
a number if the 2 MB budget stops forcing a spill, so the case cannot silently
become an in-memory sort.

## 0.3.0 → 0.3.1: the same code, measured twice

0.3.1 changes no engine code relative to the 0.3.0 record — it is the same
tree plus fixes that never touch these queries — and yet:

| case | 0.3.0 record | 0.3.1 record | delta |
|---|---|---|---|
| `scan/count_csv` | 245.8 | 204.6 | −16.8% |
| `scan/filtered_count_csv` | 266.9 | 211.0 | −20.9% |
| `scan/parquet_count` | 11.7 | 10.9 | −6.8% |
| `scan/parquet_sum` | 20.2 | 18.5 | −8.4% |
| `join/two_table_count` | 315.8 | 263.0 | −16.7% |
| `join/q3` | 336.7 | 286.8 | −14.8% |
| `gather/wide_projection` | 613.9 | 488.8 | −20.4% |
| `gather/self_join_fanout` | 559.0 | 418.4 | −25.2% |
| `spill/order_by_wide` | 532.2 | 469.5 | −11.8% |
| `spill/format_write` | 1323.8 | 1191.7 | −10.0% |
| `spill/format_read` | 477.5 | 429.4 | −10.1% |

The 0.3.0 record was taken at load average 2.7 with the CPU around 1.5 GHz;
the 0.3.1 record at load average 1.9 and 1.7 GHz. Every number moving 10–25%
in the same direction without a code change is machine state, not an
optimization. That is why the record carries the frequency and the load
average, and why the rule below is about sessions, not seconds.

Practical consequence: compare a new release against a record taken **in the
same session**, or re-record the previous release side by side
(`--compare` only needs the JSON, not the old binary, but the machine has to
cooperate). Cross-session deltas under ~25% on this laptop are not evidence of
anything.

## What each family is and is not

- **scan** is the lazy scan: registration reads footer/schema only, a `count(*)`
  decodes no columns, a filtered count decodes one, and a Parquet aggregate
  touches one column chunk per row group. The CSV cases are dominated by
  ingest (75 MB parsed per query — the engine is scan-to-query, not a loaded
  database), the Parquet cases are milliseconds. `count(*)` over Parquet peaks
  at 25 MB: no payload is read for it at all.
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

## Comparing against a record

```bash
python3 harness/bench_release.py --compare harness/baseline/2026-10-20-0.3.1.json
```

The comparison prints wall and CPU deltas per case and returns non-zero if a
case's output digest changed — a different result means the workload changed
and the timing comparison is not meaningful.

Within one session the same binary against itself moved wall time by −6.0% …
+4.1% and CPU time by −5.5% … +3.7% (largest: the gather cases and the spill
driver's read). Treat ±7% as unchanged there, and only trust a 10%+ delta that
reproduces across two runs. SF0.01 was rejected for this record because its
20–40 ms cases swing ±30% between runs even inside a session.

## Why this exists

`docs/verification.md` records the A/B numbers each optimization was accepted
with (scan 130→94 ms, spill −19% file size, and so on), but those are
before/after snapshots taken against a specific previous binary. They answer
"did this change help then". This record answers "did the release we are about
to ship get slower than the last one", for the four loops that carry the
engine: scan, join, gather, spill.

## Kernel-level record (2026-10-21)

The record above is end to end, so every join case in it includes CSV ingest
(75 MB parsed before the join runs) and every gather case includes a scan. That
answers "how long does this query take", not "what does the operator cost".
`harness/kernel_bench` fills the gap: tables are materialized in memory and
split into 4096-row batches exactly like a scan produces, the clock starts
after the tables exist, and the cases are chosen so that a difference between
two of them isolates one structural cost.

```bash
moon run --target native --release harness/kernel_bench            # 100k rows, best of 7
moon run --target native --release harness/kernel_bench -- --rows 200000 --runs 9
```

Same machine and session as the release record above (i5-12500H, `powersave`,
native release, 100k rows per table):

| case | before | after | what it measures |
|---|---|---|---|
| `scan/count` | 0.41 ms | 0.42 ms | the floor: execute the pipeline, touch nothing |
| `join/int_key` | 12.75 ms | 13.7 ms | one int32 equality key → the `Map[Int64, …]` fast path |
| `join/two_key` | **69.3 ms** | **14.0 ms** | two int32 equality keys |
| `join/str_key` | 64.3 ms | 75.1 ms | one string key → string hashing |
| `gather/narrow` | 0.45 ms | 0.45 ms | one column out of eight |
| `gather/wide` | 2.42 ms | 2.8 ms | eight columns out of eight |
| `gather/nullable` | 2.16 ms | 2.0 ms | eight nullable columns (half the rows absent) |

"Noise, not a regression": `int_key`, `str_key` and `gather/wide` did not change
code between the two columns — they moved +7%, +17% and +17% because the
machine drifted between runs, which is the same lesson as §"0.3.0 → 0.3.1"
below. The one number that moved against that backdrop is `join/two_key`,
4.9× in the same session while its single-key control stayed put.

**What changed.** Two int32-width join keys were taking the general path, which
builds a canonical string per row on both sides. They are now packed into one
exact Int64 hash key, `(a << 32) | (b & 0xFFFFFFFF)` — injective, so no
collision handling is needed, and a NULL in either component still never
matches. That is the TPC-H shape of partsupp joined on (partkey, suppkey) in
Q9, and of Q2/Q7/Q8's multi-key joins. The general path remains for strings,
Int64 pairs and three-plus columns, where an Int64 cannot hold the key exactly.

**What this did not justify.** The audit's third candidate was bit-packing the
validity channel (`FixedArray[Bool]`, one byte per row). `gather/nullable` is
not slower than `gather/wide` at this shape, so there is no measured cost to
recover — the channel is not the bottleneck for gather, and the optimization
stays on the shelf until a case shows it. Same for dropping the whole-side
`concat_batches` copy in `join_step`: the int-key control is 13.7 ms, of which
the copy is a small part, and the change would touch every join path; the
measurement does not yet ask for it.

**Limits.** In-process wall clock, one machine, one session; the numbers are
comparable to each other and to a re-run on the same machine, not to a
different host. `harness/kernel_bench` is dev-only tooling (not part of the
published package) and takes `--rows` / `--runs`.
