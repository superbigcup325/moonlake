# moonlake correctness and performance verification report

> 2026-10-06 · distillation of the verification arc. Goal: go beyond the
> surface evidence of "SF0.01 + 1e-9 relative tolerance cross-check", give
> reproducible, normalized verification for vectorization, hash join and
> predicate pushdown, and provide empirical numbers for performance, memory,
> spilling, concurrency and edge cases. Every item is reproducible with the
> commands quoted in the text.

## 1. Vectorization (eval_vec vs the scalar interpreter)

**Method**: randomized property testing (`engine/property_test.mbt`). A seeded
generator builds **type-consistent** random physical expression trees covering
all six column types (I32/I64/F64/Str/Bool/Date): comparisons and IS NULL are
generated only as Bool, EXTRACT only as Int32, and CASE branches share the
target type; each column gets a NULL about every 1/9 points (1/7 for Str/Bool).
The assertion is that `eval_vec` and `eval_scalar` are **cell-for-cell equal**
(value + NULL positions), with batch lengths covering
`0/1/2/3/5/17/4095/4096/4097` (including the scan batch size 4096 and its ±1
neighbours). Both sides NaN counts as equal (0/0 is legal); everything else must
match exactly. 60 cases × 4 expressions per case.

**Mutation verification** (proving the property has teeth):
- swapping Lt/Gt in `cmp_vec` → 7 tests fail, the property is falsified ✓
- changing I32 Sub to Add in `arith_vec` → property falsified ✓
- restored, 93/93 green.

**Fixed along the way**: the generator's first version generated IsNullE/ExtractE
at arbitrary types (the engine was fine; the generator violated type discipline),
and both falsifications were traced to the generator — falsifying a property test
must audit the generator before the engine, a discipline now on record.

## 2. Hash join (cross-check against a nested-loop oracle)

**Method**: the property test embeds a naive nested-loop join oracle and
compares cell-for-cell across eight join shapes: inner / LEFT+ON residual /
LEFT+WHERE cross-table residual / RIGHT / FULL / semi(EXISTS) / anti(NOT EXISTS)
/ anti(NOT IN). Three pathological key distributions: dense duplicates (domain
{0,1,2} + 30% NULL), scattered (near-unique), near-all-NULL (exactly one non-null
key); the residual is a cross-table `b.w > a.v` (on/off 50%). 80 cases.

**Mutation verification**: cutting the anti-retention rule
`!matched && (!null_key || !null_key_excludes)` down to `!matched` → property
falsified ✓; restored, all green.

**Real bugs the oracle caught and fixed** (`0f03d28`):
`NOT EXISTS` was being dropped by anti join under NOT IN's three-valued logic
when the correlated key was NULL. DuckDB arbitrates: with
`c=(1,10),(2,NULL),(3,30)` and `o=(10,5)`, NOT EXISTS should return {2,3};
before the fix moonlake returned {3}. Root cause: `JoinKind::Anti` conflated the
two negation semantics. The fix introduced `AntiLoose` (NOT EXISTS: drop a row
only on a true match; NOT IN: discard when the probe key is NULL/UNKNOWN). The 22
TPC-H queries cannot find this — all their correlated keys are non-null.

**Boundary tests** (`engine/e2e_test.mbt`):
- batch boundaries 4095/4096/4097 rows × (filter / group / self-join fan-out),
  compared against the model
- int64 extreme keys (±2^63-1) hash without collisions; NULL keys do not match;
  literal comparison
- `parse_f64` precision fix (`09539e5`): the decimal accumulator resolved
  **2^63** (exactly representable as a double) to a neighbour value, so
  `k = -9223372036854775808` returned 0 rows while `k >=` the same literal
  returned 1. Now decimal integers up to 20 digits convert via UInt64 exactly
  (correct rounding), and wider input keeps the 1e-9 relative contract.

## 3. Predicate pushdown (randomized differential vs DuckDB)

**Method**: `harness/fuzz_pushdown.py` — over an INNER/LEFT join graph (a-b-c,
key domain 0..40, NULL keys included) it generates random WHERE trees of 2–5
conjuncts: single-table comparison/IN/BETWEEN/LIKE/IS NULL, cross-table equality
and inequality, and OR with an implied join key (the Q19 shape), each compared
against DuckDB (1e-9 tolerance, NULL semantics aligned). **300 random queries:
300/300 match, 0 engine rejections** (seed 20261005, reproducible).

**Mutation verification**: disabling the preserved-side guard (the LEFT WHERE
escape fix `5aa02c4`) gets caught within 150 queries — the failing shape is
exactly "LEFT JOIN + WHERE-form cross-table equality":
`... LEFT JOIN c ON b.k2 = c.k2 WHERE c.s IS NULL AND b.k2 = a.k1`,
moonlake -9753 vs duckdb -7743. The fuzzer deliberately includes that
discriminating template (WHERE-form cross-table equality is the only shape that
distinguishes key placement from delayed filtering).

## 4. Overflow and edge cases (semantics pinned down)

The `engine/e2e_test.mbt` overflow battery plus `types/types_test.mbt`:
- CSV inference widens past the boundary instead of overflowing: 2147483648 stays
  exact (Int64), 9223372036854775808 becomes Float64 — **never wraps**
- integer arithmetic refuses to wrap: 2147483647+1 and 9223372036854775807+1
  are `sql error (execute): integer overflow: ...` (the same refusal `sum()`
  makes; DuckDB raises `Overflow in addition`), and every in-range result
  including the boundary itself keeps its value. The non-raising
  `Scalar::arith` still wraps, documented as such; the executor evaluates
  through `Scalar::arith_checked` on both the scalar and the vectorized path
  (the per-lane check is why the fast path did not have to be turned off)
- division is always DOUBLE: `x/0` → ±inf, `0/0` → nan; `%0` → NULL
- an out-of-range CAST is a clean bind error (never wraps)
- month arithmetic clamps to month end: 1996-03-31 + 1 month = 1996-04-30

**Documented boundary limits** (documented behaviour, not bugs):
1. an all-empty CSV column infers as STRING — all-NULL key columns cannot be
   joined (a type error rejects it rather than silently answering wrong)
2. a bare NULL in the SELECT list needs type context (use `CAST(NULL AS T)`)
3. an entire column containing values beyond int64 infers as Float64 — row-level
   exactness is bounded by the column type

## 5. Performance and memory

> These are the before/after numbers each optimization was accepted with. The
> release-level record — one machine, one build, scan/join/gather/spill, kept
> as JSON so two releases can be compared — lives in
> [`docs/bench-baseline.md`](bench-baseline.md).

`harness/measure.py` (measures the native binary directly, not `moon run`;
isolated child process, maxRSS via `getrusage(RUSAGE_CHILDREN)`; best-of-3).
These numbers are re-measured after the 2026-10-06 CSV-ingest boxing elimination
(cell offsets moved into a trimmed FixedArray): ingest SF0.1 -16% (1374 → 1150
ms), end-to-end queries -11~18%, maxRSS down below the old baseline:

| Query | SF0.01 | SF0.1 | time ratio | RSS SF0.01 | RSS SF0.1 |
|---|---|---|---|---|---|
| q1 (aggregate, full scan) | 184 ms | 1847 ms | 10.0x | 41.4 MB | 353.3 MB |
| q6 (selective filter) | 124 ms | 1213 ms | 9.8x | 41.3 MB | 353.2 MB |
| q5 (6-table join) | 149 ms | 1531 ms | 10.3x | 45.3 MB | 426.2 MB |
| q2 (correlated scalar subquery) | 24 ms | 281 ms | 11.7x | 12.3 MB | 63.1 MB |
| q17 (correlated aggregate subquery) | 148 ms | 1539 ms | 10.4x | 41.4 MB | 353.2 MB |
| ingest (lineitem LIMIT 0) | 115 ms | 1150 ms | 10.0x | 41.3 MB | 353.2 MB |

Conclusion: time and memory are **near-linear** in data size (10× data → 9.8–11.7×
time, ~8.5× memory); the eager, fully materializing architecture makes RSS a
roughly constant multiple of the data volume (SF0.1 ≈ 353 MB for 600k lineitem
rows). Test machine: local Linux, single run; numbers are this machine's reference
values. Reproduce: `moon build cmd/main --target native && python3
harness/measure.py`.

## 5.1 Window functions (differential battery)

When window functions landed on 2026-10-04, 29 queries were compared as row
multisets between moonlake and DuckDB on the same small dataset (ties, NULLs,
three partitions; floats at 1e-9 relative tolerance), 29/29 matching. Covered:
the three ranking functions (tie/NULL sort keys), whole-partition and RANGE
UNBOUNDED PRECEDING TO CURRENT ROW running frames (peers sharing values,
count/sum/min/string_agg/median/count DISTINCT), NULL partition-key grouping,
GROUP BY interaction (`sum(sum(x)) OVER ()`), window values inside row
expressions, DISTINCT/WHERE/LIMIT/alias-ORDER BY combinations, and multiple
windows coexisting. Error paths (missing OVER, outside the SELECT list, an
explicit frame clause, nested windows, a window inside an aggregate argument,
GROUP BY constraints) each give a deterministic error. Reproduce: data and
script are in the commit (`t.csv`, 8 rows + a 29-query list); e2e expected values
are hand-computed and pinned in the window section of `engine/e2e_test.mbt`.

**Re-runnable replacement (2026-10-23).** The 2026-10-04 record is history:
its fixture and script are not on disk, so nobody could re-run it and the claim
aged without evidence. `harness/check_windows.py` is the replacement, and it is
deliberately a *new* case list, not a recovered one — the numbers below are not
the old 29/29. It uses a fixed nine-row fixture (tied values, NULL sort keys, a
NULL partition key) and 22 cases: 13 value comparisons (12 with a total order,
compared in sequence; 1 without one, compared as a multiset with duplicate
counts), 1 legality-only `string_agg` (a partition has no order contract, so
the string itself is not pinned), and 8 refusal cases. Of those refusals, 2 are
valid SQL this engine does not implement (an explicit frame clause, a window in
`ORDER BY`) and 6 are window misuse the standard forbids — DuckDB must reject
them too, so a refusal cannot pass by being invalid SQL. Runs: 13/13 value
cases match DuckDB, `--random 400 --seed 20261023` matches 8/8. The gate has no
skip path: a referee error, a missing fixture, or zero executed value cases all
fail it, and a wrapper that returns a stable wrong answer exits 1 (checked). CI
runs the fixed list in the `tpch` job and the seeded fixture in `nightly`.

## 5.2 ORDER BY external sort (2026-10-04)

