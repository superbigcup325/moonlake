# Reproducible demo

Everything below runs from a fresh clone on Linux/macOS with
[MoonBit](https://docs.moonbitlang.com) (`moon` 0.1.20260920 pinned in
CI), Python 3, and either `uv` or `pip` for the DuckDB dependency.
Nothing else — no FFI, no database processes.

## 1. Run the engine

```bash
git clone https://github.com/superbigcup325/moonlake && cd moonlake
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

`--json` emits the result as one JSON array line (strings escaped, SQL
NULL as `null`).

## 2. Cross-validate against DuckDB (the correctness claim)

```bash
uv run --with duckdb python harness/gen_tpch.py   # or: pip install duckdb
bash harness/check_all.sh
```

`gen_tpch.py` generates TPC-H SF0.01 with DuckDB's dbgen, exports eight
tables plus a Parquet file, and stores DuckDB's own answers as golden
files. `check_all.sh` then runs all 15 golden queries through the CLI
and diffs each against its golden (1e-9 relative tolerance on floats):

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
uv run --with duckdb python harness/bench.py
```

Prints the moonlake-native vs DuckDB table from the README (best of 3
per query). Numbers vary by machine; the comparison is what is being
demonstrated, not superiority.

## 4. Tests and gates

```bash
moon check --deny-warn            # type check, warnings denied
moon test                         # native test suite
moon test --target wasm-gc        # same suite on wasm-gc
moon test --target js             # same suite on js
```

All three targets run the identical test suite. CI additionally
covers formatting, generated-interface freshness, and the TPC-H chain.
