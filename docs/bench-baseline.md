# Release performance baseline

> One record per release, native release build, TPC-H SF0.1, same script and
> same machine. The newest is
> [`harness/baseline/2026-10-26-0.5.1.json`](../harness/baseline/2026-10-26-0.5.1.json),
> taken beside a 0.5.0 re-record so the two can be compared (the last section).
> The first was 0.3.1 at `3d766de`
> ([`2026-10-20-0.3.1.json`](../harness/baseline/2026-10-20-0.3.1.json)); the
> earlier 0.3.0-era record
> ([`2026-10-20-0.3.0.json`](../harness/baseline/2026-10-20-0.3.0.json)) is kept
> because the difference between the two is a lesson. Regenerate with
> `python3 harness/bench_release.py --json-out harness/baseline/<date>-<version>.json`.

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
not input size. The `parquet/*` cases in the 0.4.0 records above were taken with the
old reader and are comparable on answers, not on peak memory; the 0.5.0 record
below starts from the range reader.

## 0.5.0 record, and a same-session pair against 0.4.0 (2026-10-24)

Two records were taken on this machine in one session for the 0.5.0 release:

- [`harness/baseline/2026-10-24-0.5.0.json`](../harness/baseline/2026-10-24-0.5.0.json)
  — `b40ab50`, the released 0.5.0, with the answer oracle green.
- [`harness/baseline/2026-10-24-0.4.0-rerecord.json`](../harness/baseline/2026-10-24-0.4.0-rerecord.json)
  — the published 0.4.0, rebuilt from tag `v0.4.0` in a worktree in the same
  session and recorded with this tree's script, so the pair is on one kernel,
  one toolchain and one dataset. The 0.4.0 record committed yesterday cannot be
  compared here: the kernel moved from `7.2.11-1-cachyos` to
  `7.3.0-4-cachyos` and `--compare` refuses that by design.

The pair is worth reading because 0.5.0 changed how inputs are read, and the
change shows up as both wall time and peak memory:

| case | wall 0.4.0 | wall 0.5.0 | delta | peak RSS 0.4.0 -> 0.5.0 |
|---|---|---|---|---|
| scan/count_csv | 199.0 ms | 155.8 ms | −21.7% | 345.1 -> 35.3 MB |
| scan/filtered_count_csv | 220.1 ms | 174.5 ms | −20.7% | 345.1 -> 35.2 MB |
| scan/parquet_count | 10.9 ms | 3.8 ms | −65.1% | 25.1 -> 21.6 MB |
| scan/parquet_sum | 18.5 ms | 12.1 ms | −34.6% | 39.1 -> 21.6 MB |
| join/two_table_count | 274.2 ms | 223.2 ms | −18.6% | 305.3 -> 51.1 MB |
| join/q3 | 299.1 ms | 252.1 ms | −15.7% | 307.5 -> 43.2 MB |
| gather/wide_projection | 490.9 ms | 457.4 ms | −6.8% | 373.0 -> 310.9 MB |
| gather/self_join_fanout | 433.0 ms | 361.9 ms | −16.4% | 389.0 -> 53.0 MB |
| spill/order_by_wide | 539.7 ms | 496.4 ms | −8.0% | 345.0 -> 45.3 MB |
| spill/format_write | 1234.1 ms | 1182.7 ms | −4.2% | 401.2 -> 344.5 MB |
| spill/format_read | 453.7 ms | 446.5 ms | −1.6% | 230.3 -> 230.3 MB |

Eight cases moved further than their own run-to-run spread; the rest are inside
it, and `scan/parquet_sum`'s new record repeats the wide spread the old one
showed (61.7% across its seven runs), so treat that delta as noise rather than
as a 35% win. `gather/wide_projection` is the one case whose memory barely
moves, because its peak is the materialized wide result rather than an input
file.

The memory column is the direct consequence of §20 and §21 of
`verification.md`: a CSV scan no longer materializes the file, so the cases
that read the 302 MB SF0.1 CSV lose a ~310 MB term, and the cases that read
only Parquet lose a smaller one. Wall time follows where the case was copying
that term. Nothing here is a new optimization: the run was recorded to answer
"did 0.5.0 get slower than 0.4.0", and it did not.

