# moonlake

[![CI](https://github.com/superbigcup325/moonlake/actions/workflows/ci.yml/badge.svg)](https://github.com/superbigcup325/moonlake/actions/workflows/ci.yml)

Embeddable analytical query engine for MoonBit — run SQL over CSV/Parquet files in-process, with native and WebAssembly builds from one codebase.

**[Try it in your browser](https://superbigcup325.github.io/moonlake/)** — drag in one or more CSV/Parquet files, write SQL, get a columnar result, inspect the physical plan. Files register into a session you can see (name + schema), drop, and join across. No install.

> **Status: all 22 TPC-H queries pass on official texts.** The
> evaluator is columnar — vectorized expression kernels, a columnar hash
> join, and bind-time projection pruning — but APIs may still change.

## What it is

moonlake is a pure-MoonBit, columnar SQL query engine for analytical (OLAP) workloads:

- Register CSV/Parquet files as tables, run SQL, get columnar result batches. CSV column types are inferred (int32 → int64 → float64 for integers that outgrow their type, bool, date, string) — out-of-range values widen, never wrap.
- Parquet decoding is in-house (`sources/parquet`) and scoped on purpose: flat schemas, v1 data pages, PLAIN, dictionary, the DELTA family and BYTE_STREAM_SPLIT page encodings (the last five through colenc), RLE boolean values, `UNCOMPRESSED` and `SNAPPY`. Nested fields, INT96 timestamps, v2 pages, DECIMAL, UINT_32/UINT_64 and the other codecs are refused with a pointed error rather than guessed at (a decimal byte array read as text, or a UINT taken as signed, would be a wrong answer rather than a refusal). Writing is the same scope and now speaks the format rather than merely the encoding: `write_bytes` / `write_file` emit one row group per batch with v1 pages, PLAIN values, `STRING`/`DATE` annotations, and per-column-chunk statistics (`min_value`/`max_value`/`null_count`), so moonlake's own output is prunable by its own reader; `--snappy` (library: `write_bytes_with`) stores pages compressed, and `moonlake write --csv in.csv --out out.parquet` is the CLI path. Every column is written OPTIONAL with RLE definition levels (about one bit per value on disk, and what pyarrow does by default): that is what lets the input stream through one batch at a time instead of being materialized, since a REQUIRED schema would have to be decided before the first page is written. On native targets the file path streams: pages go straight to a file handle and a temporary name is renamed over the target, so peak memory no longer grows with the output (326 MB → 101 MB writing a 75 MB file from Parquet input) and a failed write leaves the previous file intact; wasm-gc/js keep the whole-file write their hosts require, behind the same `write_file_with` signature. `harness/check_writer_interop.py` reads the result with pyarrow and DuckDB and reads a DuckDB-written file back. Reading is incremental in the same way: on native targets a scan reads the 8-byte trailer and the footer, then one column chunk per projected column per row group, so peak memory is a couple of row groups' columns rather than the file (`count(*)` over a 287 MB archive: 295 MB → 12 MB of peak RSS); `scan_bytes` and the wasm-gc/js builds keep their whole-input behaviour behind the same signatures. CSV scans are ranged the same way: registration reads a 64 KB prefix (header plus the inference sample) and a scan reads one 4 MB range at a time, indexing, materializing and dropping each range, so the per-cell offset table is one range rather than the file (`count(*)` over a 302 MB CSV: 1063 MB → 35 MB of peak RSS, 1.36 s → 0.64 s, and `write --csv` on the same input 1063 MB → 35 MB with byte-identical output).
- Ships as a native single binary for ad-hoc command-line analysis, embeds as a MoonBit library, and compiles to WebAssembly (GC) from the same codebase.
- One limit is worth knowing before you meet it: wasm-gc/js scans read whole
  files, because their filesystem module has no ranged read (native scans read
  byte ranges, and the writer streams on native). [docs/ROADMAP.md](docs/ROADMAP.md)
  says what closing that would take, and lists the rest of the directions that
  are on hold with the evidence each one waits for.
- No external database process or database FFI binding, no storage engine — the query engine is MoonBit; filesystem access uses `moonbitlang/x` (including its native system bindings) plus a small private native C stub (`platform/io`, POSIX) for incremental file reads and writes, which is not part of the published API and is replaced by whole-file calls on wasm-gc/js. moonlake reads external files and computes in memory. Queries larger than memory degrade honestly: a CLI `--memory` budget (library `execute_with` + a spill store) spills a blocking `ORDER BY` to sorted runs and streams the result back; large joins and GROUP BYs partition their inputs to disk the same way.

### SQL surface

- `SELECT` (including `*`) / `FROM` (multi-table) / `WHERE` / `GROUP BY` / `HAVING` / `ORDER BY` / `LIMIT`
- `INNER` / `LEFT` / `RIGHT` / `FULL` / `CROSS` joins, `UNION [ALL]` / `INTERSECT` / `EXCEPT` (INTERSECT binds tighter; ALL keeps multisets) (hash join; join order chosen greedily by connectivity, LEFT keeps written order)
- Expressions: arithmetic, comparison, `CASE WHEN`, `IN`, `NOT IN`, `BETWEEN`, `NOT BETWEEN`, `LIKE`, `NOT LIKE`, `IS [NOT] NULL`, `NULL` as a comparison/arithmetic operand, `EXTRACT(year/month/day)`, `DATE` literals, `date +/- INTERVAL n day/month/year` (calendar-aware, day-of-month clamping), `CAST`, string functions (`substring` — both argument styles, `length`, `upper`, `lower`, `concat`), `abs`, `round`, three-valued NULL logic throughout. Division is DuckDB-style: `/` is always DOUBLE (`x/0` is ±inf, `0/0` is nan) and `%` follows fmod (`x % 0` is NULL). Integer literals widen int32 → int64 → float64 to stay exact. Identifiers: the DATE-part keywords `year`/`month`/`day`/`date` double as bare column/table/alias names; double-quoted identifiers (`"left"`, with `""` escape) reach every other reserved word
- Aggregates: `sum` / `avg` / `min` / `max` / `count` / `count(*)` / `count(DISTINCT)` / `stddev` (+samp/pop) / `variance` (+samp/pop) / `median` / `string_agg` (literal separator); aggregates over int64 that overflow raise instead of wrapping
- `GROUP BY 1` ordinals resolve to select items
- Window functions in the select list: `row_number()`, `rank()`, `dense_rank()` and every aggregate as `agg(expr) OVER (PARTITION BY ... ORDER BY ...)` (NULLS FIRST/LAST per key). Aggregates use the standard default frame — RANGE UNBOUNDED PRECEDING TO CURRENT ROW (a running aggregate whose peers share the value); without ORDER BY the frame is the whole partition. Explicit frame clauses (`ROWS`/`RANGE` BETWEEN ...), window functions in WHERE/ORDER BY/HAVING/GROUP BY (order by the output alias instead) and windows inside correlated subqueries are rejected with pointed errors
- Subqueries: correlated `EXISTS` / `NOT EXISTS` / `IN` / `NOT IN` — including a HAVING inside the EXISTS (decorrelated to grouped semi/anti joins, residuals and all) — and correlated scalar aggregate subqueries in WHERE **and in the select list** (decorrelated to grouped LEFT joins) — nested to the depth TPC-H asks; derived tables (`FROM (SELECT ...) AS t`), with optional column alias lists (`AS t (a, b)`)
- `WITH name AS (SELECT ...)` — non-recursive CTEs, statement level; a name is its own qualifier, later CTEs may reference earlier ones
- Scalar functions: `coalesce` / `nullif` / `greatest` / `least`, `date_trunc(unit, date)`, `date_diff(unit, start, end)`; `SELECT` works without FROM and a bare `NULL` select item reads as INTEGER
- Pushdown: single-table predicates from WHERE/ON are applied as build/probe filters at each hash join; equalities become hash keys even when implied by disjunctions. At joins that preserve a side (`LEFT`/`RIGHT`/`FULL`), WHERE predicates — spanning ones included — stay post-join so NULL-extended rows still meet them
- Larger than memory: `exec --memory <n>[K|M|G] [--spill-dir <dir>]` bounds the blocking operators. `ORDER BY` becomes sorted runs whose final merge streams into projection/DISTINCT/OFFSET/LIMIT (a LIMIT query holds only its output window); a hash join partitions both sides and splits an over-budget partition again, and a `GROUP BY` partitions its input and aggregates each partition one spill file at a time — so a hot group key is fine while a single join key holding most of a side is refused with that reason. `--analyze` under a budget reports `spill runs` / `spill files` / `spill bytes written` / `spill bytes read`, and the CLI removes its temp directory on both exit paths. A query spills into its own `moonlake-spill-<n>` subdirectory of `--spill-dir` (or `TMPDIR`), so two processes may share one `--spill-dir` without touching each other's runs, and a caller's own files there are never read or deleted. A subdirectory is claimed with an `owner` marker naming the pid, the boot id and the pid's start time, so a run killed outright no longer leaks: the next query removes that subdirectory when the marker proves its owner is gone (another boot, a pid that no longer exists, a pid whose start time changed), and keeps — and reports — any directory it cannot judge, such as one with no marker (library form: `execute_with` with `ExecOptions` + a `SpillStore`; the engine itself never touches the filesystem)

Out of scope: writes (`INSERT`/`UPDATE`/`CREATE TABLE`/DDL beyond CTEs), persistence, transactions, indexes, explicit window frame clauses (the default frame is supported), cost-based optimization, multi-statement scripts.

### TPC-H cross-validation

SQL correctness is validated by differential testing against DuckDB over the TPC-H benchmark: **all 22 queries pass on their official texts** (annex parameter values; dbgen directives stripped) — every result matching DuckDB within 1e-9 relative tolerance on SF0.01, and the whole chain runs in CI (job `tpch` regenerates the data and DuckDB's answers from scratch, then diffs every query). One documented deviation: Q15's official text materializes a view with `CREATE VIEW ... ; SELECT ...; DROP VIEW ...` and the engine executes single statements, so the harness runs its sanctioned `WITH` spelling of the same query (`harness/queries/q15.sql`), which DuckDB answers identically.

```bash
uv run --with duckdb python harness/gen_tpch.py   # TPC-H SF0.01 data + goldens
bash harness/check_all.sh                         # 27 goldens: all PASS (22 TPC-H + parquet + 4 multi-row-group)
MOONLAKE_DATA=harness/data/sf01 bash harness/check_all.sh   # same at SF0.1 (regenerate first: gen_tpch.py 0.1)
```

Informational benchmark (SF0.01, best of 3, via `harness/bench.py`;
same machine, one run, both engines; refreshed 2026-10-06 after the
unboxed-CSV-ingest pass:

| query | moonlake native | duckdb |
|---|---|---|
| Pricing Summary Report | 183 ms | 3.3 ms |
| Shipping Priority | 142 ms | 4.1 ms |
| Local Supplier Volume | 151 ms | 4.1 ms |
| Forecasting Revenue Change | 124 ms | 0.8 ms |
| Volume Shipping | 166 ms | 4.7 ms |
| Returned Item Reporting | 143 ms | 7.4 ms |
| Shipping Modes and Order Priority | 147 ms | 3.3 ms |
| Promotion Effect | 122 ms | 1.4 ms |

These are the eight queries `harness/bench.py` runs (it prints the
same rows labelled q1–q14). Times include process startup and reading
the CSV from disk. duckdb is in-process over pre-loaded tables — the
same query from a fresh `read_csv_auto` costs it ~55 ms, where
moonlake's built-in byte-level reader plus the columnar evaluator
(vectorized kernels, int-keyed hash joins, projection pruning,
direct-to-vector CSV materialization) lands at 122–183 ms, down
3.4–6x from the original row-at-a-time build on the same machine
(539–995 ms on the four queries benchmarked then).

`--explain` prints the plan; a scan line states what it will read: the exact
row count when the format knows it (a Parquet footer) and `?` when it does not
(a lazy CSV scan counts nothing up front), plus `row groups: k of n read` when
statistics eliminated some. `--analyze` adds the actual row count per stage and,
under `--memory`, what the query spilled.

**Scan pushdown (2026-10-20).** Registering a table now stores its schema and
where the bytes live, not the rows; a scan produces 4096-row batches, decodes
only the columns the query projects, and skips Parquet row groups whose
statistics cannot match the pushed predicate. On the same machine and SF0.01
data, `python3 harness/bench_scan.py --base <build of the previous commit>`,
best of 5 native debug runs: q1 130→94 ms, q6 111→67 ms, q3 130→73 ms, a bare
`count(*)` over lineitem 105→48 ms, peak RSS −13…−26%. On a generated 1Mi-row
Parquet table with 8 row groups, a selective predicate drops from ~430 ms to
~50 ms and peak RSS from 130 MB to 32–39 MB.

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

For everyday use, install a standalone binary and skip `moon run`:

```bash
moon build cmd/main --target native --release
install -m755 _build/native/release/build/cmd/main/main.exe ~/.local/bin/moonlake
moonlake exec --csv lineitem.csv --file q6.sql     # SQL from a file: no shell quoting
```

Joins take one `--csv` per table; `--parquet` scans Parquet files (declare epoch-day DATE columns of an *unannotated* file with `--date-col` — a file that carries the standard DATE annotation needs nothing); the SQL is one quoted argument or a file via `--file` (a trailing semicolon is fine); `--explain` prints the physical plan; `--json` emits machine-readable output — one JSON array line per result, where SQL NULL is `null`, DATE is a quoted calendar date, and the non-finite doubles JSON cannot spell are the strings `"Infinity"`, `"-Infinity"` and `"NaN"`. `moonlake write --csv in.csv --out out.parquet [--snappy]` converts a registered table to Parquet.

As a library:

```bash
moon add superbigcup325/moonlake
```

> This README and the browser playground track `main`. `moon add` gives you the
> latest published release from mooncakes (0.5.0), which includes the session
> playground, the Parquet writer and the spill/JSON fixes recorded in
> [CHANGELOG.md](CHANGELOG.md).

**Building from source.** `main` depends on `superbigcup325/colenc@0.1.0`,
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

```moonbit nocheck
// a @catalog.Catalog with registered table entries — @csv/@parquet
// scan into one; note the argument order: content/name, not name/content.
// registration is lazy: the schema is available at once, and a query decodes
// only the columns it projects, in 4096-row batches

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

## Docs

- **Playground** ([open](https://superbigcup325.github.io/moonlake/)): register several CSV/Parquet files in a visible session, run cross-file joins, inspect the physical plan, and drop tables or clear the session — the whole engine as wasm-gc, all client-side.
- **[docs/DEMO.md](docs/DEMO.md)**: the reproducible demo, from running the engine to the DuckDB cross-check and the benchmark.
- **[docs/verification.md](docs/verification.md)**: the correctness and performance report (differential and property testing, pushdown fuzzing, memory and spill numbers).
- **[docs/bench-baseline.md](docs/bench-baseline.md)**: the release performance baseline (scan/join/gather/spill) and the machine it belongs to, with a committed JSON record and a `--compare` mode.
- **[docs/spill-survey.md](docs/spill-survey.md)**: how six systems handle larger-than-memory queries, and where moonlake's design lands.
- **[docs/devlog.md](docs/devlog.md)**: the build log, week by week.
- **[docs/ROADMAP.md](docs/ROADMAP.md)**: what is being worked towards, what is refused on purpose, and what would start a direction currently on hold.
- **[CHANGELOG.md](CHANGELOG.md)**: release notes.

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

## Acknowledgements

moonlake is being built on top of these open-source packages:

- [moonbitlang/x](https://github.com/moonbitlang/x) (Apache-2.0) — filesystem, argument parsing and encoding utilities
- [moonbitlang/quickcheck](https://github.com/moonbitlang/quickcheck) (Apache-2.0) — property-based testing
- [superbigcup325/colenc](https://github.com/superbigcup325/colenc) (Apache-2.0) — Parquet DELTA, BYTE_STREAM_SPLIT and RLE encoding/decoding primitives
- [apache/parquet-format](https://github.com/apache/parquet-format) (Apache-2.0) — the Parquet format and encoding specifications that `sources/parquet` implements; its [parquet-testing](https://github.com/apache/parquet-testing) corpus supplies the files the reader is verified against

## License

[Apache-2.0](LICENSE)
