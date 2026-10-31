# moonlake

[![CI](https://github.com/superbigcup325/moonlake/actions/workflows/ci.yml/badge.svg)](https://github.com/superbigcup325/moonlake/actions/workflows/ci.yml)

Embeddable analytical query engine for MoonBit — run SQL over CSV/Parquet files in-process, with native and WebAssembly builds from one codebase.

**[Try it in your browser](https://superbigcup325.github.io/moonlake/)** — drag in one or more CSV/Parquet files, write SQL, get a columnar result, inspect the physical plan. Files register into a session you can see (name + schema), drop, and join across. No install.

> **Status: all 22 TPC-H queries pass on official texts.** The
> evaluator is columnar — vectorized expression kernels, a columnar hash
> join, and bind-time projection pruning — but APIs may still change.

## Quickstart

```bash
git clone https://github.com/superbigcup325/moonlake && cd moonlake
moon update
moon run cmd/main -- exec --csv harness/data/sf001/lineitem.csv \
  "SELECT l_returnflag, sum(l_extendedprice) FROM lineitem WHERE l_shipdate <= date '1998-09-02' GROUP BY l_returnflag ORDER BY l_returnflag"
# l_returnflag|sum_2
# A|532348211.6499983
# ...
```

The checkout carries the SF0.01 TPC-H data, so that query runs as written. CI
pins `moonc` 0.10.18 (`0.10.18+6c83a7f62`); the supported floor is 0.10.16, and a
nightly job checks `latest` separately.

For everyday use, install a standalone binary and skip `moon run`:

```bash
moon build cmd/main --target native --release
install -m755 _build/native/release/build/cmd/main/main.exe ~/.local/bin/moonlake
moonlake exec --csv lineitem.csv --file q6.sql     # SQL from a file: no shell quoting
```

As a library, `moon add superbigcup325/moonlake` and name the packages in the
`moon.pkg` of the package that imports them (`moon new` puts `main` in
`cmd/main`, so that is the file to edit):

```text
import {
  "superbigcup325/moonlake",
  "superbigcup325/moonlake/catalog",
  "superbigcup325/moonlake/sources/csv",
}
```

```moonbit nocheck
// a @catalog.Catalog with registered table entries — @csv/@parquet
// scan into one; note the argument order: content/name, not name/content.
// registration is lazy: the schema is available at once, and a query decodes
// only the columns it projects, in 2048-row batches

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

`examples/basic/` is the snippet above as a compiled package, and
`examples/stream/` is the streaming snippet in
[docs/streaming.md](docs/streaming.md): `moon run examples/basic`,
`moon run examples/stream`.

- every flag, output mode and spill behaviour: [docs/cli.md](docs/cli.md)
- reading batches instead of collecting them: [docs/streaming.md](docs/streaming.md)

> This README and the browser playground track `main`; `moon add` gives the
> latest published release from mooncakes (0.6.3). What has landed since is in
> [CHANGELOG.md](CHANGELOG.md) under Unreleased.

## What it is

moonlake is a pure-MoonBit, columnar SQL query engine for analytical (OLAP) workloads:

- Register CSV/Parquet files as tables, run SQL, get columnar result batches. CSV types are inferred (out-of-range values widen, never wrap), a ragged row is refused by row number, and the Parquet reader and writer refuse what they do not implement rather than guessing — scope, per-format rules and peak-memory numbers in [docs/sources.md](docs/sources.md)
- Ships as a native single binary for ad-hoc command-line analysis, embeds as a MoonBit library, and compiles to WebAssembly (GC) from the same codebase; the [playground](https://superbigcup325.github.io/moonlake/) is the whole engine as wasm-gc, all client-side
- No external database process or database FFI binding, no storage engine — the query engine is MoonBit; filesystem access uses `moonbitlang/x` (including its native system bindings) plus a small private native C stub (`platform/io`, POSIX) for incremental file reads and writes, which is not part of the published API and is replaced by whole-file calls on wasm-gc/js
- Queries larger than memory degrade honestly: a `--memory` budget spills a blocking `ORDER BY` to sorted runs and streams the result back, and large joins and `GROUP BY`s partition their inputs to disk the same way
- One limit is worth knowing before you meet it: wasm-gc/js scans read whole files, because their filesystem module has no ranged read (native scans read byte ranges, and the writer streams on native). [docs/ROADMAP.md](docs/ROADMAP.md) says what closing that would take, and lists the rest of the directions that are on hold with the evidence each one waits for

## Repository layout

| path | what lives there |
|---|---|
| `sql/` | lexer, parser and AST |
| `types/` | `Scalar`, `DataType`, `DataBatch` and value encodings |
| `catalog/` | table registration and the scan interface |
| `sources/csv/`, `sources/parquet/` | CSV inference and scanning; the in-house Parquet reader and writer |
| `engine/` | binder, plan, vectorized operators, joins, aggregates, windows, streaming |
| `spill/` | the spill store used by the larger-than-memory operators |
| `cmd/main/` | the `moonlake` command-line binary |
| `playground/` | the wasm-gc browser page |
| `examples/` | the README's library snippets as compiled packages |
| `harness/` | TPC-H generation, golden comparisons, benchmarks and CI drivers |
| `docs/` | demo, verification report, roadmap, devlog and design surveys |

## SQL surface

- `SELECT` (including `*`) / `FROM` (multi-table) / `WHERE` / `GROUP BY` / `HAVING` / `ORDER BY` / `LIMIT`, `INNER` / `LEFT` / `RIGHT` / `FULL` / `CROSS` joins, `UNION [ALL]` / `INTERSECT` / `EXCEPT`, derived tables, non-recursive `WITH` CTEs
- Expressions, aggregates (`count(DISTINCT)`, `median`, `string_agg`, and the explicit `approx_count_distinct` / `approx_quantile` sketches), window functions, and correlated subqueries anywhere an expression may appear — three-valued NULL logic throughout, integer overflow raises instead of wrapping
- Semantics follow DuckDB and PostgreSQL where the engines could differ — rounding, division, integer-literal widening, float → integer casts — and every deviation from C/SQLite/MySQL is stated

The full reference, including each refusal and what is out of scope, is
[docs/sql-surface.md](docs/sql-surface.md), with the approximate-aggregate rules
in [docs/sketches.md](docs/sketches.md).

## TPC-H cross-validation

SQL correctness is validated by differential testing against DuckDB over the TPC-H benchmark: **all 22 queries pass on their official texts** (annex parameter values; dbgen directives stripped) — every result matching DuckDB within 1e-9 relative tolerance on SF0.01, and the whole chain runs in CI (job `tpch` regenerates the data and DuckDB's answers from scratch, then diffs every query). One documented deviation: Q15's official text materializes a view with `CREATE VIEW ... ; SELECT ...; DROP VIEW ...` and the engine executes single statements, so the harness runs its sanctioned `WITH` spelling of the same query (`harness/queries/q15.sql`), which DuckDB answers identically.

```bash
uv run --with duckdb python harness/gen_tpch.py   # TPC-H SF0.01 data + goldens
bash harness/check_all.sh                         # 33 goldens: all PASS (22 TPC-H + parquet + encoding variants)
MOONLAKE_DATA=harness/data/sf01 bash harness/check_all.sh   # same at SF0.1 (regenerate first: gen_tpch.py 0.1)
```

Informational benchmark (SF0.01, best of 3, via `harness/bench.py`; same
machine, one run, both engines; refreshed 2026-10-31):

| query | moonlake native | duckdb |
|---|---|---|
| Pricing Summary Report (q1) | 100 ms | 3.5 ms |
| Shipping Priority (q3) | 70 ms | 3.0 ms |
| Local Supplier Volume (q5) | 77 ms | 3.7 ms |
| Forecasting Revenue Change (q6) | 68 ms | 1.1 ms |
| Volume Shipping (q7) | 83 ms | 5.4 ms |
| Product Type Profit Measure (q9) | 93 ms | 4.7 ms |
| Shipping Modes and Order Priority (q12) | 89 ms | 2.6 ms |
| Promotion Effect (q14) | 67 ms | 2.4 ms |

All 22 queries land between 10 ms and 129 ms against DuckDB's 1.1 ms to
6.1 ms; the eight above are a spread and `harness/bench.py` prints the set.
Times include process startup and reading the CSV from disk. duckdb is
in-process over pre-loaded tables — the same q6 from a fresh `read_csv_auto`
costs it 49 ms, where moonlake's built-in byte-level reader plus the columnar
evaluator (vectorized kernels, int-keyed hash joins, projection pruning,
direct-to-vector CSV materialization) lands at 67 ms. The four queries
benchmarked against the original row-at-a-time build took 539-995 ms on this
machine.

`--explain` prints the plan; a scan line states what it will read: the exact
row count when the format knows it (a Parquet footer) and `?` when it does not
(a lazy CSV scan counts nothing up front), plus `row groups: k of n read` when
statistics eliminated some. `--analyze` adds the actual row count per stage, the time
each stage took where a monotonic clock exists (native targets: `time collect`,
`time join step <n>`, `time join`, `time aggregate`, `time sort`), what a routed
join step did with its sides (`hashed the build side`, `swapped its sides`,
`partitioned`), and, under `--memory`, what the query spilled.

**Scan pushdown (2026-10-20).** Registering a table now stores its schema and
where the bytes live, not the rows; a scan produces 2048-row batches, decodes
only the columns the query projects, and skips Parquet row groups whose
statistics cannot match the pushed predicate. On the same machine and SF0.01
data, `python3 harness/bench_scan.py --base <build of the previous commit>`,
best of 5 native debug runs: q1 130→94 ms, q6 111→67 ms, q3 130→73 ms, a bare
`count(*)` over lineitem 105→48 ms, peak RSS −13…−26%. On a generated 1Mi-row
Parquet table with 8 row groups, a selective predicate drops from ~430 ms to
~50 ms and peak RSS from 130 MB to 32–39 MB.

## Docs

- **Playground** ([open](https://superbigcup325.github.io/moonlake/)): register several CSV/Parquet files in a visible session, run cross-file joins, inspect the physical plan, and drop tables or clear the session — the whole engine as wasm-gc, all client-side
- **[docs/DEMO.md](docs/DEMO.md)**: the reproducible demo, from running the engine to the DuckDB cross-check and the benchmark
- **[docs/cli.md](docs/cli.md)**: the `moonlake` command — inputs, output modes, plans, memory budgets and spilling
- **[docs/sql-surface.md](docs/sql-surface.md)**: the SQL that is accepted, the semantics it follows, and what is refused
- **[docs/sources.md](docs/sources.md)**: CSV inference and ranged scans, the Parquet reader and writer scope, streaming IO per target
- **[docs/streaming.md](docs/streaming.md)**: `stream` / `next()` — which shapes are pulled rather than collected, and the lifecycle
- **[docs/verification.md](docs/verification.md)**: the correctness and performance report (differential and property testing, pushdown fuzzing, memory and spill numbers)
- **[docs/bench-baseline.md](docs/bench-baseline.md)**: the release performance baseline (scan/join/gather/spill) and the machine it belongs to, with a committed JSON record and a `--compare` mode
- **[docs/spill-survey.md](docs/spill-survey.md)**: how six systems handle larger-than-memory queries, and where moonlake's design lands
- **[docs/devlog.md](docs/devlog.md)**: the build log, week by week
- **[docs/ROADMAP.md](docs/ROADMAP.md)**: what is being worked towards, what is refused on purpose, and what would start a direction currently on hold
- **[CHANGELOG.md](CHANGELOG.md)**: release notes

## Where moonlake sits

MoonBit's ecosystem had SQL parsers and format readers, but no query
engine over them. moonlake fills the compute layer and is designed to
sit next to, not on top of, its neighbours:

| project | what it is | boundary with moonlake |
|---|---|---|
| [moonbit-community/sqlparser](https://github.com/moonbit-community/sqlparser) | SQL lexer/parser (AST) | parsing only, no execution; moonlake runs on its own in-house front-end (lexer, parser, AST in the in-repo `sql` package) and that is the roadmap, not a placeholder: sqlparser's select-statement AST is not destructurable cross-package, so the relationship is upstream cooperation (issues/PRs), not a planned swap-in |
| [apache/parquet-format](https://github.com/apache/parquet-format) | Parquet format and encoding specs | moonlake implements the decoding itself (no dependency): the reader follows the specs and is diffed against DuckDB answers, so the format work is in-repo while the specification stays upstream |
| [shunge/arrow](https://github.com/buildliming/MoonArrow) (MoonArrow) | Arrow IPC format read/write | memory-format interchange; a future `to_arrow` bridge is cooperation, not competition |
| [uiwcvb/moonsql](https://github.com/uiwcvb/moonsql) | embedded OLTP database (row storage, CRUD, persistence) | different species — SQLite to moonlake's DuckDB: transactional storage vs external-file analytics |
| [f4ah6o/duckdb](https://github.com/f4ah6o/duckdb), mizchi/duckdb | DuckDB C++ bindings | FFI route: the wasm-gc target is a stub upstream and the binding build is unstable; moonlake is pure MoonBit and runs natively in the browser |

## Development

```bash
moon check           # type-check
moon test            # run tests on the preferred target (wasm-gc)
moon test --target native  # filesystem/native backend tests
moon fmt             # format
moon run cmd/main    # run the CLI
git config core.hooksPath hooks   # once per clone: pre-commit gate
```

The pre-commit hook runs a fast local subset of CI: interface freshness
(`moon info`), formatting, `moon check --deny-warn` and native tests. CI also
runs the wasm-gc / js test matrix, regenerates TPC-H goldens, and checks the
spill lifecycle, the real browser page and Parquet writer interop. A separate
consumer runs the packaged library on native / wasm-gc / js with freshly
resolved dependencies; it checks CSV queries, Parquet raw/Snappy round-trips,
DATE/NULL values and table removal. Reference tools are pinned in
[harness/requirements.txt](harness/requirements.txt).

**Building from source.** `main` depends on `superbigcup325/colenc@0.1.3`,
published on mooncakes, so a plain checkout builds — no workspace file needed:

```bash
moon update   # refresh the registry index; the graph downloads on the first check
moon check
```

Hacking on `colenc` and `moonlake` together still works: add a `moon.work` that
lists the sibling checkout, and the workspace version shadows the registry one:

```bash
ln -s ../colenc .colenc
printf 'members = [".", "./.colenc"]\n' > moon.work
```

Remove both again before checking what a consumer actually installs.

A release page is the `CHANGELOG.md` section for that version, not a second copy
of it: `python3 harness/release_notes.py <version>` prints the body (the title
is the bare version), `--check <version>` asserts that a published body still
matches its section, and `--lint` keeps the file in Keep a Changelog shape.

## Acknowledgements

moonlake is being built on top of these open-source packages:

- [moonbitlang/x](https://github.com/moonbitlang/x) (Apache-2.0) — filesystem, argument parsing and encoding utilities
- [moonbitlang/quickcheck](https://github.com/moonbitlang/quickcheck) (Apache-2.0) — property-based testing
- [superbigcup325/colenc](https://github.com/superbigcup325/colenc) (Apache-2.0) — Parquet DELTA, BYTE_STREAM_SPLIT and RLE encoding/decoding primitives
- [apache/parquet-format](https://github.com/apache/parquet-format) (Apache-2.0) — the Parquet format and encoding specifications that `sources/parquet` implements; its [parquet-testing](https://github.com/apache/parquet-testing) corpus supplies the files the reader is verified against
- The TPC-H query texts in `harness/queries/` are the official benchmark texts, used here for correctness validation against DuckDB; TPC-H is a trademark of the Transaction Processing Performance Council

## License

[Apache-2.0](LICENSE) © 2026 The moonlake Authors. [NOTICE](NOTICE) carries the
copyright statement and the licenses of the packages moonlake builds on.
