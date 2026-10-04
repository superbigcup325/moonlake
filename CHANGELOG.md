# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- 2026-10-06 verification arc — normalized correctness evidence beyond the SF0.01/1e-9 differential: a randomized vec-vs-scalar differential property over generated typed expression trees (batch sizes 0..4097, mutation-verified), a nested-loop hash-join oracle property across eight join flavors with hostile key distributions (mutation-verified), and `harness/fuzz_pushdown.py` (300 random predicate trees over INNER/LEFT joins, duckdb-refereed; catches WHERE-vs-key placement regressions at LEFT joins — verified by re-introducing the escape bug)
- MoonBit module skeleton (`superbigcup325/moonlake`): library package and CLI entry point (`cmd/main`)
- 2026-10-05 acceptance arc — all 22 TPC-H queries now pass on their official texts (annex parameter values, duckdb-diffed within 1e-9 on SF0.01 and SF0.1; q15 in its sanctioned `WITH` form, see `harness/queries/q15.sql`):
  - `DATE +/- INTERVAL n day|month|year` arithmetic — calendar-aware month/year shifts with day-of-month clamping (`1996-03-31 + interval '1' month` = `1996-04-30`), vectorized, NULL-propagating; an `INTERVAL` literal outside date arithmetic is a bind error, and the TPC-H dbgen precision suffix (`interval '90' day (3)`) parses and is dropped
  - Correlated scalar subqueries (`expr <op> (SELECT agg(...) ... WHERE inner.col = outer.col ...)`) decorrelate into LEFT joins against the inner query grouped by the correlation keys — empty groups NULL-extend and the comparison filters, which is exactly scalar-subquery NULL semantics; the select item must contain an aggregate so groups stay single-row, and nesting works to the depth q20 asks (two correlation columns one level out)
  - Derived-table column alias lists (`FROM (SELECT ...) AS t (a, b)`) rename positionally, arity-checked
  - Non-recursive statement-level `WITH` CTEs: each body re-parses per reference (decorrelation rewrites the AST in place), a CTE name shadows catalog tables and qualifies its columns when no alias is given, later CTEs may reference earlier ones
  - The harness now carries the official TPC-H texts verbatim (`harness/queries/q1..q22.sql`), goldens are generated from the exact bytes moonlake runs, and `check_all.sh` covers 23 goldens (22 + the parquet variant) at any scale via `MOONLAKE_DATA`
- CLI `--version` / `--help` output
- Engine facade with version metadata and blackbox tests
- GitHub Actions CI: format check, `moon check`, tests across native / wasm-gc / js targets
- Apache-2.0 license
- W1: `types` (columnar vectors, scalars with three-valued NULL logic, epoch-day dates), `catalog`, CSV scan with type inference, engine subset parser/binder/executor, CLI `exec --csv`, TPC-H cross-validation harness (duckdb goldens, Q6 end to end)
- W2: GROUP BY hash aggregation with the v1 aggregate set (sum / avg / count / count(*) / count(distinct) / min / max), HAVING, ORDER BY (NULLS LAST) and LIMIT
- W2: CASE WHEN, LIKE and IN expressions; TRUE/FALSE literals
- W2: multi-table FROM with hash joins — comma lists, `JOIN ... ON`, `LEFT [OUTER] JOIN`, `CROSS JOIN`; WHERE/ON conjunct classification into build/probe filters, hash keys and per-pair residuals
- W2: Parquet scan adapter (`sources/parquet`) over mizchi/parquet with declared DATE columns; CLI `--parquet` / `--date-col`
- W2: TPC-H goldens for Q1 / Q3 / Q14 plus the parquet chain (q6p), `harness/check_all.sh`, and a CI job regenerating data + goldens via duckdb and cross-validating every query
- W3: TPC-H coverage to 14 of 22 queries (13 on the official text; Top Supplier rewritten — CTE inlined as a derived table), all duckdb-validated — `check_all.sh` runs 15 goldens
- W3: plain projection, table aliases with qualified columns, EXTRACT(year/month/day), derived tables (`FROM (SELECT ...) AS t`), NOT LIKE / NOT IN lists, non-correlated scalar subqueries and IN / NOT IN subqueries with SQL NULL semantics
- W3: greedy connected-first join ordering for inner-only chains; hash keys implied by OR-branch equalities (Q19)
- W3: string ordering fixed to lexicographic (`String::lexical_compare`) — MoonBit's `String::compare` is length-first and `<`/`>` are not content-ordered
- W3: CLI `--explain` (physical plan render) and `--json` (single-line JSON results); `harness/bench.py` (native vs duckdb, best of 3)
- W4: acceptance package — acceptance-facing README (ecosystem-boundary section, TPC-H scoreboard), `docs/DEMO.md` reproducible walkthrough, published to mooncakes.io as `superbigcup325/moonlake@0.1.0`
- W4: browser playground (`playground/`) — the whole engine as a wasm-gc foreign library, drop-a-CSV page with zero dependencies, GitHub Pages workflow
- W4: pre-commit gate (`hooks/`) — interface freshness, formatting, deny-warn check and tests run locally before every commit
- Polish: quickcheck property tests over the full pipeline (model-based group/aggregate oracle, join symmetry, pushdown equivalence, sum-over-groups; mutation-verified), SF0.1 cross-validation (all 15 goldens PASS on 600k+ rows) and scale-parameterized harness scripts, and Parquet drag-and-drop in the playground

### Fixed

