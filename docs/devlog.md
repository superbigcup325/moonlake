# devlog

Weekly log of goals, approach and quality boundaries. moonlake is
built with AI assistance; this file records what was done, why, and
where the edges are.

## W1 (2026-10-01 - 2026-10-08): first milestone, Q6

### Goal

The W1 gate: run TPC-H Q6 end to end over a CSV file, cross-checked
against duckdb. Q6 exercises the full v1 spine: scan with type
inference, WHERE with three-valued NULL logic, arithmetic on filtered
rows, DATE literals, BETWEEN, and a final aggregate.

### What landed

- `types`: DataType/Scalar/ColumnVector/DataBatch, epoch-day DATE
  (int32) with real calendar validation, NULL-propagating compare and
  three-valued AND/OR/NOT
- `catalog`: schema registry with materialized table entries
- `sources/csv`: NyaCSV-based scan, one type per column inferred from a
  100-row sample (int32 -> float64 -> bool -> date -> string), empty
  cells become NULL, 4096-row batches
- `engine`: hand-written subset parser (SELECT agg FROM table WHERE),
  binder with numeric promotion (int32 -> int64 -> float64), eager
  filter + final aggregate. SUM(int32) widens to int64; SUM over zero
  matching rows yields one NULL row per SQL semantics
- CLI `exec --csv`, pipe-friendly `|`-separated output
- harness: duckdb `dbgen` generates SF0.01 (60,175 lineitem rows),
  duckdb's answer stored as golden, `compare.py` diffs with 1e-9
  relative tolerance

### Result

Q6 on SF0.01: moonlake 588352.2400000002 vs duckdb 588352.24, relative
error ~4e-16. **W1 gate passed.**

### Decisions and edges

- **Subset parser instead of sqlparser for W1.** sqlparser 0.5.1 is an
  excellent Apache-2.0 parser, but its `SetExpr`/`SelectStmt` are not
  readable cross-package (probed empirically), so a parsed SELECT body
  is opaque to us. Rather than fork immediately, W1 ships a small
  in-house parser for the aggregate-filter subset; sqlparser stays
  pinned as a dependency and an upstream visibility PR is the W2 fix,
  after which the front-end swaps with the binder untouched. This
  follows the plan's stall line: work around a gap rather than sink a
  day into it.
- **Eager pipeline, not Volcano yet.** CSV is materialized in memory
  anyway, so the operator trait would be ceremony without value. The
  pull-based operator interface lands when a source is actually lazy
  (parquet row groups).
- **Row-at-a-time scalar evaluation.** Vectorized batches are the plan;
  the current evaluator loops rows. Q6 at SF0.01 runs in ~1.3s
  including CSV parsing, so correctness comes first and the perf pass
  is deferred to W3 as planned.
- **Manual number parsing.** moonbitlang/core/internal/strconv is
  import-restricted, so int/double parsing is hand-rolled (shared by
  CSV source and SQL lexer in `types`). The double parser is exact for
  the TPC-H decimal shapes; the golden diff uses relative tolerance
  regardless.
- **Quality boundaries**: no correlated subqueries, no GROUP BY yet,
  aggregates only at the top level of select items, untyped NULL
  literals rejected by the binder. All intentional v1 scope cuts.

## W2 (planned 2026-10-09..15, landed early 2026-10-02): joins, group/order/having, parquet, golden CI

### Goal

The W2 gate: TPC-H Q1, Q3 and Q14 end to end against duckdb goldens,
plus the parquet scan adapter and the golden chain running in CI.

### What landed

- `engine`: hash aggregation with GROUP BY (type-tagged canonical
  group keys), the full v1 aggregate set (sum with int widening, avg in
  float, count / count(*) / count(distinct), min/max), HAVING over the
  post-aggregation row, ORDER BY (NULLS LAST, stable) and LIMIT
- `engine`: CASE WHEN (branch type unification), LIKE (case-sensitive,
  % and _ by backtracking) and IN (equality OR-chain); TRUE/FALSE
  literals
- `engine`: multi-table FROM joined left-deep in written order — comma
  lists, `JOIN ... ON`, `LEFT [OUTER] JOIN`, `CROSS JOIN`. WHERE and ON
  conjuncts classify per step: single-table ones become build/probe
  filters (pushdown), equalities spanning both sides become hash keys
  (NULL keys never match, key sides promoted to a common type), other
  spanning conjuncts are per-pair residuals evaluated before a match
  counts — so a LEFT JOIN's NULL-extension sees the post-residual match
  set, which is the ON semantics. WHERE conjuncts stranded at LEFT
  steps defer to a post-join filter
