# Roadmap

**0.6.1 is released** — `superbigcup325/moonlake@0.6.1` on mooncakes, the annotated
tag `v0.6.1` on `ec63c74`, a GitHub release, and the deployed playground passing
16/16 at exactly 0.6.1 (verification §83). The number is the owner's decision of
2026-10-31: the plan shapes, the census output and the order of unordered rows are
visible changes, but no public signature moved and the previous behaviour was never
promised, so a patch carries it. It ships eleven changes: the budget's unit split
from the census' (§78), both halves of the one-sided spill (§81, §82), census points
for a replayed partition and a swapped step (§79, §82), the eager fold's and the
shared scan's points, the empty-grace-partition fix (§77), and the batch-size and
scan work the measurements below stand on.

**What the release measures.** The whole TPC-H set was swept against 0.6.0 before and
after: 61 of 66 cases are faster (§85) — q2 at 64 MB 13.77 -> 2.05 s, q8 at 16 MB
4.32 -> 1.76 s with its peak 503 -> 290 MB, q9 -50% with the peak -41%, q21 at 16 MB
12.34 -> 6.37 s. Three moved the other way and are recorded rather than smoothed
over: q13 by 1-6.5% (now +2.9% unbudgeted and a win at both budgets, §90), q19 at 16 MB by 95% (the scan's batch size decides the
partitioner's cost, and the batch size is chosen for the cache — §85), and five
unbudgeted peaks grew as their queries got faster (q15 41 -> 239 MB for -55.7%,
§86).

**A residual stopped re-evaluating the side that does not move.** The join cursor
rebuilt both sides' residual masks for every probe batch, so a build side of 200,000
rows against 2,930 probe batches cost 1.76 billion tri-state evaluations — q19's 128 s.
Each half is now evaluated once (§92): q19 is 128.5 -> 3.8 s unbudgeted and 3.7 s at
every budget (17.8x against 0.6.0). The 16 MB sweep against 0.6.0 turns from 61/66 to
21/22 faster: q19 -94%, q2 -76%, q21 -49%, q7/q9 -55%. The partitioner also stopped paying a gather per partition per scan batch (a
`budget / 4` chunk before routing, worth 24% on q7 at 16 MB and 10% on q9, peak 0.0%).
The record's own attribution was wrong and is corrected: q19's 2x was never the
budget's, and §85's "+66 s at 16 MB only" was the same defect seen once.

**The budget's byte count got 10% cheaper to ask.** `estimate_batch_bytes` summed a
string column one `Scalar` at a time; it now reads the column's array (§90), which is
worth 11% on q2 at both budgets and 5% on q13, with no fit decision changed and no peak
moved. The sweep's one regression against 0.6.0 was q13: it is now +2.9% unbudgeted and
-3.1% / -5.3% at 16 MB and 64 MB.

**Three directions were written as contracts and refused on their own measurements**
in the same session: the early semi/anti reorder (§84), the coalescing partition
router (§85), and the spilled tee (§88) — the last because a table that is cheap to
parse pays the tee's two extra passes instead of saving a decode, and the engine has
no plan-time signal to tell the two apart. A fourth measurement stands behind them:
setting any budget at all costs a query 45-88% even when nothing spills, and three
attempts to attribute that (§89) did not find it.

**Where a budget goes, measured rather than guessed.** An ablation of the spill machinery
(§91) puts half of q2's and 40% of q7's time at 16 MB in the partitioner and the swap, for
a peak change of 0.0% — and 71% of q9's peak at the same price, so the machinery does pay
where the join sides are what grows. What separates the two is a prediction the engine
cannot make yet.

The [delivery after colenc 0.1.3](#next-delivery-after-colenc-013) is complete;
H0, C3, E5 and R3 closed it as 0.5.1. What the next delivery is worth is now
measured rather than guessed: the budget path's unexplained 2x (§89), q19's 62 s
(§85), and the unbudgeted peak (§86) are the three numbers a contract should be
written against. FSST reuse and Roaring index integration retain their workload
triggers.


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

**Result (§71).** Kept, with one cost named. q21 without a budget fell from 5.30 to
2.94 s (-44.5%, quiet host, three interleaved rounds) with its peak unchanged
(504.3 -> 503.8 MB), better than the predicted 3.7-4.2 s: the cache is dropped after
the last expected open, before the outer chain reaches its step-1 peak, so it never
sits on top of it. q18 fell 3.30 -> 2.15 s and paid for it, 149.4 -> 231.3 MB, which
is the contract's own bound at work (its two lineitem scans keep the decoded columns
alive between them). The first matrix also moved q11 by +33% wall, which the contract
had not listed: the engine opens a table more often than the statement names it, and
each open past the expected count refilled the cache; those opens now pass through.
Under a budget and everywhere a table is named once nothing moved, and every answer
is byte-identical. Owed: the census must name the cache where it is alive.

### The census names the shared scan cache contract (2026-10-30)

Written before the change, because §71 left a debt and, while paying it, the code
reading turned up a second one that changes what the debt means. The rule the
census lives by (§61) is that it names the structures alive at a point, and that a
point never keeps one alive.

**The two debts.** First, the shared scan cache (§71) holds the decoded columns of a
table named twice, and no census point names it, so q18's +81.9 MB and q11's +18 MB
of peak are memory the report cannot show. Second, and found while reading the call
sites: `mem_report_with` and `explain_analyze_with` call `run_parsed` directly,
without `share_repeated_scans`, which only `run_select_opts` and
`run_select_stream_opts` call. So `--mem` and `--analyze` have been running the
unshared plan since §71 landed: they do not measure the run the plain query makes,
and a census of q21 would not contain the cache even if it were named. Naming a
cache the measured run never builds would be a census of nothing.

**What the change must do.** (1) The two measuring entry points build the per-query
catalog the plain entry points build, so a census run executes the same plan as the
plain one. (2) The census keeps a list of live roots, each a function returning the
bytes it holds right now; `share_repeated_scans` registers one per shared table when
a census is present. `observe` appends one entry per root that holds anything,
named `shared scan cache (<table>)`, at every point, so the cache is named exactly
between the fill and the drop and disappears from the points after it. The size is
`estimate_batch_bytes` over the cached batches, like every other root. A point still
never stores a reference to what it sizes. Nothing changes without a census: the
root list exists only on a `MemCensus`, and a plain run builds none.

**What it may not claim.** `estimate_batch_bytes` counts cells and the fixed
overhead of §70, not the validity bytes (one a cell, listed as open in §70), so the
named cache is a lower bound and the census says so by being named like the others,
whose totals are lower bounds too.

**What must not move.** Every answer, byte for byte, with and without a census.
Every plain run: peaks and wall times of the whole matrix are unchanged, because the
plain entry points are not touched. Every census run of a query that names no table
twice: its points and entries are identical to before.

**What is predicted.** q18: its census names the cache at the points that sit
between its two lineitem scans, at about 72 MB (6,001,215 rows of `l_orderkey` at 4
bytes and `l_quantity` at 8), against the 81.9 MB of peak §71 measured; the rest, about
10 MB, is the validity bytes the estimate does not count. q21: the cache is named at
the points inside the decorrelated sides and absent from the outer chain's step-1
point, which is why its peak did not move. q11: a root of a few MB at most. And the
`--mem` high-water of q21 and q18 should now agree with the plain run's peak within the
spread, where the unshared census would have reported q21 near 504 MB for a plan the
plain run no longer runs.

**How it is measured.** `--mem` on q18, q21 and q11 before and after, the plain
matrix `harness/bench_join_chain.py --budgets none,16M --rounds 3` against `31233bb`
to show nothing moved, and a unit test that a census over a table named twice has a
point naming the cache and a census over a table named once has none. It counts as
success if q18's named cache is within 15% of 72 MB, the cache is absent from the
points after its drop, and the plain matrix is inside the spread. If the census
high-water of q18 does not rise toward the plain peak once the cache exists, the
measuring entry points still differ from the plain ones and that is the finding.

**Left open on purpose.** A tee that shares the index instead of the decoded
columns, which would remove the cache and this contract with it, and the validity
bytes in `estimate_batch_bytes`.

**Result (§72).** Kept, and two of its predictions were wrong. The measuring entry
points now build the plain run's catalog, and `--mem` names the cache: q18 at
72,858,708 bytes (1.2% from the 72 MB predicted), q21 at 97,238,736, q11's three caches
at 16.2 MB. But the cache is never alive at a point the census already declared (q11
and q18 reach none, q21's is gone before the outer chain's first), so it needed a
point of its own, at the fill; a root read only at existing points would have named
nothing. And the census high-water does not agree with the plain peak (q18 138 MB
against 231 MB), because only declared points are seen. The plain matrix did not move.

### The pulled shapes declare census points contract (2026-10-30)

Written before the change, because it decides which structures a pulled shape is
allowed to name, how a root that borrows an owner's structure is kept from keeping it
alive, and what this round is allowed to measure. It is the contract §72 said was
owed: q11 and q18 reach no declared point at all, so `--mem` prints nothing for them,
and the census high-water on the one point q18 does have (138 MB) is far from the
plain run's peak (231 MB).

**The problem it answers.** The census points live in the eager executor
(`exec_joins`, the semi/anti inner side, the collected FROM tables). A shape the
router sends elsewhere never reaches them: `run_agg_pull` (a single-table aggregate
fed from the scan), `run_join_agg_pull` (a join chain folded into an aggregate, which
is q18 and q11), and the runs the binder makes at bind time for a non-correlated
scalar or IN subquery (`run_parsed` with no census, so q18's `lineitem` group-by and
q11's threshold subquery are invisible). What the composed shape holds is known from
the code: every build side whole (`scans`), a padded concatenated copy of each
(`builds`), one key index per step inside its `JoinCursor`, one probe batch in
flight, and the group state of `aggregate_seq`. The census names none of it.

**What the change must do.** Three declared points, nothing else:
(1) `composed join fold started`, kept once the build sides, their copies and the
cursors exist and before the first probe batch is pulled, naming `build sides`,
`build copies` and one `index arrays (step N)` per step; (2) `pulled fold finished`,
kept when the fold returns, naming the structures still alive (the build sides and
indexes of a composed shape) and `group result`, the finished groups; (3) the
bind-time subquery runs receive the census, so a point inside them is kept like any
other and carries its own label. A single-table pulled aggregate keeps only (2).
The group state *during* the fold is not sized by anything the executor can read
without a new accessor, so `group result` is a lower bound for it and the point says
so by name; adding that accessor is out of scope.

**How a root borrows a structure without keeping it alive.** A cursor's index is
read through a root registered on the census (the live-roots mechanism of §72). A
closure that captures a cursor keeps its index alive for as long as the census does,
which is the one thing a point may never do. So every root registered by a pulled
shape is removed when its owner finishes (`MemCensus::remove_root`), at the end of
the fold, and the point (2) reads the roots before they are removed. A plain run
builds no census, registers no root and calls none of this.

**What it may not claim.** The named bytes are `estimate_batch_bytes` plus the index
bytes the join census already reports, so they are lower bounds, as at every other
point (the validity bytes stay open from §70). The census high-water is a sample
taken at declared points; it is not a profile of the process.

**What must not move.** Every answer, byte for byte, with and without a census. A
census of any query that reaches the existing points: its points and entries are
identical (q21's six labels and their bytes, to the byte, plus the shared-cache point
of §72). Plain runs: nothing here executes without a census, so a plain run is
unchanged by construction, and the evidence for that is the goldens and the unit
tests, not a clock.

**What is predicted.** q18's composed fold names its lineitem build side (the 6M-row
`l_orderkey` and `l_quantity` columns, about 72.9 MB, the same arrays the shared
cache held and still shared with it), a concatenated copy of the same size, and a
key index of tens of MB, so the point sits well above 150 MB and the census
high-water of q18 comes within 25% of the plain run's 231 MB peak. q11's composed
fold names its few-MB build sides and no more. The bind-time subqueries show up as
points of their own. A single-table pulled aggregate such as q1 names only its group
result, a few KB, which is the honest answer for a shape that holds one batch and its
state.

**How it is measured.** `--mem` once on q18, q11, q1 and q21 before and after, read
as named bytes (they are deterministic; a resident sample printed beside them is not
read as a claim), plus unit tests that a census over a composed join-aggregate has the
two points with the roots named and that every root is gone after the fold, and the
goldens, the CLI and spill checks, and both unit suites. No benchmark harness and no
wall-time comparison is run for this change: the host's timing is not stable enough
to read, and nothing here is timed. It counts as success if q18's census high-water is
within 25% of its plain peak, q21's census is unchanged to the byte, and no root
outlives its fold. If q18's high-water stays far from 231 MB, the unnamed remainder is
the finding, and the next step is the group state accessor rather than another point.

**Left open on purpose.** Sizing the group state while it grows, the validity bytes,
and a tee that removes the shared cache and its root altogether.

**Result (§73).** Kept, with the q18 prediction wrong and its fallback taken. The pulled
shapes keep `pulled fold finished`, a composed join keeps `composed join fold started`,
and bind-time subquery runs carry the census; q21's census is unchanged to the byte and
no root was needed, because the bytes are handed to the census as numbers. q11 now
reaches points (a composed fold of 244 KB, a result of 640 KB). q18 does not compose: its
outer join is swapped and declares nothing, and the single point it prints is its
subquery's, so the census high-water (236.9 MB) lands within 2.4% of the plain peak at
a point that names only 90.9 MB. The unnamed remainder is the group state while the fold
grows, which is what the contract said to build next.

### The group state is sized while a fold grows contract (2026-10-30)

Written before the change. §73 ended with a number it could not explain: q18's census
names 90,858,996 bytes at its one point while the resident sample there is 236,820 KB,
so about 146 MB of that moment belongs to the group state of the bind-time subquery
(`SELECT l_orderkey FROM lineitem GROUP BY l_orderkey HAVING sum(l_quantity) > 300`,
1,500,024 groups), and nothing sizes it. `group result` names the finished 18.0 MB batch,
which exists only after the state has been dropped. This contract is the accessor §73
said was owed.

**What the fold actually holds.** `aggregate_seq` has two group states: the column-wise
one (`aggregate_cols`: one `Map[Int64, Int32]` of group slots, an `Int64` key array, and
per-aggregate `Int64`/`Double`/`Int32` arrays indexed by group), and the boxed one (two
`Array`s per group, one of key scalars and one of accumulators). Both live between the
first batch and the last, and neither is reachable from outside `aggregate_seq`.

**What the change must do.** `aggregate_seq` takes an optional census, and, for each
input batch, observes one point at the end of that batch's row loop, labelled
`group state (fold)`, naming what is alive at that moment: `key slots (estimate)` at the
join census's 24 bytes an entry, `group keys` and `accumulators` (the columnar arrays by
their lengths, or the per-group arrays at an estimate), and `input batch` through
`estimate_batch_bytes`. The label is fixed, not per group count: one label per count
would make the point set grow without bound. Since the arrays only ever grow, the largest
point at that label is the end of the fold, so the census reports the state at its
largest without a second mechanism. Only the pulled folds pass a census
(`fold_pulled`, from `run_agg_pull` and `run_join_agg_pull`); the eager folds keep
passing none and are unchanged.

