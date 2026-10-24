# Roadmap

What moonlake is working towards, what it deliberately refuses, and what would
have to happen before a direction currently on hold starts. The order is set by
evidence, not by appetite: a limit moves up this page when a real query, a real
file or a benchmark makes it expensive, and a candidate leaves the hold list
only when its trigger fires.

## Where 0.5.0 leaves the engine

Parquet and CSV scans read byte ranges on native targets instead of whole
files, the native Parquet writer streams as it encodes, and a query reclaims a
spill directory left behind by a killed process. Peak memory for a scan no
longer grows with input size ([CHANGELOG](../CHANGELOG.md) has the numbers).
Correctness scope is unchanged: the same SQL subset, the same flat-schema
Parquet reading, the same `PLAIN`/v1-pages writing.

## Known limits, and what closing each one means

| Limit today | Who runs into it | What a fix involves |
|---|---|---|
| The native writer refuses a file that would need an offset past 2 GiB | Anyone writing an output larger than a couple of GB (a TPC-H SF10 `lineitem` is ~7 GB) | Store page offsets as 64-bit in the footer and column metadata; a single page stays under 2 GiB, so the guard becomes per-page rather than per-file. Readers are already fine: a chunk over 2 GiB is refused by column name, and a large file with ordinary chunks is not. |
| wasm-gc and js scans read the whole file | Browser sessions over large CSVs or archives | Their filesystem module has no ranged read, so the fix starts upstream: a `read_at`-style API in `moonbitlang/x`. The browser playground has no filesystem at all and would keep using in-memory input either way. |
| The executor is not streaming end to end | Queries whose result is large but whose operators are not blocking | Spilling bounds a blocking `ORDER BY`/join/`GROUP BY`; a fully streaming pipeline (with backpressure between operators) is a design change, not a flag. Starts when a query that spills is shown to be slow *because* it materializes, not because it spills. |
| Reading is limited to flat schemas, v1 data pages, `INT32`/`INT64`/float/`STRING`/`DATE`/boolean, and the page encodings listed in the README; `DECIMAL`, `TIMESTAMP`, `INT96`, nested fields, v2 pages and the remaining codecs are refused with a pointed error | Producers that write those types | Each type or encoding needs the whole chain designed together: SQL type, CSV inference, Parquet read/write, spill format and JSON output. Starting with one of them alone tends to produce a value that is wrong somewhere later. |
| Spill reclamation declines to judge a directory it cannot prove is dead | A `--spill-dir` shared between containers, or a platform without `/proc` | Deliberate: a pid is only meaningful inside its own PID namespace, so the safe answer is to keep the directory and report it. Point each container at its own `--spill-dir`. |
| Writing is `PLAIN` values with v1 pages; `--snappy` is the only compression choice | Output size for wide or repetitive columns | A real producer whose size/read/write trade favours a dictionary or adaptive encoding. The format change is small; proving it pays is the work. |

## Candidates waiting for a trigger

These are not scheduled. Each one names the evidence that would start it, so a
reader can tell the difference between "not yet" and "no".

| Direction | What starts it |
|---|---|
| Cost-based optimization, automatic build-side choice | A profile showing the current plan choice is the hotspot at a realistic scale and selectivity. First step is a prototype that can be compared against the current planner on fixed queries. |
| Bit-packed validity, fewer join-time concatenations | An isolated benchmark showing a repeatable win; earlier experiments did not. |
| Dictionary or adaptive write encodings, v2 pages, further codecs | A specific producer file, with size, write time, read time and peak memory measured both ways. |
| `DECIMAL`, `TIMESTAMP`, explicit window frames | A semantic need with the full chain designed (see the limits table). |
| Arrow, a DataFrame API, JSONL, object storage | A real consumer and an interface contract. These stay separate adapters; the engine's own API is not a DataFrame. |
| Parallel execution, linear memory, cross-language benchmark suites | A target user and toolchain support for it. |
| Ranged reads in `moonbitlang/x` | An upstream API worth proposing: the shape is one range-read method behind the existing file type, with the same contract the native binding keeps. |

## What a release has to clear

Every release is gated, not asserted: the version claims agree across the
manifest, the library constant and the changelog; the packed archive works from
an independent consumer on native, wasm-gc and js with fresh dependency caches;
the test suite and the TPC-H golden set pass on three targets; the spill
acceptance and the writer interop checks pass; the deployed page is driven in a
real browser and must report the exact version being released; and a performance
record is committed beside the previous release's so "did it get slower" has an
answer that is not a memory. [verification.md](verification.md)
records each release's evidence and what it does not claim.

## How to move something up this page

Open an issue with the case that is expensive: the file (or its shape and size),
the query, and the number that matters — memory, wall time, or a file that
cannot be written at all. A limit with a reproduction beats a limit with a
theory.