- `sources/parquet`: adapter over mizchi/parquet's
  `read_bytes_columnar` — typed arrays map directly, nullable variants
  become validity slots, Float upcasts, timestamp/binary/repeated
  rejected at registration; parquet DATE (int32 epoch days) lifts to
  DATE via an explicit `date_columns` list at registration
- CLI: `--csv` repeatable, `--parquet`, `--date-col`
- harness: customer/orders/part CSVs, lineitem.parquet (decimals cast
  to double), q1/q3/q14 goldens plus q6p (Q6 over the parquet-shaped
  table), `check_all.sh`; CI job `tpch` regenerates data + goldens from
  scratch and runs the whole chain

### Result

`harness/check_all.sh`: q6, q1 (4 groups), q3 (10 rows, revenue-desc
order + limit), q14, q6p — all PASS against duckdb within 1e-9 relative
tolerance. Q3 runs the full 3-table hash-join chain in ~1.3s at SF0.01
including CSV parsing. **W2 gate passed.**

### Decisions and edges

- **Join order is FROM order, left-deep.** Reordering is not in the v1
  scope list (only predicate pushdown and projection pruning are), and
  at SF0.01 the written order already connects stepwise for Q3/Q14. A
  disconnected FROM (no equi conjunct between adjacent tables)
  degenerates to a cross-join filtered afterwards — correct, just slow.
- **In-house parser keeps growing.** Re-probed sqlparser 0.5.1 before
  starting: `SetExpr`/`SelectStmt` are opaque cross-package (`type`,
  not `pub(all)`), so the W1 finding stands. The subset parser gained
  the full clause surface instead; the upstream visibility PR remains
  the eventual front-end swap.
- **Plain projection is still out of subset.** `SELECT col FROM t`
  without an aggregate or GROUP BY is a bind error by design — every
  target TPC-H query aggregates; the error message says so.
- **Aggregation binds in two spaces.** Input expressions evaluate over
  the joined batch; select items, HAVING and ORDER BY evaluate over the
  post-aggregation row (group keys, then aggregate outputs). Structural
  matching against GROUP BY exprs decides what is a key; aggregates
  dedupe by written shape.
- **Parquet adapter stays eager.** Per the plan's §3.9 finding:
  mizchi/parquet decodes whole files, so per-column pruning cannot pay
  off yet; correctness first, the upstream per-column-read PR is the
  post-gate evaluation. DATE has no logical-type exposure upstream, so
  the caller declares date columns at registration instead of the
  adapter guessing.
- **Quality boundaries**: no NOT IN / NOT LIKE / IS NULL, no SELECT
  DISTINCT, ORDER BY only accepts output column names, join keys hash
  floats through their string form (join keys in the targets are
  integers), multi-table FROM capped at 30 tables (bitmask
  classification). Residuals evaluate per candidate pair on a
  materialized flat row — correct but unoptimized, fine at harness
  scale.

## W3 (planned 2026-10-16..22, landed early 2026-10-02): TPC-H 14/22,
subqueries, CLI surface, golden bench

### Goal

The W3 gate: TPC-H coverage to 10-14 runnable queries, the two promised
rule-based optimizations, bench numbers, --explain/--json/REPL,
playground kickoff, and the parquet per-column-read upstream decision.

### What landed

- SQL surface: plain projection (no aggregate), table aliases with
  qualified columns (n1.n_name), EXTRACT(year/month/day FROM date),
  derived tables (FROM (SELECT ...) alias, eager recursion at
  FROM-resolution), NOT LIKE / NOT IN literal lists, non-correlated
  scalar subqueries (folded to constants through a catalog-backed
  runner) and non-correlated IN / NOT IN subqueries (folded to
  canonical key sets with full SQL NULL semantics: NOT IN over a set
  containing NULL drops every row)
- Join planning: greedy connected-first ordering for inner-only chains
  (flat layout follows the JOIN order), LEFT chains keep written order;
  a disjunction implying the same equi pair in every branch (Q19) yields
  a hash key with the full OR as residual
- CLI: --explain (bound plan render: pushdown filters, join keys,
  build/probe/residual, aggregate, order, limit) and --json (one JSON
  array line, escaped strings, null for NULL)
