# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `@spill.run_file_name` and `@spill.is_run_file_name`. The files a spill
  directory holds are named by the store, and a host that points `--spill-dir`
  at a directory of its own has to tell them from its own files before removing
  anything: `run_file_name(id)` is the name a run gets, and
  `is_run_file_name(name)` answers whether a name is one of them ("run", one or
  more digits, ".bin"). The CLI's cleanup already asked exactly this question;
  the rule is public now so a second caller does not have to restate it.

### Changed

- The Parquet writer no longer refuses files larger than 2 GiB. A column
  chunk's `file_offset` and its `data_page_offset` are file positions, so they
  are written and counted as 64-bit now; the only 32-bit length left is a page's
  own body, and a page holds one batch, so that bound is the batch size rather
  than the file size. Writing 2.35 GiB of CSV produces a 2.41 GiB Parquet file
  in 13.5 s at 22 MB of peak RSS, with 1,820 of its 16,798 column chunks past
  2^31, and moonlake, pyarrow and DuckDB read the same rows and sums back from
  it (`harness/check_large_write.py`). Nothing public changed: `write_bytes`,
  `write_file` and `write_file_with` keep their signatures, and files under
  2 GiB are byte-identical to 0.5.0's.
- A single-table `LIMIT` stops its scan when the window is full. The executor
  used to materialize a whole table before the window saw a row: `select * from
  t limit 10` over 2,000,000 rows (75 MB of CSV) read all of them, taking 483 ms
  and 252 MB of peak RSS above the measurement floor, and 278 ms / 250 MB over
  the same rows as Parquet. It now pulls one batch of 4,096 rows: 13.9 ms and
  13 MB on CSV, 4.9 ms on Parquet, with `--analyze` reporting the 4,096 rows the
  scan emitted instead of 2,000,000. What a LIMIT cannot stream — a join, an
  aggregate, `ORDER BY` or `DISTINCT` above it, or a derived table on the outer
  side — behaves exactly as before, and all eleven benchmark shapes return the
  same rows as 0.5.0 when checked against DuckDB on the same fixture. Nothing
  public changed.
- `--snappy` output is about 13% smaller. The compressor wrote every match as a
  three-byte `copy2` tag even when the match was short and close behind, which
  is what most of a text page looks like; a length of 4–11 at an offset below
  2048 is now a two-byte `copy1`. The SF1 `lineitem` table (6,001,215 rows)
  drops from 333.0 MB to 289.2 MB, against 287.9 MB for pyarrow writing the
  same rows as plain+snappy. Only the encoder's tag choice changed, so the
  decoded bytes are the same ones as before.

## [0.5.0] - 2026-10-24

> First release since 0.4.0. The theme is that a query's memory no longer grows
> with the size of its input files: Parquet and CSV scans read byte ranges
> instead of whole files, and native Parquet output streams as it encodes
> instead of building the archive in one buffer. `count(*)` over a 287 MB
> Parquet file drops from 295 MB of peak RSS to 12 MB, and over a 302 MB CSV
> file from 1063 MB to 35 MB. It also closes what a killed query left behind:
> a spill directory is claimed with an owner marker and reclaimed by the next
> query only when that marker proves the owner is dead. One signature was
> added, native-only (`pub type Emit`, the sink `write_file_with` writes
> through); every other public signature and every produced file is unchanged,
> byte for byte.

### Changed

- 2026-10-24 a query killed outright no longer leaks its spill directory: each
  `moonlake-spill-<n>` is claimed with an `owner` marker (pid, boot id, the pid's
  start time from `/proc`) created exclusively, and the next query removes a
  directory only when that marker proves the owner is dead — another boot, a pid
  that no longer exists, or a pid whose start time changed. A directory with no
  marker, an unknown marker version, or a live owner is kept, and the first two
  are reported on stderr. Reclaiming renames the marker away first, so
  concurrent reapers cannot both empty one directory, and it deletes only the
  run files and marker names it wrote. Backends without `/proc` (wasm-gc/js, and
  macOS, which has no boot id to record) keep the previous behaviour: nothing is
  recorded and nothing is reclaimed. The rules live in the `cmd/main`
  executable, so no published signature changed; `platform/io` grew the
  exclusive create, a rename that tolerates a vanished source, a pseudo-file
  read for `/proc`, and the clock. Details and the ten-check acceptance are in
  `docs/verification.md` §22


- 2026-10-24 CSV files are scanned in byte ranges instead of whole: `scan_file`
  reads a 64 KB prefix at registration (header plus the inference sample) and
  one 4 MB range at a time while a query runs, indexing and materializing each
  range before dropping it, so peak RSS no longer grows with the file or with
  a per-cell offset table for all of it. `count(*)` over a 302 MB SF0.1 lineitem
  copy drops from 1062.7 MB to 35.2 MB and `write --csv` from 1062.7 MB to
  34.9 MB, with byte-identical archives and DuckDB-identical results; wall time
  roughly halves. Memory inputs and the wasm-gc/js builds keep their existing
  behaviour behind the same signatures, so the public interface is unchanged.
  Measured numbers and the range-level tests are in `docs/verification.md` §21

- 2026-10-23 Parquet files are read in byte ranges instead of whole: the native
  `platform/io` binding gained positioned reads (`pread` plus a size from
  `fstat`) and a `FileReader`, and `scan_file` now reads the 8-byte trailer and
  the footer at registration and one column chunk per projected column per row
  group when a query runs. Peak RSS for a scan no longer grows with the file —
  `count(*)` over a 287 MB archive drops from 295 MB to 12 MB (585 → 12 MB at
  574 MB) and a one-column aggregate from 323 MB to 37 MB — and wall time falls
  with the removed copy pass. Memory inputs (`scan_bytes`) and the wasm-gc/js
  builds keep their existing behaviour behind the same signatures, so the public
  interface is unchanged. Measured numbers and the range-level tests are in
  `docs/verification.md` §20

### Added

- 2026-10-23 native Parquet file output streams instead of buffering: a new
  native-only `platform/io` package (C stub, `FileSink`) writes pages as they are
  encoded and renames a temporary file over the target on success, so a failed or
  interrupted write leaves the previous file intact. `write_file_with` keeps one
  signature on all three backends (wasm-gc/js keep the whole-file write their
  hosts require) and the public interface gains only `pub type Emit`. Measured
  peak RSS on a Parquet input drops 326 → 101 MB raw and 199 → 101 MB Snappy, and
  the produced archives are byte-identical to 0.4.0's; with a CSV input the
  archive-sized copy is likewise gone (427 → 337 MB at 75 MB of output). The
  remaining CSV growth is the scan, tracked separately

## [0.4.0] - 2026-10-23

