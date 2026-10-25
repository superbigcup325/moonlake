# TPC-H cross-validation harness (dev only, not part of the shipped package)

Generates TPC-H data with duckdb's built-in dbgen, exports CSV for
moonlake to scan, and stores duckdb's own query results as golden
files. The golden queries are the official TPC-H texts (annex
parameter values substituted, dbgen directives stripped; q15 in its
sanctioned WITH form — see `queries/q15.sql`). CI (and local
`compare.py`) diffs moonlake output against the golden files with a
1e-9 relative tolerance on floats.

## Usage

CI uses Python 3.12 with DuckDB/PyArrow pinned in `harness/requirements.txt`.
The `uv` commands below use the same versions; alternatively install that file
in a Python 3.12 virtual environment and run the scripts with its `python`.

```bash
uv run --python 3.12 --with-requirements harness/requirements.txt python harness/gen_tpch.py       # SF 0.01
uv run --python 3.12 --with-requirements harness/requirements.txt python harness/gen_tpch.py 0.01  # explicit SF
MOONLAKE_DATA=harness/data/sf01 bash harness/check_all.sh  # validate at SF 0.1
```

Outputs land in `harness/data/sf<sf>/`:

- `customer.csv` / `orders.csv` / `lineitem.csv` / `part.csv` — the
  tables the golden queries scan
- `lineitem.parquet` — lineitem with decimals cast to double, for the
  parquet scan chain
- `q<NN>_golden.txt` for every `queries/q<NN>.sql` (22 TPC-H queries
  plus the `q6p` parquet variant) — duckdb's answers, pipe-separated
  with a header line (same shape as the moonlake CLI output)

## Compare

`compare.py` skips the header (engines label columns differently) and
compares cells in order: identical text is equal; integers exact (so
`001` differs from `1` and 64-bit ids keep their digits); numbers carrying
a decimal point or exponent within a 1e-9 relative tolerance, with NaN
equal to NaN and infinities equal to themselves; everything else exact,
whitespace included. SQL NULL is the cell `null` — both engines print
that marker and it never equals an empty string. Blank lines are rows with
a single `""` cell, so only the terminating newline of the last row is
dropped. `check_compare.py` self-tests those rules; `check_all.sh` runs it
before diffing any golden.

```bash
moon run cmd/main -- exec --csv harness/data/sf001/lineitem.csv \
  "$(cat harness/queries/q6.sql)" > /tmp/out.txt
python3 harness/compare.py harness/data/sf001/q6_golden.txt /tmp/out.txt
```

`check_all.sh` runs every golden query through the CLI and diffs each
against its golden file; multi-table queries pass one `--csv` per
table, and the parquet chain passes `--parquet` plus the DATE columns
via `--date-col`. The data directory comes from `MOONLAKE_DATA`
(default `harness/data/sf001`); point it at `harness/data/sf01` for
the SF0.1 cross-validation. CI runs the same script after regenerating
the data from scratch (job `tpch`).

## Parquet fixtures and the corpus check

Two more generators feed the in-house Parquet reader's gates:

```bash
uv run --python 3.12 --with-requirements harness/requirements.txt python harness/gen_parquet_fixtures.py
uv run --python 3.12 --with-requirements harness/requirements.txt python harness/check_parquet_corpus.py
```

`gen_parquet_fixtures.py` writes `harness/data/parquet/<shape>/<variant>/t.parquet`
plus one duckdb golden per shape. The table name the CLI registers is the file
stem, so every fixture is `t.parquet` and the queries in `queries/pq*.sql`
reference `t`; variants of one shape share that shape's golden (the reader is
supposed to be codec-independent). Shapes: every physical type with NULLs, a
low-cardinality shape that gets dictionary pages, and a two-row-group shape;
variants cover plain/uncompressed, plain/snappy, dictionary/snappy,
dictionary/uncompressed and two row groups. `check_all.sh` diffs all of them.

