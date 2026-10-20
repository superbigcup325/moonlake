# devlog

Weekly log of goals, approach and quality boundaries: what was done,
why, and where the edges are.

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
  follows a deliberate rule: work around a gap rather than sink a
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
- **Parquet adapter stays eager.** Per the dependency survey:
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
  file decode stays for v1; revisit post-competition.

## W4 (acceptance package, landed early 2026-10-03): README facade,
mooncakes 0.1.0, playground, local gates

### Goal

The acceptance package: README facade with the ecosystem
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
narrative.

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

## Out-of-core (2026-10-04 .. 2026-10-13): sorted runs, grace
## hash join, grace hash aggregation

- **The promise is that a query larger than memory degrades honestly**, not
  that it never spills. Milestones: a blocking `ORDER BY` becomes sorted
  runs on disk with a streaming k-way merge feeding
  projection/DISTINCT/OFFSET/LIMIT, so a LIMIT query holds only its output
  window (10-04); a join whose inputs exceed the budget partitions both
  sides by the join-key hash and replays one partition at a time, all eight
  flavors included (10-13); a GROUP BY does the same, and because equal
  keys land in the same partition each partition's groups are final — no
  merge phase, so non-combinable accumulators (median, `string_agg`,
  `count(DISTINCT)`) spill too. Over budget without a spill store is a
  clean error, and a single low-cardinality partition that still exceeds
  the budget falls back to an in-memory pass for that partition.
- **The engine stays filesystem-free**: spilling happens through an
  injected `SpillStore`, so the library never opens a file the caller did
  not ask for (`FsStore` in the CLI is the only implementation).
- **What the gates caught**: `OutputBuilder::build` hands out
  capacity-sized vectors (4096) whose length exceeds `row_count`, and the
  merge copied by vector length rather than live rows, so a spilled
  ORDER BY over more than one chunk wrote past the destination — every
  existing fixture stayed under a chunk and masked it; the regression
  tests now cover a 5000-row merge with and without LIMIT. The same arc
  added guards for silent wrong answers: `sum()` over int64 raises
  instead of wrapping, and ORDER BY/LIMIT/OFFSET on a UNION branch is a
  parse error instead of silently truncating that branch.
- **Spill format was settled by a bake-off, not by taste**
  (`docs/spill-survey.md` §4): a hand-rolled columnar format against a
  parquet-backed one, same interface, same 60,175-row payload, same driver.
  The hand-rolled format wins on write cost (~3x), and more importantly the
  parquet arm cannot round-trip Double or Boolean through the upstream
  writer at all — only Int32/Int64/String/Binary — so it needed bit-pattern
  hacks to pass. That is a semantics argument, not a speed one, and it is
  why the in-house format is the one that ships.

## In-house Parquet decoding (2026-10-15): cutting the last
## single-maintainer dependency

- **It started as a release blocker, not a refactor itch.** `moon publish`
  validates by extracting the package and running a *fresh* `moon check`,
  and fresh resolution pulled `mizchi/parquet`'s transitive
  `mizchi/duckdb@0.6.4`; the registry artifact for that version still ships
  a legacy `moon.mod.json`, which the current toolchain refuses outright.
  CI papers over this by alternating `moon install` with per-directory
  `moon fmt` migrations, and that workaround has no equivalent inside
  publish validation. The same wall greets consumers: a scratch module
  could not `moon add superbigcup325/moonlake@0.1.0` either — it hit
  `moonbitlang/quickcheck@0.14.0` first, the same class of stale manifest,
  which is why the engine's own dependency had to move to 0.15.0 as well.
- **The choice was between waiting, vendoring, and writing the subset we
  use.** Waiting on two upstream republishes puts the release date in
  someone else's hands. Vendoring a 10k-line reader means owning it anyway,
  in the shape of a third-party blob in the tree. The subset we actually
  need turned out to be small: every file we generate, and the default
  output of DuckDB, Arrow and pandas, uses format v1 data pages with PLAIN
  or PLAIN_DICTIONARY and Snappy compression.
- **What it took** (~1,200 lines including tests): Thrift compact protocol
  for the footer and page headers with generic unknown-field skipping, a
  schema/row-group walk, definition levels through the RLE/bit-packed
  hybrid, PLAIN layouts for the six physical types, dictionary pages plus
  RLE-encoded indices, and a raw-Snappy decoder (the ecosystem has flate,
  zlib, gzip and zstd packages; Snappy is not among them). The dependency
  graph is now `moonbitlang/x` plus `moonbitlang/quickcheck`, neither with a
  legacy manifest.