> First release since 0.3.1. It carries everything that landed on `main` in
> between: the session playground (several files, cross-file JOIN, plan panel),
> the in-house Parquet writer (NULLs, STRING/DATE annotations, statistics,
> SNAPPY, one-pass streaming input), file-level Parquet pruning, the packed
> two-key join, the spill isolation fixes, the archive-consumer gate, and the
> correctness fixes below (non-finite JSON, spilled-sort ordering). 0.2.0 was
> never published on its own.

### Fixed

- 2026-10-23 a spilled `ORDER BY` could return a wrong answer: the run writer
  accumulated several independently sorted chunks and wrote them back to back,
  while the final k-way merge reads each run file as one sorted stream. A run
  that held pieces of more than one sorted batch was only piecewise sorted, so
  the merge leaked chunk heads into the result — over SF0.1 at `--memory 1M`,
  `ORDER BY l_extendedprice DESC LIMIT 3` reported 95799.5 as its maximum
  instead of 95949.5. A 200 KB budget happened to keep one chunk per run, which
  is why the acceptance check stayed green; the regression came from the new
  benchmark oracle that compares answers, not stdout hashes. A run is now
  sorted before it is written (bounded by `budget/4`), and join/aggregation
  partition writers keep their unsorted runs. Recorded spill timings taken
  before this fix are not comparable
- 2026-10-23 `--json` (and the playground, whose `JSON.parse` runs on the same
  string) emitted a non-finite DOUBLE as a bare `Infinity`, `-Infinity` or
  `NaN` token, so one such value made the whole line invalid JSON — a division
  by zero, which this engine deliberately keeps as IEEE inf/NaN, was enough.
  Those three values now render as strings, keeping the output strictly
  parseable and still distinct from a finite number and from SQL NULL; finite
  doubles stay JSON numbers
- 2026-10-22 DuckDB 2.0 removed `fetchone()` from its relation API, breaking
  Parquet fixture generation and writer interop. Single-row reads now use the
  connection cursor API. The corpus gate only skips DuckDB read errors, lets
  Python/API errors fail, and refuses success when a recorded file was not
  verified; an all-skipped run could previously pass. CI uses Python 3.12 and
  the DuckDB/PyArrow versions in `harness/requirements.txt`
- 2026-10-22 the nightly and pre-commit hook labelled a bare `moon test` as
  native, but the module had no preferred target and it ran wasm. Both now
  select native explicitly, and `moon.mod` sets wasm-gc as the default target
- 2026-10-22 the README and harness guide still described the old single-table
  playground and five spill checks, and claimed all current features shipped
  in 0.3.1. They now describe the session UI, seven spill checks and the
  development/release boundary; quickstarts refresh the registry first and
  acknowledgements include the colenc dependency
- 2026-10-22 unsupported Parquet physical-type and encoding errors now
  interpolate the actual column name instead of printing literal placeholders
- 2026-10-21 two spilled queries sharing one `--spill-dir` corrupted each
  other: every query wrote `run0.bin`, `run1.bin` … into the directory it was
  given and then removed every `run<n>.bin` it found there, so a concurrent
  pair failed on both sides with `spill read: No such file or directory`. A
  query now spills into its own `moonlake-spill-<n>` subdirectory (`create_dir`
  is the lock) and the cleanup only looks inside the directory it created, so a
  caller's own files in `--spill-dir` are never listed, let alone deleted. A
  killed process still leaves its subdirectory behind: the filesystem API has
  no pid, clock or file timestamp, so a dead owner cannot be told from a live
  one and the next run does not guess — that boundary is pinned by the
  acceptance instead of staying invisible
- 2026-10-21 the Parquet corpus check counted a footer-only `select count(*)`
  as a read, so 18 of its 35 "read" files were ones whose data pages this reader
  refuses (LZ4/ZSTD/GZIP codecs, v2 pages, an empty dictionary page). It now
  decodes every column and compares a five-row sample against DuckDB cell for
  cell, and pins each file's class in `harness/parquet_corpus_expected.json`, so
  a file that stops decoding fails the nightly instead of hiding inside a count.
  The honest classification is 17 decoded by value, 51 refused by design, 0
  failing
