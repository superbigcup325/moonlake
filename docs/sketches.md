# Sketches

What the approximate aggregates promise, what they refuse, and what they cost.
Both are implemented and shipped in this tree: `approx_count_distinct(expr)`
and `approx_quantile(expr, q)`. The engine seam is `engine/exec_agg.mbt`'s
accumulator fold; the state machines are colenc's `sketches` package, whose own
contracts live in that project's `docs/SKETCHES.md`. This file is the SQL side:
types, NULL rules, value equivalence, parameter validation, error translation and
memory. [verification.md](verification.md) §39 records the original 0.1.1
evidence; §41 records acceptance after the move to 0.1.2. The state-cost section
below separates the current representation from those earlier measurements.

Both functions are explicit. Neither is reached by an optimizer, and neither
replaces the exact form: `COUNT(DISTINCT ...)` stays exact, `median()` keeps
every value.

## `approx_count_distinct(expr)`

Estimates the number of distinct non-NULL values, through a HyperLogLog sketch
at fixed precision `p = 14` (16,384 registers, a standard error of about 0.81%).

- **Input types.** Any scalar the engine has: boolean, int32, int64, float64,
  date, string. No cast is inserted; the value is hashed through the typed entry
  point that matches its column.
- **Result.** `int64`. The estimate is rounded to the nearest integer, so it is
  never "0.999" for a table with one value.
- **NULL and empty input.** NULL is skipped, as for every aggregate. An empty
  input, or one whose every value is NULL, returns 0. This is a count, so 0 is
  the right answer rather than NULL.
- **Value equivalence.** It has to agree with what `COUNT(DISTINCT ...)` already
  does in this tree, which is the type-tagged key in `engine/exec_agg.mbt`'s
  `scalar_key`:
  - `1` as int32 and `1` as int64 are different values, because the exact path
    tags its keys by type.
  - `-0.0` and `0.0` are the same value, and every NaN hashes to one canonical
    NaN, because the exact path compares their text form (`0` and `NaN`).
  - A string is hashed as its UTF-8 bytes, a date as its epoch day, a boolean as
    one byte.
  - DATE and INT32 with the same underlying number hash alike: they are fed to
    the sketch as the same integer. The binder gives an aggregate input one type
    per query, so the two cannot appear together in the same accumulator in
    practice; an expression that could produce both would already be a
    mixed-type column, and the approximation does not claim to separate them.
- **State.** With colenc 0.1.2, one sketch has 16,384 byte registers: 16 KiB of
  register payload plus object overhead, about 20 KB measured per group in a
  running query (20,358 B at 20,000 groups). Its v1 serialized state is unchanged at 16,386 bytes. Group
  count multiplies that cost, so the grouped crossover against the exact set is
  about 200 distinct values per group and many small groups are the expensive
  shape (table and numbers below). The 64 KiB payload and ~750-value crossover
  in the historical table describe 0.1.1.

## `approx_quantile(expr, q)`

Estimates the `q`-quantile of a numeric column through a t-digest at fixed
compression 100.

- **Input types.** int32, int64, float64. Every other type is a bind error.
- **`q`.** A constant literal, finite and in `[0, 1]`, validated at bind time —
  including for a query that would read no rows, so the same statement does not
  fail only once data appears. A non-constant or out-of-range argument is a bind
  error with the offending value in the message.
- **Result.** `float64`, as a centroid interpolant: it is not guaranteed to be
  one of the input values.
- **NULL and empty input.** NULL is skipped; an empty input or an all-NULL one
  returns NULL, like `median()`.
- **Non-finite input.** NaN and ±inf are a SQL error rather than a silent
  quasimedian: an approximate order statistic over values that have no order is
  not worth guessing at. The error is raised when the result is finished, since
  the fold itself cannot raise, and it names the function. A query whose input
  contains one such value fails as a whole.
- **int64 precision.** The value is converted to `Double` for the digest, so
  magnitudes beyond 2^53 lose their low bits. This is the same conversion
  `median()` does; it is documented, not detected.