- harness: all eight TPC-H tables, goldens for q5 q7 q8 q10 q12 q13 q19
  q11 q16 q15r (Q15 rewritten: CTE inlined as a derived table, max as a
  scalar subquery), check_all.sh at 15 goldens, bench.py (native best-of-
  3 vs duckdb)

### Result

TPC-H: 14 of 22 runnable — 13 on the official text (two more than the
promised 10; Important Stock Identification and Small-Quantity-Order
Customer Scan turned out to run unmodified once scalar subqueries and
NOT IN sets landed), plus Top Supplier rewritten (CTE inlined as a
derived table). Every golden matches duckdb within 1e-9 relative
tolerance; check_all.sh 15/15. Bench (SF0.01, best of 3): moonlake
native 0.5-1.0 s vs duckdb 0.7-6 ms per query — recorded as-is; the gap
is the row-at-a-time evaluator plus eager CSV parsing, exactly the W3
perf-pass target.

### A real bug found by the gate: string ordering

Q16's 296-row ordering disagreed with duckdb and the chase ended at a
language trap: MoonBit's `<`/`>` operators on String are not
lexicographic (they appear to follow literal-pool order), and
`String::compare` is length-first. SQL ordering now goes through
`String::lexical_compare`. Two earlier goldens (q1, q13) had passed
only because their string keys happened to be equal-length — a quiet
false-pass that the bigger golden surface exposed. A guard test now
records the trap next to the fix.

### Decisions and edges

- **Derived tables recurse at FROM-resolution time.** The engine is
  fully eager, so a derived table is just: run the inner select against
  the catalog, its output becomes a virtual schema + one batch. No
  planner change. Correlated subqueries stay out of scope (v1).
- **Join-order flat layout.** Greedy reordering forced the flat column
  layout to follow the JOIN order rather than FROM order; offsets are
  assigned after planning. With LEFT JOIN present, written order is
  kept (row preservation depends on it).
