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