**What it may not claim.** Map slots and the boxed per-group arrays are estimates, named
as such. The key and accumulator arrays are counted by element size, which is exact for
them. The point says where the group state was large, not what the process did.

**What must not move.** Every answer, byte for byte, with and without a census. Every
plain run: nothing here executes without a census, so plain peaks and wall times are
unchanged by construction, and the goldens and the matrix are the evidence rather than
the reasoning. Every existing point: `pulled fold finished` keeps naming `group result`,
and q21's census stays byte-identical.

**What is predicted.** q18's fold names about 36 MB of key slots (24 bytes over 1,500,024
groups) plus 12 MB of key array and the accumulator arrays, so between 60 and 80 MB, and
q18's named total at its largest point rises from 90.9 MB to roughly 150 MB, close to the
236.8 MB the RSS sample reads. q1's fold names a few hundred bytes (four groups). A fold
over 1.5 million groups costs one observe per batch, a few thousand times, which a
`--mem` run can afford and a plain run never does.

**How it is measured.** `--mem` on q18, q1, q11 and q21 before and after, read as named
bytes and samples (the samples are not claims); a unit test that a census over a grouped
pulled aggregate has a `group state (fold)` point naming key slots and accumulators; the
goldens, the CLI and spill checks, and both unit suites; and the plain matrix against
`b9ea01a` on the quiet host, which this change cannot move but which guards the claim
that it does not. It counts as success if q18's named total at its largest point lands
within 25% of the resident sample there, q21's census is unchanged to the byte, and the
matrix is inside the spread.