Reproducibility check: the 0.5.0 side was measured twice, once before the 0.4.0
worktree run and once immediately after it. `scan/count_csv` came out at 155.3
and 155.8 ms wall with 35.2 and 35.3 MB peak RSS; the committed record is the
second, so the numbers a future comparison reads are the ones taken next to
their 0.4.0 counterpart.

## 0.5.1 record, beside a same-session 0.5.0 re-record (2026-10-26)

The pair for this release, recorded minutes apart:

- [`harness/baseline/2026-10-26-0.5.1.json`](../harness/baseline/2026-10-26-0.5.1.json)
  — `3ab2634`, the release candidate, answer oracle green on all eleven cases.
- [`harness/baseline/2026-10-26-0.5.0-rerecord.json`](../harness/baseline/2026-10-26-0.5.0-rerecord.json)
  — the published 0.5.0, rebuilt from tag `v0.5.0` in a worktree (`2da10d1`) and
  recorded with that tag's own script, so `--compare` has nothing to declare
  missing and no case differs in `sql` or in its stdout hash.

0.5.1 changes how a result is delivered, not what a case computes. Every case's
`sql` and output hash are identical on both sides, so the comparison is timings
and memory for the same work.

The two files disagree about the clock, which is why the table below is the
`--compare` run rather than a subtraction of two JSON files: 0.5.0 was recorded
at 4373 MHz and 0.5.1 at 3406 MHz, so the record-to-record wall deltas are
mostly the machine waking up. `--compare` re-measured 0.5.1 at 4199 MHz in the
same session as the 0.5.0 re-record; its numbers are what follows, and the
peak-RSS column is clock-independent either way.

| case | wall 0.5.0 | wall 0.5.1 | delta | peak RSS 0.5.0 -> 0.5.1 |
|---|---|---|---|---|
| `scan/count_csv` | 150.9 ms | 161.2 ms | +6.8% | 35.1 -> 35.1 MB |
| `scan/filtered_count_csv` | 164.6 | 179.7 | +9.2% | 35.2 -> 35.2 MB |
| `scan/parquet_count` | 4.5 | 4.0 | −11.1% | 21.6 -> 21.2 MB |
| `scan/parquet_sum` | 11.3 | 11.0 | −2.7% | 21.6 -> 21.2 MB |
| `join/two_table_count` | 214.6 | 221.5 | +3.2% | 51.0 -> 35.1 MB |
| `join/q3` | 248.6 | 261.5 | +5.2% | 49.2 -> 45.3 MB |
| `gather/wide_projection` | 452.9 | 446.6 | −1.4% | 310.9 -> 237.2 MB |
| `gather/self_join_fanout` | 370.6 | 346.9 | −6.4% | 53.1 -> 41.3 MB |
| `spill/order_by_wide` | 498.6 | 487.2 | −2.3% | 45.4 -> 35.3 MB |
| `spill/format_write` | 1230.5 | 1186.6 | −3.6% | 318.8 -> 318.9 MB |
| `spill/format_read` | 461.0 | 437.4 | −5.1% | 228.6 -> 230.3 MB |

The loud part is the memory column, and it is the point of the release: a result
is now handed out a batch at a time (verification §§31–34), so the cases whose
peak was the collected answer fall — the two-table join 51.0 -> 35.1 MB, Q3
49.2 -> 45.3, the 16-column wide projection 310.9 -> 237.2, the 600k-row
self-join fanout 53.1 -> 41.3, and the external sort 45.4 -> 35.3 (its merge
already streamed; its input no longer accumulates). The two `spill/format_*`
cases drive the MLSPILL3 format directly rather than a query, and are here for
completeness.

One case moved beyond its own spread, and it is a cost, not a win:
`scan/filtered_count_csv`. A filtered count whose answer is one row still pays
the new delivery boundary, because the scan assembles a freshly allocated
4,096-row `DataBatch` per pull (`catalog.SCAN_BATCH_ROWS`) and the filter covers
that batch whole, where a pooled materialize did the same work in one pass. An
interleaved A/B of the two binaries on this machine (two warm-ups, then seven
alternated runs each, `SELECT count(*) FROM lineitem WHERE l_quantity < 24` over
SF0.1) puts it at 176.0 -> 183.3 ms CPU best-of and 194.5 -> 202.6 ms median,
+4.1%; the unfiltered `SELECT count(*)` over the same file A/Bs at +0.1%
(153.6 -> 153.9 ms). So the cost is the per-batch filter pass, not the scan,
and the next section of work would be the one that lets a filter run across
batch boundaries. Recorded here instead of averaged away, exactly as the 0.4.0
section records what streamed merges cost.

