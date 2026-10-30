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

0.5.1 was checked the way a reader meets the project rather than the way the
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

## 29. Current assessment and 0.5.1 scope (2026-10-25)

This assessment used source commit `eeab95e12507b4e234c8a4c0ca684ac6980899bf`
and then changed documentation only. The working tree was clean at the start.
Live GitHub queries confirmed `main` at `750b98c250f77367e401e3afa4c74d7fc60c0c0b`,
28 commits behind the local source, and the latest release at
[v0.5.0](https://github.com/superbigcup325/moonlake/releases/tag/v0.5.0).
`moon view superbigcup325/moonlake` independently returned `Latest: 0.5.0`.
The latest checked CI and Pages successes belonged to `750b98c`; neither
validates the local candidate.

All pending changes and the remaining execution plan now target **0.5.1**.
The changelog has one `0.5.1 - Unreleased` section, with all its prior entries
preserved. Its entries describe implemented behavior. The roadmap separately
marks the result API, batch-fed aggregation/sort/join, differential gate,
dictionary investigation and final acceptance as open work for that same
version. Version fields stay at 0.5.1; this is development scope, not a release.

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
| `harness/check_release.py` before documentation edits | Pass on the clean source baseline; version 0.5.1, archive 198 files, no forbidden paths |
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
registry consumer and the remainder of the 0.5.1 delivery plan still belong to
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
and `harness/check_release.py` ok at 0.5.1.

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
Python harness unit tests, and `harness/check_release.py` ok at 0.5.1.

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
Python harness unit tests, and `harness/check_release.py` ok at 0.5.1 (206 files
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
this script as the fixture to tune against, and W1 stays out of 0.5.1. Nothing
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
## 36. 0.5.1 acceptance on one candidate (2026-10-26)

**The claim being tested.** The roadmap's "What 0.5.1 has to clear" is a list of
gates, and a gate list is only a claim until one tree passes all of it: the
manifest, library constant, generated interfaces and changelog agree on 0.5.1;
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
each gate below ran. Every version claim says 0.5.1; the released version is
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
| `harness/playground_accept.cjs http://127.0.0.1:8971/index.html` | 16/16 in real Chromium (page reports 0.5.1) |
| Performance pair (this section's last part) | `--compare` 0.5.0 re-record -> 0.5.1: nothing outside run-to-run noise but the filtered count |

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
packed, with a fresh `MOON_HOME` and freshly downloaded dependencies. 0.5.1's
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
same applies to the hosted playground deployment (require the exact 0.5.1 version
after it), to `check_consumer.py --registry-version 0.5.1` (needs publication)
and to `moon publish --dry-run`. Locally, everything above was run on this
candidate. The eager shapes the release still has are recorded rather than
removed: `engine/stream.mbt` and `verification` §34 list the shapes that
accumulate, and the roadmap's "Current implementation" paragraph keeps the user
facing version of the list.

**Performance.** The pair is in `bench-baseline.md`'s last section: 0.5.1 at
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
0.5.0 and 0.5.1 both refused a file PyArrow and DuckDB read, and the local
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
0.5.1 is still unreleased. The other 51 refusals are the declared scope, not
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
still proposals. Acceptance of the final 0.5.1 candidate is R2, which reruns
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
crossover and what an adaptive representation would have to wait for. Both
numbers belong to the 64 KiB payload; §43 re-measures them against colenc 0.1.2,
where the crossover is about 200 values per group and the grouped small-group
cost is still the problem.

**What it does not close.** No optimizer rewrite, so `COUNT(DISTINCT ...)` and
`median()` stay exact and neither aggregate is chosen for the user. No
partial-state merge: the grouped path keys partitions by group key, so a group's
state is never split, and input-partitioned aggregation would need one. No
persisted sketch state and no approximate type in a result. The statistics are
the estimator's standard error and colenc's measured t-digest rank error, not a
universal bound. The 0.5.1 candidate now carries both functions, so R2 must run
its acceptance on the revision that includes them, and the release pair at the
end of `docs/bench-baseline.md` still belongs to the earlier revision.

## 40. 0.5.1 accepted again on the final candidate (2026-10-26): R2

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
  reporting 0.5.1.
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
deployment stay unauthorized. The registry consumer for 0.5.1 and the hosted
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
publication needs authorization and stays outside this section, and the 0.5.1
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
Re-recording the 0.5.1 pair on this toolchain is a decision for the release
owner, not a gate, and this section makes no timing claim. `--check-oracles`
wants the SF0.1 data set, and `check_large_write.py` (34.4 M rows) exercises the
writer's wide-offset path that a compiler bump does not reach; neither was run.

**Two CLI surfaces still behave as the release gates expect.** `moon package
--list` writes its file list to **stderr**, mixed with the `moon check` progress
lines, and ends by packaging `_build/publish/superbigcup325-moonlake-0.5.1.zip`;
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

## 43. Grouped HLL costs, measured (2026-10-26): H0

§39 wrote the approximate-aggregate contract while the dependency still carried
64 KiB of registers per sketch and left two numbers as extrapolation: the
per-group state cost and the crossover against `COUNT(DISTINCT ...)`. colenc
0.1.2 made the registers one byte each, so the roadmap's H0 asked for the
measurement rather than the old crossover divided by four. This section is that
measurement, and the second half of it is what the result triggered.

**The rig.** `harness/bench_hll.py` is new and reproducible. It generates each
fixture with DuckDB into gitignored `target/hll-bench/` (one Parquet file per
shape, a string column `s` whose values are distinct within a group and a key
column `k`), then runs every query in its own child process so peak RSS comes
from `getrusage(RUSAGE_CHILDREN).ru_maxrss` and cannot be polluted by an earlier
query. Multiple copies of the fixture widen duplicates; one variant of each
fixture makes one value in seven NULL. Wall time is the faster of two runs and
peak RSS the higher of the two, which is why a repeated figure is quoted as the
higher one; the answer of every query is checked against the fixture shape.
Binary: the native release build of this tree with no `moon.work` and no sibling
override, resolving registry `colenc@0.1.2` — the record names the commit, the
binary's SHA-256 and the dependency, and the sources that built it are unchanged
since `49a3ed4`.

**The cost of the released state.** One sketch per non-empty group, each a
16,384-byte register array and nothing else, in MB of peak RSS and milliseconds
of wall time:

| fixture (groups × distinct) | rows | `count(s)` | `count(DISTINCT s)` | `approx_count_distinct(s)` |
|---|---|---|---:|---:|---:|
| 1 × 1,000,000 | 1,000,000 | 16.9 MB / 92.6 ms | 115.4 MB / 586.0 ms | 15.0 MB / 122.7 ms |
| 100 × 10,000 | 1,000,000 | 15.6 / 85.9 | 115.3 / 330.8 | 16.7 / 133.0 |
| 1,000 × 1,000 | 1,000,000 | 14.7 / 88.2 | 119.0 / 354.0 | 33.7 / 144.1 |
| 10,000 × 100 | 1,000,000 | 15.2 / 54.3 | 35.2 / 213.0 | 206.8 / 247.0 |
| 5,000 × 10 | 50,000 | 13.3 / 7.6 | 13.4 / 15.9 | 107.5 / 81.9 |
| 20,000 × 10 | 200,000 | 15.3 / 21.6 | 21.3 / 55.2 | 403.6 / 333.2 |
| 20,000 × 1 | 20,000 | 13.4 / 10.1 | 17.2 / 14.5 | 408.0 / 274.5 |
| 1,000 × 100, duplicates ×10 | 1,000,000 | 13.3 / 41.7 | 21.3 / 182.5 | 29.3 / 91.9 |

Three readings. A sketch costs about **20 KB per group** in a real process
(16 KiB of payload plus object and group-map overhead), which the closed form
(`approx` − `count(s)`, over the group count) reports as 20,358 B at 20,000
groups, 20,091 B at 10,000 and 19,923 B at 1,000 — and less when a group's
registers are barely touched, 12,478 B at 1,000 × 1, because untouched pages
never become resident. The **crossover against the exact set** at 1,000 groups is
around 200 distinct values per group: exact 21.3 MB at 100 values against 29.3
for the sketch, both 31.3 MB at 200, and 43.3 against 33.3 at 300, with the exact
side reaching 121.4 MB at 1,000 and 1,089.2 MB at 10,000. And the shapes that
hurt are the small ones: 20,000 groups of one value each hold 408.0 MB of
sketches against 17.2 MB for the exact set, and 5,000 groups of ten hold 107.5 MB
against 13.4 MB. NULLs cost nothing extra — the 1-in-7-NULL variants land within
3 MB of the packed ones (403.6 → 406.5 MB at 20,000 × 10) — because a NULL is
skipped before the sketch sees it. The 0.1.1 table above this one stays as
history: its 65,536-byte payload and ~750-value crossover describe a
representation this tree no longer builds.

Two caveats on the numbers. Peak RSS repeats within about ±2 MB — the one-big-
group row reads 15.0 MB in the dense run and 17.3 MB in the sparse one, and that
shape takes the same code path in both, since its single group promotes before
the first million values are in — so read the per-group figure and the crossover,
not a single row. Wall time is one host under load average 0.3–1.1 and is not
comparable to the 0.5.1 performance pair, which was recorded on the same binary
family and a different rig.

**What it triggered.** Many small groups dominating memory is exactly the
condition the roadmap set for sparse HLL state, so the kernel work was promoted
and landed in colenc's tree (`sketches/hll.mbt`): a sketch now holds either the
dense array or a sorted array of live entries, promoting above
`min(128, m / 8)` live registers, with the hash, the rank update, the estimator,
the merge law and the v1 serialized bytes unchanged (colenc's pinned byte stream
and its checksum are identical). The same matrix through a `moon.work` workspace
and a `.colenc` symlink to that tree, everything else identical, answers every
query the same and moves only the grouped rows (the dense run is the record, the
sparse one a re-run of the same rig in the same session):

| fixture (groups × distinct) | `approx_count_distinct(s)` 0.1.2 | sparse state | delta |
|---|---|---|---|
| 20,000 × 1 | 408.0 MB / 274.5 ms | 15.3 MB / 13.6 ms | −392.7 MB |
| 20,000 × 10 | 403.6 / 333.2 | 17.3 / 34.0 | −386.3 |
| 5,000 × 10 | 107.5 / 81.9 | 13.4 / 11.4 | −94.1 |
| 10,000 × 100 | 206.8 / 247.0 | 17.3 / 116.5 | −189.5 |
| 1,000 × 1 | 25.3 / 13.0 | 13.0 / 2.0 | −12.3 |
| 1,000 × 100 | 29.3 / 25.6 | 15.3 / 22.2 | −14.0 |
| 1,000 × 100, duplicates ×10 | 29.3 / 91.9 | 13.3 / 105.1 | −16.0 |
| 1,000 × 1,000 | 33.7 / 144.1 | 35.3 / 153.0 | +1.6 |
| 1 × 1,000,000 | 15.0 / 122.7 | 17.3 / 127.5 | +2.3 |

Below the promotion limit the sketch stops costing anything measurable — the
closed form is 0 to 145 B per group, and `small-5k`'s grouped
`approx_count_distinct` goes from eight times the decode-only control to within
0.1 MB of it — and those shapes also run 13–95% faster, because a sparse sketch
pages in a few hundred bytes per group instead of 16 KiB. The shapes whose groups
all promote hold the same memory they held before, inside a ±2.5 MB run band, and
pay wall time proportional to how much of the query is the sketch update: 2–27%
across the 1,000-group crossover sweep (200–10,000 distinct values), 14% on the
duplicate shape, 4% at one million values in one group and 6% at 1,000 × 1,000.
The kernel's own rig, which times the update loop alone, pins that cost at +23%
for 1,000 groups that each promote.

**What this does not close.** The sparse state is **not** in the dependency: the
published version is still 0.1.2, the workspace override that measured it is not
in the tree, and consuming it needs a colenc release plus a `moon.mod` bump — a
release decision, not a source change in this repository. That decision was made
on 2026-10-26 — colenc released the state as 0.1.3 — and §44 records this tree
taking it and the same matrix on the shipped artifact. 0.5.1's accepted scope
is therefore untouched by H0, and no timing in this section is comparable to the
0.5.1 performance pair: these are new fixtures, a new rig and a single host
(load average 0.3–1.1), recorded for their memory deltas.

Two records, both committed. `harness/baseline/2026-10-26-h0-hll.json` is the
dense matrix above: a clean tree, the registry dependency, and the binary's
SHA-256, so it is reproducible from this repository as it stands.
`harness/baseline/2026-10-26-h0-hll-sparse.json` is the sparse re-run of the same
rig; its header names what it measured — the workspace override and colenc's
commit — and marks the tree dirty, truthfully: the binary-selection fix in the rig
was still uncommitted when it ran, so `git_commit` is one commit short of the
harness that produced it. Repeating it needs that colenc tree, which is
why it is recorded rather than left in a log; the kernel's own record states what
it changed and what it cost.

## 44. colenc 0.1.3 ships the sparse state (2026-10-26): H0b, C3

§43 ended with the sparse registers implemented in colenc's tree but unreleased,
and the accepted 0.5.1 candidate built against 0.1.2. The release decision went
the other way from leaving it out: colenc cut 0.1.3 with that state, published and
tagged on 2026-10-26. This section is the consumer half — take the published
artifact, rerun the acceptance list rather than inheriting it, and record what the
shipped version costs.

**The upgrade.** `moon.mod` moves from `superbigcup325/colenc@0.1.2` to
`superbigcup325/colenc@0.1.3`, resolved from the registry with no `moon.work` and
no sibling override (the H0 record's dependency block reads `registry`). It is a
one-line manifest change: 0.1.3 changes one thing inside one sketch — the
registers are held densely or as a sorted array of live entries and promote above
`min(128, m / 8)` — and the hash, the rank rule, the estimator, the merge law, the
v1 serialized bytes and the public interface are unchanged, so nothing here ports.
The kernel record for that work is colenc's `docs/SKETCHES.md`, not this one.

**Correctness on the candidate (`344d739`).** The whole §40/§41 list, rerun
rather than inherited:

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
| `check_large_write.py` | 34,400,000 rows, 8,399 row groups, 2,408,368,843-byte widest offset, 1,820 of 16,798 chunks past 2^31, read back by pyarrow, DuckDB and moonlake |
| Playground in headless Chromium (`playground_accept.cjs`) | 16/16 |

The reference-tool gates ran under Python 3.12.14 with `duckdb==2.0.0` and
`pyarrow==26.0.0`, the pinned environment, on the candidate tree before its
commit.

**Release-side checks.** Both ran afterwards, on the tree as `bacea04` — clean, no
workspace override, fresh registry and dependency caches — and nothing but this
record changed after it: `check_release.py --check-consumer` packs the 223-file
archive and passes in a separate consumer on native, wasm-gc and js (version,
CSV, Parquet raw and Snappy, DATE/NULL, drop, and four streamed shapes agreeing
with the collected ones); `check_release.py --publish-dry-run` runs
`moon publish --dry-run` over the same archive and the version claims agree
across `moon.mod`, `moonlake.mbt` and `CHANGELOG.md`. Publication itself is
still unauthorized and therefore not done.

**Remote evidence.** The eight local commits were pushed as `9c677a8` (the range
`a0c7628..9c677a8`), and the hosted runs on that commit passed: CI (all seven
jobs — check, native, wasm-gc, js, playwright, writer, TPC-H), Pages, and a
dispatched nightly (`fuzz`, `large-write`). Earlier sections' local gates are
therefore corroborated on the hosted runners for this dependency, which is what
R3's "record source/archive/toolchain identity" asks for; the tag and the registry
consumer still wait for publication.

**The H0 matrix on the shipped version.** A fresh record,
`harness/baseline/2026-10-26-h0-hll-colenc-0.1.3.json`: the same rig, the same 18
shapes, `344d739`, clean tree, load average 2.5–1.9. MB of peak RSS and
milliseconds of wall time:

| fixture (groups × distinct) | rows | `count(s)` | `count(DISTINCT s)` | `approx_count_distinct(s)` |
|---|---|---|---:|---:|---:|
| 1 × 1,000,000 | 1,000,000 | 15.3 MB / 77.1 ms | 115.6 MB / 504.2 ms | 15.5 MB / 123.0 ms |
| 100 × 10,000 | 1,000,000 | 17.2 / 76.8 | 115.9 / 314.2 | 17.3 / 130.5 |
| 1,000 × 1,000 | 1,000,000 | 15.3 / 74.4 | 120.0 / 288.4 | 35.2 / 180.9 |
| 10,000 × 100 | 1,000,000 | 15.3 / 55.6 | 33.3 / 212.1 | 15.4 / 119.4 |
| 5,000 × 10 | 50,000 | 13.4 / 7.4 | 13.5 / 14.8 | 13.3 / 12.1 |
| 20,000 × 10 | 200,000 | 15.4 / 21.0 | 21.3 / 50.3 | 17.3 / 33.4 |
| 20,000 × 1 | 20,000 | 13.3 / 11.0 | 17.3 / 15.7 | 15.4 / 15.5 |
| 1,000 × 100, duplicates ×10 | 1,000,000 | 13.4 / 40.3 | 21.3 / 183.8 | 13.4 / 109.8 |

The same fixtures, read against §43's 0.1.2 column, where the sketch cost about
**20 KB per group**:

| shape | 0.1.2 `approx_count_distinct(s)` | 0.1.3 | delta |
|---|---|---|---|
| 20,000 × 1 | 408.0 MB / 274.5 ms | 15.4 MB / 15.5 ms | −392.6 MB |
| 20,000 × 10 | 403.6 / 333.2 | 17.3 / 33.4 | −386.3 |
| 10,000 × 100 | 206.8 / 247.0 | 15.4 / 119.4 | −191.4 |
| 5,000 × 10 | 107.5 / 81.9 | 13.3 / 12.1 | −94.2 |
| 1,000 × 100, duplicates ×10 | 29.3 / 91.9 | 13.4 / 109.8 | −15.9 |
| 1,000 × 1,000 | 33.7 / 144.1 | 35.2 / 180.9 | +1.5 |
| 100 × 10,000 | 16.7 / 133.0 | 17.3 / 130.5 | +0.6 |
| 1 × 1,000,000 | 15.0 / 122.7 | 15.5 / 123.0 | +0.5 |

Two readings and one caveat. The memory columns repeat §43's sparse re-run within
about 2 MB, which is what makes the numbers trustworthy: an untracked workspace
override and a published artifact measured the same thing. The crossover against
the exact set at 1,000 groups is unchanged at about **200 distinct values per
group** — exact 18.8 MB against 15.3 at 100, both 31.3 at 200, 43.3 against 33.2
at 300, and the exact side reaching 121.3 MB at 1,000 and 1,087.9 MB at 10,000 —
because neither representation changes what a group costs once it promotes. The
caveat is wall time: this record ran at load average 2.5 and §43's dense run at
0.3–1.1, so the two columns' milliseconds are not a controlled pair. The memory
deltas are, which is what the state change is about; the timing cost of the
promotion shapes is colenc's own measured claim (+23% on 1,000 groups that each
promote), not something this table isolates.

**The release pair.** R3 needs to know that the dependency bump does not move the
release cases, so the eleven timed cases ran against a control that differs only
in the pin: `harness/baseline/2026-10-26-colenc-0.1.2-control.json` is a detached
worktree at the same commit with `moon.mod` back on 0.1.2, building its own CLI and
its own spill driver, recorded at 23:28; the candidate record is
`harness/baseline/2026-10-26-colenc-0.1.3.json` from 23:25. One round each, load
average 3.8 against 3.2:

| case | 0.1.2 control | 0.1.3 | delta |
|---|---|---|---|
| `scan/count_csv` | 164.6 ms | 159.6 ms | −3.0% |
| `scan/filtered_count_csv` | 183.8 | 177.7 | −3.3 |
| `join/two_table_count` | 240.9 | 229.9 | −4.6 |
| `join/q3` | 269.6 | 262.3 | −2.7 |
| `gather/wide_projection` | 445.9 | 431.1 | −3.3 |
| `gather/self_join_fanout` | 384.9 | 368.3 | −4.3 |
| `spill/order_by_wide` | 505.1 | 495.8 | −1.8 |
| `spill/format_write` / `format_read` | 1206.4 / 437.1 | 1244.7 / 435.2 | +3.2% / −0.4% |
| `scan/parquet_count` / `parquet_sum` | 3.8 / 11.4 | 4.7 / 11.2 | +23.7% / −1.8% |

The honest reading is the tool's own verdict, which is `0 case(s) moved further
than their own run-to-run spread`. The small negative deltas are the control
running under a higher load average, not an improvement; the two Parquet cases are
4 ms and 11 ms with spreads of 59% and 57%, the pair §41 also left unresolved; and
peak RSS is flat within 4 MB (the widest is `join/q3` at 49.2 against 45.3 MB).
The record and its framing are in
[bench-baseline](bench-baseline.md#colenc-013-hands-the-sparse-state-to-the-release-candidate-2026-10-26).

**What this does not close.** moonlake 0.5.1 is still unpublished: tag, artifact,
publication and deployment need release authorization, and this section only makes
the tree that will be released depend on the released colenc. The sparse state is
invisible through SQL except as cost — no syntax, no result change, no interface
change — so the answer set is the one §40 and §41 accepted, with the gates above
rerun rather than assumed.

## 45. A budgeted GROUP BY reads the scan as it arrives (2026-10-27): E5a, E5b, E5c

Until now a `GROUP BY` under `--memory` collected its whole input before the grace aggregation could size its partitions from it, so an 8,000,000-row input held every row however small the budget. The ROADMAP records the decision ('Budgeted GROUP BY input'); this section records what the implementation costs and what it leaves open.

**The change.** `streaming_agg_source` no longer excludes a budgeted GROUP BY. `aggregate_pulled` (`engine/extagg.mbt`) buffers the scan's batches while their estimated bytes, summed in 64 bits, stay within the budget; a pull that ends there is aggregated exactly as before and needs no spill store. At the first overflow it requires the store (the same error as before), fixes the partition count from the budget alone, `clamp(budget / 4 / 32 KiB, 2, 16)`, and routes the buffer and the rest of the pull into hash partitions that share one `budget / 4` pool; when the pool is full the largest partition buffer is written as a run. Each partition is then folded run by run through `aggregate_seq`, the same fold and the same spill format as before. Cleanup is registered before the first run is written, and the collected `grace_agg` got the same ordering, which closes a leak when a failure came during partitioning or a flush. `--analyze` gains three lines when it spills: `spill partitions`, `buffered bytes peak (estimated)` (the most input held at once, which is the budget plus the batch that crossed it) and `largest partition spilled (estimated)`. Both byte lines use the engine's size estimate, not file sizes, so they sit beside `spill bytes written` and do not equal it. A query that fits its budget prints none of them.

**Method.** `harness/bench_agg_pull.py`, native release binaries: candidate is `f4e9348` plus this change, control is `f4e9348` built in its own worktree. Each query runs in its own process, started from a small helper, because a parent that holds a DuckDB table lifts every child's `ru_maxrss` (the first version of the script printed the same growing RSS for both binaries). Candidate and control are interleaved, three rounds per case, median wall time and maximum RSS. The numbers below come from the final partition rule; an earlier run with a 256 KiB floor and a 64-partition cap returned the same answers but different partition counts, and is quoted only where it explains the rule. Every run started after the 1-minute load average stayed under 0.9. Answers are compared with the control's and, except for `string_agg` (no defined order), with DuckDB 2.0.0 through `compare.py`. Worst round-to-round spread was 6% in the scaling run and 13% in the shape run, on a 32M cell that does not spill.

**Rows grow, groups stay at 100** (peak RSS in MB, control -> candidate):

| Rows | 4M budget | 16M budget |
|---|---|---|
| 500,000 | 61 -> 61 (fits) | 61 -> 61 (fits) |
| 1,000,000 | 64 -> 63 | 63 -> 63 (fits) |
| 2,000,000 | 75 -> 63 | 75 -> 75 (fits) |
| 4,000,000 | 99 -> 63 | 105 -> 77 |
| 8,000,000 | 195 -> 63 | 191 -> 77 |

The candidate's RSS stays flat once the input exceeds the budget; the control grows with the rows. At 8,000,000 rows the candidate writes 16.8 MB in 16 partitions and 527 files at 4M, and 16.8 MB in 16 partitions and 141 files at 16M. Wall time is level: 1.78 s against 2.00 s at 4M and 1.77 s against 1.74 s at 16M (at 4,000,000 rows 0.91 against 0.89 and 0.88 against 0.86). 'Fits' means the candidate buffered everything, wrote nothing and took the path it took before.

**Other shapes** (4,000,000 rows, RSS in MB and wall time in s, control -> candidate; the answers equal the control's and DuckDB's in every row):

| Shape | 4M budget | 16M budget |
|---|---|---|
| 1,000 groups | 105 -> 67, 1.02 -> 1.03 | 111 -> 77, 0.98 -> 1.01 |
| 100,000 groups | 107 -> 45, 1.24 -> 1.10 | 107 -> 67, 1.12 -> 1.11 |
| 1,000,000 groups | 146 -> 99, 1.70 -> 1.59 | 168 -> 103, 1.65 -> 1.59 |
| median + count(DISTINCT), 100 groups | 99 -> 63, 1.18 -> 1.20 | 105 -> 77, 1.16 -> 1.17 |
| skew, 90% of rows on one key, median | 113 -> 113, 0.86 -> 0.84 | 129 -> 93, 0.83 -> 0.84 |

At a 32M budget every shape except `string_agg` fits, so both paths behave alike (1,000,000 groups: 507 and 508 MB). Group state is not bounded by this change: at that budget, where the input fits, both paths hold the same 507 MB, which is the 1,000,000 groups themselves.

**`string_agg`** (100 groups, 4,000,000 rows, answers equal the control's): 18.49 -> 21.90 s at 4M, 24.13 -> 21.86 s at 16M and 25.55 -> 21.92 s at 32M, with RSS 197 -> 67, 199 -> 99 and 205 -> 155 MB. The query takes tens of seconds on either path, and its wall time follows the partition count rather than the path: the old path picks 39, 10 and 5 partitions at those budgets, and the same query run at 2, 4, 5, 10, 16, 32, 39 and 64 partitions takes 26.2, 25.8, 25.6, 24.1, 21.9, 18.8, 18.6 and 18.0 s, every run returning the same answer. The final rule gives 16 at all three budgets, so the candidate is 18% slower at 4M, where the old path chose 39 partitions, and faster at 16M and 32M, where it chose 10 and 5. The mechanism was not isolated; a guess is that fewer partitions keep more groups' growing strings live at once.

**The partition rule.** The count has to come from the budget, because the input size is unknown at the first overflow. Three settings were measured. First the floor alone, on 8,000,000 rows and 100 groups, medians of four interleaved rounds:

| Budget | Control | 64 KiB floor | 256 KiB floor | 1 MiB floor |
|---|---|---|---|---|
| 4M | 2.00 s | 1.77 s (16 partitions) | 1.83 s (4) | 1.73 s (2) |
| 16M | 1.75 s | 2.13 s (64) | 1.76 s (16) | 1.88 s (4) |
| 32M | 1.74 s | 2.08 s (64) | 1.85 s (32) | 1.77 s (8) |

More partitions cost the cheap aggregates, because every batch is split that many ways (not isolated). Second, js at 100,000 groups under a 2M budget showed the other end: 2 partitions cost 1.54 s against the control's 1.33 s at 16, and lowering the floor to reach 16 partitions removed the difference (32 KiB 1.34, 64 KiB 1.44, 128 KiB 1.48, 256 KiB 1.54, five interleaved rounds, one answer hash across all five binaries). Fewer partitions cost the aggregates whose state grows per row. So the two ends needed bounding at once: a 32 KiB floor with a cap of 16. Third, that rule was measured on all three targets against the pre-change control, and the tables above and the paragraph below are those runs. Cap 16 is reached at a 2M budget and stays fixed above it; the floor only decides counts below the cap.

The cap removes the 64-partition penalty the first table shows: under it, 16M and 32M no longer reach 64, and no native shape at 4M or 16M is more than 3% slower than the control, while the 100,000- and 1,000,000-group shapes are 11% and 6% faster at 4M. It also removes the js slowdown (1.35 s against 1.33 s) and cuts `string_agg`'s worst case from 40% to 18%. What it costs is files: the 4M budget on 4,000,000 rows writes 269 files for 100 groups where the 256 KiB floor wrote 78, for the same total bytes. That cost does not show in wall time — at 8,000,000 rows the 4M budget writes 527 files in 1.78 s and the 16M budget 141 files in 1.77 s for the same 16.8 MB, and at 4,000,000 rows 269 files run 0.91 s against 78 at 0.88 s — but every count here is under a thousand, and a query that writes tens of thousands of run files was not exercised.

**The floor belongs to the scan.** At a 4M budget the candidate's RSS is 63 MB on one 4,000,000-row CSV and 35 MB on another with the same rows plus a 20-character column. A global `count(*)`, a path this change does not touch, shows 49, 67, 27 and 67 MB on the four files tried. The figures above are therefore the buffer plus whatever the CSV reader holds, which depends on the file; what they support is that retained input stops growing with the rows, not that 64 MB is the cost of a 4M budget.

**Tests.** `engine/agg_pull_wbtest.mbt` runs a lazy source under a 64-byte budget: a query with NULL keys, median and count(DISTINCT) equals the unbudgeted run, with the partition count asserted and no run left in the store; an overflow without a store is a clean error; a store that fails its second write leaves no run behind. Three more run the same lazy source under the 64-byte budget: an empty input answers no rows and writes nothing, HAVING keeps the one group whose rows arrive in all four batches, and a two-column key with duplicates across batches equals the unbudgeted answer. Check 11 of `spill_accept.sh` runs a 300,000-row GROUP BY whose last row cannot be parsed, after showing that the same data without that row spills, and requires a non-zero exit and no `--spill-dir` left behind; that directory is removed by the CLI scope itself, so the check covers the lifecycle and not the engine removing its own runs, which only the failing-store unit test covers. A seventh checks that the byte counters appear, that the peak exceeds the budget and that no partition wrote more than the whole input. The suites pass on wasm-gc (355), native (368) and js (355), and `spill_accept.sh` and the 33 goldens pass on the native release binary. The existing grace-aggregation tests in `e2e_test.mbt` build in-memory tables, which are not lazy, so they still exercise the collected path and are not evidence for this one.

**What this does not close.** Group state and the grouped result are still unbounded, so `--memory` is not an RSS cap. Only the 100-group shape was scaled by rows; the others ran at one input size. A 2,000,000-row, 100-group query at a 4M budget through the wasm-gc and js CLIs spills into 16 partitions and prints the same counters on both (76 files), so the path runs there. That query is narrower than the native one, so its file and byte counts are not comparable with the native table. RSS on both targets is in the paragraph below. On native the same query at 4M spills 16 partitions and 140 files with a peak of 4,197,376 estimated bytes against the 4,194,304-byte budget, and at 16M and 64M it fits and prints no spill lines. Growing the partition count mid-stream, the alternative the ROADMAP kept in reserve, was not needed for the shapes measured.

**wasm-gc and js.** `harness/bench_agg_pull.py` through wrapper scripts (`moonrun` on the wasm-gc build, `node` on the js build), 1,000,000 rows, 2M and 8M budgets, three interleaved rounds, control `f4e9348`, answers equal to the control and, except for `string_agg`, to DuckDB in every case. Both runs use the final partition rule. wasm-gc, wall seconds and peak RSS in MB, candidate / control, at 2M then 8M: 100 groups 6.42 / 6.32 (175 / 174 MB) and 5.38 / 5.38; 100,000 groups 7.94 / 7.85 and 7.21 / 7.23; median plus count(DISTINCT) 6.45 / 6.39 and 5.44 / 5.43; `string_agg` 11.70 / 10.89 and 12.07 / 12.88. The 8M budget fits the input in every shape except `string_agg`, so those cells are the unchanged path. js: 100 groups 1.39 / 1.38 and 0.63 / 0.63; 100,000 groups 1.35 / 1.33 and 0.94 / 0.91; median plus count(DISTINCT) 1.42 / 1.40 and 0.66 / 0.65; `string_agg` 2.04 / 2.09 and 2.19 / 2.08. Worst round-to-round spread was 10% on wasm-gc and 9% on js.

What these runs support is correctness and the counters on both targets and no wall-time change outside `string_agg`, where wasm-gc is 7% slower at 2M and 6% faster at 8M, both inside that run's spread. The earlier js slowdown at 100,000 groups under a 2M budget (1.53 s against 1.33 s) is what the floor experiment in the paragraph above explains; the final rule runs that cell at 1.35 s.

**Is retained input bounded on those targets?** Comparing the candidate with the pre-change control does not answer this, because both binaries read the same scan and its own peak can sit above what the input would retain. The comparison that does answer it is inside one target, with one binary, at one row count: `harness/bench_retained.py` runs `count(*)` (the scan, retaining nothing), the grouped query under a budget smaller than the input (4M, so it spills) and the same query under 512M, which is large enough for the engine to keep every row the way the collected path did. What it adds over the scan is the retained input, and it is visible once the scan is flat.

The first attempt used the CSV reader and only worked on native. Peak RSS in MB, three repeats, the maximum of each:

| Rows | native scan | native spill | native retain | js scan | js spill | js retain | wasm-gc scan | wasm-gc spill | wasm-gc retain |
|---|---|---|---|---|---|---|---|---|---|
| 1,000,000 | 67.6 | 63.4 | 63.4 | 316.4 | 360.1 | 432.2 | 176.3 | 178.8 | 166.2 |
| 2,000,000 | 67.4 | 63.3 | 75.4 | 451.7 | 549.8 | 481.6 | 217.6 | 221.4 | 224.9 |
| 4,000,000 | 67.5 | 63.4 | 99.3 | 570.3 | 582.6 | 700.4 | 311.6 | 312.4 | 310.5 |
| 8,000,000 | 67.5 | 63.3 | 163.0 | 536.1 | 606.5 | 1,043.4 | 487.3 | 486.7 | 486.5 |
| 16,000,000 | 67.5 | 63.4 | 258.7 | 611.2 | 682.5 | 1,923.0 | - | - | - |

On native the scan is flat at about 67.5 MB at every row count and the spilling query is flat at 63.3, while the retaining query climbs to 258.7 MB, which is 12.5 MB for every million rows added. On js the scan itself grows from 316 to 611 MB and on wasm-gc from 176 to 487, and because the scan's growth per million rows (about 60 MB) is larger than what those rows retain (12.5 MB), the retaining runs there land inside the footprint the scan already grew: on wasm-gc all three runs agree within 1.1 MB from 2,000,000 rows up.

That growth is the CSV reader's, not a runtime baseline as an earlier draft of this section assumed. The Parquet reader decodes fixed-size column batches and stays flat on the same rows, which is where the comparison separates on all three targets. Parquet input, peak RSS in MB, three repeats:

| Rows | native scan | native spill | native retain | js scan | js spill | js retain | wasm-gc scan | wasm-gc spill | wasm-gc retain |
|---|---|---|---|---|---|---|---|---|---|
| 1,000,000 | 6.4 | 23.4 | 37.4 | 83.1 | 271.2 | 243.0 | 31.5 | 107.7 | 91.4 |
| 2,000,000 | 6.4 | 23.6 | 58.8 | 83.3 | 256.6 | 293.9 | 34.3 | 104.5 | 112.9 |
| 4,000,000 | 6.4 | 20.5 | 101.6 | 82.8 | 267.9 | 388.8 | 39.4 | 111.1 | 166.8 |
| 8,000,000 | 6.4 | 22.2 | 194.8 | 83.8 | 269.1 | 667.6 | 49.6 | 114.8 | 253.4 |

Over the scan, the spilling query adds 14 to 17 MB on native, 173 to 188 on js and 65 to 76 on wasm-gc at every row count, while the retaining query grows to 188, 584 and 204 MB. The spilling path's excess over the scan therefore stays flat across an eightfold increase in rows on all three targets: 14.1 to 17.2 MB on native, 65.2 to 76.2 on wasm-gc and 173.3 to 188.1 on js, with no trend in any of them, and the engine's own `buffered bytes peak (estimated)` reads 4,195,840 bytes for a Parquet source (4,194,304 for a CSV one) at every row count on every target: the budget plus the batch that crossed it. The measurement is what shows that counter tracks what the process holds; the counter is what makes the bound precise.

The CSV figures still stand for what they were run for: the shape tables above, and the candidate-against-control comparisons, all read CSV on both sides.

## 46. 0.5.1 release preparation on the E5 candidate (2026-10-27): R3

Everything below ran on `8297296f2742`, whose tracked tree was clean, with moon
0.1.20261023 (moonc v0.10.17+d971670cd), Python 3.12.14, DuckDB 2.0.0 and
PyArrow 26.0.0. The E5 work landed after the 0.5.1 scope was written, so R3 is
the same list §40 ran, re-run on a candidate that carries it rather than
inherited. The tag, the publication and the page deployment are separate
release-authorization steps and none of them ran here; `moon publish --dry-run`
was skipped for the same reason (it needs credentials).

**Correctness.**

| Gate | Result |
|---|---|
| `moon info`, `moon fmt --check`, `moon check --deny-warn` | clean, no interface change |
| `moon test` (wasm-gc / native / js) | 355 / 368 / 355 passed, ten more than §40's 348 / 361 / 348 |
| 33 goldens, `check_all.sh` on native, on wasm-gc and on js | pass on all three |
| `check_correlation.py` | ok, including the cases both engines refuse |
| `check_windows.py` | ok, including the cases both engines refuse |
| `fuzz_pushdown.py 40 20261026` | 40 queries, 0 failures, 0 engine rejections |
| `check_colenc_fixtures.py` | 8 embedded + 9 regenerable cases verified at page level |
| `check_cli.sh` | pass, including partial output when a scan fails mid-result |
| `spill_accept.sh` | pass: ownership, reclaim, shared directory, ANALYZE counters |
| `check_writer_interop.py` | pass: raw and Snappy, DATE/NULL, EXPLAIN rows, DuckDB-written file read back |
| `check_parquet_corpus.py` | 17 decoded by value / 51 refused by design / 0 failing |
| `bench_release.py --check-oracles` | eleven timed cases agree with DuckDB |

**The heavy gates.**

- `check_large_write.py`: 2,465,688,897 bytes of CSV in, a 2,410,475,894-byte
  Parquet out, 34,400,000 rows in 8,399 row groups, 1,820 of 16,798 column
  chunks past 2^31, and pyarrow, DuckDB and this reader all return the same
  answer from it — byte for byte the same file §40 recorded.
- Playground: `moon build --target wasm-gc playground`, then the import audit —
  `playground.wasm` imports only `wasm:js-string` and `_` (793 imports, none
  else) — and `harness/playground_accept.cjs` driving real Chromium: 16/16,
  with the page reporting 0.5.1. The pages workflow ships that same build on
  every push, and the deployed page at
  <https://superbigcup325.github.io/moonlake/> passes the same 16/16.
- `check_release.py --tag v0.5.1 --check-consumer`: the four version claims
  agree, the archive holds 225 files with no forbidden path, the tree is clean,
  and the unpacked archive passes on native, wasm-gc and js with a fresh
  registry and dependency cache, including the four streamed shapes against
  their collected answers. Archive SHA-256
  `9521e20e11b41bc8ac51ed09d6b05e4e774f4f8fc82a951a6ee1b119cdbe4b21`, built
  from `v0.5.0-78-g8297296`.

**What this records, and what it does not.** The list above is the acceptance
for 0.5.1's source; it says nothing about a published artifact, because there is
none yet. The release pair for the performance record is §45's E5 tables plus
the 0.1.2-versus-0.1.1 pair in §41, both against controls measured on the same
host in interleaved rounds; no new timing was taken here, and the acceptance run
touched no benchmark. The 225-file archive is twelve files larger than §40's 213:
nine recorded baselines under `harness/baseline/` and the three benchmark
scripts (`bench_agg_pull.py`, `bench_hll.py`, `bench_retained.py`) are tracked
and ship, which is the same policy the earlier sections follow.

## 47. 0.5.1 is published (2026-10-27): R3

The scope that §36, §40 and §46 accepted as an unreleased candidate was
published by the repository owner under the number 0.5.1. The number is the only
change: until 2026-10-27 the scope was planned as 0.6.0, and the renumbering
commit `f8e1204` touches `moon.mod`, the `VERSION` constant and its test, this
document, the roadmap, the changelog, the README pointer and the recorded
baselines, plus three baseline filenames that carried the old number — no
behaviour. It is the release commit, so the tree it publishes is the tree §46
accepted.

| Step | Result |
|---|---|
| Version claims | `moon.mod`, `VERSION`, the `VERSION` assertions and the changelog heading agree on 0.5.1 |
| `check_release.py --tag v0.5.1 --check-consumer` | 225 archive files, no forbidden path, clean tree at `f8e1204`, consumer passes on native, wasm-gc and js from a fresh registry and dependency cache |
| `moon publish --dry-run` | `202 Accepted` for `superbigcup325/moonlake` 0.5.1 |
| `moon publish` | `Server status: 200 OK` |
| Registry | `superbigcup325/moonlake@0.5.1`, published 2026-10-27T13:29:24Z; `moon view` reports it |
| Tag and release | annotated tag `v0.5.1` on `f8e1204`, pushed; <https://github.com/superbigcup325/moonlake/releases/tag/v0.5.1> |
| `check_consumer.py --registry-version 0.5.1` | passes on native, wasm-gc and js from a fresh cache |
| Deployed page | the pages job shipped `f8e1204`; <https://superbigcup325.github.io/moonlake/> reports 0.5.1 and passes the playground acceptance 16/16 |

The archive SHA-256 recorded by the release check is
`de0369219c19e3b4a661494f7a86738c2fa410ccec813bc5fd5fbee183158d00`, built from
`v0.5.0-82-gf8e1204`. The publish ran with a writable `MOON_HOME` under a
dot-directory, because the default one is read-only in this sandbox; the
credentials were not copied into the tree.

**What this section does not say.** No performance measurement was taken for
the release: the numbers in §45 (pulled `GROUP BY`), §41 (dependency cost) and
the record at the end of `docs/bench-baseline.md` stand on the controls each of
them was measured against, and nothing in this release changed the code they
measure beyond a version string. `--memory` remains a budget for the operators
that honour it, not a cap on process RSS.

## 48. A join feeding an aggregate still collects it (2026-10-27): E6a

The join streams its probe side and the aggregate folds a scan, but neither
accepts the other, so a two-table keyed join with a `GROUP BY` above it is
answered by collecting the joined rows first (`drain_join`) and aggregating that
collection. This section measures what that costs before anything is composed.
It is a baseline, not a change: candidate and control are the same source
(0.5.1 plus documentation and harness commits), so every case also measures how
repeatable the harness is. The record is
[`harness/baseline/2026-10-27-e6a-join-agg.json`](../harness/baseline/2026-10-27-e6a-join-agg.json),
written by [`harness/bench_join_agg.py`](../harness/bench_join_agg.py) at
`57004ea`.

**Method.** Two tables, `probe(id, k, v)` with `k = i % 100` and
`v = (13 * i) % 1000`, and `build(k, w)` with `fanout` rows per key, so one probe
row produces exactly `fanout` joined rows and the grouped answer is always 100
rows. Five queries run over the same fixture set: `count(*)` (the scan), the
`GROUP BY` over `probe` alone (the aggregate state), the joined rows collected
(the intermediate result), the composed `GROUP BY` over an INNER join and the
same over a LEFT join. Probe rows and build-side fanout are swept separately,
because both multiply the joined rows while the build size, the group count and
the final result stay fixed. Three interleaved rounds per case, candidate and
control alternating order; answers are recomputed here from the fixture's key
and value functions, and every grouped case is also answered by DuckDB.

The host was not quiet by §45's standard: the quiet gate was set to 1.5 and
passed at 1.41, and the load reached 3.10 during the run, so wall times spread
up to 32% on the short cases and are quoted as direction only. Peak RSS is the
evidence. The same-code candidate/control pair bounds the noise: the RSS
difference is 0.1 MB at the median and 19 MB in the worst case, which is one of
the two spilling 4,000,000-row points.

**Peak RSS in MB** (`candidate`; the control agrees within the noise above):

| joined rows | from | no budget | 4M | 16M |
|---|---|---|---|---|
| 1,000,000 | 1,000,000 rows x fanout 1 | 51 | 54 | 51 |
| 2,000,000 | 2,000,000 rows x fanout 1 | 97 | 118 | 99 |
| 4,000,000 | 4,000,000 rows x fanout 1 | 189 | 204 | 192 |
| 2,000,000 | 1,000,000 rows x fanout 2 | 85 | 92 | 99 |
| 4,000,000 | 1,000,000 rows x fanout 4 | 154 | 164 | 191 |

**The controls say where the growth is.** At no budget the scan alone is 35 MB at
every point (36 MB with a budget set), the aggregate alone is 35 MB (45 MB when
it spills at 4M, 57 and 67 MB at 16M where it buffers more input), and the
collected join on its own is 39 MB from 1,000,000 to 4,000,000 joined rows —
because that query prints its rows rather than holding them. None of the three
grows with the joined rows, so the 51 → 97 → 189 MB is the handoff: the joined
rows are materialized as batches and the aggregate then works through the array.

**Per joined row is not a constant.** The delta over the scan is 16.7, 32.5 and
40.4 B at 1, 2 and 4 million joined rows, and the two ways of reaching 4,000,000
joined rows disagree — 189 MB from 4,000,000 probe rows against 154 MB from
1,000,000 probe rows and a four-row build. That difference was not isolated; one
candidate is how the join slices its output into batches, which differs between
the two sweeps. What the table supports is that the cost follows the joined rows,
not the probe rows, the build or the group count.

**The budget does not bound this path.** At 4,000,000 joined rows the 4M budget
peaks higher than no budget at all (204 against 189 MB) and takes 1.35 s against
0.36 s, spilling 46 partitions and 115 files for 11.1 MB written; the 16M budget
peaks at 192 MB and takes 1.36 s for 12 partitions and 28 files. The aggregate
partitions the input it is handed, and it is handed a complete collection, so
what a budget adds here is a buffer plus partitioning work on top of the
collection it cannot avoid.

**Answers.** 75 of 75 case runs return the exact answer, all 75 agree with the
control's (same source, so this is the harness checking itself), and the 45
grouped runs also agree with DuckDB. The script's own oracle is covered by
`harness/test_bench_join_agg.py`, whose fourteen cases include a lost group, an
extra group, a wrong count, a duplicated key and a truncated join.

**What this does not say.** It does not name the mechanism behind the 189 versus
154 MB difference at equal joined rows, nor measure a growing build side or a
growing group state — both were fixed by design here, and their cost is E6c's
question. It measures the native CLI only: wasm-gc and js are not in this record,
and no Parquet-input control was needed because the scan is flat at 35 MB from
1,000,000 to 4,000,000 probe rows, so the CSV reader is not hiding retained input
on this target. Longer join chains, RIGHT/SEMI/ANTI, a cross join, and ORDER BY or
DISTINCT above the join keep the eager shape they had and were not measured.

**Decision.** The intermediate collection dominates: peak RSS over the scan grows
from +16 MB at 1,000,000 joined rows to +154 MB at 4,000,000, while the scan, the
group state and the streaming join each stay flat. The roadmap's rule was to
start E6b only if E6a demonstrated that cost, so E6b is the next task. No engine
behaviour changed for this section and no version is reserved by it.

## 49. A join feeding an aggregate folds it (2026-10-28): E6b

§48 measured the handoff this section removes: a two-table keyed join with a
`GROUP BY` above it was answered by collecting the joined rows (`drain_join`) and
aggregating the array, so peak RSS over the scan followed the joined rows
(+16 MB at 1,000,000, +154 MB at 4,000,000). The
[composition contract](ROADMAP.md#the-e6b-composition-contract) fixed the shape,
the buffer accounting, the counters and the fallbacks before any code changed;
this section records what composing it did. The record is
[`harness/baseline/2026-10-28-e6b-join-agg.json`](../harness/baseline/2026-10-28-e6b-join-agg.json),
written by [`harness/bench_join_agg.py`](../harness/bench_join_agg.py) at
`bc02ff1` on a clean tree (`dirty: false`).

**Method.** The same fixtures, cases, rounds, budgets and sweep as §48, so every
row below has a row in §48's table: `probe(id, k, v)` with `k = i % 100` and
`v = (13 * i) % 1000`, `build(k, w)` with `fanout` rows per key, 1, 2 and 4
million probe rows at fanout 1 and 1 million probe rows at fanout 2 and 4, three
interleaved rounds per case, three budgets, five queries. Candidate is this tree
at `bc02ff1` (`52ede096…`); control is the released 0.5.1 source in a detached
worktree at `v0.5.1` (`4d73a05f…`), so the pair differs by the composition and
nothing else. The host was quiet when the run started (load 0.75 against a 1.5
gate) but reached 2.53 during it, and the worst round-to-round spread was 38% on
the short cases: wall times are direction only, peak RSS is the evidence.

**Peak RSS in MB, candidate against the collected control** in the same cell:

| joined rows | from | no budget | 4M | 16M |
|---|---|---|---|---|
| 1,000,000 | 1,000,000 rows x fanout 1 | 39 / 51 | 46 / 54 | 49 / 51 |
| 2,000,000 | 2,000,000 rows x fanout 1 | 39 / 97 | 45 / 117 | 61 / 100 |
| 4,000,000 | 4,000,000 rows x fanout 1 | 39 / 191 | 45 / 226 | 61 / 193 |
| 2,000,000 | 1,000,000 rows x fanout 2 | 39 / 85 | 41 / 91 | 67 / 99 |
| 4,000,000 | 1,000,000 rows x fanout 4 | 39 / 153 | 41 / 166 | 63 / 193 |

**The delta over the scan stops following the joined rows.** At no budget the
composed query peaks at 38.9, 38.9, 39.0, 38.9 and 39.2 MB across the five
points, 3.6 to 3.8 MB over the 35.3-35.6 MB scan, which is the build side plus
one batch in flight, against 16 to 156 MB for the control. The two routes to
4,000,000 joined rows now agree to 0.2 MB where the control disagreed by 38 MB,
because the composed cost does not depend on which side produced the rows.
Under a budget the peak follows the budget and the fold's buffer, not the rows:
41.4-45.5 MB at 4M and 49.4-67.3 MB at 16M, and it sits one batch and the
resident build side above the aggregate-alone control at the same setting (45.4
MB against 49.4 MB at 1,000,000 rows under 16M), where the control's peak is
the joined rows plus a batch. The control is still raised by a budget, peaking
at 225.7 MB with 4M against 191.3 MB without one at 4,000,000 rows, while the
composed path drops from 191.3 to 45.4 MB in the same comparison.

**The five row counters keep their values.** On the 4,000,000-row, fanout-1
fixture the candidate's `--analyze` reads `scan probe: 4000000`,
`scan build: 100`, `joins: 4000000`, `aggregate: 100`, `result: 100`, and the
control's five lines are identical when run on the same fixture in the same
session. `engine/join_agg_wbtest.mbt` pins that sequence for the composed path
and pins it against the shape's own definition of each counter.

**The spill lines now describe one plan.** Under the 4M budget at 4,000,000 rows
the control reports two phases, 31 partitions for the join's grace output and 46
for the aggregate, 115 files and 11.1 MB written. The composed path never runs
`join_or_spill` for this query, so it reports one phase: 16 partitions, 394 files
and 10.6 MB written, plus the fold's `buffered bytes peak (estimated)` and
`largest partition spilled (estimated)` lines that the aggregate-owned phases
already used. More files for slightly fewer bytes is the trade §45 recorded for
the aggregate's own partition rule.

**A refusal that stops being one.** A 5,000-row side whose single key outgrows
every grace partition used to fail under an 8 KB budget: the join wrote its
runs and then refused. With the shape composed the fold needs no joined row
set, so the same query answers (50,000 for the `count(*)`), writes nothing, and
leaves no directory. Two gates pinned the old refusal and now pin it on a RIGHT
join, which the contract excludes: `engine/e2e_test.mbt` and
`harness/spill_accept.sh`. A new e2e test pins the answering case instead, so
the error path keeps its coverage and the improvement is claimed by a test
rather than by a comment.

**Answers.** All 75 case runs return their expected answer, every one agrees with
the control's, and the 45 grouped runs also agree with DuckDB. The whitebox tests
additionally cover what the sweep does not: NULL keys and values, duplicate build
keys, an empty probe side, an empty build side, FULL's unmatched build rows, a
group that spans batches, grouping by a build-side column (where an unmatched
LEFT row lands in the NULL group), a global aggregate, `HAVING`, `count(distinct)`
inside the fold, a budgeted run that spills and leaves no run file, and a `LIMIT`
that counts against the grouped rows. Each excluded shape (a three-table chain, a
RIGHT join, `ORDER BY`, `DISTINCT`, a derived table, a single table) is asserted
not to compose. The corpus gates pass unchanged: the 33 golden comparisons of
`harness/check_all.sh`, plus `harness/check_cli.sh` and `harness/spill_accept.sh`
end to end.

**Coverage on real queries.** With the shape predicate instrumented at sf01,
`q14` and `q19` take the composed path; the other TPC-H queries that join and
group either carry an `ORDER BY` above the aggregate (`q3`, `q10`, `q12`), join a
third table (`q5`, `q11`, `q18`), or decorrelate into SEMI/ANTI joins (`q16`,
`q20`), all excluded by the contract. At sf01 `q19` peaks at 41.3 MB against
109.2 MB for the control, and `q3` is unchanged at 43.3 MB because it keeps the
eager path. The comparison is directional: sf01 is small, so the numbers say the
path is taken and the peak moves, not what a 1 GB dataset would show.

**Wall time.** At no budget the two paths are indistinguishable (0.31 s against
0.34 s at 4,000,000 joined rows; 0.17 s against 0.19 s at fanout 4). Under a
budget the composed path is faster where the fold partitions early (1.08 s
against 1.36 s at 4,000,000 rows and 4M) and slower where it buffers up to the
budget first (0.91 s against 0.69 s at fanout 4 and 16M, 0.50 s against 0.39 s at
2,000,000 rows and 16M), while using 63 MB instead of 193 MB at the first of
those and 61 MB instead of 99 MB at the second. That is the budget's trade: hold
input up to the budget, or hold the joined rows. The host's load does not support
a finer claim than the direction.

**What this does not say.** It does not bound the build side or the group state
(E6c), does not extend to a chain, RIGHT, SEMI/ANTI, `ORDER BY`, `DISTINCT`, a
window or a keyless cross join, and measures the native CLI only: wasm-gc and js
are not in this record. It reports CSV input only, as §48 did, because the scan is
flat there and the reader is not hiding retained input on this target. The
deployed page, the packaged consumer and the three-target answer parity for the
new path are E6c's, and §46-48 remain the evidence for the released tree.

## 50. An ordered aggregate sorts its grouped result after the fold (2026-10-28): E6b, widened

The E6b contract kept `ORDER BY` above the composed aggregate on the eager
path, and the single-table pull had excluded it since E5, because a sort needs
every row before it can emit one. That reasoning is about the fold's input, not
its output. Both pull paths already applied the `OFFSET`/`LIMIT` window to the
grouped batch once the last input row had been folded, and the eager aggregate
path sorts that same batch in memory under a budget without ever sending it to
runs. So the sort moved into the tail the two pull paths share, with the eager
path's key resolution — an output-column key sorts by its projection
expression, which holds the values the projected column will carry, and an
expression key by its bound form — and the two shape predicates stopped
refusing an `ORDER BY`.

### The decision this needed

The open question in the contract was whether an over-budget sort of the
grouped batch spills through the existing run-file pool inside a folded query.
It does not, and the reason is the one §45 states: a budget bounds input
buffers, and a grouped result is not input. Ordering a grouped result through
sorted runs is a separate, larger design — it would have to size itself against
the budget the fold is already spending, and it would move where the `LIMIT`
can stop. The tail therefore sorts in memory, exactly as the eager aggregate
path does, and a grouped result stays unbounded (the limit the roadmap still
carries). What changes is only which queries reach that sort with a pulled
input.

### What is measured

`harness/bench_ordered_agg.py` runs the TPC-H queries that carry an `ORDER BY`
over an aggregate at SF1, candidate against the E6b binary `eabf3e3`, three
rounds interleaved, recorded in `harness/baseline/2026-10-28-ordered-agg.json`
(candidate tree `c2bc3fa`, clean, quiet load 0.27, worst round-to-round spread
1%). Each query's output is compared byte for byte between the two binaries and
no case disagreed. q3 and q10 are in the matrix as invariants: they carry two
join steps, so the composition does not claim them, and their peak must not
move.

Peak RSS in MB, control against candidate, with the wall time beside it:

| query | shape | no budget | 16 MB budget | wall s, no budget / 16 MB |
| --- | --- | --- | --- | --- |
| q1 | one table, ordered groups | 543.3 → 35.3 | 558.7 → 75.3 | 2.80 → 2.70 / 5.14 → 5.02 |
| q12 | one join step, ordered | 112.7 → 35.3 | 115.3 → 35.4 | 2.64 → 2.60 / 3.16 → 2.59 |
| q3 | two join steps (invariant) | 357.1 → 357.3 | 261.2 → 262.6 | 2.41 → 2.41 / 3.21 → 3.25 |
| q10 | two join steps (invariant) | 283.1 → 283.1 | 245.3 → 245.5 | 2.52 → 2.52 / 3.94 → 3.95 |

**The ordered single-table aggregate stops holding its input.** q1's 543.3 MB
is the collected `lineitem`, and the pull path replaces it with the 4-row group
table plus one batch: 35.3 MB, the same floor a `count(*)` over the same file
reaches (§45). That is the widest drop this arc has recorded on a golden query,
and it is what makes the `ORDER BY` exclusion worth lifting. Under a 16 MB
budget both paths partition the aggregate input and spill it (the candidate
wrote 198.5 MB across 153 run files for q1); the difference is again what is
held while they do it, 75.3 MB against 558.7 MB. The wall time moves by the
same margin as any of these comparisons (2.80 against 2.70 s without a budget,
5.14 against 5.02 s with one): the scan dominates, and the budget's own work is
the same on both paths.

**An ordered join composition keeps the joined rows out of memory.** q12's
112.7 MB was the collected `orders × lineitem`; the composed path holds the
build side, the fold's state and one batch, 35.3 MB. It fits a 16 MB budget
without spilling at all, because the joined batches are folded as they arrive
(30,988 joined rows, two groups), so the budget only has to hold the fold's
buffer. It is also the only ordered one-join query in the corpus: q14 and q19
were §49's two `ORDER BY`-free shapes, and every other TPC-H query with an
`ORDER BY` over an aggregate keeps a second join step (q3, q10, q5, q7, q8,
q18, q21) or a derived table (q15).

**The invariants hold.** q3 and q10 move by 0 to 1.4 MB, which is inside the
recorded spread, and the two binaries take the same path for them by
construction: their answers are identical. That is what "the composition does
not claim this shape" has to look like, and it is why the matrix keeps them.

### What this does not say

It does not order a grouped result through sorted runs, so a query whose
grouped answer itself outgrows memory is still unbounded (§45, and the
roadmap's limits row). It does not add a second join step: q3 and q10 are
unchanged, and that is now the widest remaining shape in the corpus. DISTINCT,
a window function, a chain, RIGHT, SEMI/ANTI and a keyless cross join still
keep the eager path. The record is the native CLI over CSV input at SF1, as §49
was; wasm-gc, js and the packaged consumer are unchanged by this and still ride
§46–48.
## 51. A chain of joins above a fold (2026-10-28): E6b, one step further

§49 composed one join step into the fold and §50 lifted `ORDER BY` above it.
The shape that stayed out was the second step: a chain of three or more tables,
which is what every other TPC-H join query in the corpus is. The mapping the
contract expected to need turned out to be free. A step's probe layout is the
previous step's output layout, which is exactly what `JoinCursor` hands out and
what the collected path feeds it, so the chain is one cursor per step whose
`next_left` is the previous cursor's `next`, and the fold's expressions stay
bound to the last step's layout. The per-step order is the collected path's:
step `i`'s probe filter trims what the step below produced, its build filter is
applied at that table's scan, and the residual waits until after the last step.
A linear chain of any length whose steps are all INNER, LEFT or FULL over lazy
base tables now folds instead of collecting, and the row counters keep their
order: `scan t0`, `scan t1..tn`, `joins`, `aggregate`, `result`.

### The decision this needed

The contract left one question open and the first measurement answered it
against the naive version. Every step's build side is resident and indexed, so a
chain holds one side per step at once, and the sum can weigh more than the
joined rows the eager path would have held. With the composed path taken
whenever the shape matched, TPC-H q3 at SF1 held 32 MB more than collecting it
(352.7 against 384.5 MB in one exploratory round), while q11 held 63 MB less and
q10 and q5 about 15 MB less each; a chain whose largest table is the last build
side is the losing case, and `FROM` order decides that, not the shape.

So a chain composes only under a budget its sides fit: with one, the peak is the
bound the sides were checked against; without one, the resident sides and their
index are the peak and there is nothing to compare them to. A single step still
composes without a budget, because one resident side is a different order of
magnitude from a sum of them. The check runs on the bytes of the scans before
the layout copies exist, so a chain that keeps the eager path pays for no copy
(the copies alone were 13 MB on q18) and the scans it read are handed to the
eager path, which reuses them, so no table is read twice and the counters stay
the eager ones. §52 later removed this gate by making the index over a build side
cheaper; the rule above is the one the code held before that change.

### What is measured

`harness/bench_join_chain.py` runs the TPC-H queries that carry an aggregate
over two or more join steps at SF1, candidate against the tree before the change
(`aa63f7a`), three rounds interleaved, recorded in
`harness/baseline/2026-10-28-chain-agg.json` (the candidate tree was `aa63f7a`
plus this change, dirty at measurement time; quiet load 2.05, worst
round-to-round spread 10%). Each query's output is compared byte for byte
between the two binaries and no case disagreed.

Peak RSS in MB, control against candidate, with wall seconds beside it:

| query | shape | no budget | 16 MB budget | wall s, no budget / 16 MB |
| --- | --- | --- | --- | --- |
| q3 | three tables | 356.7 → 356.2 | 262.8 → 262.4 | 2.58 → 2.54 / 3.57 → 3.51 |
| q5 | six tables | 650.3 → 650.8 | 445.2 → 444.3 | 3.24 → 3.04 / 4.91 → 4.94 |
| q10 | four tables | 283.0 → 283.0 | 245.4 → 245.3 | 2.63 → 2.64 / 4.27 → 4.51 |
| q11 | three tables | 99.1 → 94.7 | 99.4 → 25.4 | 0.41 → 0.42 / 0.70 → 0.40 |
| q18 | three tables, `IN` | 470.4 → 467.3 | 227.4 → 227.3 | 4.95 → 4.90 / 6.02 → 5.81 |
| q20 | five tables, `IN` | 258.0 → 258.1 | 98.9 → 99.4 | 2.85 → 2.85 / 2.90 → 3.06 |
| q21 | four tables, `NOT EXISTS` | 608.3 → 604.1 | 666.7 → 666.6 | 7.86 → 8.15 / 13.65 → 13.89 |
| q1 | one table (invariant) | 35.3 → 35.4 | 73.3 → 75.4 | 2.94 → 2.93 / 5.25 → 5.27 |
| q12 | one step (invariant) | 35.3 → 35.2 | 39.3 → 35.4 | 2.83 → 2.89 / 2.88 → 2.91 |

**One corpus chain fits a 16 MB budget, and it is the shape the rule was for.**
q11 folds `partsupp ⋈ supplier ⋈ nation` from 99.4 MB to 25.4 MB, and it stops
spilling altogether: the eager path partitions both joins and writes 13 run
files (22.4 MB) where the composed path writes none, because its two build sides
are `supplier` and `nation`. Its answer and all five counters are identical.

**Every other case takes the same path as the control, and the record shows it
in the spill trace rather than only in RSS.** At 16 MB q3, q5, q10, q18, q20 and
q21 report the same spill file count and the same bytes written as the control,
which is what "the shape composes only when its sides fit" has to look like from
outside; their peaks move by the recorded spread. The two invariants move by it
as well, which is why q1 and q12 are in the matrix: q1 composes one table and
q12 one step in both binaries, and the 4 MB q12 shows at 16 MB is the spread
(the same case read 35.5 against 35.5 in an earlier round of this record). q7,
q8 and q9 keep a derived
table, so their plan is not a chain of lazy tables at all and the composition
never applies. Without a budget every chain is on the eager path, so the
candidate and the control read the same tables and move inside the spread too.

**The gates hold.** `moon test` is 382 tests green (the chain answers, counters,
filters, a FULL step mid-chain, an ordered chain and the fit check are new), the
33 golden comparisons pass, and `check_cli.sh` and `spill_accept.sh` are
unchanged by this.

### What this does not say

It does not make the composed chain cheap enough to take without a budget. The
cost is the per-key id lists a bridge-shaped build side builds when it primes
its hash map, and the exploratory round described above says what the gate
would buy: about 60 MB on q11 and 15 MB each on q10 and q5, at 32 MB on q3.
Making that trade even needs the index to be cheaper, which is a separate
change.

It does not reorder the plan: the chain is the `FROM` order, so a query whose
largest table is the last build side still holds it whole. It does not
pre-aggregate between steps. DISTINCT, a window, RIGHT, SEMI/ANTI, a keyless
cross join and a `FROM` item that is not a lazy base table still keep the eager
path, and a grouped result stays unbounded. The record is the native CLI over
CSV input at SF1, as §49 and §50 were; wasm-gc, js and the packaged consumer are
unchanged by this and still ride §46–48.

## 52. A cheaper index over a build side, and the chain gate it removed (2026-10-29)

**What §51 left.** §51 composed a chain of joins only under a budget its build
sides fit, because the ungated version measured q3 holding 32 MB more than
collecting the joined rows. The measurement was honest and the rule it produced
was one data structure out of date.

**What changed.** A build side's fast-path index was `Map[Int64, Array[Int32]]`,
a list per distinct key. That is right for a small dimension table and wrong for
a primary key over millions of rows, because then every key has one row and the
index pays an allocated list for it. It is now `IntKeyIndex`: two passes over the
build keys, the first numbering each key's slot and counting it, the second
writing every row id into its slot's range. The ids are one `FixedArray[Int32]`
of exactly four bytes per row, each distinct key costs a slot in the map and a
start in the table, and a unique key allocates nothing beyond its own id.

`join_step` builds its hash join on the same cursor, so this is not a
composition-specific win: every keyed INNER, LEFT and FULL hash join is cheaper,
whether it folds into an aggregate or collects its rows.

**What that is worth, and what composition then adds.** Three binaries of the
same tree, interleaved, three rounds, quiet host: the control (before the chain,
§51's own base), the same tree with the cheap index but §51's gate restored, and
the final tree. Peak RSS in MB:

| case | budget | control | cheap index, gate kept | cheap index, chain composed |
| --- | --- | --- | --- | --- |
| q3 | none | 356.7 | 329.3 | 356.8 |
| q5 | none | 650.6 | 584.5 | 587.0 |
| q9 | none | 742.9 | 701.1 | 700.9 |
| q10 | none | 282.8 | 262.9 | 238.8 |
| q11 | none | 99.2 | 95.2 | 35.2 |
| q20 | 16 MB | 99.1 | 87.5 | 87.2 |

The index alone takes 27 MB off q3, 66 off q5, 42 off q9, 20 off q10 and 12 off
q20 at 16 MB. Composition, on top of it, gives q10 24 MB more and q11 60 MB
more, costs q5 2.5 MB, and on q3 hands its index saving back: q3's chain holds
`orders` and `lineitem` resident, which is the whole cost §51 measured, and the
cheaper index cancels it rather than removing it.

**So the gate goes.** Against the tree a query used to run on, no composed chain
measures worse: q3 is level, q5 64 MB lower, q10 44 MB lower, q11 64 MB lower.
A chain now composes whenever there is no budget to violate, or when its sides
fit the one there is, and §51's routing rule is superseded by this paragraph.
The fit check stays, because a budget is still a promise the residency has to
keep, and the scans it runs on are still handed to the eager path so no table is
read twice. A single step composes on the terms it always had.

**The full matrix.** `harness/bench_join_chain.py` against the pre-chain control,
`harness/baseline/2026-10-29-chain-index.json` (quiet load 1.45, worst spread
11%, three rounds, no answer disagreed). Peak RSS in MB with wall seconds beside
it, no budget:

| query | shape | control | candidate | wall s |
| --- | --- | --- | --- | --- |
| q3 | three tables | 356.8 | 356.6 | 2.72 → 2.79 |
| q5 | six tables | 657.4 | 587.0 | 2.99 → 3.06 |
| q7 | derived table | 527.2 | 527.0 | 3.78 → 3.80 |
| q8 | derived table | 470.6 | 469.2 | 2.44 → 2.38 |
| q9 | derived table | 742.9 | 701.0 | 4.14 → 4.32 |
| q10 | four tables | 282.7 | 239.1 | 2.84 → 2.83 |
| q11 | three tables | 99.2 | 35.3 | 0.43 → 0.44 |
| q18 | `IN` subquery | 469.4 | 469.1 | 5.15 → 5.28 |
| q20 | `IN` subqueries | 259.0 | 259.1 | 3.03 → 3.04 |
| q21 | `NOT EXISTS` | 612.0 | 616.6 | 8.08 → 8.03 |
| q1 | one table, invariant | 35.4 | 35.3 | 2.97 → 3.00 |
| q12 | one step, invariant | 35.3 | 35.2 | 2.94 → 2.91 |

At 16 MB only q11 fits its sides and gains the composition on top of the index
(99.4 → 25.5 MB, wall 0.73 → 0.41 s); q20's 98.8 → 87.1 MB there is the index
alone, on a plan that is not a chain, and every other case sits within the
recorded spread.

**Costs.** Priming an index walks the build keys twice instead of once. The wall
columns above are the price: a few percent on the queries that changed path,
inside the spread on the ones that did not. Nothing else about the arc moved:
the chain is still the `FROM` order, there is no pre-aggregation between steps,
and DISTINCT, a window, RIGHT, SEMI/ANTI, a keyless cross join and a non-lazy
`FROM` item still keep the eager path.

**The gates hold.** `moon test` is 384 tests green (two pin the index: one id per
valid row, contiguous slots, NULL keys absent), the 33 golden comparisons pass,
and `check_cli.sh` and `spill_accept.sh` pass unchanged.

## 53. The semi, anti and right joins take the same index (2026-10-29)

**What changed.** `join_semi` and `join_swapped` were the last places that
indexed a build side as a list per distinct key on the integer path. They now
build an `IntKeyIndex`, the same row-id range the hash join cursor uses (§52).
The string-key path keeps its lists. No list-per-key index over `Int64` keys is
left in the engine.

**What it is worth: nothing measurable.** §52 named these two forms as the next
lever on eager peaks. Three interleaved rounds against the binary of the
previous commit, quiet host (load about 1.2), answers identical byte for byte.
Peak RSS in MB:

| query | form | no budget | 16 MB |
| --- | --- | --- | --- |
| q18 | `IN` subquery | 471.6 → 469.3 | 227.3 → 227.3 |
| q20 | `IN` subqueries | 258.9 → 259.1 | 87.5 → 87.4 |
| q21 | `NOT EXISTS` | 615.2 → 619.3 | 682.7 → 684.5 |
| q3 | invariant | 356.9 → 356.8 | 261.9 → 260.6 |

Every difference is inside the 11% worst spread recorded in §52, and the wall
times are level. So the peaks of q18, q20 and q21 are not set by the index over
a semi or anti side, and the lever §52 named does not exist in this corpus. What
does set them is not shown by this measurement.

**Why it is kept.** The change removes the last list-per-key code on the integer
path and costs nothing, so there is one index shape to reason about. It is a
cleanup and is recorded as one, not as a saving.

**The gates hold.** `moon test` is 384 tests green, the 33 golden comparisons
pass, and `check_cli.sh` and `spill_accept.sh` pass unchanged.

## 54. The group state of one integer key, held column-wise (2026-10-29)

**What the probes said.** Before this change the peak of q18 and q20 was the
state of their `GROUP BY`, and the cost was per group, not per byte of input: a
single `Int32` key with one `sum` fitted 288 bytes a group (35 MB base plus 288
MB per million groups, residual 5 MB), two integer keys fitted 410, and the
split at one million groups put about 240 bytes of that in the group before any
aggregate was added (a key row of boxed scalars, an accumulator row, and one
object per accumulator). A key and a running sum need about a dozen.

**What changed.** `aggregate_seq` takes a column-wise fold when the key is one
`Int32` or `Int64` column and every aggregate is a `sum` (integer or float
output), a `count` of an input or `count(*)`. The state is a slot map from key
to group id, one `Int64` array of keys, and per aggregate one array (two flags
and a sum for a `sum`), all indexed by group id, and the result columns are
built straight from those arrays. Group order (first seen), the one shared NULL
key group, sums folded in row order (so float sums are bit-identical), NULL
inputs skipped, the integer overflow check and its error all follow the general
fold. Every other shape, a second key, a string or date key, `min`/`max`,
`avg`, `distinct` and the rest, takes the general fold unchanged. The grace and
join-fold callers reach the same `aggregate_seq`, so they take it too.

**What it is worth.** Three interleaved rounds against the binary of the
previous commit, quiet host (load under 2), answers identical byte for byte.
Peak RSS in MB, wall seconds beside it:

| case | budget | before | after | wall s |
| --- | --- | --- | --- | --- |
| one key, `sum`, 1.0M groups | none | 323.3 | 117.3 | 2.12 → 1.97 |
| one key, `sum`, 1.0M groups | 16 MB | 69.5 | 51.4 | 2.38 → 2.21 |
| one key, `sum` + `count(*)` | none | 354.6 | 125.0 | 2.25 → 2.08 |
| same plus `max` (general fold) | none | 416.3 | 415.9 | 2.31 → 2.35 |
| q18 | none | 477.4 | 388.9 | 5.11 → 4.77 |
| q18 | 16 MB | 227.2 | 227.3 | 5.62 → 5.44 |
| q20 | none | 258.9 | 258.8 | 3.01 → 2.95 |
| q20 | 16 MB | 87.4 | 87.0 | 3.19 → 3.13 |
| q21 | none | 616.9 | 613.1 | 8.22 → 8.25 |
| q3 | none | 357.2 | 356.9 | 2.76 → 2.78 |
| q1 | none | 35.3 | 35.3 | 2.92 → 2.97 |

A group of this shape now costs about 82 bytes over the base (from 288) with one
`sum`, and the control row with a `max` shows the general fold is untouched. What
is left of the 82 is mostly the slot map entry and array growth; it was not
split further.

**What it does not do, and what the q18 numbers say.** q18 fell 88 MB, not the
roughly 370 the probe line promised, because its aggregate was only part of the
peak. The `IN` subquery alone now peaks at 147 MB, and the outer query with the
subquery replaced by nine literal keys peaks at 388.7 MB, the same as the whole
of q18. So what remains is the outer join, in which `lineitem`, six million rows,
is the last build side and is held whole with its index, to answer nine orders.
That is a join order question (probe `lineitem` against a small hash of
`orders` instead of building it), not an index or an aggregate one, and this
change does not touch it. q20 groups by two integer keys and q21's weight is its
`lineitem` semi and anti sides, so neither moved, as the table shows.

**The gates hold.** Five tests pin the fold: it is chosen only for one integer
key over the four aggregate kinds, it agrees cell for cell with the general fold
on batches with NULL keys, NULL inputs and keys spanning batches, an all-NULL
sum stays NULL on an `Int64` key, an int64 sum overflow still raises, and an
empty input has no groups. `moon test` passes on wasm-gc (389) and native (402),
the 33 golden comparisons pass, and `check_cli.sh` and `spill_accept.sh` pass
unchanged.

## 55. A pair of Int32 keys joins the column-wise fold (2026-10-29)

**What changed.** §54 left q20 where it was because its `GROUP BY` has two
integer keys. The column-wise fold now also takes a pair of `Int32` keys. The
pair packs into one `Int64` slot key (high half the first key, low half the
second), which is exact for 32-bit values, so the slot map and the per-group
arrays are the single-key ones. A row with a NULL in either key cannot take that
slot, so it goes through a small side map keyed by its text, one entry per NULL
pattern, which keeps `(NULL, 1)` and `(1, NULL)` apart as the general fold does.
Group order, sums and the overflow error are unchanged. Other pairs (an `Int64`
or a string in either position) and three or more keys keep the general fold.

**What it is worth.** Three interleaved rounds against the single-key build of
§54, quiet host, answers identical byte for byte. Peak RSS in MB, wall seconds
beside it:

| case | budget | before | after | wall s |
| --- | --- | --- | --- | --- |
| `(l_orderkey, l_linenumber)`, `sum`, about 4M groups | none | 1630.5 | 410.6 | 4.32 → 3.05 |
| `(l_partkey, l_suppkey)`, `sum`, 800k groups | none | 353.9 | 109.1 | 6.19 → 3.04 |
| `(l_partkey, l_suppkey)`, `sum`, 800k groups | 16 MB | 82.5 | 59.3 | 5.86 → 3.54 |
| q20 | none | 258.8 | 99.2 | 2.96 → 2.50 |
| q20 | 16 MB | 87.4 | 87.3 | 3.21 → 2.80 |
| q18 | none | 388.8 | 388.8 | 4.99 → 5.00 |
| q3 | none | 356.8 | 357.0 | 2.74 → 2.72 |

The 800k-group probe went from about 400 bytes a group (the string-key path, one
concatenated key text per row) to about 90, and q20, whose peak was that one
aggregate, fell by 160 MB. The group count of the first row is approximate (four
lines an order over the orders below key 4,000,000); it was not counted. q20 at
16 MB did not move: under a budget its peak is set elsewhere, which this
measurement does not say. q18 and q3 group by more than two keys or by strings
and are unchanged, as expected.

**The gates hold.** Two tests are added (the pair agrees cell for cell with the
general fold on batches with NULLs in either position, and negative keys and
each NULL pattern stay separate groups) and the plan test now pins which key
shapes take the fold. `moon test` passes on wasm-gc (391) and native (404), the
33 golden comparisons pass, and `check_cli.sh` and `spill_accept.sh` pass
unchanged.

## 56. A compact key range is looked up by offset (2026-10-29)

**What changed.** The index over a build side (§52) mapped each key to its slot
through a hash map, which costs an entry per distinct key and a hash per probe
row. When the valid build keys sit in a range no wider than four times the row
count plus 1,024 (and under 2^24 cells), the lookup is now one `Int32` array
indexed by `key - lowest`, four bytes a cell and no hashing; any other key set,
including a span that overflows `Int64`, keeps the map. The slot ranges and row
ids are unchanged, so the semi, anti, right and cursor paths all take it through
one `slot` method. TPC-H surrogate keys are the compact case: `orders` has 1.5M
keys over a span of 6M.

**What it is worth.** `harness/bench_join_chain.py` against the build of the
previous commit (the pair-key fold), `harness/baseline/2026-10-29-dense-index.json`,
three rounds, quiet load 1.87, worst peak-RSS spread 11%, no answer disagreed.
Peak RSS in MB with wall seconds, no budget:

| query | RSS | wall s |
| --- | --- | --- |
| q3 | 353.1 → 325.1 | 2.77 → 2.37 |
| q5 | 587.0 → 524.6 | 3.07 → 2.45 |
| q18 | 389.0 → 326.3 | 5.02 → 4.36 |
| q7 | 527.2 → 527.9 | 3.76 → 2.99 |
| q9 | 701.0 → 701.0 | 4.20 → 3.07 |
| q21 | 617.9 → 613.4 | 8.26 → 7.03 |
| q10 | 238.8 → 236.8 | 2.80 → 2.75 |
| q8, q11, q20, q1, q12 | within 2 MB | within 0.1 |

The three queries that hold a large keyed build side fall by 28, 62 and 63 MB,
which is the map entries the array replaces. The wall columns fall on the
queries that probe millions of rows, as a lookup that no longer hashes should;
the spread was recorded for RSS only, so those are reported, not claimed beyond
that. Under 16 MB every row is within the spread (q11 25.5 → 23.5 MB, the rest
within 3 MB), because there the joins partition and the sides are small.

**The gates hold.** One test pins the lookup: a compact range, a wide set, a
span that overflows `Int64`, negative keys, and keys below, inside and above the
range that are absent. `moon test` passes on wasm-gc (392) and native (405), the
33 golden comparisons pass, and `check_cli.sh` and `spill_accept.sh` pass
unchanged.

## 57. The last build side swaps with a few earlier rows (2026-10-29)

**What changed.** A chain keeps the `FROM` order, so q18 held all of `lineitem`,
six million rows and their index, as its last build side to match nine orders.
Under the contract in the roadmap, the last step of a chain now runs swapped when
the rows the earlier steps produce are few: they become the hash side
(`SwapCursor`, with the same `IntKeyIndex` and string-key fallback as
`JoinCursor`) and the last table streams past them through its build filter.
The step must be INNER over a lazy table, and the query must not carry
`string_agg` or `approx_quantile`, nor a LIMIT or OFFSET without an ORDER BY.
The decision is taken at run time: the earlier steps are pulled up to 65,536 rows
(under a budget also a quarter of the budget in estimated bytes); inside that cap
the step swaps, past it the chain runs as before.

**One deviation from the contract.** The contract said a prefix that passes the
cap is replayed ahead of the rest of the pull. The code drops it and lets the
unswapped chain open table 0 again, so a query that passes the cap reads the part
of table 0 the prefix pull consumed twice. The build sides of the earlier steps
are kept, so none of them is read twice, and the counters come from the run that
is kept. It is simpler and bounded by the cap, and the invariant rows below did
not move beyond the spread.

**What it is worth.** `harness/bench_join_chain.py` against the build of §56,
`harness/baseline/2026-10-29-swap-last-side.json`, three rounds, quiet load 2.30,
worst peak-RSS spread 10%, no answer disagreed. Peak RSS in MB with wall
seconds:

| query | budget | RSS | wall s |
| --- | --- | --- | --- |
| q18 | none | 324.7 → 145.2 | 4.48 → 4.45 |
| q18 | 16 MB | 227.3 → 71.2 | 5.68 → 4.86 |
| q3, q5, q10, q11 | none | within 2 MB | level |
| q7, q8, q9, q20, q21 | none | within 4 MB | level |
| q1, q12 | none | within 0.1 MB | level |
| every other case | 16 MB | within the spread | level |

q18 lands where §54 measured its `IN` subquery alone (147 MB), which is the
prediction the contract left unclaimed. q3, q5 and q10 pass the cap and keep
the unswapped chain, as expected, so their peaks do not move. q12 at 16 MB reads
35.5 → 39.5 MB, inside the spread.

**What it changes, on purpose.** Rows reach the fold in the table's order
instead of the prefix's, which moves the first-seen order of groups and the order
float sums accumulate in. The 33 golden comparisons pass unchanged, and the
answers above are byte-identical at this scale.

**The gates hold.** Seven tests pin the swap: a few earlier rows swap, the cap
boundary (exactly the cap swaps, one more does not), the exclusions, equality
with the unswapped chain for a residual, a probe filter and a build filter, an
empty prefix that still reads the last table to its end, and duplicate and NULL
keys. `moon test` passes on wasm-gc (398) and native (411), `check_cli.sh` and
`spill_accept.sh` pass unchanged.

## 58. Where the semi and anti side of q21 spends its memory (2026-10-29)

This is a measurement, not a change. §54 left q21 at about 615 MB without a
budget and could only say that the `lineitem` side of its `EXISTS` and `NOT
EXISTS` held it. The probes below separate the two costs that side has, using
the build of §57 and the same harness runner, three rounds each, quiet host.
Peak RSS in MB, over a base of 35.3 MB for a streamed scan:

| probe | RSS |
| --- | --- |
| `lineitem` as a derived table, 2 integer columns | 157.7 |
| the same with 3 integer columns | 218.8 |
| the same with 2 integer and 2 date columns | 279.1 |
| `EXISTS` over 2 integer columns, left side under 1,000 orders | 240.0 |
| `IN` over 1 integer column, left side under 1,000 orders | 184.1 |

**Holding the rows.** Each extra integer or date column adds about 61 MB for six
million rows, 10 bytes a cell, against the 5 bytes a cell the column itself needs
(four for the value, one for its validity flag). That is two copies: the inner
query runs as an ordinary query, so its scan batches and the one result batch it
concatenates into exist together at the peak.

**Indexing the rows.** The `EXISTS` probe is 82 MB above the derived table of the
same two columns, and the `IN` probe is about 88 MB above its one-column
equivalent. That is the semi join's key conversion and index. The key column is
widened to an `Int64` array first (48 MB for six million rows), then the index
adds its row-id array (24 MB) and its slot and start tables. These two terms
explain the figure; the split between them is estimated from the array sizes and
was not read from a counter.

**What q21 holds.** Two such sides at once, one for `EXISTS` over two columns and
one for `NOT EXISTS` over its date-filtered rows, plus the probe pipeline and the
`orders` side, which is the 615 MB. So the lever is on the inner side: not
making a second copy of the scan before the side exists, and indexing 32-bit keys
without widening them first. Neither is taken here. The first changes how a
decorrelated subquery is executed, the second the signature of the key index and
its callers, and each needs its own measurement.

## 59. An Int32 key is indexed in place (2026-10-29)

**What changed.** §58 named the widening of an `Int32` key column to `Int64`
before indexing as one of two costs on the inner side of q21. The index builder
now has `IntKeyIndex::build_i32`, which reads a single `Int32` key column as it
is and produces the same index (same compact-range rule, same slots, starts and
ids). The hash join cursor and the semi and anti side use it when the build key is
one `Int32` column; `Int64` keys, pairs of keys and the string path are as before.
The probe side was already read batch by batch and is unchanged.

**What it is worth.** Three interleaved rounds against the build of §57, quiet
load under 2, answers identical byte for byte. Peak RSS in MB, wall seconds level
in every row:

| query | no budget | 16 MB |
| --- | --- | --- |
| q21 | 605.9 → 603.2 | 679.3 → 678.5 |
| q3 | 329.0 → 306.7 | 261.6 → 263.0 |
| q5 | 524.9 → 476.9 | 445.5 → 443.7 |
| q9 | 700.4 → 692.2 | 664.3 → 663.9 |
| q18 | 145.3 → 145.2 | 69.2 → 75.3 |
| q20 | 99.3 → 99.2 | 87.0 → 87.2 |

q3 and q5 fall by 22 and 48 MB without a budget, which is the temporary `Int64`
column of their large build sides. **q21 does not move.** The widened column is
not what sets its peak: the 48 MB the §58 estimate gave it was a transient that
does not coincide with the maximum. That leaves the second term of §58, the inner
side existing twice, as the remaining lever, and this measurement supports it only
by elimination. The 16 MB rows are inside the spread (q18's 6 MB is the spread).

**The gates hold.** One test builds the same indexes from the narrow and the
widened column for a compact set with a repeat and a NULL and for a wide set with
extreme keys. `moon test` passes on wasm-gc (399) and native (412), the 33 golden
comparisons pass, and `check_cli.sh` and `spill_accept.sh` pass unchanged.

## 60. Releasing the scan batches during collection does not move q21 (2026-10-29)

This is a negative result. The contract in the roadmap ("The single-copy inner
side contract") predicted that concatenating a collected single-table result one
column at a time, and letting go of each chunk's column once copied, would take
the second copy off the inner side of q21 and off the derived-table probes of
§58. It was implemented (a releasing concatenation over shells that
`drain_scan` owns, so no vector a source shares was ever written to), passed the
gates, and was measured against the build of §59: three interleaved rounds, quiet
load under 2, answers identical byte for byte. Peak RSS in MB:

| case | budget | before | after |
| --- | --- | --- | --- |
| q21 | none | 617.8 | 613.0 |
| q21 | 16 MB | 682.9 | 684.5 |
| derived table, 2 integer columns | none | 153.2 | 153.3 |
| derived table, 3 integer columns | none | 220.7 | 220.2 |
| derived table, 2 integer and 2 date columns | none | 284.8 | 284.6 |
| q3, q5, q9, q18, q1 | none | unchanged | within 0.2 MB |
| q20 | none | 99.1 | 93.3 |

The derived-table probes were the direct test, and they did not move, so the
change was reverted and nothing from it is kept. q20's 6 MB at no budget is a
single row against an unchanged 16 MB row of 87.1 and 87.2, and is not claimed.

**What this does and does not say.** §58 inferred two copies from 10 bytes a cell
against the 5 a column needs. That inference is now unsupported, not refuted: it
could be that the inner side is not held twice at its peak, or that it is held
twice somewhere other than the collection (the outer query's scan of the derived
table, the key column an operator evaluates, the result a projection builds), or
that memory freed during the collection is not returned to the process before the
later maximum. This measurement cannot tell these apart, and no counter inside
the engine reads the live bytes by structure. Until one exists the inner side of
q21 is a measured quantity (about 603 MB without a budget) with an unexplained
composition, and the next step is that counter, not another lever.

## 61. The structure census names q21's peak (2026-10-29)

This is the measurement §60 asked for instead of another lever. The contract
("The structure census contract", roadmap) was written first and committed
alone: it fixes what a checkpoint counts, what it refuses to count, where it
reports, and what the number may be compared against. `moonlake exec --mem` runs
a query with the census on and prints one block per declared label, largest
first, each block listing the structures alive at that point, largest first.
Without the flag no census is built.

**How it counts.** At a checkpoint the executor sums structures it can point
at, sized from the structures themselves with the budget's own estimate
(`estimate_batch_bytes`) plus its own for index arrays and map entries:
collected scan batches per table, a step's probe input and filtered build scan,
the concatenated copy a build or output makes, the dense/starts/ids arrays of an
index and an estimate for its hashed slots. It is not an allocator hook:
strings, boxing, freed-but-unreturned heap and a source's decoder buffers are
outside it, so its total is a lower bound on RSS rather than a decomposition of
it. The numbers here are from `3bd799b`, which also fixed a double count in the
semi/anti point (a collected table named once as a table and again as its
filtered scan).

**q21 at SF1, no budget.** Native release build, SF1 CSVs, six interleaved
plain/census rounds: plain peak RSS 602.1–614.6 MB (median 609.7), `--mem`
605.6–620.2 MB, wall 6.95–7.05 s plain and 7.14–7.41 s measured, answers
identical. The largest census point:

```
-- resident by structure (largest point of each of 9 labels, 9 points seen)
# hash join collapsed its output (step 2): 521664603 bytes
probe input: 174491660
collected FROM tables: 145969437
collected output: 100613349
collapsed output: 100590157
```

and the collected tables inside it, by table:

| table | bytes |
| --- | --- |
| lineitem | 60739648 |
| __semi0 | 48009744 |
| __semi1 | 30346392 |
| orders | 6573525 |
| supplier | 300084 |
| nation | 44 |

The other blocks, largest first: step 1's collapse 495.3 MB (the same tables,
174.5 collected and 174.5 collapsed); step 2 collecting 451.0 MB (probe input
174.5, tables 146.0, output 100.6, index map 17.5, build copy 6.6, index arrays
5.8); step 1 collecting 396.7 MB (output 174.5, tables 146.0, build copy 60.7,
index arrays 15.3); the semi side of step 4 at 259.4 MB (tables 146.0, index
54.0, inner copy 48.0, probe input 5.7, probe copy 5.7) and of step 5 at
233.1 MB (tables 146.0, index 44.7, inner copy 30.3, probe input 6.1, probe
copy 6.1); step 3's collapse 257.9 MB and collection 252.3 MB.

**What it says.** The peak is not on the semi/anti side. It is the second chain
step's collapse: the collected join output and the single batch it becomes are
live together (2 × 100.6 MB), on top of that step's probe input (174.5 MB, which
is step 1's whole output) and the collected FROM tables (146.0 MB). The semi
sides §58 probed peak at 259.4 and 233.1 MB, below the chain's 521.7 MB. They do
hold their collected side and a concatenated copy of it (48.0 MB and 48.0 MB at
step 4), so §58's two copies are real there as well; they are simply not the
peak, which is why §60's release of that collection moved nothing. That is an
attribution, not a lever: the census exists to name the composition, and any
change to it needs its own contract and measurement.

**The gap.** The largest point names 521.7 MB of a roughly 610 MB peak: about
88 MB, 15%, is outside the contract — source decoder buffers, allocations it
does not name, and freed memory not yet returned to the process. The contract
says that gap is reportable, and this is it.

**Scope, honestly.** A budgeted run reaches the grace path, which the contract
does not instrument: q21 at 16 MB reports one block (the tables, 146.0 MB) while
peaking at 678.1 MB. A pulled shape reaches no checkpoint at all: q18 prints
nothing at 145.2 MB, and q20's only eager step (supplier × nation) names 0.5 MB
against 99.3 MB of RSS. Those are the contract's declared limits, not failures.

**The counter must not perturb.** The first version of the collapse checkpoint
named the index and the build copy, which are already released when the
concatenation runs; merely referencing them kept the cursor alive across the
copy, and the census run's peak rose to 639 MB, against 610 MB for a build with
the observe code deleted. The checkpoint now names only what is alive there, and
the paired runs above sit inside the plain run's spread. This is recorded because
a counter that changes the thing it measures is worse than none.

**Gates.** `moon test` 404 on wasm-gc and 417 on native; `check_all.sh` all 33
goldens on the native release binary; `check_cli.sh` (which now pins `--mem`: the
header, the tables block, a pulled shape printing nothing) and
`spill_accept.sh` pass. Nothing is measured unless the flag is given.

## 62. The collapse's single copy does not move the peak (2026-10-29)

The contract ("The collapse single copy contract", roadmap) was written first and
committed alone. This measures it. `concat_batches_releasing` built a join step's
collapsed output one column at a time and dropped each source column from its
batch as soon as it was copied, so the collected output and the batch it becomes
are never both at full width; it was used by `join_step` only, because `right`
may be a catalog table's own batches. Gates were green and answers byte-identical
throughout: `moon test` 406 on wasm-gc and 419 on native with the change in (two
new tests, back to 404 and 417 after the revert), `check_all.sh` 33 goldens,
`check_cli.sh`, `spill_accept.sh`.

**What it did to the census.** Exactly what the contract predicted, one copy
less at every collapse:

| point | §61 build | this build |
| --- | --- | --- |
| hash join collapsed its output (step 2) | 521664603 | 421051254 |
| hash join collapsed its output (step 1) | 495293629 | 320761181 |
| hash join collected its output (step 2) | 450980407 | 450980407 |
| semi/anti join's inner side (step 4) | 259364815 | 259364815 |

The largest declared point became the second step's collection at 451.0 MB —
the same point it was before, now no longer outweighed by the collapse.

**What it did to RSS.** Nothing measurable. Paired plain runs, native release,
SF1, candidate against the §61 build `3bd799b`: control 601.7, 599.6, 602.4 MB
(median 601.7), candidate 596.4, 598.0, 599.9 MB (median 598.0). The 3.7 MB
difference is inside the spread this comparison has had all along (the same
build has measured 595.3–614.6 MB across §60 and §61). The chain bench over the
composed queries agrees: q3 306.2 → 306.9, q5 472.6 → 471.6, q7 521.4 → 515.2,
q9 661.3 → 660.4, q21 602.6 → 598.7 MB, two rounds each, answers identical.

**What that means.** The named peak was 521.7 MB of a roughly 600 MB process.
Taking 70 MB of it away left the process at the same high-water, so the
high-water is not at the collapse: it is reached earlier, at a moment no
checkpoint declares, or the freed blocks stay resident in the runtime. The gap
between the largest declared point and RSS says the same thing from the other
side — on the reverted build it is 82.6 MB at SF1 against 17.1 MB at SF0.1 and
28.1 MB at SF0.01, so the unnamed part grows with the data at the top end and is
now larger than one collapse copy.

**Reverted.** The change was correct and gate-clean, and it is kept only as this
measurement: freeing a copy early buys no resident byte, and the time it costs
sits on the hot path. This is §60's precedent — a change that moves no number
its contract promised is not a change to keep.

**Next.** Not another lever on this copy. Two things have to be found first:
where the high-water actually is (sample RSS at each checkpoint on native, so the
census can report the process peak beside the named total instead of implying
that its largest declared point is that peak), and what the 82.6 MB of unnamed
resident memory is (object overhead the batch estimate does not count — it sizes
a string as four bytes plus its characters — is the first candidate).

## 63. The high-water readout puts the peak at the collapse, and shows what the names miss (2026-10-29)

The contract ("The high-water readout contract", roadmap) was written first and
committed alone. Every census point now also records the process's resident KB
and its high-water KB, read from `/proc/self/statm` and `VmHWM` on native; the
report carries them per point and names the point whose sample was largest. On a
target without `/proc` the fields are absent rather than zero, and a `--mem` run
of q18 (no declared point) still prints nothing.

**q21 at SF1, no budget.** Nine points, in the order the executor reached them:

| point | named MB | resident MB | high-water MB |
| --- | --- | --- | --- |
| collected FROM tables | 139.2 | 228.3 | 231.7 |
| collected its output (step 1) | 378.4 | 442.7 | 487.2 |
| collapsed its output (step 1) | 472.3 | 530.7 | 536.5 |
| collected its output (step 2) | 430.1 | 522.0 | 545.4 |
| collapsed its output (step 2) | 497.5 | 577.4 | 599.1 |
| semi/anti join's inner side (step 4) | 247.3 | 458.2 | 599.1 |
| collapsed its output (step 3) | 246.0 | 493.1 | 599.1 |
| collected its output (step 3) | 240.6 | 489.5 | 599.1 |
| semi/anti join's inner side (step 5) | 222.3 | 335.0 | 599.1 |

The header names it: `high 613508 KB, peak at hash join collapsed its output
(step 2)`. That high-water is the same number the harness measures as peak RSS
for the run, so the two instruments agree, arrived at independently.

**What it says.**

- The peak is at the second chain step's collapse, as §61 said, and it is the
  point where the process's own high-water was set (536.5 → 599.1 MB across that
  point, and no later point raises it).
- The named total at that instant is 497.5 MB against 577.4 MB resident: about
  80 MB is not named by any checkpoint, and 92 MB less than the high-water,
  which was reached slightly before the sample (the copy or the last of the
  drain). The contract's "the total is a lower bound" holds, and this is what
  the bound is worth at the peak.
- Residency and named totals do not rank the same. The two semi/anti points are
  fifth and ninth by named bytes but hold 458.2 and 335.0 MB — 211 MB and 113 MB
  more than their names. Whatever retains those bytes is freed heap the runtime
  has not returned, or structures no checkpoint declares.
- Across §62's release, the named peak there fell 70 MB and the high-water did
  not move. Together the two measurements say the process peak is driven by what
  the run allocates and retains, not by the size of a particular live pair at a
  declared point: freeing a copy earlier does not lower a high-water that the
  allocator has already reached.

**One outlier.** One of five runs of the releasing build (§62) peaked at
497.2 MB, far below its other four (584–591 MB); the current build's five runs
were 589.9–606.5 MB. A single run is not evidence, and the medians are 585.9 and
598.0 MB, so the §62 conclusion stands, but the outlier says the allocator can
sometimes hand the released blocks straight back, and that is worth knowing
before the next lever is chosen.

**Next.** Not another release of this copy, and not another count: what the peak
responds to is the total the query allocates. The first shape to try is the
chain's intermediate collapse itself — `join_step` returns one batch, so a step's
collected output is always copied into a second allocation before the next step
probes it, and passing the batches through instead would remove the copy rather
than free it early. That needs its own contract and its own measurement.

## 64. 0.6.0 is released (2026-10-29)

The version claims, checked by `harness/check_release.py --tag v0.6.0`:
`moon.mod`, the library's `VERSION`, the test that pins it, the newest CHANGELOG
heading and the tag all say 0.6.0; the archive holds 243 files and none matching
a forbidden pattern.

- Tag `v0.6.0`, annotated, at `293a51e` (`chore(release): 0.6.0`), pushed to
  `main`; the GitHub release is
  <https://github.com/superbigcup325/moonlake/releases/tag/v0.6.0>.
- Consumer: the packaged archive, on a fresh registry and dependency cache, runs
  on native, wasm-gc and JS — version, CSV, Parquet raw and Snappy, DATE and
  NULL handling, `drop`, and four streamed shapes agreeing with the collected
  ones.
- CI on `main` at the release commit: 7 of 7 green (run 40870578658); the pages
  deployment of the same commit is green, and the local browser acceptance of
  the playground passes 16 of 16.
- mooncakes: `moon publish --dry-run` answered `202 Accepted — Dry run
  completed successfully`, and `moon publish` then answered `200 OK`; the
  registry now reports `Latest: 0.6.0`, `Versions: 7`, published 2026-10-29. A
  consumer fetching `0.6.0` from the registry (fresh index and dependency cache,
  no workspace override) passes on native, wasm-gc and JS with the same checks
  as above. Default `~/.moon` is read-only here, so both runs used a scratch
  `MOON_HOME` holding the credentials.

## 65. The chain hands its batches on, and the peak falls 58 MB (2026-10-29)

The contract ("The chain without a collapse contract", roadmap) was written
first and committed alone (`1fc6398`). `join_step`, `join_semi`, `join_swapped`
and `join_or_spill` now return `Array[DataBatch]`, and the chain's state between
steps is that array: a step's collected output goes to the next step's probe
side without being copied into one batch. The census obeying §61's rule, nine of
q21's declared points became six — no step declares a collapse it no longer
makes.

**q21 at SF1, no budget, three interleaved runs each.** Peak RSS, and the
`--mem` high-water that agrees with it:

| run | 0.6.0 | this build |
| --- | --- | --- |
| 1 | 591.6 MB | 545.9 MB |
| 2 | 604.9 MB | 546.7 MB |
| 3 | 606.0 MB | 547.2 MB |
| median | 604.9 MB | 546.7 MB |

That is 58.2 MB (−9.6%) and inside the contract's predicted 540–560 MB. The
census's header now reads `high 560324 KB, peak at hash join collected its
output (step 2)`, and its six points are:

| point | named MB | resident MB | high-water MB |
| --- | --- | --- | --- |
| collected FROM tables | 139.2 | 234.3 | 234.3 |
| collected its output (step 1) | 378.4 | 443.6 | 488.8 |
| collected its output (step 2) | 430.2 | 539.0 | 547.2 |
| semi/anti join's inner side (step 4) | 247.4 | 508.8 | 547.2 |
| collected its output (step 3) | 240.6 | 502.2 | 547.2 |
| semi/anti join's inner side (step 5) | 222.3 | 363.5 | 547.2 |

The largest named point is the one the contract predicted, at the size it
predicted (430.1 MB, measured 430.2); its residency fell with the peak (577.4 →
539.0 MB at the old peak's point). What it cost is what §63 said it would cost:

- **The invariants did not move.** q1 and q12 (single-step compositions), q18 and
  q20 (pulled shapes) sit inside the spread, and every row of the matrix answered
  byte for byte; q6 is covered by the goldens (33), which pass on the same commit
  as the unit suites (406 wasm-gc, 420 native), `harness/check_cli.sh` and
  `harness/spill_accept.sh`.
- **The budget path is where the collapse is still needed, and it was measured.**
  Handing a step's output on as batches to a *partitioner* is not free: a
  partitioner slices every input batch into every partition (256 `take_rows`
  per batch), so a chain whose steps hand on ~500 batches made q7 at 16 MB run
  35.6 s against 8.0 s and peak at 2122 MB. Collapsing both sides inside the
  partitioner instead cost q3 +86 MB and q5 +160 MB, because the build side is a
  table's own scan batches and copying it is new. Collapsing only the handover,
  still inside the partitioner, cost q21 +98 MB: the caller still holds the
  batches while the copy exists, so both are resident. The collapse therefore
  stays at the producer for a budgeted run (`collapse_handed`, `collapse=true`),
  which is where it was, and the win is confined to the runs that never
  partition — exactly the shape the contract named.

**The matrix.** `harness/bench_join_chain.py --budgets none,16M --rounds 3`
against a 0.6.0 binary built from the tag, median peak RSS in MB, worst
round-to-round spread 15%:

| case | no budget | 16 MB |
| --- | --- | --- |
| q3 | 295.2 → 295.7 | 257.7 → 257.2 |
| q5 | 466.8 → 468.6 | 443.0 → 443.0 |
| q7 | 517.9 → 405.9 | 531.0 → 527.9 |
| q8 | 467.8 → 467.0 | 498.5 → 498.1 |
| q9 | 659.6 → 661.1 | 659.7 → 660.1 |
| q10 | 234.0 → 233.8 | 241.7 → 241.1 |
| q11 | 27.4 → 25.3 | 25.5 → 25.5 |
| q18 | 140.2 → 140.5 | 67.4 → 71.4 |
| q20 | 98.1 → 93.0 | 84.5 → 85.4 |
| q21 | 596.2 → 547.0 | 661.6 → 673.2 |
| q1 | 35.4 → 35.3 | 72.9 → 75.4 |
| q12 | 35.3 → 35.4 | 35.4 → 35.4 |

Every wall time stayed inside its spread (no-budget q21 7.84 → 7.67 s, q7 3.19 →
3.50 s; 16 MB q21 14.03 → 13.98 s, q7 8.22 → 8.07 s), and every answer was
byte-identical between the two binaries. Two rows moved beyond what a chain's
own intermediates explain: q7 without a budget fell 112.0 MB, because its
step 3 collects a 174.5 MB probe output that is no longer copied, and q21 at
16 MB rose 11.6 MB (1.8%, inside the spread but consistent across runs) — the
collapse now happens after the grace path returns instead of inside the step,
which holds the partition outputs and the merged batch at once for a moment.

**What is left.** The peak is still unnamed for about 109 MB (539.0 MB resident
against 430.2 MB named) — more than any single structure the census declares, so
attributing it is the next contract's first question. Of the named parts, the
two largest are the previous step's output arriving as the probe input (174.5 MB,
a materialized intermediate the eager path needs) and the tables themselves
(`collected FROM tables`, 145.9 MB), which §61's rule keeps alive for the whole
chain: 61.0 MB of them — lineitem's narrowed copy (60.7) and supplier's (0.3) —
belong to tables whose last step has already run by that point. That lifetime is
what the next contract is about. What a scan keeps while it narrows is already
answerable from the code and was checked: a lazy source decodes only the
projected columns, so a scan holds one batch's working set, not a table's.

## 66. A step lets go of the tables it finished with, and the peak falls to the step before (2026-10-29)

The contract ("The table lifetime contract", roadmap) was written first and
committed alone (`f02f7d4`). When a step completes, the tables whose last step it
was are released — the left-deep plan names each table in the step that joins it
and nothing re-scans — and the census counts and names only the tables still
alive at each point.

**q21 at SF1, no budget, three interleaved runs each.**

| run | `a56517e` | this build |
| --- | --- | --- |
| 1 | 560.1 MB | 488.3 MB |
| 2 | 551.2 MB | 491.2 MB |
| 3 | 550.6 MB | 492.1 MB |
| median | 551.2 MB | 491.2 MB |

−60.0 MB, and the contract's prediction held on every part of it: the named total
at the peak 430.2 → 372.0 MB (predicted 369.2), the resident sample 539.0 →
480.1 MB (predicted about 478), and the high-water 547.2 → 488.3 MB, at the
bottom of the predicted 490–547 MB band rather than the middle.

**Why the high-water followed, which §62 could not answer.** The release happens
after the first step and before the allocations that used to set the peak, and
the census shows exactly where the peak went: it is now at the *first* step's
point, where the high-water was already 488.8 MB in §65 and is 488.3 MB here — the
second step's collection, which used to reach 547.2 MB, now stays below what the
first step had already reached. §62 released a copy *after* the peak and the
high-water did not move; this releases 61.0 MB *before* it and the allocator
reuses them. Both results are the same rule, seen from the two sides.

**The lifetime, point by point.** `collected FROM tables`, the root a step's
point names, as the chain gives tables up (this build, q21, no budget):

| point | tables still alive | named MB | resident MB | high-water MB |
| --- | --- | --- | --- | --- |
| collected FROM tables | all six | 139.2 | 234.6 | 234.6 |
| collected its output (step 1) | all six | 378.1 | 447.7 | 488.3 |
| collected its output (step 2) | lineitem and supplier gone | 372.0 | 480.1 | 488.3 |
| semi/anti join's inner side (step 4) | orders gone | 182.9 | 439.9 | 488.3 |
| collected its output (step 3) | nation gone | 176.2 | 433.2 | 488.3 |
| semi/anti join's inner side (step 5) | `__semi0` gone | 112.1 | 258.3 | 488.3 |

The root falls 145.9 → 84.9 → 78.3 → 30.3 MB as the chain lets go: lineitem's
narrowed copy (60.7) and supplier's (0.3) after the first step, orders (6.6)
after the second, nation (44 B) after the third, `__semi0` (48.0) after the
fourth. The peak's names are honest now: what is alive at 488.3 MB is named down
to 372.0 MB, and the 108 MB that is not named does not change — the unnamed
quantity was never a table.

**The matrix.** `harness/bench_join_chain.py --budgets none,16M --rounds 3`
against an `a56517e` binary built from the commit, median peak RSS in MB, worst
round-to-round spread 18%:

| case | no budget | 16 MB |
| --- | --- | --- |
| q3 | 302.2 → 302.9 | 261.4 → 245.4 |
| q5 | 469.6 → 468.8 | 445.5 → 436.0 |
| q7 | 409.4 → 321.6 | 523.6 → 436.1 |
| q8 | 468.5 → 466.3 | 499.1 → 499.1 |
| q9 | 662.4 → 652.0 | 661.4 → 661.2 |
| q10 | 237.2 → 237.1 | 245.2 → 195.3 |
| q11 | 27.3 → 25.4 | 25.5 → 25.5 |
| q18 | 145.3 → 144.9 | 67.5 → 67.3 |
| q20 | 99.3 → 93.3 | 86.8 → 73.5 |
| q21 | 550.7 → 493.3 | 677.1 → 583.5 |
| q1 | 35.3 → 35.3 | 73.3 → 75.4 |
| q12 | 35.3 → 35.4 | 35.5 → 35.6 |

Every answer is byte-identical and every wall time is inside the spread. The
budget path was not predicted to gain and did: q21 at 16 MB fell 93.6 MB, q7
87.5 MB and q10 49.9 MB, because a spilled step's probe side is read from the
partition runs and the tables it finished with were still being held. q1 and q12
single-step invariants did not move; q3, q5, q8, q9 and q18 sit inside the
spread.

**Gates.** 33 goldens, 408 wasm-gc and 422 native unit tests (the two new ones
cover the per-step release and a table named by two steps), `harness/check_cli.sh`
and `harness/spill_accept.sh` pass; `moon info` shows no interface change.

**What is left.** The peak is still unnamed for 108 MB (480.1 MB resident against
372.0 MB named) — unchanged by this round, which is the point: it was never a
table. What the census does name at the peak is dominated by the previous step's
output arriving as the probe input (174.5 MB), which is the eager path
materializing a chain's intermediates. Lowering that means composing q21's chain
rather than passing its rows through a materialized array, and that is a
different contract.

## 67. A field ends at a word's edge, and a batch is 1024 rows (2026-10-30)

Every round before this one measured memory. Wall time had not been looked at
since the CSV reader landed, and a TPC-H query at SF1 spends most of its time
there: `SELECT count(*)` over lineitem — index the file, decode nothing — took
4.3 s against a directory the page cache serves at 4.8 GB/s, so ~180 MB/s of the
engine's own work sat between the file and the count. Three things were in that
gap, and the census could not see any of them because none of them allocates
anything of size.

**A field's end, eight bytes at a time.** An unquoted field body ends at the first
`,` or newline, and the scan walked to it one byte per iteration: 773 MB of
per-byte `if`s, the largest single cost of a scan. It now reads a word, xors with
each separator, uses the borrow trick for a zero byte, and takes the lowest set
bit of the mask. A byte *above* a match can show a high bit too — a 0x01 byte
whose borrow came out of a lower zero byte — which is harmless here because the
caller wants the first delimiter and the lowest set bit is always a real one.
That is the only subtle step in the change and it is why the helper carries a
comment rather than a name.

**A quoted cell is remembered, not flagged.** The index wrote a quoted/unquoted
flag per cell so that a rare quoted field could be found again: 96M writes on
lineitem to answer a question the TPC-H fixtures always answer "no". The scan now
records only the cells that were quoted, ascending, and a lookup is a binary
search over that list — zero entries for these files, a handful for the reader's
own quoted fixtures. The cell-emptiness test asks the width first (`e - s == 2`)
so the search only runs for two-byte cells.

**A batch is 1024 rows.** `SCAN_BATCH_ROWS` was 4096. The sweep below says the
knob is a cache question, not a call-overhead question.

| rows | `count(*)` | q21 | q9 | q1 |
| --- | --- | --- | --- | --- |
| 16384 | +35.2% | +24.5% | +19.0% | |
| 2048 | −23.0% | −14.2% | | |
| 1024 | −24.6% | −17.5% | | −7.0% |
| 512 | −26.2% | −17.0% | −17.3% | |

16384 is the direction to remember: bigger batches made every query a fifth
slower, because a batch's columns stop fitting in cache while the engine walks
them. 1024 and 512 sit within noise of each other and 1024 keeps half the
per-batch work, so 1024 is the setting landed.

**Numbers.** The bench harness, control `b3d3ae0` against this build, both on SF1
with no budget and three rounds, interleaved:

| case | wall `b3d3ae0` | wall this build | | peak RSS |
| --- | --- | --- | --- | --- |
| q1 | 9.64 s | 8.31 s | −13.8% | 35.2 → 29.2 MB |
| q7 | 8.15 s | 7.02 s | −13.9% | 325.9 → 325.7 MB |
| q9 | 9.41 s | 7.78 s | −17.3% | 652.3 → 670.7 MB |
| q21 | 19.58 s | 16.68 s | −14.8% | 501.2 → 492.1 MB |

The host was not quiet — the harness waited for load under 2.5, timed out at 3.13
and said so — so the absolutes are inflated roughly 2.7x and only the ratios are
read: every case is interleaved, so the load lands on both builds. Peak RSS did
not move for two of the four and moved 18 MB either way for the others, inside the
6% spread across rounds; this round is not about memory. What the smaller batch
does to the census numbers has not been measured, and it is the first thing to
re-baseline, because `--mem` names batches and there are now four times as many of
them.

**Gates.** Both scan changes were checked separately: 33 golden comparisons each
(22 TPC-H + the parquet variant + the reader's encoding and multi-row-group
fixtures, plus the external-sort / grace-join / grace-aggregation equivalence
checks), `moon test` 408/408 — including the quoted-field, quoted-newline and
encoding-variant tests, which is what the sparse list had to keep true — and after
the batch change `harness/check_cli.sh` and `harness/spill_accept.sh`, the latter
being the one that could have broken: 1024-row batches mean four times as many
spill files. Two tests pinned 4096 rows a batch; they now derive their numbers
from the constant, so it can move again without a test edit.

**What is left.** The index still writes two offsets per cell (start and end),
which is 768 MB of writes for lineitem; one of them is derivable from the other
when a chunk has no CRLF and would have to fall back for one that does.
Pre-sizing those arrays from the previous chunk's cell count instead of letting
them double was measured and is 2.8-5.5% *slower*: a 4 MB array made eagerly per
chunk costs more than the doubling chain it saves, so the allocator's growth is
cheaper than the arithmetic suggests.
`check_width` still makes a second pass over the rows to verify their cell
counts against the header — one subtraction a row, so a cheap pass the clock
probably cannot see — which the scan could count as it goes. And q21 scans lineitem three times — the outer
chain plus the two decorrelated `EXISTS`/`NOT EXISTS` sides — which is a planner
question worth about as much as everything in this round.

## 68. A batch is 2048 rows, because 1024 cost the budget path its peak (2026-10-30)

§67 landed 1024 rows a batch from a sweep that only ran without a budget, on a host
that was not quiet. The first quiet-host matrix (load 1.5-1.7, bench harness, three
interleaved rounds) caught what that sweep could not see.

**The regression, isolated.** `main` against `63eafd3` (the same scan changes, 4096-row
batches), 16 MB budget: q3 245.4 -> 275.3 MB, q5 439.2 -> 505.2, q8 503.3 -> 579.3, q9
664.1 -> 765.1, with wall +8% to +18% on q3/q5/q8/q9; q7 and q10 unmoved; answers
identical. Without a budget the same pair is 3-6% *faster*, so the batch change is
the whole of it. The mechanism is the partitioner: `partition_side` and
`PartitionPool::add` slice each input batch into up to 256 pieces with `take_rows`,
and `estimate_batch_bytes` charges a piece 16 bytes plus 4 per column of overhead,
so four times as many input batches make four times as many pieces whose real cost is
not counted. That is inferred from the code and the isolation, not measured
directly.

**Two other prices.** Writing SF1 lineitem as Snappy Parquet takes one row group per
batch, so the batch size is also the row-group size: 303.2 MB at 4096, 322.5 MB at
1024 (+6.4%), 310.7 MB at 2048 (+2.5%); plain is +0.9% at 1024. Write time moved
about 4%. The README and ROADMAP claim 4,096-row groups; they now describe the
batch size.

**2048 against 1024, quiet host, three rounds.**

| case | 16 MB peak 1024 -> 2048 | 16 MB wall |
| --- | --- | --- |
| q3 | 275.3 -> 262.8 MB | 3.35 -> 3.12 s |
| q5 | 505.2 -> 459.2 MB | 4.89 -> 4.35 s |
| q8 | 579.2 -> 530.1 MB | 5.07 -> 4.49 s |
| q9 | 765.2 -> 699.2 MB | 8.03 -> 7.29 s |
| q21 | 600.1 -> 598.9 MB | 12.43 -> 12.12 s |

Without a budget every case is within 2% either way (q21 5.51 vs 5.61 s, q9 2.45 vs
2.49 s, q1 2.55 vs 2.61 s). Against 4096 the 16 MB path still pays something at 2048
(q9 664 -> 699 MB, q5 +20 MB), which is the price of the no-budget gain.

**The quiet-host numbers for the whole round (1024, control `b3d3ae0`, no budget):**
q3 2.32 -> 1.90 s, q5 2.34 -> 1.95, q7 2.75 -> 2.37, q8 2.24 -> 1.86, q9 2.92 -> 2.51,
q10 2.93 -> 2.63, q18 4.22 -> 3.44, q21 6.61 -> 5.61, q1 2.79 -> 2.59 s: 8-19%, so the
loaded-host ratios in §67 held. 2048 sits within about 2% of those.

**What is left.** The real fix is to count a partition piece's overhead, or to
coalesce small batches before partitioning, so the batch size stops being a memory
knob; the earlier no-collapse rounds say coalescing has its own cost, so it is a
separate contract. The full no-budget memory matrix has not been re-baselined at 2048.

## 69. The matrix at 2048 rows a batch (2026-10-30)

§66's 24-row matrix was measured with 4096-row batches and §68 changed the batch
size, so this is the whole matrix again: `main` (2048 rows, `70b60fc`) against
`63eafd3` (the same scan code, 4096 rows), SF1, load 1.59, three interleaved rounds,
every answer byte-identical. The worst peak-RSS spread across rounds was 15%, so a
difference under about 15 MB on the large cases is not read.

| case | no budget peak, 4096 -> 2048 | no budget wall | 16 MB peak | 16 MB wall |
| --- | --- | --- | --- | --- |
| q1 | 35.3 -> 29.3 MB | 2.70 -> 2.62 s | 73.4 -> 73.4 | 5.16 -> 5.07 s |
| q3 | 306.7 -> 310.9 | 2.01 -> 1.92 | 247.0 -> 262.9 | 3.04 -> 3.13 |
| q5 | 478.7 -> 481.1 | 2.03 -> 1.93 | 439.4 -> 459.2 | 4.18 -> 4.39 |
| q7 | 326.1 -> 326.2 | 2.58 -> 2.42 | 445.5 -> 445.7 | 6.94 -> 7.02 |
| q8 | 474.7 -> 476.9 | 1.96 -> 1.87 | 501.2 -> 530.2 | 4.24 -> 4.51 |
| q9 | 662.5 -> 666.9 | 2.63 -> 2.50 | 663.8 -> 699.0 | 6.60 -> 7.23 |
| q10 | 237.2 -> 236.9 | 2.71 -> 2.63 | 195.4 -> 176.2 | 3.68 -> 3.74 |
| q11 | 25.3 -> 25.4 | 0.32 -> 0.30 | 25.5 -> 25.6 | 0.29 -> 0.27 |
| q12 | 35.4 -> 35.3 | 2.56 -> 2.48 | 35.6 -> 35.6 | 2.57 -> 2.48 |
| q18 | 145.2 -> 148.7 | 3.65 -> 3.51 | 79.5 -> 73.5 | 3.74 -> 3.65 |
| q20 | 102.0 -> 98.2 | 2.21 -> 2.15 | 74.9 -> 74.9 | 2.28 -> 2.29 |
| q21 | 508.9 -> 504.9 | 5.92 -> 5.65 | 600.7 -> 605.8 | 11.37 -> 11.44 |

**Without a budget** nothing moved in memory beyond the spread and every case is
2-6% faster (q21 -4.6%, q7 -6.2%, q9 -4.9%). The §66 numbers (q21 491 MB at the
time) still stand as the same shape: q21 is 504.9 MB here, inside the spread of
the 491-509 MB this build has shown across rounds.

**Under 16 MB** 2048 rows still costs against 4096: q9 +35 MB and +9.5% wall, q8
+29 MB and +6.4% wall, q5 +20 MB, q3 +16 MB; q10 fell 19 MB. That is the price §68
named, now measured over the full set, and it is concentrated in the shapes that
partition a large input (q3, q5, q8, q9). It is the argument for making the
partitioner count its pieces rather than for a smaller batch.

**What is left.** The census (`--mem`) numbers per point have not been regenerated
at 2048 rows; only the process peaks above were.

## 70. A partition piece is counted at what it costs (2026-10-30)

The contract ("The partition piece cost contract", roadmap) was written first and
committed alone (`8c0c570`). §68 and §69 had left the 16 MB path paying for 2048-row
batches (q9 +35 MB, q8 +29, q5 +20, q3 +16) with the mechanism inferred; the contract
said to measure the per-piece cost before changing anything.

**The probe.** Allocate many pieces of a few rows and columns, keep them alive, read
resident bytes from `/proc/self/statm` before and after. One shape per process,
because a first run that put every shape in one process reused freed pages and
reported zero and negative overheads. Fixed cost beyond the cells and validity bytes
(5 a cell on `Int32`):

| rows | cols | bytes a piece | fixed overhead |
| --- | --- | --- | --- |
| 1 | 2 | 283 | 273 |
| 8 | 2 | 377 | 297 |
| 32 | 2 | 629 | 309 |
| 1 | 6 | 535 | 505 |
| 8 | 6 | 818 | 578 |
| 32 | 6 | 1594 | 634 |

Across these shapes that is about 157 bytes a piece and 58-70 a column (the
overhead creeps up with rows because the allocator rounds), against the 16 and 4 the
estimate charged. The hypothesis held: for a piece of a few dozen rows the uncounted
part is the larger part.

**The change.** `estimate_batch_bytes` starts at 160 and adds 64 a column, in two
named constants whose comment records the fit. Nothing else moved: not the
partition counts, the flush rule, the batch size or any coalescing.

**Full matrix, SF1, quiet host (load 1.49), three interleaved rounds, against
`156a03d` (2048 rows):**

| case | 16 MB peak | 16 MB wall |
| --- | --- | --- |
| q3 | 262.9 -> 237.3 MB | 3.15 -> 3.12 s |
| q5 | 459.2 -> 415.2 | 4.35 -> 4.31 |
| q8 | 530.2 -> 471.1 | 4.50 -> 4.49 |
| q9 | 699.2 -> 619.1 | 7.31 -> 7.30 |
| q7 | 442.3 -> 443.0 | 7.01 -> 6.98 |
| q10 | 176.7 -> 175.5 | 3.99 -> 4.02 |
| q21 | 598.3 -> 597.3 | 12.25 -> 12.17 |
| q1, q11, q12, q18, q20 | within the spread | within the spread |

Without a budget every peak and wall time is inside the spread (worst peak spread
across rounds 11%), because the estimate is only read by budgeted paths. Every
answer is byte-identical. The contract predicted closing half of each §69 gap; the
four named peaks closed all of it and went 20-80 MB past it, below the 4096-row
figures (q9 663.8 MB then). One caveat on q10: an earlier run of the same pair put it
at 175.9 -> 195.3 MB, and the 4096 build showed 195 MB while the 2048 builds showed
176, so that case moves between two levels from run to run and is not read here.

**Gates.** 33 goldens, the external-sort / grace-join / grace-aggregation
equivalence checks, `harness/check_cli.sh`, `harness/spill_accept.sh`, and 408
wasm-gc and 422 native unit tests. Four tests had to change, and why is the point:
three composed-join tests ran at a 64-byte budget and the grace-join flavor test at
2048, and once a piece is counted at its cost a 64-byte budget cannot hold one, so
the grace join correctly refuses with its one-key-dominates error. A sweep found 512
as the smallest budget at which all three composed-join tests still pass and still
force the spill (768 stopped forcing it in one), and the flavor test uses 4096.

**What is left.** The estimate still ignores the validity array, one byte a cell on
every column at every batch size; that is a per-row undercount that would move every
spill threshold at once, so it stays a separate contract. The `--mem` census has not
been regenerated at 2048 rows. And the 16 MB path still pays its larger gap on q21,
which scans lineitem three times.

## 71. A table named twice is decoded once (2026-10-30)

The contract ("The shared table scan contract", roadmap) was written first and
committed alone. Before the change, on a quiet host (load 1.60, best of three, SF1),
q21 without its two subqueries took 3.23 s, with the EXISTS 4.30 s and in full
5.78 s, and one bare `SELECT count(*)` over lineitem took 1.11 s: each repeated scan
cost about what a bare scan costs, because each one indexed the same 773 MB again.

**The change.** `share_repeated_scans` walks the statement once for the tables it
names and the column names it mentions, and for a lazy table named at least twice
whose mentioned columns are a strict subset of its width it registers a `SharedScan`
source in a per-query catalog. The first open decodes the union of those columns
for every row and keeps the batches; later opens project them. The catalog entry is
not mutated, a second query starts empty, and a budgeted run shares nothing. An
EXISTS select list is not walked (`select *` there names nothing), and a window or a
bare `*` elsewhere turns sharing off for the statement.

**What the first matrix found.** The first build moved q11, which the contract had
not listed: wall 0.30 -> 0.40 s (+33%) and +18 MB. Taking each table alone cost
nothing and only the q11 shape, one subquery joining all three tables, was slow. A
trace of `SharedScan::open` showed partsupp being opened four times for two names:
the engine opens a table more often than the statement names it, so once the
expected opens were used up and the cache dropped, each further open refilled the
cache, decoding the whole union and holding every batch for a reader that gained
nothing. A further open is now passed straight through to the inner source. With
that, q11 is 0.276 -> 0.268 s and the q11-shaped query 0.257 -> 0.257 s.

**Full matrix, SF1, quiet host (load 1.24), three interleaved rounds, against
`b62918b`, no budget:**

| case | peak | wall |
| --- | --- | --- |
| q21 | 504.3 -> 503.8 MB | 5.30 -> 2.94 s (-44.5%) |
| q18 | 149.4 -> 231.3 MB | 3.30 -> 2.15 s (-34.8%) |
| q11 | 27.3 -> 45.3 MB | 0.28 -> 0.28 s |
| q20 | 99.3 -> 92.9 MB | 2.02 -> 2.07 s |
| q1, q3, q5, q7, q8, q9, q10, q12 | within the spread | within the spread |

Under 16 MB every peak and wall time is inside the spread (the cache is off under a
budget), and every answer is byte-identical. The contract predicted q21 at 3.7-4.2 s
and a peak at most one cache higher; it landed at 2.94 s with no peak change at all,
because the cache is let go after the last expected open, before the outer chain
reaches its step-1 peak. The wall time came from skipping the index, not only the
decode: the later scans now cost a projection of arrays that are already decoded.

**The price is q18.** Its scalar subquery scans lineitem twice, so the decoded
columns stay alive between the two scans: +81.9 MB of peak for -1.15 s. That is
inside the contract's bound (the cache is at most 120 MB) and the contract said
q18 would move, but it is a real memory cost bought for time, and q11 pays 18 MB the
same way.

**Gates.** 33 goldens, the external-sort / grace-join / grace-aggregation
equivalence checks, `harness/check_cli.sh`, `harness/spill_accept.sh`, and 409
wasm-gc and 423 native unit tests; the new one runs EXISTS and NOT EXISTS over a
table named twice and compares the shared answer with the budgeted (unshared) one.

**What is left.** The `--mem` census does not name the cache, so q18 and q11 hold
memory it cannot see; the contract said it must, and that is owed. The semi sides
still run before the outer query exists, so a tee that indexes each chunk once and
delivers it to every scan would avoid the cache entirely; that is the contract the
roadmap left open. The sharing is by column name and deliberately wide, so a table
with a same-named column in two scans decodes it once for both.

## 72. The census names the shared scan cache (2026-10-30)

The contract ("The census names the shared scan cache contract", roadmap) was written
first and committed alone (`0011f97`). It owed two things: `--mem` had to name the cache
§71 added, and, found while reading the call sites, `mem_report_with` and
`explain_analyze_with` had been calling `run_parsed` without `share_repeated_scans`, so
`--mem` and `--analyze` ran the unshared plan while the plain query ran the shared one.

**The change.** Both measuring entry points now build the same per-query catalog as the
plain ones. `MemCensus` keeps a list of live roots (a name and a function returning
bytes now); `observe` reads each at the moment a point is kept and names the ones that
hold anything, so a root appears exactly while it is alive and nothing a point records
keeps it alive. `share_repeated_scans` registers one root per shared table
(`shared scan cache (<table>)`) when a census is present. Plain runs build no census
and are not touched.

**What the contract got wrong.** It predicted the cache would be named at the existing
points between q18's two scans. It is not: q11 and q18 reach no declared point at all
(`--mem` printed nothing for either, before and after the entry-point fix), and q21's
cache is alive only inside the decorrelated sides, which have no point either, and is
gone before the outer chain's first point. A root that is only read at existing points
would therefore never have shown anywhere. So the cache gets one declared point of its
own, kept when it is filled (`shared scan cache filled (<table>)`), where the roots are
read and the cache is by definition alive.

**What `--mem` now says (SF1, no budget):**

| query | point | named |
| --- | --- | --- |
| q18 | shared scan cache filled (lineitem) | 72,858,708 bytes |
| q21 | shared scan cache filled (lineitem) | 97,238,736 bytes |
| q11 | filled (partsupp) | partsupp 16,162,656, supplier 81,440 |
| q11 | filled (nation) | partsupp 16,162,656, supplier 81,440, nation 665 |

q18's 72.86 MB is 1.2% from the 72 MB the contract worked out (6,001,215 rows of
`l_orderkey` and `l_quantity`), and against the 81.9 MB of peak §71 measured it leaves
about 9 MB, the validity bytes the estimate does not count. q21's cache is 97.2 MB
(four columns) and its outer-chain points are unchanged: step 1 398,348,765 bytes
and step 2 391,367,971, identical to before, which is the census's version of why its
peak did not move. The cache is absent from every point after its drop.

**What the census still cannot do.** Its high-water is not the plain run's peak: q18
reports 138 MB where the plain run peaks at 231 MB, because the census sees only the
points it declares and q18's pulled shape declares none besides this one. The contract
predicted the two would agree; they do not, and the unnamed remainder is the finding.

**Nothing else moved.** Full plain matrix against `31233bb`, SF1, quiet host (load
1.70), three rounds: no budget and 16 MB, every peak and wall time inside the spread,
every answer byte-identical. A census of a query that names no table twice is
unchanged.

**Gates.** 33 goldens, grace/external equivalence checks, `harness/check_cli.sh`,
`harness/spill_accept.sh`, 410 wasm-gc and 424 native tests; the new one checks the
cache is named for a table named twice and absent for a table named once and under a
budget.

**What is left.** The validity bytes in `estimate_batch_bytes`, so every named root is a
lower bound. The shapes that reach no declared point (q11, q18, the pulled queries) are
still mostly invisible to `--mem`; giving them points is a separate contract.

## 73. The pulled shapes keep census points (2026-10-30)

The contract ("The pulled shapes declare census points contract", roadmap) was written
first and committed alone (`3e0de51`). No benchmark or wall-time comparison was run for
this change, as the contract said: the host's timing was not stable, and everything
below is named bytes, which are deterministic, or answers.

**The change.** Three things. `run_agg_pull` and `run_join_agg_pull` keep a point,
`pulled fold finished`, when their fold returns, naming the finished groups
(`group result`) and, for a composed join, what the shape still holds. A composed
join also keeps `composed join fold started` once its build sides, padded copies and
cursors exist and before the first probe batch, naming `build sides`, `build copies`
and one `index arrays (step N)` per step. And the bind-time subquery runs (scalar, EXISTS,
IN) receive the census, so a point inside them is kept like any other.

**One deviation from the contract.** It planned live roots that borrow a cursor's index
and are removed when the fold ends. The code did not need them: `composed_entries` and
`pulled_fold_point` compute the bytes where the structures are alive and hand the census
numbers, so it never holds a cursor, no root is registered and `remove_root` was not
written. The rule it protected (a point never keeps a structure alive) holds more
simply.

**What `--mem` says now (SF1, named bytes):**

| query | point | named |
| --- | --- | --- |
| q1 | pulled fold finished | 1,096 (group result) |
| q11 | composed join fold started | 244,447 (build sides 81,743, build copies 80,591, two small indexes) |
| q11 | pulled fold finished | 640,458 (group result 358,104, index arrays step 1 120,004) |
| q18 | pulled fold finished | 90,858,996 (shared scan cache 72,858,708, group result 18,000,288) |
| q21 | all six labels and the cache point | identical to §72, to the byte |

q11 reaches 7 points now where it reached none of its own before.

**What the contract got wrong about q18.** It predicted q18 would keep a composed fold
point with the lineitem build side, a copy and an index, well above 150 MB. It keeps no
composed point at all: its outer join takes the swapped path (`--analyze` shows 9 rows
out of `orders`, 63 joined rows and 9 result rows), which declares nothing. The one
`pulled fold finished` it prints is the bind-time subquery's, the `GROUP BY l_orderkey`
over 1.5 million orders: 1,500,024 groups at 12 bytes is the 18.0 MB `group result`.
So the census high-water of q18 is 236,884 KB, 2.4% above the 231.3 MB peak the plain
matrix reported in §71 (that figure was not re-measured this round), and it is reached
at the subquery's point, where only 90.9 MB is named: about 146 MB of the resident sample
is the group state that is still growing, which nothing can size. The contract's
success criterion (high-water within 25% of the plain peak) is met, for a different
reason than it predicted, and its fallback is the finding: the next step is a group
state accessor, not another point.

**Gates.** 33 goldens, grace/external equivalence checks, `harness/check_cli.sh`,
`harness/spill_accept.sh`, 412 wasm-gc and 426 native tests (two new: a single-table
pulled aggregate keeps the point and names no build side, and a composed join-aggregate
names its sides and indexes while its answer matches the budgeted one). One check
changed on purpose: `check_cli.sh` asserted that a pulled aggregate prints no census,
which was the pre-change contract; it now asserts the point and the group result, and a
plain scan with no aggregate still prints nothing.

**What is left.** The group state while a fold grows (q18's unnamed 146 MB), the
swapped join path (`run_join_agg_swap`), which still declares no point, and the validity
bytes in `estimate_batch_bytes`. Every named total is a lower bound.

## 74. The census sizes the group state while a fold grows (2026-10-30)

The contract ("The group state is sized while a fold grows contract", roadmap) was
written first and committed alone (`db81f36`). It answered the 146 MB gap §73 left on
q18: the census named the finished groups but never the state the fold builds.

**The change.** `aggregate_seq` and `aggregate_cols` take an optional census and observe
one point per input batch, labelled `group state (fold)`, naming `key slots (estimate)`
(24 bytes a group, the join census's convention), `group keys` and `accumulators` (the
columnar arrays by element size, or the per-group arrays at an estimate), and
`input batch (estimate)`. The label is fixed, so the largest point is the end of the fold
(the arrays only grow). `fold_pulled` passes the census on; a plain run passes none and
executes exactly the old path.

**One deviation from the contract.** It said only the two pulled folds pass a census.
The swapped join-aggregate folds through the same `fold_pulled`, so it passes one too
(`run_join_agg_swap` gained the parameter): the path that declared no point at all now
reports its group state, which adds information and changes no fold.

**What `--mem` says now (SF1, named bytes):**

| query | point | named |
| --- | --- | --- |
| q18 | group state (fold) | 138,876,884 — cache 72,858,708, key slots 35,996,352, accumulators 17,998,176, group keys 11,998,784, input batch 24,864 |
| q18 | pulled fold finished | 90,858,996 (unchanged) |
| q11 | group state (fold) | 1,314,900 |
| q1 | group state (fold) | 95,560 (input batch 94,632, state 928) |
| q21 | all points | byte-identical to §73 |

The state itself (key slots + group keys + accumulators) is 65,993,312 bytes, inside the
contract's 60–80 MB prediction, and the point's total rose from 90.9 MB to 138.9 MB
against the predicted ~150 MB. q18's largest point is now also the point where the
resident sample peaks (236,880 KB), so the report names the peak rather than trailing it.

**The success criterion is not met, and the remainder is the finding.** The contract asked
for the named total to land within 25% of the resident sample at that point; 138.9 MB
against 236.9 MB is 58.6%. About 98 MB is therefore still unnamed at the peak, and none of
it is the group state the point names.

One component is known by arithmetic: `estimate_batch_bytes` counts cells and the fixed
per-batch and per-column overheads but not the validity array, so the cached 6,001,215
rows over two columns carry 12.0 MB (one byte a cell) the estimate omits (open since §70).
The rest is unattributed and this round does not guess at it. The largest candidate is the
group slot map: the point estimates it at the join census's 24 bytes an entry, 35,996,352
bytes for 1,499,848 groups, and a hash table that size can cost two or three times that,
which would be most of the gap. That is a hypothesis with no measurement behind it, not a
finding, and the honest next step is to measure the map's real per-entry cost — or name
its real size — rather than to add another point.

The CSV reader is *not* a candidate: it indexes one chunk at a time (`scan_rows` over the
current buffer), so its index arrays are sized by a 2048-row batch and not by the file.

**Gates.** 33 goldens, grace/external equivalence checks, `harness/check_cli.sh`,
`harness/spill_accept.sh`, 413 wasm-gc and 427 native tests (one new: a grouped pulled
fold keeps `group state (fold)` naming key slots and accumulators, an ungrouped one keeps
it too, and the answer equals the budgeted run's). Plain matrix against `b9ea01a`, SF1,
quiet host (load 1.75), three rounds, no budget and 16 MB: every peak and wall time
inside the 10% spread, every answer byte-identical.

**A note on what a census run now costs.** A fold over 1.5 million rows observes once per
batch, so q18's census keeps 2,942 points where it kept 2, and each observe samples
residency. That is a `--mem` run's cost, not a query's: plain runs build no census.

## 75. The slot map costs what it costs (2026-10-30)

The contract ("The slot map cost contract", roadmap) was written first and committed
alone (`162f71d`). It said the census's "twenty-four bytes an entry" was an unmeasured
guess and that q18's 98 MB gap was probably that number being wrong.

**The measurement.** One probe process per size, one size per process, filling the map
with sequential keys and reading `/proc/self/statm` before and after, three processes
each (the probe is a throwaway under a local scratch directory; it is not part of the
repository). Bytes per filled entry:

| n | `Map[Int64, Int32]` | `Map[String, _]`, keys allocated before the baseline |
| --- | --- | --- |
| 100,000 | 63 | 63 |
| 500,000 | 69 | 62 / 48 / 38 (unstable) |
| 1,500,000 | 60 | 60 |
| 3,000,000 | 48 | 53 |

Every figure was identical across its three processes to the byte, so the spread is the
map's doubling slack and the allocator's state, not measurement noise. Twenty-four bytes
was low by a factor of two to three.

**The change.** One constant, `SLOT_MAP_BYTES = 60`, at the million-entry scale the engine
works at, used by `IntKeyIndex::map_bytes`, `str_map_bytes` and the fold's
`key slots (estimate)` entry. Nothing else: `grep` showed no decision reads these numbers
(`join_agg_sides_bytes` sums batches, every budget is counted in `estimate_batch_bytes`),
and the matrix below confirms it empirically.

**What `--mem` says now (SF1, named bytes):**

| query | point | before | after |
| --- | --- | --- | --- |
| q18 | group state (fold) | 138,876,884 | 192,871,412 (key slots 35,996,352 → 89,990,880) |
| q18 | named / resident sample at the peak | 58.6% | 80.7% (192.9 MB against 239.0 MB) |
| q21 | hash join output (step 2) | 398,348,765 | 417,626,839 (index map 17,505,912 → 43,764,780) |
| q21 | named / resident sample | 77.1% | 80.9% |
| q1 | group state (fold) | 95,560 | 95,704 |
| q11 | every point | unchanged | unchanged (its maps hold a few hundred entries) |

q18's fold point now covers 80.7% of the resident sample there, so the contract's 70%
criterion is met, and the ~44 MB still unnamed is the validity bytes of §74 (12.0 MB by
arithmetic) plus the per-entry variation the single constant cannot follow.

**One criterion not met.** The contract asked for the cost to be stable within 10% across
sizes and processes. It is stable across processes (identical to the byte) and not across
sizes: 48 to 69 bytes is a 30% range, and one constant cannot be right at both ends. Sixty
is the value at the 1.5-million-entry scale of every large TPC-H case here; at three
million entries it over-counts by about 13%, and at five hundred thousand under-counts by
15%. The report says "(estimate)" for that reason, and the verification records the range
rather than implying a precision the measurement does not have.

**One deviation.** `str_map_bytes` names a `Map[String, Array[Int32]]`. Measuring that map
with the key strings included gave 84/96/92/79, which double-counts them because the helper
adds the key's length separately. Measured with the keys allocated before the baseline, the
entry costs the same as the integer map's at the larger sizes (60 at 1.5 million, 53 at
three million), which is what the helper now assumes; the 500,000-entry rows were unstable
for the reason the table shows.

**Gates.** 33 goldens, grace/external equivalence checks, `harness/check_cli.sh`,
`harness/spill_accept.sh`, 413 wasm-gc and 427 native tests. Plain matrix against
`ed4b9af`, SF1, quiet host (load 1.58), three rounds, no budget and 16 MB: every peak and
wall time inside the 10% spread, every answer byte-identical — which is the evidence that
the constants are report-only, as the `grep` said.

**What is left.** The validity bytes in `estimate_batch_bytes` (§70, 12.0 MB of q18's
remaining gap), a per-size rather than per-entry map estimate if anyone needs the precision,
the eager folds no census reaches, and the swapped path's own points.

## 76. The validity bytes were counted, measured, and reverted (2026-10-30)

The contract ("The validity bytes count contract", roadmap) was written first and
committed alone (`41eabb3`), and it allowed for this outcome: if a 16 MB case regressed
past the matrix's spread, the change would be reverted and the number that made the
tighter bound not worth it would be recorded. That is what happened, and worse than
predicted: one case aborted.

**The change, as implemented.** One line in `estimate_batch_bytes`: `total += n` before
the dtype's cell count, so an Int32 column counts 5 bytes a cell instead of 4, an Int64 9
instead of 8, a Bool 2 instead of 1. Both unit suites passed (413 wasm-gc, 427 native).

**What the matrix said** (SF1, against `8e32215`, quiet host load 1.64, three rounds):

| case | peak (MB) | wall (s) |
| --- | --- | --- |
| q5 16M | 415.3 → 415.3 | 4.10 → 4.19 |
| q7 16M | 446.0 → 444.8 | 6.60 → 6.63 |
| q8 16M | 471.3 → 481.5 | 4.27 → 4.35 |
| q9 16M | 619.2 → 629.2 | 6.89 → 7.08 |
| q10 16M | 195.5 → 173.6 | 3.71 → 3.75 |
| q21 16M | — | aborted |

The prediction was that peaks would fall slightly; two of them rose by 10 MB, because a
bigger estimate means more partitions and each partition keeps its own buffers. Wall
times rose 0.5 to 2.8% on the spilled cases. And q21 at 16 MB died with SIGABRT.

**The crash, and why it matters more than the timing.** Under the debug build the abort
is a `PanicError` at `Array::at[ColumnVector]` in `join_semi` (`exec_join.mbt:1363`),
reached from `join_step` inside `join_partitions`. A partition that ends up with no rows
on the inner side reaches `concat_batches([], [])`, which builds a batch with no columns,
and `eval_vec` then indexes a column that is not there. The crash is latent, not caused by
this change: a larger partition count only made an empty partition more likely, and any
query whose hash partitioning leaves one empty would have hit it. It is now the next
contract's job, and the estimate stays as it was until it is fixed.

**The other differing answers are not regressions.** q5, q7, q9 and q10 at 16 MB print
last-digit differences (55502041.16969999 against a control's 55502041.1697, for instance)
because a different partition count changes the order of a `sum` of doubles. The goldens
already accept that: `harness/compare.py` compares floats at 1e-9 relative tolerance, and
these differ at about 1e-16. The bench harness's `same` flag is an exact string comparison
across binaries, so it reports False and the report above should be read that way.

**What landed.** The contract, and this record. `estimate_batch_bytes` is back to its
previous form; no code from this round is in the tree.

**What is left.** Fix the empty-partition crash under its own contract, with a test that a
semi join over an empty inner partition returns the left rows (and its anti twin), then
re-attempt the validity bytes and re-measure; and the eager folds and the tee that §75
left open.

## 77. An empty grace partition no longer aborts the join (2026-10-30)

The contract ("The empty partition contract", roadmap) was written first and committed
alone (`c8a7028`). It was half of §76's finding: the validity-bytes change was rejected
because q21 at 16 MB aborted, and the abort was a latent crash that a bigger partition
count had simply made likely.

**The cause, in one line.** `join_semi` built its inner side with
`concat_batches(inner, [])`, and `concat_batches` only knows how wide to make an empty
batch from the dtype list it is handed. A grace partition with no build rows arrives as
zero batches, so the inner batch had no columns, and `eval_vec` — evaluating the step's
key expressions against it — indexed column zero of nothing. Every other
`concat_batches` call site in the engine passes a dtype list or is handed the single batch
it returns, which is why this was the only place.

**The fix.** One expression: the inner layout's dtypes,
`tail_dtypes(step.out_dtypes, step.right_width)`, the same derivation the probe side and
the residual state already use.

**The reproduction.** Two thousand distinct keys on one side, four keys on the other,
`--memory 512/1024/2048/4096`: the pre-fix build (`ffbbe7c`) aborts with `PanicError` at
every budget, the fixed build answers in all four, and its 16 MB q21 answer over SF1
compares equal to the unbudgeted one at `harness/compare.py`'s 1e-9 tolerance (100 rows).

**The test.** `engine/e2e_test.mbt`, "a semi join over an empty grace partition still
answers": the fixture above, four queries (IN, NOT IN, EXISTS, NOT EXISTS), each compared
against its unbudgeted answer at a 2048-byte budget. Run against `ffbbe7c` the test fails
(414 tests, 1 failed); on this change both suites pass — 414 wasm-gc and 428 native.

**The contract's second prediction, checked.** With §76's estimate re-applied locally and
uncommitted, q21 at 16 MB completes and returns the same 100 rows: the crash, not the
estimate, was the blocker. The estimate is not in this change — it still owes its own
measurement before it can land, and the peaks it raised are still on record.

**Gates.** 33 goldens with the grace-join equivalence checks, `harness/check_cli.sh`,
`harness/spill_accept.sh`, both unit suites. Plain matrix against `ffbbe7c` at no budget
and 16 MB, three rounds, quiet host (load 2.16, the noisiest of the session): every answer
identical, every peak and wall inside the 10% spread.

**What is left.** Re-attempting the validity bytes (now unblocked), the eager folds and
the swapped path's census points, and the tee.

## 78. The census names resident bytes, the budget keeps its own unit (2026-10-30)

The contract ("The resident bytes contract", roadmap) was written first and committed
alone (`dfea0ae`). It resolved the tension §74 to §76 kept circling: two numbers with
different jobs were sharing one definition.

**The split.** `estimate_batch_bytes` stays exactly as it was and stays the unit every
decision counts in — the budget, the partitioner, the sort's run sizing, the swap path's
check. §76's measurement is why: counting the validity byte in the bound bought 0.5 to
2.8% of wall time and two 16 MB peaks 10 MB higher. A new `resident_batch_bytes` adds the
validity array, one byte a cell, and only the census calls it.

**What moved.** Every place the census names a batch or a cache now reports resident
bytes: the fold's `input batch`, the join's `probe input`, `build copy`, `filtered build
scan`, `join output`, `collected output`, `collapsed output`, `inner copy`, `probe copy`,
`collected FROM tables`, the scan entries, the composed path's `build sides` and
`build copies`, the pulled fold's `group result`, and the shared scan cache's root. A
`grep` for the remaining callers of the old helpers is the proof of the split: the twelve
that are left are budget checks, partition counts, sort run sizing and the helpers
themselves.

**`--mem` before and after (SF1, named bytes):**

| query | point | before | after | named / resident sample |
| --- | --- | --- | --- | --- |
| q18 | group state (fold) | 192,871,412 | 204,877,938 | 86.5% (was 80.7%) |
| q18 | shared scan cache (lineitem) | 72,858,708 | 84,861,138 | the 12.0 MB was the validity of 6,001,215 rows |
| q21 | hash join output (step 2) | 417,626,839 | 483,146,786 | 93.8% of the peak sample, 99.7% of the sample at the point |
| q4 | semi/anti inner side (step 1) | — | 85,545,154 | 91.4% |
| q1 | group state (fold) | 95,704 | 110,012 | — |
| q11 | cache point | 16,244,761 | 19,464,811 | 41.9% |

q18's largest point covers 86.5% of the resident sample where it peaks; the 32 MB that
remain are the allocator's own overhead and the capacity slack of arrays sized by
doubling, which no report here counts and which keep every total a lower bound. q11 is
the one case that got *worse* as a fraction, because most of its footprint is partition
machinery the cache point does not name; the number is still more truthful than before.

**Two whitebox tests changed.** `engine/mem_wbtest.mbt` asserted the old numbers against
`batches_bytes`; they now compute their expectation with `resident_batches_bytes`, which
is the same assertion against the definition the census uses.

**Gates.** 414 wasm-gc and 428 native tests, 33 goldens with the equivalence checks,
`harness/check_cli.sh`, `harness/spill_accept.sh`. Plain matrix against `8f0b161` at no
budget and 16 MB, three rounds, quiet host: every answer identical, every peak and wall
time inside the 10% spread — the report moved, the engine did not.

**What is left.** The eager folds and the swapped path's census points, the tee, and the
allocator overhead that keeps totals lower bounds.

## 79. A budgeted join now says where its peak is (2026-10-30)

The contract ("The budgeted peak declares itself contract", roadmap) was written first
and committed alone (`bdb9105`). The observation that prompted it: with SF1 and
`--memory 16M`, q21 peaks at 598.5 MB and its no-budget peak is 504.9 MB, yet its census
declared one point — `collected FROM tables`, 183.6 MB — and no point ever sampled above
236 MB. (No `/usr/bin/time` on this host, so the 598.5 MB comes from a poller reading
`VmHWM` from `/proc/<pid>/status` while the process runs.)

**The change.** `join_partitions` declares a point per partition replay, naming the left
partition it read back, the build partition, and the output accumulated so far. The census
is threaded through `grace_join` from `join_or_spill`, which already had it. One observe
per partition: q21's 16 MB run declares 106 points, the same order as the fold's per-batch
points (§74), and only while a census runs.

**What `--mem` says now:**

| query (16 MB) | before | after |
| --- | --- | --- |
| q21 points declared | 1 | 106 |
| q21 largest point | `collected FROM tables` 183,597,619 | `spill partition replayed` 207,922,735 (output accumulated 201,628,368) |
| q21 resident sample at that point | 236,976 KB | 422,912 KB |
| q9 largest point | `collected FROM tables` 284,772,830, sample 396,576 KB | unchanged (its peak is a scan, not a replay) |
| q18 points | 1 | 1 (its budgeted plan partitions no join) |

**Where the 598.5 MB actually is.** The replay point's own sample is 423 MB — 71% of the
peak — and 97% of what it names is the accumulated output, which is the eager
materialization this engine's shape rests on. The remaining ~175 MB comes *after* the
replay: `collapse_handed` concatenates that whole output into one batch so the next step
or the eager path can read it, so the peak is very nearly the output plus its copy. That
is now attributable, which is what this round was for.

**One prediction not met.** The contract said the named total at the peak would cover more
than half of the 598.5 MB. It covers 34.7%: the point sees 423 MB of process and names
207.9 MB of it, because `resident_batch_bytes` estimates a batch's bytes and the replay's
batches are sized by capacity, not by live rows. The report's own rule — totals are lower
bounds and the resident sample is the hint — is what keeps this honest, and it is now on
the record with the number that missed.

**Gates.** 415 wasm-gc and 429 native tests (one new: the grace path names its replay and
the answer does not change), 33 goldens, `harness/check_cli.sh`,
`harness/spill_accept.sh`. Plain matrix against `317243b` at no budget and 16 MB, three
rounds on a host whose own round-to-round spread was 13% that evening: every answer
identical, and no case's candidate-against-control peak or wall time moved by more than
10% (the widest were q12's peak at 2 MB on 35 and q21's wall at 0.3%).

**What is left.** Bounding the accumulated output itself — the streaming join — which the
contract deliberately left out of scope; the eager folds' own points; and the tee.

## 80. The replay's batches stay collapsed, and the copy is the cheaper half (2026-10-30)

The contract ("The partition replay handover contract", roadmap) was written first and
committed alone (`bc8af5c`), and it named its own bar: keep the change only if it lowers a
16 MB case's peak by 10% or more without moving any 16 MB wall time past the spread.
Measured against `04738aa`, it does neither, so it was reverted.

**The change, as tried.** `join_or_spill` returned `grace_join`'s batches as they are
instead of collapsing them into one batch first, and the now-unused `collapse_handed` was
deleted. Nothing else moved.

**What it measured** (SF1, `--memory 16M`, peak from a `VmHWM` poller):

| case | control peak / wall | handed-on peak / wall |
| --- | --- | --- |
| q21 | 596.5 MB / 12.6 s | 545.1 MB / 17.5 s (−8.6%, +39%) |
| q9 | 619.1 MB / 7.6 s | 759.1 MB / 12.7 s (+23%, +67%) |
| q5 | 415.2 MB / 4.1 s | 415.4 MB / 4.4 s (flat) |

q21's peak did fall, by 8.6% rather than the 10% the bar wanted — the copy is real, but
the replay point's own sample is 423 MB of a 598.5 MB peak, so removing the copy cannot
reach the 28% the contract hoped for. q9 went the other way: handing on a hundred small
batches makes the *next* step's partitioner hold more at once, and its peak rose 23% while
its wall time rose 67%.

**Why that is the answer, not a surprise.** §65 already measured this trade from the other
side and chose the collapse; this round re-ran it with the replay's real output instead of
assuming, and got the same direction with larger numbers. The copy doubles the peak for one
moment, but the alternative costs every subsequent step's partitioner a copy per batch per
partition, which is worse at both peak and wall on the query that has the most steps (q9).

**What landed.** The contract and this record. `engine/exec_join.mbt` is back to `04738aa`
and no code from this round is in the tree.

**What is left.** The one version of this that could still pay — a collapse that writes
partitions into one destination as they finish, so the output never exists twice — which the
contract left open on purpose, and the fold's own eager copy.

## 81. A step whose build side fits the budget is not partitioned at all (2026-10-30)

The contract ("The one-sided spill contract", roadmap) was written first and committed
alone (`db94fee`). It said the budgeted path partitions both sides of every step that does
not fit, including a probe side it could have kept, and pointed at `join_step` already
streaming its probe one batch at a time. What it under-specified was the cheap half: a step
whose *build* side fits needs no partitioning at all.

**The change.** In `join_or_spill`, after the `total <= opts.budget` case and before the
grace path: if the build side alone fits the budget, join it in memory — the build is the
hash side, the probe streams past it, and the working set is the build plus its index plus
the output, which is a subset of what the `total <= budget` case next door already allows.
A RIGHT step is excluded: it builds from the accumulated side, so the check is not its
shape. The rule is `build * 2 <= budget`, not `build <= budget`, because the index is
roughly the build again: at `build <= budget` q18's 16 MB peak rose 20.3% (65.4 → 78.7 MB),
and at half that it rises 2.6% while every win below survives. That is the measured reason
for the factor of two.

**What it measured** (SF1, three rounds, matrix against `db94fee`, quiet host, worst
round-to-round spread 13.3%):

| case | peak | wall |
| --- | --- | --- |
| q7 64 MB | 451.7 → 437.1 MB (−3.2%) | 6.36 → 2.60 s (**−59.1%**) |
| q7 16 MB | 443.2 → 437.4 MB (−1.3%) | 7.18 → 4.33 s (**−39.7%**) |
| q21 64 MB | 608.9 → 546.9 MB (−10.2%) | 8.31 → 5.31 s (**−36.1%**) |
| q21 16 MB | 598.3 → 562.9 MB (−5.9%) | 12.50 → 8.87 s (**−29.0%**) |
| q10 16 MB | 195.4 → 189.4 MB (−3.1%) | 4.11 → 3.54 s (−13.9%) |
| q9 16 MB | 619.2 → 619.0 MB (flat) | 7.62 → 7.06 s (−7.3%) |
| q18 16 MB | 75.4 → 75.5 MB (+0.1%) | 4.09 → 4.06 s (flat) |

Every no-budget case is unchanged (they never take this branch), every other budgeted case
stayed inside the spread, and no peak rose. The `build * 2 <= budget` rule is what keeps
q18 there: at `build <= budget` its 16 MB peak rose 20.3% in the probe run before the rule
was tightened.

**Four answers changed their row order, none their content.** q5, q7 and q9 at 16 MB and q7
at 64 MB now emit rows in probe order where partitioning used to emit them partition-major.
Checked as multisets with 9-significant-digit canonicalisation: q5 6 rows, q7 5 rows, q9
176 rows, equal to both the control's budgeted answer and the unbudgeted answer in every
case. The goldens, which carry their own ORDER BY, all pass. This is the harness's `same`
flag doing its job — a changed order is visible — and the reason the check above exists.

**One test moved for the right reason.** "a budgeted join names the partition it replays"
(§79) used a four-row inner side, which now fits the budget and never partitions; it takes
an inner join with a three-thousand-row build side instead, which still does. A new test
pins the shortcut itself: a budgeted run whose build side fits matches the unbudgeted run
row for row on a query with no ORDER BY, which is only true while the row order is the
probe side's.

**Gates.** 416 wasm-gc and 430 native tests, 33 goldens with their equivalence checks,
`harness/check_cli.sh`, `harness/spill_accept.sh`, and the three-budget matrix above.

**What is left.** The other half of the contract — partitioning the build side and probing
it with a fitting probe side when the *build* is what overflows — and choosing the index
side at plan time, which is what q21's first step still pays for: 9.00 s against 2.98 s with
no budget, because its build is `lineitem` at 773 MB either way.

## 82. The other half: when the table side is what overflows, swap instead of spill (2026-10-30)

§81 kept a fitting build side out of the partitioner. This is the mirror of that, and it
was already half-built in the engine: `SwapCursor` (which serves the join+aggregate path's
last step) builds its hash side from the accumulated rows and streams the *table* past it a
batch at a time. When the accumulated side fits the budget and the table side does not,
that is exactly the shape needed.

**The change.** In `join_or_spill`, after the build-fits case: for an INNER step whose
accumulated side fits (`acc * 2 <= budget`), call `join_swapped_stream`, which concatenates
the accumulated rows into the prefix, hands the table's batches to `SwapCursor` through a
cursor, and drains the output. LEFT and FULL steps are excluded — they owe unmatched rows
to the side that would become the build side — and so are semi/anti, which never partition.
The new path declares its own census point (`hash join swapped its sides`), naming the
prefix copy, the index and the output, because §79 established that an allocating phase
which does not name itself is a hole in the attribution.

**What it measured** (SF1, three rounds, matrix against `130d207`, host round spread 17.8%):

| case | peak | wall |
| --- | --- | --- |
| q8 16 MB | 471.4 → 289.3 MB (−38.6%) | 4.25 → 1.71 s (**−59.8%**) |
| q8 64 MB | 525.3 → 289.2 MB (−44.9%) | 3.80 → 1.71 s (−55.0%) |
| q5 16 MB | 415.3 → 297.0 MB (−28.5%) | 3.87 → 1.85 s (−52.2%) |
| q9 64 MB | 661.2 → 389.2 MB (−41.1%) | 4.74 → 2.41 s (−49.2%) |
| q9 16 MB | 619.3 → 389.1 MB (−37.2%) | 6.43 → 3.31 s (−48.5%) |
| q5 64 MB | 447.2 → 297.2 MB (−33.5%) | 3.55 → 1.88 s (−47.0%) |
| q3 16 MB | 237.4 → 161.3 MB (−32.1%) | 2.91 → 1.81 s (−37.8%) |
| q3 64 MB | 265.3 → 160.9 MB (−39.4%) | 2.76 → 1.85 s (−33.0%) |
| q21 16 MB | 574.8 → 538.7 MB (−6.3%) | 8.52 → 6.67 s (−21.7%) |
| q18 16 MB | 77.5 → 75.3 MB (−2.8%) | 4.25 → 3.75 s (−11.8%) |

This is the first change in the session that moves *both* peak and wall time the same way
by a wide margin: the table side is no longer encoded, written, read back and decoded, it
just streams. Every no-budget case is unchanged. q20 at 16 MB moved +7.5% in wall time,
inside the run-to-run spread but recorded here.

**Five cases changed row order, none its content.** q5 and q9 at 16 and 64 MB and q7 at
16 MB emit rows in the table's order where partitioning emitted them partition-major;
verified as multisets at nine significant digits against both the control's budgeted answer
and the unbudgeted one (q3 11 rows, q5 6, q7 5, q9 176 — all equal). The goldens, which
carry ORDER BY, pass.

**Gates.** 417 wasm-gc and 431 native tests (one new: a budget the build side overflows
answers the same as no budget, and its census names the swap), 33 goldens with the
equivalence checks, `harness/check_cli.sh`, `harness/spill_accept.sh`, and the matrix above.

**What is left.** q21 at 16 MB still takes 6.67 s against 2.90 s: its chain's later steps
have neither side small enough to keep, so they still partition. Choosing the index side at
plan time — rather than by whichever side arrives first — is the next lever, and the
one-sided build partitioning the contract described is what would serve the steps in
between.

## 83. 0.6.1 is released (2026-10-31)

Renumbered from 0.7.0 by the owner: the plan changes, the census output and the order of
unordered rows are all visible, but no public signature moved and the previous behaviour was
never promised, so a patch carries it. The changelog section says that in its own words
rather than leaving it to the number.

The version claims, checked by `harness/check_release.py --tag v0.6.1 --check-consumer`
before the tag existed:

- `moon.mod`, `moonlake.mbt`, `pkg.generated.mbti` (via `moon info`), both assertions in
  `moonlake_test.mbt`, the changelog heading and the tag all say 0.6.1;
- the archive holds 244 files and none matching a forbidden pattern;
- the tree is clean at `5c774f1`;
- the consumer checkout builds against the packaged archive on native, wasm-gc and js, with
  fresh registry and dependency caches, and its four streamed shapes agree with the
  collected ones.

`moon publish --dry-run` returned `202 Accepted` for 0.6.1 with a `Check passed` line; the
real publish returned `Server status: 200 OK`.

**After the publish**, from the registry and with no workspace override:

- `harness/check_consumer.py --registry-version 0.6.1` — all three backends pass;
- `moon view superbigcup325/moonlake` — `superbigcup325/moonlake@0.6.1`, published
  2026-10-30T17:18Z, 99 downloads at the time of reading;
- tag `v0.6.1` is annotated and pushed, the GitHub release is up, and the release workflow
  (which ran to completion) deployed the playground;
- the deployed page passes `harness/playground_accept.cjs` against
  `https://superbigcup325.github.io/moonlake/index.html`: **16/16**, and its first line is
  the version gate reporting `0.6.1 (expected 0.6.1)`.

**One documentation error fixed on the way.** The empty-grace-partition fix (§77) had been
written into 0.5.1's `### Fixed` section — an already released one — instead of the
unreleased block. It now sits in 0.6.1's `### Fixed`, where the reader looking for it will
be.

**What the release carries.** Eleven changelog entries: the budget's unit split from the
census' (§78), the two halves of the one-sided spill (§81, §82), the census points for a
replayed partition and a swapped step (§79, §82), the eager fold's and the shared scan
cache's points (§74, §75), the cheaper map and group state (§73), the crash fix (§77). Three
measurements ship as refusals instead: validity bytes in the budget unit (§76), the
uncollapsed replay handover (§80), and the earlier cell-only census (§78's predecessor).

## 84. The early semi/anti placement is measured and refused (2026-10-31)

The contract ("The early semi/anti contract", roadmap) was written first and committed
alone (`b40e4a2`). It predicted a win from a row count: after q21's first step the chain
carries 3,793,296 rows and after its semi and anti steps 202,092, so placing the two most
selective conditions before the joins that build that intermediate should make steps three
and four eighteen times cheaper. The bar was q21 at least 10% better in wall time *and* peak
with no budget, and no other query more than 5% worse.

**What was built.** `place_extra_items`: after the decorrelator collects the synthetic
semi/anti items, each is inserted right after the last FROM item its ON reads, across INNER
joins only, in AST space so the binder computes the smaller layouts itself. Items whose
references cannot be attributed (bare columns, nested selects, an alias it cannot find) and
items that would cross a LEFT, RIGHT or FULL join keep the old place at the end. q21's plan
did move: supplier, lineitem, semi, anti, orders, nation.

**What it measured.** The prediction was wrong, and in both directions at once:

| q21 | before | after |
| --- | --- | --- |
| no budget, wall | 2.89 s | **7.95 s** (+175%) |
| no budget, peak | 504 MB | — |
| 16 MB, wall | 6.26 s | **16.63 s** (+165%) |
| 16 MB, peak | 545.0 MB | **872.5 MB** (+60.1%) |
| 64 MB, wall | 5.43 s | **12.25 s** (+125.7%) |
| 64 MB, peak | 550.1 MB | **804.8 MB** (+46.3%) |

Every other case was flat, the answer stayed the same (`same True`), and the row count did
fall as predicted — so the model that produced the prediction is what failed, not the code.
Two facts the row count hid:

- the semi and anti steps are not cheap filters. Each probes every row it is handed and
  evaluates a residual (`l2.l_suppkey <> l1.l_suppkey`) per pair, so a pass costs roughly in
  proportion to its input — and moving them up doubles that input, because they now see the
  rows *before* the cheap `o_orderstatus = 'F'` filter has halved them (1.9M rows became
  3.79M).
- their inner sides are already materialized, `__semi0` at 6,001,215 rows and `__semi1` at
  3,793,296, because the decorrelator pre-executes each inner query. Moving the steps up puts
  that 600 MB beside the largest probe the chain ever holds, which is where the +60% peak
  comes from.

So the current order is already the good one: the two expensive passes sit where the probe
is smallest, after the selective inner joins. Refused; the code is reverted and the census
test keeps its `(step 2)` expectation, which is the same statement from the other side.

**A latent bug found on the way, and fixed.** `explain` built its schema list in FROM order
and then appended the synthetic tables at the end — correct only while the synthetics *are*
the last FROM items, which they always were. With the reorder in place, `--analyze` on q21
failed with `unknown column "__sk1" in table "orders"` while the plain run answered
correctly. The path now resolves each FROM item against the decorrelated list (synthetic
first, catalog second), so it no longer depends on that assumption. The fix stays: it costs
nothing and the assumption is exactly the kind that a later change breaks silently.

**One smaller measurement, also below the bar.** Running the anti before the semi without
moving either — the anti keeps 337,680 of the 3,793,296 rows the first step produces, the
semi keeps 3,657,708 — is worth 2.90 s → 2.85 s (1.7%) on the existing plan, so no heuristic
ordering of the two was introduced on the strength of it.

**What this says about the next lever.** Ordering the chain by measured selectivity is a
cost model, and this round is the evidence that the engine does not have one: it orders by
the FROM list and the conjunct order, and both guesses above were wrong by a wide margin.
The roadmap's "cost-based reorder" entry is where that belongs, with row counts from the
census as its first input rather than a hand-derived estimate.
## 85. The whole TPC-H set against 0.6.0, and one regression it found (2026-10-31)

The twelve-case join matrix every earlier section measured left the other ten queries
unmeasured, so the release was swept whole: 22 queries x three budgets (none, 16 MB,
64 MB) against the published 0.6.0 binary, interleaved, two runs a case, fastest wall
and highest VmHWM kept. Every answer is identical except the five that come back in a
different order, and those were checked as multisets (floats canonicalised to nine
significant digits, rows sorted).

**Sixty-one of the sixty-six cases are faster.** The wins are the session's: q2 64 MB
13.77 -> 2.05 s, q8 16 MB 4.32 -> 1.76 s with the peak 503 -> 290 MB, q3 -41.3% and
-39.4% peak, q7 64 MB 6.26 -> 2.38 s, q9 -50% with the peak -41%, q21 16 MB 12.34 ->
6.37 s, q17 -27% with the peak -42% to -46%. Unbudgeted, q15 3.50 -> 1.55 s, q18
4.04 -> 2.12 s, q21 6.36 -> 2.96 s, q2 2.00 -> 1.61 s with the peak 1395 -> 883 MB.
Three cases are slower: q13 (+6.5% unbudgeted, +1.8% and +1.0% budgeted — the noisiest
case of the set) and q19 at 16 MB, which is the finding below.

**The peaks that moved the other way, all unbudgeted.**

| case | before | after | wall |
| --- | --- | --- | --- |
| q15 | 41.4 MB | **238.8 MB** | 3.50 -> 1.55 s (-55.7%) |
| q18 | 145.4 MB | 231.3 MB | 4.04 -> 2.12 s (-47.5%) |
| q17 | 203.2 MB | 239.4 MB | 4.71 -> 2.61 s (-44.7%) |
| q20 | 99.4 MB | 112.9 MB | 2.40 -> 2.08 s (-13.2%) |
| q22 | 35.4 MB | 41.4 MB | 0.74 -> 0.65 s (-12.6%) |

Each of the five reads a table whose columns are now kept for the whole query (the
shared decode of §71's round, and the batches a chain hands on instead of collapsing),
and each pays for it in bytes it did not use to hold. The pattern is consistent — q15,
q18 and q17 are the three that read lineitem twice or keep a wide build side — but the
cause is not isolated yet and the table above is the honest state of it: without a
budget the wall time is what the query asked for, and the peak is a cost that no
contract currently bounds. With a budget the same queries move the right way (q18 16 MB
73 -> 76 MB, q15 16 MB 41 -> 46 MB, both within 10%).

**q19 under a 16 MB budget: 65.5 -> 127.6 s, and the bisect.** One case in the sweep
doubled, and it is worth the whole section because the sweep found it and nothing else
would have.

| build | q19, 16 MB |
| --- | --- |
| 0.6.0 (`8ef102e`, the release's first follow-up docs) | 65.5 s |
| `8b11bad` — a step lets go of tables whose last step it was | 65 s |
| `70b60fc` — the scan aims for 2048 rows a batch | **127 s** |

`a56517e` (hand a chain's batches on) is 66 s, so the batch size is the whole of it,
and only at 16 MB: the same query is 66.9 vs 66.4 s unbudgeted and 65.5 vs 66.0 s at
64 MB. 2048 rows a batch was landed for a reason (§68: the four-node 16 MB matrix lost
66-101 MB of peak with it), so the question is not which of the two numbers is right
but what the partitioner does with the smaller batch.

**Two guesses about that, both measured, both wrong.** The contract of the same date
proposed that the partitioner's cost is the number of little gathers it makes — one
per partition per input batch — so it should coalesce each side's batches into chunks
of `budget / 64` before routing. Implemented, 417 + 431 tests and 33 goldens green:

| q19, 16 MB | wall |
| --- | --- |
| 2048-row batches, as it stands | 127.6 s |
| coalesced routing, `budget / 64` chunks | 131 s |
| 4096-row batches instead | 66.1 s |

So the routing is not where the time is: the pieces and their contents are unchanged
by construction, and the number of gathers fell by more than half with no effect. The
other guess was to move the scan to 4096 everywhere, which does fix q19 (66.1 s) but
costs 2-7% on the unbudgeted cases (q1 +8.3%, q16 +6.7%, q6 +4.9%, q12 +4.0%, q17
+3.0%, q5 +4.5%, and flat peaks) — the cache argument §68 measured, unchanged.

**What that leaves.** The lever is the batch size the *partitioner* sees, and it is
worth 62 s on q19 against 2-7% on everything else, so it should be decided by whether
a query is spilling, not by a constant: the scan would hand over 4096-row batches when
the query carries a budget and 2048-row ones when it does not. That needs the budget
plumbed into the source reader, which is the next round's work — the coalescing is
reverted, and this section is what it stands on: the regression is real, it is one
case, and its cause is a constant two commits away from where the effect shows.
## 86. What the shared decode costs, and why it is kept (2026-10-31)

§85's sweep found five unbudgeted cases whose peak grew while their wall time halved.
The cause is one commit, `31233bb` (decode a table once when a query names it more than
once): a query that reads a table twice decodes it once and keeps the columns for the
rest of the query.

| unbudgeted | before the cache (`b62918b`) | after it (`31233bb`) | today |
| --- | --- | --- | --- |
| q15 | 41.4 MB | 237.2 MB | 238.8 MB |
| q18 | 145.4 MB | 237.3 MB | 231.3 MB |
| q17 | 203.2 MB | 239.4 MB | 239.4 MB |

q15 is the clearest case: it expands `revenue0` twice, so lineitem is read twice, and
the cache is what turns 3.50 s into 1.55 s (-55.7%). Holding the columns costs 197 MB
of an unbudgeted peak, and 5 MB of a 16 MB one (41.5 -> 45.5 MB), because under a
budget the scan hands batches on instead of accumulating them.

The trade is worth stating plainly because it cannot be trimmed to nothing: the second
reader is the end of the query, so releasing the entry when the first reader finishes
removes exactly the reuse that pays for it. What can move is the bound — an unbudgeted
query has no memory contract, so the cache follows the query's shape rather than a
number, and the census names it (`# shared scan cache`, §75's point). A byte cap that
drops entries rather than keeping them is the shape a future contract would take; the
trigger is an unbudgeted peak contract, which does not exist yet.

Recorded here rather than fixed: the wall time is what the query asked for, the memory
is visible in the census, and the budget path is unaffected by more than 10%.
## 87. A budget turns the shared decode off, and what that costs (2026-10-31)

§86 recorded the cache's memory. This section records its price on the other side:
`share_repeated_scans` returns the catalog unchanged when `opts.budget > 0`, so a
budgeted query decodes a repeated table twice.

Set a budget large enough that nothing can spill — 2 GB, against a 1.1 GB SF1
lineitem — and the queries that read lineitem twice slow down while the rest do not
move at all:

| case | unbudgeted | 2 GB budget | |
| --- | --- | --- | --- |
| q21 (EXISTS + NOT EXISTS) | 2.98 s | 5.51 s | +85% |
| q18 (IN + aggregate subquery) | 2.15 s | 3.30 s | +54% |
| q17 (correlated avg subquery) | 2.63 s | 3.83 s | +45% |
| q9, q5, q7, q12, q13, q6, q1 | unchanged | unchanged | within 4% |

The three that pay are exactly the three whose plan scans lineitem twice, and `--mem`
says what the second decode would have cost to keep: `shared scan cache (lineitem):
139059657` bytes — 139 MB, 57% of q17's 245 MB unbudgeted peak. No 16 MB or 64 MB
budget can hold it, so the toggle is right: a cache that cannot fit is not a cache.

What it costs is the second decode, and the query pays it whatever the budget is
(the same three cases are +88%, +54% and +45% at 2 GB, where the spill path is idle
and the only difference is the toggle). The shape that could recover it is the one the
roadmap already names — write the decoded table to the spill store once and let later
readers stream it back — and this measurement is what its bar is made of: for q21 at
16 MB, one decode (~1.5 s) plus a write and two reads against two decodes (~3 s) is a
gain of about a second on 6.37 s, and it has to beat that without breaking the budget
it exists to respect.
## 88. The spilled tee, built and refused (2026-10-31)

§87 left the budgeted repeated read with no way to share: the decoded columns are
139 MB, no 16 MB or 64 MB budget holds them, so the second reader decodes again. The
contract of the same date proposed the shape the roadmap already named — decode once,
write the batches to the spill store, let every reader stream them back — and set a
bar of 10% on q21, q18 and q17 at both budgets with nothing else 5% worse.

It was built: a `TeeScan` beside the shared scan, a `TeeStream` that fills while the
first reader consumes and serves from the store afterwards, the union projection
stored once and projected per reader, chunked at `budget / 16` so the working set is
one chunk. 417 unit tests green, and every answer byte-identical. Measured against the
same tree, interleaved, two runs a case:

| case | 16 MB | 64 MB |
| --- | --- | --- |
| q18 (IN + aggregate subquery) | 4.09 -> 3.25 s (-20.5%) | 3.83 -> 3.14 (-18.0%) |
| q15 (revenue0 twice) | 3.20 -> 2.82 s (-11.9%) | — |
| q21 (EXISTS + NOT EXISTS) | 6.75 -> 6.14 s (-9.0%) | 5.53 -> 5.05 (-8.6%) |
| q17 (correlated avg) | 3.87 -> 3.53 s (-8.9%) | 4.11 -> 3.67 (-10.8%) |
| **q11 (partsupp twice)** | **0.30 -> 0.50 s (+67.7%)** | **0.31 -> 0.50 (+62.7%)** |
| thirteen others | within 2.6% | — |

q18 is the win the contract wanted. q11 is why it is not landed: partsupp is 800k rows
and cheap to parse, so the tee's two extra passes (serialize, then deserialize on
every read) cost more than the decode it saves, and the peak rises 8-16% on top. The
bar said nothing else more than 5% worse, and this is 63-68% worse on a query that
takes a third of a second — the worst kind of regression to argue for, because the
absolute number is small and the ratio is not.

The barrier is that the engine cannot tell the two tables apart before reading them.
CSV's plan reports `rows: None` (there is no row count without parsing), the file's
byte size does not separate 118 MB of partsupp from 700 MB of lineitem either, and a
*write* pass is not cheaper per byte than a *parse* pass in a ratio the code can name.
An in-memory cap is the other half of the idea and costs nothing when it fits — the
batches are already decoded and in hand — but at `budget / 8` it fits neither table
that matters, so it would buy q11's 0.2 s back and nothing else.

So: reverted, with the numbers above as the reason. What would reopen it is a signal
the engine does not have today — a source that reports its rows, or a per-format
decode cost — and then the gate is one comparison rather than a constant.
## 89. A budget costs a query that never spills, and the probes that missed it (2026-10-31)

§87 found the first half of this — a budget switches off the shared decode — and this
section records the rest: for a join query, setting a budget at all costs wall time
even when nothing is over budget and nothing spills.

q2 is the cleanest case. Its plan, printed by `--analyze`, is byte-identical with and
without a budget; its counters are identical too (`joins: 460`), and the only
difference the report shows is 16 spill files that wrote 8.6 MB and read 374 bytes
back.

| q2 (part, partsupp, supplier, nation, region) | wall |
| --- | --- |
| no budget | 1.53 s |
| 64 MB | 2.05 s |
| 16 MB | 3.93 s |

Four probes tried to attribute the 2.4 s and each was measured against the same tree:

- **the sort.** Dropping `order by` from q2 changes nothing (3.94 s at 16 MB), so the
  external sort is not it. The sort does have a fixed cost of its own — 0.27 -> 0.35 s
  (+30%) for a top-100 `order by` over partsupp — but on 1.5 s of join it is not the
  gap.
- **the collapse.** §65's collapse runs whenever a budget is set; handing batches on
  instead of collapsing them is within 1% on q2 and q7 and 20% *worse* on q9, so it is
  not the gap either (and is not landed).
- **the partitioner.** Coalescing its input (§85) halved its gathers and moved the
  time not at all.
- **the store.** The spilled tee (§88) is for repeated reads, and q2 reads each table
  once.

What is left is inside the eager path itself, and the census points at a number that
cannot be real: `# hash join collapsed its output (step 1): 3219567569 bytes` — 3.2 GB
reported at a 16 MB budget, the same value at 64 MB, where the wall time halves. Either
that label accumulates over the run instead of reporting a point, or the estimator is
wrong by an order of magnitude; the first thing the next attempt should do is settle
which, because every fit decision in §81 and §82 is made with the same estimator.

This host has no profiler (`perf`, `strace` and `ltrace` are all absent), so the
remaining attribution is a sampling question rather than a reasoning one. Recorded with
its numbers and its four refutations so the next attempt starts from the list.
## 90. The budget's byte count reads the column, not one row at a time (2026-10-31)

§89 left q2's remaining 2.4 s unexplained and flagged the estimator as the suspect — not
because it is wrong, but because of how it is spelled: `estimate_batch_bytes` summed a
string column by calling `col.get(r)` on every row, which builds a `Scalar`, matches it,
and only then reads the length. A budgeted step asks for it twice per step (both sides),
and q2's accumulated side runs to hundreds of thousands of rows and sixteen columns.

`ColumnVector::str_cell_bytes` does the same arithmetic from the column's own array, with
no `Scalar` per row. The numbers do not move by a byte — a NULL slot still costs one, a
valid cell four plus its characters — so no fit decision changes; only the cost of asking
does. Measured against the same tree, four interleaved rounds a case, medians:

| case | 16 MB | 64 MB |
| --- | --- | --- |
| q2 | 3.86 -> 3.43 s (-11.0%) | 2.00 -> 1.79 (-10.4%) |
| q13 | 3.02 -> 2.88 s (-4.8%) | 2.88 -> 2.72 (-5.4%) |
| q7 | 4.01 -> 4.01 s (+0.1%) | 2.38 -> 2.39 (+0.1%) |
| q8 | 1.77 -> 1.75 s (-1.1%) | 1.76 -> 1.76 (+0.1%) |

with the peaks equal to a tenth of a percent (q2 1424.9 -> 1425.3 MB, q13 445.7 -> 445.6,
q7 437.8 -> 438.0, q8 288.8 -> 288.8) and every answer byte-identical. 418 wasm-gc and 432
native tests pass, with a new one for the function's two cases (a valid cell and a NULL
one).

**Against the released binary.** §85 recorded one regression against 0.6.0 — q13, the
noisiest case of the set. Measured directly now, four runs a case:

| q13 | 0.6.0 | before §90 | after §90 |
| --- | --- | --- | --- |
| no budget | 1.14 s | 1.22 (+6.7%) | 1.17 (+2.9%) |
| 16 MB | 2.96 s | 3.02 (+2.0%) | 2.87 (-3.1%) |
| 64 MB | 2.87 s | 2.87 (+0.2%) | 2.72 (-5.3%) |

so the sweep's one regression is now a 2.9% loss unbudgeted and a 3-5% win at both
budgets. q2 against the same binary: 14.69 -> 3.43 s at 16 MB (-76.7%), 13.94 -> 1.80 at
64 MB (-87.1%), and 1.83 -> 1.54 unbudgeted.

**What it does not explain.** q2 is still 3.43 s at 16 MB against 1.53 unbudgeted, so
§89's question is open by another 90% of the gap. The lesson it leaves is narrower and
worth keeping: the estimator was measurable because it ran once per side per step, and
the next section on this path should time its calls before reasoning about its branches.