- **Three bugs, three different gates, which is the argument for the
  fixtures existing**: the compact-protocol varint forgot to mask the
  continuation bit, adding 128 to every zigzag value that had one (every
  offset it touched was 64 too high) — the DuckDB golden diff caught it;
  the bit-packed run advanced by `count` bytes instead of
  `count * bit_width`, which only shows up when a decode crosses a run
  boundary — a unit test on the real index bytes pinned it; and a compacted
  value array (non-nulls only) indexed by row number, which silently
  shifted every value after the first NULL and then read out of bounds —
  only the 60k-row TPC-H parquet path could have surfaced that one.
- **The third-party corpus is part of the gate, not a one-off**: the
  apache/parquet-testing corpus (71 files) runs in nightly — every file
  in scope must match DuckDB's row count, every file out of scope must be
  refused *by name*. The first run read 20 files correctly and found
  three real defects behind the 48 documented refusals: data page v2 was
  falling into the "skip index pages" branch and surfacing as a bogus
  "chunk has 0 values", a `dictionary_page_offset` of 0 (the deprecated
  "not set" spelling) was being treated as a page offset and started the
  walk at the PAR1 magic, and an empty dictionary page reported the
  wrong reason. All three are fixed; the corpus now reports 0 wrong
  answers.
- **Scope is stated where users see it** (README, `docs/verification.md`
  §6.5): flat schemas, v1 pages, PLAIN and dictionary encodings,
  UNCOMPRESSED and Snappy; nested fields, INT96, v2 pages, DELTA and
  byte-stream-split encodings and the other codecs raise pointed scan
  errors instead of guessing. The fixture matrix in `harness/data/parquet`
  is what defines that boundary, and it runs in the same `check_all.sh`
  gate as the TPC-H answers.

## colenc-backed Parquet encodings (2026-10-17): the reader fills its
## remaining encoding gaps

- **The seam was already drawn; the reader just stopped at it.** Since
  2026-10-15 the in-house reader owns the container and page walk and refuses
  DELTA_*, BYTE_STREAM_SPLIT and RLE values with pointed errors. colenc (the
  columnar encoding kernel) is exactly the other side of that seam: the
  reader keeps the container, colenc owns page-level encodings. Wiring it in
  removes the last three refusals without touching the container code.
- **What landed:** `sources/parquet` depends on `colenc/encoders` and the
  codec gate now accepts the five families. `decode_values` grew an extended
  decoder closure per physical type: int32/int64 DELTA_BINARY_PACKED, the two
  byte-array delta encodings (decoded to strings at the adapter boundary),
  BYTE_STREAM_SPLIT for float/double, and RLE booleans. A colenc decode
  failure is translated into `SqlError::Scan("parquet: colenc: ...")`, so the
  CLI keeps reporting a clean error instead of a trap.
- **Evidence:** `moon test --target {wasm-gc,native,js}` green at 241 tests
  (both modules) including eight new embedded fixtures (tiny files written by
  pyarrow, bytes embedded so the tests run on every target without touching the
  file system); `harness/check_all.sh` passes all 27 goldens; the third-party
  corpus rerun reports 20 read, 48 refused by design, 0 failing, unchanged —
  its DELTA/BSS files are still out of scope for v2 pages or ZSTD/GZIP, not for
  the encoding.
- **Local-only for now:** colenc is not on the registry yet, so this branch
  resolves it through a `moon.work` workspace whose members are this module and
  the colenc checkout. `moon.mod` pins `superbigcup325/colenc@0.1.0`; until
  the kernel is published, the branch builds only inside that workspace.
- **Not in this step:** the write path (thrift encoding plus page assembly,
  which colenc's acceptance rig already exercises) and moving the spill
  format onto colenc encodings. Both stay on the P5 list.

## Parquet writing (2026-10-17): the engine gets a write path

- **Why now:** the reader was the only half of the container story. colenc
  supplies page bodies; the container work (thrift metadata, page headers,
  footer, magic) is the same port the acceptance rig already proved, so the
  writer is small and the format questions were already answered by the
  reader's fixtures.
- **Scope mirrors the reader on purpose:** flat required columns, v1 data
  pages, PLAIN, UNCOMPRESSED, INT32/INT64/DOUBLE/BYTE_ARRAY/BOOLEAN, one row
  group per batch (so multi-batch entries exercise row-group assembly). NULLs
  are refused with a pointed error: definition levels are the next step, not
  something to write wrong.
- **Evidence:** 245 tests green on wasm-gc, native and js (four new writer
  tests: all types round trip, one row group per batch, NULL refusal, empty
  entry). A probe file (5 rows, one row group, 463 bytes) and a two-row-group
  file (3 rows) both read back with equal values in DuckDB and pyarrow.
- **Still open on P5:** moving the spill format onto colenc encodings. The
  spill store is a closure over opaque bytes, so the change is local, but the
  survey's measured targets (248/125 ms and 7.53 MB against a 48.6 MB
  baseline) deserve their own before/after run rather than a guess.