**Left open on purpose.** The swapped join-aggregate path (`run_join_agg_swap`), which
still declares no point, the eager folds (no census reaches them), and the validity
bytes in `estimate_batch_bytes`.

**Result (§74).** Kept, with its success criterion missed and its fallback named. The fold
now keeps `group state (fold)` per batch: q18's state is 65,993,312 bytes (inside the
predicted 60–80 MB), its largest point rose from 90.9 MB to 138.9 MB against a predicted
~150 MB, and that point is now the resident peak. But 138.9 MB against a 236.9 MB sample
is 58.6%, not the 25% the contract asked for. Of the ~98 MB left, 12.0 MB is the validity
bytes `estimate_batch_bytes` omits and the rest is unattributed; the largest candidate is
the group slot map, estimated at 24 bytes a group where a real hash table may cost two or
three times that, and measuring it is the next contract. The CSV reader indexes one chunk
at a time, so it is not part of the answer.

### The slot map cost contract (2026-10-30)

Written before the change. §74 left q18's peak at 138,876,884 named bytes against a
236,880 KB resident sample, and named its own largest suspect: the group slot map, which
the census reports at "twenty-four bytes an entry" — a constant inherited from the join
index and never measured. At 1,499,848 groups that is 35,996,352 bytes; if a MoonBit
`Map[Int64, Int32]` really costs two or three times that, most of the 98 MB gap is this
one number being wrong.

