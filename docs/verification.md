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
texts + the Parquet variant + three multi-row-group Parquet queries, plus the
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
design, 0 failing. This is what caught an ordering regression the per-push jobs
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
