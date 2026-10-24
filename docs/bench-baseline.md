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

Since 2026-10-21 every record also carries `method.data_sha256` (the dataset
itself, names included — a path is not an identity, and regenerating SF0.1 with
a different generator produces the same names and different numbers) and each
case's `sql`, so a timing can be traced back to a query rather than to a prose
description of one. The `spill/*` cases prove the spill differently now: the
engine removes its run files when the query ends, so the case asks `ANALYZE`
for `spill files:` before timing, and separately asserts that nothing is left
in the spill directory afterwards. Records taken before this change lack the
two fields; a reader comparing across the boundary should compare `id`s, not
whole objects.

## The environment this record belongs to

| | |
|---|---|
| CPU | 12th Gen Intel Core i5-12500H (16 logical cores), governor `powersave`, 1731 MHz at start |
| RAM | 15.4 GB |
| Kernel / OS | 7.2.11-1-cachyos / Linux x86_64, glibc 2.44 |
| Toolchain | `moon 0.1.20261016` (moonc `v0.10.16`) |
| Build | `moon build cmd/main --target native --release` (binary SHA-256 in the JSON) |
| Data | `harness/data/sf01` (TPC-H SF0.1, eight CSVs + `lineitem.parquet`, tracked in the repository) |
| Method | 2 warm-ups, then fastest of 7 runs; wall and CPU (`user+sys`) from the child's own `wait4` rusage; peak RSS likewise (see "the peak-RSS floor"); each case's run-to-run spread is recorded; stdout drained and hashed, never stored |
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

## The peak-RSS floor (2026-10-21)

`ru_maxrss` is the child's high-water mark, and a forked child starts with its
parent's resident pages mapped. Anything big in the harness process at fork
time is therefore a floor on every case it measures. The dataset hash added the
day before read all 75 MB of `lineitem.csv` before the cases ran, and the two
Parquet cases — whose own footprint is 25 and 39 MB — both reported **94.9 MB**.
A controlled check pinned it: 150 MB of ballast in the parent made an 11 ms
`count(*)` report 164 MB. The hash now runs *after* the measurements and the
parent is collected before they start, which returns the two cases to 25.1 and
39.1 MB with every other case unchanged. Records taken in between carry the
inflated floor for cases smaller than the parent, so compare RSS across the fix
with that in mind; wall and CPU time are unaffected.

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

It also refuses to print deltas when the two records were not taken under the
same conditions (CPU, core count, kernel, toolchain, dataset SHA-256, build
mode, runs and warm-ups): a difference there is the machine or the input, not
the code. `--allow-env-mismatch` prints them anyway for a reader who knows what
moved. Fields an older record predates are reported as "not compared" rather
than treated as a mismatch, so the committed 0.3.x records stay usable. Clock,
load average and governor are printed as *advisory* lines instead — they move
between sessions legitimately, and they are exactly what made the 0.3.0 → 0.3.1
pair look 10–25% faster on identical code.

Each case also records the spread of its own runs (`run spread`, in the record
and in the printed table), because that spread is the floor a comparison has to
clear: a delta inside it is labelled as such, and the run ends with how many
cases moved further than their own noise. Records taken before 2026-10-21 have
no spread, and the comparison says so instead of pretending the deltas are
significant.

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

## Parquet write cost (2026-10-21)

The writer used to have no choice to make: PLAIN, v1 pages, no compression.
With `--snappy` (and the annotations/statistics from the same change) it does,
so here is the trade-off measured on SF0.1 lineitem (600,572 rows × 16 columns,
native release, one machine, one session, best of 3 for the reads):

| | file size | write | write peak RSS | read (`sum(l_quantity)`) |
|---|---|---|---|---|
| `--out` (raw) | 75.2 MB | 1.03 s | 452 MB | 0.051 s |
| `--out --snappy` | 34.5 MB | 1.27 s | 367 MB | 0.034 s |

Both read back the same value (`15334802`). Three things worth reading off that
table:

- compression costs ~23% write time and halves the file;
- write peak RSS goes **down** with compression, because `write_bytes`
  accumulates the whole archive in one buffer — the compressed pages are simply
  smaller, so the buffer is too. The writer is not streaming; that is the
  dominant term in its memory use, not the pages;
