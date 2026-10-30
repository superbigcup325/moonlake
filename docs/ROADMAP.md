# Roadmap

**0.5.1 is released** — `superbigcup325/moonlake@0.5.1` on mooncakes, the
annotated tag `v0.5.1` on `f8e1204`, a GitHub release, and the registry consumer
check passing on all three targets (verification §47). The number is the owner's
decision of 2026-10-27: the scope was planned as 0.6.0 and is unchanged, and
every document, the delivery-plan heading and the recorded baseline filenames
were renumbered together. The current dependency is the
published colenc 0.1.3 (`344d739`), whose full local acceptance, grouped-sketch
matrix and release pair are recorded in verification §44 and
`docs/bench-baseline.md`. Two dependency costs closed on the way: the 0.1.1
artifact's wide-CSV cost (the 0.1.2 cases ran 6-11% faster than its control in
every round) and the grouped sketch's per-group state (0.1.3 hands the sparse
registers to this tree, worth 393 MB on the worst shape). The short Parquet cases
remain unresolved.

Upstream checked on 2026-10-27 (Asia/Shanghai): `main` is `020be75`, with
[CI passing](https://github.com/superbigcup325/moonlake/actions/runs/40513060636).
The release commit `f8e1204` passed
[Pages](https://github.com/superbigcup325/moonlake/actions/runs/40512431550),
and verification §47 records both the fresh-cache registry consumer on three
targets and the deployed playground at exactly 0.5.1. `moon view` confirms
0.5.1 and colenc 0.1.3 as the respective registry latest versions. colenc `main`
is `d6a892e`, with
[CI passing](https://github.com/superbigcup325/colenc/actions/runs/40347664183).
Neither repository has an open issue or pull request at this snapshot. The
latest nightly passed on `f4e9348`, before E5; it is not a nightly result for
the released source. This status check did not repeat functional or performance
acceptance.

The [delivery after colenc 0.1.3](#next-delivery-after-colenc-013) is complete:
H0 measured the grouped-HLL cost, C3 consumed sparse state, E5 removed retained
scan input before budgeted GROUP BY, and R3 released the scope as 0.5.1. The
[next proposed work](#next-work-after-051) is to measure a join feeding an
aggregate and decide whether to compose their batch paths. FSST reuse and
Roaring index integration retain their workload triggers.

## Current implementation

Native CSV and Parquet sources read byte ranges, the native Parquet writer
streams its output, and spill directories are reclaimed when ownership evidence
proves the process is dead. These shipped in 0.5.0. The 0.5.1 changes add files
past 2 GiB, smaller Snappy output, a single-table LIMIT that stops its scan,
checked SQL integer arithmetic, CSV and CLI fixes, more general correlated
subqueries, and two explicit approximate aggregates
(`approx_count_distinct`, `approx_quantile`; [sketches](sketches.md), §39).
[CHANGELOG](../CHANGELOG.md) lists implemented changes;
[verification](verification.md) records the evidence for each.

Sources read incrementally, and the operators that can work a batch at a time
now do. `execute` and `execute_with` return a complete `SelectResult`; `stream`
and `stream_with` hand out batches instead, and the CLI prints through them, so
a single-table scan with its `WHERE`, projection and `OFFSET`/`LIMIT` window
never holds its result (verification §31). A single-table `GROUP BY` or global
aggregate folds its groups as the scan delivers batches and holds its state
instead of its input (109.7 MB → 35.3 MB of peak RSS over 16 columns and
2,000,000 rows, §32). A spilled `ORDER BY` builds runs from those batches and
hands the merge out as a cursor, owning the run files it writes (506.8 MB →
178.8 MB, §33). A two-table `INNER`/`LEFT`/`FULL` join reads its build side once,
probes a batch at a time and returns the joined rows in batches of at most
4,096, so only the side that has to be resident is (270.8 MB → 35.3 MB, §34).
A budgeted single-table GROUP BY also consumes the scan: bounded partition
buffers replace the collected input (verification §45: 195 MB → 63 MB at
8,000,000 rows, 100 groups and a 4M budget). Parquet-input controls show bounded
retained input on native, wasm-gc and js. The CSV reader's own footprint grows
on wasm-gc and js, and group state and the final grouped result remain unbounded.
What still accumulates is listed per shape: a `RIGHT` or `SEMI`/`ANTI` join, a
keyless cross join, `DISTINCT` or a window above a join, and a `FROM` item that
is not a lazy base table (a derived table), plus set operations. A `GROUP BY`
above a two-table keyed INNER/LEFT/FULL join folds the join's batches instead,
with or without an `ORDER BY` (verification §49, §50), and a chain of the same
kinds above one folds a cursor per step, with or without a budget (§51, §52). `--memory` budgets the operators that honour it and is
not a process RSS cap.

## 0.5.1 delivery plan

This completed plan retains its original dependency order. R0 fixed the scope,
S0 added regression evidence before executor changes, E3 added result consumption,
and E4 changed one blocking operator at a time. The existing early-stop measurements, batch
contract and single-table LIMIT implementation cover the earlier E0/E1/E2
milestone; extend them rather than implementing that milestone again. Every task
below, R1 included, is complete on `3ab2634` (verification §36). S0's gate is
`harness/check_correlation.py` with its fixtures, wired into the fixed-case CI
job and the seeded nightly; verification §30 records what it found while being
committed — two wrong answers in three-valued `IN` / `NOT IN` and one shape
whose refusal message is still the binder's. E3's contract is stated in
`engine/stream.mbt` and its evidence in verification §31; E4a's is the same
batch contract one operator further in, and verification §32 records it. E4b's
is a cursor over run files, and verification §33 records it; E4c's is the one
shape whose build side must stay resident, recorded in §34; W0's answer is a
measurement and a decision, and verification §35 records both.

| Task | Delivery | Depends on | Acceptance |
|---|---|---|---|
| R0 | One release scope in the changelog, roadmap and handoff | Current-state check | **Done.** The scope was planned as 0.6.0 and published as 0.5.1 by the owner decision recorded in verification §47; 0.5.0 is the preceding release |
| S0 | Reproducible regression evidence for the latest SQL and CLI changes | R0 | Commit the correlation differential fixtures and runner, including duplicate outer rows, NULLs, empty inputs and deliberate refusals; normalize dates and non-finite values and compare unordered answers as row multisets; an oracle error, missing fixture, wrong answer or zero value cases fails; run fixed cases in CI and add seeded cases to nightly |
| E3 | An additive result-consumption API and a CLI that consumes batches | S0 | **Done** (verification §31): a caller reads the schema and consumes a single-table scan/filter/projection/`OFFSET`-`LIMIT` query batch by batch without collecting it; `execute` / `execute_with` keep their signatures and run the same pull; `close` and a failed pull release the scan; text and JSON output are consumed per batch (a 16-column 2,000,000-row result: 1,090.6 MB → 35.2 MB of peak RSS for `--json`) |
| E4a | Aggregation consumes batches | E3 | **Done** (verification §32): a single-table `GROUP BY` or global aggregate folds the scan's batches as they arrive and never holds its input array; NULL key groups, NULL aggregate inputs, empty inputs and DISTINCT aggregates match the collected answers and the goldens; the counters `--analyze` prints are identical on both paths; a budgeted `GROUP BY` still spills and still matches in-memory answers (16 columns, 2,000,000 rows: 109.7 MB → 35.3 MB of peak RSS) |
| E4b | External sort consumes batches and feeds the result consumer | E3 | **Done** (verification §33): runs are built from the scan's batches, the final merge is a cursor and a sorted stream hands it out a batch at a time, so neither the input array nor the sorted answer is materialized (16 columns, 2,000,000 rows, `select * … order by id`: 506.8 MB → 178.8 MB of peak RSS); ties, NULL order, DISTINCT, OFFSET/LIMIT and the in-memory fallback match the collected answers at four budgets; the run files are removed on exhaustion, on early close and on error; `--analyze` counters and spill bytes are unchanged |
| E4c | Join input and output use the batch contract | E3, established spill lifecycle | **Done** (verification §34): a two-table INNER/LEFT/FULL join streams — `JoinCursor` reads the build side once and probes a batch at a time, the output leaves in batches of at most 4096 rows, and `join_step` runs on the same cursor so the collected and streamed answers cannot diverge; duplicate keys on both sides, empty build and probe sides, LEFT/FULL unmatched rows, residual predicates, NULL keys and an early close are compared against `execute`; the shapes that stay collected are listed and each is pinned by a test (16 columns, 2,000,000 rows probed against a 1,000-row build: 270.8 MB → 35.3 MB of peak RSS, and under `--memory 8M` the grace path is not entered at all, 1.99 s → 0.41 s) |
| W0 | A second dataset tests whether adaptive dictionaries are worth implementing | Fixed comparison inputs; independent of E3/E4 | **Done** (verification §35), and the answer is "not in this release": on a seeded 500,000-row access log a per-column dictionary is worth −14% of the file at our writer's 4,096-row groups and −28% at 65,536-row groups, a table-level dictionary is a net *loss* (+1.6%), and PyArrow's 65,536-row groups save 1.4% of the file while raising the reader's peak from 13 MB to 57 MB, so the layout decision comes before the encoding; `harness/dict_survey.py` reproduces the tables and `write --snappy` output is within ±1.4% of PyArrow's plain output on the same rows (the seed, both layouts, the per-column deltas, the write/read times and the memory numbers are recorded) |
| R1 | Final 0.5.1 acceptance and release evidence | S0, E3, E4a, E4b, E4c, W0 | **Done** (verification §36): one candidate passes the whole list — check, format and interfaces clean, 340 native / 327 wasm-gc / 327 js tests, 75 Python self-tests, the 33 goldens on wasm-gc, native, js and through the release binary, the S0 differential plus window, pushdown, corpus, encoding, CLI, spill and writer gates, a 2,410,475,894-byte file round-tripping through three readers, and the packaged consumer pulling four shapes on three targets with fresh caches; the playground builds host-free and passes 16/16 in real Chromium; the performance pair is recorded beside a same-session 0.5.0 re-record; the eager shapes and platform limits are stated in `engine/stream.mbt`, §34 and the paragraph above. The later source acceptance is in §46 and the completed publication is in §47 |

**E3 contract.** Extend the ownership and early-stop rules in
`engine/stream.mbt` to the result boundary. `catalog.BatchStream` is an open
public trait; preserve external implementations when adding lifecycle behavior.
Specify exhaustion, early stop, repeated cleanup, query failure and consumer
failure, especially once a stream owns spill files. State which query shapes
stream and which use an eager fallback. Keep bind/type errors independent of
whether a LIMIT reads the tail. Define and test the CLI's partial-output behavior
when execution fails after rows have already been emitted, including its nonzero
exit status and error channel.

**Implementation entry points.** E3 started at `moonlake.mbt`,
`engine/engine.mbt`, `engine/stream.mbt`, `catalog/source.mbt` and
`cmd/main/main.mbt`; E4a added `streaming_agg_source`, `InputPull` (then named
`AggPull`) and `run_agg_pull` to `engine/stream.mbt`, dispatched from
`engine.mbt`, and folds through `engine/exec_agg.mbt`'s `aggregate_seq`. E4b
added `streaming_sort_source`, `sort_input`, `run_sort_pull` and
`ResultStream::sorted` there, `build_runs` and `MergeCursor` in
`engine/extsort.mbt`, and made a sorted stream the one stream that owns run
files; E4c started from `engine/exec_join.mbt`, `engine/extjoin.mbt`,
`engine/scan.mbt` and `engine/correlate.mbt`, and added
`JoinCursor` (also `join_step`'s engine, so one cursor serves both deliveries),
`streaming_join_source`, `JoinedPull` and `ResultStream::joined`. Grace
partitions keep their own path and are not fed incrementally: a two-table join
of the streamed shape never reaches them, while a chain of three or more still
does.
S0 starts from the cases documented in verification's pre-release user pass and
general decorrelation sections. W0 extended the measurements behind the writing
limit below with a structurally different table, and found that the row-group
size moves those numbers more than the encoding does (verification §35).

**Resource evidence.** Extend `harness/bench_early_stop.py` and the release
benchmark instead of relying on local-only probes. Record the source batch and
byte counts, first-result latency, total wall time, peak RSS, spill bytes and
result consumption separately. Measure the old collector, a batch consumer and
the CLI in isolated processes with stdout written to a file or sink. Compare
increasing input sizes with a fixed result or group count to expose retained
input. Performance comparisons need the same session, data hashes, toolchain,
build mode and answer oracle, plus a control run to identify machine noise.

W0 was a committed 0.5.1 investigation and it is answered in §35: on a second
table a per-column dictionary is worth −14% of the file at our current row-group
size and −28% at sixteen times fewer row groups, so the layout decision comes
first and dictionary implementation (W1) stays out of 0.5.1. When its trigger
below fires, W1 must bound dictionary memory, choose per column, fall back to
PLAIN when repetition does not pay, and preserve v1-page and reader
interoperability. A W0 result that does not justify the change completes the
investigation; it did not block 0.5.1 on a speculative encoding change.

Window functions, DISTINCT, set operations and derived queries may retain
documented eager paths in 0.5.1. A blocking operator can consume batches without
emitting its final answer early. Neither batch consumption nor a small
`--memory` value alone proves bounded total RSS. Broader SQL types, codecs,
optimizers, adapters and platform work still follow the triggers below.

## Follow-up after colenc 0.1.1

This follow-up began with 0.1.1; the status below was refreshed after 0.1.3 on
2026-10-26 (Asia/Shanghai), using source inspection and live release/CI queries.
Completed tasks retain their original revisions and measurements. The new
sequence below adds no implemented SQL or index API.

### Baseline and ownership

| Project | Current evidence | Consequence for the plan |
|---|---|---|
| colenc | [0.1.3 is released](https://github.com/superbigcup325/colenc/releases/tag/v0.1.3) from `a97c230`; checked upstream `main` is `d6a892e`, with [CI passing](https://github.com/superbigcup325/colenc/actions/runs/40347165504). Registry-consumer acceptance passed on three targets for both 0.1.2 and 0.1.3 | The dedicated Roaring entry points, compact HLL registers, the sparse sketch state, t-digest changes and reusable FSST models are available. Kernel and publication work is complete; no new colenc release blocks 0.5.1 |
| moonlake | `344d739` consumes colenc 0.1.3 at version 0.5.1 without a workspace override; `main` is `a0c7628`. The [latest release is 0.5.0](https://github.com/superbigcup325/moonlake/releases/tag/v0.5.0) | C0, R2, A0/A1/A2, the 0.1.2 acceptance/baseline pair and the 0.1.3 upgrade are complete. E5 (verification §45) now belongs to 0.5.1 by decision on 2026-10-27, so the acceptance list reruns on the final candidate before release |
| moonlake verification | §41 records the full list on `95c42c6` and §44 the same list on `344d739` (colenc 0.1.3): 348 wasm-gc / 361 native / 348 js tests, goldens, differentials, corpus, large-file and playground checks, plus the archive consumer and publish dry run at `bacea04`. `4de8077` passed CI and nightly; `a0c7628` passed CI, and `9c677a8` passed CI, Pages and a dispatched nightly | The old remote-nightly failure is resolved. The 0.5.1 registry consumer and hosted-page version acceptance can only run after publication; tag and artifact identity are recorded, publication awaits authorization |

colenc owns buffer encodings, bitmap operations, sketch state and their typed
errors. moonlake owns SQL types and NULL semantics, accumulator state, memory
accounting, row identities, index validity, scan planning and file I/O. Import
`colenc/sketches` directly into the aggregate implementation when it is used;
approximate state does not belong in the reversible spill-column encoding API.

### Work order and exit criteria

C0, R2, A0, A1 and A2 are done, followed by the 0.1.2 consumer acceptance and
baseline in §41 and the 0.1.3 upgrade in §44. The earlier scope and completed R0
through R1 are preserved. A0/A1's state-cost numbers below describe colenc 0.1.1;
the current p14 register payload is 16 KiB, H0 refreshed the SQL crossover (§43)
and the sparse state it promoted is released in the dependency this tree now
consumes. E5 is implemented (verification section 45), part of 0.5.1 by decision on 2026-10-27, and the
acceptance list ran again on the candidate that carries it (verification §46). I0 remains
unimplemented and outside it.

| Task | Deliverable | Depends on | Exit |
|---|---|---|---|
| C0 | Consume colenc 0.1.1 | Published registry artifact | **Done** (verification §38): the manifest, the README instructions and the AGENTS.md notes name 0.1.1 together; `moon tree` resolves it with no workspace override, after the registry index and the cached 0.1.0 copy were cleared. The new `Encoding` / `EncodingError` variants needed no consumer edit, because the engine translates errors through `EncodingError::message` and never matches on `Encoding`. Three-target suites, page fixtures, writer interoperability, spill round trips, the goldens on wasm-gc, js and the release binary, and `check_release.py --check-consumer` with fresh caches pass. It enables APIs; it introduces no approximate SQL or automatic index |
| C3 | Consume colenc 0.1.3 | Published registry artifact | **Done** (verification §44): the manifest moves to 0.1.3, resolved from the registry with no workspace override, and no source here changed — the state change is inside the sketch. The acceptance list was rerun rather than inherited (check/format/interfaces, 348/361/348 tests, the 33 goldens on three paths, both differentials, pushdown, page fixtures, CLI, spill, writer interop, corpus 17/51/0, 75 unit tests, eleven oracles, the 2.41 GB write, 16/16 in Chromium), the H0 matrix was re-recorded against the artifact, and the eleven release cases ran against a control pinned to 0.1.2 with no case outside its own run-to-run spread |
| R2 | Refresh 0.5.1 on the final source and dependency | C0, `ae6a28c` | **Done** (verification §40): `bc1a8f5` passed the whole list again — check, format and interfaces clean, 348 wasm-gc / 361 native / 348 js tests, the 33 goldens on all three paths, the correlation differential (fixed and seeded), the window and pushdown gates, page fixtures, CLI, spill, writer interoperability, the corpus at 17 decoded / 51 refused / 0 failing, and the eleven timed cases green against DuckDB. The 2.41 GB write, the host-free wasm build, 16/16 in real Chromium and the 213-file archive consumer with fresh caches all pass. Its one open decision — the 0.1.1 artifact costing about 10% on wide CSV scans (7–14% by run; bisect and probes in `bench-baseline.md`) — is **closed** by C2/§41: colenc 0.1.2 ships the dispatch split and the re-record puts those cases 6–11% faster than the 0.1.1 control. The 0.1.2 upgrade pair has since passed CI and nightly (§41); exact registry/page-version checks remain separate release acceptance |
| A0 | Record SQL sketch semantics and aggregate-state costs | C0; before A1/A2 code | **Done** (verification §39): [docs/sketches.md](sketches.md) states input and output types, NULL and empty-input behavior, the value equivalence (type-tagged, `-0.0`/`0.0` one value, every NaN one value, strings as UTF-8 bytes, dates as epoch days), parameter validation, update/finalize, ownership and error translation, plus the measured state per group (HLL 65,536 B, t-digest 52–73 centroids) and the crossover against the exact set (about 750 distinct values per group). It reuses the one fold and states that no partial-state merge is used |
| A1 | Explicit `approx_count_distinct(expr)` backed by HLL | A0 | **Done** (verification §39): a new `Acc` variant on the same fold, so the in-memory gather, the streaming pull and the grace partitions all reach it, and the window path too. Fixed precision 14, Int64 result rounded to nearest, empty/all-NULL input 0, NULL skipped; canonicalization matches `scalar_key` (type-tagged, both zeros one value, all NaN payloads one value). 1,000,000 distinct strings: 1,010,708 (+1.07%); peak RSS 56.6 MB against 144.7 MB for the exact count and 56.6 MB for a decode-only `count(s)`. Exact `COUNT(DISTINCT ...)` unchanged, no optimizer rewrite, no partition merge. Suites cover native/wasm-gc/js; the historical grouped shape shows a smaller memory benefit (1,000 groups × 1,000 distinct: 145.8 MB against 152.8 MB) |
| A2 | Explicit `approx_quantile(expr, q)` backed by t-digest | A1, numeric and rank contract | **Done** (verification §39): compression 100, numeric input, a constant `q` in [0, 1] folded into `AggSpec.q` and validated at bind time (so an empty input or a LIMIT fails the same way), Float64 output and NULL for empty/all-NULL input. Non-finite input is a SQL error raised at the finish step, because the fold cannot raise; int64 beyond 2^53 is documented as a Double conversion rather than detected. q = 0.5 and 0.9 over 0..999,999 match the exact median and 90th percentile; peak RSS 33.9 MB against 44.4 MB for `median()`. Exact `median()` unchanged |
| E5 | Budgeted GROUP BY consumes scan batches | R2; separate from approximate SQL | Replace input collection before grace partitioning with bounded input/run buffering, retaining exact grouped answers. Compare fixed group counts over increasing inputs and separately test many groups and skew. A hot group with exact distinct/median/string state needs an explicit over-budget policy; a sketch does not bound the number of groups. Verify spill ownership, cleanup, counters and existing goldens before broadening other eager shapes. **Implemented** (verification section 45): the pulled aggregation, its shared buffer pool and a 256 KiB partition floor; E5c is partly done |
| I0 | One measured Roaring use case | C0, immutable row identity and scan-use contract | Prototype repeated predicate-set intersection on an immutable registered table and compare with an exact scan. Test selective and unselective predicates, NULLs, duplicate values, multi-batch/multi-file row identities and stale indexes. Count build/load time, query time, decoded bytes, peak RSS and index size, with build amortization. Complete the investigation even if the answer is to retain the scan |

### Semantic and memory decisions

A1 and A2 answered the two sketch questions below, and their answers are the
contract now recorded in [docs/sketches.md](sketches.md) and the evidence in
§39. The Roaring paragraph is still a proposal. Keeping the reasoning here makes
the settled choices visible next to the one that is not settled.

**HLL.** The [colenc contract](https://github.com/superbigcup325/colenc/blob/v0.1.3/docs/SKETCHES.md)
hashes typed bytes and distinguishes signed zero and NaN payloads. A SQL
adapter must define its own accepted value equivalence before feeding those
bytes: pin numeric widening, DATE representation, string encoding, signed zero
and NaN behavior against moonlake's distinct semantics. Compare the adapter's
canonical values with an exact set; use statistical trials to judge the
estimator. Matching another approximate estimator exactly is not an oracle.
The default sketch now has 16,384 byte registers, or 16 KiB of register
payload, plus object overhead; its v1 serialized state remains 16,386 bytes.
The old 64 KiB payload and approximately 750-distinct-value crossover belong to
0.1.1. One dense sketch per group can still cost more than an exact set for small
groups. H0 must measure the current SQL crossover and establish accounting before
selecting an adaptive representation or exposing a precision option.

**t-digest.** Carry the existing colenc acceptance contract forward: the 1%
interior and 0.5% tail rank-error ceilings describe its named empirical matrix
at compression 100. They are not universal bounds. Report the independent
reference comparison and order/merge spread; do not demand byte or numerical
identity with another implementation. SQL tests must validate the q parameter
even when a LIMIT or empty input would avoid every update. The current
`acc_step` cannot raise; error translation for invalid updates must be designed
alongside the fold and stream-failure contract. Windows, weighted inputs and
persisted SQL sketch states need separate contracts.

**Roaring.** The current surface accepts IDs in 0..2^31-1. Give every prototype
a checked per-table mapping, including multi-file offsets and a defined response
when that range is exhausted. Define source identity and invalidation before
reusing an index. `ScanRequest` currently carries projection and advisory
conjuncts, with no row-selection/gather contract, so a bitmap intersection alone
does not prove fewer Parquet bytes are decoded. Begin with an opt-in immutable
table experiment; persistent sidecars, automatic index selection and broader
predicate syntax wait for useful end-to-end evidence. Apply residual predicates
and preserve SQL's NULL rules and duplicate rows.

**Budgeted GROUP BY input (E5a, decided before E5b changes behavior).** Today
`streaming_agg_source` refuses a GROUP BY under `--memory`, so the scan is
collected whole and `grace_agg` sizes its partitions from `batches_bytes` of
that array. The decision below replaces the collection and keeps every answer
exact. It adds no colenc API.

1. *Buffer first, partition on overflow.* Batches come from the same
   `InputPull` the unbudgeted aggregate uses. Their estimated bytes are summed
   in 64 bits (the current `Int32` total overflows past 2 GiB, which a stream can
   reach). While the sum stays within the budget, the buffered batches go
   through `aggregate_seq` exactly as the within-budget path does today, so
   counters, results and the no-spill-store behavior of a query that fits do not
   change. A spill store is first required at the first overflow, with the
   existing "provide a spill store" error.
2. *One shared buffer pool.* Partition writers no longer each hold their own
   `budget / 4` (up to 64 of them, so up to 16 times the budget in total). They
   share one pool of `budget / 4`; when it is full, the largest partition buffer
   is flushed as a run. Retained input is at most the budget plus one scan batch
   and does not depend on the total row count.
3. *Partition count is fixed at the first overflow and derived from the budget,
   not from the input.* `P = clamp((budget / 4) / MIN_RUN, 2, CAP)` with
   `MIN_RUN` 32 KiB and `CAP` 16. Both ends were measured: 64 partitions cost
   the cheap aggregates about 20% because every batch is split that many ways,
   while 2 partitions cost `string_agg` a quarter of its time and js 100,000
   groups 15% (E5c records both tables). The cap is reached at a 2M budget and
   holds above it, so no native shape at 4M or 16M is more than 3% slower than
   the collected path, and two are faster. The cost is file count: 269 files against 78 for the same
   bytes on 4,000,000 rows at a 4M budget, which was not measured against
   filesystem limits. Growing `P` mid-stream (`hash mod 2P` refines
   `hash mod P`) stays in reserve.
4. *Skew and one oversized exact state stay exact.* A partition is aggregated
   run by run through `aggregate_seq`, so it costs its group state plus one run,
   and a hot key only unbalances I/O. The state of a single group under
   `median`, `count(DISTINCT)` or `string_agg` grows with that group's rows; a
   hard cap would turn queries that answer today into errors, so there is none.
   `--analyze` reports the partition count and, on the existing `aggregate`
   line, the group count; the buffered-bytes peak and the largest partition's spilled bytes are
   reported by `--analyze` too, as estimates. Combining partial states (which would let `count` or `sum` be
   pre-aggregated) needs a combine phase and is outside E5.
5. *Ownership.* The cleanup is registered before the first run is written and
   each run id is recorded as soon as its write returns, so a source failure, a
   spill failure or an aggregation failure all leave through one removal of
   every run written so far. The collected `grace_agg` registers its cleanup the
   same way now (it used to do so after partitioning, which leaked runs when
   partitioning or a flush failed). A failing remove does not hide the original
   error.
6. *Shapes that keep the collected path:* joins, DISTINCT, ORDER BY, window
   functions and tables that are not lazy.

`--memory` is still not a process RSS cap: group state and the grouped result
can grow, and are reported separately from retained input.

**colenc follow-through.** Its ROADMAP/NEXT-STEPS now distinguish the published
sketches from engine adoption and document the engine seam above. Retain zero
runtime dependencies and zero FFI. Further kernel changes need a consumer measurement: sparse HLL
only if per-group memory is the limiting cost, t-digest scaling/compression
changes only if the measured accuracy or merge spread matters, and additional
bitmap APIs only if I0 needs them. Preserve the recorded contracts and existing
byte/statistical gates when evaluating a new implementation.

## Next delivery after colenc 0.1.3

Every task in this table is complete and shipped in 0.5.1. E5 was added after
the scope was first written, so R3 repeated acceptance on the source that
carried it (verification §46), then recorded publication and registry/page
acceptance (§47). The table preserves the delivery evidence; the
[post-release proposal](#next-work-after-051) below is the next work order.

| Order | Task and owner | Delivery and exit |
|---|---|---|
| 1 | R3, moonlake: completed release | Reconcile current documentation and review the accepted 0.5.1 scope, now on the released colenc 0.1.3 (`344d739`, verification §44). Check version claims and the final package contents, run the archive consumer with fresh caches and no colenc workspace override, and record source/archive/toolchain identity. Run the release dry run, tag and publish only under release authorization. After publication run `harness/check_consumer.py --registry-version 0.5.1`; after the relevant deployment run playground acceptance with the exact expected 0.5.1 version. Any source change reopens its affected gates. **Source side done** (verification §46): `8297296` passes the whole list on all three targets — 355 wasm-gc / 368 native / 355 js tests, the 33 goldens on each target, the differentials, the corpus, the large 2 GiB write, the playground in real Chromium, and the archive consumer from a fresh cache at 225 files and archive SHA-256 `9521e20e…`; the version claims agree and the tree is clean. **Done** (verification §47): the dry run was accepted (202), `moon publish` answered 200 OK, the tag `v0.5.1` and the GitHub release are up, and the registry consumer check for 0.5.1 passes on native, wasm-gc and js from a fresh cache |
| 2 | H0, moonlake: current grouped-HLL baseline | **Done** (verification §43, re-measured on the released artifact in §44). `harness/bench_hll.py` sweeps 18 shapes in isolated processes with decode-only and exact-count controls, duplicates and NULL variants; against colenc 0.1.2 a sketch cost about 20 KB per group, the crossover at 1,000 groups was near 200 distinct values, and 20,000 groups of one value held 408.0 MB against 17.2 MB for the exact set. That promoted sparse sketch state, which colenc released as 0.1.3: the same matrix through the registry artifact moves those rows to 15.4 MB, 392.6 MB less, answers identically and leaves the crossover where it was. The 0.1.1 and 0.1.2 tables stay as history |
| 3 | E5a, moonlake: input-buffer and spill contract | State how to choose or grow partitions without knowing the total input size, share a budget across all partition buffers, and preserve group-key equality and exact aggregate semantics. Decide the over-budget policy for skew and for one exact distinct/median/string state before implementation. Specify ownership and cleanup on source/spill failure. Record the decision before changing behavior. **Recorded** in the "Budgeted GROUP BY input" paragraph under Semantic and memory decisions; E5b implements it and E5c measures it |
| 4 | E5b, moonlake: consume batches before grace aggregation | Replace the collected scan input with bounded partition buffering for the existing single-table budgeted GROUP BY shape. Reuse the accumulator fold and spill format; retain explicit fallback behavior for other shapes. Exact queries stay exact. This task requires no new colenc API. **Done** (verification section 45) |
| 5 | E5c, moonlake: correctness and resource evidence | Compare answers with the existing exact path and DuckDB, including empty input, NULLs, duplicate keys, DISTINCT aggregates, skew, HAVING and failure cleanup. With a fixed group/result count, grow input rows and record scan batches/bytes, wall time, peak RSS, total buffered bytes and spill bytes at several budgets. Separately vary group count and large per-group state. Retained input must stop growing with total rows; group/result state is reported separately. Run the existing target suites and spill/golden gates after the implementation. **Done** (verification section 45, `harness/bench_agg_pull.py`): the rows-grow table, five other shapes, `string_agg`, the partition-size choice and DuckDB answers are recorded. The buffered-bytes and largest-partition counters exist. On wasm-gc and js the path runs with the same counters and answers (verification section 45). Retained input is bounded by measurement on all three targets (`harness/bench_retained.py --input parquet`, verification section 45). The CSV reader's own footprint grows on wasm-gc and js and hides it there, which is why the measurement uses Parquet input. The file counts the partition cap produces were measured: 527 files run in 1.78 s against 141 in 1.77 s at 8,000,000 rows, so the split costs no wall time at these sizes, though counts above a thousand were not exercised. `string_agg` time follows the partition count and not the path (verification section 45), which is a recorded cost rather than an open question |

E5 started at `engine/stream.mbt`'s `streaming_agg_source` (which excluded a
budgeted GROUP BY) and `engine/extagg.mbt`'s
`aggregate_within_budget` / `grace_agg` (which took a collected batch array).
The exit is removal of retained scan input for this shape. Group state and the
final grouped result can still grow; `--memory` does not become a process RSS
cap through this change.

H0 promoted sparse HLL state: many small groups did dominate memory, and the
measured trade pays — 393 MB off the worst shape, with 13–95% less wall time on
the many-small-group shapes and 2–27% more on the 1,000-group crossover sweep. colenc
released it as 0.1.3 with the hash, rank, estimator, merge law and v1 bytes unchanged,
and its own record states the promotion rule, the merge combinations and the cost
matrix. C3 consumed it with a `moon.mod` bump
and no source change. An exact-small-set estimator
remains a separate decision.

FSST model reuse waits for repeated small string batches whose training cost is
visible; its first consumer must own model lifetime, held-out/drifting inputs
and fallback behavior. I0 waits for a repeated-predicate workload with immutable
row identities; count build/load cost, query cost, index size and reuse before
considering scan integration. A bitmap intersection alone cannot reduce Parquet
decoding without a selection/gather contract. Wider bitmap IDs, automatic
planner choice, larger row groups/dictionary writing and further eager shapes
retain their existing triggers.

The final step of each implemented delivery is its affected benchmark refresh,
with a same-session control and answer oracle. The completed 0.1.3 acceptance
list, its release pair and the H0 matrix are the starting baseline, not pending
work to repeat solely because the plan changed.

## Next work after 0.5.1

E6a measured the boundary the current source has: `streaming_join_source`
declines an aggregate above the join, and `streaming_agg_source` accepts only one
table, so a two-table keyed join with a `GROUP BY` above it still collects the
joined rows. With the build side, the group count and the final result fixed,
peak RSS over the scan grows from 16 MB at 1,000,000 joined rows to 154 MB at
4,000,000, while the scan, the aggregate state and the streaming join each stay
flat, and a budget set on that query raises the peak rather than bounding it
(§48). The next task is therefore **E6b: compose one supported join/aggregate
shape**. No implementation or new release version is committed by this planning
update.

| Order | Task | Delivery and exit |
|---|---|---|
| 1 | E6a: bottleneck and ownership record | **Done** (2026-10-27), recorded in §48 and in `harness/baseline/2026-10-27-e6a-join-agg.json`. Use the released 0.5.1 source as the control. Fix the build side, group count and final result size; grow probe rows and join fanout for a two-table keyed INNER/LEFT join followed by GROUP BY. Separate scan cost, resident build state, intermediate rows, aggregate state and final output. Record exact answers, wall time, peak RSS, scan/join row counts and spill counters at several budgets. Include scan-only, join-only and single-table aggregate controls. Specify deferred predicates, schema/column mapping, buffer accounting, exhaustion, early close and failure cleanup before implementation. If intermediate collection does not dominate, close the investigation and select the measured bottleneck instead |
| 2 | E6b: compose one supported join/aggregate shape | **Done** (2026-10-28), recorded in §49 and in `harness/baseline/2026-10-28-e6b-join-agg.json`. E6a demonstrated the cost (§48): the collection dominates, so start here, with the composition contract the measurement could not settle now [written below](#the-e6b-composition-contract): deferred predicates above the join, schema/column mapping into the aggregate, buffer accounting against the existing partition pool, and exhaustion, early close and failure cleanup. Feed the existing join cursor's batches into the exact aggregate fold or the budgeted partitioner, reusing their semantics and spill format. Preserve `execute`/`stream` behavior, the current budget rules and explicit fallback for unhandled join kinds, longer chains, ORDER BY, windows and SELECT DISTINCT. Keep the build side and aggregate/output state visible as resident costs; this task does not bound them |
| 3 | E6c: prove answers, lifecycle and scaling | Compare with the released collected path and DuckDB, including NULL keys/values, duplicate keys and fanout, empty sides, LEFT unmatched rows, residual/deferred predicates, HAVING, DISTINCT aggregates, skew and state that exceeds a budget. Exercise source and spill failures, exhaustion and early close with no leaked runs. With fixed build/group/result size, retained intermediate rows must stop growing with probe rows or fanout. Report the growing build/group-state cases separately. Run target suites and goldens on native, wasm-gc and js, plus the affected correlation and spill gates; exercise portable composition and failure behavior on each target and extend the packaged consumer to the new composition. Record same-session interleaved control/candidate measurements with an answer oracle, medians and spread |

Implementation entry points are `engine/stream.mbt` (`InputPull`, `JoinedPull`,
`run_agg_pull`, and since E6b `streaming_join_agg_source`, `JoinFoldPull` and
`run_join_agg_pull`, with the fold's tail shared as `fold_pulled` /
`finish_agg_pull`), `engine/exec_join.mbt`, `engine/exec_agg.mbt` and
`engine/extagg.mbt`. Reuse the existing cursor, fold, resource rigs and corpus;
no colenc API or format change is a prerequisite. The measurement matrix is
`harness/bench_join_agg.py`, which carries its answer oracle as a unit test, and
its baseline is the record §48 cites; E6b can reproduce that baseline before and
after its change with the same script and control. Use the Parquet-input control
from `harness/bench_retained.py` when the CSV reader hides retained input, and
report CSV behavior separately. Future acceptance must name its actual source;
§46–47 remain evidence for the released tree.

### The E6b composition contract

Written 2026-10-27, before any code change, because these answers decide the
implementation's signature, its counters and its failure behavior.

**The shape.** The composition applies when the query is an aggregate with no
ORDER BY, no window function and no DISTINCT, when there are exactly two join
steps whose probe is table 0 and whose join is table 1, when both key lists are
non-empty, when the kind is INNER, LEFT or FULL, and when both FROM items are
lazy base tables. That is `streaming_join_source`'s predicate with the aggregate
allowed instead of refused: one step, a kind whose output row is decidable from
the probe row and the build table, and nothing above the join that needs every
row first. The shape does not depend on a budget; the only decision this
contract takes from a budget is the build side's size, under buffer accounting
below. Every other query keeps the eager path and its memory behavior, including
a longer chain, RIGHT, SEMI/ANTI, a keyless cross join, ORDER BY, DISTINCT and a
window.

**What feeds the fold.** The probe side is `table_input_pull` with the step's
probe filter, the same pull the join stream opens. The build side is
`materialize_scan` with the step's scan pushdown, concatenated into the combined
layout with `tail_dtypes(step.out_dtypes, step.right_width)`. `JoinCursor::open`
then hands out batches of at most `JOIN_OUT_BATCH` rows in `step.out_dtypes`. A
batch reaches the fold after `bq.deferred` has been applied to it and only if
rows remain, because a zero-row batch is not a batch and a fold of nothing adds
nothing.

**No column mapping.** The cursor's output layout is the layout the fold's
expressions are bound to: the collected path hands `aggregate_within_budget` the
join's combined layout together with the same `bq.group_exprs` and `bq.aggs`, so
nothing is projected between the join and the fold. That equality is also what
rules out a second join, whose output would be a different layout.

**The tail.** After the fold the order is the one `run_agg_pull` already runs:
HAVING on the finished groups, projection, then OFFSET/LIMIT. A LIMIT never
reaches the join. A grouped result is final only after the last row is folded, so
the composed pull reads the probe side to exhaustion whenever it runs.

**Buffer accounting.** A grouped query with a budget hands the pull to
`aggregate_pulled`: batches are buffered while their estimated bytes stay within
the budget, and the first overflow routes the buffer into the fixed partition
count from `agg_pull_partitions` (two to sixteen, set by the budget with a 32 KiB
floor) whose writers share one `budget / 4` pool. A grouped query without a
budget and a global aggregate fold through `aggregate_seq` and retain nothing.

The build side stays whole, as it is for every two-table join, and it is checked
against the budget before the shape is accepted: when `batches_bytes` of the
materialized build side exceeds the budget, the query keeps the eager path,
where `join_or_spill` can partition the join instead of holding it. Accepted,
the shape holds the build side and the fold's buffer, each at most the budget,
plus the batches in flight; E6c measures that peak rather than assuming it. Group
state and the grouped result stay unbounded, and no budget means there is nothing
to check: the shape always composes.

**Counters.** `--analyze` must read the same row counts as the collected path for
the same query: `scan <probe table>` rows the probe pull was handed, `scan <build
table>` rows the build scan kept, `joins` rows the deferred filter passed to the
fold, then `aggregate` and `result`. Those five cannot differ. The spill lines
describe the plan instead, and this shape stops running `join_or_spill` for these
queries: a query that used to spill the join and then the aggregate can report
one phase afterwards, with fewer files. That is a plan change, not an answer
change.

**Exhaustion.** The cursor returns `None` once, after the probe side ends and
after FULL has emitted its unmatched build rows. The fold then produces its final
batch and the pull is not called again.

**Early close.** `execute` has no close, and the answer is one batch, so
`ResultStream` keeps handing this shape back materialized and E6b adds no stream
variant. A stream over grouped rows would still have to read to exhaustion, so a
failure is the only early stop.

**Failure cleanup.** The build scan runs before any run file is written, so a
failing build scan fails before the fold owns anything. Past that,
`aggregate_pulled` registers `remove_writers` before its first run and drops the
runs on success, on a failing pull and on a failing fold. With no store it raises
its own over-budget error, so a query that `join_or_spill` used to refuse reports
the aggregate's message instead.

**Where it goes.** `run_pipeline` tries the shape next to `streaming_agg_source`,
and the fold tail of `run_agg_pull` is factored out so both paths share it.
`streaming_join_source` and `streaming_agg_source` keep their current predicates:
the join stream still refuses an aggregate above it, and the aggregate stream
still accepts one table.

**What E6b must show.** Answers equal to the collected path and DuckDB for INNER,
LEFT and FULL over the composed shape, including NULL keys, duplicate keys,
fanout, an empty side, unmatched LEFT rows, a HAVING clause, and grouping by a
build-side column, where an unmatched LEFT row has to land in the NULL group. The
five row counters equal to the collected path's on the same query. The recorded
baseline's `join-agg` peak minus `scan` no longer growing with joined rows under
`harness/bench_join_agg.py`, and every fallback above still answering through the
eager path.

**Separate decisions.** Exact group state and the final grouped result still
have no hard cap; neither E5 nor E6 may silently switch an exact aggregate to a
sketch. A workload that exceeds the budget in one DISTINCT/median/string state
needs its own spill-or-refusal contract. The measured E5 `string_agg` cost (up
to 18%) and file counts above a thousand remain follow-ups when a caller or
profile shows them to matter. FSST reuse, I0, writer layout/dictionaries, wider
SQL types and upstream ranged reads keep their existing entry conditions;
release completion alone does not promote them.

### What composing leaves open

The contract drew boundaries on purpose and each one is settled here rather
than deleted. `ORDER BY` above the composed aggregate was lifted on 2026-10-28
(§50), and the second join step, the widest one left, is taken under the contract
below.

**ORDER BY above the composed aggregate: done (§50).** The contract excluded it
because a sort needs every row first, but the grouped result is one batch and
the eager tail sorts exactly that batch in memory, so the exclusion was
narrower than it looked. The sort moved into the tail both pull paths share,
with the eager key resolution, and the decision the contract left open went the
way §45 already ruled: a budget bounds input buffers, so a grouped result is
sorted in memory and stays unbounded rather than spilling through the run-file
pool. That lifted the exclusion for both shapes at once, and q1 now holds 35 MB
where it held 543 MB (q12: 113 → 35 MB). A second join step is what still keeps
the other TPC-H joins off the path.

**A second join step: taken (§51, §52).** It was the widest shape left, and the
mapping it was expected to need turned out to be the cursor's own layout. A
chain holds one resident build side per step, and that residency first looked
expensive enough to gate: §51 composed a chain only under a budget its sides fit,
and at SF1 and 16 MB that was q11 alone (99 → 25 MB, no spill). The gate then
turned out to be paying for an index: §52 replaced the list a build side kept per
distinct key with one contiguous row-id range, and the same ungated matrix
measured at or below the eager path everywhere, so a chain now composes with or
without a budget and only the fit check keeps a budget honest. The contract below
records the rest of what it decided, with §52 superseding its budget-only rule.

**The growing build side and group state.** Both stay resident whole, as they
were before, and E6c measures them; the chain makes the first of them larger, one
side per step, which is why the fit check sums them. §52 cut what a resident side
costs to index, and since `join_step` builds its hash join on the same cursor
that win reached the eager path too; the `RIGHT` and `SEMI`/`ANTI` forms take
the same index on their integer path, and measured neutral (verification §53).

### The chain composition contract (2026-10-28)

Written before the code change, because these answers decide the shape predicate
and what the fit check measures.

**Scope: a linear chain of any length.** `steps[i].table == i` for every step,
every `FROM` item is a lazy base table, every key list is non-empty, and every
kind is INNER, LEFT or FULL. Nothing else moves: DISTINCT and a window still keep
the eager path, `ORDER BY` no longer does (§50), and RIGHT, SEMI/ANTI and a
keyless cross join stay out for the reason they are out of a single step (they do
not pair a probe row with rows of a resident side).

**The layout question is answered by the cursor.** A step's probe layout is the
previous step's output layout, which is exactly what `JoinCursor` hands out and
what `exec_joins` feeds it, so no mapping is needed: the chain is one
`JoinCursor` per step whose `next_left` is the previous cursor's `next`, and the
fold's expressions stay bound to the last step's layout. The per-step order is
`exec_joins`': the probe filter of step `i` applies to the previous output, its
build filter at the scan of its table, and the deferred residual after the last
step.

**Every build side is resident, and that is now the cost.** A probe row finds its
matches in a whole build side, so a chain holds one per step. `join_agg_fits`
sums them against the budget, and a budget smaller than the sum keeps the eager
path, which can partition each join instead. The scans this check already read
are handed to that path for every table, so no table is read twice and the
`scan` counters are the eager ones.

**A chain composes whenever it can.** With a budget, the peak is the bound the
sides fit into, and a chain whose sides do not fit keeps the eager path, which
can partition each join. Without a budget the resident sides and the index over
each of them are the peak. §51 measured that as 32 MB more than collecting on q3
and gated the shape on it; §52 made the index a row-id range instead of a list
per key and the same matrix came out at or below the eager path, so the gate is
gone and only the fit check remains.

**What it does not do.** It does not reorder the plan: the chain is the `FROM`
order, so a query whose largest table is the last build side holds it whole. It
does not pre-aggregate between steps. It changes neither the fold, nor the spill
accounting, nor the row counters: `scan t` per table, `joins` for the rows the
fold received, `aggregate`, `result`.

### The build side swap contract (2026-10-29)

Written before the code change, because these answers decide what the routing
reads, which row order the fold sees and which counters may move.

**The problem it answers.** A chain keeps the `FROM` order, so the last build
side is whichever table was named last. q18 names `lineitem` last, joins it to
nine orders, and holds all six million of its rows and their index to match
them: that is what is left of its 326 MB once the aggregate (§54) and the index
(§52, §56) are cheap. Hashing the nine rows and streaming `lineitem` past them
holds the nine.

**The shape.** What the chain composition already accepts, with two more
conditions. The last step is INNER and its table is a lazy base table: LEFT and
FULL stay out because their unmatched rows belong to the side that would become
the hash side. The aggregate list holds neither `string_agg` nor
`approx_quantile`, whose results depend on the order rows arrive in; every other
kind is exact under reordering or, for float sums, averages and variances, equal
to within the 1e-9 relative tolerance the golden comparison already applies. A
query with OFFSET or LIMIT and no ORDER BY keeps the current path, because which
groups a window over unsorted groups keeps would change. Everything else runs the
chain as it does today.

**The decision is taken at run time, from rows.** There are no statistics to
read, so a prefix answers it. The chain of every step but the last is pulled (its
builds scanned and checked against the budget as now, the last step's probe
filter applied) and its output is collected up to a cap of 65,536 rows and, under
a budget, a quarter of the budget in bytes, whichever is smaller. There are
three outcomes:

- The prefix ends inside the cap: swap. Its rows are the hash side.
- The prefix is empty: swap, with an empty hash side.
- The prefix passes the cap: no swap. The batches collected so far are replayed
  ahead of the rest of the pull, the last table is scanned and sized as today,
  and the chain runs unchanged. A budget those sides do not fit sends the query
  to the eager path, which reads the probe table a second time; the discarded
  attempt reports nothing, so the counters are the eager ones.

The cap is a promise rather than a ratio: the swapped side is resident, so the
swap never holds more than a fixed small amount, and under a budget it is the
same kind of bound the fit check gives the other sides.

**What the swap does.** One cursor, built next to `JoinCursor` and sharing its
`IntKeyIndex` and its string-key fallback. The prefix rows are the build side;
the last table arrives as the probe through `table_input_pull`, with the step's
build filter as its scan filter; keys come from `keys_l` on the prefix and
`keys_r` on the table's batches; the residual is checked per candidate pair; and
the output is the step's combined layout, prefix columns then the table's, in
batches of at most `JOIN_OUT_BATCH`. NULL keys never match. The fold's
expressions stay bound to that layout, so nothing between the join and the fold
changes.

**What it changes, on purpose.** Rows reach the fold in the table's order
instead of the prefix's, and for one probe row its prefix matches arrive in
ascending order. That moves the first-seen order of groups, the tie order under
an ORDER BY, the order float sums accumulate in, and the point at which an
integer sum's checked add first overflows. None of those is a promise the engine
makes; they are written here so that a changed row is read as this and not as a
defect. A query whose ORDER BY is a total order answers as before.

**Counters.** The five row counters read what the collected path reads: `scan
<table>` for the streamed table is the rows its build filter kept, counted as the
pull delivers them, and it is counted even when the hash side is empty, because
the table is still streamed to its end; `joins` is the rows that reached the
fold.

**Exhaustion, early close, failure.** The stage owns no run file. The cursor
returns `None` once, when the table's stream ends; an early stop is a failure,
as it is for the chain, and the budgeted fold's own cleanup is unchanged.

**Where it goes.** The scan of the last build moves out of `join_agg_scans` when
the shape allows a swap, `run_pipeline` runs the prefix before it asks the fit
check, and `run_join_agg_pull` takes the swapped cursor as the last link of
`chain_pull`. The eager hand-off already accepts a shorter list of scans.

**What it must show.** Answers equal to the unswapped chain for duplicate keys on
both sides, NULL keys, an empty prefix, an empty table, a residual, a probe filter
on the last step and a build filter on its table; the cap boundary at exactly the
cap and one row past it; every exclusion above answering through the current path
(LEFT, FULL, a derived table, `string_agg`, `approx_quantile`, LIMIT without ORDER
BY); the golden comparisons and the five counters unchanged. The measurement is
q18 at SF1, with and without a budget, against the build before the change, with
the other TPC-H chains kept in the matrix as invariants: q3, q5 and q10 are
expected to pass the cap and take no swap, so their peaks must not move. Result
(§57): q18 fell from 325 MB to 145 MB without a budget and from 227 MB to 71 MB
at 16 MB, and the other chains did not move.

### The single-copy inner side contract (2026-10-29)

Written before the code change, because these answers decide which batches may
be released, who owns them, and what the measurement is allowed to claim.

**The problem it answers.** A decorrelated `EXISTS` or `IN` runs its inner query
as an ordinary query before the outer one starts (`run_parsed`), and a
single-table inner query is collected by `drain_scan`: the scan's batches are
pushed into an array and then concatenated into one result batch, so at the
concatenation both the scan's batches and the result exist. Verification §58
measured that as 10 bytes a cell where a column needs 5 (a derived table over two
integers of six million rows: 157.7 MB against a 35.3 MB base, twice the 61 MB
the columns need). q21 holds two such sides. The same collection serves every
collected single-table result and every derived table over one table.

**The change.** `drain_scan` concatenates column by column and lets go of each
chunk's column as soon as it has been copied, so the peak is the result plus the
columns not yet copied, not the result plus every chunk. Nothing else about the
collected path moves: the same batch is returned, with the same rows in the same
order, and an empty or single-chunk input is returned as it always was.

**Ownership.** The batch contract says a batch belongs to the caller, but a
source may hand out batches that share vectors with a table that outlives the
query (an in-memory table is scanned without copying). So the release works on a
shell the collection makes: each chunk's column array is copied into a new batch
before it is kept, and only the shell's slots are cleared. A vector nobody else
holds is freed when its slot is cleared; a vector the source also holds stays
where it is, untouched. The source's own batches are never written to.

**Scope.** The collected single-table result of `run_parsed`, which covers the
inner side of a decorrelated subquery over one table and a derived table over
one table. Not in scope, and still taken as they were: the build sides of a
chain (`join_agg_sides` concatenates scans that are kept for the eager hand-off,
which is a separate question about when that hand-off stops needing them), an
inner query that aggregates or joins (it does not go through `drain_scan`), and
the widening of keys, which §59 closed.

**Counters and answers.** Unchanged by construction: the `scan` and `result`
counters are pushed from the same places, and the batch returned is cell for cell
the one the plain concatenation makes.

**What it must show.** The release concatenation equals the plain one for several
batches with NULLs, and leaves no column in its shells; a query over an in-memory
table twice in a row answers the same and leaves the table's batches with their
rows. The measurement is q21 at SF1, with and without a budget, against the build
of §59 with q3, q5, q9, q18 and q20 as invariants, plus the derived-table probe of
§58, which should fall from 157.7 MB toward the 97 MB one copy implies. The q21
figure is not predicted beyond that: its two sides are resident one after the
other, so what falls is the larger transient, not both.

**Result (§60).** Measured and not kept: the releasing concatenation left the
derived-table probes and q21 where they were, so the two-copy reading of §58 is
unsupported and the lever is withdrawn.

### The structure census contract (2026-10-29)

Written before the change, because what is counted, where it reports and what
the number may be compared against decide whether the result answers the
question §60 left open.

**The problem it answers.** §60 left q21's inner side at about 603 MB with an
unexplained composition. RSS subtraction cannot split structures that are
resident at the same time, and the derived-table probes vary one axis at a
time. No counter in the engine reads bytes by structure, so every explanation
so far is an inference.

**What the counter is.** A per-query census, enabled only by a profiling run. At
declared points the executor records the byte size of the structures that are
alive at that point, sized from the structures themselves, and keeps the largest
point at each declared label. It is not an allocator hook and not a GC counter: the
census does not see strings, boxing or garbage the runtime has not collected, so
its total is a lower bound on the process's RSS at that point, to be compared
with the RSS a benchmark measures.

**A checkpoint never extends a structure's life.** It names only what is alive
at that moment, and nothing it reads may keep a structure alive that the plain
run would have released. The first version's collapse checkpoint named the index
and the build copy across the concatenation, which held the join cursor alive and
raised q21's peak by about 30 MB (§61): the census must be invisible in the run it
measures.

**What a checkpoint counts.** Each one is a named set of roots the engine holds
there:

- every collected `FROM` table's scan batches, by table name, at the sizes
  `estimate_batch_bytes` reports (the same estimate the budget uses);
- the batches a step is handed, the filtered copy of a side the eager path makes
  for it, and the concatenated side or output copy an operator builds on top;
- a hash index's arrays: the dense slot array, the starts and the id range, four
  bytes a cell, plus the hashed map at an estimate for its entries;
- nothing else yet: a source's decoder and file buffers, the spill store's
  pages, a grace join's partitions, the swap prefix and the group state of a
  fold stay outside this contract, so a query whose peak is one of those shows a
  census below its RSS and the gap is reported as a gap.

**Scope by shape.** The checkpoints are declared in the eager join path
(`exec_joins`, its hash joins and its semi/anti sides), which is the path q21
runs on. The pulled shapes stay uncounted until a measurement needs them.

**Where it reports.** `moonlake exec --mem` runs the query with a census and
prints a `-- resident by structure` header followed by one block per label,
largest first: the label, its total, then its entries largest first. The flag is off by default; without it no
census is built and nothing is paid.

**Answers and counters.** Unchanged: the census reads structures that already
exist, so the answer, the five row counters, the spill bytes and the result of a
`--mem` run equal the plain run's. A `--mem` run is not a benchmark: measuring
allocates and takes time.

**What it must show.** For q21 at SF1 without a budget, a largest checkpoint that
names the structures §58 and §60 could not split, its total compared with the
603 MB the harness reports and the gap stated. For a fixture whose side is small
enough to size by hand, the checkpoint equals the sizes the test computes. A
query run without the flag builds no census, and the gate suite's answers,
counters and timings do not move.

**Result (§61).** Built and measured. q21's peak is the second chain step's
output collapse (521.7 MB of a ~610 MB peak): the collected output and the batch
it becomes are live together at 2 × 100.6 MB, over that step's 174.5 MB probe
input and the 146.0 MB of collected tables. The semi sides peak lower, at 307.4
and 263.5 MB, so §58's inner-side reading was aimed at the wrong copy. About
88 MB of the peak is outside the contract, as are the grace path (a budgeted run
names only its tables) and the pulled shapes (nothing).

### The collapse single copy contract (2026-10-29)

Written after §61 named the peak, because the census says where the bytes are
and this is the smallest change that takes one of the two copies away.

**Why this is not §60 again.** §60 copied a collected result's columns one at a
time and released each one, in `drain_scan`, where the batches belong to a
source: releasing them leaves the source's shells behind and the source's data
resident, and q21 did not move. A join step's collected output is different.
`JoinCursor::slice` builds every output batch with `gather`, so a step owns its
collected output outright, and nothing else holds those columns. §61's largest
point was exactly this pair — the collected output and the batch it becomes,
100.6 MB each on top of a 174.5 MB probe input and 146.0 MB of collected tables.

**What changes.** `concat_batches_releasing`, used by `join_step` for its output
collapse only: the collapsed batch is built one column at a time and each source
column is dropped from its batch as soon as it has been copied, so the
destination grows while the collected output shrinks and the two are never both
at full width. The batches must be the caller's own; the function drops
references and never writes a source column's contents. The build-side concat
keeps the plain function: `right` may be a catalog table's own batches
(`prescanned`), and releasing those would empty the catalog.

**What it must not change.** The answer, row by row; the five row counters, the
spill counters and the plan; the answer to a query whose collected output is a
single batch (already returned as is, never copied). A column a step shares with
its build or probe side keeps its bytes where they are: dropping a reference is
sound, freeing is not promised.

**Prediction.** q21 at SF1 without a budget: the largest census point falls from
521.7 MB to about 421.1 MB (the collapse's two 100.6 MB copies become one), and
peak RSS from about 610 MB toward about 510 MB. The other chain queries
(q3, q5, q7, q8, q9, q10, q11, q12) are expected to improve where their peak is
a collapse; q1 and q6, which have no join step, and q18 and q20, whose peaks are
pulled, are invariants and must not move. If a collected column is shared with
its build side, less memory leaves than predicted; that is a result, not a
failure of the measurement.

**Result (§62).** Implemented, measured and reverted. The census's named peak
fell by exactly one copy (q21: 521.7 MB → 451.0 MB) and peak RSS did not move
(601.7 → 598.0 MB median, inside the spread; the chain queries likewise). The
high-water is therefore not at the collapse — it is reached at a moment no
checkpoint declares, or the runtime keeps freed blocks resident. The next step
is to measure the high-water itself, and to name the unnamed 82.6 MB of resident
memory, not to shrink this copy again. §63 then did measure it, and the
high-water *is* at that collapse (599.1 MB, where 497.5 MB is named): what did
not move was the process peak, because the copy's real cost there was about
57 MB against the 100.6 MB the census names.

### The chain without a collapse contract (2026-10-29)

Written after §63 put the peak at the second chain step's collapse and said the
peak follows what a run allocates and retains. §62 tried to release one of the
two copies there and moved nothing; this is the other way to have one copy —
never make it.

**What the collapse is for.** Nothing that a consumer needs. `join_step` collects
a cursor's batches and then `concat_batches`es them into one batch only because
the chain's state between steps is one batch (`acc = [join_or_spill(...)]` in
`exec_joins`). The next step's probe side already takes an array
(`join_step(acc : Array[DataBatch], ...)`), the filter above the chain takes an
array, and the aggregate and result paths consume batches. The collapse exists
for the shape of a variable, not for a reader.

**What changes.** `join_step`, `join_semi`, `join_swapped` and `join_or_spill`
return `Array[DataBatch]`; a step's collected output is handed to the next step
unchanged, and the chain collapses only where a consumer asks for one batch. The
semi/anti and swapped-right forms already build their output directly, so they
return a one-element array. The collected batches come from `JoinCursor::slice`
through `gather`, are already in `step.out_dtypes` order, and preserve row order,
so no re-layout is involved: this removes a copy, it does not move one.

**What it must not change.** Answers row by row, and every counter, in the same
order: batches are a transport here, and the joined row count is what it was.
The budget path and its partitioning: `batches_bytes` already takes arrays, and
the grace path keeps its own merge, which collapses a partition's sorted runs
into one batch — a different question from this one, kept as it is. A query
where the collected output is already one batch behaves as it does today.

**Where a collapse is still required.** A consumer that needs a single batch,
which today means the sites that call `concat_batches` on a step's output
(`engine.mbt` for the composed fold's build side, `extjoin.mbt` for the merge).
The census follows §61's rule and names only what is alive: the "hash join
collapsed its output" point disappears where no collapse happens, and a point
must not name a batch it has handed on. A label with no live structure is not
declared rather than declared as zero.

**Prediction.** q21 at SF1 without a budget: the second step's collapse copy
(100.6 MB named, about 57 MB real per §63's two neighbouring samples) is never
allocated, so the process high-water falls from 599.1 MB toward 540–560 MB, and
the census's largest point becomes "hash join collected its output (step 2)" at
430.1 MB. The other chain queries are expected to move by the size of their own
intermediates at most, and these are invariants that must not move: q1, q6, q12
(no multi-step chain), q18 and q20 (pulled shapes). Wall time must not grow by
more than the run-to-run spread; if it does, the collapse was buying locality
that many small batches lose, and that is a result to record.

**How it is measured.** verification §65: `harness/bench_join_chain.py` against
the 0.6.0 binary, plus `--mem` on q21 for the named peak and the high-water,
three runs each with the medians and the spread printed, at SF1 and with the
16 MB budget on the shapes that gate on it. It counts as success if q21's
high-water falls beyond the spread and no invariant moves beyond it; a negative
result reverts the code and keeps this record (§60, §62).

**Result (§65).** Confirmed on the shape the contract named, and it stops
exactly where the contract said a collapse is still required. Without a budget
no step copies its collected output: q21's high-water fell from 604.9 to 546.7
MB (median of three interleaved runs each, −9.6%) into the predicted
540–560 MB, its census names six points instead of nine, and the largest is
"hash join collected its output (step 2)" at 430.2 MB — the point and the size
predicted. q7 fell 112.0 MB, q20 5.1 MB, and the invariants (q1, q6, q12, q18,
q20) stayed inside the 15% spread with every wall time and every answer
unchanged. Under the 16 MB budget the collapse is still made, now at the
producer rather than by the shape of a variable, because a partitioner slices
each input batch into every partition: without it q7 ran 4.4x slower (35.6 s
against 8.0 s, 2122 MB peak), collapsing both sides inside the partitioner cost
q3 +86 MB and q5 +160 MB, and collapsing only the handover there cost q21 +98 MB
— the caller still holds the batches while the copy exists. So a budgeted run
hands on one batch a side as it always did, and that is now measured rather than
accidental.

### The table lifetime contract (2026-10-29)

Written before the change, because these answers decide when a table may be let
go, who may still be reading it, and what the measurement is allowed to claim.

**The problem it answers.** §61's census rule is that only structures alive at a
point are named, and the executor keeps every collected table alive for the whole
chain (`tables`, and the comment in `exec_joins` says so out loud). §65 then put
the process peak at the second chain step's collected output, where the census
names `collected FROM tables` at 145.9 MB of a 430.2 MB named total: 61.0 MB of
that is lineitem's narrowed copy (60.7) and supplier's (0.3), whose only step —
the chain's first — had already run by then. Nothing reads them again: the plan
is left-deep, each table appears in the step that joins it, and no re-scan
exists.

**What changes.** When a step completes, every table whose last step is that one
is released: its slot in `tables` is replaced with an empty array, so the batches
it held have no reader left. Releases happen step by step, not at the end of the
chain, because the point of the change is the peak that comes later. A table
named by several steps (a self-join) is released after the later of them, and the
leftmost table — the chain's initial `acc`, replaced by the first step's output —
is released after that step, like any other.

**What it must not change.** Answers and counters: the release runs after the
step's batches have been consumed, so no reader sees it, and a row order or count
that moves is a bug, not a trade. The plan, the spill path (`right` and `acc` are
read inside the step; a grace join partitions copies of them, and the release
waits for that to finish), and a table a later step still names. The census
follows §61: a released table stops being named from the next point on, the
`collected FROM tables` total is what is still alive, and a label with nothing
alive is not declared rather than declared as zero. The release may never be
skipped to name a table, and a point may never keep one alive.

**Prediction.** q21 at SF1 without a budget: at the peak, `collected FROM tables`
falls from 145.9 to 84.9 MB and the named total from 430.2 to 369.2 MB; the
resident sample from 539.0 toward 478 MB if the allocator reuses the released
blocks, and the high-water from 547.2 toward 490–547 MB if it does. §62 measured a
release *after* the peak and it did not move the high-water; this release happens
*before* the allocation that sets it, which is the open question and the reason
the change is worth a measurement rather than an assumption. Nothing else is
predicted to move: q1 and q12 compose one step, so there is nothing to release
before their only peak, and q3, q5, q7, q9, q10, q18 and q20 may fall by the size
of their own finished tables or not at all.

**How it is measured.** verification §66: `harness/bench_join_chain.py` against
the `a56517e` binary (`--budgets none,16M`, three rounds, the spread printed),
`--mem` on q21 as three interleaved runs each, and the per-point census table
before and after. It counts as success if q21's high-water falls beyond the 15%
spread with q1, q6, q12 unchanged and every answer byte-identical; if the named
total falls and the high-water does not, the release is withdrawn (§60, §62) and
the result says so — that would leave allocating less as the only lever, which
means composing q21's chain rather than materializing its intermediates, and that
is a different contract.

**Result (§66).** Kept, and it answers the question §62 left open. q21 without a
budget: high-water 551.2 → 491.2 MB (median of three interleaved runs each), with
the named total at the peak 430.2 → 372.0 MB and the resident sample 539.0 →
480.1 MB, as predicted; the high-water landed at the bottom of the predicted band
because the whole 61.0 MB was reused, not because the prediction was generous.
The census shows where the peak went: it is now the *first* step's point (488.3
MB, where it was already 488.8 MB in §65), and the second step's collection —
the old peak at 547.2 MB — stays below it. §62's release after the peak moved
nothing; this one, before it, moves everything, which is one rule with two sides:
a release only pays if the allocation it hands memory back to comes later. The
root the census names falls point by point as the chain lets go — 145.9 → 84.9 →
78.3 → 30.3 MB — and the 108 MB that was never named does not change. The budget
path gained too, unpredicted: q7 523.6 → 436.1 MB, q21 677.1 → 583.5 MB, q10
245.2 → 195.3 MB. Every answer byte-identical, wall times inside the spread, the
single-step invariants (q1, q12) unmoved.

### The high-water readout contract (2026-10-29)

Written because §62 falsified the assumption behind the census's presentation:
its largest declared point is not the process's peak, so a report that only
names structures cannot say where the peak is.

**What it reports.** At each declared point, in addition to the named total, the
census records the process's current resident bytes and its high-water mark, and
the report carries both: per point, its residency and the high-water at that
moment; in the header, the process's high-water and the label whose sample was
the largest. A point is where the peak happened if its residency sample is the
largest, and the difference between the high-water and that sample is memory
held at a moment no checkpoint declares.

**How it reads them.** On native, `/proc/self/statm` gives the resident pages
and `/proc/self/status`'s `VmHWM` the high-water; a page is taken as 4096 bytes.
On a target without `/proc` (wasm-gc, js, and a native platform without it) the
readout is absent rather than zero: the report prints no resident fields and the
named totals are exactly what they are today, so an absent readout never passes
for a small one.

**The rules the readout keeps.** It reads the process, never the engine: it may
not keep any structure alive, and it may not be the thing a measurement measures.
The read is a file read on the already-slowed path of a census run, and the
report says so. A residency sample is the process's, not the query's: it includes
the allocator's free lists, the runtime, and anything the host is doing.

**What it must show.** For q21 at SF1 without a budget, the point at which the
process's residency is highest, the named total there, and how much of the
high-water that point does not name. If the largest sample is a declared point,
the next clue is its composition; if no declared point reaches the high-water,
the report says so and the unnamed memory is the finding.

**Result (§63).** Built and measured. q21's high-water is set during the second
chain step's collapse (599.1 MB, the same number the harness reports), where the
named total is 497.5 MB: about 80 MB is unnamed at the peak and 92 MB less than
the high-water itself. The semi/anti points, fifth and ninth by named bytes,
hold 211 MB and 113 MB more than they name — freed heap the runtime has not
returned. With §62 this says the peak responds to what a run allocates, not to
how early a copy is released.

### The scan's per-cell cost contract (2026-10-30)

The first round whose subject is wall time rather than memory. Written before
the change because each of the three costs lives in an inner loop that allocates
nothing of size — the census cannot see any of them — and each carries a rule a
later reader could break without a test failing.

**What the code must keep.** A field's end is the first `,` or newline, found a
word at a time; the *lowest* set bit of the mask is authoritative, because a byte
above a match can also show a high bit (a 0x01 byte whose borrow came out of a
lower zero byte), so a caller that ever trusted a higher bit would read a wrong
field end. A quoted cell lives in an ascending list and is found by binary
search, so the list stays sorted and holds only cells that were actually quoted.
A batch is `SCAN_BATCH_ROWS` rows except the last, and a range never straddles a
batch: `--mem`'s per-batch accounting and the spill partitioner's slicing both
depend on it.

**The knob.** `SCAN_BATCH_ROWS` is public and was 4096 when the reader was
written. The sweep says the batch size is a cache question, not a call-overhead
one: 16384 rows a batch cost 19-35% on every query measured, and 1024 against
4096 is worth 14-25% the other way without a budget, but under one it costs 28-101 MB of peak (§68). The setting is 2048.

**How it is measured.** `harness/bench_join_chain.py --budgets none --rounds 3`
with control and candidate interleaved; the wall-time column is read as a ratio
when the host is not quiet (the harness prints the load it settled for), peak RSS
must stay inside the spread, and an answer that changes is a failure regardless of
the clock. Success is every case improving beyond the spread.

**Result (§67).** Kept. Without a budget the harness reports q1 9.64 → 8.31 s
(−13.8%), q7 8.15 → 7.02 s (−13.9%), q9 9.41 → 7.78 s (−17.3%) and q21 19.58 →
16.68 s (−14.8%) against `b3d3ae0`, every answer byte-identical and peak RSS
inside the 6% spread (two cases unmoved, q9 +18 MB, q21 −9 MB). The host load
was 3.13, so the absolute times are inflated about 2.7x and only the ratios are
read. The sweep also settled the neighbouring question: 16384 rows a batch is
recorded above as a 19-35% loss, so that nobody adopts it later as an obvious win
— the batch size is a cache question and the curve turns up hard.

**Correction (§68).** The first quiet-host matrix showed what the loaded one had
hidden: with 1024-row batches the 16 MB budget path rose on q9 by 101 MB, q8 76,
q5 66 and q3 28 (wall +12% on q8/q9), because the partitioner slices every input
batch into up to 256 pieces and four times as many batches means four times as many
pieces whose overhead `estimate_batch_bytes` does not count. 2048 gives back most of
it (q9 765 -> 699 MB) and keeps the no-budget win to within about 2%.

What this leaves is a per-row width check the scan could count as it goes, a second offset
per cell that is derivable when a chunk has no CRLF, and the three separate
lineitem scans q21 makes — the last worth about as much as this round, and a
planner question rather than a reader one.

### The partition piece cost contract (2026-10-30)

Written before the change, because it decides what the budget is allowed to count,
what a first measurement has to establish before any code moves, and what a
negative result looks like. §68 and §69 left the 16 MB path with a measured cost at
2048-row batches against 4096 (q9 +35 MB and +9.5% wall, q8 +29 MB, q5 +20 MB, q3
+16 MB) and a mechanism that is inferred from the code and the isolation run, not
measured.

**The problem it answers.** `partition_side` and `PartitionPool::add` cut every
input batch into up to one piece per partition with `take_rows`, and
`estimate_batch_bytes` prices a piece at 16 bytes plus 4 per column plus the
column's cells. A piece of a few dozen rows is dominated by what that formula
leaves out: the batch record, the column array, and per column the vector's two
arrays and their headers. Those costs belong to the piece, not to its rows, so
halving the batch size doubles the pieces a pass makes and doubles the uncounted
bytes, while the budget thinks it is holding the same amount. The batch size has
become a memory knob, which is the thing §68 said it should not be.

**What the first step must establish.** Whether the hypothesis is true, and how
large the per-piece cost really is. Before touching the estimate, measure it: build
a large number of pieces of a few rows and a few columns, read the resident
bytes before and after, and fit a fixed cost per piece and per column. If the fixed
cost is small next to the 28-101 MB gaps, the mechanism is wrong and this contract
ends with that finding and no code change (§60, §62). The same pass records how
many pieces q3, q5, q8 and q9 make under 16 MB at 4096 and at 2048 rows, so the
claim "four times as many" becomes a count.

**What changes if it holds.** `estimate_batch_bytes` adds the measured per-piece and
per-column constants. Nothing else: not the partition counts, not the flush rule,
not the batch size, and not coalescing, which the no-collapse rounds measured and
rejected. Because the estimate is what decides when a run is written, counting
more makes a budgeted run flush earlier, so it can write more and smaller runs;
the spill acceptance checks and wall time are where that would show.

**What must not move.** Every answer, byte for byte. Everything without a budget:
the estimate is read only by the budgeted paths, and a run without `--memory` must
measure identical peaks within the spread. The single-table and single-step
shapes (q1, q6, q11, q12), which do not partition a large input. The external
sort, grace join and grace aggregation equivalence checks and `harness/spill_accept.sh`.

**What is predicted.** If the per-piece cost explains the gap, the 16 MB peaks at
2048 rows fall toward the 4096 figures: at least half of the gap closed on each of
q9 (699 -> 681 MB or lower), q8 (530 -> 516), q5 (459 -> 449) and q3 (263 -> 255),
measured against the 1% spread the isolation runs showed on these cases, with wall
within that spread. Counting the cost may also leave the 4096 build ahead,
because pieces are fewer there; that is not a failure, since the batch size would no
longer be the knob that decides it.

**How it is measured.** `harness/bench_join_chain.py --budgets none,16M --rounds 3`
on a quiet host, the change against `70b60fc`, the whole 12-query matrix as in §69
so that nothing that moves unpredicted is missed, plus the piece counts and the
fitted constants above. It counts as success if the four named peaks close at least
half their gap with no invariant moved; if the peaks do not move, the estimate is
reverted and the finding is recorded.

**Left open on purpose.** The estimate also ignores the validity array (one byte a
row on every column) at every batch size; that is a per-row undercount unrelated to
the batch size and would change every spill threshold at once, so it is a separate
contract if the piece fit shows it matters.

**Result (§70).** Kept, and it did better than the contract predicted. The probe
kept 50,000 to 200,000 small pieces alive in a native process, one shape per
process so freed pages could not hide the growth, and read the resident bytes: a
piece costs about 157 bytes before its first column and 58-70 bytes a column, where
the estimate charged 16 and 4. With those constants (160 and 64) in
`estimate_batch_bytes`, the 16 MB peaks at 2048 rows fell below the 4096 figures
rather than to them: q9 699.2 -> 619.1 MB, q8 530.2 -> 471.1, q5 459.2 -> 415.2,
q3 262.9 -> 237.3 (the contract asked for half the gap), with every wall time
inside the spread and every answer byte-identical. Nothing without a budget moved,
and q1, q7, q11, q12, q18, q20 and q21 stayed inside the spread. So the batch size
is no longer a memory knob: the budget now sees what a piece costs.

### The shared table scan contract (2026-10-30)

Written before the change, because it decides what may be kept alive between two
scans of one table, who may read it, and what a negative result looks like. Every
round so far has treated a scan as something a query does once per table named in
its text; q21 names lineitem three times.

**The problem it answers.** `Correlator::finish_semi` runs each decorrelated
EXISTS / NOT EXISTS inner side eagerly through `run_parsed`, and each one scans the
lineitem CSV from the start, as does the outer chain. On a quiet host (load 1.60,
best of three, SF1) q21 without its two subqueries takes 3.23 s, with the EXISTS
4.30 s (+1.07) and in full 5.78 s (+1.48 for the NOT EXISTS); one bare
`SELECT count(*)` over lineitem takes 1.11 s. So each extra scan costs about what a
bare scan costs, and the two repeated scans are together about 2.5 s of 5.78 s. The
repeated work is indexing the same 773 MB again: a column decode added about 0.1 s
to the bare scan in the earlier measurement, so what a second scan buys is almost
entirely the index it rebuilds.

**What may be shared.** Only the decoded columns a later scan of the same table
asks for, cached for the life of one query. Not the cell index: for lineitem it is
768 MB (two offsets a cell over 96M cells), which would dwarf every number this
project has fought for, so a shared index is out of scope. The decoded columns the
three scans of q21 name are `l_orderkey`, `l_suppkey`, `l_receiptdate` and
`l_commitdate`: about 96 MB of values and 24 MB of validity bytes over 6M rows, so
the cache is a cost measured in the same units as the peak it can raise.

**Who may read it, and when it goes.** A scan reads the cache only when it asks for
columns the cache already holds in full and carries no predicate hint that changes
which rows it must see (a filtered scan reads the cached columns and filters them;
it never fills the cache from a partial pass). The cache belongs to one query: the
catalog entry is not mutated, a second query starts empty, and the cache is dropped
after the last scan of that table has run, at the same point the table-lifetime
release (§66) lets a finished table go. Under a memory budget there is no cache at
all: a budgeted run keeps scanning, because holding 120 MB there is exactly what the
budget forbids.

**What changes if it holds.** The first scan of a table that is named more than once
fills the cache with the union of the columns its later scans project; the later
scans read it. Nothing else: not the plan, not the join order, not the semi/anti
sides' residuals, not the batch size.

**What must not move.** Every answer, byte for byte. Everything without a repeated
table: q1, q3, q5, q6, q7, q8, q9, q10, q11, q12 name each table once and must show
identical peaks within the spread. Everything under a budget. The census’s rule
that only structures alive at a point are named: the cache is a new root and must be
named at the points where it is alive, and must disappear from the points after it
is dropped.

**What is predicted.** q21 without a budget falls from 5.78 s toward 3.7-4.2 s,
because the two repeated scans become reads of decoded arrays plus the cost of
filling the cache once (the outer scan still indexes the file, and so does the first
scan that fills the cache; the saving is the second index, not both). Its peak rises
by at most the cache, 120 MB, and by less if the cache is dropped before the outer
chain's peak at step 1; q18 and q20, which also repeat a table, are expected to move
by their own smaller amounts.

**How it is measured.** `harness/bench_join_chain.py --budgets none,16M --rounds 3`
on a quiet host, the change against `b62918b`, the whole 12-query matrix as in §69,
plus `--mem` on q21 for where the cache is alive and where the high-water is. It
counts as success if q21 without a budget falls beyond the spread by at least a
third of the predicted saving (about 0.5 s) with its peak no more than the cache
above the control and every invariant unmoved. If the wall time falls but the peak
rises by more than the cache, the cache is being held past its last reader and that
is a bug, not a result. If q21 does not fall, the second index was not the cost and
the change is reverted with this record kept (§60, §62).

**Left open on purpose.** Sharing one pass between consumers (a tee that indexes a
chunk once and delivers it to every scan of the file) would avoid the cache's memory
entirely, but the decorrelated sides are run eagerly before the outer query exists,
so it needs the planner to hand all three scans to one executor; that is a different
contract and is only worth writing if this one's memory cost proves too high.

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
| Exact group state and the final grouped result are unbounded | Many groups, or one large DISTINCT/median/string state, even under a small `--memory` value | E5 bounds scan-input buffers, not exact state or output (verification §45). A separate design must choose exact spilling or a clear refusal, account for skew and define output consumption; approximate substitution requires an explicit query choice. |
| The executor is not streaming end to end | Unrestricted results and queries with blocking operators | A single-table scan streams its result through `stream`/`stream_with`, and the CLI prints through it, so an unrestricted `WHERE`/projection result no longer holds its rows (verification §31: `--json` over 16 columns and 2,000,000 rows, 1,090.6 MB → 35.2 MB of peak RSS). A single-table aggregate folds the scan's batches as they arrive, so it holds its state and one batch rather than its input (verification §32: 109.7 MB → 35.3 MB). An `ORDER BY` under a budget merges its runs into batches instead of materializing the sorted answer (§33: 506.8 MB → 178.8 MB), and a two-table join probes a batch at a time with only its build side resident (§34: 270.8 MB → 35.3 MB). What still retains its input: a chain of three or more joins without a budget its build sides fit, a RIGHT/SEMI/ANTI join, a cross join, and DISTINCT or a window above a join; a `GROUP BY` above a two-table keyed INNER/LEFT/FULL join folds the join's batches instead, with or without an `ORDER BY`, a chain of the same kinds folds one cursor per step with or without a budget, and a single-table ordered aggregate sorts its groups after the fold (verification §49, §50, §51, §52). SF1 measured 159 MB for one projected column and 3.1 GB for all sixteen before any of this; §34 re-measures the join on a 16-column probe. See verification §25 for the eager measurements and §27 for the LIMIT comparison. |
| Reading is limited to flat schemas, v1 data pages, `INT32`/`INT64`/float/`STRING`/`DATE`/boolean, and the page encodings listed in the README; `DECIMAL`, `TIMESTAMP`, `INT96`, nested fields, v2 pages and the remaining codecs are refused with a pointed error | Producers that write those types | Each type or encoding needs the whole chain designed together: SQL type, CSV inference, Parquet read/write, spill format and JSON output. Starting with one of them alone tends to produce a value that is wrong somewhere later. |
| A non-equality correlation is answered by a nested loop | A correlated subquery whose predicate is not an equality over a large inner table | Keyless semi/anti joins test candidate inner rows; a scalar theta aggregate tests distinct outer combinations against inner rows. A range-aware or index-backed join needs a data layout that can answer the predicate without a scan. Start that optimization when a real query shows the cost. Verification §28 records the supported shapes and §30 the gate that now preserves their answers; §34 lists the join shapes that stay eager, and a semi/anti join is one of them (it is decorrelated into a scan first). |
| Spill reclamation declines to judge a directory it cannot prove is dead | A `--spill-dir` shared between containers, or a platform without `/proc` | Deliberate: a pid is only meaningful inside its own PID namespace, so the safe answer is to keep the directory and report it. Point each container at its own `--spill-dir`. |
| Writing is `PLAIN` values with v1 pages and one row group per 4,096-row batch; `--snappy` is the only compression choice | Output size for wide or repetitive columns | Measured on 6M SF1 rows: a per-column dictionary takes pyarrow's 288 MB to 196 MB (−32%) at no write- or read-time cost, and plain+zstd would reach 183 MB, but that needs a reader that accepts zstd. moonlake's own `--snappy` write is 289.2 MB for those rows: the 16% gap to pyarrow that this row used to name was one missing tag in the compressor (a short match close behind now costs two bytes, not three), so what is left is the dictionary, which is worth −32% and needs a per-column choice because it *grows* columns with no repetition. A second table (verification §35) prices both halves: on 500,000 rows of an access log the same per-column dictionary is worth −14% at our 4,096-row groups and −28% at 65,536-row groups, a dictionary on every column is 1.6% *larger* than plain, and the bigger group saves 1.4% of that file while costing the reader 13 MB → 57 MB of peak RSS. So the row-group size is the larger lever and the two decisions are not independent; `harness/dict_survey.py` regenerates the tables. |

## Candidates waiting for a trigger

These are not scheduled. Each one names the evidence that would start it, so a
reader can tell the difference between "not yet" and "no".

| Direction | What starts it |
|---|---|
| Cost-based optimization, automatic build-side choice | A profile showing the current plan choice is the hotspot at a realistic scale and selectivity. First step is a prototype that can be compared against the current planner on fixed queries. |
| Bit-packed validity, fewer join-time concatenations | An isolated benchmark showing a repeatable win; earlier experiments did not. |
| Adaptive dictionary write encodings, v2 pages, further codecs | The second table exists (verification §35) and it moved the first step: the encoding is worth −14% at our current row-group size and −28% at sixteen times fewer row groups, so what starts this is a decision to write larger row groups — a streaming writer change with its own read-memory cost — or an output-size complaint from a real producer whose columns are repetitive enough that a sixth of the file matters. Implementing the dictionary first would bank the smaller half of the same win. |
| `DECIMAL`, `TIMESTAMP`, explicit window frames | A semantic need with the full chain designed (see the limits table). |
| Arrow, a DataFrame API, JSONL, object storage | A real consumer and an interface contract. These stay separate adapters; the engine's own API is not a DataFrame. |
| Parallel execution, linear memory, cross-language benchmark suites | A target user and toolchain support for it. |
| Ranged reads on wasm-gc and js | Upstream exposing one: a single range-read method behind the existing file type, with the same contract the native binding keeps. `moonbitlang/async` shows the shape on native; the synchronous path and the wasm-gc/js runtime behind it are upstream's to build, so this direction waits rather than being worked on here. |

## What 0.5.1 had to clear

R1 first ran after the required implementation and investigation tasks above
were complete, on `3ab2634` (verification §36). The expanded scope passed again
in §40 and, after E5, in §46; §47 records publication, registry-consumer
acceptance and the deployed playground at 0.5.1. The checklist is the release
contract, with each run's exact source and results retained in verification:

- The manifest, library constant, generated interfaces, changelog and eventual
  tag agree on 0.5.1. Set the changelog's release date when the release happens.
- Check, format, interface freshness, the native/wasm-gc/js test suites and
  Python gate self-tests pass. Extend the independent archive consumer to use
  the new result API on all three targets, with fresh dependency caches.
- Golden queries pass on all three targets. `harness/check_all.sh` now takes
  `MOONLAKE_TARGET` (native, wasm-gc, js) and `MOONLAKE_BIN`, so the claim above
  is one script with three settings plus the built binary.
- The S0 differential, window and pushdown checks, Parquet corpus, encoding
  fixtures, CLI checks, spill lifecycle and writer interoperability pass. The
  real file-past-2-GiB check ran on the candidate. The later upgrade pair at
  `4de8077` passed a dispatched nightly, recorded in §41; the current `main`
  at `a0c7628` also passed CI. Release checks still identify their exact source.
- A complete 0.5.1 performance record is committed beside a same-session 0.5.0
  re-record (`bench-baseline.md`, last section). The LIMIT-specific records stay
  separate optimization evidence; no case changed its `sql` or its stdout hash,
  so the comparison is the same work, and the one real cost it shows is measured
  by an interleaved A/B.
- Check host-free wasm imports and drive the candidate playground in a real
  browser. After deployment, require the exact 0.5.1 version; after publication,
  run the registry consumer for 0.5.1. These are separate from local acceptance.

The release dry run, tag and publication are complete in §47.
[verification.md](verification.md) keeps source acceptance, registry acceptance
and hosted-page acceptance distinct. Future source changes need their affected
gates; this planning update did not repeat code acceptance or benchmarks.

## How to move something up this page

Open an issue with the case that is expensive: the file (or its shape and size),
the query, and the number that matters — memory, wall time, or a file that
cannot be written at all. A limit with a reproduction beats a limit with a
theory.

## Benchmarks

**The colenc kernel record and the moonlake dependency pairs are complete.**
They are different measurements; the SQL grouped-HLL crossover they left open is
§43's and §44's, and the engine has no index result to report.

- colenc's final scoreboard was regenerated on `26fb9c0`, after K0 through K6.
  Its `docs/NEXT-STEPS.md` records sketch update/merge/query/state costs and
  separates bitmap parsing from expansion. Worst encode swing was 14% native
  and 23% wasm-gc; compare within that record rather than combining noisy runs.
- moonlake's initial final-candidate record is on `bc1a8f5`, beside the
  same-session `3ab2634` re-record. Those files retain the history of the 0.1.1
  cost; §41 supersedes that open decision.
- The dependency pair is recorded at `4de8077`:
  `harness/baseline/2026-10-26-colenc-0.1.2.json` (`95c42c6`) and
  `harness/baseline/2026-10-26-colenc-0.1.1-control.json` (`bc1a8f5`, built in
  its own worktree) are the first of three alternating pairs. CSV cases were
  6-11% faster in every round with identical answer hashes. The 4 ms/11 ms
  Parquet cases had spreads up to 73% and remain unresolved.
- The SQL sketch measurements in `docs/sketches.md` and §39 used 0.1.1; H0
  refreshed them against 0.1.2's dense representation (§43) and again against the
  released sparse 0.1.3 (§44), which is the state this tree carries: grouped RSS,
  timings and the crossover are measured, not inferred. I0 has no engine evidence
  yet.

Refresh the affected benchmark last after H0, E5 or a promoted conditional
investigation; keep revision/toolchain/data identity, isolated resource costs,
answer or accuracy checks and spread beside the result.