- **Order and merges.** The digest is order-sensitive to the extent its contract
  allows, and the estimate carries the rank error colenc measured at
  compression 100 (1% interior, 0.5% tail) rather than a universal bound. A
  grouped query keeps one digest per group; no partial-state merge is used,
  because the grace path partitions by group key.

## State cost, measured

The released 0.1.2 representation is one byte per register: 16 KiB of payload at
p14, `2^p` bytes at general precision, plus object overhead. Hashing, rank,
estimator and the 16,386-byte p14 serialized state are unchanged from 0.1.1.

H0 measured what that costs a grouped query ([verification §43](verification.md#43-grouped-hll-costs-measured-2026-10-26-h0)).
Rig: `harness/bench_hll.py` at `49a3ed4`, native release, no workspace override,
one child process per query for peak RSS. MB is peak RSS, ms is wall time:

| groups × distinct | rows | `count(s)` | `count(DISTINCT s)` | `approx_count_distinct(s)` |
|---|---|---|---:|---:|---:|
| 1 × 1,000,000 | 1,000,000 | 16.9 MB / 92.6 ms | 115.4 MB / 586.0 ms | 15.0 MB / 122.7 ms |
| 100 × 10,000 | 1,000,000 | 15.6 / 85.9 | 115.3 / 330.8 | 16.7 / 133.0 |
| 1,000 × 1,000 | 1,000,000 | 14.7 / 88.2 | 119.0 / 354.0 | 33.7 / 144.1 |
| 10,000 × 100 | 1,000,000 | 15.2 / 54.3 | 35.2 / 213.0 | 206.8 / 247.0 |
| 5,000 × 10 | 50,000 | 13.3 / 7.6 | 13.4 / 15.9 | 107.5 / 81.9 |
| 20,000 × 10 | 200,000 | 15.3 / 21.6 | 21.3 / 55.2 | 403.6 / 333.2 |
| 20,000 × 1 | 20,000 | 13.4 / 10.1 | 17.2 / 14.5 | 408.0 / 274.5 |
| 1,000 × 100, duplicates ×10 | 1,000,000 | 13.3 / 41.7 | 21.3 / 182.5 | 29.3 / 91.9 |

- **Per group, about 20 KB.** 16 KiB of registers plus object and group-map
  overhead: the closed form (`approx` − `count(s)`) reports 20,358 B at 20,000
  groups, 20,091 B at 10,000 and 19,923 B at 1,000, and less when a group's
  registers are barely touched (12,478 B at 1,000 × 1) because untouched pages
  never become resident.
- **The crossover against the exact set is about 200 distinct values per group**
  at 1,000 groups: exact 21.3 MB at 100 values against 29.3 MB for the sketch,
  both 31.3 MB at 200, and 43.3 against 33.3 at 300. The exact side reaches
  121.4 MB at 1,000 values and 1,089.2 MB at 10,000.
- **Small groups are the cost.** 20,000 groups of one value hold 408.0 MB of
  sketches against 17.2 MB for the exact set; 5,000 groups of ten hold 107.5 MB
  against 13.4 MB. NULLs are skipped before a sketch sees them, so the 1-in-7
  NULL variants land within 3 MB of the packed ones.
- Peak RSS repeats within about ±2 MB, so the per-group figure and the crossover
  are the claims, not any single row; wall time is one host and not comparable to
  the release performance pair.
- The old 65,536 B payload and its ~750-value crossover below describe 0.1.1 and
  are kept as history, not as this dependency's threshold.

### The sparse state in the dependency (unreleased)

The small-group rows above are what promoted sparse HLL state in colenc. A sketch
there now holds either the dense array or a sorted array of live entries and
promotes above `min(128, m / 8)` live registers, with the hash, rank, estimator,
merge law and v1 bytes unchanged. Measured through an untracked `moon.work`
workspace against the same matrix, the same binary configuration, with identical
answers ([verification §43](verification.md#43-grouped-hll-costs-measured-2026-10-26-h0)):

| groups × distinct | 0.1.2 | sparse state | delta |
|---|---|---|---:|
| 20,000 × 1 | 408.0 MB / 274.5 ms | 15.3 MB / 13.6 ms | −392.7 MB |
| 20,000 × 10 | 403.6 / 333.2 | 17.3 / 34.0 | −386.3 |
| 5,000 × 10 | 107.5 / 81.9 | 13.4 / 11.4 | −94.1 |
| 10,000 × 100 | 206.8 / 247.0 | 17.3 / 116.5 | −189.5 |
| 1,000 × 1 | 25.3 / 13.0 | 13.0 / 2.0 | −12.3 |
| 1,000 × 100 | 29.3 / 25.6 | 15.3 / 22.2 | −14.0 |
| 1,000 × 100, duplicates ×10 | 29.3 / 91.9 | 13.3 / 105.1 | −16.0 |
| 1,000 × 1,000 | 33.7 / 144.1 | 35.3 / 153.0 | +1.6 |
| 1 × 1,000,000 | 15.0 / 122.7 | 17.3 / 127.5 | +2.3 |

Below the promotion limit a sketch stops costing anything measurable — the closed
form is 0 to 145 B per group — and those shapes also run 13–95% faster, because a
sparse sketch pages in a few hundred bytes per group instead of 16 KiB. A shape
whose groups all promote holds the memory it held before, inside a ±2.5 MB run
band, and pays wall time in proportion to how much of the query is the sketch
update: 2–27% across the 1,000-group crossover sweep, 14% on the duplicate shape,
4% at one million values in one group and 6% at 1,000 × 1,000. This is **not** in the dependency: 0.1.2 is the published
version, the override that measured it was removed, and taking the sparse state
needs a colenc release plus a `moon.mod` bump. 0.6.0's accepted scope does not
include it.

### Historical 0.1.1 baseline

The per-group numbers come from a scratch probe against `colenc/sketches` 0.1.1;
the query numbers come from the native release binary of this tree
(`_build/native/release/build/cmd/main/main.exe`) over one Parquet file with
1,000,000 rows, 2026-10-25. Peak RSS is the process maximum, measured in a
separate process per query.

| State | Per group |
|---|---|
| HLL, `p = 14` | 65,536 B in memory (16,384 registers × 4 B); 16,386 B serialized |
| HLL, `p = 4 / 8 / 12 / 16` | 64 B / 1,024 B / 16,384 B / 262,144 B |
| t-digest, compression 100 | 52–73 centroids after 1k–1M updates, 0.98–1.21 KB serialized |
| exact `COUNT(DISTINCT ...)` | about 88 B per distinct value on this machine |
| exact `median()` | keeps every value: 8 B per row plus array growth |

| Query over the 1,000,000-row file | Peak RSS | Answer |
|---|---|---|
| `count(s)` (decodes the string column, no state) | 56.6 MB | 1,000,000 |
| `count(DISTINCT s)`, every value distinct | 144.7 MB | 1,000,000 |
| `approx_count_distinct(s)` | 56.6 MB | 1,010,708 (+1.07%) |
| `count(d)` (decodes the double column, no state) | 34.1 MB | 1,000,000 |
| `median(d)` over 0..999,999 | 44.4 MB | 499,999.5 |
| `approx_quantile(d, 0.5)` | 33.9 MB | 499,999.5 |
| `k, count(DISTINCT s) GROUP BY k` (1,000 groups × 1,000 distinct) | 152.8 MB | — |
| `k, approx_count_distinct(s) GROUP BY k` (same groups) | 145.8 MB | — |

On this 0.1.1 baseline, the 65,536 B dense payload and roughly 88 B per exact
set entry put the observed crossover at about **750 distinct values per group**.
The 1,000-group row above belongs to that representation. These are retained as
historical measurements, not the cost or crossover of the current dependency.
Do not divide 750 by four to claim a new SQL threshold: object, group-map and
scan costs still have to be measured together in H0.

## What is not claimed

- No optimizer rewrite: `COUNT(DISTINCT ...)` never becomes an estimate.
- No persisted sketch state, no sketch column type, no merge across a spill
  partition or between queries.
- No error bound other than the estimator's standard error and the t-digest
  contract's measured rank error; no claim of agreement with another
  implementation's estimate, byte for byte or value for value.
- No `approx_median`, weighted input, ordered-set variant or window frame
  contract beyond what a window's own semantics give it.
