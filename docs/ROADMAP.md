# Roadmap

The current delivery target is **0.6.0, unreleased**. All changes since 0.5.0
and the work scheduled below belong to it. Completing a task does not make a
release: the remaining tasks and their acceptance checks must clear first.
Directions waiting for evidence stay on the hold list until their trigger fires.

## Current implementation

Native CSV and Parquet sources read byte ranges, the native Parquet writer
streams its output, and spill directories are reclaimed when ownership evidence
proves the process is dead. These shipped in 0.5.0. The pending 0.6.0 changes
include files past 2 GiB, smaller Snappy output, a single-table LIMIT that stops
its scan, checked SQL integer arithmetic, CSV and CLI fixes, and more general
correlated subqueries. [CHANGELOG](../CHANGELOG.md) lists implemented changes;
[verification](verification.md) records the evidence for each.

Sources read incrementally, but most executor paths still accumulate their
input batches before the parent operator runs. `execute` and `execute_with`
return a complete `SelectResult`; `stream` and `stream_with` hand out batches
instead, and the CLI prints through them, so a single-table scan with its
`WHERE`, projection and `OFFSET`/`LIMIT` window no longer holds its result.
Aggregation, joins, `ORDER BY` and set operations still do — each needs its
state built from batches first, which is what E4a/E4b/E4c are. `--memory`
budgets blocking operators and is not a process RSS cap.

## 0.6.0 delivery plan

The order below is by dependency. R0 fixes the scope, S0 preserves correctness
before another executor change, E3 adds result consumption, and E4 changes one
blocking operator at a time. The existing early-stop measurements, batch
contract and single-table LIMIT implementation cover the earlier E0/E1/E2
milestone; extend them rather than implementing that milestone again.
R0, S0 and E3 are complete. E4a/E4b/E4c, W0 and R1 remain
open; their inclusion in 0.6.0 is a delivery commitment, not a claim that the
features already exist. S0's gate is `harness/check_correlation.py` with its
fixtures, wired into the fixed-case CI job and the seeded nightly; verification
§30 records what it found while being committed — two wrong answers in
three-valued `IN` / `NOT IN` and one shape whose refusal message is still the
binder's. E3's contract is stated in `engine/stream.mbt` and its evidence in
verification §31; E4a starts from `engine/exec_agg.mbt` and `engine/extagg.mbt`
with that pull in place.

| Task | Delivery | Depends on | Acceptance |
|---|---|---|---|
| R0 | One unreleased 0.6.0 scope in the changelog, roadmap and handoff | Current-state check | Every pending changelog entry belongs to 0.6.0; implemented work and remaining work have distinct status; the latest published release stays identified as 0.5.0 |
| S0 | Reproducible regression evidence for the latest SQL and CLI changes | R0 | Commit the correlation differential fixtures and runner, including duplicate outer rows, NULLs, empty inputs and deliberate refusals; normalize dates and non-finite values and compare unordered answers as row multisets; an oracle error, missing fixture, wrong answer or zero value cases fails; run fixed cases in CI and add seeded cases to nightly |
| E3 | An additive result-consumption API and a CLI that consumes batches | S0 | **Done** (verification §31): a caller reads the schema and consumes a single-table scan/filter/projection/`OFFSET`-`LIMIT` query batch by batch without collecting it; `execute` / `execute_with` keep their signatures and run the same pull; `close` and a failed pull release the scan; text and JSON output are consumed per batch (a 16-column 2,000,000-row result: 1,090.6 MB → 35.2 MB of peak RSS for `--json`) |
| E4a | Aggregation consumes batches | E3 | Global and grouped aggregates update state as input arrives; remove the full input array on the supported path; empty groups, DISTINCT aggregates and NULLs match the oracle; budgeted cases really spill and match in-memory answers |
| E4b | External sort consumes batches and feeds the result consumer | E3 | Build sorted runs directly from batches and consume the final merge incrementally; cover multi-batch runs, ties, NULL order, OFFSET and LIMIT at several budgets; success, error and early-stop paths remove owned run files |
| E4c | Join input and output use the batch contract | E3, established spill lifecycle | Start with hash-build state and a streaming probe, then feed grace partitions incrementally; cover duplicate keys, empty sides, outer joins, residual predicates and semi/anti NULL semantics against the oracle; identify eager correlation paths explicitly |
| W0 | A second dataset tests whether adaptive dictionaries are worth implementing | Fixed comparison inputs; independent of E3/E4 | Measure low- and high-cardinality columns, long strings and NULLs with the same page/row-group layout; record bytes, write/read time and memory; distinguish PyArrow experiments from Moonlake implementation results |
| R1 | Final 0.6.0 acceptance and release evidence | S0, E3, E4a, E4b, E4c, W0 | The release checks below pass on the final candidate; record the remaining eager paths and platform limits; publish only after release authorization |