`check_parquet_corpus.py` downloads apache/parquet-testing (cached in
`~/.cache/moonlake-parquet-corpus`). In scope, every column must decode, row
counts must agree and a five-row sample from up to three columns must match
DuckDB cell for cell. Out of scope, the reader must refuse *by name*. Each
file's class is recorded in `parquet_corpus_expected.json`; a class change,
Python/API error or recorded file missing from the verified results fails the
gate, including a run where DuckDB skips everything. New files are reported
for review. By default the gate drives `moon run cmd/main`, which is the wasm-gc build, and
`eprintln` has no stderr channel on that target (`moonbitlang/core` documents the
fallback to stdout), so a refusal arrives on stdout there. The gate reads either
stream and records which one, which keeps the default invocation as strict as
CI's: CI pins `MOONLAKE_BIN` to the native binary, where every diagnostic is on
stderr.

`test_parquet_corpus.py` checks the gate's success and failure paths
on every PR. The full corpus runs nightly; third-party data is fetched rather
than committed.

## Scan benchmark (lazy scan / pushdown A/B)

```bash
moon build cmd/main --target native
python3 harness/bench_scan.py                                   # current build
python3 harness/bench_scan.py --base <old-binary>                    # A/B
uv run --python 3.12 --with-requirements harness/requirements.txt python harness/bench_scan.py --big --base <old-binary>
```

`bench_scan.py` times the queries that exercise the scan layer (CSV column
pruning on q1/q6/q3 and `count(*)`, Parquet on q6p and a one-column aggregate)
against a binary of your choice, reporting the fastest wall time of `--runs`
after one warm-up and the peak RSS from `/proc/<pid>/status` (`VmHWM`). `--big`
first generates a 1Mi-row, 8-row-group Parquet table with statistics, which is
what makes the row-group skipping measurable. `gen_parquet_stats.py` writes the
small fixtures (`harness/data/parquet/stats/`) that the lazy-scan unit tests
embed as hex; it needs pyarrow rather than duckdb because duckdb floors
`ROW_GROUP_SIZE` at 2048 rows.

## Release baseline (`bench_release.py`)

```bash
python3 harness/bench_release.py                     # measure, print a table
python3 harness/bench_release.py --json-out harness/baseline/<date>-<version>.json
python3 harness/bench_release.py --compare harness/baseline/2026-10-20-0.3.1.json
```

Every record also carries the dataset's SHA-256 and each case's `sql`, so
"same work, faster" can be checked against the workload itself rather than a
prose description of it; the `spill/*` cases ask `ANALYZE` to prove the spill
(and assert the spill directory is empty afterwards) because the engine now
removes its run files.

One record, one machine: scan (CSV/Parquet), join (2-table and Q3), gather
(the filter/join output-assembly paths), and spill (in-query external sort
plus the MLSPILL3 write/read). It builds the native release binary, records
the toolchain, CPU/governor/kernel, git commit, binary hash and load average,
times the fastest of `--runs` (default 7) after two warm-ups with both wall
and CPU time, and hashes each case's stdout so `--compare` can tell "same
work, different speed" from "the result changed". `harness/baseline/` holds
one committed record per release (`<date>-<version>.json`);
`docs/bench-baseline.md` is the human-readable one, including the measured
noise floor (±7% within a session, up to ~25% across sessions on the same
binary). Numbers are only comparable on the same machine and data (TPC-H
SF0.1, tracked in `harness/data/sf01`; SF0.01 was too short to survive host
noise).

Answers are checked, not just hashed: after the timed runs each case's output
is compared against DuckDB over the same files, outside the timed region, and a
mismatch aborts the record. `--check-oracles` runs only that check (nightly
uses it on the debug binary), `--no-oracle` skips it and says so — a stable
wrong answer used to hash exactly as consistently as a right one, and that is
how a broken spilled sort was recorded as a baseline. Comparator behaviour is
covered by `test_bench_release.py` (environment/data mismatch refusal, changed
or unstable output, missing fields, added/removed cases, the run-spread band),
which runs with the other Python tests and needs no data or timings.

## Release provenance (`check_release.py`)

```bash
python3 harness/check_release.py                  # offline: versions, archive, clean tree
python3 harness/check_release.py --check-consumer  # fresh dependencies, three targets; no upload
python3 harness/check_release.py --publish-dry-run  # also the publish gate (needs `moon login`)
```