- **Scalar subqueries fold at bind time.** Non-correlated means the
  inner select sees only its own FROM; folding to a constant is then
  sound anywhere an expression binds (WHERE, HAVING, Q11's threshold).
- **Projection pruning + vectorization deferred, deliberately.** The
  bench shows time concentrated in row-at-a-time evaluation and eager
  CSV parsing; pruning decoded columns saves memory but no time until
  the vectorized evaluator lands. Order of work: vectorize first, prune
  on top. Both remain promised for v1 and now have a measurable target.
- **REPL is blocked on upstream**: moonbitlang/x has no stdin API yet;
  --explain and --json shipped instead. Playground kickoff deferred to
  the next session (wasm bridge + page is an independent chunk).
- **Parquet per-column-read upstream PR: evaluated, not pursued.** The
  adapter consumes read_bytes_columnar; a column-selection read would
  only pay off after vectorization/pruning exist to exploit it. Whole-
  file decode stays for v1; revisit post-competition (plan §11).

## W4 (acceptance package, landed early 2026-10-03): README facade,
mooncakes 0.1.0, playground, local gates

### Goal

The acceptance package per the plan: README facade with the ecosystem
section, a mooncakes release, green CI, a reproducible demo page — and
the playground kickoff that slipped from W3.

### What landed

- README: CI badge, the concrete v1 SQL surface, the TPC-H scoreboard
  as a table (14/22: 13 direct + Q15 rewritten), the benchmark with its
  honest caveat, and the ecosystem-boundary section — parser / format
  readers / Arrow interchange / embedded OLTP / DuckDB bindings, each
  with the exact seam to moonlake
- `docs/DEMO.md`: fresh-clone-to-evidence walkthrough (CSV + Parquet
  runs with expected outputs, plan explain, the 15-golden chain, bench,
  three-target tests)
- **Published to mooncakes.io**: `superbigcup325/moonlake@0.1.0`
  (dry-run accepted first; the listing went live and the docs build
  kicked off)
- Playground: `playground/` is a foreign_library package exporting
  `run(csv, table, sql) -> JSON` and `version()` through
  `link.wasm.exports` with js-string builtins — the entire engine in
  the browser, no server, no external wasm. `index.html` is a
  dependency-free drop-a-CSV page (table + wall-clock time, errors as
  JSON). JSON rendering moved into the engine facade so CLI and
  playground share one implementation. A pages workflow builds the wasm
  and publishes the two-file site (needs Pages enabled in repo
  settings)
- `hooks/pre-commit`: interface freshness, formatting, deny-warn check
  and tests run before every commit — the same gates as CI, so a stale
  .mbti can never need a push round-trip again (it caught one itself
  during the playground commit)

### Result

Verified end to end in a real browser: engine 0.1.0 loads (wasm-gc),
a dropped 60175-row lineitem.csv answers the Q1-shaped GROUP BY in
312 ms with totals identical to the duckdb-validated golden. node
harness: run() in 299 ms — the wasm-gc build is faster than the native
CLI on the same query (622 ms), matching the wasm-gc performance
narrative from the plan.

### Decisions and edges

- **Publishing order**: dry-run -> README facade -> publish, so the
  mooncakes listing renders the final README from day one.
- **Playground ships two files** (index.html + playground.wasm) with no
  build chain on the JS side; Pages needs a one-time enable in repo
  settings, the workflow is committed and dispatch-ready.
- **The evaluator stays row-at-a-time.** Projection pruning and
  vectorization remain the declared next steps; W4 discipline was
  polish, not new engine features.

## Polish (buffer period, 2026-10-03): property tests, SF0.1, Parquet in
the playground

- **quickcheck properties** (4 x 80 cases, seeded): model-based oracle
  for filter+group+five aggregates, join symmetry, pushdown equivalence,
  sum-over-groups. Mutation-verified: breaking aggregate NULL skipping
  gets Falsified at case 7.
- **SF0.1**: all 15 goldens PASS on 600k+ lineitem rows (Q16 2762 rows,
  Q11 2541 rows; Q8 non-empty at 2 rows). bench native 5.1-11.4 s vs
  duckdb 2-12 ms — linear in the 10x growth, so CSV parsing dominates.
  Data stays out of the repo; one command regenerates it. Restoring the
  q6p golden exposed a real regression: the QUERIES-dict refactor had
  silently dropped that golden from generation, masked at SF0.01 by the
  old file still sitting in the tree.
- **Playground Parquet**: bytes cross the wasm boundary as a
  byte-faithful binary string. First cut used TextDecoder('windows-1252')
  which corrupts 0x80-0x9F and surfaced as a parquet footer mismatch —
  caught immediately by the in-browser end-to-end check. Q6 over a
  dropped 1.9 MB parquet answers in 128 ms, identical to golden.

## Official-text acceptance (2026-10-05): all 22 TPC-H queries on
## their official texts

- **The adapted texts were hiding four real bugs.** Running the
  official dbgen texts (annex parameters, duckdb-refereed at SF0.01)
  flipped the scoreboard from "14/22, 13 on official text" to 8/22 —
  and every gap it exposed was real. The semi/anti machinery had two
  soundness holes the adapted goldens could never see: lifted residual
  refs collided with pair-key synthetic names (any non-equality
  residual in EXISTS/IN silently compared the wrong column), and
  `join_semi` gathered row 0 of an empty inner batch (NOT IN over an
  empty key set aborted the process). Worse, `plan_step` placed
  WHERE-origin spanning conjuncts as hash keys at LEFT/RIGHT/FULL
  steps, so NULL-extended rows escaped the predicate entirely — no
  subqueries needed to reproduce. The repo's own q16/q21 rewrites had
  been dodging all three (LIKE->=, `<>`->`=`, dropping the nation
  join); the old q8 rewrite even hardcoded `n2.n_name = 'BRAZIL'`
  into the inner query, pinning mkt_share at 1.0 by construction.
- **Four features closed the rest**: DATE +/- INTERVAL (7 queries),
  correlated scalar aggregate subqueries via grouped LEFT joins
  (q2/q17/q20), derived-table column alias lists (q13), and
  statement-level WITH CTEs (q15's sanctioned spelling — the
  create-view statement form stays out, the engine executes single
  SELECTs). 21/22 official texts pass outright; q15 is the one
  documented deviation.
- **The harness now runs what ships.** `harness/queries/` holds the
  official texts verbatim, `gen_tpch.py` reads them and generates
  goldens from the exact bytes moonlake runs, and `check_all.sh`
  covers 23 goldens at any scale — verified at SF0.1 (23/23, q21 at
  47 rows instead of SF0.01's 1, q16 at 2762). The SF0.01 weak rows
  (q8/q18 at 0, q21 at 1) are why scale matters: assertions over
  empty results prove nothing about semantics.
- Process note: the pre-commit hook assumes the working tree matches
  the index (it re-runs `moon info`/`moon fmt` over the tree), so
  splitting one change into two commits needs `git stash push -- <paths>`
  between them — plain staged-file discipline trips the freshness gate.