- the read side is faster on the compressed file, and not only because it is
  smaller: the same pages decode through the same codec path, but there is less
  to read.

`count(*)` over the same files is footer-only (0.02–0.05 s) and measures
nothing, which is why the read column above aggregates a real column.

**Same measurement after the writer learned to stream (2026-10-21, later).**
The input is no longer materialized (one pass over a `BatchStream`, every column
written OPTIONAL — see `verification.md` §11), so the write column moves to:

| | file size | write | write peak RSS |
|---|---|---|---|
| `--out` (raw) | 75.2 MB | 0.84 s | 421 MB |
| `--out --snappy` | 34.5 MB | 1.03 s | 351 MB |

The 452 → 421 / 367 → 351 part of that is the table copy the writer used to
hold. The rest is not the writer: the CSV source reads the whole file into
`Bytes` and `count(*)` over the same file costs 341 MB before the writer appends
anything, and `write_bytes` still accumulates the archive because the fs API has
no incremental write. Writing from `lineitem.parquet` (84.8 MB, no CSV parse)
shows the split more cleanly: 407 → 328 MB raw and 286 → 203 MB with Snappy.

**After the archive copy went away (2026-10-23).** `write_file_with` streams on
native targets now (`verification.md` §19): the whole-archive buffer and the copy
handed to the file write are gone, and the output is published by renaming a
temporary file. Same table, same machine, one isolated child per run:

| input | before | after |
|---|---|---|
| `--csv` (SF0.1, 75 MB → 75 MB) | 427.7 MB / 1.02 s | 336.9 MB / 0.91 s |
| `--csv` ×2 (151 MB → 150 MB) | 799.3 MB / 1.97 s | 547.6 MB / 1.75 s |
| `--csv` ×4 (302 MB → 301 MB) | 1411.1 MB / 4.13 s | 1066.5 MB / 3.92 s |
| `--parquet` raw | 326.3 MB / 0.75 s | 100.8 MB / 0.70 s |
| `--parquet --snappy` | 199.4 MB / 0.86 s | 100.8 MB / 0.89 s |

Two conclusions the table supports and one it does not. Supported: the removed
term is exactly the archive (the delta tracks output size at 1×/2×/4×), and with a
Parquet input the writer's contribution is now flat — 101 MB whatever the codec
and output size. Not supported by these numbers: that a CSV input is likewise
flat. It is not — the scan itself grows with the file (4× still costs 1066 MB),
which is why CSV chunking is the next memory item rather than a writer one.

**After CSV reads became ranged (2026-10-24).** The scan no longer holds the
file or its per-cell index (`verification.md` §21), which was the term the
paragraph above left open. Same table, same machine, one isolated child per run:

| input | before | after |
|---|---|---|
| `--csv` (SF0.1, 75 MB → 75 MB) | 320.1 MB / 0.99 s | 35.0 MB / 0.83 s |
| `--csv` ×2 (151 MB → 150 MB) | 537.2 MB / 2.11 s | 33.7 MB / 1.70 s |
| `--csv` ×4 (302 MB → 301 MB) | 1062.7 MB / 3.95 s | 34.9 MB / 3.23 s |

The write column is now flat in the input format: 35 MB whether the source is a
CSV scan or a Parquet read, at 1× and at 4×. Reading a CSV moved the same way —
`count(*)` 327.8 → 34.2 MB and 1062.7 → 35.2 MB, `sum(l_quantity)` 326.2 → 39.1
MB and 1062.6 → 57.4 MB — and the archives are byte-identical to what the
previous build wrote (md5 `84a4dfd8…` 1×, `425bc3c1…` 2×, `043b084c…` 4×).

## Answers are checked before numbers are recorded (2026-10-23)

