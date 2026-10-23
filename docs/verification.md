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
- literal arithmetic wraps as **defined semantics**: 2147483647+1 → -2^31;
  9223372036854775807+1 → -2^63
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

**2. End to end**: all 27 golden queries (`harness/check_all.sh`: 22 TPC-H
texts + the Parquet variant + four multi-row-group Parquet queries, plus the
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
bash harness/check_all.sh                            # 27 goldens + parquet fixture checks
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
a time (`BatchSeq`, `engine/exec.mbt`). Honest result: peak RSS on
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

**What cannot be fixed without a clock or a pid.** A killed process leaves its
subdirectory behind, and the next run does not remove it: the filesystem API in
use (`moonbitlang/x/fs`) exposes no pid, no wall clock and no file timestamp,
so a dead owner and a live one look identical, and deleting on a guess would
break a running query. Measured: `kill -9` during a spilled sort leaves
`moonlake-spill-0` with 40 run files (1.8 MB); a following clean query creates
its own directory, finishes, removes it, and leaves that one alone. The leak is
therefore bounded to one directory per interrupted query, which the acceptance
pins as a known boundary. Reclaiming it needs a native syscall surface in the
CLI, which conflicts with the project's "no FFI" claim and is a decision, not a
bug fix.

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
7. a `moonlake-spill-0` left by an interrupted run survives the next query.

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

What is left is not the writer's own buffering and is not fixable here: the
sources read a whole file into `Bytes` (75 MB CSV, 84.8 MB Parquet) because the
fs API has no range reads, and `write_bytes` still accumulates the whole archive
before handing it to `write_bytes_to_file` (the CLI path needs an incremental
write handle for that, which `moonbitlang/x/fs` does not expose). The CSV path
in particular is now dominated by the scan itself: `count(*)` over the same CSV
costs 341 MB on its own.

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
   `moon.mod`, `README.md`, `LICENSE` and `moonlake.mbt`, and no path matching
   `.internal/`, `moon.work`, `.mooncakes/`, `_build/`, `target/`,
   `__pycache__/`, `harness/data/`, `harness/spill_bench/`,
   `harness/kernel_bench/`, `hooks/`, `.venv/` or `.env`. This is the only
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
filesystem APIs that the current dependency does not expose.

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