**What is measured.** The real cost of the two maps the census estimates:
`Map[Int64, Int32]`, the group slot table and the join index's `slots`, and
`Map[String, Array[Int32]]`, the join index's string half (`str_map_bytes`, which already
counts its per-key arrays separately and adds 24 bytes an entry). A probe process fills
one map with `n` entries and reports the resident delta over `n`, for
`n` = 100,000 / 500,000 / 1,500,000 / 3,000,000, three processes each, one size per
process: a freed page is reused by the next allocation, so two sizes in one process
would report the second one's cost as near zero (the mistake the piece probe made, §70).
The probe fills sequential `Int64` keys, which is the shape a `l_orderkey` group key and
a dense join key both have.

**What the number means.** The map grows by doubling, so a filled map holds up to twice
its entries in capacity; the measured bytes per *filled* entry therefore include that
slack, and so does what the census reports, because the census counts filled groups. The
measurement is resident bytes, which include the allocator's rounding, and that is also
what the resident sample in `--mem` counts, so the two are comparable.

**What the change must do.** Replace the 24-byte constant with the measured one, in the
two places the census names a map: `IntKeyIndex::map_bytes` and `str_map_bytes`, and the
fold's `key slots (estimate)` entry. Only those. `grep` shows neither number feeds a
decision — `join_agg_sides_bytes` sums batches, and every budget is counted in
`estimate_batch_bytes` — so this cannot move what a query does, only what a report says.

**What must not move.** Every answer, every plain run, and every decision: no budget, no
spill threshold, no compose choice reads these numbers. Wall times are unchanged by
construction, and the matrix is run as evidence rather than as a measurement of this
change.

**What is predicted.** 40 to 64 bytes per entry for the `Int64` slot map, so q18's
`key slots` entry rises from 36.0 MB to between 60 and 96 MB and its largest point from
138.9 MB to between 163 and 199 MB, against a 236.9 MB sample. If the measurement lands
at or below 24 bytes the constant was right and the gap is somewhere else, which the
verification records rather than explains away.

**How it is measured.** The probe's output at four sizes and three processes each (the
spread is the evidence, not one run); `--mem` on q18, q11, q21 and q1 before and after;
and the gates: both unit suites, the goldens, the CLI and spill checks. It counts as
success if the per-entry cost is stable within 10% across sizes and processes and q18's
named total at its peak covers at least 70% of the resident sample there, or the
remainder is attributed to a structure the census can name.

**Left open on purpose.** The validity bytes in `estimate_batch_bytes` (§70), the eager
folds that no census reaches, and the swapped path's own points.

**Result (§75).** Kept: the twenty-four-byte guess was low by two to three times. A probe
measured 63/69/60/48 bytes per filled `Map[Int64, Int32]` entry at 100 thousand to three
million entries, identical across processes; `SLOT_MAP_BYTES = 60` replaces the guess in
the three places the census names a map, and nothing reads those numbers but the report.
q18's largest point rises from 138.9 MB to 192.9 MB and covers 80.7% of the resident
sample there, meeting the 70% criterion; q21's step point rises to 417.6 MB. The
stability criterion is not met across sizes (a 30% range, one constant cannot follow it),
which is recorded rather than smoothed over. The plain matrix against `ed4b9af` is inside
the spread with identical answers.

### The validity bytes count contract (2026-10-30)

Written before the change. `estimate_batch_bytes` is the unit every memory decision in
this engine is counted in — the spill thresholds, the compose-or-eager choice, the piece
sizing of §70 — and it counts a column's cells and two fixed overheads but not the
validity array every column carries: one byte a cell. §70 listed it as open, §74 and §75
both left it as the one component of q18's remaining gap that arithmetic can name (12.0 MB
over 6,001,215 rows and two columns).

**Why this one is not report-only.** The map constant of §75 changed what a report said.
This constant changes when a budgeted run flushes: count a cell at five bytes instead of
four and the same budget holds a fifth fewer rows, so a spilled case spills sooner. An
Int32 column goes from 4 to 5 bytes a cell, an Int64 from 8 to 9, a Bool from 1 to 2, and
the `BATCH_FIXED_BYTES`/`COLUMN_FIXED_BYTES` constants of §70 stay as measured.

**What the change must do.** Add one byte per cell per column, which is the validity
array's own size, and nothing else. The alternative — leaving the estimate and naming the
validity bytes only in the census — is refused here because the estimate's job is bound
memory, and a bound that omits a byte a cell is not a bound; but the refusal is only worth
anything if the measurement below shows the tighter bound costs little.

**What must not move.** Every answer, byte for byte; every golden; the spill acceptance
checks; and the resident peaks of the budgeted cases, which may fall a little but may not
rise. The no-budget cases must not move at all: `join_agg_composes` short-circuits on a
zero budget and the eager path never consults the estimate.

**What it may cost, and the bar.** A budgeted run now flushes earlier, so wall time may
rise. The bar: every 16 MB case's wall time stays within the matrix's own spread (10% this
session) of the control, and every peak stays at or below the control's. If any 16 MB case
regresses past the spread, the change is rejected, `estimate_batch_bytes` goes back, and
this contract's result records the number that made the tighter bound not worth it.

**What is predicted.** The 16 MB peaks fall slightly (a case holding 16 MB of estimated
bytes now holds about 10% fewer real bytes); wall time rises 0 to 3% on the spilled cases
and not at all elsewhere; no-budget cases are identical. In the census, q18's fold point
rises by 12.0 MB (the cached 6,001,215 rows over two columns) and the `input batch`
entries rise by their validity bytes.

**How it is measured.** The plain matrix against `8e32215` at no budget and 16 MB, three
rounds, on a quiet host; `--mem` on q18 before and after; the goldens, the spill
acceptance script, the CLI checks, and both unit suites. It counts as success if no 16 MB
case regresses past the spread and q18's named bytes rise by the arithmetic 12.0 MB.

**Left open on purpose.** The eager folds and the swapped path, which still declare no
census point, and the tee that would remove the shared decode cache altogether.