## Spill on colenc encodings (2026-10-17): 40% smaller, slower writes

- **The format was the last hand-rolled piece.** `SpillStore` keeps opaque
  bytes, so switching the wire format to colenc is local: MLSPILL2 stores a
  dtype, an encoding code, the payload length, one presence byte per row and a
  dense colenc stream over the non-null values. Dictionary payloads carry the
  entry count and dictionary length so the reader can split dictionary from
  indices.
- **Selection is measured, not guessed.** Each column tries PLAIN and the
  encodings that apply to its type, and keeps the smallest payload; ties keep
  the earlier candidate. The expensive candidates are gated by samples: a
  4096-value sample decides whether a dictionary is plausible (at most a
  quarter distinct) and the first 256 pairs decide whether DELTA_BYTE_ARRAY is
  worth an extra pass (average common prefix of at least two bytes).
- **Numbers on the bake-off workload** (SF0.01 lineitem, 60,175 rows,
  best-of-3, release, same machine, write includes the CSV scan):

  | format | write | read | file | write RSS | read RSS |
  |---|---|---|---|---|---|
  | MLSPILL1 | 78.7 ms | 38.8 ms | 8.08 MiB | 66.4 MiB | 32.4 MiB |
  | MLSPILL2 | 115.0 ms | 44.9 ms | 4.86 MiB | 48.6 MiB | 28.5 MiB |

  Write lands at 1.46× the old cost (the agreed ceiling was 1.5×), read at
  1.16×, and the file is 40% smaller. Without the sampling gates the first
  version wrote in 124.6 ms (1.58×) — trying a dictionary over 60k unique
  strings and a DELTA_BYTE_ARRAY pass over unrelated comments was the
  difference.
- **What is deliberately not here:** null flags remain one byte per row
  (963 KB of the 4.86 MiB on this workload). A bit-packed validity bitmap is
  the obvious next lever, but it is a second format change and this one
  already met its size/time target. Byte-stream compression stays out of scope.
- **Evidence:** 249 tests on wasm-gc, native and js (new: compact selection for
  repetitive/monotonic/low-cardinality columns, all-null and sparse columns);
  all 27 golden queries and the spill equivalence checks green. The benchmark
  driver lives in `harness/spill_bench/` (excluded from the package) and
  `harness/spill_bench.py`; the baseline numbers were taken from a worktree at
  `682f87a` with the same driver copied in.

## colenc on the registry (2026-10-19): the dependency stops being local

- **The workspace hack was a publishing problem, not a design decision.**
  `superbigcup325/colenc@0.1.0` was pinned in `moon.mod` while the module was
  unreleased, so only a tree that also carried an untracked `moon.work` and a
  symlink to the colenc checkout could resolve it — and CI, which clones
  neither, could not build the branch at all.
- **Now it resolves from the registry.** A clean checkout runs
  `moon update && moon install`, which downloads `superbigcup325/colenc@0.1.0`
  into `.mooncakes`, and `moon check` goes green with no workspace file. The
  local `moon.work` and `.colenc` symlink are gone from this tree; they stay
  documented for the two-module editing loop (a workspace member shadows the
  registry version, which is useful when changing colenc and misleading when
  testing what a consumer installs).