- 2026-10-21 a spilled sort leaked its intermediate run files on the success
  path: `reduce_and_merge` recorded the files it produced while merging and
  then only removed them through `errdefer`, so every successful spilled
  `ORDER BY` left them behind. The CLI's `remove_dir` is not recursive, so the
  directory survived too — one temp tree per spilled query, until a query
  failed mid-spill on a full disk. The intermediates are now removed after the
  merge returns, and the CLI purges a spill directory of `run<n>.bin` files
  (its own names only — `--spill-dir` may point at a caller's directory) and
  reports a directory it cannot remove instead of swallowing the error
- 2026-10-21 `ANALYZE` could not report a spill: `explain_analyze` ran with
  `ExecOptions::in_memory()` hard-coded, so the spill counters it collected
  were never reachable. `explain_analyze_with` takes the caller's options, the
  CLI passes `--memory`, and the engine counts files and bytes at the store
  boundary (`spill files` / `spill bytes written` / `spill bytes read`)

### Changed

- 2026-10-21 the Parquet writer speaks the format, not just the encoding: it
  writes the standard `STRING` and `DATE` annotations (both the deprecated
  `converted_type` and the current `logicalType`, because readers disagree on
  which they look at), and per-column-chunk statistics marked exact. Before
  this a written DATE was a bare INT32 and a written string an unannotated byte
  array — a BLOB to DuckDB, an integer to anyone else. A file moonlake writes is
  now prunable by moonlake's own row-group skipping
- 2026-10-21 the Parquet reader acts on those annotations: an annotated DATE
  column needs no `--date-col`, and an annotation with no faithful engine type
  is refused instead of silently misread — `DECIMAL` (its bytes are not text)
  and `UINT_32`/`UINT_64` (values past the signed maximum would read as
  negative) now fail with a message naming the column and the reason. Six
  apache/parquet-testing files moved from "read" to "refused by design"
- 2026-10-21 `bench_release.py --compare` refuses to print deltas when the two
  records were not taken under the same conditions (CPU, cores, kernel,
  toolchain, dataset SHA-256, build, runs, warm-ups; `--allow-env-mismatch`
  overrides), prints clock/load/governor as advisory lines instead of refusing
  on them, labels a delta that sits inside the case's own run-to-run spread,
  and records that spread per case — so the ±7% rule is measured rather than
  assumed. Records from before the spread field say so instead of implying
  their deltas are significant
- 2026-10-21 the baseline's per-case peak RSS carried a fork-inherited floor:
  hashing the dataset read all 75 MB of CSV into the harness process before the
  cases ran, and a forked child starts with its parent's resident pages, so the
  two Parquet cases (25 and 39 MB on their own) both reported 94.9 MB. The hash
  runs after the measurements and the parent is collected before they start;
  the controlled check (150 MB of ballast → an 11 ms case reported 164 MB) is
  written down in `docs/bench-baseline.md`
- 2026-10-21 the Parquet writer streams its input. It used to call
  `entry.scan(...)` — the whole projected table in memory — and walk it twice:
  once to decide REQUIRED vs OPTIONAL per column (the schema is file-wide, the
  pages are written before the footer), once to write. Every column is now
  written OPTIONAL with definition levels, which is the only schema that can be
  declared before the first page and still describe a NULL arriving later, so
  the pre-pass is gone and one `BatchStream` feeds pages as batches arrive.
  Cost: 18,816 bytes on the SF0.1 lineitem file (0.03% — hybrid RLE turns a run
  of ones into a few bytes). Peak RSS: 407 → 328 MB writing from
  `lineitem.parquet` (286 → 203 with `--snappy`), 456 → 421 MB from the CSV.
  What still bounds it is not the writer: sources read whole files (the fs API
  has no range reads) and `write_bytes` still accumulates the archive before
  `write_bytes_to_file`; an incremental file handle would be needed for that

### Performance

- 2026-10-21 a join on two int32 equality keys is 4.9x faster (69.3 → 14.0 ms
  on a 100k x 100k join, same session, single-key control unchanged at
  ~13 ms). It was falling back to the general path, which builds a canonical
  string per row on both sides; the two keys are now packed into one exact
  Int64, `(a << 32) | (b & 0xFFFFFFFF)`, which is injective so no collision
  handling is needed, and a NULL in either component still never matches. This
  is the partsupp-on-(partkey, suppkey) shape of TPC-H Q9. Strings, Int64 pairs
  and three-plus keys keep the general path

### Added

- 2026-10-23 the release benchmark verifies answers instead of only hashing
  stdout: every timed case is compared against DuckDB over the same files
  outside the timed region (`--check-oracles` runs just that check, `--no-oracle`
  opts out), `kernel_bench` checks each case against the table it built and
  `spill_bench.py` recomputes the first column's checksum from the CSV. A
  mismatch aborts the record. Comparator behaviour gained 14 self-tests
  (environment/data refusal, output change and instability, missing fields,
  added/removed cases, spread band); the check immediately found the wrong
  spilled-sort answer fixed above
- 2026-10-23 the Parquet encoding evidence is now rebuildable and page-level:
  `harness/gen_colenc_fixtures.py` writes the DELTA int32/int64, DELTA length and
  byte-array, BYTE_STREAM_SPLIT float/double cases (nulls, empty strings,
  boundaries, −0.0, SNAPPY, four row groups, three pages per group) and records
  the PyArrow version, the exact write arguments and the digests in
  `harness/colenc_fixtures.json`; `harness/check_colenc_fixtures.py` reads the
  actual page headers of both those files and the embedded `colenc_integration_test`
  fixtures, then compares values from PyArrow and from the CLI. A v2 page or a
  different encoding fails even when the footer still lists the claimed one. The
  `tpch` CI job and nightly run the gate
- 2026-10-23 `harness/check_windows.py` replays the window-function differential
  that `docs/verification.md` §5.1 had only as history: a fixed nine-row fixture
  plus a 22-case list, DuckDB-refereed. Total-order results compare in sequence,
  unordered ones as a multiset with duplicate counts, an order-free `string_agg`
  is row count only, and refusals are counted apart — valid SQL we refuse must
  run in DuckDB, SQL the standard forbids must be refused by both. No skip path:
  a referee error, a missing fixture or zero executed value cases fail the gate.
  The `tpch` CI job runs the fixed list and nightly runs `--random 400`
- 2026-10-22 `harness/check_consumer.py`: the packaged library is extracted
  into a temporary workspace and used by an independent consumer on native,
  wasm-gc and JS, resolving dependencies from a fresh registry/cache. The
  version, CSV query, raw/Snappy Parquet round-trips, DATE/NULL values and
  table removal must agree. Per-PR CI and release provenance run the gate;
  `--registry-version` checks the published current API after a release, with
  no workspace override. No credentials or package upload are needed
- 2026-10-22 browser acceptance now requires the exact engine version from
  `moon.mod` (or `MOONLAKE_EXPECT_VERSION`), so a stale deployed page cannot
  pass merely because it loads and reports a version
- 2026-10-21 `TableEntry::stream(request)` returns the scan a `TableEntry::scan`
  would return, as a `BatchStream` cursor instead of an `Array[DataBatch]`, so a
  caller that consumes batches one at a time never materializes the table. The
  Parquet writer is the first user; the engine keeps `scan` because its
  operators are still eager
- 2026-10-21 the release record carries the dataset's SHA-256 and each case's
  `sql`. A path is not an identity (regenerating SF0.1 with a different
  generator yields the same names and different numbers), and a prose `what` is
  not a workload. The `spill/*` cases now prove the spill with `ANALYZE` and
  assert the spill directory is empty afterwards, because the engine removes its
  run files — the old check counted the leaked ones
- 2026-10-21 `harness/check_release.py` and a `release` workflow on `v*` tags:
  the version claims (`moon.mod`, the library `VERSION`, the newest CHANGELOG
  heading, the tag name) have to agree, `moon package --list` has to hold the
  files a release needs and none of the dev-only ones (dot-directories,
  `moon.work`, `harness/data/`, the bench drivers, `hooks/`), the tree has to be
  clean, and
  `--publish-dry-run` optionally runs the publish gate. 0.3.0 shipped after a
  manual review found three of those four agreeing; nothing made them agree by
  construction. `/harness/kernel_bench/` is excluded from the archive like the
  other dev driver
- 2026-10-21 the playground holds a session instead of one table per run: the
  bridge exports `add_csv` / `add_parquet` / `drop_table` / `tables` / `query`
  / `plan` / `reset`, so several files can be registered, listed with their
  schema, dropped, and joined across. A duplicate table name is refused rather
  than silently replacing the old table, the page has a Plan panel
  (`engine.explain`, including the scan row counts), and `Catalog::drop` is the
  library-side equivalent
- 2026-10-21 `harness/playground_accept.cjs` grew to 15 checks and the new CI
  job `playground` runs it in headless Chromium on every PR: two files at once,
  a cross-file JOIN, the plan panel, a duplicate name, a dropped table, a clear,
  CSV and Parquet agreeing cell for cell, both error paths and no uncaught JS
  error
- 2026-10-21 `harness/kernel_bench`: in-memory operators measured without the
  CSV ingest every release-record case contains, with case pairs chosen so a
  difference isolates one structural cost. The same run recorded two
  candidates that did *not* justify work: gather over nullable columns is not
  slower than over non-nullable ones (so bit-packing the validity channel has
  no measured cost to recover), and the whole-side concat in `join_step` is
  small against the int-key control
- 2026-10-21 `EXPLAIN` states a scan's row count: exact when the format knows
  it (`rows: 600572` from a Parquet footer or a materialized table) and `?` when
  it does not (a lazy CSV scan). No estimates are printed — the engine has no
  cardinality model, and a guess beside an exact count invites trusting it
- 2026-10-21 Snappy compression on the write path: `--snappy` (CLI) or
  `write_bytes_with` / `write_file_with` (library). The compressor is ~120
  lines of LZ77 in the Snappy block format (`sources/parquet/snappy.mbt`), so
  the writer still has no dependency the reader does not already need. On a
  4000-row text table the file goes 140,274 → 24,323 bytes
- 2026-10-21 `moonlake write (--csv|--parquet …)+ --out <file.parquet>
  [--table <name>] [--snappy]`: the writer's only way out of the library, which
  is what lets a round trip be scripted and checked
- 2026-10-21 `harness/check_writer_interop.py`: moonlake → pyarrow → DuckDB and
  DuckDB → moonlake, checking the schema (VARCHAR vs BLOB, DATE vs INTEGER), the
  values, the NULLs and a non-ASCII string; `--snappy` shrinking is asserted on
  a table large enough for it to show. A new CI job `writer` runs it on every
  PR
- 2026-10-21 a grace hash join partition that still exceeds the budget is
  partitioned again (up to two extra levels, 256 partitions each) instead of
  failing at the first level: a small budget against a large input used to be
  reported as "hash skew" even when no key dominated. What no re-partitioning
  can split is one key holding most of a side, and that error now says so
- 2026-10-21 grace aggregation pulls a partition one spill file at a time
  instead of materializing it (`BatchSeq`), so a hot group key no longer puts
  a whole partition in memory on top of the budget
- 2026-10-21 `harness/spill_accept.sh`: seven checks over the spill lifecycle —
  no directory after a successful sort, none after a failed query, `--spill-dir`
  keeps files moonlake did not write, `ANALYZE` reports the counters, and an
  in-memory `ANALYZE` stays silent; concurrent queries sharing a directory do
  not collide, and a new query leaves an interrupted query's directory alone

## [0.3.1] - 2026-10-20

> Patch release. 0.3.0's wasm did not instantiate in a browser (so the
> playground never loaded) and `--json` was invalid for any DATE column;
> both are fixed here. No API changes — a 0.3.0 consumer upgrades by changing
> the version.

