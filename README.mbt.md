# moonlake

[![CI](https://github.com/superbigcup325/moonlake/actions/workflows/ci.yml/badge.svg)](https://github.com/superbigcup325/moonlake/actions/workflows/ci.yml)

Embeddable analytical query engine for MoonBit — run SQL over CSV/Parquet files in-process, with native and WebAssembly builds from one codebase.

> **Status: all 22 TPC-H queries pass on official texts.** The
> evaluator is columnar — vectorized expression kernels, a columnar hash
> join, and bind-time projection pruning — but APIs may still change.

## What it is

moonlake is a pure-MoonBit, columnar SQL query engine for analytical (OLAP) workloads:

- Register CSV/Parquet files as tables, run SQL, get columnar result batches. CSV column types are inferred (int32 → int64 → float64 for integers that outgrow their type, bool, date, string) — out-of-range values widen, never wrap.
- Ships as a native single binary for ad-hoc command-line analysis, embeds as a MoonBit library, and compiles to WebAssembly (GC) from the same codebase.
- No FFI, no external database process, no storage engine — moonlake reads external files and computes in memory.

### SQL surface

- `SELECT` (including `*`) / `FROM` (multi-table) / `WHERE` / `GROUP BY` / `HAVING` / `ORDER BY` / `LIMIT`
- `INNER` / `LEFT` / `RIGHT` / `FULL` / `CROSS` joins, `UNION [ALL]` (hash join; join order chosen greedily by connectivity, LEFT keeps written order)
- Expressions: arithmetic, comparison, `CASE WHEN`, `IN`, `NOT IN`, `BETWEEN`, `NOT BETWEEN`, `LIKE`, `NOT LIKE`, `IS [NOT] NULL`, `NULL` as a comparison/arithmetic operand, `EXTRACT(year/month/day)`, `DATE` literals, `date +/- INTERVAL n day/month/year` (calendar-aware, day-of-month clamping), `CAST`, string functions (`substring` — both argument styles, `length`, `upper`, `lower`, `concat`), `abs`, `round`, three-valued NULL logic throughout. Division is DuckDB-style: `/` is always DOUBLE (`x/0` is ±inf, `0/0` is nan) and `%` follows fmod (`x % 0` is NULL). Integer literals widen int32 → int64 → float64 to stay exact. Identifiers: the DATE-part keywords `year`/`month`/`day`/`date` double as bare column/table/alias names; double-quoted identifiers (`"left"`, with `""` escape) reach every other reserved word
- Aggregates: `sum` / `avg` / `min` / `max` / `count` / `count(*)` / `count(DISTINCT)`
- Subqueries: correlated `EXISTS` / `NOT EXISTS` / `IN` / `NOT IN` (decorrelated to semi/anti joins, residuals and all) and correlated scalar aggregate subqueries (decorrelated to grouped LEFT joins) — nested to the depth TPC-H asks; derived tables (`FROM (SELECT ...) AS t`), with optional column alias lists (`AS t (a, b)`)
- `WITH name AS (SELECT ...)` — non-recursive CTEs, statement level; a name is its own qualifier, later CTEs may reference earlier ones
- Pushdown: single-table predicates from WHERE/ON are applied as build/probe filters at each hash join; equalities become hash keys even when implied by disjunctions. At joins that preserve a side (`LEFT`/`RIGHT`/`FULL`), WHERE predicates — spanning ones included — stay post-join so NULL-extended rows still meet them

Out of scope: writes (`INSERT`/`UPDATE`/`CREATE TABLE`/DDL beyond CTEs), persistence, transactions, indexes, window functions, cost-based optimization, multi-statement scripts.

### TPC-H cross-validation

SQL correctness is validated by differential testing against DuckDB over the TPC-H benchmark: **all 22 queries pass on their official texts** (annex parameter values; dbgen directives stripped) — every result matching DuckDB within 1e-9 relative tolerance on SF0.01, and the whole chain runs in CI (job `tpch` regenerates the data and DuckDB's answers from scratch, then diffs every query). One documented deviation: Q15's official text materializes a view with `CREATE VIEW ... ; SELECT ...; DROP VIEW ...` and the engine executes single statements, so the harness runs its sanctioned `WITH` spelling of the same query (`harness/queries/q15.sql`), which DuckDB answers identically.

```bash
uv run --with duckdb python harness/gen_tpch.py   # TPC-H SF0.01 data + goldens
bash harness/check_all.sh                         # 23 goldens: all PASS (22 + parquet variant)
MOONLAKE_DATA=harness/data/sf01 bash harness/check_all.sh   # same at SF0.1 (regenerate first: gen_tpch.py 0.1)
```

Informational benchmark (SF0.01, best of 3, via `harness/bench.py`;
same machine, one run, both engines:

| query | moonlake native | duckdb |
|---|---|---|
| Pricing Summary Report | 205 ms | 3.6 ms |
| Shipping Priority | 168 ms | 3.5 ms |
| Local Supplier Volume | 173 ms | 4.1 ms |
| Forecasting Revenue Change | 137 ms | 1.1 ms |
| Volume Shipping | 185 ms | 3.4 ms |
| Returned Item Reporting | 171 ms | 4.8 ms |
| Shipping Modes and Order Priority | 171 ms | 4.1 ms |
| Promotion Effect | 146 ms | 1.2 ms |

These are the eight queries `harness/bench.py` runs (it prints the
same rows labelled q1–q14). Times include process startup and reading
the CSV from disk. duckdb is in-process over pre-loaded tables — the
same query from a fresh `read_csv_auto` costs it ~55 ms, where
moonlake's built-in byte-level reader plus the columnar evaluator
(vectorized kernels, int-keyed hash joins, projection pruning,
direct-to-vector CSV materialization) lands at 137–205 ms, down
5–8x from the original row-at-a-time build on the same machine.

## Quickstart

```bash
git clone https://github.com/superbigcup325/moonlake && cd moonlake
moon run cmd/main -- exec --csv harness/data/sf001/lineitem.csv \
  "SELECT l_returnflag, sum(l_extendedprice) FROM lineitem WHERE l_shipdate <= date '1998-09-02' GROUP BY l_returnflag ORDER BY l_returnflag"
# l_returnflag|sum_2
# A|532348211.6499983
# ...
```

Joins take one `--csv` per table; `--parquet` scans Parquet files (declare epoch-day DATE columns with `--date-col`); `--explain` prints the physical plan; `--json` emits machine-readable output.

As a library:

```bash
moon add superbigcup325/moonlake
```

```moonbit nocheck
// a @catalog.Catalog with registered table entries — @csv/@parquet
// scan into one; note the argument order: content/name, not name/content

///|
fn main raise {
  let cat = @catalog.Catalog::new()
  cat.register(@csv.scan_string("region,amount\nnorth,100\n", "events"))

  // read results back cell by cell: names() gives the columns,
  // row_count() the rows, get(row, col) a @types.Scalar (null via Null)
  let result = @moonlake.execute(
    "SELECT region, count(*) FROM events GROUP BY region", cat,
  )
  for r in 0..<result.row_count() {
    println(result.get(r, 0).to_string() + "|" + result.get(r, 1).to_string())
  }
}
```

## Where moonlake sits

MoonBit's ecosystem had SQL parsers and format readers, but no query
engine over them. moonlake fills the compute layer and is designed to
sit next to, not on top of, its neighbours:

| project | what it is | boundary with moonlake |
|---|---|---|
| [moonbit-community/sqlparser](https://github.com/moonbit-community/sqlparser) | SQL lexer/parser (AST) | parsing only, no execution; moonlake ships an in-house subset front-end today (sqlparser's select-statement AST is not destructurable cross-package yet) and stays pinned as the future swap-in once its visibility improves |
| [mizchi/parquet](https://github.com/mizchi/parquet) | Parquet reader/writer | format decoding only; moonlake adapts its columnar read into the same vectors the executor consumes |
| [shunge/arrow](https://github.com/buildliming/MoonArrow) (MoonArrow) | Arrow IPC format read/write | memory-format interchange; a future `to_arrow` bridge is cooperation, not competition |
| [uiwcvb/moonsql](https://github.com/uiwcvb/moonsql) | embedded OLTP database (row storage, CRUD, persistence) | different species — SQLite to moonlake's DuckDB: transactional storage vs external-file analytics |
| [f4ah6o/duckdb](https://github.com/f4ah6o/duckdb), mizchi/duckdb | DuckDB C++ bindings | FFI route: the wasm-gc target is a stub upstream and the binding build is unstable; moonlake is pure MoonBit and runs natively in the browser |

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
commit — the same gates CI runs. CI covers native / wasm-gc / js test
matrices plus the TPC-H cross-validation job.

## Acknowledgements

moonlake is being built on top of these open-source MoonBit packages:

- [moonbit-community/sqlparser](https://github.com/moonbit-community/sqlparser) (Apache-2.0) — SQL lexer/parser
- [mizchi/parquet](https://github.com/mizchi/parquet) (Apache-2.0) — Parquet reading
- [moonbitlang/quickcheck](https://github.com/moonbitlang/quickcheck) (Apache-2.0) — property-based testing

## License

[Apache-2.0](LICENSE)
