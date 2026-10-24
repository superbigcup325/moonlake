# Roadmap

What moonlake is working towards, what it deliberately refuses, and what would
have to happen before a direction currently on hold starts. The order is set by
evidence, not by appetite: a limit moves up this page when a real query, a real
file or a benchmark makes it expensive, and a candidate leaves the hold list
only when its trigger fires.

## Where 0.5.0 leaves the engine

Parquet and CSV scans read byte ranges on native targets instead of whole
files, the native Parquet writer streams as it encodes, and a query reclaims a
spill directory left behind by a killed process. A scan that aggregates holds a
couple of row groups rather than the file ([CHANGELOG](../CHANGELOG.md) has the
numbers); a scan that returns its rows still materializes them, which is the
executor row below. Correctness scope is unchanged: the same SQL subset, the same flat-schema
Parquet reading, the same `PLAIN`/v1-pages writing.

## Known limits, and what closing each one means

The writer's 2 GiB file-offset limit was the first row here until 2026-10-24.
It is gone: page and column-chunk offsets are 64-bit, so a single page still has
to fit its 32-bit length field and a file no longer does. A 2.41 GiB file
written from CSV reads back identically in moonlake, pyarrow and DuckDB
([CHANGELOG](../CHANGELOG.md), `harness/check_large_write.py`). What is still
refused:

| Limit today | Who runs into it | What a fix involves |
|---|---|---|
| wasm-gc and js scans read the whole file | Browser sessions over large CSVs or archives | Their filesystem module has no ranged read, so the fix starts upstream. `moonbitlang/async` already reads at a position, but only on native targets; the synchronous filesystem being built in `moonbitlang/x` does not carry one yet, and a wasm-gc version needs the runtime to export it as well. The browser playground has no filesystem at all and would keep using in-memory input either way. |
| The executor is not streaming end to end | Any query that returns its rows, not only ones larger than memory | Measured, and the trigger has fired: a scan materializes every projected value before the parent operator runs, so 6M rows of SF1 `lineitem` peak at 159 MB for one column and 3.1 GB for all sixteen, on CSV and Parquet alike, while `count(*)` over the same scan stays at 35 MB; `LIMIT 1000` still peaks at 2.6 GB because the scan finishes before the limit sees a row. Spilling is not the culprit: a 64 MB budget still peaks at 3.2 GB, and spilling to RAM or to disk differs by 0.03 s while moving 3.8 MB. A fix is bounded batches with backpressure between operators, starting with `LIMIT` reaching the scan; the merge pass is what spilling would then cost on top. [verification §25](verification.md) has the tables. |
| Reading is limited to flat schemas, v1 data pages, `INT32`/`INT64`/float/`STRING`/`DATE`/boolean, and the page encodings listed in the README; `DECIMAL`, `TIMESTAMP`, `INT96`, nested fields, v2 pages and the remaining codecs are refused with a pointed error | Producers that write those types | Each type or encoding needs the whole chain designed together: SQL type, CSV inference, Parquet read/write, spill format and JSON output. Starting with one of them alone tends to produce a value that is wrong somewhere later. |
| Spill reclamation declines to judge a directory it cannot prove is dead | A `--spill-dir` shared between containers, or a platform without `/proc` | Deliberate: a pid is only meaningful inside its own PID namespace, so the safe answer is to keep the directory and report it. Point each container at its own `--spill-dir`. |
| Writing is `PLAIN` values with v1 pages; `--snappy` is the only compression choice | Output size for wide or repetitive columns | Measured on the same 6M rows: pyarrow writes them in 288 MB as plain+snappy, 207 MB with a dictionary on every column, 196 MB with one on the twelve that benefit, and 183 MB with zstd. Per-column dictionary is therefore worth about a third of the file at no write- or read-time cost, but moonlake's own plain output is 333 MB for those rows — 16% above pyarrow's with comparable raw bytes, so the gap is the codec ratio of our page layout, not the encoding. The first step is attributing that 16%; an adaptive per-column dictionary comes after it, and zstd needs its slot in the reader's refusal list lifted. |

## Candidates waiting for a trigger

These are not scheduled. Each one names the evidence that would start it, so a
reader can tell the difference between "not yet" and "no".

| Direction | What starts it |
|---|---|
| Cost-based optimization, automatic build-side choice | A profile showing the current plan choice is the hotspot at a realistic scale and selectivity. First step is a prototype that can be compared against the current planner on fixed queries. |
| Bit-packed validity, fewer join-time concatenations | An isolated benchmark showing a repeatable win; earlier experiments did not. |
| Page layout, adaptive dictionary write encodings, v2 pages, further codecs | The writing row above has the measurement now: a per-column dictionary is worth −32% on SF1 `lineitem`, yet plain output is 16% larger than pyarrow's for the same rows and codec, so the page layout is the first question (page size, where pages end, statistics) and the encoding choice the second. Starts when that 16% is charged to something specific. |
| `DECIMAL`, `TIMESTAMP`, explicit window frames | A semantic need with the full chain designed (see the limits table). |
| Arrow, a DataFrame API, JSONL, object storage | A real consumer and an interface contract. These stay separate adapters; the engine's own API is not a DataFrame. |
| Parallel execution, linear memory, cross-language benchmark suites | A target user and toolchain support for it. |
| Ranged reads on wasm-gc and js | Upstream exposing one: a single range-read method behind the existing file type, with the same contract the native binding keeps. `moonbitlang/async` shows the shape on native; the synchronous path and the wasm-gc/js runtime behind it are upstream's to build, so this direction waits rather than being worked on here. |

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