### Fixed

- 2026-10-20 the browser playground's wasm did not instantiate at all:
  `playground.wasm` imported the wasm host's `__moonbit_fs_unstable` module
  (12 functions) because the lazy-scan refactor routed `scan_string` and
  `scan_bytes` through the same `read_input` as their `scan_file`
  siblings, keeping `@fs` reachable. The page passes no imports, so it threw
  at `WebAssembly.instantiate` and never enabled Run. Scan inputs now carry
  their reader as a function field: a build that only scans in-memory content
  links no filesystem module (imports 12 → 0). CI builds the wasm and fails on
  any import beyond the js-string builtins
- 2026-10-20 `--json` emitted invalid JSON for DATE columns (a bare
  `1992-01-04` token); `SelectResult::to_json` now quotes a DATE as a calendar
  date, matching DuckDB's own JSON output, with a test for the quoted value
  and for `null` inside a DATE column
- 2026-10-20 the playground left the previous result's status on screen when a
  query threw or its result failed to parse; both paths now report `failed`
- 2026-10-20 the pages workflow only rebuilt on `playground/**` changes, so the
  deployed page still served `engine 0.1.0` while main carried 0.3.0. Engine,
  sources, types, sql, catalog, spill and the module manifests now trigger it

### Added

- 2026-10-20 `harness/bench_release.py`: one release performance record covering
  scan, join, gather and spill, with the toolchain, machine, git commit and
  binary hash alongside the numbers, stdout hashes to prove the work did not
  change, and `--compare` for release-to-release deltas. The first record is
  [`harness/baseline/2026-10-20-0.3.1.json`](harness/baseline/2026-10-20-0.3.1.json),
  with the 0.3.0-era record beside it, read in
  [`docs/bench-baseline.md`](docs/bench-baseline.md)
- 2026-10-20 `harness/playground_accept.cjs`: drives the playground in headless
  Chromium — CSV and Parquet uploads with DATE columns, two error paths, a
  cross-file JOIN (refused by name) and a same-file self-join

## [0.3.0] - 2026-10-20

> First release since `0.1.0` (published 2026-10-03). The `0.2.0` entries
> below record an internal development milestone that was never published on
> its own; everything since `0.1.0` ships in this version.

### Added

- 2026-10-20 the scan layer is lazy and pushdown-aware. A table entry now
  carries either materialized batches or a `ScanSource`, so the catalog needs
  the table's schema and nothing else. `@csv`/`@parquet` registration returns a
  source: `scan_file` keeps the path and re-reads it when a query opens the
  scan, `scan_string`/`scan_bytes` keep the caller's bytes, and typed columns
  exist only while a batch is live. `TableEntry::scan(ScanRequest)` is the new
  read path; `TableEntry::new(schema, batches)` builds a materialized entry as
  before
- 2026-10-20 scanners yield batches instead of a whole table: `BatchStream`
  produces `SCAN_BATCH_ROWS` (4096) row batches, CSV chunked by data rows and
  Parquet one batch per row group (sliced at 4096). An empty table still emits
  one zero-row batch so the engine sees the column layout
- 2026-10-20 column pruning reaches the sources. The engine passes the pruned
  column list it already computed (`table_cols`) as
  `ScanRequest.projection`; CSV parses and Parquet decodes only those columns,
  in projection order, and a zero-column projection (a bare `count(*)`) decodes
  nothing. A column outside the projection can no longer fail a query: a value
  that does not parse is only an error when the query reads that column
- 2026-10-20 Parquet row-group skipping from column-chunk statistics:
  `min_value`/`max_value` and `null_count` decide whether a group can be ruled
  out before a page is read. Bounds are used only when provably usable
  (explicitly inexact bounds, the deprecated signed-order pair on BYTE_ARRAY
  and non-UTF-8 string bounds are all refused), an all-NULL chunk satisfies no
  comparison, and the operator is taken into account (a group whose column is
  constant `c` is skipped for `col <> c`, one whose range is below the constant
  for `col >= c`, and so on). Float columns only prune on the strict
  comparisons: this engine's `Scalar::compare` treats NaN as equal to every
  value, while writers leave NaN out of their statistics, so `=`, `<=`, `>=`
  and `<>` could otherwise drop a group that holds a matching NaN. Hints come
  only from the table's build filter —
  the expression the engine already applies to that table's rows before
  joining it — and the engine still applies its own filter, so a hint can cost
  work but never a row