- **Evidence:** this is a resolution claim, so it was verified as a fresh
  consumer would: `.mooncakes` wiped, `MOON_HOME` pointed at an empty scratch
  directory, `moon update` re-clones the registry index, `moon install`
  downloads colenc, then 176 tests on wasm-gc, native and js plus the 27
  golden queries pass with no workspace and no local checkout in play. (The
  suite is smaller than the 251 counted while colenc sat in the workspace:
  only this module's tests run now; colenc runs its own in its repository.)
- **What this unlocks:** the branch can go through the same gates as `main` —
  CI check/test matrices and `moon publish --dry-run` — because nothing in the
  dependency graph is local-only any more.

## Spill presence bitmaps (2026-10-19): 19% smaller, and a benchmark that
## measured the wrong binary

- **The last per-row byte was the presence channel.** MLSPILL2 wrote one flag
  byte per row per column: 963 KB of the 4.86 MiB, and on TPC-H lineitem every
  one of those bytes is a 1, because the table has no NULLs at all. The payload
  side had already been squeezed as far as the encodings go, so this was the
  only remaining per-row overhead.
- **MLSPILL3 makes presence a bitmap.** A column with no NULLs writes a single
  mode byte and nothing else; a nullable column writes `ceil(rows / 8)` bytes,
  bit `r % 8` of byte `r / 8` marking row `r`. The dense payload is untouched,
  so the encodings keep seeing a NULL-free column. Spill files never outlive
  the process, so the magic bump rejects older runs instead of carrying a
  compatibility path.
- **Numbers**, SF0.01 lineitem (60,175 rows, 16 columns), best-of-3, release
  build, same machine; the baseline is a worktree at the pre-change commit run
  through the same driver:

  | format | write | read | file | write RSS | read RSS |
  |---|---|---|---|---|---|
  | MLSPILL2 (byte flags) | 129.5 ms | 51.4 ms | 4.86 MiB | 45.5 MiB | 25.9 MiB |
  | MLSPILL3 (bitmap) | 125.2 ms | 52.1 ms | 3.94 MiB | 37.4 MiB | 24.8 MiB |

  The file is 19% smaller, write and read stay inside noise (the write side
  gets slightly faster, the read side re-runs at 48.8–52.6 ms across runs), and
  the write peak drops 18% because 963 KB of payload never gets built. The
  checksum over every scalar (dtype tags mixed in, FNV-1a) is identical to
  MLSPILL2's — `280a0917958ead3d` — which is what says this is framing, not
  values.
- **The first measurement was of the old binary, and it looked plausible.**
  `harness/spill_bench.py` hardcoded a release path from an older toolchain
  layout (`build/superbigcup325/moonlake/harness/spill_bench`); the current one
  is `build/harness/spill_bench`. The stale binary sat there since October 17,
  so the first "after" run reported MLSPILL2's size, timing and checksum to the
  byte while the source said MLSPILL3. A benchmark that silently measures code
  you did not change is worse than the format bug it hides, so the driver now
  globs the newest `spill_bench.exe` under `_build/native/release/build` and
  refuses to run when that binary is older than the driver sources or
  `moon.mod`. The numbers above are from the fixed driver, with the baseline
  built in a worktree rather than trusted from a previous log.
- **Evidence:** 180 tests on wasm-gc, native and js (four new ones pin the
  wire layout: exact byte counts for the null-free and nullable shapes, a
  13-row column whose bitmap ends mid-byte, and a buffer truncated inside the
  bitmap raising a pointed error), all 27 golden queries including the
  external-sort / grace-join / grace-aggregation equivalence checks, which run
  the spilling paths under a tiny budget and therefore round-trip MLSPILL3
  under load.


## Parquet writes take NULLs (2026-10-19): OPTIONAL columns and definition
## levels

- **The refusal was a placeholder.** The October 17 writer said "NULLs are
  refused rather than approximated", which was the honest move while
  definition levels had no encoder. colenc's RLE/bit-packed hybrid
  (`encode_rle_hybrid`) is that encoder, so the gap closed with a pre-pass, a
  schema flag and one extra section per page.
- **What landed:** the writer walks the entry once to decide, per column,
  whether it is OPTIONAL (it holds a NULL anywhere) or REQUIRED — the decision
  is file-wide because the schema is, so a column that happens to be null-free
  in one row group still carries levels in that group. An optional page body is
  `[u32 length][hybrid levels, bit width 1][dense values]`; the v1 page header
  needs nothing extra (the level section is self-describing) and the chunk
  metadata lists RLE next to PLAIN.
- **Evidence:** 181 tests on wasm-gc, native and js, including a NULL in every
  physical type and a two-group case that is null-free in the first group and
  NULL in the second. Interop is judged by readers this writer does not own: a
  three-row file with NULLs in an INT32 and a BYTE_ARRAY column reads back
  through pyarrow as `{'a': [10, None, -3], 'b': [b'alpha', b'', None]}` and
  through DuckDB as `(10, b'alpha'), (NULL, b''), (-3, NULL)`, both columns
  reported nullable — an empty string stays distinct from NULL in both.
- **Still out of scope:** encodings other than PLAIN, compression, v2 pages,
  nested fields, INT96 — the writer's scope stays the reader's.


## Lazy scans (2026-10-20): the catalog stops holding tables

- **The catalog was the last place that required the whole table.** Registration
  read and parsed everything and handed back `batches`; every query paid for
  all columns whether it read one or sixteen, and Parquet's row groups were an
  on-disk detail nobody could exploit. A `ScanSource` with a `BatchStream`
  cursor turns the table into schema + where the bytes live, and the four
  pushdowns fall out of that interface rather than sitting on top of a
  materialized table.
- **What landed:** `TableEntry` holds `batches` *or* a `source`; `@csv` and
  `@parquet` registration return sources (`scan_file` keeps the path and
  re-reads on open, `scan_string`/`scan_bytes` keep the caller's bytes); scans
  yield 4096-row batches (`SCAN_BATCH_ROWS`); the engine passes the pruned
  column list it already computed as `ScanRequest.projection`, so a
  `count(*)` decodes no columns at all; Parquet decodes one column chunk of one
  row group at a time and skips row groups whose `min_value`/`max_value` and
  `null_count` rule out the predicate. Hints come only from the table's build
  filter, the expression the engine already applies to that table's rows
  before joining it, and the engine still filters — a hint can cost work, never
  a row. A lazy table's build filter is also run per incoming batch, so a
  selective scan no longer accumulates the table it filters.
- **Evidence:** 200 tests in the module's packages on wasm-gc, native and js
  (19 new); all 27 golden queries still
  match DuckDB (including the multi-row-group Parquet fixture, whose selective
  query now reads 2 of 4 groups); six mutation tests show the new tests have
  teeth (disabling `Lt` pruning, trusting inexact bounds, dropping the strict
  UTF-8 check, ignoring row-group skipping, ignoring the projection, and letting
  float bounds prune equality each fail the test that is supposed to catch
  it); `harness/bench_scan.py` A/Bs against a
  binary built from the previous commit. CSV SF0.01: q1 130→94 ms, q6
  111→67 ms, q3 130→73 ms, `count(*)` 105→48 ms, peak RSS −13…−26%. Parquet,
  1Mi generated rows in 8 row groups: `count(*)` 446→57 ms, a filter keeping
  6 groups 438→51 ms, one keeping a single group 424→47 ms, peak RSS
  130→32–39 MB.
- **A semantic trap found while testing:** this engine's `Scalar::compare`
  treats NaN as equal to every value, while Parquet writers leave NaN out of
  their min/max — so trusting float bounds for `=`, `<=`, `>=` or `<>` would
  drop a group whose NaN row does match. Float pruning is limited to the strict
  comparisons, and a fixture with the group `[NaN, 5.0]` (statistics say
  `[5, 5]`) pins it: `f = 7.0` must return the NaN row.
- **Edges kept visible:** no constant folding, so `date '1994-01-01' +
  interval '1' year` produces no hint although the plain literal does;
  predicates do not cross a derived table, so q6p's subquery still decodes all
  16 columns (152→142 ms, +3 MB); CSV has no statistics to skip with; a
  file-backed table is read twice per query because the fs API has no range
  reads.


## Release acceptance for 0.3.0 (2026-10-20): the package, the page, the
## baseline

- **Three artifacts were accepted, not the repository.** A fresh consumer
  module resolved `superbigcup325/moonlake@0.3.0` (plus x 0.5.6, quickcheck
  0.15.0, colenc 0.1.0) against a freshly cloned registry index; the installed
  tree diffs clean against `git archive v0.3.0` except the dev-only paths the
  archive excludes and `README.md` materialized from the symlink; the README
  library example runs on native, wasm-gc and js. That is the consumer's
  evidence, and it is now written down rather than re-derived by hand.
- **The browser page was broken, and had been for the whole release.**
  `playground.wasm` imported the wasm host's filesystem module, so the page
  threw at `WebAssembly.instantiate` and Run never enabled; the deployed site
  only still worked because it was a 0.1.0 build from before the refactor. The
  lazy `CsvInput`/`ParquetInput` enums did it: `scan_string` and `scan_bytes`
  went through the same `read_input` as `scan_file`, so `@fs` stayed reachable
  from the in-memory path. Function-field readers fixed the link graph (12
  host imports → 0, matching the pre-lazy-scan build, which is the comparison
  that should have been run when the scan layer landed). CI now fails when the
  playground wasm imports anything beyond the js-string builtins — a build
  gate, because this class of bug is invisible to every test that does not
  instantiate the module the way a browser does.
- **DATE was never valid JSON.** One match arm in `to_json` printed all
  scalars through `to_string`; a DATE came out as a bare `1992-01-04`. The
  page's `JSON.parse` threw, `--json` was invalid for any DATE column, and the
  page's error path left the previous status on screen because it returned
  without setting one. Quoted dates plus a `failed` status on both catch paths;
  the acceptance suite now asserts DATE min/max render as calendar dates and
  that the CSV and Parquet paths agree cell for cell.
- **The deploy trigger was the release trigger nobody checked.** `pages.yml`
  watched `playground/**`, so engine releases never redeployed the site: the
  public demo said `engine 0.1.0` while main carried 0.3.0. The engine
  directories now trigger it too, and the live version is part of the
  acceptance (it is the artifact candidates click first).
- **One file per upload is a limitation, not a bug.** Cross-file JOINs cannot
  be expressed in the page (the bridge registers one table per run); the
  acceptance pins the honest failure — a bind error naming the missing table —
  and the README now says so instead of implying a general SQL console. Joins
  over the uploaded table were verified in the same run, so the limit is the
  bridge, not the engine.
- **A baseline is a machine, a build and a hash, not a table of numbers.**
  `harness/bench_release.py` records scan/join/gather/spill with the toolchain,
  CPU, governor, kernel, commit, binary hash and load average, times the fastest
  of seven runs after two warm-ups, and hashes each case's stdout so a
  comparison can tell "same work, faster" from "different work". The first
  record is committed under `harness/baseline/`. Two decisions came out of
  measuring it twice: SF0.01 is unusable for this (its 20–40 ms cases swing
  ±30% on a busy laptop), so the record lives at SF0.1, where the same binary
  compared against itself stays inside ±6%; and wall time alone is noisier than
  `user+sys`, so both are recorded. `docs/bench-baseline.md` states the ±7%
  noise floor and why gather is measured end to end (the kernel is
  package-private) instead of pretending it is a microbenchmark.
- **What the acceptance did not do:** it did not re-run the full TPC-H chain on
  the fixed tree (the 27-golden check covers it) and it did not deploy — the
  live page still serves 0.1.0 until the next push to main. The 0.3.0 tag was
  not moved; the fixes are unreleased on main and a patch version is a release
  decision.
- **Follow-up: 0.3.1 shipped the same evening.** `moon publish` returned
  `Server status: 200 OK`, `moon view` reports `Latest: 0.3.1` (three versions),
  and the annotated tag `v0.3.1` plus a GitHub release point at the published
  tree. The registry check was re-run from an empty module and a fresh
  `MOON_HOME`: 0.3.1 resolves the same four-package graph, its tree equals
  `git archive v0.3.1` apart from the package's documented exclusions, the
  README example prints `north|1` on all three backends, and a DATE column now
  comes back as `[{"first_day":"2024-03-01"}]` — valid JSON — which is the 0.3.0
  bug seen from a consumer's side.
- **The baseline's second lesson.** Re-measuring at 0.3.1 produced numbers
  10–25% faster than the 0.3.0 record for identical engine code, because the
  laptop was in a different thermal/load state (load 2.7 → 1.9, CPU ~1.5 →
  1.7 GHz). Both records are kept side by side and `bench_release.py` now
  records the CPU frequency, because otherwise the next reader would mistake
  machine state for an optimization.

2026-10-21 — **The out-of-core path leaked, and nothing was watching it.**
Goal: make `--memory` trustworthy before touching its performance — a budget
that silently leaves files behind is worse than no budget, because the failure
arrives later and somewhere else. What the audit turned up was one real leak
(intermediate run files, success path only, seven files per spilled sort), one
unreachable counter set (`explain_analyze` hard-coded `in_memory()`), and two
structural limits (a 64-partition cap reported as "hash skew"; a partition
materialized before aggregation). Fixed the first two outright, replaced the
cap with two extra partitioning levels, and made aggregation pull a partition
one file at a time. Quality boundary: the split still refuses one key holding a
side, and its error now says that is the reason; the byte counters are measured
at the store boundary so an operator cannot forget to report. Honest limit
recorded in `verification.md` §10: the aggregation change removes a term from
the memory equation but is not separately measurable on the current workloads,
which is a workload gap rather than an optimization.