**E3 contract.** Extend the ownership and early-stop rules in
`engine/stream.mbt` to the result boundary. `catalog.BatchStream` is an open
public trait; preserve external implementations when adding lifecycle behavior.
Specify exhaustion, early stop, repeated cleanup, query failure and consumer
failure, especially once a stream owns spill files. State which query shapes
stream and which use an eager fallback. Keep bind/type errors independent of
whether a LIMIT reads the tail. Define and test the CLI's partial-output behavior
when execution fails after rows have already been emitted, including its nonzero
exit status and error channel.

**Implementation entry points.** E3 starts at `moonlake.mbt`,
`engine/engine.mbt`, `engine/stream.mbt`, `catalog/source.mbt` and
`cmd/main/main.mbt`. E4a uses `engine/exec_agg.mbt` and `engine/extagg.mbt`;
E4b uses `engine/exec_sort.mbt`, `engine/extsort.mbt` and
`engine/spillruns.mbt`; E4c uses `engine/exec_join.mbt`,
`engine/extjoin.mbt`, `engine/scan.mbt` and `engine/correlate.mbt`.
S0 starts from the cases documented in verification's pre-release user pass and
general decorrelation sections. W0 extends the measurements behind the writing
limit below with a structurally different table.

**Resource evidence.** Extend `harness/bench_early_stop.py` and the release
benchmark instead of relying on local-only probes. Record the source batch and
byte counts, first-result latency, total wall time, peak RSS, spill bytes and
result consumption separately. Measure the old collector, a batch consumer and
the CLI in isolated processes with stdout written to a file or sink. Compare
increasing input sizes with a fixed result or group count to expose retained
input. Performance comparisons need the same session, data hashes, toolchain,
build mode and answer oracle, plus a control run to identify machine noise.

W0 is a committed 0.6.0 investigation. Dictionary implementation (W1) enters
the version only if that investigation or a real consumer justifies it. W1 must
bound dictionary memory, choose per column, fall back to PLAIN when repetition
does not pay, and preserve v1-page and reader interoperability. A negative W0
result completes the investigation; it does not block 0.6.0 on a speculative
encoding change.

Window functions, DISTINCT, set operations and derived queries may retain
documented eager paths in 0.6.0. A blocking operator can consume batches without
emitting its final answer early. Neither batch consumption nor a small
`--memory` value alone proves bounded total RSS. Broader SQL types, codecs,
optimizers, adapters and platform work still follow the triggers below.

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
| The executor is not streaming end to end | Unrestricted results and queries with blocking operators | A single-table scan streams its result through `stream`/`stream_with`, and the CLI prints through it, so an unrestricted `WHERE`/projection result no longer holds its rows (verification §31: `--json` over 16 columns and 2,000,000 rows, 1,090.6 MB → 35.2 MB of peak RSS). Aggregation, joins and `ORDER BY` still retain their input before their parent operator runs; SF1 measured 159 MB for one projected column and 3.1 GB for all sixteen. E4a/E4b/E4c above are scheduled for 0.6.0 to remove that retention on those paths. See verification §25 for the eager measurements and §27 for the LIMIT comparison. |
| Reading is limited to flat schemas, v1 data pages, `INT32`/`INT64`/float/`STRING`/`DATE`/boolean, and the page encodings listed in the README; `DECIMAL`, `TIMESTAMP`, `INT96`, nested fields, v2 pages and the remaining codecs are refused with a pointed error | Producers that write those types | Each type or encoding needs the whole chain designed together: SQL type, CSV inference, Parquet read/write, spill format and JSON output. Starting with one of them alone tends to produce a value that is wrong somewhere later. |
| A non-equality correlation is answered by a nested loop | A correlated subquery whose predicate is not an equality over a large inner table | Keyless semi/anti joins test candidate inner rows; a scalar theta aggregate tests distinct outer combinations against inner rows. A range-aware or index-backed join needs a data layout that can answer the predicate without a scan. Start that optimization when a real query shows the cost. Verification §28 records the supported shapes, §30 the gate that now preserves their answers; E4c must name any eager fallback. |
| Spill reclamation declines to judge a directory it cannot prove is dead | A `--spill-dir` shared between containers, or a platform without `/proc` | Deliberate: a pid is only meaningful inside its own PID namespace, so the safe answer is to keep the directory and report it. Point each container at its own `--spill-dir`. |
| Writing is `PLAIN` values with v1 pages; `--snappy` is the only compression choice | Output size for wide or repetitive columns | Measured on 6M SF1 rows: a per-column dictionary takes pyarrow's 288 MB to 196 MB (−32%) at no write- or read-time cost, and plain+zstd would reach 183 MB, but that needs a reader that accepts zstd. moonlake's own `--snappy` write is 289.2 MB for those rows: the 16% gap to pyarrow that this row used to name was one missing tag in the compressor (a short match close behind now costs two bytes, not three), so what is left is the dictionary, which is worth −32% and needs a per-column choice because it *grows* columns with no repetition. |

