# Sketches

What the approximate aggregates promise, what they refuse, and what they cost.
Both are implemented and shipped in this tree: `approx_count_distinct(expr)`
and `approx_quantile(expr, q)`. The engine seam is `engine/exec_agg.mbt`'s
accumulator fold; the state machines are colenc's `sketches` package, whose own
contracts live in that project's `docs/SKETCHES.md`. This file is the SQL side:
types, NULL rules, value equivalence, parameter validation, error translation and
memory. [verification.md](verification.md) §39 records the evidence.

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
- **State.** One dense sketch per non-empty group: 16,384 registers of four
  bytes, 65,536 bytes in memory (a serialized state would be 16,386 bytes, which
  is not what a running query holds). A group that gets no non-NULL value never
  allocates one. Group count × 64 KiB is the floor, which is why the exact path
  is cheaper below a few hundred distinct values per group (table below).

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

The crossover that matters: a dense sketch costs 65,536 B whatever it holds,
while the exact set costs roughly 88 B per distinct value here, so a group needs
about **750 distinct values** before the sketch is the cheaper representation.
Below that, `COUNT(DISTINCT ...)` wins on memory, and the 1,000-group row above
shows the shape: 1,000 sketches are 64 MB no matter how few values each group
holds. A precision option or an adaptive sparse representation is a colenc
decision that waits for a consumer measurement in which per-group memory is the
limiting cost.

## What is not claimed

- No optimizer rewrite: `COUNT(DISTINCT ...)` never becomes an estimate.
- No persisted sketch state, no sketch column type, no merge across a spill
  partition or between queries.
- No error bound other than the estimator's standard error and the t-digest
  contract's measured rank error; no claim of agreement with another
  implementation's estimate, byte for byte or value for value.
- No `approx_median`, weighted input, ordered-set variant or window frame
  contract beyond what a window's own semantics give it.
