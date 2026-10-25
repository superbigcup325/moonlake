# Reproducible demo

Everything below runs from a fresh clone on Linux/macOS with
[MoonBit](https://docs.moonbitlang.com) (`moon` 0.1.20261016 or newer — CI
installs `latest`), and `uv` (which can supply Python 3.12). Reference tools are
pinned in `harness/requirements.txt`; a Python 3.12 virtual environment with
`pip install -r harness/requirements.txt` works too. The engine needs no
external database process or database FFI binding; filesystem access uses
`moonbitlang/x`'s system bindings.

## 1. Run the engine

```bash
git clone https://github.com/superbigcup325/moonlake && cd moonlake
moon update
moon run cmd/main -- exec --csv harness/data/sf001/lineitem.csv \
  "SELECT l_returnflag, sum(l_extendedprice) AS total FROM lineitem \
   WHERE l_shipdate <= date '1998-09-02' GROUP BY l_returnflag ORDER BY l_returnflag"
```

Expected output (pipe-separated, header first):

```
l_returnflag|total
A|532348211.6499983
N|1053887642.8199986
R|534594445.3499986
```

The same query over a Parquet file:

```bash
moon run cmd/main -- exec --parquet harness/data/sf001/lineitem.parquet \
  --date-col l_shipdate --date-col l_commitdate --date-col l_receiptdate \
  "$(cat harness/queries/q6.sql)"
# revenue
# 588352.2400000002
```

`--explain` shows the physical plan before executing:

```bash
moon run cmd/main -- exec --explain \
  --csv harness/data/sf001/customer.csv --csv harness/data/sf001/orders.csv \
  --csv harness/data/sf001/lineitem.csv "$(cat harness/queries/q3.sql)"
```

`--json` emits the result as one JSON array, printed as it arrives: the
opening `[` starts the first line and each batch adds one more, so a 2,000,000-row
result is 489 lines that `json.load` reads as one document (a result that fits
one batch is a single line). Strings are escaped and SQL NULL is `null`.

## 2. Cross-validate against DuckDB (the correctness claim)

```bash
uv run --python 3.12 --with-requirements harness/requirements.txt python harness/gen_tpch.py
uv run --python 3.12 --with-requirements harness/requirements.txt python harness/gen_parquet_fixtures.py
uv run --python 3.12 --with-requirements harness/requirements.txt python harness/gen_multigroup.py
bash harness/check_all.sh
```

`gen_tpch.py` generates TPC-H SF0.01 with DuckDB's dbgen, exports eight
tables plus a Parquet file, and stores DuckDB's own answers as golden
files. `check_all.sh` then runs every golden comparison through the CLI
(22 TPC-H, the `q6p` Parquet variant, four multi-row-group Parquet
fixtures and the reader's codec variants — 33 comparisons, counted by the
script itself) and diffs each against its golden (1e-9 relative tolerance
on floats):

```
== q6
PASS: 1 rows match duckdb golden
...
all golden queries pass
```

This is the same chain CI runs on every push (job `tpch`), regenerating
the data from scratch.

## 3. Reproduce the benchmark

```bash
moon build cmd/main --target native   # the module's preferred target is
                                      # wasm-gc; the benchmark wants native
uv run --python 3.12 --with-requirements harness/requirements.txt python harness/bench.py
```

Prints the moonlake-native vs DuckDB table from the README (best of 3
per query). Numbers vary by machine; the comparison is what is being
demonstrated, not superiority.

## 4. Tests and gates

```bash
moon check --deny-warn            # type check, warnings denied
moon test --target native         # native test suite
moon test --target wasm-gc        # same suite on wasm-gc
moon test --target js             # same suite on js
```

All three targets run the identical test suite; a bare `moon test` selects
wasm-gc, the preferred target in `moon.mod`. CI additionally covers formatting,
generated-interface freshness, the TPC-H chain, spill lifecycle, browser
acceptance and writer interop.

The pre-publish consumer gate uses the actual archive and fresh public
dependencies on all three targets, with no package upload:

```bash
python3 harness/check_release.py --check-consumer
```

After publishing a new release of the current API, validate the registry copy
without a workspace override (replace `0.5.0` with the published version):

```bash
python3 harness/check_consumer.py --registry-version 0.5.0
```