- Playground: loading a CSV in the browser threw `csvText is not defined` (a leftover write to an undeclared variable in the module script), so the drag-and-drop / file-pick path silently never enabled the Run button; only the Parquet path worked. The dead store is gone and the CSV path runs end to end in the browser again
- Explicit `JOIN (SELECT ...) AS t (a, b)` syntax rejected derived tables ("expected table name after FROM") — only comma-list FROM accepted them; the shared table-reference parser now handles subqueries, WITH names, aliases and column lists on both paths
- LEFT JOIN pushdown soundness: WHERE conjuncts referencing only the build (right) table were applied as build filters, dropping build rows and letting NULL-extended probe rows survive a predicate they cannot satisfy (e.g. `... LEFT JOIN orders ON ... WHERE orders.amount > 15` returned the unmatched rows with NULL amounts). They now stay a deferred post-join filter; probe-side pushdown and ON-clause placement are unchanged
- CLI exit codes: every error path (bad SQL, unknown table/column, unreadable file, usage violation) exited 0. Errors now print a single-line message to stderr and exit 1 via a clean process exit (`moonbitlang/x/sys`), so no runtime abort stack trace trails the message; success, `--help` and `--version` remain 0
- Integer overflow wrapped silently: CSV inference and SQL literals shared a parser that ignored the int32 range, so `2147483648` came back as `-2147483648` and past int64 the sign flipped (`9223372036854775807` → `-1`). Integer parsing is now range-checked end to end: CSV columns widen int32 → int64 → float64 (DuckDB-style sniffing), SQL literals widen int32 → int64 → float64, sign-only inputs (`-`) no longer parse as `0`. The float parser's int64 digit accumulator had the same wrap on 20-digit inputs; it now accumulates in double precision (accuracy contract unchanged: 1e-9 relative)
- Keywords `year`/`month`/`day`/`date` were unusable as column names in any form (bare, qualified, aliased) and double-quoted identifiers were not supported at all — a CSV with a `day` column had no way to reference it. The DATE-part keywords now parse as names in name positions, and `"quoted"` identifiers (with `""` escape) reach every other reserved word
- A scalar subquery over zero rows raised a bind error; SQL semantics say it yields NULL, so only more than one row is now an error
- CLI: a `--date-col` naming no scanned column was a silent no-op (exit 0) that surfaced later as a confusing type mismatch — it is now a usage error; words after the quoted SQL silently glued onto the query (a stray word became a table alias) — the SQL must now be one quoted argument; a UTF-8 BOM glued onto the first CSV header cell's name — it is now stripped

### Changed

- Division and modulo follow DuckDB: `/` is true division and always yields DOUBLE (integer operands promote, `x/0` is ±inf, `0/0` is nan) instead of C-style integer division returning NULL on a zero divisor; `%` follows fmod — the result takes the dividend's sign (`-10.5 % 3` is `-1.5`) — and `x % 0` is NULL. `--json` renders non-finite floats as bare `Infinity`/`NaN` tokens, byte-identical to DuckDB's own JSON output (Python's `json` module round-trips them; strict RFC 8259 parsers do not)

### Added

- `IS NULL` / `IS NOT NULL` — the first way to test NULL-ness in a WHERE or CASE condition
- Columnar evaluation core (the v1 vectorization milestone): `eval_vec` evaluates expressions over whole batches with typed kernels — column refs shared zero-copy, constant broadcast, same-type int32/int64/float64 arithmetic, three-valued comparison, NULL-aware AND/OR/NOT — with a per-row fallback for the remaining shapes; nine differential tests pin the vector path to the scalar interpreter cell-for-cell
- Filter, projection, aggregation inputs and ORDER BY run on the vector path: masks come from the vectorized boolean result, each output column is one pass, group keys and aggregate inputs are evaluated once per batch, and sort keys are materialized before the comparator runs
- Columnar hash join: both sides concatenate once into single batches, keys evaluate once per side, probe hits collect (left row, build row) integer pairs, and output assembles by typed per-column gathers — no row-major boxed Scalar arrays. NULL-key, residual and LEFT NULL-extension semantics are unchanged
- Bind-time projection pruning: the executor walks the bound plan, drops every unreferenced column from the pipeline (zero-copy vector subsets) and rewrites all column references. TPC-H lineitem scans narrow from 16 columns to the 2–6 the query touches; `--explain` reports the narrowed counts and renders the executed plan. `SELECT *` degenerates to an identity rewrite
- The NyaCSV-backed CSV scan is replaced by a built-in byte-level reader: one pass records per-cell offsets (RFC-4180 dialect — quoted fields with `""` escapes, commas and newlines inside quotes, LF/CRLF terminators, blank lines skipped, BOM stripped), and materialization parses numeric/boolean/date cells straight from their byte ranges, so text columns are the only ones that ever build Strings. Ingest of a 7.4 MB lineitem.csv drops 386 -> 132 ms and every bench query lands at 137–205 ms; the public `scan_string`/`scan_file` API and the wasm playground path are unchanged
- Performance pass over ingest and the join core: CSV cells materialize straight into typed FixedArrays (no boxed Scalar per cell — about a million temporaries per lineitem.csv load at SF0.01), `scan_file` reads bytes and hands them to NyaCSV without a full-file String decode, single-int join keys hash `Int64`s directly instead of building a key string per row, and row selection/batch concatenation copy FixedArray ranges instead of boxed cells. Best-of-3 on one machine: every bench query drops 16–29%, q7 (six-table join) 1040 → 483 ms cumulative against the row-at-a-time build; ingest is now the dominant remaining cost
- `NOT BETWEEN` (postfix form, three-valued negation of BETWEEN)
- `NULL` as a comparison or arithmetic operand: `v = NULL` is UNKNOWN per row, `NOT IN (1, NULL)` is empty, `v + NULL` propagates (the literal takes its type from the other operand; standalone `SELECT NULL` remains unsupported)
- `SELECT *` — expands to every FROM column, each table in FROM order; also inside derived tables