## 0.5.1 final record, beside the candidate it refines (2026-10-26)

The final candidate adds the colenc 0.1.1 upgrade and the two approximate
aggregates to the revision above, so it needed its own record:

- [`harness/baseline/2026-10-26-0.5.1-final.json`](../harness/baseline/2026-10-26-0.5.1-final.json)
  — `bc1a8f5`, the revision R2 accepted, oracle green on all eleven cases.
- [`harness/baseline/2026-10-26-0.5.1-3ab2634-rerecord.json`](../harness/baseline/2026-10-26-0.5.1-3ab2634-rerecord.json)
  — `3ab2634`, the candidate accepted in §36, recorded minutes earlier in the
  same session with the same script. Both records were taken at 4200 MHz, and
  no case differs in `sql` or in its stdout hash.

| case | wall 3ab2634 | wall final | delta | peak RSS 3ab2634 -> final |
|---|---|---|---|---|
| `scan/count_csv` | 152.1 ms | 180.7 ms | +18.8% | 35.0 -> 35.3 MB |
| `scan/filtered_count_csv` | 168.8 | 198.2 | +17.4% | 33.3 -> 35.2 MB |
| `scan/parquet_count` | 4.0 | 3.7 | −7.5% | 21.2 -> 20.9 MB |
| `scan/parquet_sum` | 11.2 | 10.9 | −2.7% | 21.2 -> 20.9 MB |
| `join/two_table_count` | 238.0 | 248.0 | +4.2% | 34.5 -> 35.3 MB |
| `join/q3` | 277.3 | 278.5 | +0.4% | 45.3 -> 45.2 MB |
| `gather/wide_projection` | 425.2 | 444.6 | +4.6% | 233.9 -> 237.3 MB |
| `gather/self_join_fanout` | 334.5 | 445.4 | +33.2% | 41.3 -> 41.2 MB |
| `spill/order_by_wide` | 482.7 | 514.1 | +6.5% | 35.4 -> 35.5 MB |
| `spill/format_write` | 1184.3 | 1189.9 | +0.5% | 320.0 -> 320.9 MB |
| `spill/format_read` | 446.0 | 439.0 | −1.6% | 230.4 -> 230.3 MB |

Memory is flat everywhere (within 2.3 MB), so nothing regressed in RSS. Time is
another matter: the two CSV scans and the fanout join moved more than their own
run spread, and the investigation found a cause that is not in this tree.

**The bisect.** `ae6a28c`, whose source differs from `3ab2634` only by the
Parquet reader fix, measures +0.3% on `SELECT count(*)` over SF0.1 lineitem.
`24d983b` changes only `moon.mod` (colenc 0.1.0 -> 0.1.1) and measures 9.4%
slower for the same query against the same control, in the same session. So the
cost comes in with the dependency artifact, not with the code that uses it.

**The probes.** A local copy of colenc 0.1.1 with `encoders/roaring.mbt` deleted
and the facade's two `Roaring` arms turned into refusals — nothing else changed —
built through a `moon.work` workspace: `scan/count_csv` comes back at the
control's speed and the fanout join within ±1.5% of it. The decisive variant
keeps `roaring.mbt` where it is and only refuses the two facade arms: the binary
is the same 1,632,744 bytes as the deletion probe, 8,248 fewer than the shipped
one, and measures 159.1 ms median against the control's 159.1 while the shipped
candidate sits 10.8% above it. So the cost is reachability, not the file's
package: nothing in the CSV path calls the bitmap, but the generic
`encode_column` / `decode_column` dispatch that the spill format calls does, so
dead-code elimination cannot drop the 1,137 lines and what remains moves the hot
loops. Rotating interleaved A/B (10–12 pairs per side, so neither binary always
runs first, the machine at 0.4–2.5 load; the harness's own bias, measured by
A/B-ing one binary against itself, is 1.5%), taken twice on different days:

