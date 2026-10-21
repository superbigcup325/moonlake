# TPC-H cross-validation harness (dev only, not part of the shipped package)

Generates TPC-H data with duckdb's built-in dbgen, exports CSV for
moonlake to scan, and stores duckdb's own query results as golden
files. The golden queries are the official TPC-H texts (annex
parameter values substituted, dbgen directives stripped; q15 in its
sanctioned WITH form — see `queries/q15.sql`). CI (and local
`compare.py`) diffs moonlake output against the golden files with a
1e-9 relative tolerance on floats.

## Usage

```bash
uv run --with duckdb python harness/gen_tpch.py          # SF 0.01
uv run --with duckdb python harness/gen_tpch.py 0.01     # explicit SF
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
uv run --with duckdb python harness/gen_parquet_fixtures.py   # fixtures + goldens
python3 harness/check_parquet_corpus.py                       # nightly: third-party files
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
`~/.cache/moonlake-parquet-corpus`) and requires two things of every file: in
scope, the row count must equal duckdb's; out of scope, the reader must refuse
it *by name*. It runs in the nightly workflow — the corpus is third-party data,
so it is fetched rather than committed.

## Scan benchmark (lazy scan / pushdown A/B)

```bash
moon build cmd/main --target native
python3 harness/bench_scan.py                                   # current build
python3 harness/bench_scan.py --base <old-binary>                    # A/B
uv run --with pyarrow python harness/bench_scan.py --big --base <old-binary>
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

## Writer interop (`check_writer_interop.py`)

```bash
uv run --with duckdb --with pyarrow python harness/check_writer_interop.py
```

The writer's acceptance: it writes a four-row table (int32/int64/double/string/
bool/date, NULLs, a non-ASCII string) raw and with `--snappy`, and requires
pyarrow and DuckDB to read the same schema (VARCHAR vs BLOB, DATE vs INTEGER),
values and NULLs, moonlake to read it back without `--date-col`, and DuckDB's
own `COPY … TO` output to be readable by moonlake. A separate 4000-row table
asserts that `--snappy` actually shrinks the file — four rows are all page
header. Runs on every PR (job `writer`).

## Spill lifecycle (`spill_accept.sh`)

```bash
bash harness/spill_accept.sh
```

Five checks over what a spilled query leaves behind: no directory after a
successful sort, none after a failed query, `--spill-dir` keeps files moonlake
did not write (only `run<n>.bin` is removed), `ANALYZE` under a budget reports
`spill files` / `spill bytes written` / `spill bytes read`, and an in-memory
`ANALYZE` stays silent about spilling.

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

Drives the real page in headless Chromium: CSV upload, Parquet upload with
DATE columns, two error paths, a cross-file JOIN (refused by name — the page
holds one table), a same-file self-join, and a no-uncaught-JS-error check.
Playwright is not a project dependency; a real browser is the manual step
release acceptance needs, and this script is that step written down. CI only
guards the wasm's import list (the `Playground wasm is host-free` step), which
is what silently broke the 0.3.0 page.