`--compare` has always refused to print deltas across different machines, data
or builds, and it flags a changed stdout hash. Neither can tell a stable wrong
answer from a right one: a query that returns the same incorrect rows every run
hashes just as consistently as a correct one. `bench_release.py` now also checks
each timed case's answer against DuckDB, outside the timed region, with views
over the same files (`read_csv_auto` / `read_parquet`) — the reference has its
own parser and its own plan. Q3's top-10 compares as a multiset because revenue
ties leave no total order; the golden chain already pins its exact order. A
mismatch aborts the run instead of writing a record (`--check-oracles` runs only
this check, `--no-oracle` opts out and says so in the record's conditions).

The check paid for itself immediately: it found that a spilled `ORDER BY` was
returning a wrong answer at budgets between 800 KB and 8 MB (see
`verification.md` §5.2). Every spill number recorded before that fix timed an
incorrect sort and must not be compared with later ones. The kernel and spill
format drivers now check their own answers too: `kernel_bench` verifies each
case against the table it built (count value, or an order-independent row bag
over the projected columns) and `spill_bench.py` recomputes the first column's
text checksum from the CSV, so the format's write/read checksum pair is not the
only evidence.

## 0.4.0 records, and what a same-session pair actually showed (2026-10-23)

Two records were taken on this machine in one session for the 0.4.0 release:

- [`harness/baseline/2026-10-23-0.4.0.json`](../harness/baseline/2026-10-23-0.4.0.json)
  — `529dd98`, the release candidate, with the answer oracle green.
- [`harness/baseline/2026-10-23-0.3.1-rerecord.json`](../harness/baseline/2026-10-23-0.3.1-rerecord.json)
  — the published 0.3.1, rebuilt from tag `v0.3.1` in a worktree (`fb2a10f`) in
  the same session, recorded with that tag's own script (it predates
  `data_sha256`, the run-spread field and the oracle, so `--compare` reports
  those as "not compared").

`--compare` between them refuses one comparison by design and shows one
legitimate cost:

- `spill/order_by_wide` reports **output changed — not comparable**, because
  0.3.1 returns the wrong top-3 (see `verification.md` §5.2). That is the
  correct answer from the tool: the two sides did different work.
- The scan, join and gather deltas in that pair (up to ~38%) did **not**
  survive a control. An interleaved A/B of the two binaries on this machine,
  five to seven alternated runs each, gives `count(*)` over the SF0.1 CSV at
  202.6 ms CPU (0.3.1) vs 213.7 ms CPU (0.4.0) best, ~5% — not 38%. The pair
  was recorded with different clock/load state (`CPU MHz at start` 3200 vs
  4194, load average 3.45 vs 2.94), which is exactly the cross-record noise the
  rest of this file warns about. Treat the pair's non-spill deltas as machine
  state, not code.

The one cost that is real is the sort fix itself. Alternating the two binaries
on the spilled case (`--memory 2M`, 600,572 rows, same session): 0.3.1 473 ms
CPU best / 485 ms median, 0.4.0 550 ms CPU best / 555 ms median — about 16%
more, because every run file is now sorted before it is written. That is the
price of a correct answer, and it is recorded here rather than hidden inside a
number that looks like a win.

`bench_release.py` also stopped treating the toolchain's install path as a
condition: `moon version` prints the path of the binary, which differs when a
record is taken through a scratch `MOON_HOME` (needed because the default home
is not writable here). The fingerprint now compares version and build hash.

## Parquet reads after range reads (2026-10-23)

The 0.4.0 numbers above include a reader that loaded each whole Parquet file.
`sort/order_by` and the scan cases therefore carried the archive in memory as a
fixed term; that term is gone (`verification.md` §20). This is an
interleaved A/B of two binaries on this machine, one isolated child per run, both
reading files written by the newer build so the bytes are identical:

| query (4× SF0.1 `lineitem`) | 0.4.0 reader | range reader |
|---|---|---|
| `count(*)`, 287 MB raw | 295 MB / 169 ms | 12 MB / 23 ms |
| `sum(l_quantity)`, 287 MB raw | 323 MB / 196 ms | 37 MB / 56 ms |
| `count(*)`, 574 MB raw | 585 MB / 450 ms | 12 MB / 44 ms |
| `sum(l_quantity)`, 574 MB raw | 630 MB / 531 ms | 67 MB / 115 ms |
| `sum(l_quantity)`, 132 MB Snappy | 169 MB / 145 ms | 37 MB / 79 ms |

The rule to carry forward: a Parquet case no longer scales its memory with the
input file, so any future regression in these cases is scan or operator memory,
not input size. The `parquet/*` cases in the records above were taken with the
old reader and are comparable on answers, not on peak memory.