## Candidates waiting for a trigger

These are not scheduled. Each one names the evidence that would start it, so a
reader can tell the difference between "not yet" and "no".

| Direction | What starts it |
|---|---|
| Cost-based optimization, automatic build-side choice | A profile showing the current plan choice is the hotspot at a realistic scale and selectivity. First step is a prototype that can be compared against the current planner on fixed queries. |
| Bit-packed validity, fewer join-time concatenations | An isolated benchmark showing a repeatable win; earlier experiments did not. |
| Adaptive dictionary write encodings, v2 pages, further codecs | The writing row has the measurement and the page-layout question is closed, so what starts this is a second table to tune a per-column heuristic against, or an output-size complaint from a real producer whose columns are repetitive enough for the −32% to matter. |
| `DECIMAL`, `TIMESTAMP`, explicit window frames | A semantic need with the full chain designed (see the limits table). |
| Arrow, a DataFrame API, JSONL, object storage | A real consumer and an interface contract. These stay separate adapters; the engine's own API is not a DataFrame. |
| Parallel execution, linear memory, cross-language benchmark suites | A target user and toolchain support for it. |
| Ranged reads on wasm-gc and js | Upstream exposing one: a single range-read method behind the existing file type, with the same contract the native binding keeps. `moonbitlang/async` shows the shape on native; the synchronous path and the wasm-gc/js runtime behind it are upstream's to build, so this direction waits rather than being worked on here. |

## What 0.6.0 has to clear

R1 starts after the required implementation and investigation tasks above are
complete. Record evidence against the final candidate SHA:

- The manifest, library constant, generated interfaces, changelog and eventual
  tag agree on 0.6.0. Set the changelog's release date when the release happens.
- Check, format, interface freshness, the native/wasm-gc/js test suites and
  Python gate self-tests pass. Extend the independent archive consumer to use
  the new result API on all three targets, with fresh dependency caches.
- Golden queries pass on all three targets. `harness/check_all.sh` currently
  runs the default wasm-gc target; add an explicit target or binary selection
  and preserve a reproducible command before claiming native or js coverage.
- The S0 differential, window and pushdown checks, Parquet corpus, encoding
  fixtures, CLI checks, spill lifecycle and writer interoperability pass. Run
  the real file-past-2-GiB check and confirm the new nightly job at its own SHA.
- Commit a complete 0.6.0 performance record beside a same-session 0.5.0
  re-record. Keep the LIMIT-specific records as separate optimization evidence.
  Explain any changed answers or workloads before comparing timings.
- Check host-free wasm imports and drive the candidate playground in a real
  browser. After deployment, require the exact 0.6.0 version; after publication,
  run the registry consumer for 0.6.0. These are separate from local acceptance.

`moon publish --dry-run` uploads an archive, so it belongs to authorized release
work along with push, tag and publication. Current assessment and local
preparation do not perform those actions. [verification.md](verification.md)
records completed checks and their limits; a check on an earlier SHA is history,
not acceptance of the final candidate.

## How to move something up this page

Open an issue with the case that is expensive: the file (or its shape and size),
the query, and the number that matters — memory, wall time, or a file that
cannot be written at all. A limit with a reproduction beats a limit with a
theory.