**Result (§76).** Rejected, and the rejection found a latent crash. Counting the validity
byte cost 0.5 to 2.8% of wall time on the spilled cases and *raised* two peaks by 10 MB
(more partitions, each with its own buffers), contradicting the prediction; and q21 at
16 MB aborted with a `PanicError` inside `join_semi`, because a partition with an empty
inner side reaches `concat_batches([], [])`, which has no columns to index. That crash is
latent and predates the change — a larger partition count only made it likely — so the
estimate is back as it was and the crash is the next contract, before this one is retried.

### The empty partition contract (2026-10-30)

Written before the change. §76 measured the validity bytes and found, on the way, that
q21 under a 16 MB budget aborts outright: `PanicError` at `Array::at[ColumnVector]` in
`join_semi`, reached from `join_step` inside `join_partitions`. The cause is one call:
`join_semi` builds its inner side with `concat_batches(inner, [])`, and `concat_batches`
only knows how wide to make an empty batch from the dtype list it is handed. Handed an
empty list it returns a batch with no columns; handed a zero-batch inner side — a grace
partition with no build rows, which is ordinary when the partition count is larger than
the number of distinct keys — `eval_vec` then indexes column zero of nothing.

**Why it is latent, and why it is worth its own round.** The crash predates §76: any
partition that ends up empty crashes, and the partition count depends on the estimate,
the budget and the data's key distribution, so a different budget, a different constant
or a skewed table reaches it. §76 reached it by making partitions smaller, which is
exactly the direction memory work keeps going. A crash inside a join that only some
budgets hit is worse than a slow query, so the estimate change waits behind this.

**What the change must do.** Give the concatenation the inner layout's dtypes —
`tail_dtypes(step.out_dtypes, step.right_width)`, the same expression the probe side and
the residual already use — so a zero-batch inner becomes an empty batch of the right
width, and the semi/anti join answers correctly instead of reading past its columns. No
other call site needs it: every other `concat_batches` in the engine either passes a
dtype list or returns the single batch it was handed.

**What must not move.** Every answer and every golden; the plain matrix's peaks and wall
times; and the behaviour of a non-empty inner side, which the fix does not touch. A
semi join over an empty inner must return no left rows, and its anti twin must return
every left row except where a NULL key rules it out — the same rules `join_semi` already
documents.

**What is predicted.** q21 at 16 MB completes and returns the control's rows (up to the
last-digit sum order the spill path already has); the four other 16 MB cases that differed
only in float order stay as they are; and with the §76 estimate re-applied locally and
uncommitted, q21 at 16 MB completes there too — which is the evidence that the crash, not
the estimate, was the blocker.

**How it is measured.** A unit test that forces a semi join through the grace path with a
partition smaller than the partition count (a tiny budget against a small fixture), for
both the semi and the anti flavour, comparing against the unbudgeted answer; the q21
16 MB reproduction before and after; both unit suites, the goldens, the CLI checks and the
spill acceptance script; and the plain matrix, which must not move.

**Left open on purpose.** Re-attempting the validity bytes afterwards, the eager folds and
the swapped path's census points, and the tee.

**Result (§77).** Fixed with one expression: `join_semi` now concatenates its inner side
with `tail_dtypes(step.out_dtypes, step.right_width)`, so a zero-batch inner side becomes
an empty batch of the right width instead of one with no columns. Two thousand distinct
keys against four reproduced the abort at every one of 512/1024/2048/4096 bytes on
`ffbbe7c` and none on this change; the new test fails on `ffbbe7c` and passes here, at
414 wasm-gc and 428 native; the plain matrix is inside the spread with identical answers.
With §76's estimate re-applied locally, q21 at 16 MB now completes and matches the
unbudgeted answer, so the estimate is unblocked and owes only its own measurement.

### The resident bytes contract (2026-10-30)

Written before the change. Two rounds have now said the same thing from opposite sides:
§76 added the validity array to the budget unit and the measurement said no (peaks rose,
walls rose, and the bar rejected it), and §74, §75 and §76 all left "the validity bytes"
as the largest component of q18's unnamed gap. The resolution is that the two numbers
have different jobs and should stop sharing one.

**The two jobs.** The budget unit is a *conservative* bound: it decides when a run
flushes and how many partitions a join makes, and §76 measured that counting the validity
byte in it costs more than it buys (0.5 to 2.8% of wall time, and two 16 MB peaks 10 MB
higher, because a bigger total means more partitions and each partition carries fixed
buffers). The census is a *report*: it says how many bytes a structure holds, and a report
that omits a byte a cell is simply wrong. So the bound keeps the unit that measured
better, and the report gets the truth.

**What the change must do.** Add `resident_batch_bytes` — the existing estimate plus the
validity array, one byte a cell per column — and use it wherever the census names a
batch: the fold's `input batch`, the join's `probe input`, `build copy`, `join output`,
`collapsed output`, `inner copy` and `probe copy`, the composed path's `build sides` and
`build copies`, the pulled fold's `group result`, the `collected FROM tables` entry, and
the shared scan cache's root. `estimate_batch_bytes` and `batches_bytes` keep their
current definition and every decision keeps calling them: the budget, the partitioner,
the sort's run sizing and the swap path's check.

**What must not move.** Every answer and every golden; every plain run's peak and wall
time, because nothing a decision reads changes; and `--mem`'s behaviour (the points and
their labels stay, the numbers they name grow).

**What is predicted.** q18's `shared scan cache (lineitem)` rises from 72,858,708 by the
6,001,215 rows' validity bytes (12.0 MB over two columns), so its fold point rises from
192,871,412 to about 204.9 MB — 85.7% of the 239.0 MB resident sample there, against 80.7%
before. q21's step point rises by the validity of the structures it names. Smaller points
move by their own few hundred bytes. No wall clock or peak moves at all.

**How it is measured.** `--mem` on q18, q11, q21, q1 and q4 before and after; the plain
matrix against `8f0b161` at no budget and 16 MB to show it is flat (the change is
report-only); both unit suites, the CLI checks, the goldens and the spill acceptance
script. A `grep` is part of the evidence: every remaining caller of `batches_bytes` and
`estimate_batch_bytes` is a decision or a size check, not a report.

**Left open on purpose.** The allocator's own overhead, which no report here counts and
which keeps every total a lower bound; the eager folds and the swapped path's points; and
the tee.