Mechanism: `ExecOptions { budget, spill }` injects a budget and a spill store
(the engine stays fs-free; `SpillStore` is a struct of function fields, the
native CLI injects `spill.FsStore`, and wasm lands on an explicit "a budget must
be paired with a store" error). ORDER BY on a non-aggregate query runs external
sort under a budget: in-batch sort → flush sorted runs at ~budget/4 → pairwise
merge down to ≤8 ways → a final k-way merge **streamed** into
projection/DISTINCT/OFFSET/LIMIT — with LIMIT only the output window is in
memory, without LIMIT what materializes is the query result itself. All run files
are deleted when the query ends (including on the error path, via errdefer).

Verification:
- the wire format (`types.spillfmt`, MLSPILL3) round-trips every dtype + NULL +
  int64/double extremes; presence is a bitmap — a column with no NULLs spends
  one mode byte, a nullable one a bit per row — and the layout is pinned by
  exact-size tests (8027 bytes for 1000 null-free doubles, 6152 for the same
  column with every fourth row NULL), a 13-row partial trailing byte, and a
  buffer truncated inside the bitmap; parsing has truncation defences
  (out-of-range is an
  Execute error with a position, no longer a range panic — a bug found and fixed
  during debugging: serialization used vector capacity instead of batch row
  count, so a partially filled vector from the builder wrote a garbage tail;
  the e2e equivalence test caught it on the spot)
- e2e: a 2400-row duplicate-value fixture, budgets 900/1500 forcing multiple
  runs + merging; LIMIT / no-LIMIT / OFFSET / DISTINCT / mixed asc-desc five
  shapes are cell-for-cell equal to the in-memory path
- the golden chain gains a self-consistency check: a full non-aggregate ORDER BY
  over SF0.01 lineitem under `--memory 200K` matches the in-memory path row for
  row (at the end of `check_all.sh`)
- semantic boundary (stated plainly): the budget bounds run state, not base-table
  materialization (scan laziness is a separate item), and not the final result
  when there is no LIMIT

**A wrong-answer bug found by the benchmark oracle (2026-10-23).** The release
benchmark's spill case was timing a query whose answer was wrong above a
certain budget. A run file is read back as one sorted stream, but the writer
appended independently sorted chunks without merging them: a run that held
pieces of more than one 4096-row batch was only piecewise sorted, and the k-way
merge then emitted chunk heads out of order. Over SF0.1 at `--memory 1M`,
`SELECT l_orderkey, l_extendedprice FROM lineitem ORDER BY l_extendedprice DESC,
l_orderkey LIMIT 3` returned 95799.5 / 95749.5 / 95549.5 instead of 95949.5 /
95899.5 / 95899.5. Every budget from 800 KB to 8 MB was affected; 100–400 KB and
1.5 MB were not, which is exactly why the 200 KB equivalence check in
`check_all.sh` and every engine test (one batch per run) stayed green. `RunWriter::flush`
now sorts the accumulated run before writing it (`budget/4`, the same bound the
merge passes work under); join and aggregation partition writers keep the old
unsorted behaviour through an explicit empty key list. Evidence: the top row
now matches in-memory at 100 KB / 200 KB / 400 KB / 800 KB / 1 MB / 1.5 MB /
2 MB / 4 MB / 8 MB; a new engine test over a 60k-row fixture at 200–400 KB
budgets fails (`Str("g0") != Str("g3")`) when the run sort is removed and
passes with it; `spill_accept.sh` is 7/7 and the golden spill equivalence still
matches. Timings recorded in `harness/baseline/` before this fix measured the
same amount of I/O on a wrong ordering and are not comparable with later ones.

CLI: `exec --memory <n>[K|M|G]` (with `--spill-dir <dir>`, defaulting to a
per-run directory probed by suffix under TMPDIR, removed when the query ends).
Library form: `execute_with(sql, catalog, opts)`.

## 6. Concurrency

- **Global-state audit**: engine/types/catalog/sources contain no package-level
  mutable globals (zero top-level `let mut` / `Ref` / atomics). All of
  `execute(sql, catalog)`'s state lives on the call stack — the library's
  thread-safety contract = one independent Catalog per thread (or a read-only
  Catalog shared with external synchronization).
- **Parallel-process determinism**: 8 concurrent CLI processes run q5 over the
  same dataset; their output md5 is identical (1 unique hash).
- The MoonBit language does not expose thread primitives to users; in-process
  parallelism is out of contract.
- **Survey of language-level parallelism** (2026-10-04, moon 0.1.20260920):
  in-process data parallelism is currently **inexpressible** — a language/toolchain
  limitation, not an engine design gap. moonbitlang/async describes itself as
  "single-threaded, cooperative multitasking", "user code can only utilize one
  hardware processor" (internal threads serve IO workers only); core builtin and
  moonbitlang/x expose no thread/spawn/atomic primitives at all; community actor
  libraries (fuwaroid-style) are likewise single serial loops. native FFI
  (`extern "C"`) could in theory attach a C thread, but GC-managed objects cannot
  be shared across FFI threads, degrading to process-level parallelism with worse
  engineering — better to just use multiple processes. Conclusion: parallelism
  stays a process-level contract (one Catalog per thread / externally synchronized
  read-only sharing); in-query parallelism waits until the language offers user
  threads or wasm shared-memory threads. Under a columnar layout, partitioning
  scan/join/agg is the natural entry point.

## 6.5 Parquet decoding (2026-10-15)

The hand-written decoder's correctness evidence comes in three tightening layers:

**1. Decoder unit tests** (`sources/parquet/thrift_wbtest.mbt`,
`page_wbtest.mbt`, 15 items, hand-built byte buffers so all three backends run
them): the compact protocol's varint/zigzag and field delta, generic skipping of
unknown fields, PLAIN layouts per type (including empty strings, bit-packed
booleans), the RLE/bit-packed hybrid stream (RLE runs, bit-packed runs of
arbitrary bit width, **byte stepping across runs**), the 4-byte length prefix of
definition levels, and malformed input raising a scan error rather than trapping.

**2. Fixture × DuckDB golden** (`harness/gen_parquet_fixtures.py` +
`check_all.sh`): one fixture per shape — a full physical-type + NULL column, a
low-cardinality dictionary page, and two row groups; each shape is generated in
one variant per codec the decoder claims to support (plain/uncompressed,
plain/snappy, dictionary/snappy, dictionary/uncompressed, two-row-group/snappy),
all compared against the same DuckDB golden (one golden per shape, shared across
variants), plus two queries for grouped and full-table aggregation. **The
supported range is defined by this fixture set, not by a documentation promise.**

**3. Real-data end to end**: q6p runs over the 60,175-row `lineitem.parquet`
(written by DuckDB as SNAPPY + PLAIN_DICTIONARY, 16 columns including
date/string/double); the result matches the DuckDB golden.

**4. Third-party corpus cross-check** (`harness/check_parquet_corpus.py`, run
nightly): pull all 71 files from apache/parquet-testing, compare each row count
against DuckDB, and anything out of range must be **rejected by name**, not
silently answered wrong. Result: **20 read correctly** (including
`int32_with_null_pages` 1000 rows, `overflow_i16_page_cnt` 40000 rows,
`nation.dict-malformed`, `plain-dict-uncompressed-checksum`, `sort_columns`,
`unknown-logical-type` and other boundary files), **48 rejected by name by
design** — by reason: nested schema 13, other compression codecs
(LZ4/LZ4_RAW/ZSTD/Brotli) 8, INT96 7, FIXED_LEN_BYTE_ARRAY 6, GZIP 4, DELTA_*
encodings only 4, v2 data pages 3, TIMESTAMP 1, repeated 1, empty dictionary page
1 — **3 that DuckDB itself cannot read either** (skipped), and **0 wrong answers**.

> Read counts in this section and in §6.6 are footer-level (`count(*)`); §11
> replaced the metric with a column-and-value check, which is why the number it
> reports is smaller.

**Supported range** (everything else is a structured scan error, no guessing):
flat schema, v1 data pages, PLAIN, dictionary (including RLE/bit-packed
indices and definition levels), DELTA_BINARY_PACKED (INT32/INT64),
DELTA_LENGTH_BYTE_ARRAY, DELTA_BYTE_ARRAY, BYTE_STREAM_SPLIT
(FLOAT/DOUBLE) — the last five decode through colenc — RLE boolean values,
UNCOMPRESSED and SNAPPY. Rejected: nested/repeated, INT96, v2 data pages,
GZIP/ZSTD and other codecs, BIT_PACKED, empty dictionary pages.

The corpus's own DELTA* and BYTE_STREAM_SPLIT files are still refused, but for
different reasons now: they carry v2 data pages or ZSTD/GZIP compression. The
colenc-backed paths are covered by embedded fixture tests in
`sources/parquet/colenc_integration_test.mbt` instead.

**5. Encoding evidence by source (2026-10-23).** A support matrix is only as
good as the thing that can fail, so the three sources are named separately:
**embedded fixtures** (hex constants in `colenc_integration_test.mbt`, the only
source that runs on wasm-gc/js) — now checked *outside* MoonBit as well: the
generator that wrote them was never recorded, so `check_colenc_fixtures.py`
pins each constant's SHA-256, parses its page headers, and decodes its values
with PyArrow rather than trusting the `.mbt` assertions; **regenerable set**
(`harness/gen_colenc_fixtures.py` → `harness/data/parquet/colenc/`, manifest
`harness/colenc_fixtures.json` with PyArrow version, exact `write_table`
arguments, digests, observed pages and expected values) covering
DELTA_BINARY_PACKED int32/int64 (nulls, int32/int64 boundaries), both DELTA
string encodings (empty string and NULL in the same column), BYTE_STREAM_SPLIT
float/double (nulls, −0.0, −1e300), SNAPPY + DELTA, four row groups and three
data pages in one row group; **upstream corpus** (unchanged, nightly) — the only
source whose bytes we do not control. Combinations that cannot be generated are
not claimed: the generator refuses to write a case whose pages do not carry the
claimed encoding, and PyArrow produces no v1-page DELTA file with a dictionary
page, so "dictionary + DELTA" is not in the matrix.

This closed the gap the audit found in the footer-only evidence: the gate reads
`DATA_PAGE`/`DATA_PAGE_V2` headers (page type, version, encoding, `num_values`),
not `ColumnChunkMetaData.encodings`, so a v2 page or a different encoding fails
even if the footer still lists the claimed one. Negatives checked: replacing a
fixture with a PLAIN-encoded file fails on its digest; editing the manifest's
encoding claim fails on the observed pages; temporarily removing the
DELTA_BYTE_ARRAY decoder makes the CLI comparison fail with the reader's own
scan error. The 17 committed cases (8 embedded, 9 regenerable) verify 17/17,
and the Python suite grew to 36 tests.

**Write path**: `write_bytes` / `write_file` (same package) emit the scope the
reader accepts — one row group per batch, one PLAIN data page per column,
UNCOMPRESSED — with page bodies produced by colenc. A column that holds a NULL
anywhere is written OPTIONAL: each page gets the RLE definition-level section
(4-byte length prefix, 1-bit hybrid levels) and a dense value section, and the
decision is file-wide because the schema is. Round-trip tests cover all six
engine types, NULLs in every physical type, and two row groups (including a
column that is null-free in the first group and NULL in the second, which pins
the file-wide rule); a probe file with NULLs in both columns was read back with
the same values and the same NULL rows by DuckDB and pyarrow.

**Real bugs these gates caught** (each of layers 1/2/3 did its part; recorded
for re-evaluation):
1. the compact varint did not mask off the continuation bit (0x80 treated as a
   data bit), shifting offset values by +64 — surfaced by layer 2's fixture
   cross-check
2. bit-packed run byte stepping was written as `count` instead of
   `count * bit_width`, only exposed when reading across runs — pinned by layer
   1's unit test once that shape was added
3. a compact value array (non-null only) was indexed by row number, so after a
   NULL everything shifted and went out of range — exposed by layer 3's q6p real
   data; changed to an independent cursor with an invariant check
4. **v2 data pages (page type 3) previously fell into the "skip index page"
   branch**, so delta-encoded and rle-dict family files were read as "0 values in
   chunk", a misleading error — exposed by layer 4's corpus; now it names
   "data page v2 is not supported" directly
5. `dictionary_page_offset = 0` is some writers' way of saying "unset", but was
   treated as a real page start, parsing a page header from the PAR1 magic —
   exposed by layer 4's `dict-page-offset-zero.parquet`
6. an empty dictionary page (0 entries) previously reported "dictionary page
   before any dictionary page", which is untrue — exposed by layer 4's
   `single_nan.parquet`; now it distinguishes "no dictionary page" from
   "dictionary page is empty"

## 6.6 Lazy scans and pushdown (2026-10-20)

The catalog no longer holds table data. A `TableEntry` carries the schema plus
either materialized batches or a `ScanSource`; scans are pulled as a
`BatchStream`, column pruning is part of the request (`ScanRequest.projection`,
not a hint), and Parquet row groups are skipped from footer statistics when a
predicate the engine will apply cannot match them. All four properties are
tested structurally, end to end, and by mutation.

**1. Structural tests** (`sources/parquet/lazy_test.mbt`,
`sources/parquet/stats_wbtest.mbt`, `sources/csv/scan_test.mbt`): registration
is lazy (`entry.batches.length() == 0`, `is_lazy()`), a Parquet scan emits one
batch per row group and a CSV scan one per 4096 data rows, the projection
decides which columns exist *and in which order* (including a zero-column
projection that still reports row counts), each comparison operator's skip rule
is pinned per fixture group, an all-NULL group is skipped, a group with no
statistics is not, a column that is constant inside a group is skipped for
`<> c`, truncated (`is_max_value_exact = false`) and non-UTF-8 bounds are
refused, and a CSV column outside the projection is never parsed — a value that
would fail its inferred type is only an error when a query actually reads it.

**2. End to end**: all 33 golden comparisons (`harness/check_all.sh`: 22
TPC-H texts + the Parquet variant + four multi-row-group Parquet queries +
the reader's codec variants, plus the
external-sort / grace-join / grace-aggregation equivalence checks) still match
DuckDB byte for byte, including `mgfilter`, whose predicate `v >= 200000 AND
v < 300047` reads 2 of the 4 row groups; `--explain` names both pushdowns:

```
scan lineitem (4 cols)
  pushed: l_shipdate >= 1994-01-01, l_quantity < 24
...
scan multigroup (1 cols)
  pushed: v >= 200000, v < 300047
  row groups: 2 of 4 read (2 skipped by statistics)
```

**3. Mutation verification** (each applied alone, then reverted; 200 tests
in the module's packages, 19 of them new here):
1. `Lt` excludes nothing in `excludes_int` → "statistics skip row groups a
   predicate cannot match" fails (`0 != 4`)
2. trusting inexact bounds (`bounds_for` drops the exactness guard) → "inexact
   bounds are refused" fails
3. lossy instead of strict UTF-8 for string bounds → "non-UTF-8 string bounds
   are refused" fails
4. Parquet scan ignores `group_skipped` → 3 row-group tests fail
   (`12 != 3`, `12 != 6`, `3 != 0`)
5. CSV ignores `request.projection` → 20+ engine tests fail (rows/vals wrong);
   the projection is load-bearing, not decorative
6. float columns prune on every operator again (pyarrow's NaN-free bounds are
   trusted for `=`) → "float statistics respect this engine's NaN ordering"
   fails (`2 != 0` groups skipped): the engine compares NaN as equal to every
   value, so the group holding `[NaN, 5.0]` would lose the row that `f = 7.0`
   matches

**4. Performance and memory** (`harness/bench_scan.py`, best of 5, native debug
build, same machine, A/B against `8b23c7d`):

| case | before | after | peak RSS before → after |
|---|---|---|---|
| CSV SF0.01 q1 (8 cols) | 130 ms | 94 ms | 42 → 36 MB |
| CSV SF0.01 q6 (4 cols) | 111 ms | 67 ms | 42 → 37 MB |
| CSV SF0.01 q3 (3 tables) | 130 ms | 73 ms | 46 → 34 MB |
| CSV SF0.01 `count(*)` | 105 ms | 48 ms | 42 → 36 MB |
| Parquet SF0.01 `sum(quantity)` | 126 ms | 10 ms | 36 → 12 MB |
| Parquet 1Mi rows, `count(*)` | 446 ms | 57 ms | 128 → 32 MB |
| Parquet 1Mi rows, 6/8 groups kept | 438 ms | 51 ms | 130 → 39 MB |
| Parquet 1Mi rows, 1/8 group kept | 424 ms | 47 ms | 130 → 39 MB |

The 1Mi-row file is generated by the benchmark itself (pyarrow, 8 row groups of
131072 rows, statistics on every column). The Parquet gains are real work
avoided: with `count(*)` nothing is decoded, and with a selective predicate the
unused row groups are never read. The one regression is the full 16-column read
that q6p's derived table performs: 152 → 142 ms but +3 MB, because the scan
still decodes everything and the engine then materializes its batches.

**5. Third-party corpus** (`harness/check_parquet_corpus.py`, nightly): the
apache/parquet-testing files must either read with DuckDB's row count or be
refused with one of the documented scope messages — 39 read, 29 refused by
design, 0 failing (footer-level counts; §11 replaced the metric). This is what
caught an ordering regression the per-push jobs
missed: the lazy rewrite moved the footer row-count check ahead of the schema
gate, so `repeated_no_annotation.parquet` (repeated scope *and* `num_rows = 0`
over a 6-row group) reported "row groups hold 6 rows, the file metadata says 0"
— a corruption message for a file this reader simply cannot represent. The
schema gate runs first again, which is the order the refactor's predecessor
used (`read_columns` validated `leaf_elements` before summing row groups).

**Safety argument.** A hint can only come from the table's *build filter* — the
expression `exec_joins` already applies to that table's rows before joining it
— and the engine still evaluates it (the scan's per-batch filter is an early
run of the same expression, not a replacement). Flat-space conjuncts (probe
filters, residuals, the deferred WHERE) are deliberately not hints: at an outer
join a residual ON condition can leave a row visible as an unmatched side.
Bound comparisons require the column's exact dtype (Int32/Int64/Double/Date/
String/Bool) and a provably usable bound, so a mismatched or missing statistic
only costs an opportunity, never a row. Floats are narrower still: NaN is left
out of writers' statistics but compares as equal to everything here, so only
`<` and `>` may prune a float column (`sources/parquet/lazy_test.mbt` pins the
`[NaN, 5.0]` group against `= 7.0`).

**Known edges.** Constant folding is not done, so `l_shipdate < date '1994-01-01'
+ interval '1' year` (TPC-H's spelling) yields no hint while the plain literal
does; predicate pushdown does not descend into derived tables, so q6p decodes
all 16 columns in its subquery; CSV has no statistics (nothing to skip) and its
row count is unknown until the file is parsed; a file-backed table is read twice
per query — once at registration to infer the schema, once when the scan opens —
because `moonbitlang/x/fs` offers no range reads.

## 7. Reproduction commands

```bash
moon test                                            # 201 items (all properties)
uv run --with duckdb python harness/gen_tpch.py      # SF0.01 data + goldens
uv run --with duckdb python harness/gen_parquet_fixtures.py  # parquet fixtures + goldens
bash harness/check_all.sh                            # 33 goldens + parquet fixture checks
uv run --with duckdb python harness/gen_tpch.py 0.1  # SF0.1
MOONLAKE_DATA=harness/data/sf01 bash harness/check_all.sh
uv run --with duckdb python harness/fuzz_pushdown.py 300 20261005
moon build cmd/main --target native
python3 harness/measure.py sf001 sf01
python3 harness/bench_scan.py --base <binary of the previous commit> --big
  # --big needs pyarrow: uv run --with pyarrow python harness/bench_scan.py
python3 harness/bench_release.py --compare harness/baseline/2026-10-20-0.3.1.json
  # release baseline: scan/join/gather/spill, see docs/bench-baseline.md
node harness/playground_accept.cjs http://127.0.0.1:8971/index.html
  # browser acceptance; serve playground/index.html + playground.wasm first
```

## 8. Registry package acceptance (0.3.0 and 0.3.1, 2026-10-20)

The release question is not "does the repository build" but "does what
mooncakes hands a stranger resolve, match what was tagged, and work when
imported". Measured on a scratch module (`moon new`, empty `.mooncakes`, a
fresh `MOON_HOME` so the registry index itself was cloned) with
`moon add superbigcup325/moonlake`.

**0.3.1** (the patch that fixes the browser build and DATE JSON; the check was
re-run after `moon publish` reported `Server status: 200 OK`):

- **Resolution.** `moon add` on an empty module resolved
  `superbigcup325/moonlake@0.3.1` and pulled the same graph as 0.3.0 —
  `moonbitlang/x@0.5.6`, `moonbitlang/quickcheck@0.15.0`,
  `superbigcup325/colenc@0.1.0`. `moon view superbigcup325/moonlake` reports
  `Latest: 0.3.1`, `Versions: 3`, published 2026-10-20T15:46:49Z.
- **Content.** The installed tree diffs clean against `git archive v0.3.1`
  except the same dev-only exclusions and the materialized `README.md`
  symlink; `@moonlake.version()` prints `0.3.1`.
- **Usage and the fix itself.** The README example prints `north|1` on native,
  wasm-gc and js, and `SELECT min(day)` over a DATE column now returns
  `[{"first_day":"2024-03-01"}]` — valid JSON with the date quoted — on all
  three backends. That last check is the 0.3.0 bug seen from a consumer's
  side.

**0.3.0** (first release since 0.1.0):

- **Resolution.** The add resolved `superbigcup325/moonlake@0.3.0` and pulled
  the same four packages, every one carrying a `moon.mod` (no legacy
  `moon.mod.json` anywhere). The registry index listed 0.3.0 and 0.1.0
  (`moon view --versions`), 0.3.0 with checksum `ef68f460…`, published
  2026-10-20T14:01:31Z.
- **Content.** The installed tree diffs clean against `git archive v0.3.0`
  except for the dev-only paths the package excludes (`.github`, `.githooks`,
  `.gitignore`, `.moonignore`, `hooks/`, `harness/data/`,
  `harness/spill_bench/`) and `README.md`, which arrives as a regular file
  because the archive dereferences the repository's symlink. The installed
  library reported itself as `0.3.0` (`@moonlake.version()`).
- **Usage.** The README's "As a library" example — verbatim apart from the
  consumer's `moon.pkg` imports — compiled and printed `north|1` on native,
  wasm-gc and js.

One note for the archive, not a defect: it also ships `AGENTS.md`, `docs/` and
the harness scripts (~1.3 MB). `.moonignore` deliberately keeps out only the
test data, the local hook directory and the spill driver.

## 9. Browser playground acceptance (2026-10-20)

Historical 0.3.x acceptance. The single-table limitation below was removed by
the session playground; see [§13](#13-playground-session-2026-10-21)
for its later browser acceptance.

The playground is the release's only "try it without installing" surface, and
its file-upload path had never been checked except by hand. Method: build
`playground.wasm`, serve `index.html` + the wasm from a static server, and
drive a real headless Chromium with real file-input uploads of the SF0.01
fixtures (`harness/playground_accept.cjs`). Result: 13/13 checks pass on the
fixed tree; the deployed page was tested too.

| check | result |
|---|---|
| page loads, engine version reported | `engine 0.3.0 loaded (wasm-gc)` |
| CSV upload enables Run, grouped aggregate | 3 rows, groups A/N/R |
| Parquet upload with `l_shipdate,…` DATE columns | 3 rows, groups A/N/R |
| CSV and Parquet agree on the same query | identical cells, including `532348211.6499983` |
| DATE min/max render as calendar dates | `1992-01-04 … 1998-11-29` |
| unknown column / syntax error | message shown, status `failed`, no table |
| cross-file JOIN (`lineitem JOIN orders`) | refused by name: `unknown table "orders"` |
| same-file self-join | 12 900 rows, so the engine is not the limit |
| CSV reload after Parquet | 60 175 rows |
| uncaught JS errors | none |

The acceptance found three release bugs that unit tests could not see, all
fixed on this branch:

1. **The wasm did not instantiate at all.** `playground.wasm` imported 12
   functions from the wasm host's `__moonbit_fs_unstable` module; the page
   passes no imports, so the browser threw at `WebAssembly.instantiate` and
   Run never enabled. The lazy-scan refactor made `@fs` reachable from
   `scan_string`/`scan_bytes` through a shared `read_input`; a build of
   `8b23c7d` (pre-lazy-scan) has zero such imports. Fixed by carrying the
   reader as a function field (`3f6bbe6`), and CI now builds the wasm and
   fails on any import beyond the js-string builtins.
2. **DATE was not valid JSON.** `to_json` print scalar values through
   `to_string`, so a DATE came out as a bare token (`{"lo":1992-01-04}`):
   `--json` was invalid for any DATE column, and the page's `JSON.parse` threw
   and left the previous status on screen. Now quoted (`8c38978`, with a test
   covering the quoted value and `null` inside a DATE column).
3. **The deployed page was not the release.** It reported `engine 0.1.0`, the
   last playground-triggered build; the pages workflow only watched
   `playground/**`, so none of the 0.2/0.3 engine ever redeployed. The trigger
   now covers the engine directories (`6001da4`); the live site updates on the
   next push to main.

One limitation is by design and is now documented rather than implied: the
page holds one uploaded table, so a cross-file JOIN cannot be expressed in
it. The failing path is a pointed bind error, and joins over the uploaded
table work — verified in the same run. The README no longer claims the page
shows a physical plan (that is `--explain` on the CLI).

## 10. Spill lifecycle (2026-10-21)

The out-of-core path is the engine's best claim and its least observable one:
`--memory` decides whether a query lands on it, and until now nothing checked
what the query left behind on disk, or reported what it spilled.

**The leak.** `reduce_and_merge` (`engine/extsort.mbt`) recorded each
intermediate run it wrote while merging into `created`, and only removed them
through `errdefer`, which fires when the function raises. On the success path
they stayed. The CLI then called the non-recursive `fs.remove_dir`, whose
failure was swallowed, so a directory survived as well. Measured on
`harness/data/sf001/lineitem.csv` with `--memory 200K` and an
`ORDER BY … LIMIT 3`: exit 0, correct rows, seven files (`run15.bin` …
`run21.bin`, 560 KB) left in the spill directory. Repeat that a few hundred
times and the next spilled query fails halfway through with a full disk.

Now the intermediates are removed once the merge returns, and the CLI removes
the directory its query wrote into and prints a warning when one cannot be
removed. Since the query now owns a subdirectory (see "Two processes, one
`--spill-dir`" below), that removal never has to reason about a caller's
files at all.

**Multi-level grace join.** A partition that still exceeds the budget after the
first level is partitioned again (two extra levels, 256 partitions each). The
first level used to cap the partition count at 64, so a small budget against a
large input was reported as "hash skew" even when no key dominated. A/B on the
new unit test (`engine/e2e_test.mbt`, 200k rows over 200k distinct keys, 4 KiB
budget): with `JOIN_MAX_DEPTH = 0` the test aborts with the budget error; with
the shipped value it returns the expected 100 rows in 5.9 s including the
build. What re-partitioning cannot fix — one key holding most of a side — is
still refused, and the message now says why instead of blaming the budget.

**Streamed aggregation.** Grace aggregation used to read a whole partition into
memory before aggregating it, which for a hot group key meant materializing an
arbitrarily large partition on top of the budget. It now pulls one spill file at
a time (`BatchSeq`, `engine/exec_agg.mbt`). Honest result: peak RSS on
`SELECT l_returnflag, count(*) … GROUP BY 1` at SF0.1 with `--memory 200K`
moved 305.0 → 303.7 MB, i.e. nothing measurable, because the scan's live set
dominates and the projected input is one column wide (~3 MB), so the partition
being materialized was never the peak. What changed is the bound: the
aggregation no longer has a term proportional to partition size. A fixture where
it would show needs a wide aggregation input, which the current workloads do not
have; that is a gap in the workloads, not a claim about the change.

**Two processes, one `--spill-dir`.** Every query used to write `run0.bin`,
`run1.bin` … straight into the directory it was given, and the finish purge
deleted every `run<n>.bin` it found there. Two spilled queries sharing a
`--spill-dir` therefore overwrote each other's runs and then deleted them: the
A/B with the previous binary and the current one, two concurrent queries on one
directory, is exit 1 on both sides with `spill read: No such file or directory`
before, and `count 7` / `count 9` with an empty directory after. The fix is
structural rather than defensive: a query spills into its own
`moonlake-spill-<n>` subdirectory, `create_dir` decides which one (it is the
lock; a racing process loses and moves on), and the purge only ever looks
inside the directory it created — so a caller's own files are not even listed,
let alone deleted.

**What could not be fixed without a clock or a pid.** A killed process leaves
its subdirectory behind, and the next run does not remove it: the filesystem API
in use (`moonbitlang/x/fs`) exposes no pid, no wall clock and no file timestamp,
so a dead owner and a live one look identical, and deleting on a guess would
break a running query. Measured: `kill -9` during a spilled sort leaves
`moonlake-spill-0` with 40 run files (1.8 MB); a following clean query creates
its own directory, finishes, removes it, and leaves that one alone. The leak is
therefore bounded to one directory per interrupted query, which the acceptance
pins as a known boundary. Reclaiming it needs a native syscall surface in the
CLI, which conflicts with the project's "no FFI" claim and is a decision, not a
bug fix. That decision was taken in §22: the CLI now records an owner marker and
reclaims a directory whose owner it can prove dead, and still keeps one it
cannot judge — the paragraph above is the state this section measured.

**Acceptance.** `bash harness/spill_accept.sh` (seven checks, deterministic,
~4 s):

1. a spilled `ORDER BY` leaves no directory behind;
2. a query that fails on hash skew leaves none either;
3. `--spill-dir` keeps a caller's `notes.txt` and a `runx.bin` that is not a
   run file — the query's own subdirectory is the only thing removed;
4. `--analyze --memory 200K` prints `spill runs:`, `spill files:`,
   `spill bytes written:` and `spill bytes read:`;
5. the same `ANALYZE` without a budget prints no spill line at all;
6. two spilled queries running at once on one `--spill-dir` both succeed with
   their own answers and leave the directory empty;
7. a `moonlake-spill-0` left by an interrupted run survives the next query
   (§22 restates this as "a directory with no marker survives", and adds the
   reclaiming cases; the list here is the seven this section shipped).

Counters are taken at the store boundary (one wrapper around the caller's
`SpillStore`, `engine/options.mbt`), not inside each operator, so a future
spilling operator cannot forget to report itself.

## 11. Parquet write path (2026-10-21)

The writer existed but was invisible to everyone: no CLI path, no annotations,
no statistics, no compression. A written file was a valid Parquet file that no
consumer could interpret — a DATE came back as an integer, a string column as a
BLOB — and moonlake's own statistics-based row-group skipping could not prune
its own output.

**Annotations.** `w_schema_leaf` now writes the standard `STRING` and `DATE`
annotations on both spellings: the deprecated `ConvertedType` (field 6) and the
current `LogicalType` union (field 10), because consumers disagree on which one
they look at. The reader parses both (`parse_logical_type`, plus field 6) and
acts on them: an annotated DATE column no longer needs `--date-col`, which the
writer's own round trip now demonstrates (a written DATE reads back as
`@types.Date` with no `--date-col`).

**Refusals instead of wrong answers.** An annotation with no faithful engine
type is refused at registration:

| annotation | before | now |
|---|---|---|
| DECIMAL (all physical types) | byte array decoded lossily as text | `column "x": DECIMAL is not supported (read it as DOUBLE, or cast it in the source)` |
| UINT_32 | read as INT32, large values negative | refused, names the overflow |
| UINT_64 | read as INT64, large values negative | refused, names the overflow |

On apache/parquet-testing (71 files) that moved six files from "read" to
"refused by design": `byte_array_decimal`, `fixed_length_decimal`,
`fixed_length_decimal_legacy`, `int32_decimal`, `int64_decimal`,
`concatenated_gzip_members` (which carries a UINT_64 column).

**The corpus count was measuring the wrong thing.** It asked each file for
`select count(*)`, which reads only the footer, so a file whose data pages need
LZ4, ZSTD, GZIP or v2 pages counted as "read". Reading one column through the
CLI showed 18 of the 35 decoded nothing: `hadoop_lz4_compressed` passed while
`select c0` raised `compression codec 5 is not supported`, and
`delta_binary_packed` passed although its pages are v2, so the DELTA path never
ran. The check now decodes every column (`count(<col>)`) and compares a
five-row sample against DuckDB cell for cell, and it records the class of every
file in `harness/parquet_corpus_expected.json` so a later flip fails instead of
hiding inside a count. The honest classification is **17 decoded by value, 51
refused by design, 0 failing** (three files DuckDB cannot read either are
skipped). The DELTA and BYTE_STREAM_SPLIT paths stay covered by the embedded
fixtures in `sources/parquet/colenc_integration_test.mbt`: every corpus file
that carries them also carries a v2 page or a codec outside the scope, so no
external file exercises them end to end.

**Statistics.** Each column chunk carries `null_count` plus `min_value` /
`max_value` (fields 3, 5, 6) marked exact (7, 8). The deprecated `min`/`max`
pair is deliberately not written: for BYTE_ARRAY it was defined in signed byte
order, which is a trap this reader refuses to trust on the way in. Bounds are
omitted rather than guessed when they cannot be proven: a NaN in a float column
makes min/max meaningless, and a string column containing non-ASCII bytes could
be ordered differently by a byte-comparing reader and this string-comparing one.
The whitebox test `the writer's statistics let the reader skip a row group`
writes two row groups (0–9 and 100–109) and asserts `row_groups_skipped = 1` for
`v < 50` — the loop is closed.

**Snappy.** A ~120-line LZ77 compressor in the Snappy block format (14-bit hash
table over 4-byte sequences, literals between matches, `copy2` tags) sits beside
the decoder in `sources/parquet/snappy.mbt`; `--snappy` and
`write_bytes_with`/`write_file_with` store pages compressed, and page/chunk
headers carry both sizes plus codec id 1. Measured on a 4000-row text table:
140,274 → 24,323 bytes. Round-trip tests cover empty, sub-match, a 200-byte run,
incompressible bytes and a 200 KB block (the 64 KiB offset window).

**Bidirectional acceptance.** `harness/check_writer_interop.py` (new CI job
`writer`) writes the same four-row table raw and with Snappy, then:

1. pyarrow reads it: `string`, `date32[day]`, `int32`, `int64`, `double`, `bool`
   — and the NULLs and the `é` string survive;
2. DuckDB reads it: `VARCHAR`, `DATE`, `INTEGER`, `BIGINT`, `DOUBLE`,
   `BOOLEAN`, same values;
3. moonlake reads it back with no `--date-col`;
4. DuckDB writes its own file (`COPY … TO … (format parquet)`) and moonlake
   reads that one with no `--date-col` either.

The CLI form is `moonlake write --csv in.csv --out out.parquet [--snappy]
[--table <name>]`; the library form is `write_file_with(path, entry, codec)`.

**One pass instead of a materialized input (2026-10-21).** The writer used to
call `entry.scan(...)`, which returns `Array[DataBatch]` — the whole projected
table — and it walked that array twice: once to decide REQUIRED vs OPTIONAL per
column (the schema is file-wide) and once to write. It now walks one
`BatchStream` (`TableEntry::stream`) and writes each page as its batch arrives,
because every column is written OPTIONAL: an OPTIONAL schema is the only one
that can be declared before the first page and still describe a later NULL, so
giving up REQUIRED is what removes the pre-pass. The cost is the definition
levels: 600,572 rows × 16 columns grew the SF0.1 lineitem file by 18,816 bytes
(75,155,785 → 75,174,601, 0.03%), because the hybrid RLE stream compresses a run
of ones to a few bytes. Measured peak RSS on the same data (native release):

| input | before | after |
|---|---|---|
| `--csv` (raw) | 456 MB | 421 MB |
| `--csv --snappy` | 401 MB | 351 MB |
| `--parquet` (raw, 84.8 MB) | 407 MB | 328 MB |
| `--parquet --snappy` | 286 MB | 203 MB |

What was left in that pass was not the writer's own buffering: the sources read a
whole file into `Bytes` (75 MB CSV, 84.8 MB Parquet) because the fs API has no
range reads, and `write_bytes` still accumulated the whole archive before handing
it to `write_bytes_to_file`. The CSV path was already dominated by the scan
itself (`count(*)` over the same CSV costs 341 MB on its own). The archive copy
is gone since §19: `write_file_with` streams on native targets.

## 12. EXPLAIN row reporting (2026-10-21)

`EXPLAIN` described what a scan would do (projection width, pushed predicates,
row groups read) but never how many rows. The information existed for free:
`ScanPlan.rows` is `Some` for a Parquet footer and for a materialized entry, and
`None` for a lazy CSV scan, and it had no consumer at all.

The scan line now prints `rows: <n>` or `rows: ?`, and the guard is removed so a
materialized table reports its count too (it used to be skipped because the line
was only built for lazy entries). Nothing is estimated: the engine has no
cardinality model, and a number produced by one would be indistinguishable from
the exact ones in the same list.

```
scan lineitem (0 cols)
  rows: 600572
  row groups: 5 of 5 read
```

Covered by `engine/e2e_test.mbt` ("explain prints the row count it knows, and ?
when it does not"), and end to end by `harness/check_writer_interop.py`, which
requires `rows: 4` over a written four-row file and `rows: ?` over the same data
as a CSV.

## 13. Playground session (2026-10-21)

The page used to hold one table: uploading a second file replaced the first,
a cross-file JOIN could not even be expressed, and the bridge rebuilt the
catalog on every run. That was a bridge limitation, not an engine one, and it
was the wrong limitation for a demo that leads the README.

**Session bridge.** `playground/lib.mbt` now keeps one `@ref.Ref[@catalog.Catalog]`
for the lifetime of the wasm instance and exports `add_csv`, `add_parquet`,
`drop_table`, `tables`, `query`, `plan`, `reset` and `version`. Two decisions
worth naming:

- a duplicate table name is an **error** (`table "t" is already registered;
  drop it first`), not a silent replacement. The page shows the table list, so
  a rename or a drop is visible there; "the second upload quietly replaced the
  first" is not;
- `plan` returns `engine.explain`'s text, which since §12 includes the scan row
  count, so the panel answers "what will this read" as well as "what will it do".

`Catalog::drop` is the library-side equivalent (a missing name is a no-op; a
caller that cares can `lookup` first).

**Page.** Several files at once (input `multiple` or drag-and-drop), a table
list with `name (col:type, …)` and a per-table drop, Run / Plan / Clear, a
`<pre>` for the plan, and the engine version on `document.body.dataset.engine`
as well as the status line — the status line is rewritten as the session
changes, so a reader that needs the version asks the attribute.

**Acceptance.** `harness/playground_accept.cjs`, 15 checks, now run on every PR
by the new `playground` job (`moon build --target wasm-gc playground`, then
Playwright + Chromium in the working tree):

| # | check |
|---|---|
| 1 | the wasm loads and reports `0.3.1` |
| 2 | two files in one upload become two tables |
| 3 | the table list shows `id:int32, k:int32` |
| 4 | a cross-file JOIN returns the expected 3 pairs (it used to be refused) |
| 5 | the plan panel shows `scan t1` and a `rows:` line |
| 6 | a duplicate name is refused |
| 7 | a dropped table is gone and the query names it |
| 8 | Clear empties the session and disables Run |
| 9 | CSV and Parquet of SF0.01 agree cell for cell (`60175 | 1992-01-04 | 1998-11-29`) |
| 10 | DATE renders as `yyyy-mm-dd` on both paths |
| 11 | a JOIN across the two uploaded copies runs (301,389 rows) |
| 12 | an unknown column surfaces and marks the run failed |
| 13 | a failed query sets the status to `failed` |
| 14 | a syntax error surfaces |
| 15 | no uncaught JS error across the run |

The wasm still imports nothing but the JS-string builtins (the PR gate asserts
it), so the page needs no server-side anything.

## 14. Release provenance (2026-10-21)

A release had no automated claim of what it was. The 0.3.x series was published
from a manual checklist, and the checklist had already drifted: `v0.3.1` sits
two commits after the version-bump commit `61a6cc4`, and the baseline record
committed *inside* the tagged tree names `3d766de` as its commit.

`harness/check_release.py` checks three claims and a `release` workflow runs it
on every `v*` tag:

1. **the version claims agree** — `moon.mod` `version`, the library
   `VERSION` constant in `moonlake.mbt`, the newest versioned `CHANGELOG`
   heading (an `## [Unreleased]` section is skipped: it is work in progress,
   not a claim), and the tag name when the check runs on a tag. Disagreement
   names every value.
2. **the archive is the one intended** — `moon package --list` must contain
   `moon.mod`, `README.md`, `LICENSE` and `moonlake.mbt`, no dot-prefixed path
   (a dot-directory at any depth, or `.env`) and none matching `moon.work`,
   `_build/`, `target/`, `__pycache__/`, `harness/data/`,
   `harness/spill_bench/`, `harness/kernel_bench/` or `hooks/`. That is the only
   trustworthy preview of an archive: `.git/info/exclude` is never consulted for
   packaging and a `.moonignore` replaces a directory's `.gitignore`.
   `/harness/kernel_bench/` was excluded alongside the existing spill driver in
   the same change.
3. **the tree is clean**, so the archive cannot carry a half-finished edit.

`--publish-dry-run` adds the publish gate the project already used (it unpacks
the archive in a temp directory and checks it there). It needs credentials —
`moon publish` reads them from the moon home — so it is opt-in and stays a
maintainer step; the verdict is the `Server status: 202` line, because the CLI
exits non-zero after a successful dry run.

Two staging details, both learned the hard way in this change: `moon package
--list` writes its file list to **stderr**, mixed with the `moon check` progress
lines it runs first; and the archive's last stderr line is `Package to
…/publish/<module>-<version>.zip`, which is not a file in the archive.

## 15. Development verification fixes (2026-10-22)

Current source reports `0.4.0-dev`, while the latest published stable package
is 0.3.1. The development version agrees in `moon.mod`, the library constant,
the generated interface and the newest CHANGELOG heading; it does not claim
that the session playground or the subsequent writer/spill changes have been
published. `preferred_target = "wasm-gc"` is now explicit. The native nightly
and pre-commit hook both use `moon test --target native`.

**Reference tool drift.** DuckDB 2.0.0 removed relation `fetchone()`. The writer
check and Parquet fixture generator failed on that call, while the corpus
gate caught its `AttributeError` and could skip every file with a zero exit.
Single-row queries now use `execute(...).fetchall()[0]`: the complete fetch
also matters because 2.0 rejects a relation query while an earlier cursor
result is unfinished. Only `duckdb.Error` becomes a referee refusal; a Python
error fails the check. A recorded file missing from verified results fails
too, and an empty `--update` cannot erase the record. Seven Python regression
tests cover real Parquet input, invalid input, an API failure, a successful
gate, all-skipped and missing-input gates, and an empty update.

**Environment and results.** Local validation used `moon 0.1.20261016`,
`moonc v0.10.16`, Python 3.12.14, DuckDB 2.0.0 and PyArrow 26.0.0. CI uses
Python 3.12 and the exact reference package versions in
`harness/requirements.txt`, and prints their versions before checking data.

- `moon check --deny-warn`, interface regeneration and formatting pass;
  the only `.mbti` change is the development version constant.
- Native, wasm-gc (also the default) and JS each pass 212 tests.
- The offline release archive check passes: all version claims agree and
  `moon package --list` contains 148 files, with no forbidden development path.
  `moon publish --dry-run` also unpacked that archive and passed its own
  `moon check`. The server-side dry run is pending: it uploads the archive to
  mooncakes.io and that upload has not been authorized.
- In a disposable checkout, regenerate TPC-H SF0.01, Parquet fixtures and
  multigroup data with the pinned tools, then run `harness/check_all.sh`:
  all 27 golden queries, spill sort/join/aggregate equivalence and the
  Parquet fixtures pass. The working checkout's tracked data is unchanged.
- `harness/check_writer_interop.py` passes raw/Snappy reads by PyArrow and
  DuckDB, moonlake readback, DuckDB-written input, row-count plans and the
  compression check (140,290 to 24,340 bytes for 4,000 rows).
- The cached 71-file apache/parquet-testing snapshot yields 17 decoded by
  value, 51 refused by design, 0 failing, and 3 files DuckDB cannot read.
  Unsupported physical-type errors now name the actual column rather than
  printing `{el.name}`.
- All 7 spill lifecycle checks and all 15 real Chromium playground checks
  pass. The browser reports `0.4.0-dev`, including after the session changes.

Reproduce the Python checks with:

```bash
uv run --python 3.12 --with-requirements harness/requirements.txt python -m unittest discover -s harness -p 'test_*.py'
uv run --python 3.12 --with-requirements harness/requirements.txt python harness/check_writer_interop.py
uv run --python 3.12 --with-requirements harness/requirements.txt python harness/check_parquet_corpus.py
```

These are local development results. The previous published-package evidence
remains in §8; a 0.4.0 tag, publication, registry-consumer acceptance and a
check of the newly deployed public page are separate release steps. Whole-file
output buffering and reclaiming a killed query's spill directory still require
filesystem APIs that the current dependency does not expose (both have landed
since: §19 for the writer, §22 for spill reclamation).

## 16. Archive consumer and deployed-page acceptance (2026-10-22)

An unpacked archive passing `moon check` does not prove that another module
can import its public API. `harness/check_consumer.py` now packages moonlake,
extracts that zip into a temporary directory and copies `harness/consumer/`
into a separate module. The workspace contains only the extracted package and
the consumer. A fresh `MOON_HOME` links the installed compiler/core and fetches
its own registry and dependencies; it does not copy credentials, the working
checkout's dependency cache or a local colenc workspace override.

The consumer uses only the public API: the facade's version and CSV query,
raw and Snappy Parquet write/read, DATE annotation and NULL handling, and
`Catalog::drop`. All three targets (native / wasm-gc / js) return the exact
expected values. `--json-out` records the archive SHA-256, toolchain, source
mode, version and per-target results. The current archive contains 150 files;
the consumer fixture is a development driver excluded by `.moonignore` and
the release gate's forbidden-path check.

```bash
python3 harness/check_consumer.py
python3 harness/check_release.py --check-consumer --json-out /tmp/release-provenance.json
```

The per-PR `check` job and the release workflow now run this gate. It only
downloads public dependencies: no archive is uploaded and no login is needed.
Six regression tests check that the version comes from the zip, workspace
overrides and escaping zip paths are refused, stale versions and wrong values
fail, and the temporary toolchain home does not copy credentials or registry
state. Together with the corpus-gate tests, all 13 Python tests pass. Native,
wasm-gc and JS each still pass the 212 MoonBit tests; public library interfaces
are unchanged (the new executable fixture has an empty generated interface).

Archive-consumer evidence is deliberately distinct from registry installation.
After publishing a new release of the current API, the same consumer can run
with `--registry-version <version>`: no workspace is created, and the package
must resolve from mooncakes. That post-release path has not been exercised for
0.4.0, which remains unpublished.

**Remote and browser evidence.** The already-pushed `4e58b3d` passed
[CI](https://github.com/superbigcup325/moonlake/actions/runs/39762647767),
[nightly](https://github.com/superbigcup325/moonlake/actions/runs/39763417840)
and [Pages deployment](https://github.com/superbigcup325/moonlake/actions/runs/39762647802).
The public page was then driven with real Chromium: it reports `0.4.0-dev`
and passes all 15 scenarios. The acceptance now requires the exact version in
`moon.mod`, not merely a version-shaped string. A deliberate
`MOONLAKE_EXPECT_VERSION=0.0.0-stale` run returns exit 1 with 14/15 checks:
only the version check fails, while the 14 functional checks still pass. This
proves that a working page with the wrong release identity is rejected.

These remote runs predate the new consumer and version-gate changes; their
verification is local until those changes are pushed. The server-side publish
dry run and actual release remain separate from these checks.

## 17. Non-finite doubles in JSON (2026-10-23)

`--json` and the browser page share one encoder, `SelectResult::to_json`. It
printed every other scalar through `to_string`, so a DOUBLE infinity or NaN
came out as the bare token `Infinity` / `-Infinity` / `NaN`. Those are not JSON:
a strict parser rejects the whole line, and the page's `JSON.parse` fell into
its error path instead of rendering the row. The arithmetic was never wrong —
integer division is DuckDB's true division, so `x / 0` is inf and `0.0/0.0` is
NaN by design — so the encoder was the defect.

Contract, unchanged for the values that already worked: SQL NULL is `null`,
DATE is a quoted `YYYY-MM-DD`, a finite DOUBLE is a JSON number, and the three
non-finite values are the strings `"Infinity"`, `"-Infinity"` and `"NaN"`.
This diverges from DuckDB on purpose, and that was measured rather than
assumed: `to_json(1.0::DOUBLE/0.0)::VARCHAR` returns the bare token `Infinity`
(it is not a quoted string and not equal to `to_json('Infinity')`), so DuckDB's
own document is the one strict parsers reject. Encoding them as `null` would
have bought compatibility at the cost of hiding a real value.

**Before**, at `c651e67`:

```bash
moon run --target native cmd/main -- exec --csv harness/data/sf001/nation.csv --json \
  "SELECT 1.0/0.0 AS pos_inf, -1.0/0.0 AS neg_inf, 0.0/0.0 AS nan, 1.5 AS ok, NULL AS nil, 'a\"b' AS s, DATE '2024-03-01' AS d LIMIT 1"
# [{"pos_inf":Infinity,"neg_inf":-Infinity,"nan":NaN,"ok":1.5,"nil":null,"s":"a\"b","d":"2024-03-01"}]
# node: JSON.parse -> Unexpected token 'I', ..."pos_inf":Infinity,"..." is not valid JSON
```

**After** the fix, the same command prints

```text
[{"pos_inf":"Infinity","neg_inf":"-Infinity","nan":"NaN","ok":1.5,"nil":null,"s":"a\"b","d":"2024-03-01"}]
```

and Node's `JSON.parse` returns an object with `pos_inf === "Infinity"`,
`nil === null` and `ok === 1.5`. `moon test engine` pins the same line
(`to_json keeps non-finite floats parseable without hiding them`) and parses it
with `moonbitlang/core/json`, so parseability is asserted rather than implied.
`to_json`'s signature and the `/` semantics are unchanged.

**Local evidence at `3022a0a`.** Gates: `moon check --deny-warn`,
`moon fmt --check`, 213 MoonBit tests on each of native / wasm-gc / js, 13
Python regression tests, `check_writer_interop.py`, all 7 spill acceptance
checks, and the offline release provenance (150-file archive, version claims
agree). The archive consumer runs the public API from that zip on all three
targets against a fresh registry cache. Browser: `harness/playground_accept.cjs`
passes 16/16 against the built wasm in real Chromium, the new scenario being a
`l_quantity / 0` row that must show `Infinity` / `NaN` while the status stays a
row count. The playground wasm still imports nothing beyond the js-string
builtins, so the host-free gate is unaffected.

These are local results for an unpublished development version; the pushed
`4e58b3d` CI/nightly/Pages evidence in §16 does not cover this commit.

## 18. 0.4.0 release (2026-10-23)

Tag `v0.4.0` (annotated, on `ba039f3`) and
[the GitHub release](https://github.com/superbigcup325/moonlake/releases/tag/v0.4.0)
were created only after the same SHA passed CI, nightly and Pages, and after
`moon publish --dry-run` returned `Server status: 202 Accepted`.

**Publish.** `moon publish` (run through a scratch `MOON_HOME`, because the
default toolchain home is not writable here) unpacked the archive, passed its
own `moon check` on the extracted package and reported **`Server status: 200
OK`** against mooncakes.io. `moon view superbigcup325/moonlake` now reports
`Latest: 0.4.0`, published `2026-10-23T11:47:30Z`, four versions total.

**Registry consumer.** `harness/check_consumer.py --registry-version 0.4.0`
resolved the package from mooncakes with a fresh registry and dependency cache
and no workspace override; native, wasm-gc and JS all return the expected
version, CSV query, raw/Snappy Parquet round-trips, DATE/NULL values and table
removal. The run's JSON report stays out of the repository. Evidence boundary:
this is a registry install of a **released** artifact, not the archive gate of
§16.

**Tag-triggered release workflow, first run ever.** `release.yml` had never
executed through its tag trigger (0 runs before this release). On the tag push
it ran green and checked the version claims including the tag
(`moon.mod` / `moonlake.mbt` / CHANGELOG), the archive contents (163 files, no
forbidden path) and the archive consumer on all three targets
([run](https://github.com/superbigcup325/moonlake/actions/runs/39948442827)).
The pre-tag CI and the dispatched nightly on `ba039f3` were green
([CI](https://github.com/superbigcup325/moonlake/actions/runs/39947476168),
[nightly](https://github.com/superbigcup325/moonlake/actions/runs/39947618462)),
and Pages deployed that SHA
([pages](https://github.com/superbigcup325/moonlake/actions/runs/39947476021)).

**Deployed page.** The public page was driven in real Chromium with
`MOONLAKE_EXPECT_VERSION=0.4.0`: 16/16 checks pass, including the exact version
and the new non-finite-double row (`Infinity` / `NaN` render, status stays a row
count). The page and the tag therefore agree on the release identity.

**Performance.** Two records were taken on this machine for the release
(`harness/baseline/2026-10-23-0.4.0.json` and a same-session 0.3.1 re-record
from tag `v0.3.1`). The comparison refuses the spill case by design (0.3.1's
output is wrong) and shows the sort fix costs ~16% CPU on that case; the
scan/join deltas in that pair did not survive an interleaved A/B control
(~5%), and `docs/bench-baseline.md` says so with numbers.

Release limitations, unchanged at the time: the writer still buffered its whole
output, a SIGKILLed query's spill directory was not reclaimed (both waited on a
native I/O decision), and non-finite doubles are strings rather than DuckDB's bare
tokens. The first of these is resolved since §19 on native targets; the spill
reclamation landed in §22.

## 19. Incremental Parquet output (2026-10-23)

The writer accumulated its whole archive in a `Buffer` and then handed that one
`Bytes` to `write_bytes_to_file`, so peak memory grew with output size — the
larger the file, the more copies of it were alive. `write_file_with` now streams
on native targets: pages go to a file handle as they are encoded, a temporary
name is renamed over the target on success, and the signature is identical on
every backend. This section is the evidence for what shipped: the route, the
routes rejected and the contract the binding has to keep.

**Mechanism.** `platform/io` is a whole-package native-only binding (`O_WRONLY`
open, `write` with EINTR retry, `fsync`, `close`, `rename`, `unlink`, `strerror`)
declared with `native-stub` and target-gated files, so wasm-gc/js build an empty
package and the published interface stays target-independent. The writer keeps
owning byte offsets: `write.mbt` exposes `pub type Emit = (Bytes) -> Unit raise
@types.SqlError` and one `write_with(entry, codec, emit)` flow; `write_bytes_with`
emits into a `Buffer`, and `write_file_with` is a shared wrapper over a
target-split private impl (`write_file_native.mbt` streams, `write_file_other.mbt`
keeps the whole-file write the wasm/js hosts require). A sink never reports a
position — a transport that miscounts bytes is exactly how a Parquet footer ends
up pointing past its data — and the 2 GiB page-offset guard still runs on an
`Int64` writer-side counter.

**Same bytes.** The transport changed, the format did not: for both codecs the
file produced by the streaming path is byte-identical to `write_bytes_with`
(`write_file_test.mbt`), and identical to the archive the previous, non-streaming
build wrote from the same input (md5 `84a4dfd8…` raw 1×, `7ccb79e3…` from Parquet
input raw, `938430a5…` snappy; 2× and 4× inputs likewise).

**Failure behaviour.** A write publishes nothing until it succeeds: the target
keeps its previous contents and the temporary file is gone both when `finish`
fails (rename onto a directory is the test case) and when the process aborts the
sink explicitly. A write into a non-existent directory fails naming the path and
creates nothing. An emit failure stops the writer where it failed (whitebox test)
instead of after the whole table was encoded.

**Peak memory** (native release, one isolated child per run so `ru_maxrss` is
that run's own high-water mark; SF0.1 `lineitem`, 75 / 151 / 302 MB inputs):

| input → output | before | after |
|---|---|---|
| `--csv` 75 MB → 75 MB | 427.7 MB / 1.02 s | 336.9 MB / 0.91 s |
| `--csv` 151 MB → 150 MB | 799.3 MB / 1.97 s | 547.6 MB / 1.75 s |
| `--csv` 302 MB → 301 MB | 1411.1 MB / 4.13 s | 1066.5 MB / 3.92 s |
| `--parquet` raw (75 MB out) | 326.3 MB / 0.75 s | 100.8 MB / 0.70 s |
| `--parquet --snappy` (34 MB out) | 199.4 MB / 0.86 s | 100.8 MB / 0.89 s |

The removed term is the archive-sized second copy. With a Parquet input the new
peak is flat at ~101 MB regardless of codec and output size; the remaining CSV
growth is the scan's own memory, which is the CSV range reader's subject, not
the writer's.

**Gates.** `moon check --deny-warn` on native, wasm-gc and js; 223 / 218 / 218
tests; 27 golden queries; spill 7/7; `check_writer_interop.py` (pyarrow and DuckDB
read the streamed files raw and Snappy); `moon package --list` ships
`platform/io/io_native.c`. The interface gained exactly one line
(`pub type Emit = (Bytes) -> Unit raise @types.SqlError`).

Not done here: the 2 GiB page-offset limit still refuses larger files, and the
sources still read a whole file because the fs API has no range reads yet.

## 20. Parquet range reads (2026-10-23)

Registration used to read the whole file even though it kept none of it: the
reader's input was `() -> Bytes`, so "open a Parquet table" allocated a buffer
the size of the archive, and the footer parse, the row-group statistics and the
first decoded chunk all worked off that copy. Peak memory was therefore the file
plus the decode working set, and the fs API in use (`moonbitlang/x/fs`) has no
range read at all.

**Mechanism.** `platform/io` — the native-only binding introduced for the write
path — gained a read side: `open_read` (`O_RDONLY`), `size` (`fstat`) and
`pread` (positioned, EINTR-retried, returns the byte count). `FileReader` wraps
them as `open` / `size` / `read_at(offset, length)` / `close`, and `read_at`
refuses a range that does not fit the file instead of returning a short read.
The reader's input became `ParquetInput { size, read_at }`: an in-memory input
slices, a native file input does one `pread` per range, and the wasm/js input
keeps the whole-file read those hosts require. Because `read_at` is a function
field rather than an enum with a `File` arm, a build that only scans in-memory
content (the browser playground) still does not link the fs module, and
`scan_bytes` is unchanged.

Two reads replace the whole-file parse:

- `read_footer` reads the last 8 bytes, checks the `PAR1` magic and the
  little-endian footer length, then reads exactly the footer body and parses it.
  A length whose top bit is set reads back negative and is rejected as such
  rather than turned into an offset.
- `decode_chunk` asks for one column chunk at a time (`chunk_range` keeps
  `Int64` offsets, since a footer stores them that way) and decodes it from a
  buffer that starts at 0, so every page offset inside the chunk is unchanged
  and the decoder never learns where the chunk lives. A chunk larger than 2 GiB
  is refused by column name instead of being narrowed silently.

**Nothing is read twice per query, but the footer is parsed more than once.**
`scan_file` parses it at registration, and `open` parses it again for each
query. On a 287 MB archive that is ~2 KB of reads per parse — the flat
`count(*)` peak below is that cost made visible.

**Peak memory and wall time** (native release, one isolated child per run so
`ru_maxrss` is that run's own high-water mark; SF0.1 `lineitem` multiplied 4× and
8×, written by this build so both sides read the same file):

| query | before | after |
|---|---|---|
| `count(*)`, 287 MB raw | 295.1 MB / 0.169 s | **12.3 MB** / 0.023 s |
| `sum(l_quantity)`, 287 MB raw | 323.1 MB / 0.196 s | **37.2 MB** / 0.056 s |
| `count(*)`, 574 MB raw | 584.6 MB / 0.450 s | **12.2 MB** / 0.044 s |
| `sum(l_quantity)`, 574 MB raw | 629.9 MB / 0.531 s | **67.0 MB** / 0.115 s |
| `count(*)`, 132 MB Snappy | 139.1 MB / 0.101 s | **12.2 MB** / 0.024 s |
| `sum(l_quantity)`, 132 MB Snappy | 169.1 MB / 0.145 s | **37.2 MB** / 0.079 s |
| `count(*) WHERE` 3 columns, 287 MB raw | 297.2 MB / 0.447 s | **12.2 MB** / 0.351 s |

Three repeats of `sum(l_quantity)` on the 287 MB file: 323.0 / 322.7 / 323.0 MB
before, 37.1 / 37.2 / 37.2 MB after. The before numbers track the input size
(295 MB peak for a 287 MB file, 585 MB for 574 MB, 139 MB for the 132 MB Snappy
file), which is the point: they were the file. The after numbers do not — a
metadata-only query is flat at ~12 MB at both sizes, and a one-column aggregate
is bounded by the row-group columns in flight (37 MB at 4×, 67 MB at 8×), not by
the file — which is why the three-column `count(*) WHERE` row stays under the
one-column aggregate: it reads its predicate columns, but keeps only a row mask
instead of a column to aggregate. Wall time fell with the removed copy-and-touch pass, most visibly on
`count(*)` where the old path paid a full read to answer from the footer.

**Same answers.** Over the 2.4 M-row 287 MB archive, results match DuckDB
exactly for row counts (`2402288`; `3604` for the three-column predicate; `342756`
for the ship-mode filter) and within floating-point summation order for the
sums (`sum(l_quantity)` = `61339208` on both; `sum(l_extendedprice)` differs in
the last four digits, `86463717120.96204` vs `…95938`, as the two engines add the
same values in different orders).

**What the tests pin**, because no round-trip test can tell a range reader from a
whole-file reader — both are correct:

- a whitebox test installs an input that records every range. Registration is
  exactly two reads (the 8-byte tail, then a body ending where the tail starts),
  a one-column scan is exactly one chunk starting at byte 4, and a two-column
  scan is two ranges in file order (the second begins where the first ended, so
  the reader seeks rather than streams). The fixture is 256 rows so the bytes
  read stay a small fraction of the file.
- the two guards are exercised directly: a 2,000,000,001-byte chunk is refused
  before any read is attempted and names the column, and a read past the end of
  the input names the column and the byte range.
- footer failures are covered from files on disk on every backend: a truncated
  trailer (`missing PAR1 magic at the end of the file`), a `0xFFFFFFFF` footer
  length (`footer length … does not fit`), a 4-byte file (`too short to be
  Parquet`), and a path that does not exist (the message names it).
- `FileReader` itself has its own tests in `platform/io`: exact ranges at head,
  middle and tail of a written file, two reads in a row that must not disturb
  each other (positioned reads, not a seek and a read), the past-the-end refusal,
  a closed reader, and a missing path.

**Gates.** `moon check --deny-warn` on native, wasm-gc and js; 236 / 227 / 227
tests; 27 golden queries; spill 7/7; `check_writer_interop.py`. The release archive
gains exactly the four new `sources/parquet` files and still ships the one C
file, `platform/io/io_native.c`, which the write path already required. The published
interface gained nothing: `platform/io` is native-only, so its generated
interface stays empty on the default target, and `sources/parquet`'s public
signatures are unchanged.

Not done here: the writer's 2 GiB page-offset limit still refuses larger files
(a reader no longer needs the relaxation, a writer still does), CSV scans still
read whole files (the remaining memory term), and wasm-gc/js scans still
read the whole file because their fs module cannot do better.

## 21. CSV range reads (2026-10-24)

Registration used to read the whole CSV and keep it: the source's input was
`() -> Bytes`, so opening a table allocated a buffer the size of the file, and
the byte-level reader then indexed **every cell of the file at once** — one
`Int32` start, one `Int32` end, one `Bool` quoted flag per cell, plus a row
table. That index, not the bytes, was the dominant term: roughly 9 bytes per
cell, about 28 per lineitem row, ~700 MB for a 4× copy of SF0.1. A scan only
ever needs the rows of the batch it is building, so the whole index was paid for
one 4096-row slice at a time.

**Mechanism.** `CsvInput` became `{ label, size, read_at, reset }` — the shape
the Parquet reader took in §20 — and `scan_file` is target-split: native reads
4 MB ranges through `platform/io`, wasm-gc/js keep the whole-file read their
hosts require (with `reset` dropping the snapshot when a scan opens, so a table
still sees the file as it is then, exactly as the ranged native input does).
Registration reads a 64 KB prefix — header plus the 100-row inference sample —
and grows it only when a row does not fit. A scan then reads one range at a
time: `scan_chunk` indexes it, `RawCsv::cut_rows` trims it to whole 4096-row
batches, those batches are materialized, and the range is dropped before the
next read. Rows past the last whole batch are re-read as the start of the next
range, so no batch straddles two ranges and no row is lost or counted twice. A
range that cannot hold one record (a very long quoted field) is widened until it
can, which is what keeps a quoted multi-line field one row rather than a
fragment. The header is re-checked at the first range of every file, so a file
that changed under a registered table is refused instead of mis-read, and error
messages carry absolute file row numbers (`row_base`), so a bad cell in the
fourth range reports the row a whole-file scan would have reported.

**Peak memory** (native release, one isolated child per run so `ru_maxrss` is
that run's own high-water mark; SF0.1 `lineitem`, 75 / 151 / 302 MB inputs):

| query | input | before | after |
|---|---|---|---|
| `count(*)` | 75 MB | 327.8 MB / 0.30 s | 34.2 MB / 0.17 s |
| `sum(l_quantity)` | 75 MB | 326.2 MB / 0.32 s | 39.1 MB / 0.17 s |
| `count(*)` | 151 MB | 537.7 MB / 0.65 s | 35.1 MB / 0.31 s |
| `sum(l_quantity)` | 151 MB | 538.5 MB / 0.68 s | 47.1 MB / 0.34 s |
| `count(*)` | 302 MB | 1062.7 MB / 1.36 s | 35.2 MB / 0.64 s |
| `sum(l_quantity)` | 302 MB | 1062.6 MB / 1.45 s | 57.4 MB / 0.66 s |
| `l_returnflag, count(*) GROUP BY` | 302 MB | 1062.9 MB / 1.44 s | 97.1 MB / 0.79 s |

The before column tracks the input size, because it *was* the input plus its
index. The after column does not: a metadata-only query is flat at ~35 MB at
1×/2×/4×, and a one-column aggregate grows only with the columns in flight
(39 → 57 MB as the input quadruples), not with the file. The grouped query is
the honest ceiling here: its peak is the scan term plus the group table it builds
(97 MB at 2.4 M rows).

**The write path was paying the same term.** With the CSV reader chunked,
`write --csv` no longer materializes the file to write it (input and output as
before, one isolated child per run):

| input → output | before | after |
|---|---|---|
| 75 MB → 75 MB | 320.1 MB / 0.99 s | 35.0 MB / 0.83 s |
| 302 MB → 301 MB | 1062.7 MB / 3.95 s | 34.9 MB / 3.23 s |

That closes the open item §19 named — "the scan itself grows with the file (4×
still costs 1066 MB)" — and the writer is now flat for both input formats.

**Same bytes, same answers.** The archives are unchanged: md5 `84a4dfd8…` for
the 1× write and `043b084c…` for the 4× write, identical between the two builds
and to what the pre-streaming build produced for 1×. Over the 2.4 M-row 302 MB
file, row counts (`2402288`), `sum(l_quantity)` (`61339208`) and the
`l_returnflag` groups (`A 591160 / N 1217924 / R 593204`) match DuckDB exactly,
on the CSV and on the Parquet file written from it.

**What the tests pin**, because a chunked reader and a whole-file reader return
the same rows and only one of them is bounded:

- a whitebox test installs an input that records every range. Registration is
  bounded by the 64 KB prefix, the largest scan read is exactly the 4 MB range,
  and the bytes read stay under the file plus one range; the 100,000-row fixture
  produces 25 batches, 24 of them full, and the last row decodes to its value.
- range boundaries are invisible in the rows: a fixture whose every row carries
  a newline inside a quoted field (so most boundaries fall inside a quoted
  field) yields exactly 165,000 rows and the expected string; a single quoted
  field longer than one range (4.25 MB) still arrives as one row, and that test
  asserts the range had to grow to read it.
- error numbering survives chunking: a bad cell at data row 99,000 — in the
  second range — reports `row 99002 column 0`, the number a whole-file scan
  would give.
- a header that changed under a registered table is refused when the scan opens,
  with the message naming the file.
- the blackbox suite keeps its existing 11 CSV tests unchanged, including the
  5000-row 4096 + 904 batch split and the multi-file glob.

**Gates.** `moon check --deny-warn` on native, wasm-gc and js; 241 / 232 / 232
tests; 27 golden queries; spill 7/7; `check_writer_interop.py`; `moon package
--list` still ships the one C file, `platform/io/io_native.c`. The published
interface gained nothing: `CsvInput` is private, `platform/io` is native-only,
and `sources/csv`'s public signatures are unchanged.

Not done here: wasm-gc/js still hold the file bytes (their fs module has no range
read, and the browser build has no filesystem to read ranges from), the writer's
2 GiB page-offset limit still refuses larger files, and spill-lease reclamation
was untouched at this point -- it landed the same day, in §22.

## 22. Spill directory reclaim (2026-10-24)

§10 pinned a boundary and called it a decision: a killed query leaves its
`moonlake-spill-<n>` subdirectory behind, and the next run must not remove it,
because `moonbitlang/x/fs` exposes no pid, no clock and no file timestamp, so a
dead owner and a live one look identical. Measured then: `kill -9` during a
spilled sort left 40 run files (1.8 MB) that nothing would ever clean up. One
directory per interrupted query, forever.

**The three facts that prove an owner dead.** A spill directory now carries an
`owner` marker, written immediately after `create_dir` succeeds:

```
version=1
pid=4242
boot_id=d82cf1fc-0ad6-4062-9f3b-9d87d4e1872f
starttime=5658786        field 22 of /proc/4242/stat
nonce=4242-1761310000    which claim this was; readable in a postmortem
created_at=1761310000    seconds since the epoch
```

Only `pid`, `boot_id` and `starttime` take part in the verdict, and all three
are needed:

* the recorded boot id differs from this boot → the owner died before the
  machine came back, so the directory is stale;
* `/proc/<pid>` is gone → stale;
* `/proc/<pid>` exists but its start time differs → the number was reused by a
  different process, so the owner is gone and the directory is stale too.

Everything else is "cannot tell" and the directory is kept: no marker at all,
an unknown version (a newer build may write rules this one must not delete), a
parseable marker with a field missing, no `/proc` on the platform, a probe that
errors. Deleting on a guess is how a live query loses its run files, and a
leaked directory under `TMPDIR` is the smaller problem.

**Claim and reclaim order.** The marker is created with `O_CREAT|O_EXCL`
(`write_new_file`), never overwritten: a directory belongs to whoever claimed it
first, and `create_dir` remains the lock on the *index*. Reclaiming looks before
it deletes: a directory holding a file the protocol did not write is left alone
and reported, not half-emptied. Otherwise it renames the marker to
`owner.stale-<nonce>` — that rename is the claim among concurrent reapers,
exactly one of them wins it — then deletes only `run<n>.bin` and the marker names
this protocol writes, then removes the directory. A reclaim interrupted after
the rename leaves a marker-less directory, which the "cannot tell" rule keeps
rather than emptying again and again.

**Where the code lives.** `cmd/main/spill_owner.mbt` holds the rules as a pure
function, `judge_owner(mark, boot_id_here, probe)`, plus the parser, the
inspection and the reclaim order; `spill_owner_native.mbt` supplies the machine
facts (`/proc`, the exclusive create, the rename) and `spill_owner_other.mbt`
supplies conservative stubs for wasm/wasm-gc/js, where nothing is recorded and
nothing is reclaimed — the pre-§22 behaviour, kept deliberately. It all sits in
an executable package, which no one imports, so no published interface moved;
`spill` keeps its `FsStore` and knows nothing about leases. `platform/io` grew
the primitives that made this possible: an exclusive create, a rename that
reports "the source is gone" instead of failing, a hand-rolled read for the
`/proc` pseudo-files (`moonbitlang/x/fs` sizes a read from `stat`, and every
`/proc` file reports 0), and the wall clock. The C file went from 113 to 177
lines.

**Evidence.** The rules are tested as a table, on all three backends, because
`judge_owner` takes the boot id and the probe as arguments: 9 tests cover the
round trip, an unknown version, a marker missing any of its three facts, a
reboot, a gone pid, a live pid, a reused pid, a platform without a boot id, and a
probe that cannot answer. Four more run on native only, against the real
`/proc`: a marker this process writes judges `live` (and a second claim leaves it
alone), a marker for pid 999999999 — above any `pid_max` — judges `stale` and is
reclaimed, a marker for this pid with the wrong start time judges `stale`, and a
directory with no marker is `unavailable`. 254 / 241 / 241 tests across native,
wasm-gc and js.

**Acceptance.** `bash harness/spill_accept.sh` (ten checks, deterministic, ~6 s):

1. a spilled `ORDER BY` leaves no directory behind;
2. a query that fails on hash skew leaves none either;
3. `--spill-dir` keeps a caller's `notes.txt` and a `runx.bin` that is not a
   run file;
4. `--analyze --memory 200K` prints all four spill counters *and a non-zero run
   count* — check 4 used to pass on zero, which proved nothing;
5. the same `ANALYZE` without a budget prints no spill line at all;
6. two spilled queries running at once on one `--spill-dir` both succeed with
   their own answers and leave the directory empty;
7. a `moonlake-spill-0` with **no** marker survives the next query (the old
   check 7, restated: it is now the "cannot tell" rule, not the only case);
8. a query frozen as soon as it claims its directory, then `kill -9`'d, leaves
   that directory behind with a stale run file; the next query on the same
   `--spill-dir` reclaims it, leaves nothing, and says
   `moonlake: reclaimed …: its process (…) is gone`;
9. a directory whose marker names a live process — an unrelated `sleep` with its
   real boot id and start time — is **not** reclaimed, is not mentioned as
   reclaimed, and the query moves on to the next index;
10. a `version=9` marker is kept and reported as "not one this version
    understands".

Check 8 freezes the query with `SIGSTOP` the moment its `owner` file appears
rather than waiting for run files: a spill on SF0.1 only lasts part of the run,
so polling for `run*.bin` raced the query to completion. The leaked run file is
written in by hand, which is exactly what a kill in the middle of a sort leaves.

**Gates.** `moon check --deny-warn` on native, wasm-gc and js; 254 / 241 / 241
tests; 27 golden queries; spill 10/10; `check_writer_interop.py`; playground
16/16; `moon package --list` at 184 entries (the five new files, including the
native-gated test, ship because the archive excludes only dot-prefixed paths and
the dev-only trees listed in §16).

**What is refused on purpose.** A `--spill-dir` shared across PID namespaces (two
containers, one volume) makes a live query look dead: pids are per namespace and
a boot id is per kernel, so the evidence is meaningless in that setup. Nothing
detects the setup, and the mitigation is the same as for `/proc`-less platforms:
point each container at its own `--spill-dir`. On macOS, `boot_id_here()` is
empty, no marker is written, and no directory is ever reclaimed — the pre-§22
behaviour, minus the surprise.

**Not done here.** No lease is renewed or expired by time: an owner that hangs
forever keeps its directory forever, which is correct (it is still running). The
writer's 2 GiB page-offset limit is still separate work.

## 23. 0.5.0 release (2026-10-24)

Every gate below ran on `2da10d1`, the commit the tag points at.

**Pre-publish gates.** `harness/check_release.py --tag v0.5.0 --check-consumer`
reported the version claims agreeing (`moon.mod`, `moonlake.mbt`, the newest
CHANGELOG heading and the tag), the archive holding 187 files with no
dot-prefixed path, a clean tree, and an archive consumer green on native,
wasm-gc and JS with a fresh registry and dependency cache. `moon publish
--dry-run` then returned `Server status: 202 Accepted, detail: Dry run completed
successfully`.

**Publish.** `moon publish` (through a scratch `MOON_HOME`, because the default
toolchain home is not writable in this environment) unpacked the archive, passed
its own `moon check` on the extracted package and reported **`Server status: 200
OK`**. `moon view superbigcup325/moonlake` reports `Latest: 0.5.0`, published
`2026-10-24T14:05:05Z`, five versions total.

**Registry consumer.** `harness/check_consumer.py --registry-version 0.5.0`
resolved the package from mooncakes with no workspace override; native, wasm-gc
and JS all return the expected version, CSV query, raw/Snappy Parquet
round-trips, DATE/NULL values and table removal. Evidence boundary: this is a
registry install of a **released** artifact, not the archive gate of §16.

**Tag, workflows, GitHub release.** The tag is annotated, on `2da10d1`. Pages
deployed that commit ([pages](https://github.com/superbigcup325/moonlake/actions/runs/40100901865))
and the tag-triggered provenance job ran green
([release](https://github.com/superbigcup325/moonlake/actions/runs/40100915146)),
which re-checked the version claims against the tag and ran the archive consumer.
CI on the same SHA finished green afterwards
([CI](https://github.com/superbigcup325/moonlake/actions/runs/40100901861)):
check, native/wasm-gc/js tests, the TPC-H chain, writer interop and the
playground job. [The GitHub release](https://github.com/superbigcup325/moonlake/releases/tag/v0.5.0)
was created from the CHANGELOG section of this version.

**Deployed page.** The public page was driven in real Chromium with the version
gate defaulting to `moon.mod`: 16/16 checks pass, so the page and the tag agree
on the release identity.

Release limitations at the tag: the writer's 2 GiB page-offset limit refused
larger files, wasm-gc/js scans still read whole files (their filesystem module
has no range reads), and spill reclaim still declines to guess about a directory
whose owner cannot be proven dead. §22 lists what is refused on purpose and why;
`docs/ROADMAP.md` says what closing each would involve. The first of those has
since moved: §24.

**Performance record, added after the release.** 0.5.0's numbers in this section
are measured A/B pairs, not a release record. A
[`2026-10-24-0.5.0.json`](../harness/baseline/2026-10-24-0.5.0.json) record was
committed beside a 0.4.0 rebuilt from tag `v0.4.0` in the same session, so the
scan/join/gather/spill cases have a like-for-like comparison across the release
(`docs/bench-baseline.md`, last section).

## 24. Parquet files past 2 GiB (2026-10-24)

The writer stored a page's position in the file as `Int32`, so it refused any
output that would need an offset past 2 GiB (it raised `file would exceed the
2 GiB page offset limit` before emitting the page). That was the last item on
the list of limits this repository admitted to. The fix is a type: a column
chunk's `file_offset` and its `data_page_offset` are positions inside the file,
so they are `Int64` in the writer and decoded as `Int64` by the reader, which
already did that. The one 32-bit length left is a page's own body and stored
size, and a page holds one batch, so that bound is the batch size rather than
the file size.

**Before and after, same input, same machine.** A 2.35 GiB CSV (34,400,000
rows of `id,tag`) written to Parquet:

| build | result |
|---|---|
| 0.5.0, from tag `v0.5.0` | exit 1, `parquet write: file would exceed the 2 GiB page offset limit`, no output file |
| this tree | exit 0, 2,410,475,894 bytes in 13.5 s, peak RSS 22 MB |

**What the file looks like to other readers.** pyarrow's metadata reports
34,400,000 rows in 8,399 row groups, with the widest `data_page_offset` at
2,408,368,843 and 1,820 of 16,798 column chunks past 2^31, so the offsets in the
footer are genuinely wide rather than coincidentally small. pyarrow reads
34,400,000 rows and the expected `sum(id)`; DuckDB returns the same
`count(*)`/`sum`/`min`/`max`; moonlake's own range reader returns the same
count and sum over the whole file (1.4 s, 227 MB peak RSS) and prunes to 15 MB
for a predicate on the id range. This is reproducible with
`harness/check_large_write.py`, which generates the CSV, writes it, checks the
footer with pyarrow, cross-reads with DuckDB and reads back with moonlake. That
script runs in the nightly workflow's `large-write` job rather than on every
push: it needs about 5 GB of scratch disk and a few minutes, and a nightly
cadence notices a regression long before a release does. It reads the Parquet a
column at a time, so a 16 GB runner is enough for a 2.4 GiB file.

**Unchanged.** No public signature moved (`write_bytes`, `write_bytes_with`,
`write_file`, `write_file_with` keep theirs, and `pkg.generated.mbti` does not
change). Files under 2 GiB are byte-identical to 0.5.0's, compared directly:
242 bytes for a three-row CSV, 75,174,601 bytes writing the SF0.1 `lineitem`
CSV, 84,788,461 bytes rewriting the SF0.1 Parquet. The whitebox test
`a column chunk offset past 2 GiB survives the footer round trip` builds a
synthetic footer at offset 5,000,000,000 and reads it back through `read_footer`,
so the wide path is covered without a multi-gigabyte fixture in the test suite.
Gates: `moon check --deny-warn` and 255 / 242 / 242 tests on native, wasm-gc and
js.

**Not done here.** A single page larger than 2 GiB is still not writable (it
would need a `DataPageHeader` this format's reader does not have), a row group
remains one batch, and the writer still produces one row group per CSV batch,
which for this file means 8,399 small row groups rather than a handful of large
ones. None of those is new, and none of them is what the 2 GiB limit was.

## 25. What a spilling query spends, and where (2026-10-24)

The roadmap holds the streaming-executor direction until a query that spills is
shown to be slow *because* it materializes, and not because it spills. This is
that measurement. The input is SF1 `lineitem`: 6,001,215 rows, as a 773 MB CSV
and as a 751 MB Parquet written from it by this tree, so the row reader and the
column reader face the same queries. Peak RSS is `VmHWM` read from
`/proc/<pid>/status`: `getrusage` over children reports a running maximum, which
makes every smaller case look like the largest one before it.

**The spill bytes are not the cost.** The same `ORDER BY` at a 16 MB budget,
writing its runs to tmpfs and to disk:

| spill directory | wall (median of 2) | runs | bytes written and read | peak RSS |
|---|---|---|---|---|
| `/dev/shm` | 2.95 s | 6 | 3,774,219 | 125 MB |
| disk | 2.98 s | 6 | 3,774,219 | 129 MB |

Three hundredths of a second apart, 3.8 MB each way. What grows with a smaller
budget is the number of runs, and with it the work of merging them:

| query | budget | runs | spilled | wall | peak RSS |
|---|---|---|---|---|---|
| `l_orderkey`, ordered | 8G | 0 | 0 | 1.59 s | 159 MB |
| | 64M | 2 | 3.8 MB | 2.89 s | 221 MB |
| | 16M | 6 | 3.8 MB | 2.95 s | 125 MB |
| | 1M | 98 | 18.8 MB | 6.44 s | 117 MB |
| all 16 columns, ordered | 8G | 0 | 0 | 4.84 s | 3,346 MB |
| | 64M | 46 | 1.67 GB | 50.6 s | 5,082 MB |

The narrow sort nearly doubles while moving 3.8 MB, so the extra time is a
second pass over the rows, not the file. The wide sort is ten times slower and
moves 1.67 GB, and its peak *rises* to 5.1 GB under a 64 MB budget: the budget
bounds the run buffer, while the merged rows and their buffers are on top of it.
A spilling query is slow because of the rows it copies and re-merges; the device
is irrelevant at both sizes.

**The rows are the cost, and the blocking operator is not what allocates them.**
The same scan with nothing after it, CSV then Parquet:

| query | CSV | Parquet |
|---|---|---|
| `count(*)` | 1.44 s / 35 MB | 0.05 s / 13 MB |
| `l_orderkey` alone | 2.16 s / 159 MB | 0.78 s / 159 MB |
| `l_comment` alone | 2.80 s / 620 MB | — |
| all 16 columns | 13.1 s / 3,195 MB | 11.9 s / 3,132 MB |
| all 16 columns, `where l_quantity < 10` (3% of rows) | 5.6 s / 584 MB | 4.4 s / 590 MB |
| all 16 columns, `limit 1000` | 4.9 s / 2,557 MB | — |

`count(*)` over the bare table stays at 35 MB because no column is decoded;
project one column and the peak is that column's rows, project sixteen and it is
all sixteen, at about six times the decoded bytes (24 MB of `int32` becomes
159 MB of rows). The result buffer is not the CLI's: the same peak appears when
the rows go straight into an aggregate.

| query | wall | peak RSS |
|---|---|---|
| `select count(*) from (select * from lineitem)` | 5.33 s | 3,195 MB |
| `select count(*) from (select * from lineitem order by l_orderkey)` | 5.76 s | 3,328 MB |
| `select * from lineitem limit 1000` | 4.87 s | 2,557 MB |

`LIMIT` reaches nothing: the scan materializes all 6M rows before the limit
operator sees the first one. Parquet gives the same numbers as CSV for the same
projection, so this is the executor, not the reader, and the spilling sort's
3.2 GB floor was there before it spilled anything.

That was true of every shape when these numbers were taken. [§27](#27-a-limit-stops-its-scan-2026-10-24)
is what a plain single-table LIMIT does now — 14.3 ms and 27 MB, from 4.87 s and
2,557 MB, for the same query — and everything else in this section still
describes a scan with no window above it.

**What this means for the roadmap.** The trigger fires, and it fires above the
spill files: the first thing a streaming executor has to change is the scan's
row materialization and the missing backpressure (`LIMIT` reaching the scan is
the visible proof), after which the merge pass is what spilling costs on top.
The executor row in the limits table now carries these numbers. The scripts behind this
section are not committed: they are a debug probe (`VmHWM` sampling over the
native CLI), not a regression gate, and every number is a wall clock on one
developer machine, so they say "rows, not bytes" rather than "N seconds".

## 26. The 16% snappy gap was one tag (2026-10-24)

Section 25 left a debt that looked like page layout: for the same 6M rows in the
same layout, this writer's `--snappy` file was 333.0 MB against pyarrow's
287.9 MB. The raw bytes were comparable (ours are smaller, since `l_orderkey` is
`int32` here and `int64` in pyarrow's inference), the page granularity was the
same (one page per batch, 4,094 rows against pyarrow's 4,096), and the
per-column breakdown blamed the data with short repeats: `l_quantity` 17.1 MB
against 11.7, `l_comment` 88.5 against 73.0, while `l_shipinstruct` — mostly
incompressible text — was 13.1 against 12.4.

The compressor wrote every match as a three-byte `copy2` tag, even a four-byte
match eight bytes behind the cursor, which is what most of a text page looks
like. The format has a two-byte form for exactly that (`copy1`: length 4–11 at
an offset below 2048) and the decoder already accepted it; the encoder now emits
it when it fits.

| check | result |
|---|---|
| SF1 `lineitem` written with `--snappy` | 333.0 MB → 289.2 MB |
| pyarrow, plain+snappy, same rows | 287.9 MB |
| read back in moonlake / pyarrow / DuckDB | 6,001,215 rows, sum 18,005,322,964,949 |
| `harness/check_writer_interop.py` | all checks passed |

Only the encoder's tag choice moved, so the decoded bytes are the ones written
before. ### What the two tags cost to run

Same session, same input (the SF1 `lineitem` CSV, 6,001,215 rows), same machine:
the previous commit's encoder rebuilt against this one, two writes and two read
queries each, on the files the two encoders produced.

| run | old encoder | new encoder |
|---|---|---|
| file size | 333.0 MB | 289.2 MB |
| `write --csv … --snappy` (two runs) | 10.52 s / 10.18 s | 10.11 s / 10.22 s |
| `select count(*)` | 0.054 s / 0.057 s | 0.055 s / 0.054 s |
| `select sum(l_orderkey)` | 0.50 s / 0.16 s | 0.16 s / 0.14 s |

Writing is a wash — the shorter tag pays for the branch that chooses it — and so
is reading, because a page decompresses to the same bytes either way. The 0.50 s
entry is the old file's first touch, which had to fill a page cache that the
second run found warm.

The whitebox test `a short match close behind is a two-byte copy` builds
the provoking pattern (a four-byte token every eight bytes), walks the tags and
requires at least 90 `copy1` and no wider copy, so a regression to `copy2` fails
a test instead of quietly costing 13% of every compressed file.

## 27. A LIMIT stops its scan (2026-10-24)

A LIMIT over a single table used to cost a full scan. The executor is eager:
the scan drains its source into an array and each operator runs over that array
in turn, so the window could only cut rows that had already been read, decoded
and projected. Over the 2,000,000-row fixture (75 MB of CSV, 71 MB of Parquet)
`select * from t limit 10` pulled every row, in 483 ms and 252 MB of peak RSS,
where `select count(*)` over the same scan was 205 ms and 21 MB.

The window now pulls. The scan, the build filter pushed down to it, the deferred
`WHERE` and the projection run a batch at a time, and the loop stops as soon as
the `OFFSET + LIMIT` window is full. There is no cancel protocol because nothing
needs one: a consumer that has what it asked for stops calling `next`, and an
unfinished stream is dropped — the sources hold decoders and file handles, not
spill files or locks. The rules a stage may rely on are written at the top of
`engine/stream.mbt`.

| case | rows the scan pulled | wall ms | peak RSS MB |
|---|---|---|---|
| `select * from t limit 10` (CSV) | 2,000,000 → 4,096 | 482.8 → 13.9 | 252.0 → 13.0 |
| `select id from t limit 10` (CSV) | 2,000,000 → 4,096 | 212.6 → 16.1 | 31.4 → 13.2 |
| `select * from t limit 10` (Parquet) | 2,000,000 → 4,096 | 277.6 → 4.9 | 250.2 → 0.1 |
| `select count(*) from t` | 2,000,000 | 205.0 → 217.0 | 21.3 → 21.2 |
| `select id from t` (all rows) | 2,000,000 | 418.9 → 405.7 | 37.5 → 37.2 |
| `select * from t where i32 < -1000 limit 10` | 0 | 385.6 → 398.3 | 21.5 → 21.0 |
| `select count(*) from t where i32 < 0` | 999,737 | 237.9 → 247.3 | 27.5 → 27.1 |
| `select id from t order by id limit 5 offset 1000000` | 2,000,000 | 235.3 → 239.8 | 39.3 → 51.2 |
| `select id, i32 from t order by i32, id limit 10` | 2,000,000 | 1037.6 → 1048.7 | 53.3 → 51.2 |
| `select * from (select id from t) s limit 10` | (no plan) | 223.4 → 233.2 | 53.4 → 37.2 |

"Rows the scan pulled" is the `scan` line of `--analyze`. Before and after are
one build apart over the same seeded fixture, measured by
`harness/bench_early_stop.py --compare` with two timed runs per case and the
fastest kept; wall and RSS are single-digit percentages apart between runs for
everything in the table, so the rows that moved are the ones to read. Peak RSS is
`ru_maxrss` of the query's own process minus the 14 MB floor a bare `/bin/true`
reports through the same path (a forked child carries its parent's resident pages
until it execs, so the raw number has a constant in it); in raw terms the first
row is 265.8 MB → 27.1 MB, and the Parquet row lands on the floor itself. Answers
are judged against DuckDB reading the same file — multiset for an unordered
result, in order where the query defines an order, a count plus a column sum for
the 2,000,000-row output — so a faster wrong answer would fail instead of looking
good, and every case in the table answered the same before and after.

Everything else stayed where it was, and the numbers say why. `count(*)` has to
see every row. `ORDER BY` cannot know its top ten before the last batch arrives,
and the `OFFSET` case carries one. A derived table is a finished query by the
time the outer LIMIT sees a row. The filter case is the interesting one: its
`scan` line is 0 both before and after because the predicate is pushed into the
scan, which then still has to read the file to conclude that no row matches, so
398 ms is the honest cost of that shape rather than something this change could
remove.

What a LIMIT may stream is not this change's decision to make: the binder already
decides which predicates are applied to a table before the first join, and only
those may travel to a source (see `engine/scan.mbt`). A probe filter, a join
residual or the deferred `WHERE` cannot, because an outer join can leave a row
visible as the unmatched side. The window applies what it may to each batch and
stops when it has what it needs.

§25's case is the same shape at SF1 scale: `select * from lineitem limit 1000`
over the 773 MB CSV took 4.87 s and peaked at 2,557 MB before the window pulled,
and is 14.3 ms and 13.0 MB above a 14.2 MB floor now, for 1,000 rows out of
6,001,215. `count(*)` over the same file is 1.53 s and 21.0 MB, so the window
costs one 4 MB range and the count costs the whole file — which is the
difference this change is supposed to make and nothing more.

`engine/pull_wbtest.mbt` pins both sides of that boundary with a counting source:
`LIMIT 10` over eight batches of 100 rows pulls one batch (the case that used to
pull eight), `LIMIT 250` pulls three, `LIMIT 5 OFFSET 495` pulls five, `LIMIT 0`
pulls none, and a filter that passes rows still stops at the window — while
`count(*)`, `ORDER BY`, `SELECT DISTINCT`, a join and a derived table still pull
all eight, because a count that fell there would be a wrong answer. Nothing
public changed: `execute`, `execute_with` and `run_select` keep their signatures,
and the eager path remains the implementation for every shape that cannot stop
early, so the remaining operators can move to this contract one at a time.

## 26. Pre-release user pass (2026-10-25): what an ordinary session found

0.6.0 was checked the way a reader meets the project rather than the way the
suite meets it: install the CLI, follow `README` and `docs/DEMO.md`, and use
every documented feature until something looks wrong. Eleven defects came out
of that, all of them in the CLI or in a corner of the expression layer rather
than in the columnar core, and all eleven are fixed. What each one was, and the
evidence that it is now the answer SQL users expect:

The three that changed a *result* rather than a message:

- **`ORDER BY` on a qualified column sorted by an output alias.** `SELECT k AS
  z, flag AS k FROM a ORDER BY a.k DESC` bound `a.k` to the output column named
  `k` (the `flag` alias) instead of to the input column. Read as a user this
  surfaced three ways — an `ORDER BY` that ignored its direction, `NULLS LAST`
  not taking effect, and a `LIMIT` over a `LEFT JOIN` returning the wrong rows —
  because all three queries sorted by the wrong key. It is one defect: a
  qualified reference is an input-column reference and never an alias. Pinned by
  `engine/e2e_test.mbt` (two tests, direction and NULLS ordering) and by the
  99-query differential below.
- **`round()` and `cast(<double> AS int)` truncated toward zero.** `round` is now
  half away from zero on both sides, and a float → integer cast rounds the same
  way, which is PostgreSQL's and DuckDB's convention (C, SQLite and MySQL
  truncate — the README now says which one this is, since a C-minded reader
  would assume the other). The cast also refuses a value that does not fit
  instead of saturating. Checked against DuckDB on the same rows:
  `round(x)` over `[-2.5, -1.23, 2.5, 1.23]` gives `[-3, -1, 3, 1]` in both,
  `round(x, 3)` over `[-1.2345, 1.2345]` gives `[-1.235, 1.235]` in both, and
  `cast(x AS int)` over `[2.9, -2.5, 1e20]` gives `[3, -3, <out of range>]`
  with the last one an error in both.
- **A CSV column of `True`/`FALSE` was inferred as STRING.** Only lowercase
  spellings were compared, so a pandas or Excel export became text and `WHERE
  flag` failed with `build filter must evaluate to bool, got string`. The
  comparison is case-insensitive now (both the string and the bytes path), and
  `sources/csv/scan_test.mbt` pins `True`, `TRUE`, `False`, `FALSE`.

The four that were a wrong or unhelpful *message*:

- (Superseded by §28: the non-equality correlation is answered now, and the
  message names only the limits that remain.) A correlated subquery whose
  correlation is not an equality now says so:
  `this correlated subquery cannot be decorrelated: only inner.col = outer.col
  equalities over plain tables are paired, and the subquery may not carry
  DISTINCT, LIMIT, a set operation or a GROUP BY with HAVING — rewrite a
  non-equality correlation as a join`. It used to read `unknown table or alias
  "j1" in FROM`, which points at the wrong thing entirely.
- Two shapes that were refused are now answered, because the decorrelator can
  answer them exactly: a correlated `EXISTS` whose subquery carries a `GROUP BY`
  (existence is independent of the grouping, so it is dropped) and one whose
  `HAVING` runs over the correlation keys themselves (the grouping the
  decorrelator builds anyway). On a three-row fixture where `2` and `3` appear
  twice and three times, `exists (... group by k)` returns `[2,2,3,3,3]` here and
  in DuckDB, `... group by k having count(*) > 1` returns `[3,3,3]` in both, and
  the `NOT EXISTS` form returns `[1,2,2,4]` in both. A `HAVING` over some other
  grouping is still refused, with the reason.
- `moonlake write` refused an `--out` that is one of its own inputs. It used to
  replace the source: `write --csv t.csv --out t.csv` exited 0 and left a
  Parquet file where the CSV had been. The refusal is lexical (so `./t.csv` and
  `sub/../t.csv` are caught) and covers `--parquet` inputs; `harness/check_cli.sh`
  pins that the source survives.
- A Parquet write failure is a `sql error (execute):`, not `sql error (scan):`.
  A `cannot create <out>.moonlake-tmp-...` was labelled as a reading error;
  reading failures keep their `scan` label, writing ones moved to the stage they
  belong to.

The four that were a refusal where a working answer was expected:

- `concat` was binary-only, so the variadic form every other engine accepts
  (`concat(a, '-', b)`, `concat(1, 2)`) raised `concat() takes exactly two
  arguments`. It is variadic now, casts its arguments, and skips NULL ones as
  DuckDB does (`concat('a', NULL, 'b')` is `'ab'`), while `||` keeps its own
  semantics under its own lowering — `'a' || NULL` is still NULL, which is what
  the standard says and what a second, distinct function name protects.
- An untyped `NULL` where a call demands a type is accepted: `length(NULL)`,
  `upper(NULL)`, `abs(NULL)`, `substring(s, NULL)` are NULL, and `NULL IS NULL`
  is TRUE (it used to raise the v1 "untyped NULL is only supported as a
  comparison or arithmetic operand" refusal). A non-NULL argument of the wrong
  type still errors.
- `moonlake exec` with no input files ran the query instead of printing usage, so
  `moonlake exec "SELECT 1 + 1"` works: the empty catalog needed no dummy CSV,
  and the usage line shows the file group as optional. `--json` and `--explain`
  work there too (`[{"two":2}]`, `scan __one`).
- `--out` on top of an input is refused (above), and the one leftover that was
  not fixable without a directory-listing FFI is documented rather than swept: a
  write killed outright can leave `<out>.moonlake-tmp-<pid>-<n>` beside the
  target. Because publication is a `rename`, that is a partial temp file and
  never a half-written `--out`, and the names do not end in `.csv`/`.parquet`,
  so a glob scan never picks one up.

Regression cover: `engine/e2e_test.mbt` gained tests for the qualified
`ORDER BY` (direction and NULLS ordering), the correlation refusal, the grouped
`EXISTS` (three answers plus the refusal), `round`/`cast`, `concat`, the untyped
NULL and `NULL IS NULL`; `sources/csv/scan_test.mbt` pins the four bool
spellings; `types/round_half_away` is pinned from the `round`/`cast` test rather
than from `types`; and `harness/check_cli.sh` pins the three CLI edges
(expression-only `exec`, an unknown command's exit code, `write` refusing an
`--out` that is its input) in CI. The whole suite is 276 tests on wasm-gc and 289
on native, `moon check --deny-warn` is clean.

The 99-query DuckDB differential that produced these findings agrees on 83 or 84
cases depending on the run: `window-avg` orders a partition by `y` and two rows
share that value, so whether its output lines up is a coin flip — a query that
defines no order cannot disagree on one. In an 83 run the sixteen that disagree
are these, and none of them is a wrong answer:

| group | cases | why |
| --- | --- | --- |
| same rows, order differs | 7 | no `ORDER BY` (`distinct`, the three set operations) or an `ORDER BY` full of ties (`order by k` where `k` is NULL, `order by g` where a partition's rows share the value) — an unordered result compared in order |
| DATE rendered differently | 5 | DuckDB hands Python a `datetime`, moonlake's `--json` a `YYYY-MM-DD` string; the dates are equal |
| non-finite doubles | 1 | `7.0/0` is `"Infinity"` in JSON because JSON has no such literal; DuckDB's Python value prints `inf` |
| `x % 0` | 1 | moonlake is NULL (fmod), DuckDB 2.0 raises by default — documented as deliberate |
| non-equality correlation | 2 | **closed by §28**: both queries answer now and agree with DuckDB |

The date-arithmetic, division and `%` groups were already recorded as deliberate
divergences before this pass (sections 5 and 15); the pass added no new ones.

The release gates were re-run whole, since two of the fixes touch the binder and
one touches the Parquet writer's error path: `moon test` 276/276 (wasm-gc),
`moon test --target native` 289/289, `moon check --deny-warn` clean,
`harness/check_all.sh` 33/33 golden comparisons plus its three spill-equivalence
checks (the script now counts them itself, so the "27" in this document can stop
drifting), `harness/check_writer_interop.py` all checks, and
`harness/check_cli.sh` on both the debug and the release binary.

## 28. General decorrelation (2026-10-25): the refusal becomes an answer

**The claim under test.** §26 shipped a refusal: a correlated subquery whose
correlation was not an `inner.col = outer.col` equality said so and pointed at
a join. That is honest, but it is also a hole a user hits immediately —
`WHERE EXISTS (SELECT 1 FROM u WHERE u.v < t.a)` is ordinary SQL and every other
engine answers it. This section is the work that turned the refusal into an
answer, and the evidence that the answers are right.

**Three tiers, because the cost of each shape is different.** The decorrelator
is still a single AST rewrite that runs before binding (`engine/correlate.mbt`),
so the tiers differ only in what they build:

1. An equality pair stays what it was: a hash-keyed semi/anti join (or a grouped
   LEFT join for a scalar subquery). Nothing about that path changed.
2. A subquery with *no* equality pair but a predicate over both sides becomes a
   semi/anti join with **no hash key** — every inner row sits under the one
   empty key and each candidate is tested with the join residual. `join_semi`
   already supported zero keys; what was missing was the planner routing a
   keyless `EXISTS` into it and keeping the non-`Eq` conjunct as the residual
   (`engine/binder.mbt`, `plan_step`). `EXISTS (SELECT 1 FROM i WHERE i.v >
   o.v)`, `i.v BETWEEN o.v - 11 AND o.v + 11`, `i.k <> o.k`,
   `i.k = o.k OR i.v > o.v * 3` and `o.v IN (SELECT i.v FROM i WHERE i.k < o.k)`
   all landed here.
3. A **scalar aggregate** over a non-equality correlation has no key the inner
   side could be grouped by, and nothing can be precomputed per correlation key
   the way the equality flavor does it — the aggregate genuinely depends on the
   outer row's numbers. It is computed once, eagerly, over the *distinct*
   combinations of the outer expressions the subquery reads, grouped by a
   canonical row key, and left-joined back on that key. Deduplication is what
   keeps it honest: without it a repeated outer row would multiply the inner
   matches and a `count(*)` would double. The join inside is a theta join (a
   nested loop over the distinct outer combinations) — the price of the general
   shape, recorded in the roadmap as such.

**Row identity instead of a NULL-safe equality.** Tiers 2 and 3 need to say
"these two rows are the same" and "this value is this value, NULLs included".
`@types.CmpOp` has no NULL-safe equality, and adding one would touch elision,
pushdown and every hash table, so the identity is a string: an internal
`__row_key(...)` function built on the canonical, type-tagged, length-prefixed
encoding the hash joins and DISTINCT already use (`engine/exec_agg.mbt`
`scalar_key` / `canonical_key`). It is registered in the binder next to the other
scalar functions and evaluated in the evaluator's NULL-aware preamble, so it
works on values, not just on columns.

**EXISTS and IN as values.** Once a scalar aggregate can be computed for an
arbitrary correlation, `EXISTS` and `IN` stop being WHERE-only: the same theta
table answers `SELECT EXISTS (SELECT 1 FROM i WHERE i.v > o.v) FROM o`,
`WHERE NOT (EXISTS (...) OR k > 2)` and `CASE WHEN EXISTS (...) ...`. `EXISTS`
counts rows and compares with 0. `IN` is a CASE over three counts — matches, all
rows, and rows whose value is NULL — which reproduces SQL's three-valued result
including the empty set (`NULL IN (empty)` is FALSE, `NULL IN ({NULL})` is
NULL, `x NOT IN ({x, NULL})` is FALSE). Everything the semi-join pass leaves
behind is walked by one expression rewriter, which is why a correlation under
`OR` / `NOT` / `CASE` works at all.

**Outer-only conjuncts are parameters, not errors.** `WHERE i.v < o.v AND o.k >
1` used to be refused because `o.k > 1` touches neither side; it reads only the
outer row, so it is a parameter of the correlation and rides in the join
predicate (or in the theta aggregate) exactly as written. `BETWEEN` and mixed
`AND`/`OR` shapes then fall out of the same rule.

**The evidence.** A 39-query differential against DuckDB over four fixtures
(`o` with a repeated row and NULL keys, `i`, `n` with NULL values, and a
one-column `one`) agrees on all 39: the equality-shape regression queries from §26, keyless `EXISTS` /
`NOT EXISTS` / `IN` / `NOT IN` in WHERE, the same under `NOT` and `OR`, scalar
subqueries in the select list, in WHERE, in arithmetic and in `CASE`, repeated
outer rows through a join, and `IN` / `NOT IN` against sets that contain NULLs.
The harness compares sorted row multisets, so no query can pass on ordering.
`engine/e2e_test.mbt` gained five tests (the theta join, the nested
`NOT`/`OR`/`CASE` shapes, the theta aggregate including the repeated-outer-row
case, the three-valued `IN`, and the two positions that name themselves); the
two shapes §26 recorded as refused are gone from that list.

**What is still refused, and why it is named.** A derived table in the
subquery's FROM (the classification pass only treats `Named` FROM items as
belonging to one side), `DISTINCT` / `LIMIT` / `OFFSET` / a set operation inside
it, a grouping or `HAVING` that is not the correlation keys, and a reference to a
table two levels out. Three *positions* are outside the rewriter, which visits
the WHERE clause and the select list: the select list of a grouping outer query
(its value would have to appear in the `GROUP BY`), a `HAVING` clause (it runs
against grouped rows), and a `JOIN ON` clause (the synthetic table it needs joins
after the clause that reads it). Each reports its reason and points at a join;
none of them guesses, and none of them reaches the user as `unknown table or
alias <outer> in FROM` any more.

**Gates.** `moon test` 280/280 (wasm-gc), `moon test --target native` 293/293,
`moon check --deny-warn` clean, `harness/check_all.sh` 33/33 golden comparisons
plus its three spill-equivalence checks, `harness/check_writer_interop.py` all
checks, `harness/check_cli.sh` on the debug and release binaries, `moon fmt
--check` clean, and the only `.mbti` difference is the one that pre-dates this
work (`round_half_away`).

## 29. Current assessment and 0.6.0 scope (2026-10-25)

This assessment used source commit `eeab95e12507b4e234c8a4c0ca684ac6980899bf`
and then changed documentation only. The working tree was clean at the start.
Live GitHub queries confirmed `main` at `750b98c250f77367e401e3afa4c74d7fc60c0c0b`,
28 commits behind the local source, and the latest release at
[v0.5.0](https://github.com/superbigcup325/moonlake/releases/tag/v0.5.0).
`moon view superbigcup325/moonlake` independently returned `Latest: 0.5.0`.
The latest checked CI and Pages successes belonged to `750b98c`; neither
validates the local candidate.

All pending changes and the remaining execution plan now target **0.6.0**.
The changelog has one `0.6.0 - Unreleased` section, with all its prior entries
preserved. Its entries describe implemented behavior. The roadmap separately
marks the result API, batch-fed aggregation/sort/join, differential gate,
dictionary investigation and final acceptance as open work for that same
version. Version fields stay at 0.6.0; this is development scope, not a release.

Checks actually run in this assessment:

| Check | Result and scope |
|---|---|
| `moon version --all` | moon/moonrun 0.1.20261016, moonc v0.10.16+b1a0e846e |
| `moon check --deny-warn`, `moon fmt --check` | Pass; no MoonBit implementation or generated interface changed |
| `moon test --target native` | 293 passed |
| `moon test --target wasm-gc` | 280 passed |
| `moon test --target js` | 280 passed |
| Python harness unit tests | 51 passed with Python 3.12.14 and the pinned DuckDB 2.0.0 / PyArrow 26.0.0 environment |
| Native CLI build and `harness/check_cli.sh` | Pass; expression-only exec, unknown command and same-input output refusal |
| `harness/check_all.sh` | 33 golden comparisons plus sort/join/aggregation spill equivalence passed; default wasm-gc target |
| `harness/check_release.py` before documentation edits | Pass on the clean source baseline; version 0.6.0, archive 198 files, no forbidden paths |
| Version and archive checks after documentation edits | Pass; all version claims agree, archive still 198 files, no forbidden paths |
| Documentation checks | All pending changelog entries preserved, task IDs and relative links checked, README symlink intact, `git diff --check` clean |

The first Python invocation used the system Python, which lacked DuckDB and
PyArrow. An offline attempt found no matching packages in the selected cache,
and the sandboxed download then failed DNS resolution. Downloading the pinned
dependencies into a temporary cache with permitted network access resolved the
environment issue; the Python 3.12 run above passed. The oracle-mismatch line
printed by a gate self-test is an intentional negative case.

This assessment did not rerun the independent archive or registry consumers,
writer interoperability, full spill lifecycle, large-file write, external
Parquet corpus, random differentials, full performance baseline or real-browser
acceptance. Existing earlier records retain their own SHA and scope. No push,
tag, dry-run upload, package publication or deployment was performed.

The documentation itself was committed afterwards, so the entries above and the
version fields are what `main` now carries. `harness/check_release.py` was run
again on that clean tree and passed — the three version claims agree, the
archive holds 198 files with no forbidden path — but it is a check of the
current candidate, not of a release: `moon publish --dry-run`, the tag, the
registry consumer and the remainder of the 0.6.0 delivery plan still belong to
authorized release work on the final candidate.

## 30. The correlation differential becomes a committed gate (2026-10-25)

**The claim under test.** §28's headline evidence was a 39-query differential
that agreed with DuckDB on all 39. It ran from a script that was never
committed. That is the same failure mode as the 29-query window battery in §5.1:
the numbers were true when written, and the day `engine/correlate.mbt` changed
nobody could tell which of them still were. S0 turned that evidence into a gate
that runs on every push and cannot silently pass.

**What is committed.** `harness/data/correlation/` holds five fixtures, and
`harness/check_correlation.py` holds the cases. The fixtures are shapes, not
data:

| File | What it exists to catch |
|---|---|
| `o.csv` | duplicate outer rows (`id = 1` twice, so a correlated aggregate that loses deduplication multiplies), NULL keys and NULL values, a date column, `nan` / `inf` / `-inf` in a float column |
| `i.csv` | a repeated correlation key, a NULL key, a NULL value |
| `n.csv` | a NULL-rich inner side for `IN` / `NOT IN` three-valued logic |
| `one.csv` | a single-column table, where a subquery cannot lean on `SELECT *` |
| `e.csv` | header-only: an empty input, where a correlated aggregate must return its empty-group value instead of dropping the outer row. Both engines type it from the header alone, so its cases cast (`CAST(e.v AS INT)`) rather than measuring the fixture's typing. |

**What the runner decides.** 45 value cases (1 ordered, 44 as row multisets) and
11 documented refusals. An unordered answer is compared as a multiset, because a
decorrelated query has no defined row order and sorting both sides would let a
wrong order pass; the one ordered case carries a total `ORDER BY`. Dates and
non-finite values compare by value, and booleans compare by value across the two
engines' spellings (`true`/`false` here, `True`/`False` in DuckDB). There is no
skip path: a wrong answer, an engine error on a value case, a refusal without
its message, a valid-SQL refusal the referee rejects, a missing or empty
fixture, a referee error and a run with zero value cases all fail. Refusals are
counted apart from matches and a run with only refusals fails, because a refusal
is evidence of a limit, not proof that the arithmetic is right.

`harness/differential.py` is the shared plumbing — CLI invocation, row
extraction, cell normalization, `Case`/`Report`, `run_cases` — extracted from
the window gate so both gates agree on what "equal", "refused" and "failure"
mean; `harness/check_windows.py` now imports it and its 14 unit tests still
pass. `harness/test_check_correlation.py` adds 15 tests of the gate's own
failure paths (wrong value, tolerated row order, duplicate counts, a refusal
with the wrong message, a referee error, missing/empty fixture, no cases,
seeded-fixture replay). The fixed cases run in the `tpch` CI job;
`--random 400 --seed 20261025` runs in nightly, and the seed replays a failure.

**What it found.** Three defects, none of them visible from the 39-query
battery, and two of them wrong answers:

1. **`IN` against a set holding NULL answered `false`.** `engine/eval.mbt`
   applied the UNKNOWN rule behind `negated && right_has_null`, so only `NOT IN`
   was right; `x IN (set with NULL)` where `x` was absent returned `false`
   instead of NULL. `SELECT o.v IN (SELECT n.v FROM n) FROM o` disagreed with
   DuckDB on three of five rows. The fix is one condition, and the golden corpus
   is unaffected — no recorded golden exercises the shape, which is exactly why
   the differential had to exist.
2. **A correlated `NOT IN` whose set may hold a NULL was answered by dropping
   the whole query into an internal refusal.** The decorrelator's NULL-poison
   detection pushed a `false` filter and returned "unsupported" through the same
   `None`, so the caller read a resolvable shape as an unanswerable one. Keeping
   the poison instead produced an *empty* answer for `o.v NOT IN (SELECT i.v
   FROM i WHERE i.k < o.k)` (DuckDB returns 5 rows), because the conjunct loop's
   early exit returned the original select and discarded the added filter.
   Both are now correct: the exact per-row answer where the set cannot be
   narrowed per row, and a named refusal (`cannot be decorrelated`) where it can,
   since answering that shape needs a per-row count of the NULLs the anti join
   never compares. That refusal is pinned by the gate so implementing it in E4c
   flips the case loudly.
3. **A correlated `NOT IN` over an empty set dropped a NULL probe.** `join_semi`
   read "NULL probe key" as UNKNOWN without asking whether the row's set had any
   member; `v NOT IN <empty set>` is TRUE even for NULL `v`. The committed
   fixture passed by luck and the seeded nightly found it (307 rows against
   DuckDB's 323). The fix asks the residual whether anything could be a member,
   which is the same question the join already answers for a match.

**Tests that pin the engine behaviour now.** `engine/e2e_test.mbt` gained three:
`IN` and `NOT IN` against a set holding NULL as values (true/NULL/true and
false/NULL/false), a `NOT IN` over an empty correlated set keeping the NULL
probe, and the narrowed-set refusal naming itself. The fixtures also record the
one shape whose message is still wrong: a reference to a table two levels out is
refused, but by the binder — `unknown table or alias "o" in FROM` — and the gate
pins that text with a note rather than pretending otherwise. §28's sentence "none
of them reaches the user as `unknown table or alias <outer> in FROM` any more"
therefore holds for the positions it lists and not for that one; the README now
says so. A named message belongs to E4c, which already owns the join contract
this path will need.

**Gates.** `moon test` 283/283 (wasm-gc), `moon test --target native` 296/296,
`moon test --target js` 283/283, `moon check --deny-warn` clean, `moon fmt
--check` clean, no `.mbti` change, `harness/check_correlation.py` 45 value cases
matched and 11 refusals as documented (and the same on the 400-row seeded
fixture, plus seeds 1/2/3 at 120 rows), `harness/check_windows.py` still ok,
`harness/check_all.sh` 33/33 golden comparisons plus its spill-equivalence
checks, `harness/spill_accept.sh` all checks, and 66 Python harness unit tests.

## 31. Results leave the engine as they arrive (2026-10-26)

**The claim under test.** §27 gave one shape an early stop: a single-table
`LIMIT` pulled batches and stopped when its window was full. It did that inside
the executor, and the *result* still left as one materialized batch — so
`select * from t` over a table larger than memory printed two million rows only
after holding all of them, and `--json` built the whole document as one string.
E3 puts the pull at the result boundary: a caller can read the schema and
consume the rows, and the CLI does.

**What streams, and what cannot.** A query streams when it is one lazy table
with nothing above the projection that must see every row first: the build
filter pushed into the scan, the deferred `WHERE`, the projection, and an
`OFFSET`/`LIMIT` window applied per batch. A `LIMIT` is no longer required, and
its absence does not change the answer — the window applies to whichever batches
arrive. Everything else is materialized before the stream is handed out:
aggregation, a join, `ORDER BY`, `SELECT DISTINCT` and set operations, plus
anything over a non-lazy table (`scan_string`, a derived table, an in-memory
catalog). The reason is not conservatism: an aggregate has no first row until
the last input row is in, and `ORDER BY` cannot know its first row either. The
distinction is one function, `streaming_source` in `engine/stream.mbt`, whose
shape test is three lines and whose comment says why each clause is there.

**One pull, two deliveries.** `run_select` and `run_select_stream` both go
through `prepare_select` and then `drain_scan` or `scan_pull`, so a collected
result and a pulled one cannot disagree about a row — the collected path
concatenates what the pulled path hands out. That is what makes the second
delivery safe to add: it is the same code reading the same scan, not a second
implementation to keep in step. `@moonlake.execute` keeps its signature and its
answer; `@moonlake.stream` / `stream_with` add the incremental one.

**Lifecycle, written down.** `engine/stream.mbt` and the `ResultStream` doc
comment state the whole contract: `next` returns whole batches and `None` once,
at the end, and keeps returning `None`; `close` stops the pull, is idempotent
and is safe before the first call; a pull that raises **ends** the stream rather
than leaving it resumable (an `errdefer` sets the finished flag), because a scan
whose state is unknown must not pretend it can continue; and dropping the
stream releases the scan cursor. `catalog.BatchStream` gained no method: it stays
exhaustion-only, so an implementation outside this repository keeps compiling.
A stream also owns no spill files — a shape that needs a `--memory` budget is
materialized inside `stream_with`, before the stream exists — which is why an
unfinished stream is safe to drop and why the CLI's spill purge can never take a
file the stream still needs.

**Eager shapes keep their numbers.** The pooled benchmark case `scan/full`
(`select id from t` over 2,000,000 rows, the whole result printed) moved
410.0 ms / 31.4 MB to 412.3 ms / 21.3 MB — the 8 MB that used to hold the
projected column, plus its copies. Nothing else in the table moved: `scan/count`
21.5 → 21.2 MB, `scan/sort_limit` 53.4 → 53.3 MB, `scan/limit` 13.4 → 13.3 MB,
so the shapes that still materialize still cost what they did
(`harness/baseline/2026-10-26-results-streamed.json` is the record;
`harness/bench_early_stop.py` is the case list).

Where the difference is visible is a result large enough to notice. Same
fixture, same build, one process per measurement, peak RSS from `os.wait4`
(raw, the floor is about 22 MB — `bench_early_stop.py` subtracts it):

| output | case | before | after |
|---|---|---|---|
| text | `select id from t` | 405 ms / 53.3 MB | 402 ms / 35.3 MB |
| text | `select * from t` (16 columns) | 1,265 ms / 347.8 MB | 1,102 ms / **35.2 MB** |
| `--json` | `select id from t` | 426 ms / 147.7 MB | 398 ms / 35.3 MB |
| `--json` | `select * from t` | 2,419 ms / **1,090.6 MB** | 1,878 ms / **35.2 MB** |

The after column is flat: whatever the query returns, the process holds one
batch, which is the point of the change. `--json` also got faster because it no
longer concatenates a document — the encoder writes one line per batch. The rows
are unchanged: text output is byte-identical for both cases, and the JSON
document parses to the same 2,000,000 rows in the same order (489 lines instead
of 1). Both engines' answers are still checked against DuckDB by the benchmark
for its own cases.

**What the tests pin.** `engine/pull_wbtest.mbt` (which §27 started) now covers
both deliveries with the counting source: one pulled batch stops the scan at one
batch read and `close` keeps it there; `LIMIT 250` returns 100 + 100 + 50 and
reads three batches; `LIMIT 5 OFFSET 495` drops four whole batches and returns
five rows; an empty result ends at once; seven shapes (scan, filter, offset,
group by, order by, distinct, derived) return the same scalars pulled and
collected; an aggregate arrives as one batch; a materialized empty answer is one
empty batch while a pulled empty one is no batch at all; a source that raises on
its second batch ends the stream and closing it is still safe; and a bind error
is raised by `stream()` with zero rows read, so a `LIMIT` that never reads its
tail cannot hide a type error. `harness/check_cli.sh` drives the native binary:
20,000 rows to `--json` must be one parseable array of 20,000 rows across more
than one line, a two-row result must be byte-identical to the whole-array
encoding, text output must be a header plus 20,000 rows, and a scan that fails
after the first batch must leave the rows it printed on stdout, the message on
stderr and exit 1 without a panic trace.

**A CLI exit path found on the way.** The failure test above first ended in
`PanicError` and exit 134: `main` is `raise`, and a raise from inside the print
loop or from input registration escaped every `catch` the command had. Both
subcommands are now wrapped, so a failure exits 1 with its message on stderr and
no stack trace, whatever stage it came from.

**Gates.** `moon test` 290/290 (wasm-gc), `moon test --target native` 303/303,
`moon test --target js` 290/290, `moon check --deny-warn` clean, `moon fmt
--check` clean, `.mbti` gains exactly the new functions, `harness/check_cli.sh`
all checks (four new ones), `harness/check_all.sh` 33/33 golden comparisons plus
its spill-equivalence checks, `harness/spill_accept.sh` all checks,
`harness/check_correlation.py` unchanged (45 value cases, 11 refusals), and 66
Python harness unit tests.

## 32. Aggregation folds the scan as it arrives (2026-10-26)

**The claim under test.** §31 removed the result array: a single-table result
leaves the engine one batch at a time. Its *input* arrays were still there, and
§25/§27 measured what they cost — an aggregate held every batch the scan handed
it, then folded them. E4a takes the same pull one operator further in: a
`GROUP BY` or a global aggregate folds the batches as they arrive, so the
operator holds its group state and one batch instead of its input.

**What was actually in the way.** The fold already worked batch by batch.
`aggregate_seq(seq, group_exprs, group_types, aggs)` in `engine/exec_agg.mbt`
pulls from a `BatchSeq` and updates group keys and accumulators per batch; it
existed because the grace path aggregates one spill partition at a time
(`aggregate_seq(BatchSeq::of_runs(...))`). What it was never handed was the
*scan*: every caller passed a collected `Array[@types.DataBatch]`, because
`run_pipeline` materialized each table before the operator ran. So the change is plumbing, not a new algorithm — and that matters, because
a per-batch fold that is a second implementation would be the thing to get
wrong.

**What the pull is.** `engine/stream.mbt` gains three pieces next to `ScanPull`:

- `streaming_agg_source(bq, sources, opts)` — the shape test. One lazy table,
  `aggregate` set, no `ORDER BY`, no `SELECT DISTINCT`, no window function. A
  budgeted `GROUP BY` is excluded on purpose: the grace path derives its
  partition count from the size of the input it was handed
  (`partition_count(batches_bytes(joined), budget, AGG_PARTITION_CAP)` in
  `engine/extagg.mbt`), so that run still needs the input collected. A global
  aggregate is included under a budget, because it can never spill — one row is
  one row.
- `InputPull` / `input_pull` (named `AggPull` / `agg_pull` until §33 made the
  sort read the same cursor) — a cursor over the table's stream with the build
  filter and the deferred `WHERE` applied per batch, and `next` that never hands
  out a zero-row batch, since a fold of nothing adds nothing and the batch
  contract forbids it.
- `run_agg_pull(entry, launch, stats)` — `aggregate_seq` over that cursor, then
  HAVING, the projection and the `OFFSET`/`LIMIT` window, which is exactly what
  the eager tail applies to an aggregate's one output batch. It is one
  `match streaming_agg_source(...)` at the top of `run_pipeline`; everything
  else keeps the collected path.

The result is still one batch — an aggregate has no first row before the last
input row — so `stream`/`stream_with` hand a group result out as one batch, as
§31 already said. What changed is the memory the operator needs to get there.

**The counters do not move.** `InputPull` counts the rows the build filter kept,
which is the number `materialize_scan` reports for the same table, and
`run_agg_pull` pushes `("scan t", n)`, `("aggregate", groups)` and
`("result", rows)` in the same order the eager tail does. `--analyze` output is
identical for both paths on a battery of shapes: global `COUNT`/`SUM`/`MIN`/
`MAX`/`AVG`, `GROUP BY` a string key, `GROUP BY` an int32 key, `WHERE` before the
group, `HAVING`, `LIMIT`/`OFFSET` on the group result, `COUNT(DISTINCT ...)`
both global and grouped, and an empty table. `engine/agg_pull_wbtest.mbt` pins
that: the same SQL run once without a budget (pulled) and once with a budget
(collected, since a budgeted `GROUP BY` keeps the old path) must produce the
same rows *and* the same counters, which they do —
`[("scan t", 12), ("aggregate", 4), ("result", 4)]` for both.

**The number.** 16-column, 2,000,000-row CSV fixture, release build, one process
per measurement, peak RSS from `os.wait4` (raw; the floor is about 22 MB):

| case | before | after |
|---|---|---|
| `select count(*) from t` | 231.4 ms / 35.4 MB | 227.1 ms / 35.2 MB |
| `select cat, count(*) from t group by cat` | 337.7 ms / 109.7 MB | 323.1 ms / **35.3 MB** |
| `select cat, avg(f64), sum(i64) from t group by cat` | 437.7 ms / 149.9 MB | 414.3 ms / **35.2 MB** |
| `select count(distinct cat), sum(f64) from t` | 598.5 ms / 129.6 MB | 549.6 ms / **35.2 MB** |

`count(*)` never moved because it reads no columns: there was nothing to
retain. The grouped cases fall to the plateau §31 measured for streamed
results — the process holds one batch and its group state, so the size of the
table stops mattering. The wall time moves slightly the other way for the same
reason (`DISTINCT` was also building the set while it retained the input).

The pooled benchmark carries the same change as two new cases, and the before
side was measured with the pre-E4a binary in the same session (floor 14.1 MB
subtracted, two timed runs each):

| case | before | after |
|---|---|---|
| `agg/group` (`select cat, count(*), sum(i64) ... group by cat`) | 445.8 ms / 115.1 MB | 380.4 ms / **19.6 MB** |
| `agg/global` (`select count(*), sum(i64) from t`) | 291.4 ms / 39.4 MB | 264.1 ms / **19.7 MB** |

`agg/global` moves too — the earlier `count(*)` case read no columns, but a
`SUM` over a column had that column's every batch retained. The committed record
is `harness/baseline/2026-10-26-aggregation-folded.json`; the rest of its table
does not move in any way this change could explain (`scan/count` 19.0 → 19.3 MB,
`scan/full` 18.7 → 20.3 MB, `scan/sort_limit` 51.6 → 58.2 MB, i.e. sampling
noise between invocations of the same case).

**What the tests pin.** `engine/agg_pull_wbtest.mbt` (10 tests) uses a lazy
counting source over four batches of three rows with a string key, an int32 key
and a value column, all three with NULLs, and keys that repeat across batches:

- the pull itself: unfiltered it hands over four batches of three and counts 12
  scanned rows; under `WHERE v > 90` it skips the three batches the build
  filter empties and hands over only the last one, counting the 2 rows that
  survived;
- `GROUP BY` a string key with a NULL key: four groups, the NULL key its own
  group, the NULL value left out of the sum, and the source opened once, pulled
  four times and read 12 rows;
- `GROUP BY` an int32 key with a NULL key: three groups;
- HAVING filters the finished groups (3 of 4 survive `count(*) > 2`);
- `COUNT(DISTINCT g)` and `COUNT(DISTINCT v)` count a value once across
  batches — the set outlives the batch it was first seen in;
- an empty input answers one row globally (`0` and a NULL sum) and no rows
  grouped;
- the counters match the collected run, as above;
- a source that raises on its second batch fails the aggregate rather than
  answering a partial row;
- a global aggregate answers under a budget with no spill store, because it
  never partitions.

Parity with a second implementation is covered where it already was: the 33
golden comparisons include single-table TPC-H aggregates (q6's shape has no
`ORDER BY`, so it now folds through the pull and is compared to DuckDB's
answer), `harness/check_all.sh`'s grace-aggregation equivalence checks still
exercise the spill path against in-memory answers, `harness/spill_accept.sh`
covers the store lifecycle, and the correlation differential is unchanged.

**Gates.** `moon test` 302/302 (wasm-gc), `moon test --target native` 315/315,
`moon test --target js` 302/302, `moon check --deny-warn` clean, `moon fmt
--check` clean, `.mbti` unchanged (the new items are private to the package),
`harness/check_all.sh` 33/33 golden comparisons plus the spill-equivalence and
reader-fixture checks, `harness/spill_accept.sh` all checks,
`harness/check_cli.sh` all five sections, `harness/check_correlation.py` fixed
cases and `--random 400 --seed 20261025` both ok, 66 Python harness unit tests,
and `harness/check_release.py` ok at 0.6.0.

## 33. ORDER BY sorts, feeds and hands over incrementally (2026-10-26)

**The claim.** A budgeted `ORDER BY` over one table no longer collects its input
either. §31 gave the scan a pull interface and §32 let an aggregate fold that
pull; a sort is the other blocking operator with a streaming shape, and it was
still going the long way round: `run_pipeline` materialized every row into
`joined`, `external_sort_project` took that array, wrote runs from it, and
returned one materialized batch — which `stream` then handed back as a one-batch
stream. So a "streamed" sorted result had already built both the input array and
the sorted answer before the caller saw its first row.

**What was in the way.** Three things, and only the third was new code:

1. `external_sort_project(kept : Array[DataBatch], …)` — the sort's entry point
   was an array, so the caller had to build one. Run building, the reduction and
   the merge all worked on batches already.
2. `final_merge` drained the k-way merge into one `concat_batches` because it
   had to return a `DataBatch`. The merge itself (one `RunReader` per run, pick
   the smallest current row, project, dedupe, window) was per-row already; only
   the accumulation was the batch.
3. Nothing owned the run files. §32's stream contract could promise "a stream
   owns no spill files" precisely because a budgeted shape was materialized
   before the stream was handed out — `external_sort_project` removed its files
   before returning. A stream over the merge would have to break that promise in
   the honest direction: it now owns them.

**What landed.**

- `engine/extsort.mbt`: `build_runs(next, keys, budget, store)` takes a batch
  source instead of an array — `next` is called until it answers `None`, each
  batch is sorted and chunk-split as before, and a source that never fills the
  accumulator writes no file at all (the in-memory fallback, unchanged). 
  `external_sort_project` now takes `(next, pre_types, …)` and is nothing but
  `build_runs` + the reduction + `final_merge`. `MergeCursor` is the final merge
  as a cursor: `merge_open` reads the merge inputs, `next` returns up to 4,096
  projected/deduped/windowed rows and stops as soon as the OFFSET/LIMIT window
  is full, and `final_merge` is now `merge_open` + drain + `concat_batches`, so
  the collected answer and a streamed one are the same cursor with one of them
  concatenating. `reduce_runs` (was `reduce_and_merge`) reports the files it
  writes back to its caller's `owned` list instead of deleting them itself —
  ownership had to move up when the merge stopped being self-contained.
- `engine/stream.mbt`: `streaming_sort_source(bq, sources, opts)` is the shape
  predicate (one lazy table, `ORDER BY`, no aggregate, no window, `budget > 0`);
  `sort_input` feeds the scan's pull into `build_runs` and answers
  `(scanned, runs, InMemory | Runs)`; `run_sort_pull` is the collected form
  (`execute` — the input is no longer an array, and a LIMIT stops the merge);
  `ResultStream::sorted` is the streamed form, with `StreamPull::Sorted` wrapping
  a `SortedPull { cursor, store, owned }` that removes its files when the merge
  ends, when `close` stops it, and when it raises. `InputPull` is `AggPull`
  renamed: the sort and the fold read a table the same way.
- `engine/engine.mbt`: `run_pipeline` dispatches `streaming_sort_source` before
  the scan loop, so the collected path never builds `joined` for this shape;
  `run_select_stream_opts` dispatches it before the materialized fallback. The
  eager sort branch stays for the shapes that must collect (joins, budgeted
  GROUP BY, windows) and now feeds `external_sort_project` from a producer over
  the array it already has.
- The empty-input layout comes from the schema (`sort_pre_types`), not from
  `batches[0]`: a table with no rows still answers one empty batch in the
  query's own column layout, which is what the collected path returns.

**The one promise this amends.** §31/§32 said a stream owns no spill files. That
is still true of every shape except a spilled sort, and it is now stated as what
it is: a sorted stream owns its runs and releases them on exhaustion, on `close`
and on error; a caller that drops one unfinished leaves them to the store's
owner (the CLI removes its per-query directory at exit, a library caller's
`SpillStore` is the caller's to sweep). `engine/stream.mbt`'s header,
`moonlake.mbt`'s `stream_with` doc and the README paragraph were rewritten
rather than quietly contradicted.

**The counters do not move.** A sort has to read the whole table either way, so
`scan t` is the same number; `spill runs` is the number of primary runs (not the
files alive at the end); `result` is the row count after the window. Measured
against the pre-E4b release binary at `--memory 1M` on the 200,000-row fixture,
`--analyze` output is identical for `order by … limit 10`, for
`order by … desc, … limit 5 offset 100`, for `select distinct … order by …` and
for a sort with no LIMIT, including `spill files`, `spill bytes written` and
`spill bytes read` (the store's own counters: the same files are written and
read).

**The number.** 2,000,000 rows, 16 columns, `--memory 8M`, best of three
(`os.wait4` max RSS, same session, pre-E4b binary versus this one):

| query | before | after |
|---|---|---|
| `select * from t order by id` (no LIMIT) | 6073 ms / 506.8 MB | 5948 ms / **178.8 MB** |
| `select * from t order by id limit 10` | 5053 ms / 335.0 MB | 5034 ms / **168.7 MB** |
| `select id from t order by id limit 10` | 319 ms / 43.8 MB | 300 ms / **39.3 MB** |
| `select id, i32 from t order by i32, id limit 10 offset 1000` | 993 ms / 55.4 MB | 992 ms / **41.3 MB** |

The no-LIMIT row is the one that shows what changed: the sorted answer used to
exist as an array before the stream returned it, so peak RSS was input + answer;
now the merge hands the answer out batch by batch and the peak is the merge
state. The remaining ~170 MB in the 16-column rows is not the input: it is
`FANIN` decoded runs. The accumulator flushes at `budget/4` **estimated** bytes
(`estimate_batch_bytes`, which is the serialized size), while a decoded run costs
several times that, so the merge's live set is `FANIN × decoded-run`, not
`budget`. Narrow columns land near the budget (`select id …`: 39.3 MB at an
8 MB budget, and 39.5 MB at 1 MB — the scale is the fixed part). Making the
estimate account for decoded width would change run sizes and every recorded
spill number, so it stays a known limit, recorded here rather than fixed
silently.

**What the tests pin.** `engine/sort_pull_wbtest.mbt` (11 tests) uses the §32
fixture (four batches of three rows, string/int32/value columns with NULLs, keys
that repeat across batches) and a 10-batch, 10,000-row tie fixture, plus an
inspectable in-memory `SpillStore`:

- every sort shape returns the collected answer's rows at four budgets (64 B,
  512 B, 4 KB, 1 MB — many runs, several batches per run, and the in-memory
  fallback), including `desc nulls last`, `nulls first`, `DISTINCT`, and
  `LIMIT 2 OFFSET 1`;
- a 10,000-row streamed sort comes back as three batches (4,096 + 4,096 + 1,808),
  each no larger than the cursor's batch, in order across batch boundaries;
- the run files exist while the merge is handing rows over and are gone when it
  ends — and gone after `close` stops it early, with `next` then answering
  `None`;
- a store that raises on read fails the stream and leaves no files;
- the collected sort under a budget matches the unbudgeted answer for four
  shapes, and reports the same counters as the streamed form (`scan t` 12,
  `result` 3, one `spill runs` entry);
- an input that fits the accumulator writes no file and reports no
  `spill runs` entry, which is the E4b-untouched fallback;
- an empty table answers one empty typed batch, then `None`;
- a budgeted `ORDER BY … LIMIT 10` still pulls every batch and still prunes the
  projection to one column;
- a `MergeCursor` with `LIMIT 3` over two runs takes three rows, reports
  `taken == 3`, answers `None` next, and leaves its files to the caller.

Parity with the other implementation is covered where it already was: the 33
golden comparisons include TPC-H `ORDER BY` queries (unbudgeted, so they take
the eager path through the same `build_runs`/`MergeCursor` code),
`harness/check_all.sh`'s external-sort equivalence checks run the spilled sort
through the new streaming path and diff it against the in-memory answer,
`harness/spill_accept.sh` covers the store lifecycle, and the correlation
differential is unchanged.

**Gates.** `moon test --target native` 326/326, `moon test` (wasm-gc) 313/313,
`moon test --target js` 313/313, `moon check --deny-warn` clean, `moon fmt
--check` clean, `.mbti` unchanged (everything new is private to the package),
`harness/check_all.sh` 33/33 golden comparisons plus the equivalence and reader
checks, `harness/spill_accept.sh` all checks, `harness/check_cli.sh` all five
sections, `harness/check_correlation.py --random 400 --seed 20261025` ok, 66
Python harness unit tests, and `harness/check_release.py` ok at 0.6.0.

## 34. A join probes a batch at a time (2026-10-26)

**The claim.** A two-table join is the operator that cannot avoid holding one
side — a probe row has to find its matches, so the build side stays resident —
but it was holding three. `exec_joins` collected the probe side, concatenated
the build side, built the hash maps, and `concat_batches`d every output chunk
into one batch, so the probe rows, the build rows and the joined row set were
all alive at the same time. Only the first of those is forced: the probe side
can arrive a batch at a time, and the joined rows can leave in batches.

**What was in the way.** `join_step(acc : Array[DataBatch], right : Array[DataBatch], step)`
took both sides as arrays and returned one `DataBatch`. Splitting it needed
three things: a cursor that owns the hash maps and pulls probe batches, a way to
slice one probe batch's matches into output batches when a duplicated key makes
it overflow, and a decision about which shapes can be probed at all.

**What landed.**

- `engine/exec_join.mbt`: `JoinCursor` is one hash join as a cursor —
  `{ build, int_map, str_map, matched, next_left, out_l, out_r, … }`.
  `JoinCursor::open(step, build, next_left)` takes the resident build side and a
  probe source; `prime` builds the map from the first probe batch and picks the
  int-key fast path (`int_key_cols`) or the canonical-string one; `match_batch`
  probes one batch, applies the residual per candidate, marks matched build ids
  and keeps unmatched probe rows for `Left`/`Full` (right id `-1`); `slice`
  gathers at most `JOIN_OUT_BATCH` (4096) pending pairs into one output batch,
  mapping `-1` to NULL; `next` drains pending output, pulls the next probe
  batch, and at exhaustion appends the `Full` tail of unmatched build ids.
  `join_step`'s plain branch is now build-concat + cursor over `acc` +
  `drain_join`, so **the collected path and the streamed path are the same
  cursor** and cannot disagree; `join_swapped` (RIGHT), `join_semi`
  (SEMI/ANTI/AntiLoose) and `grace_join` are untouched.
- `engine/stream.mbt`: `streaming_join_source(bq, sources)` is the shape
  predicate — two lazy tables, `steps.length() == 2`, `steps[0].table == 0`,
  `steps[1].table == 1`, kind ∈ `Inner|Left|Full`, both keys non-empty, and no
  `aggregate`/`order_by`/`windows`/`distinct` above it. `ResultStream::joined`
  materializes the build side through `materialize_scan` with the step's
  `build_filter`, then wraps `table_input_pull` (the collector factored out of
  `input_pull`) in `JoinedPull`, which applies the deferred predicate, the
  projection and the OFFSET/LIMIT window per output batch — so a `LIMIT` stops
  probing as soon as its window fills.
- `engine/engine.mbt`: `run_select_stream_opts` dispatches join → sort → scan →
  materialized. `run_pipeline` is unchanged, so `execute` and `--analyze` still
  run the collected path over the same cursor.

**What stays eager, and why.** Each of these is a test, not an omission:

- a chain of three or more joins — the probe side is itself a join, which would
  have to be pulled first;
- `RIGHT` — `join_swapped` swaps the sides, so the probe table is the one that
  must be resident;
- `SEMI`/`ANTI` — decorrelation turns them into a synthetic semi/anti table
  joined from the probe side, so the surviving shape is a *single-table scan*
  with a deferred filter: it streams as a scan, which is why its batch count is
  not one;
- a keyless cross join — the memory budget refuses one that overflows instead of
  partitioning it, and a stream that silently answered what `--analyze` refuses
  would be a worse inconsistency than the collection it saves;
- anything above the join that needs every row first: `ORDER BY`, `GROUP BY`,
  `DISTINCT`, a window function, a derived table, a set operation.

The grace/budget path is not fed incrementally: a two-table join of this shape
never reaches it (it is smaller than the budget in the streamed form), while a
chain of three or more still does and still spills.

**The number.** 2,000,000 rows and 16 columns on the probe side, release
builds, one process per measurement, best of three, peak RSS from `os.wait4`
(raw, floor ~22 MB), same session, pre-E4c binary versus this one:

| query | before | after |
|---|---|---|
| `select * from t join d on t.id = d.id` (1,000-row build, no budget) | 582 ms / 270.8 MB | 428 ms / **35.3 MB** |
| the same under `--memory 8M --spill-dir` | 1986 ms / 270.2 MB | 413 ms / **35.5 MB** |
| `select t.id, t.i32, t.i64, d2.v from t join d2 on t.id = d2.id` (2,000,000-row build and output) | 1780 ms / 404.1 MB | 1660 ms / **272.4 MB** |

The first two rows are the claim: the probe side and the answer no longer exist
as arrays, and under a budget the grace path is not entered at all — 1986 ms
became 413 ms because nothing spills. The third row is the honest ceiling: with a
2,000,000-row build side the build is resident by necessity, and the remaining
272 MB is that side plus how it is read (CSV batches, then one concatenated
batch), not the probe side or the answer.

**The counters do not move.** `--analyze` runs the collected path, so for the
fixture it still prints `scan l: 5`, `scan r: 6`, `joins: 7`, `result: 7` on both
deliveries, and `harness/check_all.sh`'s grace-join equivalence checks are
unchanged. A streamed join reports no counters of its own: it has no spill files
to account for.

**What the tests pin.** `engine/join_pull_wbtest.mbt` (14 tests) uses a lazy
two-column fixture whose `cells` array records `[opens, pulls, rows, projection
width]`, so each test can see what the engine asked the sources for:

- twelve join shapes — inner, left, full, right, semi, anti, residual `and`
  predicates on each side, `WHERE` on the build and on the probe side —
  return the same rows from `stream` and from `execute`, compared as multisets;
- a duplicated probe key fills the size cap exactly: 5,000 probe rows against a
  two-row build come back as 4,096 + 4,096 + 1,808 rows and 10,000 joined rows;
- duplicate keys on both sides cross-multiply (2 × 3 = 6 rows);
- an empty build side leaves an inner join with nothing, `LEFT` keeps every
  probe row with a NULL right side, and `FULL` degenerates to the `LEFT` answer;
- an empty probe side emits nothing until the `FULL` tail, which arrives once;
- `NULL` keys match nothing: `INNER` 1 row, `LEFT` 2, `FULL` 3;
- a residual decides pairs and `LEFT` keeps a row with no passing pair (2 rows,
  3 rows);
- closing after one output batch stops the probe side — `pulls == 1` of eight
  available probe batches;
- `LIMIT 3` over 1,000 probe rows pulls fewer than all 100 batches, and
  `LIMIT 2 OFFSET 998` is carried across batch boundaries;
- the probe-side filter is applied before the join and the deferred predicate
  after; the same query with an `ORDER BY desc` above it goes back to one batch;
- the eagerly executed shapes above each return exactly one batch and the
  collected answer's rows, and a semi/anti join agrees while streaming as a scan;
- each table is opened once: two opens total, and the build side is read whole
  before the probe starts;
- the collected path is unchanged: one batch, the same row count, and the same
  `--analyze` counters as before the stream existed.

**Gates.** `moon test --target native` 340/340, `moon test` (wasm-gc) 327/327,
`moon test --target js` 327/327, `moon check --deny-warn` clean, `moon fmt`
clean, `.mbti` unchanged (everything new is private to the package),
`harness/check_all.sh` 33/33 golden comparisons plus the equivalence and reader
checks, `harness/spill_accept.sh` all checks, `harness/check_cli.sh` all five
sections, `harness/check_correlation.py --random 400 --seed 20261025` ok, 66
Python harness unit tests, and `harness/check_release.py` ok at 0.6.0 (206 files
in the archive).

## 35. A second table prices the dictionary, and finds the row group bigger (2026-10-26)

**The claim being tested.** The writing row of the roadmap says a per-column
dictionary takes a TPC-H `lineitem` file from 288 MB to 196 MB (−32%) at no
write- or read-time cost, and that the choice must be per column because a
dictionary *grows* a column with nothing to repeat. One table is not evidence
for a heuristic, so W0 asked a second one: does the same encoding pay elsewhere,
would one rule pick the right columns, and is it worth implementing in this
release.

**The dataset.** A web access log, built by `harness/dict_survey.py` from seed
20261026 rather than committed: 500,000 rows, eleven columns chosen to disagree
with each other — a monotonic `int64` clock, a 20,000-valued `int64` id, two
tiny string enumerations (40 countries, 6 devices with 3% NULLs), a repetitive
long string (`path`, 3,000 values, about 55 characters), a near-unique long
string (`query`, 497,511 values, about 70 characters), a 9-valued `int32`
status, unique `double` and `int64` measurements, a boolean, and a 2,000-value
string with 40% NULLs. PyArrow writes it; the file the footer describes is the
only thing being compared.

**Same layout or the comparison is meaningless.** Our writer emits one row group
per 4,096-row batch; PyArrow's default is 65,536. The first run compared the
encodings across that difference and produced read numbers that were really
layout numbers, so the script now writes at 4,096 by default (our writer's
layout) and runs the chosen set once more at 65,536 as a control. Both layouts
are recorded below, because the answer depends on which one is asked.

**Per column, at our writer's 4,096-row groups** (one column per file, plain
pages versus dictionary pages, same codec and layout):

| column | role | distinct | plain B | dict B | delta | dictionary used |
|---|---|---|---|---|---|---|
| `ts` | monotonic | 500,000 | 2,025,826 | 2,781,233 | +37% | yes |
| `uid` | medium | 20,000 | 2,002,029 | 2,612,735 | +31% | yes |
| `country` | tiny | 40 | 1,016,812 | 418,153 | −59% | yes |
| `device` | tiny, nullable | 7 | 1,164,792 | 250,453 | −78% | yes |
| `path` | repetitive string | 3,000 | 3,660,641 | 2,794,673 | −24% | yes |
| `query` | near-unique string | 497,511 | 5,370,938 | 6,126,023 | +14% | yes |
| `status` | tiny | 9 | 866,390 | 279,164 | −68% | yes |
| `latency` | unique `double` | 383,746 | 2,629,995 | 3,380,268 | +29% | yes |
| `size` | unique `int64` | 470,152 | 2,535,995 | 3,290,431 | +30% | yes |
| `flag` | boolean | 2 | 79,335 | 79,335 | 0% | no (falls back) |
| `note` | medium, nullable | 2,001 | 1,824,379 | 1,534,590 | −16% | yes |

The signs are the same as `lineitem`'s: tiny enumerations and repetitive strings
win by a lot, high-cardinality columns lose, and a boolean is not
dictionary-encoded at all (the footer says `RLE, PLAIN` even when asked). The
magnitudes are not. `path` and `note` win far less than their lineitem
counterparts, and `uid` — which wins 21% at 65,536 rows per group — *loses* 31%
at 4,096, because a dictionary page is written once per column chunk: a chunk
holding nearly as many distinct ids as rows re-stores almost the whole column,
and Snappy had already squeezed the plain `int64` pages it replaced.

**Per column, at 65,536-row groups** (the same script with `--row-group 65536`):

| column | delta at 4,096 | delta at 65,536 |
|---|---|---|
| `country` | −59% | −62% |
| `device` | −78% | −81% |
| `status` | −68% | −70% |
| `path` | −24% | −74% |
| `note` | −16% | −67% |
| `uid` | +31% | −21% |

The three that move are the three whose dictionary is worth storing once and
amortizing: a repeated long string and a medium-cardinality id pay for their
dictionary page in every chunk. Sixteen times fewer chunks is sixteen times
fewer copies of it.

**The whole file.**

| variant | bytes | vs plain | write ms | DuckDB read ms | our read ms | our read peak |
|---|---|---|---|---|---|---|---|
| 4,096-row groups: | | | | | | |
| plain+snappy | 23,153,871 | — | 145 | 16 | 348 | 13 MB |
| dictionary on everything | 23,525,033 | +1.6% | 248 | 16 | 309 | 13 MB |
| dictionary on the five that win here | 19,899,055 | −14.1% | 165 | 14 | 284 | 13 MB |
| moonlake `--snappy` | 22,844,269 | −1.3% | 745 | 17 | 334 | 13 MB |
| 65,536-row groups: | | | | | | |
| plain+snappy | 22,822,656 | — | 131 | 25 | 363 | 57 MB |
| dictionary on everything | 19,636,566 | −14.0% | 202 | 14 | 283 | 39 MB |
| dictionary on the six that win here | 16,400,404 | −28.1% | 128 | 13 | 253 | 38 MB |
| moonlake `--snappy` (still 4,096 rows per group) | 22,844,269 | +0.1% | 774 | 15 | 336 | 13 MB |

Four things are decided by this table.

1. **A table-level dictionary is a net loss.** On everything it is 1.6% *larger*
   than plain at our layout: the four losing columns give back more than five
   winning ones save. The per-column choice is not a refinement, it is the whole
   value of the encoding.
2. **Our writer is at parity with PyArrow's plain output.** On this table
   `--snappy` is 1.3% *smaller* than PyArrow at the same layout and 0.1% larger at
   the other, which is the second dataset confirming the single-tag fix that
   closed the 16% gap on lineitem. What is left is the encoding, not the codec.
3. **The dictionary is worth −14% at our layout and −28% at PyArrow's**, so the
   encoding and the row-group size are not independent decisions, and the layout
   is the larger lever: `path` alone is 3.66 MB plain at 4,096 and 0.93 MB with a
   dictionary at 65,536.
4. **The layout also sets what a read costs, in both directions.** Reading our
   own 4,096-row-group file costs 13 MB of peak RSS; reading the 65,536-row-group
   file with the same engine costs 57 MB, because the reader holds one row
   group's decoded columns. The dictionary then brings that 57 MB back to 39 MB
   by making the file smaller, but it never gets near the small group's 13 MB.
   A smaller file is not automatically a cheaper read.

**What W0 decides.** The investigation is complete and it does not start the
implementation in this release. A dictionary is worth a sixth of the file at the
layout we write today, and a per-chunk choice is implementable streaming —
sample the batch, dictionary the columns whose values repeat, fall back to
`PLAIN` — but the same table says the row-group size would double that win, and
implementing the encoding first would bank the smaller half and make the
comparison afterwards harder to read. That is the same ordering argument the
2026-10-24 entry used to postpone the dictionary behind the Snappy tag, applied
to the same row. So the hold-list entry now starts from the row-group size, with
this script as the fixture to tune against, and W1 stays out of 0.6.0. Nothing
in the writer changed for this section; the numbers labelled "moonlake" above
are the current `write --snappy` output, and everything else is PyArrow encoding
a hypothetical.

**How to reproduce.** `python3 harness/dict_survey.py --rows 500000` and the
same with `--row-group 65536`. The script regenerates the dataset from the seed,
asserts every file returns the same answer (a `double` sum is compared with a
relative tolerance, since summation order differs between the two writers), and
prints both tables. It is a measurement tool and not a gate: nothing here
depends on the numbers, which is why the JSON record stays out of the repository.
\n
## 36. 0.6.0 acceptance on one candidate (2026-10-26)

**The claim being tested.** The roadmap's "What 0.6.0 has to clear" is a list of
gates, and a gate list is only a claim until one tree passes all of it: the
manifest, library constant, generated interfaces and changelog agree on 0.6.0;
the linter, formatter, interface freshness, the native/wasm-gc/js suites and the
Python gate self-tests pass; the goldens pass on all three targets and through
the built binary; the differential, corpus, encoding, CLI, spill and writer
gates pass; a file past 2 GiB round-trips; the packaged consumer pulls results
on all three targets with fresh caches; the browser page runs; and the release
has a performance record taken beside the release it replaces. The remaining
eager paths and platform limits have to be recorded as limits, not left to be
discovered.

**The candidate.** `3ab2634`, the last commit that changes `harness/`, on top of
`dcc6ae7` (the last library change); the commit carrying this section adds
documentation and the two baseline records only. The working tree was clean when
each gate below ran. Every version claim says 0.6.0; the released version is
still 0.5.0 at tag `v0.5.0`, and nothing was pushed, tagged, published or
deployed.

**Gates, and what each one actually ran.**

| Gate | Result |
|---|---|
| `moon check --deny-warn` | Clean, 46 tasks |
| `moon fmt --check` | Clean |
| `moon info`, then `git diff -- '*.mbti'` | No interface change |
| `moon test --target native` | 340 passed |
| `moon test --target wasm-gc` | 327 passed |
| `moon test --target js` | 327 passed |
| Python harness unit tests (`unittest discover -s . -p 'test_*.py'` in `harness/`) | 75 passed (Python 3.12.14, DuckDB 2.0.0, PyArrow 26.0.0) |
| `bash harness/check_all.sh` (default wasm-gc) | 33/33 goldens, 2 m 05 s |
| `MOONLAKE_TARGET=native` | 33/33, 5 s |
| `MOONLAKE_TARGET=js` | 33/33, 13.6 s |
| `MOONLAKE_BIN=_build/native/release/build/cmd/main/main.exe` | 33/33, 2.4 s |
| `harness/check_correlation.py --random 400 --seed 20261025` | ok (S0 differential) |
| `harness/check_windows.py --random 400 --seed 20261023` | 8 value cases matched, nothing refused |
| `harness/fuzz_pushdown.py` | 300 queries, 0 failures, 0 rejections |
| `harness/check_colenc_fixtures.py` | 8 embedded + 9 regenerable cases at page level |
| `harness/check_parquet_corpus.py` | 17 decoded by value, 51 refused by design, 0 failing |
| `bash harness/check_cli.sh` | Pass (partial output on a mid-scan failure included) |
| `bash harness/spill_accept.sh` | Pass (five lifecycle cases) |
| `harness/check_writer_interop.py` | Pass (schema, values, NULLs, both directions, `--snappy` 140,290 -> 24,334 bytes) |
| `harness/check_large_write.py` | 2,410,475,894-byte file, 34,400,000 rows, 8,399 row groups, 1,820 of 16,798 column chunks past 2^31, three readers agree |
| `harness/check_consumer.py` (archive, fresh `MOON_HOME`) | native, wasm-gc and js: version, CSV, Parquet raw/Snappy, DATE/NULL, drop, and four streamed shapes agreeing with the collected answers |
| `harness/check_release.py --check-consumer` | Version agreement, archive contents, consumer |
| Playground: `moon build --target wasm-gc playground` + import audit | `playground.wasm` imports only `wasm:js-string` and `_` |
| `harness/playground_accept.cjs http://127.0.0.1:8971/index.html` | 16/16 in real Chromium (page reports 0.6.0) |
| Performance pair (this section's last part) | `--compare` 0.5.0 re-record -> 0.6.0: nothing outside run-to-run noise but the filtered count |

**The three-target goldens are the reason the target switch was worth adding.**
Before it, `check_all.sh` could only ever run `moon run cmd/main`, so the release
claim "the goldens pass" meant "the wasm-gc interpreter passes". `MOONLAKE_TARGET`
runs the same 33 goldens through native and js, and `MOONLAKE_BIN` runs them
through the release binary a user actually gets. The three backends differ where
this project's readers differ — native reads files with `fs`, wasm-gc and js go
through the host, and wasm-gc writes `%eprintln` to stdout, which is why the
checks print their own `[stderr]` marker rather than trusting the channel — so a
pass on one backend was never evidence for the others.

**The consumer is the API, not the code.** `harness/consumer/main.mbt` is copied
into a module that has no access to this checkout, built against the archive just
packed, with a fresh `MOON_HOME` and freshly downloaded dependencies. 0.6.0's
addition is the result API, so the consumer now drains four shapes — a scan with
a filter and a window, a two-table join, a folded aggregate and an unordered
`ORDER BY` — and requires each pulled delivery to print exactly what
`execute(...).to_json()` prints for the same query, using `JsonRow::batch` the way
the CLI does. It then stops a stream after its first batch and checks `close`.
That is the one check that would still fail if the public boundary rotted while
everything inside the module stayed green.

**What this pass does not close.** The nightly job at *this* SHA needs the push
that release authorization covers: the job exists (`.github/workflows/nightly.yml`,
including the >2 GiB write) and last ran green at run `40077399241` on
2026-10-24 against the then-`main`, which is history rather than acceptance. The
same applies to the hosted playground deployment (require the exact 0.6.0 version
after it), to `check_consumer.py --registry-version 0.6.0` (needs publication)
and to `moon publish --dry-run`. Locally, everything above was run on this
candidate. The eager shapes the release still has are recorded rather than
removed: `engine/stream.mbt` and `verification` §34 list the shapes that
accumulate, and the roadmap's "Current implementation" paragraph keeps the user
facing version of the list.

**Performance.** The pair is in `bench-baseline.md`'s last section: 0.6.0 at
`3ab2634` beside a 0.5.0 re-recorded from tag `v0.5.0` in a worktree minutes
apart, with one case (`scan/filtered_count_csv`) measured as a real ~4% cost by
an interleaved A/B and ten cases inside their own spread. Peak RSS falls on
every case whose answer used to be collected — the two-table join 51.0 -> 35.1 MB,
the 600k-row self-join 53.1 -> 41.3 MB, the wide projection 310.9 -> 237.2 MB.

**How to reproduce.** Build with `moon build cmd/main --target native --release`
and run the commands in the table with
`UV_CACHE_DIR=.internal/uv-cache uv run --python 3.12 --with-requirements
harness/requirements.txt python ...` for the Python gates. `check_large_write.py`
needs about 5 GB of scratch and a few minutes; the playground needs
`PLAYWRIGHT_MODULE` pointing at a Playwright install and the page served over
HTTP. The four `harness/check_all.sh` invocations are the same script with
`MOONLAKE_TARGET` or `MOONLAKE_BIN` set.

## 37. The nightly's one red: a footer that undercounted its own chunk (2026-10-26)

Nightly run `40177160450`, head `750b98c`, failed one step of the `fuzz` job,
the corpus cross-check: `nation.dict-malformed.parquet: decoded -> failing`,
`unexpected refusal: … page at offset 292 claims 28 payload bytes, past the end
of the file`. The local branch is 39 commits ahead of that head, and only this
file was red — the other 67 classified as their record says.

**The arithmetic.** The file is 2850 bytes and upstream has not touched it since
2018-09-03. `comment_col`'s chunk starts at byte 591 and the footer declares
`total_compressed_size` 2002, but its pages need 2017: a 15-byte dictionary page
header with a 1957-byte payload, then a 17-byte data page header with 28 bytes
of payload. The last payload ends at byte 2608, exactly where the 234-byte
footer begins. Nothing in the file is truncated; only the footer's own sum omits
the dictionary page header.

**Why it appeared in 0.5.0 and not before.** `d6cf724` (0.5.0) sized each chunk
from that number and read it as one range, so the last page's 28 bytes sat
outside the buffer the decoder owned, and the bounds check, written against
`data.length()`, called a chunk-relative offset "past the end of the file".
Before 0.5.0 the whole file was the buffer and the file decoded correctly. So
0.5.0 and 0.6.0 both refused a file PyArrow and DuckDB read, and the local
commit that settled the fixture recorded the refusal as the expected class: a
regression normalized as a decision, plus a message that named the wrong
quantity.

**The fix.** `walk_chunk` follows the page headers now, as the reference readers
do. `decode_chunk` hands it a `grow` closure; when a page's payload passes the
declared extent, the closure re-reads the chunk from its start far enough to
hold that page (`payload_start + payload_len`). `read_page_tail` refuses only
when that length passes the end of the file, and it names the file offset and
the column. Genuine truncation is refused exactly as before.

**Evidence.** `select nation_key, name, region_key, comment_col from
"nation.dict-malformed"` returns 25 rows × 4 columns and agrees with DuckDB cell
for cell (25 rows compared, 0 mismatches, including the `comment_col` strings the
last page carries). Three whitebox tests in `sources/parquet/scan_wbtest.mbt`
pin the shape: a hand-built footer that understates the chunk still reads its
last page (asserting the second read, at the same offset, is exactly `short`
bytes longer), a tail past the end of the file is refused by column name and
file offset before any read is attempted, and a tail inside the file is read
from the chunk start. `check_parquet_corpus.py` reports 17 decoded by value, 51
refused by design, 0 failing, the count §11 recorded before the ranged read
landed. `--update` re-records the one class change
(`nation.dict-malformed: refused -> decoded`), and the stale `{el.name}`
descriptions in the same file became the real column names, since the gate
compares classes and treats `why` as prose. Suites at 330 (wasm-gc), 343
(native) and 330 (js), `moon check --deny-warn` and `moon fmt --check` clean, no
`.mbti` change: the whole edit is inside the package's private reader path.

**What it does not close.** The nightly stays red until this is pushed, and
0.6.0 is still unreleased. The other 51 refusals are the declared scope, not
defects; the one shape this file taught is that a footer number is evidence
about the writer's bookkeeping, not about where the pages end.

## 38. colenc 0.1.1 is consumed (2026-10-26)

`moon.mod` imports `superbigcup325/colenc@0.1.1` now, C0 of
[the follow-up plan](ROADMAP.md#follow-up-after-colenc-011), and the README's
build instructions and the AGENTS.md dependency notes name the same version.
`moon tree` reports `superbigcup325/colenc@0.1.1` with no `moon.work` and no
`.colenc` symlink, and the copy resolved under `.mooncakes/` is 0.1.1: the
registry index and the cached 0.1.0 copy both had to go first (`moon update`,
then the first `moon check` downloaded the artifact).

**Nothing in code had to change.** 0.1.1 adds `Encoding::Roaring`, the
`sketches` package and three `EncodingError` variants (`OutOfRange`, `Corrupt`,
`InvalidArgument`); its interface also respells `Int` as `Int32`, which is the
same type. The engine's only contact with `EncodingError` is
`EncodingError::message`, in `sources/parquet/reader.mbt`'s `colenc_scan_error`
and `sources/parquet/write.mbt`'s `colenc_write_error`, and nothing matches on
`Encoding` variants, so the additions compile untouched: `moon info` produced no
`.mbti` diff and `moon fmt` no source change. The sketches and the bitmap are
available and unused; no SQL function, index or engine behavior changed here.

**Evidence on `24d983b`**, the commit that carries the bump:

| Check | Result |
|---|---|
| `moon check --deny-warn` | clean |
| `moon test` (wasm-gc / native / js) | 330 / 343 / 330 passed |
| goldens, `harness/check_all.sh` | 33 comparisons pass on wasm-gc, on js and through the native release binary |
| page fixtures, `check_colenc_fixtures.py` | 8 embedded + 9 regenerable cases verified at page level |
| `check_writer_interop.py` | all checks pass: raw and Snappy output, DATE/NULL, EXPLAIN rows, and a DuckDB-written file read back |
| `spill_accept.sh` | all checks pass: run-file ownership, reclaim, a shared directory, ANALYZE counters |
| `check_cli.sh` | pass: no input files, unknown command, overwrite refusal, streamed `--json`, partial output on a failed scan |
| corpus, `check_parquet_corpus.py` | 17 decoded by value / 51 refused by design / 0 failing |
| `check_release.py --check-consumer` | 210 archive files, version claims agree, consumer green on native/wasm-gc/js with fresh registry and dependency caches |

**What it does not close.** The upgrade enables the colenc surface and proves
nothing about using it: A0's semantics and state costs, A1, A2, E5 and I0 are
still proposals. Acceptance of the final 0.6.0 candidate is R2, which reruns
§36's gates on one revision — including the >2 GiB file, the host-free wasm
build and the browser playground — and the performance pair is re-recorded
last. Push, tag, publication and deployment remain unauthorized.

## 39. Approximate aggregates with a contract (2026-10-26): A0, A1, A2

Two explicit aggregates land: `approx_count_distinct(expr)` over a HyperLogLog
and `approx_quantile(expr, q)` over a t-digest, both from `colenc/sketches`
0.1.1. [docs/sketches.md](sketches.md) is the contract (types, NULL rules, value
equivalence, parameters, errors, cost); this section is the evidence.

**Where it goes.** `sql/ast.mbt` gains the two `AggFn` variants (the only public
interface change: `sql/pkg.generated.mbti`), `sql/parser.mbt` parses them, and
`engine/binder.mbt` binds them: any scalar input for the distinct count, a
numeric one for the quantile, `q` folded from a literal into `AggSpec.q`. The
fold lives in `engine/exec_agg.mbt` as two new `Acc` variants, so the in-memory
gather, the streaming pull in `engine/stream.mbt` and the grace path in
`engine/extagg.mbt` all reach it without a second implementation; the window
path calls the same `acc_step`/`acc_finish`, and `engine/prune.mbt` carries the
new field through. Both kinds stay on the boxed fold path.

**Two decisions worth their own line.** The distinct sketch is fed the exact
path's equivalence, not colenc's raw bytes: the fold canonicalizes `-0.0` to
`+0.0`, every NaN payload to one canonical NaN (the two properties their text
form has in `scalar_key`), and hashes strings as UTF-8 bytes and dates as their
epoch day. And because `acc_step` cannot raise, a non-finite quantile input sets
a flag on the accumulator and `acc_finish` raises the SQL error, so the query
fails at the same boundary as `sum()`'s overflow instead of inside the fold.

**Correctness.**

| Check | Result |
|---|---|
| `moon test` (wasm-gc / native / js) | 348 / 361 / 348 passed, 18 of them new |
| `approx_count_distinct` on 1..100 (100 values) | 100, exactly |
| on five values, and on an empty or all-NULL input | 5, 0 and 0 |
| on 10,000 distinct values | within three standard errors of 10,000 |
| on 1,000,000 distinct strings | 1,010,708 (+1.07%) against the exact 1,000,000 |
| `approx_quantile(d, 0.5)` over 0..999,999 | 499,999.5, equal to `median()` |
| `approx_quantile(d, 0.9)` over the same column | 899,999.5, the exact 90th percentile |
| `q = 0` / `q = 1` | the minimum / the maximum |
| `q = 1.5`, `q = -0.1`, `q = v`, `q = 2.0` with no rows | bind errors, the last one before any row is read |
| NaN input to the quantile | `sql error (execute): approx_quantile() requires finite input` |
| whitebox: `-0.0`/`0.0`, two NaN payloads, int32 vs int64, strings, booleans, dates | one, one, two, two, two, two values |

**Cost**, on the 1,000,000-row Parquet file, native release binary, one process
per query (a `count(col)` decodes the same column without state):

| Shape | Peak RSS | Exact counterpart |
|---|---|---|
| `approx_count_distinct(s)` | 56.6 MB | 144.7 MB for `count(DISTINCT s)`; 56.6 MB for `count(s)` |
| `approx_quantile(d, 0.5)` | 33.9 MB | 44.4 MB for `median(d)`; 34.1 MB for `count(d)` |
| `k, approx_count_distinct(s) GROUP BY k`, 1,000 groups × 1,000 distinct | 145.8 MB | 152.8 MB for the exact grouped count |

The ungrouped wins are the sketch's 64 KiB against a map that keeps every value
(88 B per distinct value here) and an array that keeps every row (8 B per row
plus growth). The grouped row is the honest other half: 1,000 sketches are
64 MB whatever their groups hold, so below roughly 750 distinct values per group
the exact path is still the cheaper one. `docs/sketches.md` records the
crossover and what an adaptive representation would have to wait for.

**What it does not close.** No optimizer rewrite, so `COUNT(DISTINCT ...)` and
`median()` stay exact and neither aggregate is chosen for the user. No
partial-state merge: the grouped path keys partitions by group key, so a group's
state is never split, and input-partitioned aggregation would need one. No
persisted sketch state and no approximate type in a result. The statistics are
the estimator's standard error and colenc's measured t-digest rank error, not a
universal bound. The 0.6.0 candidate now carries both functions, so R2 must run
its acceptance on the revision that includes them, and the release pair at the
end of `docs/bench-baseline.md` still belongs to the earlier revision.

## 40. 0.6.0 accepted again on the final candidate (2026-10-26): R2

Everything below ran on `bc1a8f5`, whose tracked tree was clean; the worktrees
used for the performance control and the bisect live outside the module. The
point of R2 is that one revision carries the Parquet reader fix, the colenc
0.1.1 upgrade and the two approximate aggregates, and all of §36's gates were
re-run on it rather than inherited.

**Correctness.**

| Gate | Result |
|---|---|
| `moon check --deny-warn`, `moon fmt --check`, `moon info` then a `.mbti` diff | clean |
| `moon test` (wasm-gc / native / js) | 348 / 361 / 348 passed |
| 33 goldens, `check_all.sh` on wasm-gc, on js and through the release binary | pass on all three |
| `check_correlation.py`, fixed cases and `--random 40 --seed 20261026` | pass |
| `check_windows.py`, 13 cases and `--random 400 --seed 20261026` | pass |
| `fuzz_pushdown.py 40 20261026` | pass |
| `check_colenc_fixtures.py` | 8 embedded + 9 regenerable cases at page level |
| `check_cli.sh` | pass, including partial output when a scan fails mid-result |
| `spill_accept.sh` | pass: ownership, reclaim, shared directory, ANALYZE counters |
| `check_writer_interop.py` | pass: raw and Snappy, DATE/NULL, EXPLAIN rows, DuckDB-written file read back |
| `check_parquet_corpus.py` | 17 decoded by value / 51 refused by design / 0 failing |
| `bench_release.py --check-oracles` | eleven timed cases agree with DuckDB |

**The heavy gates.**

- `check_large_write.py`: 2,465,688,897 bytes of CSV in, a 2,410,475,894-byte
  Parquet out, 34,400,000 rows in 8,399 row groups, 1,820 of 16,798 column
  chunks past 2^31, and pyarrow, DuckDB and moonlake all read the same answer
  back.
- Playground: `moon build --target wasm-gc playground`, then the import audit —
  `playground.wasm` imports only `wasm:js-string` and `_` — and
  `harness/playground_accept.cjs` driving real Chromium: 16/16, the page
  reporting 0.6.0.
- `check_release.py --check-consumer`: 213 archive files, no forbidden path,
  version claims agree, and the unpacked archive passes on native, wasm-gc and
  js with fresh registry and dependency caches.

**The performance pair is a cost, not a formality.** The final candidate is
about 10% slower on wide CSV scans than `3ab2634` (7–14% by run), and the bisect
puts the cause
outside this tree: `ae6a28c` (reader fix only) measures +0.3%, while `24d983b`
(the manifest move to colenc 0.1.1, source unchanged) measures 9.4% slower
against the same control. Two local colenc probes settle what the cause is: one
deletes `encoders/roaring.mbt` and refuses the facade arms, the other keeps the
file and only refuses the arms. Both produce the same 1,632,744-byte binary and
both return to the control's speed, so the cost is reachability — the generic
`encode_column` / `decode_column` dispatch that the spill format calls reaches
the 1,137 lines, so dead-code elimination cannot drop them and what remains moves
the hot loops. Memory is flat everywhere. The record, the rotating A/B numbers
and the probes are in
[bench-baseline](bench-baseline.md#060-final-record-beside-the-candidate-it-refines-2026-10-26).
The fix is to take the `Roaring` arms out of that dispatch into dedicated
functions, then re-run the pair; it is not something this tree can do for itself.
**Closed by §41**: colenc 0.1.2 publishes exactly that split, and the re-record
on this tree puts the cost at zero.
That change is implemented on colenc's unreleased `main`, and a build of this
tree against it is at control speed (157.9 against 163.0 ms median, 8,248 bytes
smaller), so what remains is a colenc release and a re-record.

**What it does not close.** Remote CI and the nightly at this SHA need the push;
`moon publish --dry-run` uploads an archive, and publication, tagging and
deployment stay unauthorized. The registry consumer for 0.6.0 and the hosted
playground's version check happen after those. Nothing here is a statement about
the published 0.5.0, and the CSV cost above is the one open decision before
publishing.

## 41. The CSV cost is gone with colenc 0.1.2 (2026-10-26): C1, C2

§40 left one measured decision open: colenc 0.1.1 kept the bitmap reachable from
the generic dispatch, and this tree built against it scanned wide CSV about 10%
slower than `3ab2634`. The fix was specified there and shipped upstream, so this
section is the consumer half — take the published artifact, rerun the whole
acceptance list, and record the pair the decision was waiting for.

**The upgrade.** `moon.mod` moves from `superbigcup325/colenc@0.1.1` to
`superbigcup325/colenc@0.1.2`, resolved from the registry with no `moon.work` and
no sibling override. It is a one-line manifest change: the two observable colenc
changes (`encode_column` / `decode_column` now refuse `Encoding::Roaring`, and
`HllSketch::registers()` returns a snapshot) are both invisible here, because the
engine reaches the bitmap through `encode_roaring_column` / `decode_roaring_column`
where it reaches it at all, and reads registers through `register(index)`.

**Correctness on the candidate (`95c42c6`).** The whole §40 list, rerun rather
than inherited:

| Gate | Result |
|---|---|
| `moon check --deny-warn`, `moon fmt --check`, `moon info` then a `.mbti` diff | clean |
| `moon test` (wasm-gc / native / js) | 348 / 361 / 348 passed |
| 33 goldens, `check_all.sh` on wasm-gc, on js and through the release binary | pass on all three |
| `check_windows.py`, 13 cases and `--random 400 --seed 20261026` | pass |
| `check_correlation.py`, fixed cases and `--random 40 --seed 20261026` | pass |
| `fuzz_pushdown.py 40 20261026` | 40 queries, 0 failures, 0 rejections |
| `check_colenc_fixtures.py` | 8 embedded + 9 regenerable cases at page level |
| `check_cli.sh`, `spill_accept.sh` | pass |
| `check_writer_interop.py` | pass: raw and Snappy, DATE/NULL, DuckDB-written file read back |
| `check_parquet_corpus.py` | 17 decoded by value / 51 refused by design / 0 failing |
| `python3 -m unittest discover -s harness` | 75 tests, OK |
| `bench_release.py --check-oracles` | eleven timed cases agree with DuckDB |
| `check_large_write.py` | 34,400,000 rows, 8,399 row groups, 2,410,836,843-byte widest offset, 1,820 of 16,798 chunks past 2^31, read back by pyarrow, DuckDB and moonlake |
| Playground in real Chromium (`playground_accept.cjs`) | 16/16 |
| `check_release.py --check-consumer` | version claims agree, 215 archive files, no forbidden path, clean tree, three-target archive consumer with fresh caches |

The gates that need reference tools ran under `duckdb==2.0.0` and
`pyarrow==26.0.0` from `harness/requirements.txt`, in a scratch Python 3.12
environment; the system interpreter has neither, and the four checks that shell
out to DuckDB fail loudly rather than skipping when they are missing, which is
how the first pass reported them.

**The pair.** Candidate `95c42c6` (colenc 0.1.2) against control `bc1a8f5`
(colenc 0.1.1) in a scratch worktree, each building its own CLI and its own
`spill_bench` driver so the control could not be measured with the candidate's
code. Three pairs, candidate first, at load average 0.9–1.7, seven runs a case
with two warm-ups, medians of the three pairs reported:

| case | 0.1.1 | 0.1.2 | delta |
|---|---|---|---|
| `scan/count_csv` | 171.3 ms | 153.0 ms | −10.7% |
| `scan/filtered_count_csv` | 188.5 | 170.0 | −9.8% |
| `join/two_table_count` | 235.4 | 214.8 | −8.8% |
| `join/q3` | 266.7 | 249.6 | −6.4% |
| `gather/self_join_fanout` | 383.2 | 348.4 | −9.1% |
| `gather/wide_projection` | 430.2 | 411.9 | −4.3% |
| `spill/order_by_wide` | 492.3 | 478.7 | −2.8% |
| `spill/format_write` / `format_read` | 1136.4 / 427.5 | 1147.0 / 420.2 | +0.9% / −1.7% |
| `scan/parquet_count` / `parquet_sum` | 3.9 / 10.8 | 4.6 / 11.4 | unresolved |

The CSV family is negative in all three rounds and the Parquet pair is the
opposite: 4 ms and 11 ms cases whose in-record spread reached 73%, with the
earlier session disagreeing on the sign for `parquet_count`. The record and the
reasoning are in
[bench-baseline](bench-baseline.md#colenc-012-removes-the-cost-on-a-quiet-host-2026-10-26).
Peak RSS is flat within 1.7 MB everywhere.

**What it does not close.** The published moonlake release is still 0.5.0:
publication needs authorization and stays outside this section, and the 0.6.0
registry consumer, the hosted playground version check and the deployment happen
after that. Remote CI and the nightly do certify these commits — `4de8077` on
`main` passed the push CI and a dispatched nightly, and pages deployed from it.

## 42. The toolchain moved and the tree needed nothing (2026-10-26): T1

The environment moved from `moon 0.1.20261016` (moonc `v0.10.16`) to
`moon 0.1.20261023` (moonc `v0.10.17`); `moon version --all` now also prints the
enabled feature flags (`rr_moon_mod`, `rr_moon_pkg`). CI installs `latest`, so
this toolchain arrives without the repository choosing it, and every acceptance
recorded in §36–§41 was taken on the older one. This section is the same tree
re-run — `a0c7628`, clean, with no source, manifest or interface change.

**Nothing in the tree had to change.** `moon check --deny-warn` is clean on
wasm-gc, native and js; `moon fmt --check` has nothing to rewrite (the
`Int` → `Int32` rewrite that followed 0.1.20261012 is not re-triggered) and
`moon info` leaves every `.mbti` byte-identical. `moon.mod` still parses on the
same keys — this CLI rejects an unknown key outright, which is how the key's
existence was checked rather than assumed — and `preferred_target = "wasm-gc"`
still selects the default backend: a scratch module carrying that line builds
`_build/wasm-gc` only. The dependency graph resolves unchanged
(`moonbitlang/x@0.5.6`, `moonbitlang/quickcheck@0.15.0`,
`superbigcup325/colenc@0.1.2`).

**The gates, re-run rather than inherited.**

| Gate | Result |
|---|---|
| `moon check --deny-warn` on wasm-gc / native / js | clean |
| `moon fmt --check`, `moon info` then a `.mbti` diff | clean, no diff |
| `moon test` (wasm-gc / native / js) | 348 / 361 / 348 passed |
| 33 goldens, `check_all.sh` on wasm-gc (36 CLI runs: `pqall` and `pqdict` run plain and Snappy) | every answer matches DuckDB |
| `check_cli.sh` | pass |
| `spill_accept.sh` | 10/10 |
| `check_windows.py` | 13 value cases matched, 1 legality-only, 2 refused by design, 6 refused in agreement with DuckDB |
| `check_correlation.py` | 45 value cases matched, 11 refused by design |
| `fuzz_pushdown.py 40 20261026` | 40 queries, 0 failures, 0 rejections |
| `check_colenc_fixtures.py` | 8 embedded + 9 regenerable cases at page level |
| `check_writer_interop.py` | pass: raw and Snappy output read by pyarrow, DuckDB and moonlake, a DuckDB-written file read back, `EXPLAIN` report |
| `check_parquet_corpus.py` | 17 decoded by value / 51 refused by design / 0 failing |
| `python3 -m unittest discover -s harness` | 75 tests, OK |
| Playground in real Chromium (`playground_accept.cjs`) | 16/16 |
| Playground wasm import gate | `playground.wasm` imports only `wasm:js-string` |
| `check_consumer.py` (fresh registry and dependency cache) | pass on native / wasm-gc / js |
| `check_release.py` | version claims agree, 217 archive files, no forbidden path, clean tree |
| `moon publish --dry-run` (writable scratch `MOON_HOME`) | `202 Accepted ... Dry run completed successfully` |

The Python gates ran on 3.12.14 with `duckdb==2.0.0` and `pyarrow==26.0.0` from
`harness/requirements.txt`.

**What was deliberately not re-run.** The performance pair: the toolchain is
part of `bench_release.py`'s fingerprint, so a record taken on 0.1.20261016 is
refused as a comparison target instead of being mixed with new timings.
Re-recording the 0.6.0 pair on this toolchain is a decision for the release
owner, not a gate, and this section makes no timing claim. `--check-oracles`
wants the SF0.1 data set, and `check_large_write.py` (34.4 M rows) exercises the
writer's wide-offset path that a compiler bump does not reach; neither was run.

**Two CLI surfaces still behave as the release gates expect.** `moon package
--list` writes its file list to **stderr**, mixed with the `moon check` progress
lines, and ends by packaging `_build/publish/superbigcup325-moonlake-0.6.0.zip`;
`moon publish --dry-run` answers `202 Accepted` and still exits 255, so the
recorded rule — read the `Server status` line, not the exit code — holds. The
dry run also still needs a writable `MOON_HOME`, because the default one is
read-only here and the unpacked-copy check fails without it.

**One thing the re-run surfaced, unrelated to the compiler.** The three fixture
generators rewrite tracked files under `harness/data/`, so running the CI
integration list locally leaves the tree dirty and `check_release.py` then fails
its clean-tree claim until `git restore -- harness/data`. Regeneration is
deterministic run to run, so the changed bytes are reference-toolchain drift: the
committed Parquet fixtures were written by DuckDB 1.5.6 and are all-nullable,
while 2.0.0 writes seven of the eight columns `NOT NULL`. Both forms pass the
goldens and the unit tests; refreshing the committed copies is a separate
decision, recorded as a pitfall in `AGENTS.md`.