Run on every `v*` tag by the `release` workflow. It refuses a tag when the
version claims disagree (`moon.mod` / `moonlake.mbt` `VERSION` / the newest
CHANGELOG heading / the tag), when `moon package --list` carries a dev-only path
(a dot-directory, `moon.work`, `harness/data/`, the bench drivers, `hooks/`, …)
or when the tree is dirty. The release workflow also runs `--check-consumer`.
Note that `moon package --list` prints its list to stderr, below the
`moon check` it runs first.

## Packaged and published consumers (`check_consumer.py`)

```bash
python3 harness/check_consumer.py                         # package this checkout, test its archive
python3 harness/check_consumer.py --archive /path/to/moonlake.zip
python3 harness/check_consumer.py --registry-version 0.4.0  # only after publishing the current API
```

The default gate builds `moon package`, extracts the zip into a temporary
directory and copies `harness/consumer/` into a separate downstream module.
Only the extracted package and the consumer become workspace members. A fresh
`MOON_HOME` reuses the installed compiler/core but fetches its own registry and
dependency graph: no login credentials, existing `.mooncakes`, local colenc
checkout or source checkout can satisfy the package import. The archive hash,
toolchain and results can be recorded with `--json-out`.

On native / wasm-gc / js, the public API must report the expected version and
return identical CSV and raw/Snappy Parquet query results, including DATE and
NULLs; dropping a table must remove it. The per-PR `check` job runs this gate.
It does not upload an archive. `--registry-version` removes the workspace
override and checks the published current API after an authorized release; an
archive-consumer pass is not registry-install evidence.

## Kernel benchmark (`kernel_bench/`)

```bash
moon run --target native --release harness/kernel_bench
moon run --target native --release harness/kernel_bench -- --rows 200000 --runs 9
```

The kernel-level complement to `bench_release.py`: tables are materialized in
memory and split into 4096-row batches like a scan produces, so a case times the
operator instead of the ingest. Cases are paired so that the difference between
two of them isolates one structural cost — one int key vs two int keys vs a
string key, narrow vs wide vs nullable gather. It is how the packed two-key
join (`69 ms → 14 ms` on 100k rows) was found and accepted; the numbers and the
noise caveat are in [`docs/bench-baseline.md`](../docs/bench-baseline.md).
Every case now verifies its answer outside the timed region before printing a
number: the count cases must return the built row count, and the gather cases
must match an order-independent row bag (count plus the sum of per-row hashes)
over the source table they select from. A wrong answer aborts the run. The same
rule applies to `spill_bench.py`, which recomputes the first column's text
checksum from the CSV instead of trusting the format's write/read checksum
pair.

## Window differential (`check_windows.py`)

```bash
moon build cmd/main --target native
MOONLAKE_BIN=_build/native/debug/build/cmd/main/main.exe \
  uv run --python 3.12 --with-requirements harness/requirements.txt \
  python harness/check_windows.py
# nightly uses a seeded 400-row fixture instead of the fixed nine rows:
python harness/check_windows.py --random 400 --seed 20261023
```

This replays the window battery that `docs/verification.md` §5.1 only records
as history: a fixed nine-row fixture (tied values, NULL sort keys, a NULL
partition key) and 22 cases over the three ranking functions, whole-partition
and running frames, `DISTINCT` aggregates, two windows in one select list,
windows after aggregation, window values inside row expressions, and the
documented refusals. A total order means rows compare in sequence through
`compare.py`; without one they compare as a multiset with duplicate counts, so
ties cannot fake a mismatch. An order-free `string_agg` is asserted for row
count only, and refusals are counted apart from matches: valid SQL we refuse
must run in DuckDB (a documented limit), SQL the standard forbids must be
refused by both. `--fixture <csv>` replays your own data (copied in as `t.csv`).
Exit codes: 0 matched, 1 mismatch or gate failure, 2 environment/referee
problem — there is no skip path.

## Parquet encoding evidence (`check_colenc_fixtures.py`)

```bash
moon build cmd/main --target native
MOONLAKE_BIN=_build/native/debug/build/cmd/main/main.exe \
  uv run --python 3.12 --with-requirements harness/requirements.txt \
  python harness/check_colenc_fixtures.py
```