**Result (§78).** Split, and both halves are better for it. `estimate_batch_bytes` keeps
its definition and stays the unit of every decision; `resident_batch_bytes` adds the
validity array for the census only, and every census site now reports it. q18's largest
point rises 192,871,412 → 204,877,938 (86.5% of the resident sample there, from 80.7%),
its cache entry rises by the 12.0 MB the rows' validity accounts for, and q21's step point
rises to 483,146,786 (93.8% of its peak sample). Two whitebox tests moved to the new
definition. Plain matrix against `8f0b161`: identical answers, everything inside the
spread, which is the point — the report changed and the engine did not.

### The budgeted peak declares itself contract (2026-10-30)

Written before the change. With SF1 and `--memory 16M`, q21 peaks at 598.5 MB, and its
"no budget" peak is 504.9 MB — the budgeted run holds *more* than the unbudgeted one. The
census cannot say where: under that budget q21 declares one point, `collected FROM tables`
at 183.6 MB, and the highest resident sample any of its points sees is 236 MB. Three
hundred and sixty megabytes of the peak live in a phase the census never visits.

**Why the points miss it.** A budgeted plan materializes and replays in `join_partitions`:
per partition it reads the partition back from the spill store, joins it, and pushes the
joined batches onto an accumulated `out` array that is the whole step's output. That
number — the accumulated output plus the partition being replayed — is where a budgeted
peak lives, and nothing observes it (§73 added points to the pulled shapes, not to the
partitioned ones).

**What the change must do.** Declare a point at each partition's replay in
`join_partitions`, naming what is alive there: the replayed left partition, the replayed
build partition, and the output accumulated so far. One observe per partition, not per
row: the partition count is capped at 256 a level and three levels deep, so a step adds
at most 768 points, which is the same order as the fold's per-batch points (§74).

**What must not move.** Every answer, every golden, every peak and every wall time: a
point is declared, not taken, and the contract keeps the honesty rule that a point never
keeps a structure alive — the closures read what the replay already holds. The plain
matrix is run as evidence.

**What is predicted.** q21's 16 MB census starts naming a point above 400 MB, dominated by
the accumulated output, and the named total at the peak covers more than half of the
598.5 MB sample. If the peak is instead in a phase with no natural boundary (an allocator
high-water from a temporary the replay frees), the points will show a much lower ceiling
than the peak and that will be the finding — the round's deliverable is the attribution,
not a fix.

**How it is measured.** `--mem` on q21, q18 and q9 with and without a 16 MB budget, before
and after; the number of points a query declares; both unit suites, the goldens, the CLI
checks and the spill acceptance script; the plain matrix against `317243b`.

**Left open on purpose.** What to do about the peak once it is named — the accumulated
output is the eager materialization this engine's whole shape rests on, and bounding it is
the streaming join's problem, not this contract's.

**Result (§79).** Declared. `join_partitions` now observes once per partition replay,
naming the left partition, the build partition and the output accumulated so far; q21's
16 MB census goes from 1 point to 106 and its largest becomes `spill partition replayed`
at 207,922,735 bytes, sampled at 423 MB of the 598.5 MB peak. The rest of the peak is
`collapse_handed`'s copy of that same output, which runs after the replay — so the peak is
now attributable to the eager materialization rather than unknown. The contract predicted
the named total would cover half the sample and it covers 34.7%, which the report's
lower-bound rule already accounts for and which is recorded. Plain matrix unchanged.

### The partition replay handover contract (2026-10-30)

Written before the change. §79 named the budgeted peak: with `--memory 16M` q21 reaches
598.5 MB, of which the replay point samples 423 MB (its accumulated output estimated at
201.6 MB) and the rest is `collapse_handed` concatenating that same output into one batch
right after the replay — the output and its copy alive together. Without a budget the same
query peaks at 504.9 MB, so the budgeted run costs about 95 MB more than the unbudgeted
one, and the extra is this copy.

**Why the copy exists.** §65 concluded that a budgeted join should hand the next step one
batch a side: a partitioner slices every input batch into every partition, so a hundred
small batches cost a hundred copies per partition, and holding a handover batch and its
copy at once measured worse than not collapsing. That conclusion was measured against the
alternative of *collapsing at both ends*, not against handing the replay's own batches on.

**What is measured, and the decision it makes.** Return the replay's batches to the caller
as they are, instead of collapsing them into one. The peak should fall by roughly the
output's size, and the wall time should rise if the next step repartitions many small
batches — that is exactly the trade §65 described, and this round re-measures it with the
replay's real output rather than assuming either direction.

The change is kept only if it lowers at least one 16 MB case's peak by 10% or more and no
16 MB case's wall time moves outside the matrix's spread; otherwise `collapse_handed`
stays exactly as it is and this contract's result records the measurement that said so.

**What must not move.** Every answer and every golden: the batches are the same rows in
the same order, only in more pieces. The no-budget cases, which never take the grace path.
And the census's attribution: the `spill partition replayed` point keeps naming what the
replay holds, and a new point or the existing one keeps the collapse visible if it stays.

**What is predicted.** q21 16 MB: peak 598.5 MB → about 430 MB (the replay point's sample,
with the collapse gone), wall time perhaps 5 to 15% worse because the next step repartitions
106 batches instead of one. If the wall cost is that high, the honest outcome is rejection —
this engine's target is wall clock, and a 28% peak saving on one budgeted query is not
worth a 15% time cost on the slowest case it has.

**How it is measured.** The plain matrix against `04738aa` at no budget and 16 MB, three
rounds, on a quiet host; `--mem` on q21 and q9 at 16 MB before and after for the
attribution; both unit suites, the goldens, the CLI checks and the spill acceptance script.

**Left open on purpose.** A collapse that does not double the peak (writing the replay's
output into one destination as partitions finish would), and the fold's own eager copy.

**Result (§80).** Rejected, and §65's choice confirmed from the other side. Handing the
replay's batches on uncollapsed lowers q21's 16 MB peak by only 8.6% (596.5 → 545.1 MB)
while raising its wall time 39%, and *raises* q9's peak 23% with a 67% wall-time cost,
because the next step's partitioner then holds a hundred small batches at once
(`require the spread` bar: at least one 10% peak win, no wall time past the spread).
`collapse_handed` stays; the numbers are recorded in §80. A collapse that writes into one
destination as partitions finish remains open.

