# moonlake

Embeddable analytical query engine for MoonBit — run SQL over CSV/Parquet files in-process, with native and WebAssembly builds from one codebase.

> **Status: early development.** The engine is under active construction; APIs will change.

## What it is

moonlake is a pure-MoonBit, columnar SQL query engine for analytical (OLAP) workloads:

- Register CSV/Parquet files as tables, run SQL, get columnar result batches.
- Ships as a native single binary for ad-hoc command-line analysis, embeddable as a MoonBit library, and compiles to WebAssembly (GC) to run in the browser.
- No FFI, no external database process, no storage engine — moonlake reads external files and computes in memory.

Planned v1 scope (landing milestone by milestone — GROUP BY /
HAVING / ORDER BY / LIMIT, all v1 aggregates, CASE WHEN / IN / LIKE,
INNER / LEFT / CROSS hash joins over multi-table FROM, and the Parquet
scan already work; see CHANGELOG):

- `SELECT` / `FROM` / `WHERE` / `GROUP BY` / `HAVING` / `ORDER BY` / `LIMIT`
- `INNER` / `LEFT` / `CROSS` joins (hash join)
- Expressions: arithmetic, comparison, `CASE WHEN`, `IN`, `BETWEEN`, `LIKE`, string & math functions, `DATE` literals
- Aggregates: `sum` / `min` / `max` / `count` / `count(DISTINCT)` / `avg`
- Derived tables in `FROM`, non-correlated `IN` subqueries
- Rule-based optimizations: predicate pushdown, projection pruning

Out of scope for v1: writes (`INSERT`/`UPDATE`/DDL), persistence, transactions, indexes, correlated subqueries, window functions.

SQL correctness is validated by differential testing against DuckDB over TPC-H benchmark queries.

## Quickstart

```bash
git clone https://github.com/superbigcup325/moonlake && cd moonlake
moon run cmd/main -- exec --csv harness/data/sf001/lineitem.csv \
  "SELECT l_returnflag, sum(l_extendedprice) FROM lineitem WHERE l_shipdate <= date '1998-09-02' GROUP BY l_returnflag ORDER BY l_returnflag"
# l_returnflag|sum_2
# A|532348211.6499983
# ...
```

Joins take one `--csv` per table; `--parquet` scans Parquet files
(declare epoch-day DATE columns with `--date-col`). Every golden query
is cross-validated against DuckDB (python3 + duckdb, or uv):

```bash
uv run --with duckdb python harness/gen_tpch.py   # TPC-H SF0.01 data + goldens
bash harness/check_all.sh                         # q6 q1 q3 q14 q6p: all PASS
```

The same chain runs in CI (job `tpch`) after regenerating the data from
scratch.

**TPC-H scoreboard**: 14 of 22 queries runnable (11 direct + 3 with the
sanctioned rewrites — derived tables, scalar subqueries), all matching
DuckDB within 1e-9 relative tolerance on SF0.01.

Informational benchmark (SF0.01, best of 3, reproducible via
`harness/bench.py`; row-at-a-time evaluation, vectorization pending):

| query | moonlake native | duckdb |
|---|---|---|
| q6 | 539 ms | 0.7 ms |
| q1 | 622 ms | 3.0 ms |
| q3 | 713 ms | 4.8 ms |
| q7 | 995 ms | 4.3 ms |

As a library (once published to mooncakes.io):

```bash
moon add superbigcup325/moonlake
```

## Development

```bash
moon check           # type-check
moon test            # run tests
moon fmt             # format
moon run cmd/main    # run the CLI
git config core.hooksPath hooks   # once per clone: pre-commit gate
```

The pre-commit hook re-runs interface freshness (`moon info`),
formatting, `moon check --deny-warn` and the tests before every
commit — the same gates CI runs.

## Acknowledgements

moonlake is being built on top of these open-source MoonBit packages:

- [moonbit-community/sqlparser](https://github.com/moonbit-community/sqlparser) (Apache-2.0) — SQL lexer/parser
- [moonbit-community/NyaCSV](https://github.com/moonbit-community/NyaCSV) (Apache-2.0) — CSV parsing
- [mizchi/parquet](https://github.com/mizchi/parquet) (Apache-2.0) — Parquet reading
- [moonbitlang/quickcheck](https://github.com/moonbitlang/quickcheck) (Apache-2.0) — property-based testing

## License

[Apache-2.0](LICENSE)