Three kinds of evidence, kept apart: the **embedded** hex fixtures in
`sources/parquet/colenc_integration_test.mbt` (they run on every target with no
file system), the **regenerable** set under `harness/data/parquet/colenc/`
(built by `gen_colenc_fixtures.py`, pinned in `harness/colenc_fixtures.json`),
and the **upstream corpus** in `check_parquet_corpus.py`. For the first two the
gate reads the actual page headers (`harness/parquet_pages.py`), so a file whose
data pages are v2 or a different encoding fails instead of hiding behind the
footer's encoding list; values are then decoded by PyArrow and by the CLI and
compared cell for cell. Regenerate only with the versions in
`harness/requirements.txt`; a fixture that stops demonstrating its encoding, or
a disabled decoder, fails the gate.

## Writer interop (`check_writer_interop.py`)

```bash
uv run --python 3.12 --with-requirements harness/requirements.txt python harness/check_writer_interop.py
```

The writer's acceptance: it writes a four-row table (int32/int64/double/string/
bool/date, NULLs, a non-ASCII string) raw and with `--snappy`, and requires
pyarrow and DuckDB to read the same schema (VARCHAR vs BLOB, DATE vs INTEGER),
values and NULLs, moonlake to read it back without `--date-col`, and DuckDB's
own `COPY … TO` output to be readable by moonlake. A separate 4000-row table
asserts that `--snappy` actually shrinks the file — four rows are all page
header. Runs on every PR (job `writer`).

## Dictionary survey (`dict_survey.py`)

```bash
moon build cmd/main --target native --release
uv run --python 3.12 --with-requirements harness/requirements.txt \
  python harness/dict_survey.py --rows 500000
python harness/dict_survey.py --rows 500000 --row-group 65536   # the control layout
```

W0's investigation, and the numbers behind verification §35. It builds a seeded
500,000-row access log (a monotonic clock, a 20k-valued id, tiny enumerations, a
repetitive long string, a near-unique long string, a boolean, a 40%-NULL note),
writes it with PyArrow as plain+snappy, dictionary-on-everything and
dictionary-on-the-winning-columns, and writes the same rows with `moonlake write
--snappy`. It reports per-column byte deltas (and whether PyArrow actually used
a dictionary or fell back), whole-file bytes, write time, DuckDB read time, our
reader's time and peak RSS, and the control run at PyArrow's 65,536-row groups.
Every file must return the same answer — floats to a relative tolerance, since a
double sum is not associative — or the script refuses. It is a measurement, not
a gate: no exit status depends on the numbers.

## Spill lifecycle (`spill_accept.sh`)

```bash
bash harness/spill_accept.sh
```

Seven checks over what a spilled query leaves behind: no directory after a
successful sort, none after a failed query, a shared `--spill-dir` keeps the
caller's files, `ANALYZE` under a budget reports `spill files` / `spill bytes
written` / `spill bytes read`, an in-memory `ANALYZE` stays silent, concurrent
queries sharing a directory do not collide, and a new query leaves an
interrupted run's files alone. Every query owns its own `moonlake-spill-<n>`
subdirectory; normal cleanup removes only that query's runs. SIGKILL leaves
the subdirectory behind because the current filesystem API cannot establish
that its owner is dead.

## Playground acceptance (`playground_accept.cjs`)

```bash
moon build --target wasm-gc playground
mkdir -p /tmp/site && cp playground/index.html /tmp/site/ \
  && cp _build/wasm-gc/debug/build/playground/playground.wasm /tmp/site/
python3 -m http.server 8971 --directory /tmp/site &
PLAYWRIGHT_MODULE=/path/to/node_modules/playwright \
  node harness/playground_accept.cjs http://127.0.0.1:8971/index.html
```

Runs on every PR (job `playground`, which installs Playwright and Chromium).
The first check requires the exact version in this checkout's `moon.mod`, so
a stale page cannot pass just because it prints some version. To check a
different release intentionally, set `MOONLAKE_EXPECT_VERSION=<version>`.

Drives the real page in headless Chromium with 15 checks: several files
registered in one session, schema listing, cross-file JOINs, the physical plan,
duplicate-name refusal, dropping a table, clearing the session, CSV and Parquet
agreeing cell for cell (including DATE columns), visible query errors and no
uncaught JS errors. The `playground` CI job runs this browser acceptance in
addition to the `Playground wasm is host-free` import gate, which catches the
class of failure that broke the 0.3.0 page. Playwright remains a dev-only tool.