### The unbudgeted peak, waiting for a contract

A query without a budget has no memory bound by design: what it allocates is what it
asked for. §86 measures what that means now — q15 holds 239 MB of decoded input for a
2.3x faster answer, q18 and q17 150-240 MB — and finds the cache that does it cannot be
trimmed without removing the reuse that pays for it. A byte cap that drops entries
instead of keeping them is the shape the fix would take, and the trigger is a contract
that says what an unbudgeted peak owes; until then the census names the bytes and the
number is a choice the caller makes with `--memory`.

### The spilled tee contract (2026-10-31)

A table a query reads more than once is decoded once and kept (§71). A budget cannot
afford the keeping — `--mem` puts q17's lineitem at 139 MB, 57% of its unbudgeted peak
— so the sharing is switched off under a budget and the second reader decodes again.
§87 measures what that costs: q21 +85%, q18 +54%, q17 +45% against a 2 GB budget where
nothing spills, and nothing at all on the eleven cases that read each table once.

The tee: under a budget, a table with more than one reader in the plan is decoded once
and its batches written to the spill store, and every reader streams batches back from
the store instead of from the source. The store is already injected, already deleted on
every exit path, and already the thing the partitioner uses for exactly this reason; the
tee's working set is one batch, so the budget holds. The first reader pays the write,
the later ones pay a read each, and no reader ever holds the table.

Bar: q21, q18 and q17 at 16 MB and 64 MB each at least 10% faster than today, every
other case within 5% of its wall time and its peak, answers unchanged (the reordered
ones checked as multisets), 33 goldens, 417 + 431 unit tests, the CLI and the spill
acceptance gates green, and the store's files gone when the query ends.