- 2026-10-20 scan-time filtering: a lazy table's build filter runs on each
  incoming batch while it is drained, so a selective scan never accumulates
  the table's rows (`EXPLAIN` prints the pushed predicates and
  `row groups: N of M read (K skipped by statistics)`). On TPC-H SF0.01, best
  of 5 native debug runs against the previous commit: q1 130→94 ms, q6
  111→67 ms, q3 130→73 ms, `count(*)` over lineitem 105→48 ms, peak RSS
  42→36 MB (q3 46→34 MB). On a generated 1Mi-row, 8-row-group Parquet table:
  `count(*)` 446→57 ms, a filter keeping 6 groups 438→51 ms, one keeping a
  single group 424→47 ms, peak RSS 130→32-39 MB; `harness/bench_scan.py`
  reproduces the comparison

- 2026-10-19 the spill format is MLSPILL3: presence is a bitmap instead of one
  byte per row. A column with no NULLs costs a single mode byte and a nullable
  one `ceil(rows / 8)` bytes, so the bake-off file drops from 5.10 MB to 4.13 MB
  (-19%) with write and read inside noise (125 vs 130 ms, 52 vs 51 ms) and an
  18% lower write RSS; the checksum over every scalar is unchanged. The
  benchmark driver also stopped trusting a hardcoded release path — it locates
  the newest build and refuses to measure a binary older than its sources,
  which is how a first run reported the previous format's numbers
- 2026-10-17 the Parquet reader decodes the remaining page encodings through
  colenc: DELTA_BINARY_PACKED (INT32/INT64), DELTA_LENGTH_BYTE_ARRAY and
  DELTA_BYTE_ARRAY (BYTE_ARRAY), BYTE_STREAM_SPLIT (FLOAT/DOUBLE) and RLE
  boolean values. The encoding gate accepts them, decode errors surface as
  pointed scan errors with the colenc message, and eight small embedded
  fixtures pin each path on every target. colenc is published as
  `superbigcup325/colenc@0.1.0`, so the dependency resolves from the registry
  and a plain checkout builds
- 2026-10-17 a Parquet writer (`sources/parquet/write.mbt`): `write_bytes` and
  `write_file` turn a `TableEntry` into one row group per batch with one PLAIN
  data page per column, encoding page bodies through colenc. Scope matches the
  reader: flat columns, v1 pages, UNCOMPRESSED, INT32/INT64/DOUBLE/
  BYTE_ARRAY/BOOLEAN; a column that holds a NULL anywhere is written OPTIONAL
  with an RLE definition-level section per page, everything else REQUIRED.
  Round-trip tests cover every physical type, NULLs, and multiple row groups;
  DuckDB and pyarrow read the output back
- 2026-10-17 the spill format is MLSPILL2: each column is a dense colenc
  stream (non-null values only) and the writer picks the smallest of PLAIN,
  DELTA_BINARY_PACKED, DELTA_LENGTH_BYTE_ARRAY, DELTA_BYTE_ARRAY and
  DICTIONARY per column, with a sample deciding whether the expensive
  candidates are tried. On SF0.01 lineitem the file drops from 8.08 to
  4.86 MiB; write is 1.46× and read 1.16× the old cost, and both RSS peaks
  fall. `harness/spill_bench.py` reproduces the measurement

### Changed

