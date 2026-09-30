# moonlake

Embeddable analytical query engine for MoonBit — run SQL over CSV/Parquet files in-process, with native and WebAssembly builds from one codebase.

> **Status: early development.** The engine is under active construction; APIs will change.

## What it is

moonlake is a pure-MoonBit, columnar SQL query engine for analytical (OLAP) workloads:

- Register CSV/Parquet files as tables, run SQL, get columnar result batches.
- Ships as a native single binary for ad-hoc command-line analysis, embeddable as a MoonBit library, and compiles to WebAssembly (GC) to run in the browser.
- No FFI, no external database process, no storage engine — moonlake reads external files and computes in memory.

Planned v1 scope:

- `SELECT` / `FROM` / `WHERE` / `GROUP BY` / `HAVING` / `ORDER BY` / `LIMIT`
- `INNER` / `LEFT` / `CROSS` joins (hash join)
- Expressions: arithmetic, comparison, `CASE WHEN`, `IN`, `BETWEEN`, `LIKE`, string & math functions, `DATE` literals
- Aggregates: `sum` / `min` / `max` / `count` / `count(DISTINCT)` / `avg`
- Derived tables in `FROM`, non-correlated `IN` subqueries
- Rule-based optimizations: predicate pushdown, projection pruning

Out of scope for v1: writes (`INSERT`/`UPDATE`/DDL), persistence, transactions, indexes, correlated subqueries, window functions.

SQL correctness is validated by differential testing against DuckDB over TPC-H benchmark queries.

## Quickstart

Work in progress — SQL execution arrives with the first engine milestones.

```bash
# CLI (native build, planned)
moonlake exec --csv lineitem.csv \
  "SELECT l_returnflag, sum(l_extendedprice) FROM lineitem GROUP BY l_returnflag"
```

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
```

## Acknowledgements

moonlake is being built on top of these open-source MoonBit packages:

- [moonbit-community/sqlparser](https://github.com/moonbit-community/sqlparser) (Apache-2.0) — SQL lexer/parser
- [moonbit-community/NyaCSV](https://github.com/moonbit-community/NyaCSV) (Apache-2.0) — CSV parsing
- [mizchi/parquet](https://github.com/mizchi/parquet) (Apache-2.0) — Parquet reading
- [moonbitlang/quickcheck](https://github.com/moonbitlang/quickcheck) (Apache-2.0) — property-based testing

## License

[Apache-2.0](LICENSE)