| query | 3ab2634 | `bc1a8f5` | delta |
|---|---|---|---|
| `SELECT count(*)` over SF0.1 lineitem, first | 159.1 ms median, 148.8 best | 179.0 ms median, 173.7 best | +12.5% median, +16.7% best |
| the fanout join, first | 351.7 ms median, 332.4 best | 397.9 ms median, 374.3 best | +13.1% median, +12.6% best |
| `SELECT count(*)`, second | 163.4 ms median, 156.5 best | 179.0 ms median, 176.5 best | +9.5% median, +12.8% best |
| the fanout join, second | 372.8 ms median, 363.4 best | 400.9 ms median, 389.0 best | +7.5% median, +7.0% best |

So the honest figure is a range, not a digit: the scan costs about 10% and the
join 7–8%, with single sessions as high as 14%. The recorded pair above reports
+18.8% and +33.2% because the pair is taken case by case rather than interleaved;
the rotating A/B, which alternates and rotates the order, is the number to
quote. The conclusion does not depend on which of these one picks.

Two further checks bound what it is not: the expression-only `SELECT 1 + 1` is
1.0 ms on both binaries (no startup cost), and the Parquet cases are unchanged
(the layout that moved is in the CSV scan's path). `orders.csv`, a narrower and
smaller CSV, shows no regression, so the cost lands on wide-row CSV scans.

**What that means for publishing.** The upgrade is what makes the two new
aggregates possible, and this tree's own code has no part in the cost. The fix
belongs upstream, and the second probe says what it has to be: a package move
alone would not help, because the generic dispatch still reaches the bitmap.
Taking the `Roaring` arms out of `encode_column` and `decode_column` and into
dedicated functions — so a caller that only ever passes PLAIN, DELTA, the
length-family or dictionary never links a bitmap — removes the cost without
touching this tree, at the price of a small semantic change for Roaring callers.
That change exists now on colenc's unreleased `main` and was measured the same
way: this tree built against it is 1,632,744 bytes, 8,248 fewer, and measures
157.9 ms against the control's 163.0 for the scan and parity on the join, ten
interleaved pairs a side. So the cost is removable rather than intrinsic. Until a
colenc release carries it and this pair is recorded again, 0.5.1 ships about 10%
slower wide-CSV scans (7–14% by run) than the candidate in §36, and that stays a
decision for the release owner rather than something to average away. Recorded
here, with the bisect and all three probes, because the next reader should not
have to rediscover it.

## colenc 0.1.2 removes the cost, on a quiet host (2026-10-26)

The cost the section above had to accept belonged to the colenc 0.1.1 artifact,
not to this tree, and colenc 0.1.2 ships the specified fix: the `Roaring` arms
left the generic `encode_column` / `decode_column` dispatch for
`encode_roaring_column` / `decode_roaring_column`. This is the re-record that
was owed, and the cost is gone.

- [`harness/baseline/2026-10-26-colenc-0.1.2.json`](../harness/baseline/2026-10-26-colenc-0.1.2.json)
  — this tree at `95c42c6`, which moves the dependency to the published
  `superbigcup325/colenc@0.1.2`. No source change was needed.
- [`harness/baseline/2026-10-26-colenc-0.1.1-control.json`](../harness/baseline/2026-10-26-colenc-0.1.1-control.json)
  — `bc1a8f5`, the revision §40 accepted, consuming 0.1.1. Built and measured
  in a scratch worktree outside the module, so its `spill_bench` driver and CLI
  are its own and not the candidate's.

Both committed records are the first of the three pairs; the table below reports
the median of all three, because the two runs in a pair differ by a few percent
even on a quiet host. Order was candidate, control, three times, so neither
binary always ran first. Each `bench_release.py` run is the fastest of seven
after two warm-ups, all eleven cases passed their DuckDB oracle, and the output
SHA-256 of every case is identical across all six records, so the two sides did
the same work.

Load average at the six starts was 0.91, 1.20, 1.69, 1.57, 1.57 and 1.71, and
the governor is `powersave`, which shows in the recorded clock: the six values
of `cpu_mhz_at_start` were 3889, 4362, 4063, 3355, 442 and 3595. That is why the
per-round delta is listed beside the median — a pair whose sides landed on
different clocks moves, but the sign does not.

| case | 0.1.1 control | 0.1.2 | delta | per-round delta |
|---|---|---|---|---|
| `scan/count_csv` | 171.3 ms | 153.0 ms | **−10.7%** | −12.3 / −7.6 / −11.0 |
| `scan/filtered_count_csv` | 188.5 | 170.0 | **−9.8%** | −9.8 / −9.7 / −9.8 |
| `scan/parquet_count` | 3.9 | 4.6 | +17.9% | +17.9 / +45.7 / +12.8 |
| `scan/parquet_sum` | 10.8 | 11.4 | +5.6% | +5.6 / +2.8 / +5.4 |
| `join/two_table_count` | 235.4 | 214.8 | **−8.8%** | −9.5 / −8.2 / −9.4 |
| `join/q3` | 266.7 | 249.6 | **−6.4%** | −7.6 / −6.4 / −5.7 |
| `gather/wide_projection` | 430.2 | 411.9 | −4.3% | −3.6 / −3.8 / −4.7 |
| `gather/self_join_fanout` | 383.2 | 348.4 | **−9.1%** | −9.0 / −8.7 / −10.1 |
| `spill/order_by_wide` | 492.3 | 478.7 | −2.8% | −3.6 / −3.1 / −2.1 |
| `spill/format_write` | 1136.4 | 1147.0 | +0.9% | +1.4 / −0.2 / +0.9 |
| `spill/format_read` | 427.5 | 420.2 | −1.7% | −1.7 / −0.9 / −4.2 |

**What this settles.** The wide CSV scan and the queries built on it moved back
to the control's speed and past it: −10.7% on `count(*)`, −9.8% on the filtered
count, −8.8% on the two-table join, −6.4% on Q3 and −9.1% on the fanout join,
positive in every one of the three rounds. §40 measured 0.1.1 at 9.5–13% above
the pre-upgrade control for the same queries, so the two measurements bracket the
same cost from opposite sides. The candidate's 153.0 ms is also below the
159.1 ms the pre-upgrade control measured in the earlier session — across
sessions, so indicative rather than a claim: it says the scan did not merely
return to where it was, and a same-session pair against `3ab2634` would be
needed to assert that.

**What this does not settle.** The two Parquet cases stay unresolved, and the
table says so rather than picking a side. They are 4 ms and 11 ms cases whose
round-to-round spread inside a single record reached 73% and 69%; a 0.6 ms
difference is under what this rig resolves, and the earlier session's pair
disagreed on the sign for `parquet_count` (−2.5% then, +17.9% here). Nothing on
the Parquet read path changed between the two artifacts, and `parquet_sum` is
identical to the digit on three of its six runs. Treat both as unchanged. The
spill-format pair is flat within ±1.4%, and `gather/wide_projection` (−4.3%,
consistent in all three rounds) is the one small win worth noting beside them.

**Memory.** Peak RSS is flat: every case is within 1.7 MB between the two
records, and the sizes that differ most are the two that also have the widest
run spread.

## colenc 0.1.3 hands the sparse state to the release candidate (2026-10-26)

The dependency moves one patch version and one thing changes: the HLL sketch
keeps a sparse state until a group outgrows it. None of the eleven release cases
runs an approximate aggregate, so the pair here answers a narrower question than
§41's did — whether a new artifact disturbs the cases the release is judged on. It
should not, and the record says it does not.

- [`harness/baseline/2026-10-26-colenc-0.1.3.json`](../harness/baseline/2026-10-26-colenc-0.1.3.json)
  — `344d739`, which moves `moon.mod` to the published
  `superbigcup325/colenc@0.1.3`. Recorded at 23:25, load average 3.2.
- [`harness/baseline/2026-10-26-colenc-0.1.2-control.json`](../harness/baseline/2026-10-26-colenc-0.1.2-control.json)
  — a detached worktree at the same commit with `moon.mod` put back on 0.1.2, so
  the two records differ in the dependency and nothing else. It builds its own CLI
  and its own `spill_bench` driver, and its header says `git_dirty: true` because
  that pin is the uncommitted change. Recorded at 23:28, load average 3.8; a first
  control at load 6.1 (not kept) agreed within noise.

One round each, because the expectation is a wash and a wash is what a single
round can establish:

| case | 0.1.2 control | 0.1.3 | delta |
|---|---|---|---|
| `scan/count_csv` | 164.6 ms | 159.6 ms | −3.0% |
| `scan/filtered_count_csv` | 183.8 | 177.7 | −3.3 |
| `join/two_table_count` | 240.9 | 229.9 | −4.6 |
| `join/q3` | 269.6 | 262.3 | −2.7 |
| `gather/wide_projection` | 445.9 | 431.1 | −3.3 |
| `gather/self_join_fanout` | 384.9 | 368.3 | −4.3 |
| `spill/order_by_wide` | 505.1 | 495.8 | −1.8 |
| `spill/format_write` | 1206.4 | 1244.7 | +3.2 |
| `spill/format_read` | 437.1 | 435.2 | −0.4 |
| `scan/parquet_count` | 3.8 | 4.7 | +23.7 |
| `scan/parquet_sum` | 11.4 | 11.2 | −1.8 |

`bench_release.py --compare` prints the verdict: `0 case(s) moved further than
their own run-to-run spread`. The negative column is not a win to claim — the
control ran at the higher load average of the two, and every case's delta sits
inside the spread its own seven runs already showed. The two Parquet cases are the
4 ms and 11 ms pair §41 also left unresolved, with 59% and 57% spreads here. Peak
RSS is flat within 4 MB (`join/q3` 49.2 → 45.3, `scan/filtered_count_csv` 33.2 →
35.2, everything else within 1 MB).

The memory this release changes is not in this table: it is in the grouped sketch
rows that `harness/bench_hll.py` measures, and §44 carries them.

## A join feeding an aggregate, before composing it (2026-10-27)

There is no change to compare here: the question is what the current shape costs,
so the candidate and the control are the same source and the pair measures the
harness as much as the engine. What the record establishes is that the rows a
join hands to an aggregate are collected whole, that their cost follows the
joined rows rather than the probe rows or the group count, and that a
`--memory` budget on that query raises the peak instead of bounding it.

- [`harness/baseline/2026-10-27-e6a-join-agg.json`](../harness/baseline/2026-10-27-e6a-join-agg.json)
  — `57004ea`, quiet gate 1.5, entered at load 1.41, peak load 3.10 during the
  run. Candidate `7e5815af…` from this tree and control `4d73a05f…` from a
  detached worktree at `v0.5.1` (`f8e1204`); the two differ in documentation and
  harness only.
- The fixtures are `probe(id, k, v)` with `k = i % 100` and `v = (13 * i) % 1000`,
  and `build(k, w)` with `fanout` rows per key; 1, 2 and 4 million probe rows at
  fanout 1, and 1 million probe rows at fanout 2 and 4. Build side, group count
  (100) and final result (100 rows) stay fixed. Three interleaved rounds, three
  budgets, five queries.

Peak RSS in MB, candidate; every grouped answer equals the control's and
DuckDB's:

| joined rows | no budget | 4M | 16M |
|---|---|---|---|
| 1,000,000 | 51 | 54 | 51 |
| 2,000,000 | 97 | 118 | 99 |
| 4,000,000 | 189 | 204 | 192 |
| 2,000,000 (fanout 2, 1M probe rows) | 85 | 92 | 99 |
| 4,000,000 (fanout 4, 1M probe rows) | 154 | 164 | 191 |

The three controls are flat: at no budget the scan is 35 MB, the aggregate alone
35 MB and the collected join on its own 39 MB at every point, because that query
prints its rows instead of holding them. The delta over the scan is 16.7, 32.5
and 40.4 bytes per joined row at 1, 2 and 4 million rows — not one coefficient,
and the two routes to 4,000,000 joined rows differ by 35 MB, which was not
isolated. What a budget does: at 4,000,000 joined rows the 4M setting peaks
19 MB above no budget and takes 1.35 s against 0.36 s, writing 11.1 MB in 115
files; the 16M setting peaks at 192 MB and takes 1.36 s.

Wall times are direction only: the host was shared, the quiet gate was 1.5
rather than §45's 0.9, the peak load during the run was 3.10, and the worst
round-to-round spread was 32% on the short cases. Peak RSS is the evidence, and
the same-code pair bounds it — a 0.1 MB median difference and a 19 MB worst case
at the spilling 4,000,000-row points. §48 carries the full method and the limits.

## A join feeding an aggregate, composed (2026-10-28)

The pair §48 asked for. Candidate is the tree that folds the join's batches into
the aggregate (`bc02ff1`); control is the released 0.5.1 source in a detached
worktree, which collects the joined rows first. Fixtures, sweep, rounds, budgets
and queries are unchanged from the record above, so the two tables read down the
same points.

- [`harness/baseline/2026-10-28-e6b-join-agg.json`](../harness/baseline/2026-10-28-e6b-join-agg.json)
  — `bc02ff1`, clean tree, quiet gate 1.5, entered at load 0.75, peak load 2.53
  during the run, worst round-to-round spread 38% on the short cases. Candidate
  `52ede096…` and control `4d73a05f…`, the same control binary §48 used.
- All 75 case runs return their expected answer, agree with the control's, and
  the 45 grouped runs also agree with DuckDB. §49 carries the method, the
  counter comparison and the limits.

Peak RSS in MB, candidate against the collected control:

| joined rows | no budget | 4M | 16M |
|---|---|---|---|
| 1,000,000 | 39 / 51 | 46 / 54 | 49 / 51 |
| 2,000,000 | 39 / 97 | 45 / 117 | 61 / 100 |
| 4,000,000 | 39 / 191 | 45 / 226 | 61 / 193 |
| 2,000,000 (fanout 2, 1M probe rows) | 39 / 85 | 41 / 91 | 67 / 99 |
| 4,000,000 (fanout 4, 1M probe rows) | 39 / 153 | 41 / 166 | 63 / 193 |

The three controls have not moved and are the same in both records: the scan is
35.3 to 35.6 MB at every point, the aggregate alone is 35 MB without a budget and
45, 57 and 67 MB at 16M as its input grows, and the streaming join is 38.6 to
39.5 MB. So the composed peak is the scan plus the build side plus one batch, and
under a budget it is the budget rather than the joined rows; the collected peak
is the joined rows. Wall times are direction only on this host: equal at no
budget, faster for the composed path where the fold partitions early, slower
where it buffers up to the budget before partitioning, while using 63 MB instead
of 193 MB at that point.

## An ordered aggregate on the pull path (2026-10-28)

`harness/bench_ordered_agg.py` at SF1, the tree of `c2bc3fa` against the E6b
binary `eabf3e3`, three rounds interleaved, quiet load 0.27, worst
round-to-round spread 1% (`harness/baseline/2026-10-28-ordered-agg.json`). Peak
RSS in MB, control against candidate, with wall seconds beside it:

| query | shape | no budget | 16 MB | wall s, no budget / 16 MB |
| --- | --- | --- | --- | --- |
| q1 | one table, ordered | 543.3 → 35.3 | 558.7 → 75.3 | 2.80 → 2.70 / 5.14 → 5.02 |
| q12 | one join step, ordered | 112.7 → 35.3 | 115.3 → 35.4 | 2.64 → 2.60 / 3.16 → 2.59 |
| q3 | two join steps, invariant | 357.1 → 357.3 | 261.2 → 262.6 | 2.41 → 2.41 / 3.21 → 3.25 |
| q10 | two join steps, invariant | 283.1 → 283.1 | 245.3 → 245.5 | 2.52 → 2.52 / 3.94 → 3.95 |

Every answer is byte-identical between the two binaries. The 35 MB floor is the
one a scan alone reaches on this data set (§45), so an ordered single-table
aggregate now costs what an unordered one costs; the collected 543 MB is the
input. Under a 16 MB budget the candidate's peak is the budget plus the fold's
buffer while the collected path still holds the input it read (558.7 MB). q3
and q10 move inside the recorded spread, which is what an invariant should do.

## A chain of joins above an aggregate (2026-10-28)

`harness/bench_join_chain.py` at SF1, the tree of `aa63f7a` plus the change
recorded in verification §51 against that tree's own binary, three rounds
interleaved, quiet load 2.05, worst round-to-round spread 10%
(`harness/baseline/2026-10-28-chain-agg.json`). Peak RSS in MB, control against
candidate, with wall seconds beside it:

| query | shape | no budget | 16 MB | wall s, no budget / 16 MB |
| --- | --- | --- | --- | --- |
| q3 | three tables | 356.7 → 356.2 | 262.8 → 262.4 | 2.58 → 2.54 / 3.57 → 3.51 |
| q5 | six tables | 650.3 → 650.8 | 445.2 → 444.3 | 3.24 → 3.04 / 4.91 → 4.94 |
| q10 | four tables | 283.0 → 283.0 | 245.4 → 245.3 | 2.63 → 2.64 / 4.27 → 4.51 |
| q11 | three tables | 99.1 → 94.7 | 99.4 → 25.4 | 0.41 → 0.42 / 0.70 → 0.40 |
| q18 | three tables, `IN` | 470.4 → 467.3 | 227.4 → 227.3 | 4.95 → 4.90 / 6.02 → 5.81 |
| q20 | five tables, `IN` | 258.0 → 258.1 | 98.9 → 99.4 | 2.85 → 2.85 / 2.90 → 3.06 |
| q21 | four tables, `NOT EXISTS` | 608.3 → 604.1 | 666.7 → 666.6 | 7.86 → 8.15 / 13.65 → 13.89 |
| q1 | one table, invariant | 35.3 → 35.4 | 73.3 → 75.4 | 2.94 → 2.93 / 5.25 → 5.27 |
| q12 | one step, invariant | 35.3 → 35.2 | 39.3 → 35.4 | 2.83 → 2.89 / 2.88 → 2.91 |

The rule the numbers support is in §51: a chain holds one resident build side per
step, so it composes only under a budget those sides fit. That is q11 and nothing
else in the corpus at 16 MB, where it drops from 99.4 to 25.4 MB and stops
spilling (13 run files, 22.4 MB before). Every other case reports the same spill
trace as the control, and the 4 MB q12 shows at 16 MB is the recorded spread on a
case that composes in both binaries. Without a budget every chain takes the eager
path, so those rows are the control's own shape. The next section supersedes this
routing rule by making the index cheaper.

## A cheaper index over a build side (2026-10-29)

`harness/baseline/2026-10-29-chain-index.json`, from
`harness/bench_join_chain.py --budgets none,16M --rounds 3` against the pre-chain
control, quiet load 1.45, worst spread 11%, no answer disagreed. Peak RSS in MB,
control → candidate, with wall seconds behind it:

| query | shape | no budget | 16 MB | wall s, no budget / 16 MB |
| --- | --- | --- | --- | --- |
| q3 | three tables | 356.8 → 356.6 | 261.4 → 262.4 | 2.72 → 2.79 / 3.63 → 3.56 |
| q5 | six tables | 657.4 → 587.0 | 446.5 → 445.3 | 2.99 → 3.06 / 4.75 → 4.74 |
| q7 | derived table | 527.2 → 527.0 | 568.2 → 567.7 | 3.78 → 3.80 / 7.64 → 7.60 |
| q8 | derived table | 470.6 → 469.2 | 503.1 → 501.3 | 2.44 → 2.38 / 4.77 → 4.78 |
| q9 | derived table | 742.9 → 701.0 | 663.8 → 663.8 | 4.14 → 4.32 / 7.63 → 7.60 |
| q10 | four tables | 282.7 → 239.1 | 245.2 → 245.1 | 2.84 → 2.83 / 4.38 → 4.35 |
| q11 | three tables | 99.2 → 35.3 | 99.4 → 25.5 | 0.43 → 0.44 / 0.73 → 0.41 |
| q18 | three tables, `IN` | 469.4 → 469.1 | 227.3 → 227.4 | 5.15 → 5.28 / 5.85 → 5.93 |
| q20 | five tables, `IN` | 259.0 → 259.1 | 98.8 → 87.1 | 3.03 → 3.04 / 3.13 → 3.18 |
| q21 | four tables, `NOT EXISTS` | 612.0 → 616.6 | 682.2 → 684.0 | 8.08 → 8.03 / 13.67 → 13.77 |
| q1 | one table, invariant | 35.4 → 35.3 | 73.4 → 75.4 | 2.97 → 3.00 / 5.54 → 5.52 |
| q12 | one step, invariant | 35.3 → 35.2 | 35.5 → 35.5 | 2.94 → 2.91 / 2.92 → 2.92 |

Two changes are in the candidate: the index over a build side is one row-id
range instead of a list per key, and a chain of joins composes without a budget.
The first moves every keyed hash join (q9 without a budget, q20 under 16 MB); the
second is what takes q10 to 239 MB and q11 to 35.3. Verification §52 separates
the two by measuring a build of the same tree with the old gate restored: with
the cheap index alone the rows read 329.3 (q3), 584.5 (q5), 701.1 (q9), 262.9
(q10), 95.2 (q11) and 87.5 (q20 at 16 MB), so composition on q3 gives back the
index saving it gained (its chain holds `orders` and `lineitem` resident) and
costs q5 2.5 MB, while q10 gains 24 and q11 60.