- 2026-10-20 the Parquet scan no longer concatenates row groups into one
  batch; the reader decodes one chunk of one row group at a time, which is
  what makes streaming and skipping possible. A full 16-column read (the shape
  of q6p's derived table) is 152→142 ms but needs ~3 MB more, because the
  scan's batches are what the engine then materializes
- 2026-10-20 `write_bytes`/`write_file` materialize a lazy entry before
  writing it, so a CSV or Parquet table can be written out without a separate
  copy step
- 2026-10-20 `moonbitlang/x` 0.5.5 → 0.5.6 (the latest `quickcheck`, 0.15.0,
  and `colenc` 0.1.0 are unchanged). Nothing in this tree changes behavior: it
  already uses `moonbitlang/core/encoding/utf8` rather than the now-deprecated
  `@unicode` helpers, and the new `@time` zone loading is unused here. The one
  upstream behavior change that reaches us is
  `@fs.read_file_to_string`, which the CLI uses for `--file <f>`: malformed
  UTF-8 now decodes to U+FFFD instead of dropping the trailing bytes. 200 tests
  on wasm-gc/native/js and the 27-query golden chain are unchanged

- 2026-10-19 `superbigcup325/colenc@0.1.0` is on mooncakes, so the module
  resolves its encoding kernel from the registry like any other dependency: a
  plain checkout builds after `moon update` (the dependency graph downloads on
  the first check/build/test), CI needs no workspace definition, and
  `moon publish --dry-run` validates a clean unpack again. The local-only
  `moon.work` + symlink setup is gone; the README keeps the recipe for editing
  both modules side by side

### Fixed

- 2026-10-20 a Parquet file that is both out of scope and internally
  inconsistent now reports the scope refusal: registering a table ran the
  footer row-count check before the schema gate, so a file with an unsupported
  schema *and* a wrong `num_rows` (apache/parquet-testing's
  `repeated_no_annotation.parquet` carries `num_rows = 0` over a 6-row group)
  failed with "row groups hold 6 rows, the file metadata says 0" instead of
  "nested schemas are not supported". The schema gate runs first again, so
  `harness/check_parquet_corpus.py` is back to 39 read / 29 refused by design /
  0 failing

- 2026-10-20 `harness/compare.py` judged the goldens too loosely in five ways,
  each able to pass a real divergence: an empty cell counted as SQL NULL (so
  `""` and `null` were interchangeable), every line was `strip()`ed (and TPC-H
  comments really do end in spaces, so whitespace at a row's edges was never
  compared), any numeric-looking cell was re-parsed as a double (`"001"`
  matched `"1"`, and 64-bit ids past 2^53 collapsed onto their neighbours),
  non-finite values fell through the tolerance and matched nothing — not even
  themselves — and *all* trailing blank lines were dropped although a
  single-column `""` row is a blank line. Cells now compare exact text first,
  integers exactly, decimals/exponents within 1e-9 with NaN and infinities
  handled as values, and only the terminating newline of the last row is
  dropped. `harness/check_compare.py` pins 27 cases (12 of which fail on the
  old comparator) and `check_all.sh` runs it before diffing a golden; the
  full sweep still passes

## [0.2.0] - 2026-10-16

> Not published on its own: this milestone's changes ship in `0.3.0`.

### Changed

- 2026-10-15 the Parquet path is in-house: `sources/parquet` decodes Parquet itself — Thrift compact-protocol footer and page headers, row groups, v1 data pages, PLAIN and dictionary (RLE/bit-packed hybrid) encodings, definition levels, `UNCOMPRESSED` and `SNAPPY` — and `mizchi/parquet`, together with the `mizchi/duckdb` it dragged in, is gone from the dependency graph. Scope is deliberate, not accidental: flat schemas, v1 pages, those codecs and encodings; nested fields, INT96, v2 pages, DELTA/byte-stream-split encodings and the other codecs raise pointed scan errors. Two reasons to write it: the transitive `mizchi/duckdb` shipped a legacy `moon.mod.json` that the current toolchain refuses, which made the module both unpublishable and uninstallable for consumers, and the reader was the last single-maintainer dependency in the graph. Dropping it also let `moonbitlang/quickcheck` move to 0.15.0, whose generator API now lives in `moonbitlang/core/quickcheck`
- 2026-10-13 the in-house SQL front-end (lexer, parser, AST) moved out of `engine` into its own `sql` package: the engine imports `@sql`, the AST types (`Select`, `LExpr`, `AggFn`, …) live at `@sql.*`, and the parser-side `contains_win_marker` helper is now public there; the unused `moonbit-community/sqlparser` dependency was dropped from `moon.mod`; the in-house front-end is the roadmap and sqlparser remains upstream cooperation (visibility issues/PR), not a planned swap-in
- Division and modulo follow DuckDB: `/` is true division and always yields DOUBLE (integer operands promote, `x/0` is ±inf, `0/0` is nan) instead of C-style integer division returning NULL on a zero divisor; `%` follows fmod — the result takes the dividend's sign (`-10.5 % 3` is `-1.5`) — and `x % 0` is NULL. `--json` renders non-finite floats as bare `Infinity`/`NaN` tokens, byte-identical to DuckDB's own JSON output (Python's `json` module round-trips them; strict RFC 8259 parsers do not)

### Added

- 2026-10-15 Parquet fixtures and their DuckDB goldens (`harness/gen_parquet_fixtures.py`, `harness/data/parquet`): one shape per type and coding mix — every physical type with NULLs, a low-cardinality shape that gets dictionary pages, a two-row-group shape — each generated in the codec variants the reader claims (plain/uncompressed, plain/snappy, dictionary/snappy, dictionary/uncompressed) and diffed in `check_all.sh` (now 27 goldens) so a decode bug fails the same gate the TPC-H answers do; plus fourteen decoder unit tests on hand-built buffers (compact-protocol integers and generic skipping, PLAIN layouts, the hybrid RLE/bit-packed stream including the byte-advance between runs, definition levels, malformed input raising scan errors instead of trapping)
- 2026-10-13 grace hash aggregation — when a GROUP BY's input exceeds the memory budget, the input partitions by the group-key hash into per-partition spill runs and the in-memory aggregate replays one partition at a time — equal keys land in the same partition, so each partition's group rows are final and non-combinable accumulators (median, string_agg, count-distinct) need no merge phase. Low-cardinality keys whose single partition still exceeds the budget fall back to an in-memory pass for that partition (group state cannot be split without a combine phase); over budget without a spill store is a clean error; global aggregates keep the streaming fold. Equivalence pinned by accumulator-family in-memory-vs-spilled tests over NULL-carrying keys, a 20k-row 97-group e2e with median, and a `spillagg` golden check in `check_all.sh`
- 2026-10-13 grace hash join — when a join's inputs exceed the memory budget, both sides partition by the join-key hash into per-partition spill runs and the in-memory join replays one partition at a time (all eight join flavors, the vectorized residual included); over budget without a spill store, key-less cross joins and single-key hash skew are clean errors pointing at `--memory`/`--spill-dir`. Equivalence pinned by seven-flavor in-memory-vs-spilled property tests, a 20k-row many-partition e2e, and a `spilljoin` golden check in `check_all.sh`
- 2026-10-13 CSV ingest pass — unchecked byte and array access in the scan and materialization hot paths (every index is scanner-constructed), a 9-digit int32 parse fast path with the int64 parser as fallback, single byte reads in the field loops and 64k-entry growable offset arrays: SF0.01 lineitem ingest 117 -> 105 ms (A/B, min of 9, scan phase 62 -> 42 ms), the TPC-H bench shifts down accordingly with all 27 goldens byte-identical
- 2026-10-13 join residual vectorization — a non-pushable join predicate (e.g. q19's three-way spanning OR) now decomposes into arms whose single-side conjuncts precompute Kleene true/unknown masks per joined batch pair through the vectorized kernels; only both-side conjuncts stay per-pair against a reduced row. q19 415 -> 162 ms, semantics pinned by the join oracle property, the semi/anti residual e2e battery, the 27 goldens and the duckdb-referenced pushdown fuzzer
- 2026-10-05 hot-path perf arc — typed group indexes for hash aggregation (single int/date keys hash raw `Int64`s, a single string key hashes the column's own strings, composite keys share one reusable `StringBuilder` and materialize the boxed key row once per group instead of once per row); mutable accumulator payloads allocated once per group instead of an enum rebuild per fold step; numeric aggregate inputs (sum/avg/count/stddev/variance/median over `INT`/`FLOAT64`) fold straight from the typed arrays with no boxed `Scalar` per cell; `ORDER BY` sorts the key `ColumnVector`s directly via typed comparators (no boxed decoration, no `Option` per comparison — `Scalar::compare_nn` is the new non-null total compare, also used by the spill merge and min/max folds). SF0.1 Q1 2015 -> ~1.6 s (-21%), SF0.01 Q1 187 -> 136 ms (-27%), raw-table ORDER BY -4% (scan-dominated); all 27 duckdb goldens byte-identical throughout
- 2026-10-04 external sort for ORDER BY — `ExecOptions { budget, spill }` (library `execute_with`, CLI `--memory <n>[K|M|G]` + `--spill-dir`) turns the blocking ORDER BY of non-aggregate queries into sorted runs on disk with a streaming k-way merge feeding projection/DISTINCT/OFFSET/LIMIT, so a LIMIT query's memory is the output window; engine stays fs-free via an injected SpillStore; equivalence tests (tiny budget vs in-memory, five shapes) plus a golden-chain self-consistency check pin correctness
- 2026-10-04 multi-row-group parquet coverage — the SF0.01 parquet export is a single row group, so the reader's multi-group path had never been exercised; `harness/gen_multigroup.py` writes a 4-group x 2048-row fixture with known per-group bounds (the same asset promised upstream in mizchi/parquet#4), four golden queries (full read, bounds-selective filter, aggregate over NULLs, window) run in `check_all.sh` (23 -> 27) and regenerate in both CI workflows
- 2026-10-04 window functions — `row_number()` / `rank()` / `dense_rank()` and every aggregate as `agg(expr) OVER (PARTITION BY ... ORDER BY ...) [NULLS FIRST|LAST]` in the select list, duckdb-diffed over a 29-query battery (ranking ties, NULL partition/order keys, running RANGE frames with peer sharing, GROUP BY interplay via `sum(sum(x)) OVER ()`, DISTINCT/WHERE/LIMIT composition); window markers compose inside item expressions (`v + sum(v) OVER (...)`) and outputs are referenceable by alias; explicit frame clauses and window placement outside the select list are pointed errors
- 2026-10-06 SQL-surface arc (audit gaps closed): `INTERSECT` / `EXCEPT` with ALL / DISTINCT (INTERSECT binds tighter, NULL-safe row comparison, multiset counts); correlated scalar subqueries in the select list; `EXISTS` / `NOT EXISTS` with a HAVING clause; `coalesce` / `nullif` / `greatest` / `least`; `date_trunc` / `date_diff`; `string_agg` (literal separator); `stddev` (+samp/pop), `variance` (+samp/pop), `median` (Welford); `GROUP BY` ordinals; `SELECT` without FROM; bare `NULL` select items as INTEGER
- 2026-10-06 usability arc — standalone-binary startup (`moon build cmd/main --target native --release` + one `install` line puts `moonlake` on PATH; README quickstart), `exec --file <q.sql>` to skip shell quoting entirely (trailing semicolons fine), a pointed hint when data flags are passed without the `exec` subcommand, and a CSV-reader perf pass: per-cell offsets moved from boxed arrays to trimmed FixedArrays — SF0.1 ingest -16% (1374 -> 1150 ms), end-to-end queries -11-18%, maxRSS below the previous baseline (370 -> 353 MB)
- 2026-10-06 verification arc — normalized correctness evidence beyond the SF0.01/1e-9 differential: a randomized vec-vs-scalar differential property over generated typed expression trees (batch sizes 0..4097, mutation-verified), a nested-loop hash-join oracle property across eight join flavors with hostile key distributions (mutation-verified), and `harness/fuzz_pushdown.py` (300 random predicate trees over INNER/LEFT joins, duckdb-refereed; catches WHERE-vs-key placement regressions at LEFT joins — verified by re-introducing the escape bug)
- 2026-10-05 acceptance arc — all 22 TPC-H queries now pass on their official texts (annex parameter values, duckdb-diffed within 1e-9 on SF0.01 and SF0.1; q15 in its sanctioned `WITH` form, see `harness/queries/q15.sql`):
  - `DATE +/- INTERVAL n day|month|year` arithmetic — calendar-aware month/year shifts with day-of-month clamping (`1996-03-31 + interval '1' month` = `1996-04-30`), vectorized, NULL-propagating; an `INTERVAL` literal outside date arithmetic is a bind error, and the TPC-H dbgen precision suffix (`interval '90' day (3)`) parses and is dropped
  - Correlated scalar subqueries (`expr <op> (SELECT agg(...) ... WHERE inner.col = outer.col ...)`) decorrelate into LEFT joins against the inner query grouped by the correlation keys — empty groups NULL-extend and the comparison filters, which is exactly scalar-subquery NULL semantics; the select item must contain an aggregate so groups stay single-row, and nesting works to the depth q20 asks (two correlation columns one level out)
  - Derived-table column alias lists (`FROM (SELECT ...) AS t (a, b)`) rename positionally, arity-checked
  - Non-recursive statement-level `WITH` CTEs: each body re-parses per reference (decorrelation rewrites the AST in place), a CTE name shadows catalog tables and qualifies its columns when no alias is given, later CTEs may reference earlier ones
  - The harness now carries the official TPC-H texts verbatim (`harness/queries/q1..q22.sql`), goldens are generated from the exact bytes moonlake runs, and `check_all.sh` covers 23 goldens (22 + the parquet variant) at any scale via `MOONLAKE_DATA`
- `IS NULL` / `IS NOT NULL` — the first way to test NULL-ness in a WHERE or CASE condition
- Columnar evaluation core (the first vectorization pass): `eval_vec` evaluates expressions over whole batches with typed kernels — column refs shared zero-copy, constant broadcast, same-type int32/int64/float64 arithmetic, three-valued comparison, NULL-aware AND/OR/NOT — with a per-row fallback for the remaining shapes; nine differential tests pin the vector path to the scalar interpreter cell-for-cell
- Filter, projection, aggregation inputs and ORDER BY run on the vector path: masks come from the vectorized boolean result, each output column is one pass, group keys and aggregate inputs are evaluated once per batch, and sort keys are materialized before the comparator runs
- Columnar hash join: both sides concatenate once into single batches, keys evaluate once per side, probe hits collect (left row, build row) integer pairs, and output assembles by typed per-column gathers — no row-major boxed Scalar arrays. NULL-key, residual and LEFT NULL-extension semantics are unchanged
- Bind-time projection pruning: the executor walks the bound plan, drops every unreferenced column from the pipeline (zero-copy vector subsets) and rewrites all column references. TPC-H lineitem scans narrow from 16 columns to the 2–6 the query touches; `--explain` reports the narrowed counts and renders the executed plan. `SELECT *` degenerates to an identity rewrite
- The NyaCSV-backed CSV scan is replaced by a built-in byte-level reader: one pass records per-cell offsets (RFC-4180 dialect — quoted fields with `""` escapes, commas and newlines inside quotes, LF/CRLF terminators, blank lines skipped, BOM stripped), and materialization parses numeric/boolean/date cells straight from their byte ranges, so text columns are the only ones that ever build Strings. Ingest of a 7.4 MB lineitem.csv drops 386 -> 132 ms and every bench query lands at 137–205 ms; the public `scan_string`/`scan_file` API and the wasm playground path are unchanged
- Performance pass over ingest and the join core: CSV cells materialize straight into typed FixedArrays (no boxed Scalar per cell — about a million temporaries per lineitem.csv load at SF0.01), `scan_file` reads bytes and hands them to NyaCSV without a full-file String decode, single-int join keys hash `Int64`s directly instead of building a key string per row, and row selection/batch concatenation copy FixedArray ranges instead of boxed cells. Best-of-3 on one machine: every bench query drops 16–29%, q7 (six-table join) 1040 → 483 ms cumulative against the row-at-a-time build; ingest is now the dominant remaining cost
- `NOT BETWEEN` (postfix form, three-valued negation of BETWEEN)
- `NULL` as a comparison or arithmetic operand: `v = NULL` is UNKNOWN per row, `NOT IN (1, NULL)` is empty, `v + NULL` propagates (the literal takes its type from the other operand; standalone `SELECT NULL` remains unsupported)
- `SELECT *` — expands to every FROM column, each table in FROM order; also inside derived tables

### Fixed

- 2026-10-05 spilled ORDER BY over more than 4096 result rows crashed on a destination overrun: `OutputBuilder::build` hands out capacity-sized vectors (4096) whose length exceeds `row_count`, and `copy_vec_range` copied by vector length, so `final_merge`'s multi-chunk `concat_batches` wrote past the destination (reproduced as a `check_range` trap; the existing spill fixtures stayed under one chunk, masking it). The copy now takes the live row count explicitly; regression tests cover the unit shape and a 5000-row spill merge with and without LIMIT
- 2026-10-04 mixed `ORDER BY output_col, expression` dropped the output-column key whenever an expression key was present (a two-phase sort applied only the expression keys); the binder now resolves both shapes into one written-order key list that sorts jointly — caught by the window-function tests
- 2026-10-06 silent-wrong-answer guards: `sum()` over int64 raises on overflow instead of wrapping (duckdb promotes to HUGEINT); ORDER BY / LIMIT / OFFSET on a UNION branch is a parse error instead of silently truncating that branch
- Playground: loading a CSV in the browser threw `csvText is not defined` (a leftover write to an undeclared variable in the module script), so the drag-and-drop / file-pick path silently never enabled the Run button; only the Parquet path worked. The dead store is gone and the CSV path runs end to end in the browser again
- Explicit `JOIN (SELECT ...) AS t (a, b)` syntax rejected derived tables ("expected table name after FROM") — only comma-list FROM accepted them; the shared table-reference parser now handles subqueries, WITH names, aliases and column lists on both paths
- LEFT JOIN pushdown soundness: WHERE conjuncts referencing only the build (right) table were applied as build filters, dropping build rows and letting NULL-extended probe rows survive a predicate they cannot satisfy (e.g. `... LEFT JOIN orders ON ... WHERE orders.amount > 15` returned the unmatched rows with NULL amounts). They now stay a deferred post-join filter; probe-side pushdown and ON-clause placement are unchanged
- CLI exit codes: every error path (bad SQL, unknown table/column, unreadable file, usage violation) exited 0. Errors now print a single-line message to stderr and exit 1 via a clean process exit (`moonbitlang/x/sys`), so no runtime abort stack trace trails the message; success, `--help` and `--version` remain 0
- Integer overflow wrapped silently: CSV inference and SQL literals shared a parser that ignored the int32 range, so `2147483648` came back as `-2147483648` and past int64 the sign flipped (`9223372036854775807` → `-1`). Integer parsing is now range-checked end to end: CSV columns widen int32 → int64 → float64 (DuckDB-style sniffing), SQL literals widen int32 → int64 → float64, sign-only inputs (`-`) no longer parse as `0`. The float parser's int64 digit accumulator had the same wrap on 20-digit inputs; it now accumulates in double precision (accuracy contract unchanged: 1e-9 relative)
- Keywords `year`/`month`/`day`/`date` were unusable as column names in any form (bare, qualified, aliased) and double-quoted identifiers were not supported at all — a CSV with a `day` column had no way to reference it. The DATE-part keywords now parse as names in name positions, and `"quoted"` identifiers (with `""` escape) reach every other reserved word
- A scalar subquery over zero rows raised a bind error; SQL semantics say it yields NULL, so only more than one row is now an error
- CLI: a `--date-col` naming no scanned column was a silent no-op (exit 0) that surfaced later as a confusing type mismatch — it is now a usage error; words after the quoted SQL silently glued onto the query (a stray word became a table alias) — the SQL must now be one quoted argument; a UTF-8 BOM glued onto the first CSV header cell's name — it is now stripped

## [0.1.0] - 2026-10-03

### Added

- MoonBit module skeleton (`superbigcup325/moonlake`): library package and CLI entry point (`cmd/main`)
- CLI `--version` / `--help` output
- Engine facade with version metadata and blackbox tests
- GitHub Actions CI: format check, `moon check`, tests across native / wasm-gc / js targets
- Apache-2.0 license
- W1: `types` (columnar vectors, scalars with three-valued NULL logic, epoch-day dates), `catalog`, CSV scan with type inference, engine subset parser/binder/executor, CLI `exec --csv`, TPC-H cross-validation harness (duckdb goldens, Q6 end to end)
- W2: GROUP BY hash aggregation with the v1 aggregate set (sum / avg / count / count(*) / count(distinct) / min / max), HAVING, ORDER BY (NULLS LAST) and LIMIT
- W2: CASE WHEN, LIKE and IN expressions; TRUE/FALSE literals
- W2: multi-table FROM with hash joins — comma lists, `JOIN ... ON`, `LEFT [OUTER] JOIN`, `CROSS JOIN`; WHERE/ON conjunct classification into build/probe filters, hash keys and per-pair residuals
- W2: Parquet scan adapter (`sources/parquet`) over mizchi/parquet with declared DATE columns; CLI `--parquet` / `--date-col`
- W2: TPC-H goldens for Q1 / Q3 / Q14 plus the parquet chain (q6p), `harness/check_all.sh`, and a CI job regenerating data + goldens via duckdb and cross-validating every query
- W3: TPC-H coverage to 14 of 22 queries (13 on the official text; Top Supplier rewritten — CTE inlined as a derived table), all duckdb-validated — `check_all.sh` runs 15 goldens
- W3: plain projection, table aliases with qualified columns, EXTRACT(year/month/day), derived tables (`FROM (SELECT ...) AS t`), NOT LIKE / NOT IN lists, non-correlated scalar subqueries and IN / NOT IN subqueries with SQL NULL semantics
- W3: greedy connected-first join ordering for inner-only chains; hash keys implied by OR-branch equalities (Q19)
- W3: string ordering fixed to lexicographic (`String::lexical_compare`) — MoonBit's `String::compare` is length-first and `<`/`>` are not content-ordered
- W3: CLI `--explain` (physical plan render) and `--json` (single-line JSON results); `harness/bench.py` (native vs duckdb, best of 3)
- W4: acceptance package — acceptance-facing README (ecosystem-boundary section, TPC-H scoreboard), `docs/DEMO.md` reproducible walkthrough, published to mooncakes.io as `superbigcup325/moonlake@0.1.0`
- W4: browser playground (`playground/`) — the whole engine as a wasm-gc foreign library, drop-a-CSV page with zero dependencies, GitHub Pages workflow
- W4: pre-commit gate (`hooks/`) — interface freshness, formatting, deny-warn check and tests run locally before every commit
- Polish: quickcheck property tests over the full pipeline (model-based group/aggregate oracle, join symmetry, pushdown equivalence, sum-over-groups; mutation-verified), SF0.1 cross-validation (all 15 goldens PASS on 600k+ rows) and scale-parameterized harness scripts, and Parquet drag-and-drop in the playground