**Result (§88).** Built and refused. The tee is 20% faster on q18 and 9-12% on q15,
q21 and q17 — but 63-68% *slower* on q11, whose partsupp is cheap to parse and pays the
two extra passes the tee adds, and the bar said nothing else more than 5% worse. The
engine cannot tell the two tables apart before reading them: CSV's plan has `rows:
None`, byte size does not separate them, and serialize-plus-deserialize is not cheaper
per byte than parse in any ratio the code can name. An in-memory cap costs nothing and
fits neither table, so it buys only q11's 0.2 s back. What reopens this is a plan-time
signal the engine does not have — a source that reports its rows, or a per-format
decode cost — and then the gate is one comparison instead of a constant.

### The partition routing contract (2026-10-31)

The grace join slices every input batch by key hash into one piece per partition, so
the number of pieces — and the number of little gathers that make them — is the
number of input batches times the partition count. The scan's batch size therefore
decides the routing cost of a spill it knows nothing about. On q19 at SF1 under a
16 MB budget the same query takes 65.5 s when the scan emits 4096-row batches and
127.6 s when it emits 2048-row ones, with every other byte of work identical; the
answer, the partitions and the pieces' contents are the same, only their number
differs. 2048 is what the scan itself wants (verification §68: a batch's columns stay
in cache while the engine walks them, and the 16 MB cases of that round agree), so
the fix is not to make the scan hand over bigger batches — that is worth 2-7% on
every other unbudgeted query — but to stop the scan's batch size from deciding how a
partition is filled.

The partitioner coalesces. `join_partitions` groups each side's batches into chunks of
at least `budget / 64` estimated bytes, concatenates a chunk, and routes the
concatenation; only then does a batch's rows become pieces. The transient cost is one
chunk, `budget / 64`, beside the accumulator the writers already hold; the run size
stays `budget / 4`, so a partition's piece count and its replay are unchanged, and a
query's answer cannot change because the rows, their keys and their partition numbers
are exactly what they were.

Bar, measured against today's tree on SF1: q19 under a 16 MB budget back under 80 s
(65.5 s was the 4096-row scan, 127.6 s today), no other 16 MB or 64 MB case more than
5% worse, and no case's peak more than 5% higher. 33 goldens, 417 + 431 unit tests,
the CLI and the spill acceptance gates unchanged.

**Result (§85).** Measured and refused. The coalescing was built — each side grouped
into chunks of `budget / 64`, concatenated, routed — and left q19 at 131 s where it
was 127.6 s, so the cost is not the routing: the pieces and their contents are
unchanged by construction, and halving the number of gathers with them made no
difference. The same section's bisect puts the whole regression on the scan's batch
size (4096 rows: 65.5 s, 2048: 127.6 s, at 16 MB only), and moving the scan back to
4096 everywhere costs 2-7% on the unbudgeted cases, so the batch size should follow
whether a query is spilling rather than a constant. That needs the budget plumbed into
the source reader, and it is the next round's work; the coalescing is reverted.

### The early semi/anti contract (2026-10-31)

Written before the change, after measuring what q21's chain actually carries. The
decorrelator turns `EXISTS` and `NOT EXISTS` into semi and anti join steps and appends them
after every FROM item (`extra_items` in `engine/correlate.mbt`), so q21's chain is
supplier, lineitem, orders, nation, semi, anti — the two most selective conditions in the
query run *last*, after two joins have already built the intermediate they filter.

Two readings say this is the remaining lever on q21:

- after the first step (supplier joined with the date-filtered lineitem) the chain carries
  **3,793,296 rows**; after the semi and anti steps it carries **202,092**. A factor of
  18.8 that steps three and four (orders at 729,413 scanned rows, then nation) currently
  pay for in full.
- q21 with no budget takes 2.90 s and peaks at 504 MB; with `--memory 16M` it takes 6.67 s
  at 538 MB. The unbudgeted peak *is* that intermediate, so a step order that never builds
  it helps both paths at once — unlike the budget work, which only helps the budgeted one.

**What the change must do.** Place each semi/anti item as early as its own key references
allow: immediately after the last FROM item whose columns it reads, provided every join it
moves across is INNER. The reorder happens in AST space, before binding, so the binder
computes the smaller layouts itself and no positional column reference is rewritten by
hand. A semi item whose keys read an alias that a later item introduces stays where it is,
and so does one that would cross a LEFT, RIGHT or FULL join, because moving it would change
which rows owe an unmatched output.

**What the change must not do.** It must not change any answer: the semi and anti
conditions are conjunctive filters on the outer rows, so their position among INNER joins
cannot change the set of rows that survive, only when they are applied. Goldens and the
budgeted/unbudgeted equivalence checks decide that.

**Bar.** On SF1, q21's wall time and peak both at least 10% better with no budget, and no
regression over 5% on any other query in the matrix; every golden unchanged.

**What it is not.** It is not a general join reordering: the FROM order decides which side
each join builds from and the engine's plans are recorded in verification §41–§60, so a
cost-based reorder of the ordinary joins is a different change with a different contract.

**Result (§84).** Measured and refused. The reorder was built (each synthetic semi/anti
item placed right after the last FROM item its ON reads, across INNER joins, in AST space),
moved q21's plan as predicted, and made it worse in both directions: no budget 2.89 → 7.95 s,
16 MB 6.26 → 16.63 s with the peak 545 → 872 MB, 64 MB 5.43 → 12.25 s with the peak 550 →
805 MB. The row count fell exactly as predicted; the model behind the prediction is what was
wrong — a semi or anti pass costs in proportion to its input, and moving it up doubles that
input by getting ahead of the cheap inner filters, while its pre-executed inner side (600 MB
for q21's `__semi0`) then sits beside the largest probe the chain holds. The current order is
already the good one. The change found a real latent bug in `explain`, whose schema list
assumed the synthetic tables are the last FROM items; that is fixed and kept, and the rest is
reverted. A smaller measurement along the same line — anti before semi, 1.7% — was below the
bar, so no such heuristic was added. Ordering the chain by measured selectivity is a cost
model, and this round is the evidence that guessing one is not the way to get it.

### The one-sided spill contract (2026-10-30)

Written before the change, after measuring what the budgeted path actually costs. SF1 with
`--memory 16M`: q21 takes 17.96 s against 2.9 s with no budget, and the same query spilling
to `/dev/shm` takes 17.96 s — the disk is not the cost. The cost is the spill's own CPU:
every partitioned side is encoded to a run format and decoded back, and the symmetric grace
path does that to *both* sides of every step that does not fit.

Three facts from reading the code, which shape the contract:

- `join_step` already streams the probe side (`next_left` hands `acc`'s batches to the
  cursor one at a time) and only materializes the build side.
- `concat_batches` already returns its single input unchanged, so a one-batch partition is
  not re-copied.
- q21's first step is the shape that matters: probe `supplier` at 324 KB (fits easily),
  build `lineitem` at 773 MB (does not). The grace path partitions both — it encodes and
  decodes 773 MB of build side, and 324 KB of probe side it could have kept.

**What the change must do.** Partition the side that needs it, and only that side. When the
build side fits the budget and the probe side does not, the step already works: stream the
probe, hold the build. When the probe fits and the build does not, partition the *build*
side into `ceil(build / budget)` parts and probe each part with the whole in-memory probe
side — `P` cheap passes over small rows instead of encoding and decoding the probe. When
neither fits, the symmetric grace path stays exactly as it is.

**What must not move.** Every answer, every golden and every peak: the partitioner's output
is the same rows in the same order (a partition is a key range, and a probe row can only
match rows in its own partition), and the probe side being small is what makes the repeated
passes safe to bound. The steps where both sides exceed the budget are untouched, and the
contract's measurement must show they are.

**What is predicted.** q21 at 16 MB saves the probe-side encode/decode, which is small, so
its wall time should move by only a few percent — the honest expectation is that this
contract buys little on q21 and more wherever a step's probe side is small and its build
side is not. If the measurement shows no case improving by more than the spread, the change
is rejected on the same terms §80 was.

**How it is measured.** The plain matrix against `04738aa` at no budget and 16 MB, three
rounds, quiet host, plus 4M and 64M for the middle band; `--mem` on the cases that move;
both unit suites, the goldens, the CLI checks and the spill acceptance script.

**Left open on purpose.** Encoding a partition as batches rather than bytes when the store
is in memory (the CPU cost measured here is the encoding, not the disk), and choosing the
index side at plan time instead of by arrival order.

**Result (§81).** The cheap half landed and it is the largest win this session: when the
build side fits the budget (`build * 2 <= budget`, the index being the build again), the
step is not partitioned at all — the build is the hash side and the probe streams past it.
q7 at 64 MB goes 6.34 → 2.58 s (−59.3%), q7 at 16 MB −39.1%, q21 at 64 MB −34.1% and at
16 MB −28.9%, q10 −12.9%, q9 −7.1%, with q21's 64 MB peak also down 10.4%. Four cases
change row order and none changes content (verified as multisets). The rest of the contract
— one-sided partitioning when the *build* is what overflows — is what q21's first step still
pays for.

**Result (§82).** The mirror landed, reusing `SwapCursor`: an INNER step whose accumulated
side fits (`acc * 2 <= budget`) but whose table side does not now swaps roles — the
accumulated rows become the hash side and the table streams past them, with no partitioner,
no encoding and no spill. It is the first change this session that moves peak and wall time
together: q8 at 16 MB goes 4.25 → 1.71 s (−59.8%) with its peak down 38.6%, q5 −52.2%,
q9 −48.5% at 16 MB and −49.2% at 64 MB with peaks down a third to 41%, q3 −37.8%, q21
−21.7%. Five cases change row order and none changes content (verified as multisets). What
is left is plan-time choice of the index side, which q21's 6.67 s against 2.90 s is still
paying for.

**Result (§83).** 0.6.1 is published and verified from the registry on all three
backends. The release carries the two halves of the one-sided spill (§81, §82), the split
between the budget's unit and the census' (§78), the census points (§74, §75, §79, §82) and
the empty-partition crash fix (§77); three measurements ship as refusals (§76, §80). The
number says patch because the owner judged the visible changes — plan, census output, row
order of unordered results — to be within a patch, and the changelog section records that
judgement rather than leaving it implicit.

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
