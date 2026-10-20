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
