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
What still accumulates is listed per shape: a chain of three or more joins, a
`RIGHT` or `SEMI`/`ANTI` join, a keyless cross join, and an `ORDER BY`, `GROUP BY`,
`DISTINCT` or window above a join, plus derived tables and set operations.
`--memory` budgets the operators that honour it and is not a process RSS cap.

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

Three boundaries the contract drew on purpose, in the order they are worth
revisiting.

**ORDER BY above the composed aggregate.** The contract excludes it because a
sort needs every row first, but the grouped result here is already one batch and
the eager tail sorts exactly that batch, so the exclusion is narrower than it
looks. It is also what keeps most of the TPC-H goldens off the path: at sf01 only
q14 and q19 carry no `ORDER BY`, while q3, q10 and q12 sort their grouped answer
and keep the eager path. Widening needs one decision the contract did not take:
whether an over-budget sort of the grouped batch spills through the existing
run-file pool inside a folded query. Then it needs the same answer and counter
proof this task carried.

**A second join step.** The fold's expressions are bound to the combined
two-table layout, so a third table would need a mapping between the second
cursor's output and that layout; nothing else in the composition depends on the
step count.

**The growing build side and group state.** Both stay resident whole, as they
were before, and E6c measures them; this task bounded neither.

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
| The executor is not streaming end to end | Unrestricted results and queries with blocking operators | A single-table scan streams its result through `stream`/`stream_with`, and the CLI prints through it, so an unrestricted `WHERE`/projection result no longer holds its rows (verification §31: `--json` over 16 columns and 2,000,000 rows, 1,090.6 MB → 35.2 MB of peak RSS). A single-table aggregate folds the scan's batches as they arrive, so it holds its state and one batch rather than its input (verification §32: 109.7 MB → 35.3 MB). An `ORDER BY` under a budget merges its runs into batches instead of materializing the sorted answer (§33: 506.8 MB → 178.8 MB), and a two-table join probes a batch at a time with only its build side resident (§34: 270.8 MB → 35.3 MB). What still retains its input: a chain of three or more joins, a RIGHT/SEMI/ANTI join, a cross join, and any of ORDER BY, DISTINCT or a window above a join; a `GROUP BY` above a two-table keyed INNER/LEFT/FULL join folds the join's batches instead (verification §49). SF1 measured 159 MB for one projected column and 3.1 GB for all sixteen before any of this; §34 re-measures the join on a 16-column probe. See verification §25 for the eager measurements and §27 for the LIMIT comparison. |
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
