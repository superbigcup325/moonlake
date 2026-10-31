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

2026-10-21 (later) — **The corpus gate was counting footers, not reads.**
Goal: check the 0.4.0 priority list against the tree instead of against its own
summary, starting with the claim that the apache/parquet-testing corpus proves
what the reader says it supports. It did not. The check asked each file for
`count(*)`, which reads a footer and no page, so 18 of the 35 files it counted
as "read" could not decode a single column: `hadoop_lz4_compressed` passed while
`select c0` raised "compression codec 5 is not supported", and
`delta_binary_packed` passed with v2 pages, so the DELTA path never ran. The
gate now decodes every column, compares a five-row sample against DuckDB cell
for cell (type-aware, so `true`/`1`/`NaN` compare as values, not spellings), and
records each file's class in `harness/parquet_corpus_expected.json` so a class
flip fails the nightly instead of being invisible. Result: 17 decoded by value,
51 refused by design, 0 failing; 3 skipped because DuckDB cannot read them
either. What the corpus still cannot prove is now written down: no external file
exercises DELTA_BINARY_PACKED, the DELTA byte-array pair or BYTE_STREAM_SPLIT,
because every file that carries one also carries a v2 page or a codec outside
scope — those five encodings rest on the embedded fixtures in
`colenc_integration_test.mbt`, not on third-party data. Two smaller corrections
went in beside it: the `page.mbt` scope comment (still said "PLAIN and
dictionary" after colenc landed) and the `verification.md` §11 count that had
been quoted as evidence.

2026-10-21 (later still) — **One `--spill-dir` was not safe to share.**
Goal: close the spill holes the audit found without loosening what the
out-of-core path already proves. The one that mattered was reproducible: every
query wrote `run0.bin`, `run1.bin` … into the directory it was given, and each
deleted every `run<n>.bin` it found when it finished — so two concurrent spilled
queries sharing a `--spill-dir` exited 1 on both sides with `spill read: No such
file or directory`. Measured against the previous binary; after the fix the same
pair returns `count 7` and `count 9` and leaves the directory empty. The fix is
structural rather than defensive: one `moonlake-spill-<n>` subdirectory per
query, `create_dir` as the lock, the purge scoped to the directory this process
created — which also means a caller's own files in `--spill-dir` are never even
listed. The other hole has no fix at this layer: a killed process leaves its
subdirectory, and `moonbitlang/x/fs` exposes no pid, no clock and no file
timestamp, so a dead owner is indistinguishable from a live one; deleting on a
guess would break a running query. The boundary is now measured and pinned in
the acceptance (`kill -9` leaves `moonlake-spill-0` with 40 files and the next
query leaves it alone). One path was tried and dropped: read `/proc/self/stat`
for a pid and reap directories whose owner is gone. It cannot work — x/fs sizes
a file with `fseek`+`ftell` and /proc reports size 0, so the read comes back
empty — and the `None` fallback would have turned the reap into silent dead
code, which is worse than not having it. Reclaiming interrupted runs needs a
native syscall surface: a decision against the "no FFI" claim, not a bug fix.

2026-10-21 (bench) — **A guard, and the floor it exposed.** Goal: make "same
machine, same data, same build" something the tool checks instead of something
the doc asks the reader to remember. `--compare` now refuses to print deltas
when the two records disagree on CPU, cores, kernel, toolchain, dataset hash,
build mode, runs or warm-ups; it prints clock/load/governor as advisory lines
instead, because those legitimately move between sessions and are what made the
0.3.0 → 0.3.1 pair look 10–25% faster on identical code. Each case also records
the spread of its own runs, so a delta smaller than that spread is labelled as
noise rather than reported as a win; records from before the field say so
instead of implying the deltas mean something.

Writing that guard turned up a measurement bug that the previous day's
`data_sha256` had introduced: hashing the dataset read all 75 MB of
`lineitem.csv` into the harness process before the cases ran, and a forked child
starts with its parent's resident pages mapped, so `ru_maxrss` on the two
Parquet cases — whose own footprint is 25 and 39 MB — read 94.9 MB for both. A
controlled check confirmed the mechanism: 150 MB of ballast in the parent made
an 11 ms `count(*)` report 164 MB. `posix_spawn` does not help (vfork shares the
address space until exec). The hash now runs after the measurements and the
parent is collected before they start; the two cases return to 25.1 and 39.1 MB
with every other case unchanged. Evidence: two records taken minutes apart
around the fix, compared by the new guard — the RSS rows move 94.9 → 25.1 and
39.1 while nothing else does, and the same pair shows wall time moving up to 21%
between two runs of the same binary, which is exactly why the spread column
exists.

2026-10-21 (writer) — **One pass, and the two walls behind it.** Goal: take the
materialized input out of the Parquet writer, the one term the audit could
attribute without touching a dependency. The writer called `entry.scan`, held
the whole projected table, and walked it twice — the first walk existed only to
decide REQUIRED vs OPTIONAL, because the schema is file-wide while the pages are
written before the footer is. Writing every column OPTIONAL removes the reason
for the walk: an OPTIONAL schema can be declared up front and still describe a
NULL that arrives in a later batch. Measured on SF0.1 lineitem: the file grows
by 18,816 bytes (0.03% — hybrid RLE turns 600k ones into a few bytes), and peak
RSS falls 407 → 328 MB writing from `lineitem.parquet`, 286 → 203 MB with
`--snappy`, 456 → 421 MB from the CSV. Two walls stand behind this change and
neither is the writer's: the sources read whole files (75 and 84.8 MB) because
the fs API has no range reads, and `write_bytes` still accumulates the archive
because `x/fs` has no incremental write handle. The CSV number is now dominated
by the scan itself — `count(*)` over the same file costs 341 MB before the
writer appends anything — so the next real step is a native file sink, which is
the same FFI decision the interrupted-spill reaping is waiting on: one decision,
two payoffs. Scope kept honest by tests instead of prose: the existing writer
tests are round-trips through the reader, and `check_writer_interop.py` re-read
the OPTIONAL output with pyarrow and DuckDB on all three paths (raw, snappy,
DuckDB-written input) without a change.

2026-10-22 — **A release archive needs a caller.** Goal: finish the release
checks without treating a local source build as evidence for a packaged
consumer. Added a public-API fixture and `check_consumer.py`: extract the zip,
build a different module against it, fetch the registry/dependencies into a
fresh toolchain home, and run native / wasm-gc / js. All three return the same
CSV and raw/Snappy Parquet results, including DATE/NULLs and table removal.
The per-PR check and release workflow now run it; the record identifies the zip
by SHA-256. Quality boundary: this is archive evidence, not a registry install;
`--registry-version` provides that separate post-publish check and has not been
run for the unpublished 0.4.0 release. No credentials or package upload are
needed for the archive gate.

The deployed `4e58b3d` already has green CI, nightly and Pages. Its public page
passes 15 browser checks, and the version check now compares the exact module
version. A deliberate wrong-version run fails only that check (14/15, exit 1),
so a stale but functional page cannot pass as the expected release. Evidence
and commands are in `verification.md` §16; six new harness regression tests
bring the Python suite to 13, with 212 MoonBit tests still passing per target.

2026-10-23 — **JSON has no infinity, and the engine means infinity.** Goal:
settle what `--json` and the playground do with non-finite doubles before a
release is cut. The audit had flagged `to_json`'s `other => to_string()` arm;
the reproduction was one query — `SELECT 1.0/0.0, -1.0/0.0, 0.0/0.0` — whose
output parsed as neither `--json` output nor a page result, because `Infinity`,
`-Infinity` and `NaN` are not JSON tokens. The engine is right to produce them:
integer division is DuckDB's true division, so `x / 0` is inf and `0.0/0.0` is
NaN, and the arithmetic path keeps that instead of turning it into an error.
The encoder was the only thing lying about it. Non-finite doubles now serialize
as the strings `"Infinity"`, `"-Infinity"` and `"NaN"`: the line is strictly
parseable, the three values stay distinguishable from each other, and SQL NULL
is still `null`. This deliberately diverges from DuckDB, which was measured
here rather than assumed: `to_json(1.0::DOUBLE/0.0)::VARCHAR` returns the bare
token `Infinity` (not a quoted string, and not `to_json('Infinity')`), i.e.
a document strict parsers reject; collapsing the values to `null` would buy
compatibility at the price of hiding a real value. Finite doubles still print
as JSON numbers, and DATE stays a quoted calendar date.
Quality boundary: the fix is in the one result encoder both the CLI and the
page use, and the evidence is an exact-string test plus `@json.parse` on the
same string, a CLI run that `JSON.parse`s to the expected object, and a new
browser scenario (16/16) that asserts the table shows `Infinity`/`NaN` while
the page's status stays a row count rather than falling into its error path.
What this does not do: change `/` semantics, add a JSON serialization option,
match DuckDB's relaxed output byte for byte, or claim a partner's readers
interpret the strings the same way.

2026-10-23 — **The writer stops holding its own output.** Goal: make Parquet
file output cost memory proportional to the batches in flight rather than to
the archive, without changing a byte of the format and without splitting the
public interface per backend. The starting point was measured, not assumed:
`write_file_with` built the whole archive in a `Buffer` and then handed that
one `Bytes` to a whole-file write, so a 75 MB output kept roughly two copies of
it alive and a 301 MB output kept about 1.4 GB of peak RSS. `moonbitlang/x`
offers no incremental write handle and its file functions are private, so the
transport had to come from somewhere else. Two routes were rejected: a
native-only dependency poisons the wasm-gc build plan outright, and
target-filtered public functions make the interface differ per backend (a wasm
consumer gets `Value … not found` for a function that exists on native).

What shipped is a native-only `platform/io` package (a small C stub behind
`native-stub`, gated so wasm-gc/js build an empty package) plus a shared writer
flow: `write_with(entry, codec, emit)` emits pages, `write_bytes_with` emits into
a buffer, and `write_file_with` is one shared signature over a target-split
private impl. The writer keeps owning offsets — a sink that miscounts bytes is
how a footer ends up pointing past its data — and it publishes by renaming a
temporary file, so a failure leaves the previous file in place.

Quality boundary: the archive is byte-identical to what 0.4.0 wrote (md5 compared
for both codecs at three input sizes), 223/218/218 tests pass across native,
wasm-gc and js with `--deny-warn`, the 27 golden queries and 7 spill checks are
unchanged, pyarrow and DuckDB read the streamed files, and `moon package --list`
ships the C file. Two things this does not claim: the 2 GiB page-offset limit is
still enforced, and a CSV input still costs memory in the scan, which is why the
`--csv` numbers improve by the archive size instead of collapsing to the
Parquet-input plateau.

2026-10-23 (reader) — **The reader stops holding its input.** Goal: remove the
same term from the read side, where it was even more visible — a scan of a 287 MB
archive peaked at 295 MB before decoding anything, and `count(*)`, a query whose
answer is in the footer, paid for the file. Registration read the whole thing to
parse the footer and then kept it alive for the row groups.

The native binding built for the writer already had the syscalls needed for the
other half of the job, so the read side is one more C entry point and a
`FileReader` in `platform/io`: positioned reads (`pread`) with a size from
`fstat`, and a refusal when a range does not fit. The reader's input became
`ParquetInput { size, read_at }` — a memory slice for `scan_bytes`, one `pread`
per range on native, and the whole-file read every wasm/js host still requires,
behind a target-split file. `read_footer` reads 8 tail bytes and then the footer
body; `decode_chunk` reads one column chunk into a buffer that starts at 0, so
page offsets inside a chunk are untouched and the decoder stays ignorant of file
layout. Chunk offsets stay `Int64` because footers store them that way, and a
chunk over 2 GiB is refused by column name instead of being narrowed.

Quality boundary: this is a *reader* change, so the evidence has to be about
reads, not answers — a whole-file reader returns the same rows. Two things hold
it down. First, results: 2.4 M rows over a 287 MB archive match DuckDB on counts
exactly and on sums within summation order. Second, ranges: a whitebox test
installs an input that logs every range and asserts that registration is exactly
two reads, that a one-column scan is exactly one chunk starting at byte 4, and
that a two-column scan fetches two non-overlapping ranges in file order; the
guards (2 GiB chunk, read past the end) and the footer failures (truncated
trailer, negative footer length, four-byte file, missing path) are tested
directly, and `FileReader` has its own tests including two positioned reads that
must not disturb each other. 236/227/227 tests across native, wasm-gc and js with
`--deny-warn`, 27 golden queries, 7 spill checks, writer interop unchanged.

Peak RSS: 295 → 12 MB for `count(*)` on 287 MB, 585 → 12 MB on 574 MB, and
one-column aggregates are now bounded by the row-group columns in flight
(37 → 67 MB as input doubles) rather than by the file. What this does not claim:
CSV scans still read whole files (that is the remaining memory term), the
writer's 2 GiB page-offset limit is untouched, and the browser
build still pays a whole-file read because its fs module cannot do better.

2026-10-24 (csv) — **The CSV scan stops indexing the file.** Goal: the last
open memory item from the reader work — CSV reads still pulled the whole file
into `Bytes` and, worse, built a byte-level offset index for every cell of it
(start, end, quoted flag, row table: ~9 bytes per cell, ~700 MB for a 4× SF0.1
copy). A scan only needs the rows of the batch it is building, so the index was
being paid whole to serve a 4096-row slice.

The Parquet reader already had the primitive, so CSV took the same shape:
`CsvInput { label, size, read_at, reset }`, a 4 MB range at a time on native
through `platform/io`, and the whole-file read every wasm/js host still forces
behind a target-split file. Registration reads a 64 KB prefix (header plus the
100-row inference sample) and grows it only when a row does not fit there; a scan
indexes one range, trims it to whole 4096-row batches, materializes those
batches, and drops the range. Rows past the last whole batch are re-read as the
start of the next range, so a batch never straddles two ranges. A range too
small for one record (a long quoted field with newlines) is widened until it
holds one, and the header is re-checked at the first range of every file. Offsets
inside a range start at zero, so the reader and the per-cell parsers did not
change at all — only where their bytes come from and how many rows they see.

Two things were not obvious. First, the `reset` hook exists because on wasm/js
the input is a whole-file snapshot: the existing blackbox test that rewrites a
file between registration and scan caught exactly that regression (3 rows became
2), so the snapshot is dropped when a scan opens and the semantics match native
again. Second, the row index into the chunk had to become `skip + r` rather than
`skip + r + 1`; the off-by-one read one row past the end on the *last* row of a
range, which is why the first run panicked in `RawCsv::decode` instead of
returning wrong data — the safer of the two failures, and the reason the tests
below assert values rather than only row counts.

Quality boundary: a chunked reader and a whole-file reader return the same rows,
so the evidence has to be about reads as well as answers. Peak RSS over SF0.1
`lineitem`: `count(*)` 327.8 → 34.2 MB (1×), 537.7 → 35.1 (2×), 1062.7 → 35.2
(4×); `sum(l_quantity)` 326.2 → 39.1, 538.5 → 47.1, 1062.6 → 57.4; a grouped
query 1062.9 → 97.1 at 2.4 M rows. `write --csv` loses the same term: 320.1 →
35.0 MB at 1× and 1062.7 → 34.9 MB at 4×, with byte-identical archives (md5
`84a4dfd8…` 1×, `425bc3c1…` 2×, `043b084c…` 4×) and DuckDB-identical counts,
sums and groups. Five whitebox tests hold the mechanism down: recorded ranges
(prefix-sized registration, 4 MB scan reads), a fixture whose every row carries
a newline inside quotes so boundaries land inside quoted fields, a 4.25 MB
single quoted field that forces the range to grow, an error at data row 99,000
reporting file row 99002, and a changed header being refused on open.
241/232/232 tests across native, wasm-gc and js with `--deny-warn`, 27 golden
queries, 7 spill checks, writer interop unchanged.

What this does not claim: wasm-gc/js still hold the file bytes (no range read in
their fs module, and nothing to seek in a browser), the writer's 2 GiB page-offset
limit is untouched, and spill-lease reclamation is still the next item.

2026-10-24 (spill) — **A spill directory can now say who owns it.** Goal: the
one entry on the memory list that was never a performance problem — a query
killed with `SIGKILL` left its `moonlake-spill-<n>` behind, and nothing would
ever remove it. The reason it was left was honest: `moonbitlang/x/fs` exposes no
pid, no clock and no file timestamp, so a dead owner and a live one looked
identical, and the previous section called the leak a pinned boundary rather than
fix it with a guess.

Approach: write the proof down when the directory is claimed. Right after
`create_dir` wins, the query creates `owner` with `O_CREAT|O_EXCL` — a claim, not
a lock, so an existing marker is never overwritten — recording its pid, the
kernel's boot id, and that pid's start time (field 22 of `/proc/<pid>/stat`).
A later run judges a marker with three facts and needs all of them: a different
boot id means the owner died before the reboot; a missing `/proc/<pid>` means the
process is gone; a different start time means the number was reused. Everything
else — no marker, an unknown version, a missing field, no `/proc`, a probe that
errors — is "cannot tell", and a directory that cannot be judged is kept and
reported. Reclaiming renames the marker to `owner.stale-<nonce>` before deleting
anything: that rename is the claim among concurrent reapers, and it guarantees a
reclaim interrupted in the middle leaves a directory with no marker, which the
"cannot tell" rule then refuses to touch again.

The rules are pure — `judge_owner(mark, boot_id_here, probe)` — and the machine
facts are target-split, so the table of seven combinations is tested on all three
backends without forking a process or rebooting, while four native tests hit the
real `/proc`. The protocol sits in `cmd/main`, an executable nobody imports, so
the published interface did not move and `spill` still knows nothing about
leases. `platform/io` grew an exclusive create, a rename that reports a vanished
source instead of failing, a hand-rolled `/proc` read (`x/fs` sizes a read from
`stat`, and every `/proc` file reports 0, so a size-driven read returns empty),
and the clock: 113 → 177 lines of C.

Two things cost time. The boot id file ends with a newline, and the marker parser
trims while the in-memory comparison did not, so a marker this process had just
written judged itself stale — the native test caught it in the first run. And the
acceptance check I first wrote waited for `run*.bin` before killing the query;
on SF0.1 with `--memory 200K` the spill phase lasts a fraction of the run, so the
poll lost the race and the query exited cleanly. The check now freezes the query
the moment its `owner` file appears and writes the leaked run file by hand, which
is exactly what a kill mid-sort leaves. The same investigation showed check 4 of
the existing suite would pass on `spill runs: 0`, so it now requires a non-zero
count.

Quality boundary: one directory is only reclaimed on positive evidence. The known
false-dead case is a `--spill-dir` shared across PID namespaces, where pids mean
different things in different containers; that is documented rather than
detected, and the mitigation is a per-container directory. On macOS there is no
boot id to record, so nothing is claimed and nothing is reclaimed — the old
behaviour, minus the surprise.

Evidence: 254 / 241 / 241 tests across native, wasm-gc and js with
`--deny-warn`; a ten-check `harness/spill_accept.sh` including the frozen-then-
`kill -9` reclaim and the live-owner protection; 27 golden queries; writer
interop; playground 16/16; `moon package --list` at 184 entries.

What this does not claim: no lease is renewed or expired by time, so an owner
that hangs forever keeps its directory forever (it is still running, so that is
the right answer), and the writer's 2 GiB page-offset limit is still its own task.

2026-10-24 (structure) — **Three copies of the same spill machinery became one.**
Goal: nothing behavioural — a survey of the code after the parquet/CSV range reads
and the spill reclaim, asking where the same thing is written more than once.
Four answers, all of them about maintenance rather than speed: the three spill
consumers each carried the run writer, the key hash and the "remove your run
files on both exit paths" loop; the CSV and Parquet native inputs carried the
same four range-reading helpers down to identical bytes; `analyze_query` and
`run_query` were the same fifteen lines with a different engine call inside; and
`engine/exec.mbt` mixes aggregation, sorting, joins and batch plumbing in one
2286-line file.

The first three are done. `engine/spillruns.mbt` now holds what sort, join and
aggregation share — batch sizing, the writer (with a `partitioned` constructor so
callers stop assembling its fields by hand), the key hash and row routing, the
partition reader, and one removal call per exit path. The partition count was one
formula with two inline caps (256 in the join, 64 in the aggregation), so it is
`partition_count(bytes, budget, cap)` with each caller passing the cap its own
recursion requires; that is the one place where "unify the duplication" would
have changed behaviour if it had been done carelessly. `platform/io` gained
`file_size`, `read_range` and `close_quietly`, which is where the "one open per
range, close on the failure path" rule belongs — two copies of a descriptor
lifetime rule is how one of them gets fixed alone. `with_spill_run` wraps the
budgeted query in the CLI, so both commands share one purge-on-both-paths
skeleton; the `errdefer` was the line worth not copying twice.

Left undone at that point, and done in the next section: splitting
`engine/exec.mbt` four ways (aggregation, sorting, joins, batch utilities) and
`cmd/main/main.mbt` (usage text, glob, spill directory, commands). Also left: the
`run<n>.bin` naming rule is written
in `spill/store.mbt` and guessed again by the CLI's purge, which is a real
encapsulation gap; closing it means giving the published `spill` package a public
name rule, so it is an interface decision, not a refactor.

Verification: `moon check --deny-warn` on native/wasm-gc/js after each commit,
`moon fmt --check`, `moon info` with no `.mbti` change, 254/241/241 tests, 27
golden queries, spill acceptance 10/10, writer interop, playground 16/16, and the
release archive gained exactly one file (`engine/spillruns.mbt`). One behavioural
detail was checked on purpose rather than assumed: a missing CSV still reports
`cannot read file at <path>: cannot open <path>: <errno>`, because the shared
helper raises the same text the two copies did.

2026-10-24 (structure) — **Two 2000-line files became eight that say what they
hold.** Goal: nothing behavioural again, the second half of the survey above.
`engine/exec.mbt` (2286 lines) was four stages in one file — aggregation, the
ordering/slicing stage, the joins, and the batch primitives they all call — and
`cmd/main/main.mbt` (750) had the usage texts, `--csv` glob expansion and the
spill-directory bookkeeping sitting next to the two commands.

Approach: split on the `///|` separator, not by hand, and prove the result is a
move rather than an edit. A script cut both files into blocks, wrote them into
the new files by an explicit index map, and then compared the block multisets
against `HEAD`: 66/66 blocks for the engine, 25/25 for the CLI, zero differences
in either direction. That check is the whole argument — it catches a block
dropped at a boundary, a block emitted twice, and any accidental rewording,
none of which a green test suite would distinguish from a correct move. In
MoonBit order within a package is irrelevant and package-private names cross
files freely, so no block needed a rename, a `pub`, or a forward declaration;
each new file only gained a header comment saying what belongs in it.

One thing the split taught: `window` in `exec.mbt` is not the window-function
stage (that is `engine/window.mbt` and `exec_windows`), it is the OFFSET/LIMIT
slice over a row-id list, so it went to `exec_sort.mbt` next to `order_limit`.
Filing it by name would have been wrong, which is the argument for reading each
block's doc comment before moving it rather than trusting the file's outline.

Boundary kept: `extsort.mbt`, `extjoin.mbt` and `extagg.mbt` are the spilling
counterparts and did not move, so an in-memory stage and its over-budget twin
stay one directory apart instead of one file. The CLI's single test block moved
whole into `glob.mbt` rather than being split across the two files it tests, so
the test *count* stayed 254/241/241 — a split block would have turned one test
into two and made the numbers drift for a change that added no assertion.

Verification: `moon check --deny-warn` on native/wasm-gc/js, `moon fmt --check`,
`moon info` with no `.mbti` change, 254/241/241 tests, 27 golden queries, spill
acceptance 10/10, writer interop, playground 16/16, and `moon package --list`
185 → 191 entries (three fewer engine files than that suggests: `exec.mbt` is
gone) — the archive grew by exactly the six files the split added.

2026-10-24 (release) — **0.5.0 shipped, and the docs were made readable first.**
Goal: publish the four memory changes since 0.4.0, but read the tracked docs as
someone who only has the repository before doing it.

What that reading found: four tracked docs and the `platform/io` header cited a
local decision note by filename, the release checker listed a local scratch directory
among the paths an archive must not contain, one benchmark record stored the
absolute path of the toolchain binary it ran, and eight places used milestone
labels (`N1`, `N2a`, `N2b`, `N3`) that mean nothing outside the work that
produced them. None of those is a wrong claim; each is a sentence a stranger
cannot follow.

Fixes, chosen so the reasoning stays where the claim is: the `platform/io`
header now lists the two routes that were rejected (a native-only dependency
poisons the wasm-gc build plan; target-filtered public functions make the
interface differ per backend), `verification.md` says which route shipped and
what contract the binding keeps, and the devlog keeps the prose. The archive
gate stopped naming one dot-directory and now rejects any path component
starting with a dot, which is both stricter and needs no local knowledge.
Recorded toolchain strings keep the version and build hash and drop the path.
Milestone labels became the change they name: the streaming writer, the Parquet
range reader, the CSV range reader, spill-lease reclamation.

One accidental confirmation of the gate: the version bump commit was refused by
the pre-commit hook because `moonlake_test.mbt` still asserted `0.4.0` on both
`version()` and `VERSION`. A release touches more than `moon.mod`, and the hook
is what noticed.

Publish: `moon publish --dry-run` returned `202 Accepted`, `moon publish`
returned `Server status: 200 OK`, and the registry consumer passed on native,
wasm-gc and js against the published artifact. The deployed page passed its
16/16 acceptance with the version gate defaulting to `moon.mod`. Evidence,
including run links, is in `verification.md` §23.

Quality boundary: nothing behavioural changed between the last code commit of
0.5.0 and the release commit except the version constants; the docs commit moved
claims and the gate together, and the gate keeps passing over the same 187-file
archive.

2026-10-24 (planning) — **The plan moved into the repository, and 0.5.0 got its record.**

The repository had no roadmap: what comes next, what is refused on purpose and
what would start a held direction lived in an untracked handoff note, so a
reader could only take the changelog's word for it. `docs/ROADMAP.md` now
carries that: the limits refused on purpose (a writer offset past 2 GiB,
whole-file reads on wasm-gc/js, an executor that is not streaming end to end,
the schema and encoding scope, spill reclamation declining to judge an owner it
cannot prove dead), what closing each would involve, and the trigger each held
direction waits for (cost-based planning, bit-packed validity, dictionary
encodings, DECIMAL/TIMESTAMP, Arrow/DataFrame, parallelism). The README states
the two limits a user can actually hit and links to it; AGENTS.md keeps one
pointer, so the plan is not written twice.

0.5.0 shipped without a committed performance record, which is how "did it get
slower" becomes a memory. Two records were taken in one session:
`2026-10-24-0.5.0.json`, and a 0.4.0 rebuilt from tag `v0.4.0` in a worktree,
because yesterday's 0.4.0 record sits on a different kernel and `--compare`
refuses that by design. The pair shows where the release's work landed: CSV
scans 345 -> 35 MB peak RSS and 22% less wall time, joins 305 -> 51 MB,
`count(*)` over Parquet 10.9 -> 3.8 ms because the reader stopped bringing the
whole file in. Eight cases moved further than their own run spread; the rest,
including a 34.6% `sum(l_quantity)` delta that sits inside a 61.7% spread, are
noise, and `bench-baseline.md` says so instead of counting them as wins.

Issue #9 is closed. Both follow-ups were already done — every release since
0.3.1 was published from its tag, and the playground upload path is driven in
real Chromium in CI — so the closure comment points at the sections that prove
it rather than at a session log.

2026-10-24 (writer) — **The 2 GiB file limit was an offset type, not a design.**

Every release since writing landed carried the same limitation line: the writer
refuses an output that would need a page offset past 2 GiB. Reading the guard
showed it was not a compromise, just an `Int32` in three places (the column
chunk's `file_offset`, the column metadata's `data_page_offset`, and the
counted position) with a polite error in front of it. A file position is
64-bit in Parquet, so the fix is a type: the reader already decoded those
fields as `Int64` and the reader's only narrowing is a chunk's length, which
stays.

The before/after is one input. 2.35 GiB of CSV, written by 0.5.0 and by this
tree: 0.5.0 exits 1 with `file would exceed the 2 GiB page offset limit` and
leaves nothing behind (the streaming sink renames on success, so a failure
leaves the previous file alone); this tree writes 2,410,475,894 bytes in 13.5 s
at 22 MB of peak RSS. The file has 8,399 row groups and 1,820 of its 16,798
column chunks start past 2^31, so the offsets in the footer are genuinely wide.
pyarrow, DuckDB and moonlake read the same 34,400,000 rows and the same sum
back, which is the only way to tell "wrote a wide offset" from "wrote a wide
offset that happens to be the low 32 bits".

What did not change is the part worth checking: files under 2 GiB are byte
identical to 0.5.0's on three inputs (242 bytes for a three-row CSV, 75 MB
writing the SF0.1 CSV, 85 MB rewriting the SF0.1 Parquet), and no public
signature moved. The one 32-bit length left is a page's body, which is one
batch, so the honest statement of the new limit is "a page must fit, a file
need not" rather than "no limit".

`harness/check_large_write.py` repeats the whole thing (generate, write, read
the footer with pyarrow, cross-read with DuckDB, read back with moonlake) in a
few minutes and 5 GB of scratch disk, so the claim in CHANGELOG and
verification §24 has a command behind it.

2026-10-24 (executor) — **The rows are the cost; the spill files are not.**

The roadmap had one direction parked on an open question: a streaming executor
waits until a spilling query is shown to be slow *because* it materializes
rather than because it spills. Answering it needed a profile, not an
implementation, so the question went to SF1: 6M `lineitem` rows, the native
release CLI, peak RSS read per process from `/proc` (the `getrusage` figure over
children is a running max, which quietly turns every case into its predecessor's
size).

The spill itself is free. The same `ORDER BY` at a 16 MB budget, with its runs
on tmpfs and on disk, finishes 0.03 s apart and moves 3.8 MB each way. Even a
46-run sort that pushes 1.67 GB through files is not paying for the device. What
it pays for is the rows: the narrow sort nearly doubles from 1.59 s to 2.95 s
while spilling 3.8 MB, which is a second pass over the rows, and the wide sort
goes from 4.8 s to 50.6 s.

The uncomfortable part is where the memory sits. A plain `SELECT *` over those
6M rows, no blocking operator anywhere, peaks at 3.1 GB — the scan materializes
every projected value before the parent operator runs, about six times the
decoded bytes, on CSV and on Parquet with the same number. `LIMIT 1000` does not
reduce it, because the scan has already finished. So the 3.2 GB floor under a
spilling sort was there before the sort spilled anything, and `--memory` bounds
the run buffer rather than the rows: a 64 MB budget peaks *higher* (5.1 GB) than
an 8G one.

That reorders the work. The first win is backpressure between operators — a
`LIMIT` that reaches the scan is the visible proof — and only then the merge
pass that spilling costs on top. Both rows in `docs/ROADMAP.md` carry the
numbers, and `docs/verification.md` §25 has the tables and the method. Nothing
here is committed as a script: it is a debug probe over the CLI, not a gate, and
the wall clocks are one machine on one day, so the claim being made is "rows,
not bytes" rather than "N seconds".

2026-10-24 (writer) — **A dictionary is worth a third of the file, and still not
the first thing to do.**

The writing row of the roadmap has said "prove it pays" since the 0.5.0 scope
was cut. It is now measured: SF1 `lineitem`, 6M rows, one table, five ways to
write it with pyarrow and one with our own writer, read back with DuckDB.

Plain+snappy is 288 MB. A dictionary on every column is 207 MB, and on the
twelve columns that actually benefit it is 196 MB — 32% smaller, written in the
same 1.6 s and read back in the same 20 ms, because a dictionary is a page
encoding and costs the reader nothing extra to *skip*. The columns that lose are
the ones with no repetition to find: `l_orderkey` and `l_extendedprice` grow,
which is exactly the argument for choosing per column rather than per file.
zstd would take 183 MB, but that is the codec list, not the encoder.

What changed the plan is the baseline. Our writer emits 333 MB for the same
rows: 16% more than pyarrow's plain+snappy, with comparable raw bytes (ours are
*smaller* for the integers, since we write `int32` where pyarrow infers `int64`)
and the same page granularity. So the gap is not the encoding at all — it is how
well Snappy does on the bytes we hand it, i.e. page layout. Adding a dictionary
on top of a page layout that already leaves 16% on the table would bank the
smaller half of the win and make the comparison afterwards harder to read.

So the order is: charge the 16% to something specific (page size, where pages
end, statistics overhead), then choose encodings per column. The numbers are in
the roadmap's writing row and the candidate row now starts from them. No code
changed for this.

2026-10-24 (snappy) — **The 16% was one missing tag.**

The encoding measurement left an odd baseline: our `--snappy` output was 333 MB
where pyarrow's plain+snappy of the same rows was 288, with comparable raw bytes
and the same page granularity. The plan for that number was "page layout", and
the per-column table killed it: `l_shipinstruct` (mostly incompressible text)
was within 6% of pyarrow, while `l_quantity` and `l_comment` — the columns made
of short repeats — were 46% and 21% worse. That is not a page boundary problem;
it is what a compressor does with short matches.

It was writing every match as a three-byte `copy2`. Snappy's two-byte `copy1`
covers a length of 4 to 11 at an offset under 2048, which is precisely the
"ABCD" then a few varying bytes, "ABCD" again shape that text pages are made of,
and the decoder here had always accepted it. Emitting it when it fits: 333.0 MB
→ 289.2 MB, half a percent off pyarrow, with the decoded bytes unchanged because
only the tag choice moved.

The test does not check a size, it walks the tags: a pattern with a four-byte
token every eight bytes must come out as at least 90 `copy1` and no wider copy,
so the day someone reverts the encoder the suite says so instead of every
compressed file growing by 13% unnoticed. What is left of the writing row is the
per-column dictionary — still worth −32% on this table, and still waiting for a
second table to tune the choice against.

## A LIMIT that stops reading (2026-10-24): the first operator on a batch
## contract

The executor was eager by construction: the scan drained its source into an
array, each operator ran over that array, and the window at the end cut rows
that had already been decoded and projected. So `select * from t limit 10` over
2,000,000 rows cost 483 ms and 252 MB of peak RSS to return ten rows, while
`count(*)` over the same scan was 205 ms and 21 MB. The ten rows were not paying
for counting; they were paying for materializing every column.

The window now pulls batches and stops when it is full. That is only safe if a
stage knows what it may assume, so the rules are written down next to the code
that follows them: whole batches until `None`, never an empty batch, any batch
size, source order only, error by raising, the caller owns what it was handed,
and an unfinished stream must be droppable. There is no cancel message and no
`Stop` value — a consumer that has what it asked for simply stops calling
`next`, which also means a stage cannot claim to have stopped for a reason it
did not have.

What may travel toward the source did not change with this: the binder already
decides which predicates apply to a table before the first join, and an outer
join makes the rest unsafe to push. The window applies the build filter and the
deferred `WHERE` per batch and projects per batch, which is what the eager path
did to the whole array, so the answers are the same rows — checked against
DuckDB for all eleven shapes in `harness/bench_early_stop.py`, with the pull
counts pinned by a counting source in `engine/pull_wbtest.mbt`.

The numbers that matter: 2,000,000 rows pulled → 4,096, 483 ms → 13.9 ms,
252 MB → 13 MB on CSV, and 278 ms / 250 MB → 4.9 ms / 14 MB on Parquet. The
aggregate, the sort, the distinct, the join and the derived table are untouched,
because each of them genuinely needs every row first — the honest count in the
whitebox test is the one that did not move. Everything public kept its
signature, and the eager path is still the implementation for the rest, so the
next operator can move over without a rewrite.

## An ordinary session (2026-10-25): eleven things a reader hits before the
## core

Every check in this repository drives the engine from the inside: the suite
binds expressions, the harness compares result sets, and the differential runs
SQL both sides already agree how to write. That is the right way to test a
columnar core and the wrong way to find out what a person meets in the first ten
minutes. So this pass was the other one — install the CLI, follow the README and
`docs/DEMO.md`, use each documented feature the way it is described, and write
down whatever looks wrong. Eleven defects came out. None of them was in the
vectorised operators or the codecs; every one was an argument-handling edge, a
message, or an expression-layer corner, which is where a user *is* during that
first ten minutes and where an internal suite has no reason to look.

The one that mattered: `ORDER BY` on a qualified column sorted by an output
alias. `SELECT k AS z, flag AS k FROM a ORDER BY a.k DESC` bound `a.k` to the
output column named `k` — the `flag` alias — because the ORDER BY binder looked
the name up among the select labels before it looked at the input schema. A user
does not report that as one bug. They report three: "ORDER BY desc ignored",
"NULLS LAST has no effect", and "LIMIT over a LEFT JOIN returns the wrong rows",
because those were the three queries they were writing when the sort key was
silently the wrong one. It is one defect with three faces, and the fix is one
rule: a qualified reference is an input-column reference, never an alias. A bare
name still resolves to the last same-named output column, which is what DuckDB
does and what `select k as a, k as b ... order by b` depends on.

`round` truncated toward zero for negative halves because it was MoonBit's
`Double::round`, which rounds half toward +infinity. The interesting part is not
the fix, it is that the fix is a *choice*: `cast(2.5 AS int)` is 3 in PostgreSQL
and DuckDB and 2 in C, SQLite and MySQL. This engine reads like DuckDB in its
division (`/` always double, `x/0` infinity) and its CSV inference, so it is
DuckDB here too, and the README says so next to `round` — a C-minded reader
would otherwise assume the other convention and never see it in a test. The
same cast now refuses a value that does not fit instead of saturating, because
`cast(1e20 AS int)` quietly returning INT32_MAX is a wrong number.

Two refusals turned into answers, and one of them is worth describing. The
decorrelator pairs `inner.col = outer.col` equalities and says nothing about
what it could not pair, so a non-equality correlation surfaced as `unknown table
or alias "j1" in FROM` — a message that sends the reader to look for a missing
table. It now names the supported shape and what to write instead. That message
is only honest if the list is complete, and checking it found that a correlated
`EXISTS` with a `GROUP BY` was refused for no reason at all: existence does not
depend on the grouping, so the grouping is dropped, and a `HAVING` is kept when
it runs over the correlation keys (which is the grouping the decorrelator builds
anyway) and refused with that reason when it does not. Checked against DuckDB on
a fixture where the keys repeat: `[2,2,3,3,3]`, `[3,3,3]`, `[1,2,2,4]` — equal
results. So the better message also bought two shapes their answers.

The rest are small and were all reported to us rather than found here: `concat`
was binary-only in a world where it is variadic (and `||` is the two-argument
one that propagates NULL, which is why they now lower to different names);
`TRUE` in a pandas export became a string column and `WHERE flag` failed;
`NULL IS NULL` and `length(NULL)` raised the v1 "untyped NULL is only supported
as a comparison or arithmetic operand" refusal; `moonlake exec "SELECT 1 + 1"`
printed the usage text because it insisted on an input file; `write --out t.csv`
happily replaced the CSV it had just read; a write failure was labelled
`sql error (scan):`; and a Parquet write killed with `kill -9` leaves a
`<out>.moonlake-tmp-<pid>-<n>` file behind. That last one stays: sweeping the
directory needs a `readdir` FFI the native stub does not have, the leftover is a
partial temp file rather than a half-written output (publication is a `rename`),
and its name does not match a `*.csv`/`*.parquet` glob, so a scan cannot pick it
up. Documented in the README's write paragraph instead of half-fixed.

Verification for all of it is in `docs/verification.md` §26: the 99-query DuckDB
differential that produced these findings now agrees on 83–84 cases, and each of
the sixteen that disagree has a named cause (unordered comparisons, DATE rendered
as a string in JSON, a deliberate `x % 0`, and the two correlations refused on
purpose). The CLI edges moved into `harness/check_cli.sh` and the `tpch` CI job,
because they live in argument handling rather than in the engine: exec with no
input, an unknown command's exit code, and `write` refusing its own input.

## General decorrelation (2026-10-25): a refusal that had to become an answer

The last pass ended with a message: this correlated subquery cannot be
decorrelated, only `inner.col = outer.col` equalities are paired, rewrite a
non-equality correlation as a join. A user read that and asked for the general
case instead. Fair — `WHERE EXISTS (SELECT 1 FROM u WHERE u.v < t.a)` is plain
SQL, and every other engine answers it.

### Approach

The decorrelator was already one AST rewrite before binding, so the work was not
in changing the architecture but in admitting three more shapes into it. The
equality flavor stayed exactly as it was. A subquery with no equality pair but a
predicate touching both sides became a semi/anti join with no hash key: the join
already supported an empty key (all inner rows under one bucket, each candidate
tested against the residual), so the planner only had to stop refusing the shape
and keep the non-`Eq` conjunct as the residual. That covers `>`, `<`, `<>`,
`BETWEEN`, an `OR` over both sides and a comparison against an expression.

The second shape needed new machinery. A scalar aggregate over a non-equality
correlation cannot be keyed, because the aggregate depends on the outer row's
numbers; there is no per-key table to precompute. So it is computed once,
eagerly, over the distinct combinations of the outer expressions the subquery
reads, grouped by a canonical row key and left-joined back on it. The
deduplication is the whole trick — a repeated outer row would otherwise multiply
the inner matches and a `count(*)` would double — and the join inside is a theta
join, which is slower than a hash join by construction. That cost is stated in
the roadmap rather than hidden.

The key itself is a string, because `CmpOp` has no NULL-safe equality and adding
one would reach into elision, pushdown and every hash table. Reusing the
canonical type-tagged encoding that hash joins and DISTINCT already use keeps the
two definitions from drifting.

Once that table exists, `EXISTS` and `IN` stop being WHERE-only: counting rows
answers `EXISTS` anywhere an expression may appear, and a CASE over match count,
row count and NULL count reproduces `IN`'s three-valued result, empty set
included. One expression rewriter walks everything the semi-join pass leaves
behind, which is also why a correlation under `NOT` / `OR` / `CASE` started
working — that gap was never about the rewrite, it was about only ever visiting
top-level WHERE conjuncts.

### What changed in the failure modes

Two refusals turned into answers and one into a different, smaller refusal. The
nested-correlation case, the derived-table-in-FROM case and the
`DISTINCT`/`LIMIT` cases are still refused, and the message now names them
instead of claiming the equality restriction that no longer holds. Three
*positions* turned out to be outside the rewriter — `HAVING`, a `JOIN ON` and
the select list of a `GROUP BY` query — and each used to fail with `unknown
table or alias "o" in FROM`, which sends the reader looking for a missing table.
They name themselves now, next to the same advice. A correlated
subquery in the select list of a `GROUP BY` query used to fail with `column
"__scalar0.__sk1" must appear in GROUP BY or inside an aggregate` — a message
written in the decorrelator's own vocabulary — and now says that its value would
have to appear in the `GROUP BY`, which is true and actionable. That one is a
pre-existing limit of the equality flavor too; it just was not visible before
because the general shape failed earlier with something else.

### Evidence

A 39-query DuckDB differential over NULL-rich fixtures agrees on all 39
(`docs/verification.md` §28), including the two shapes the previous pass
recorded as deliberately refused. Four new `engine/e2e_test.mbt` tests pin the
theta join, the nested `NOT`/`OR`/`CASE` shapes, the theta aggregate (with the
repeated-outer-row case that is the whole point of the dedup), three-valued
`IN`, and the positions that name themselves. The gates were re-run whole:
280/280 wasm-gc, 293/293 native, 33/33 TPC-H goldens plus spill equivalence,
writer interop, CLI checks on both binaries.

## 0.5.1 scope (2026-10-25): pending changes and the remaining execution work

The release target is 0.5.1 for both the implemented changes since 0.5.0 and
the remaining work in `docs/ROADMAP.md`. The separate Unreleased changelog
entries have been merged into 0.5.1 and its premature release date removed.
The README identifies 0.5.0 as the published package and 0.5.1 as development
work. Existing local handoff files now point to that single public plan.

The LIMIT milestone is already implemented. The remaining sequence preserves
the latest SQL fixes in a reproducible differential gate, adds batch result
consumption without breaking the collector API, then feeds aggregation,
external sort and joins in batches. A second dataset tests dictionary benefits;
implementing dictionaries still needs that evidence. Final acceptance follows
those tasks within 0.5.1, including a complete performance record and independent
consumers. Planned behavior stays out of the changelog until implemented and
verified. Verification section 29 records this assessment's checks and limits.

## The gate that had to exist (2026-10-25): three wrong answers in the differential

S0's premise is uncomfortable: the previous entry's evidence — 39 queries, all
agreeing with DuckDB — was produced by a script that was never committed, so it
was true the day it ran and unfalsifiable every day after. The same thing had
already happened to the 29-query window battery, which "passed 29/29" until
nobody could re-run it. So this task was not "add tests"; it was "make the
claim re-runnable, then find out what breaks".

### Approach

Commit the shapes, not the data. Five fixtures (`harness/data/correlation/`)
carry what a correlated subquery can trip on: a duplicated outer row, NULL keys
and values, `nan`/`inf`/`-inf`, a date column, an empty header-only table, a
one-column table. The runner holds 45 value cases and 11 documented refusals;
unordered answers compare as row multisets with values normalized across the two
engines' spellings (dates, non-finite doubles, booleans). Every failure mode is a
failure: wrong answer, engine error on a value case, refusal without its
message, a valid-SQL refusal the referee rejects, missing or empty fixture,
referee error, zero value cases. Refusals are counted apart from matches so a
run of pure refusals cannot pass.

The gate shares its plumbing with the window gate (`harness/differential.py`),
which `check_windows.py` now imports. Two gates that disagree about what "equal"
means are two gates that can each be wrong.

### What it found

Three defects, none reachable from the 39-query battery, and only one of them
needed random data:

1. `x IN (set containing NULL)` answered `false` instead of NULL. The
   three-valued rule had been attached to `NOT IN` alone.
2. A correlated `NOT IN` whose set may hold a NULL produced an internal refusal,
   because the poison detection returned the same "unsupported" as a genuinely
   unanswerable shape; the first repair then answered *empty* (five rows of the
   fixture lost) because the conjunct loop's early exit dropped the filter the
   repair had added. Now: exact answer where the set cannot be narrowed per row,
   named refusal where it can.
3. A correlated `NOT IN` over an empty set dropped a NULL probe. The committed
   fixture passed by luck; the seeded nightly (307 rows against DuckDB's 323)
   did not. `join_semi` now asks its residual whether anything is a member of
   that row's set.

The pattern is worth naming: two of the three are "UNKNOWN where SQL says TRUE,
or TRUE where SQL says UNKNOWN" — exactly the class a hand-written case list
misses and a differential catches for free.

### Evidence

`docs/verification.md` §30. The gate is green on the committed fixtures (45
value cases, 11 refusals), on the 400-row seeded nightly fixture and on seeds
1/2/3 at 120 rows; the window gate stays green after the shared-plumbing
extraction, and its 14 self-tests plus 15 new ones (66 Python harness tests in
total) pin the failure paths. MoonBit: 296/296 native, 283/283 wasm-gc and js,
`moon check --deny-warn` and `moon fmt --check` clean, no `.mbti` change, 33/33
goldens, spill acceptance green. `engine/e2e_test.mbt` gained three tests for the
behaviour the gate now guards.

One rough edge is recorded rather than papered over: a reference to a table two
levels out is still refused by the binder (`unknown table or alias "o" in FROM`),
not by a named message, and both the README and the gate now say so instead of
claiming otherwise. Naming it belongs to E4c, which owns the join contract this
path needs anyway.

## After colenc 0.1.1 (planning snapshot, 2026-10-25)

colenc 0.1.1 is published with Roaring and the dedicated HLL/t-digest package.
The source inspection found moonlake still importing 0.1.0, while colenc's old
NEXT-STEPS still scheduled the now-implemented sketches. The follow-up plan in
[the roadmap](ROADMAP.md#follow-up-after-colenc-011) starts from the released
APIs and separates the kernel's state/byte contracts from SQL and scan behavior.

The first work is C0, consuming the registry dependency without a sibling
workspace override, followed by R2, refreshing the final 0.5.1 candidate.
The full local acceptance belongs to `3ab2634`; `ae6a28c` adds the reader fix
recorded in verification §37. Live remote main is still `750b98c`, and its latest
nightly is red on that locally fixed corpus case. Neither earlier acceptance
nor colenc's green CI establishes that the final engine revision passes.

The feature queue starts with a SQL/state-cost contract, then explicit HLL
and t-digest aggregates. Dense HLL's default register payload is about 64 KiB
per group in memory, rather than its 16 KiB serialized payload; signed zero,
NaN and typed hashing need an engine adapter. t-digest needs a numeric-conversion
policy and an update-error path through the aggregate fold. Exact distinct and
median remain available. Budgeted GROUP BY input streaming is a separate task;
Roaring starts with an immutable-table experiment because row identity,
invalidation and a scan-selection contract are still engine work.

This pass inspected current source and existing evidence and queried live
release, branch and CI metadata. It changed planning/status documents only;
no dependency, SQL function or index implementation was changed. Historical
suite, registry-consumer and performance results were not rerun. The final
roadmap checklist reminds the maintainer to update both projects' benchmarks
after the last code and dependency changes.

## Results that leave one batch at a time (2026-10-26): E3

### Goal

The 0.5.1 plan's E3: an additive consumption API and a CLI that prints through
it. The repository already had one early stop (§27, a single-table `LIMIT`), but
it lived inside the executor: the result still left as one materialized batch,
`select * from t` over a table bigger than memory printed only after holding
every row, and `--json` built the whole document as a string. E3 moves the same
pull to the result boundary and lets the CLI consume it.

### What landed

`engine/stream.mbt` grew a `ScanPull` (source cursor, per-batch build filter,
deferred `WHERE`, projection, `OFFSET`/`LIMIT` window) and `ResultStream`, and
`moonlake.mbt` exposes `stream` / `stream_with`. The important structural
decision is that `run_parsed` splits into `prepare_select` (bind, then either a
set-operation result or a `Launch`) and two consumers: `drain_scan` for the
collected result and `scan_pull` for the streamed one. The old eager body moved
into `run_pipeline` untouched. So `execute` and `stream` cannot disagree — they
are the same scan read twice, not two implementations — and the eager path stays
where it was for every shape that must see all rows.

The CLI's print path switched from `SelectResult` to `ResultStream`, which is
where the JSON shape had to be decided. One array, one line per batch: the first
line carries `[`, the last carries `]`, and a single-batch result is
byte-identical to the whole-array encoding. A batch line is printed only once a
following batch exists, which is what keeps a trailing comma off the last line;
the first attempt emitted `{...},` on every line and closed with `[...]`, and
`json.loads` rejected it with `Extra data`. Text output needed no shape change —
header, one row per line — and that the two are byte-identical to 0.5.0 for the
same 2,000,000-row result is now pinned by hand and by `harness/check_cli.sh`.

### Lifecycle, before writing it down

The batch contract at the top of `engine/stream.mbt` already said early stop
needs no protocol: a consumer stops calling `next` and the unfinished stream is
safe to drop. At the result boundary that sentence needs two more clauses,
because a caller can hold a stream across failures. A pull that raises *ends* the
stream — `errdefer` sets the finished flag — so a retry reports the end instead
of resuming a scan whose state is unknown. And `catalog.BatchStream` gained no
method: it is an open public trait, exhaustion is its whole protocol, and a
`close` would have broken every implementation outside this repository. The
stream itself owns nothing but the cursor, which is why the CLI's spill purge can
never take a file it still needs: a shape that needs a budget is materialized
inside `stream_with`, before a stream exists.

### The number that made it worth doing

Same 2,000,000-row, 16-column fixture, same release build mode, one process per
measurement, peak RSS from `os.wait4` (the floor is ~22 MB):

| output | case | before | after |
|---|---|---|---|
| text | `select * from t` | 1,265 ms / 347.8 MB | 1,102 ms / 35.2 MB |
| `--json` | `select * from t` | 2,419 ms / 1,090.6 MB | 1,878 ms / 35.2 MB |

The after column does not move with the result size, which is the claim. `--json`
is also faster because it no longer concatenates a document. The pooled
benchmark's `scan/full` case moved 31.4 → 21.3 MB (the 8 MB the projected column
occupied) and, correctly, nothing else in that table moved: aggregation, `ORDER
BY` and derived tables still retain their input, and E4a/E4b/E4c are what remove
that.

### What the tests and the gate pin

`engine/pull_wbtest.mbt` now covers both deliveries through its counting source:
one pulled batch stops the scan at one read, `LIMIT 250` reads exactly three
batches and returns 100 + 100 + 50, `LIMIT 5 OFFSET 495` drops four whole
batches, an empty pulled result ends at once while a materialized empty answer is
one empty batch, seven shapes return identical scalars pulled and collected, and
a source that fails on its second batch ends the stream for good. Two CLI cases
came out of writing the last one. First, a bind error must arrive at `stream()`
with zero rows read, so a `LIMIT` that never reads its tail cannot hide a type
error. Second — found by the gate, not by design — a failure after output began
ended in `PanicError` and exit 134, because `main` is `raise` and a raise from
inside the print loop escaped the command's own `catch`. Both subcommands are
wrapped now, so any stage's failure exits 1 with its message on stderr.

### Evidence

`docs/verification.md` §31, `harness/baseline/2026-10-26-results-streamed.json`
(the pooled record), `README.mbt.md`'s API tour and `docs/DEMO.md`'s `--json`
note. Gates: 303/303 native, 290/290 wasm-gc, 290/290 js, `moon check
--deny-warn` and `moon fmt --check` clean, `.mbti` additions only, 33/33 goldens,
spill acceptance, correlation differential and 66 Python harness tests unchanged
and green.

## Aggregation folds the scan as it arrives (2026-10-26): E4a

### Goal

The 0.5.1 plan's E4a: an aggregate should update its state as input arrives
instead of being handed the input. E3 removed the result array; this removes the
input array behind the same operator, and it is the first E4 step because it is
the one where the fold already existed.

### What landed

Not a new aggregation algorithm. `aggregate_seq` in `engine/exec_agg.mbt` has
pulled from a `BatchSeq` and folded batch by batch since the grace path needed
to aggregate one spill partition at a time; every caller just handed it a
collected array. So E4a is a producer for that sequence: `AggPull` in
`engine/stream.mbt` (renamed `InputPull` in E4b, when the sort started reading
the same cursor) wraps the scan's `BatchStream` with the table's build filter
and the deferred `WHERE`, counts the rows the build filter kept (so `--analyze`
reports what the collected path reports), and never hands on a batch the filters
emptied. `run_agg_pull` runs `aggregate_seq` over it and then the same HAVING,
projection and `OFFSET`/`LIMIT` window the eager tail applies to an aggregate's
one output batch. The dispatch is one `match streaming_agg_source(...)` at the
top of `run_pipeline`; every other shape keeps the path it had.

`streaming_agg_source` is where the honesty lives. It allows one lazy table with
`aggregate` set and no `ORDER BY`, `SELECT DISTINCT` or window function. It
excludes a budgeted `GROUP BY`, because the grace path sizes its partitions from
the input it was handed (`partition_count(batches_bytes(joined), ...)`), so that
run still needs the input collected — the operator that spills cannot yet decide
how much to spill while the input is still arriving. A global aggregate is
included under a budget, since it can never spill.

### The number

Same 16-column, 2,000,000-row fixture, release build, one process per
measurement, peak RSS from `os.wait4` (raw, floor ~22 MB):

| case | before | after |
|---|---|---|
| `select cat, count(*) from t group by cat` | 337.7 ms / 109.7 MB | 323.1 ms / 35.3 MB |
| `select cat, avg(f64), sum(i64) from t group by cat` | 437.7 ms / 149.9 MB | 414.3 ms / 35.2 MB |
| `select count(distinct cat), sum(f64) from t` | 598.5 ms / 129.6 MB | 549.6 ms / 35.2 MB |

`select count(*) from t` was already at 35 MB and stays there: it reads no
columns, so there was nothing to retain. The grouped cases now sit on the
plateau E3 measured for streamed results, and the table size stops mattering.

### What the tests pin

`engine/agg_pull_wbtest.mbt` is a lazy counting source over four batches of
three rows whose keys repeat across batches, with NULLs in both keys and in the
value column: the pull hands over the batches one at a time and skips the ones a
`WHERE` empties; a `GROUP BY` a string key and one by an int32 key both put the
NULL key in its own group and leave NULL values out of the sum; HAVING filters
the finished groups; `COUNT(DISTINCT ...)` counts a value once across batches;
an empty input answers one row globally and none grouped; a source that raises
mid-input fails the aggregate instead of answering a partial row; a global
aggregate answers under a budget without a store. The one parity test runs the
same `GROUP BY` with and without a budget — pulled and collected — and requires
the same rows and the same counters, because "the same fold" is the whole claim.

### Evidence

`docs/verification.md` §32. Gates: 315/315 native, 302/302 wasm-gc, 302/302 js,
`moon check --deny-warn` and `moon fmt --check` clean, `.mbti` unchanged,
33/33 goldens (q6's single-table aggregate now folds through the pull), spill
acceptance, CLI checks, the correlation differential and 66 Python harness tests
unchanged and green.

## ORDER BY sorts and merges as the rows arrive (2026-10-26): E4b

### Goal

The 0.5.1 plan's E4b: the external sort should build its runs from the scan and
feed its consumer incrementally. §31 gave the scan a pull interface and E4a let
an aggregate fold it; a budgeted `ORDER BY` was the remaining blocking operator
whose input still had to be an array, so "streamed with `--memory`" meant the
engine built the input array and the sorted answer before the caller saw a row.

### What landed

Three refactorings and one new shape.

`build_runs` takes a batch source instead of an array and fills runs as the
batches come, so `external_sort_project(next, pre_types, …)` no longer needs
anything collected. `MergeCursor` splits the final k-way merge out of
`final_merge`: `merge_open` reads the merge inputs, `next` returns up to 4,096
projected/deduped/windowed rows and stops as soon as the OFFSET/LIMIT window is
full, and `final_merge` is now the drain — so the collected answer and a
streamed one cannot disagree, because they are one cursor with one of them
concatenating. `reduce_runs` (was `reduce_and_merge`) hands the files it writes
back to the caller's `owned` list instead of deleting them, because ownership
had to move up when the merge stopped being self-contained.

`streaming_sort_source` is the shape: one lazy table, `ORDER BY`, no aggregate,
no window, `budget > 0` (`DISTINCT` and the OFFSET/LIMIT window are fine — the
cursor applies both). `run_pipeline` dispatches it before it would materialize
`joined`, `run_select_stream_opts` dispatches it before the materialized
fallback, and `ResultStream::sorted` wraps the merge in the first pull that owns
files: `StreamPull::Sorted(SortedPull { cursor, store, owned })` removes its runs
on exhaustion, on `close` and on a raising `next`. `AggPull` became `InputPull`,
since the sort reads a table exactly the way the fold does.

This is where §31's "a stream owns no spill files" stopped being true, so it is
amended in words rather than quietly: a sorted stream owns its runs and releases
them on all three endings; a caller that drops one unfinished leaves them to the
store's owner, which for the CLI is the per-query directory it deletes at exit.

### The number

The same 16-column, 2,000,000-row fixture, `--memory 8M`, release builds, one
process per measurement, peak RSS from `os.wait4` (raw, floor ~22 MB):

| query | before | after |
|---|---|---|
| `select * from t order by id` | 506.8 MB | 178.8 MB |
| `select * from t order by id limit 10` | 335.0 MB | 168.7 MB |
| `select id from t order by id limit 10` | 43.8 MB | 39.3 MB |

The no-LIMIT row is the point: the sorted answer used to exist as an array
before the stream returned it, so the peak was input plus answer; now it is the
merge state. What remains of the 16-column peak is `FANIN` decoded runs, not the
input — the accumulator flushes at an *estimated* (serialized) `budget/4`, while
a decoded run costs several times that. Recorded as a known limit rather than
fixed, because changing the estimate would move every recorded spill number.

### What the tests pin

`engine/sort_pull_wbtest.mbt` (11 tests) reuses the E4a fixture and adds a
10,000-row tie fixture and an inspectable store: every sort shape returns the
collected answer's rows at four budgets from 64 B to 1 MB; a 10,000-row stream
comes back as three 4,096-row-capped batches in order across the boundaries;
the run files exist mid-merge and are gone at the end, after an early `close`,
and after a store failure, with `next` answering `None` in each case; the
collected sort equals the unbudgeted answer and reports the same counters as the
streamed one; an input inside the accumulator writes nothing and reports no
`spill runs`; an empty table answers one empty typed batch; a budgeted
`ORDER BY … LIMIT 10` still pulls every batch (a sort cannot know its top 10
early) and still decodes one column; and a `LIMIT 3` cursor over two runs keeps
`taken == 3` instead of draining them.

### Evidence

`docs/verification.md` §33. Gates: 326/326 native, 313/313 wasm-gc, 313/313 js,
`moon check --deny-warn` and `moon fmt --check` clean, `.mbti` unchanged,
33/33 goldens (the unbudgeted `ORDER BY` goldens now run through the extracted
`build_runs`/`MergeCursor` too), the external-sort equivalence checks in
`harness/check_all.sh`, spill acceptance, CLI checks, the correlation
differential and 66 Python harness tests green.

## A join probes a batch at a time (2026-10-26): E4c

### Goal

E4c is the "Join input and output use the batch contract" task in
`docs/ROADMAP.md`. The point is not to make joins cheap — a hash join has to
keep one side resident — but to stop paying for the other two copies: the probe
side collected, and the joined row set concatenated into one batch before the
caller sees a row.

### What landed

`JoinCursor` in `engine/exec_join.mbt` is now one hash join as a cursor: a
resident build side with its id maps, a probe source it pulls from, and a
pending-pair buffer it slices into output batches of at most 4,096 rows. It
holds the int-key fast path and the canonical-string one, marks matched build
ids so a `FULL` tail can be appended once at exhaustion, and keeps unmatched
probe rows for `LEFT`/`FULL` with a `-1` right id that the gather renders as
NULL. `join_step` — the collected path — was moved onto the same cursor, which
is the reason the two deliveries cannot disagree: there is only one engine.

`streaming_join_source` in `engine/stream.mbt` is the shape predicate, and
`ResultStream::joined` / `JoinedPull` are the stream: the build side is
materialized through the same `materialize_scan` the collected path uses, the
probe side is the existing `table_input_pull` (factored out of `input_pull`),
and the deferred predicate, the projection and the OFFSET/LIMIT window are
applied per output batch — so `LIMIT` stops probing.

What stays eager is written down rather than left to be discovered: a chain of
three or more joins, `RIGHT`, `SEMI`/`ANTI` (decorrelated into a scan, so they
stream as a scan), a keyless cross join (the budget path refuses one over
budget; the stream keeps that answer), and anything above the join that needs
every row first. The grace path is not fed incrementally: this shape never
reaches it, and a chain still does.

### The number

2,000,000 rows, 16 columns on the probe side, release builds, one process per
measurement, `os.wait4` peak RSS (raw, floor ~22 MB), pre-E4c binary versus this
one:

| query | before | after |
|---|---|---|
| `select * from t join d on t.id = d.id`, 1,000-row build | 270.8 MB | 35.3 MB |
| the same under `--memory 8M` | 1986 ms / 270.2 MB | 413 ms / 35.5 MB |
| `t` joined to a 2,000,000-row build, 2,000,000-row output | 404.1 MB | 272.4 MB |

The second row is the interesting one: under a budget the join no longer spills
at all, because the stream is smaller than the budget, so the grace machinery is
never entered. The third row is the ceiling this task does not move — a large
build side is resident by design, and what is left is that side plus how it is
read.

### What the tests pin

`engine/join_pull_wbtest.mbt` (14 tests) uses a lazy fixture that records
`[opens, pulls, rows, projection width]` so each test can see what the engine
asked for: twelve shapes agree with `execute` as multisets; a duplicated probe
key fills the 4,096 cap with no empty or oversized batch; duplicate keys on both
sides cross-multiply; empty build and empty probe sides, `NULL` keys and
residual predicates behave as the collected answer does; closing after one batch
stops probing (`pulls == 1` of eight); `LIMIT` cuts probing short and carries
`OFFSET` across batches; the probe-side filter runs before the join and the
deferred one after; every eagerly executed shape returns one batch and the same
rows; each table is opened once and the build side is read whole; and the
collected path still reports the same counters.

### Evidence

`docs/verification.md` §34. Gates: 340/340 native, 327/327 wasm-gc, 327/327 js,
`moon check --deny-warn` and `moon fmt` clean, `.mbti` unchanged, 33/33 goldens,
spill acceptance, all five CLI sections, the correlation differential at 400
random cases, 66 Python harness tests, and the release check at 0.5.1 with 206
files in the archive.

## A second table prices the dictionary (2026-10-26): W0

### Goal

W0 is the roadmap's committed investigation, not an implementation: a second
dataset decides whether adaptive dictionary write encodings (W1) are worth
building into 0.5.1, and it has to be a table the writer does not already know —
the writing row was derived from `lineitem` alone.

### What landed

`harness/dict_survey.py` builds a seeded web access log — 500,000 rows,
eleven columns deliberately disagreeing with each other (monotonic clock,
20,000-valued id, two tiny enumerations, a repetitive 55-character path, a
near-unique 70-character query string, a boolean, a 40%-NULL note) — and writes
it four ways with PyArrow: plain+snappy, dictionary on everything, dictionary on
the columns that win, and both row-group layouts. It writes the same rows with
`moonlake write --snappy`, reads every file back with both engines, and refuses
to print a table if two files disagree on the answer.

Two bugs in the measurement itself, found while making it honest: our engine
names a table after the file stem, so `plain+snappy.parquet` was an unknown
table (files are now `t_plain_snappy.parquet` and the SQL follows the stem); and
comparing `sum(latency)` exactly across writers fails in the last bits because a
double sum is not associative, so floats compare with a relative tolerance and
everything else exactly.

### The number

Per-column, at our writer's 4,096-row groups: `country` −59%, `device` −78%,
`status` −68%, `path` −24%, `note` −16%; and it *loses* on `ts` +37%, `uid`
+31%, `latency` +29%, `size` +30%, `query` +14%. Whole file: plain 23.15 MB,
dictionary on everything 23.53 MB (+1.6% — worse than plain), dictionary on the
five that win 19.90 MB (−14.1%). At 65,536-row groups the same choice is
16.40 MB (−28.1%), because `path` goes −24% → −74%, `note` −16% → −67% and `uid`
+31% → −21%: a dictionary page is written once per column chunk, so few big
chunks amortize it and many small ones do not.

The layout turns out to be the larger lever, in both directions: PyArrow's big
groups save 1.4% of the file over ours while raising *our reader's* peak from
13 MB to 57 MB, because it holds one row group's decoded columns. Our own
`--snappy` output is 1.3% smaller than PyArrow's plain output at our layout and
0.1% larger at theirs — the second dataset confirming the one-tag fix that
closed the 16% gap on lineitem.

### The decision

W1 stays out of 0.5.1, and the reason is in the numbers rather than in the
schedule: the encoding is worth a sixth of the file at the layout we write
today, and twice that at a layout we do not. Implementing it first would bank
the smaller half and make the next comparison harder to read — the same ordering
argument the 2026-10-24 entry used to put the Snappy tag ahead of the dictionary.
The hold-list entry now starts from the row-group size and carries this script
as the fixture to tune against, which is a writer change with its own read-memory
cost and belongs to a release that schedules it.

### Evidence

`docs/verification.md` §35 has both layouts, the per-column table, the whole-file
table and the four conclusions. Nothing in the writer changed: the "moonlake"
rows in those tables are the current `write --snappy` output, and every other
row is PyArrow encoding a hypothetical, which is why the two are labelled apart.
The script is a measurement tool, not a gate; the JSON record stays out of the
repository because no assertion depends on the numbers.

## Accepted on one candidate (2026-10-26): R1

### Goal

The delivery plan ends with an acceptance task, not a feature: one tree where
every gate in `ROADMAP.md`'s release list passes, the evidence is recorded
against that SHA, and the shapes that still accumulate are stated as limits.
The risk R1 exists to cover is the one every release has — six tasks green in
their own sections and nothing ever run together.

### What landed

Two pieces of tooling, because two of the checks could not have been true
before. `harness/check_all.sh` always ran the goldens through `moon run
cmd/main`, so "the goldens pass" meant "the wasm-gc interpreter passes";
`MOONLAKE_TARGET` now selects native, wasm-gc or js and `MOONLAKE_BIN` points
the same 33 goldens at the release binary a user gets. And the packaged
consumer imported the library without ever pulling a result, which is the one
thing this release adds: it now streams a scan with a filter and a window, a
two-table join, a folded aggregate and an unordered `ORDER BY`, requires each
pulled delivery to print what `execute(...).to_json()` prints for the same
query, then stops one stream early and checks `close`. `JsonRow` is what makes
that comparison exact — it writes a batch's rows without the brackets, which is
how the CLI already prints a result as its batches arrive.

Then the pass itself, on `3ab2634`: suites at 340/327/327, 75 Python self-tests,
the goldens on three targets and through the binary, the correlation and window
differentials, the pushdown fuzzer, the Parquet corpus and encoding fixtures,
the CLI and spill-lifecycle checks, writer interop, a 2,410,475,894-byte file
round-tripping through pyarrow, DuckDB and our own reader, the archive consumer
on three targets with fresh caches, and the playground page in real Chromium —
16/16, from a host-free wasm. Playwright was already on this machine, which is
why the browser acceptance could be run locally instead of trusted to CI.

### The number

The performance pair is in `bench-baseline.md`: 0.5.1 at `3ab2634` beside the
published 0.5.0 rebuilt from tag `v0.5.0` in a worktree and recorded with that
tag's own script, minutes apart. No case changed its `sql` or its stdout hash,
and peak RSS falls wherever the answer used to be collected — the two-table join
51.0 -> 35.1 MB, the self-join fanout 53.1 -> 41.3, the wide projection 310.9 ->
237.2, the external sort 45.4 -> 35.3.

One case moved out of its spread, and it is a cost: `scan/filtered_count_csv`.
A filtered count whose answer is one row now pays the delivery boundary, because
the scan assembles a freshly allocated 4,096-row batch per pull and the filter
covers that batch whole. The record pair showed +9.2%, which is the machine as
much as the code, so the number in the doc comes from an interleaved A/B of the
two binaries: +4.1% CPU best-of (176.0 -> 183.3 ms), while the unfiltered
`count(*)` over the same file is +0.1%. Recording it as ~4% with the shape that
pays it is more useful than either averaging it away or calling it noise.

### What acceptance does not mean

It does not mean released, and it does not mean CI has seen this SHA. The
nightly job that runs the >2 GiB write exists and last went green on 2026-10-24
at the then-`main`; a green run at *this* SHA needs the push, and the hosted
playground, the registry consumer and `moon publish --dry-run` need the
authorized release work. `check_release.py --check-consumer` passes on the clean
candidate (210 archive files, version claims agree, consumer green on three
targets), which is the reachable half of that boundary.

## A footer that undercounted its own chunk (2026-10-26): R2

The nightly failed exactly one step: the Parquet corpus cross-check refused
`nation.dict-malformed.parquet`, which its record said should decode. The
tempting move was to accept the refusal: the file is named "malformed", and a
local commit had already written the refusal into the record. Reading the file
said otherwise.

Its last column declares a 2002-byte chunk; its two pages need 2017. The 15-byte
difference is exactly the dictionary page header, and the last payload ends at
byte 2608, where the 234-byte footer starts. So the file is readable (PyArrow
and DuckDB read all 25 rows) and only the footer's sum is wrong. The reader had
sized the chunk from that sum since 0.5.0's ranged reads, and the bounds check
compared a chunk-relative offset against the buffer, so it reported "past the
end of the file" about a page that was inside it. Before 0.5.0 the file decoded.

So the fix is not a looser check: the reader follows the page headers, asking
for the rest of a page when it overruns the declared extent and refusing only
when it really passes the end of the file. The refusal now names the file offset
and the column. Three whitebox tests hold the shape, the corpus gate is back to
17 decoded / 51 refused / 0 failing, and `select *` on the fixture matches
DuckDB cell for cell.

The lesson is about the gate, not the file: a `refused` class is only honest for
a file a reference reader also refuses. Two of three readers disagreeing with us
is a bug report about our reader. That is what §37 of `verification.md` records.

## colenc 0.1.1 is consumed (2026-10-26): C0

The bump was one line of manifest and two sentences of instructions, which is
the interesting part: 0.1.1 adds `Encoding::Roaring`, the `sketches` package and
three `EncodingError` variants, and none of that reached an edit here. The
engine translates colenc errors through `EncodingError::message` in one reader
helper and one writer helper, and it never matches on `Encoding` variants, so
the additions are compatible by construction rather than by luck. `moon info`
produced no `.mbti` diff, which is the same statement from the other side.

What did need attention was the environment, not the code. The registry index
still carried only colenc 0.1.0, so `moon update` had to refresh it first, and
the cached `.mooncakes/superbigcup325/colenc` copy had to go: a populated cache
is exactly what hides a version bump from a build that would otherwise fail.
With both cleared the graph resolved 0.1.1 and the first check downloaded it.

Evidence is in §38 of `verification.md`, all of it on the commit that carries
the bump: three-target suites at 330/343/330, the 33 goldens on wasm-gc, js and
through the release binary, page fixtures, writer interop, spill acceptance,
the CLI checks, the corpus at 17 decoded / 51 refused / 0 failing, and the
archive consumer green on three targets with fresh caches. The consumer gate
has to run after the bump is committed because it refuses a dirty tree, which
is worth knowing before starting one.

None of this uses the new surface. The next task is R2, the same gates again on
the final candidate, and the feature work behind it still starts from A0's
semantics and state costs.

## Two approximate aggregates, and the cost that keeps them honest (2026-10-26): A0, A1, A2

The surface is small — `approx_count_distinct(expr)` and
`approx_quantile(expr, q)` — and the implementation follows the shape the
executor already had: two new accumulator variants on the one fold in
`engine/exec_agg.mbt`, reached from the in-memory gather, the streaming pull, the
grace partitions and the window path without a second copy of anything. The
parser and binder additions are the boring half. The contract is
`docs/sketches.md`, and §39 of `verification.md` is the evidence.

Two decisions were not mechanical. First, the distinct sketch has to see what
the exact path calls one value, or the two answers disagree on the same column
for no reason a user could see: the fold canonicalizes `-0.0` to `+0.0` and
every NaN payload to one NaN, because that is what the exact key's text form
does, and hashes strings as UTF-8 bytes and dates as epoch days. Second, a
t-digest refuses non-finite values and `acc_step` cannot raise, so the fold sets
a flag and the finish step raises; the query fails whole, at the same boundary
as `sum()`'s overflow.

Then the measurements, which are the part that decides how the feature is
described. On 1,000,000 distinct strings, `count(DISTINCT s)` peaks at 144.7 MB
while `approx_count_distinct(s)` peaks at 56.6 MB — and `count(s)`, which
decodes the same column and keeps no state, is also 56.6 MB, so the sketch is
its 64 KiB and the 88 MB was the map. `median(d)` on the same file's double
column is 44.4 MB against `approx_quantile`'s 33.9 MB. Ungrouped, the sketches
win by a wide margin.

Grouped, they can lose, and that belongs in the first paragraph rather than in
a footnote: 1,000 groups holding 1,000 distinct values each cost 145.8 MB with
the sketch against 152.8 MB exact, because 1,000 dense sketches are 64 MB
whatever they hold and the exact set only pays for what it has. About 750
distinct values per group is where they cross. That is why there is no
optimizer rewrite and no default: the feature is explicit because the engine
cannot know which side of that line a query is on.

Suites are at 348 wasm-gc / 361 native / 348 js, 18 of them new. What is left
for 0.5.1 is R2, the acceptance rerun on this revision.

## Accepted again, and the 10% that came with the dependency (2026-10-26): R2

The candidate changed after §36, so the whole list ran again on `bc1a8f5`
instead of being inherited: three-target suites, the 33 goldens on three paths,
the correlation differential (fixed and seeded), windows, pushdown, page
fixtures, CLI, spill, writer interoperability, the corpus at 17 / 51 / 0, the
2.41 GB write through three readers, the host-free wasm audit, 16/16 in real
Chromium, and the archive consumer at 213 files with fresh caches. Everything
passed. §40 is the record.

The performance pair is the part worth reading. The final candidate is about 10%
slower than `3ab2634` on wide CSV scans (7–14% by run; the recorded pair overstates
it because it is taken case by case rather than interleaved), and the honest thing was to chase it
rather than call it noise. The bisect was clean because the commits are clean:
`ae6a28c` is the reader fix and measures +0.3%; `24d983b` touches only the
manifest and measures 9.4% slower against the same control in the same session.
The previous candidate's source is otherwise identical. A probe build with
`encoders/roaring.mbt` removed from a local colenc 0.1.1, facade arms refusing,
comes back to the control's speed on both the scan and the join.

So the 1,137 lines the bitmap added to `colenc/encoders` stay linked: the
generic `encode_column` / `decode_column` dispatch that the spill format calls
reaches them, and what survives dead-code elimination moves the hot CSV loop
around. A second probe made that precise — keep the file, refuse only the two
facade arms, and the binary is the same size as a deletion build and the scan is
back at the control's speed. It is a dispatch problem in the dependency, not a
regression in this tree, and the fix is to move the `Roaring` arms out of the
generic dispatch — a colenc release, then this pair re-run. A package move alone
would not have done it, which is why the probe was worth running twice. The
change itself is small and lives in colenc: `encode_column` / `decode_column`
refuse the set encoding, and `encode_roaring_column` / `decode_roaring_column`
carry its path. A build of this tree against it is 8,248 bytes smaller and at
control speed. Recorded
with the rotating A/B (10–12 pairs a side, 1.5% measured harness bias), the
bisect and both probes in `bench-baseline.md`, because the cost should be a
decision for the release owner and not a footnote.

Memory is flat across every case, expression-only start-up is unchanged, and the
Parquet cases did not move. The CSV cost is the only open question before
publishing; the rest is authorization.

## 0.5.1 is published, and the join still collects (2026-10-27): E5, R3, E6a

The last unbounded operator before the release was the one the release notes had
quietly described as bounded. A `GROUP BY` under `--memory` collected its input
and then partitioned it, so the budget decided how the rows were spilled and not
how many were held: 8,000,000 rows over 100 groups peaked at 195 MB at the 4M
budget meant to bound it and 191 MB at 16M. E5 made the aggregate read the scan instead — the same batches a
`count(*)` already consumed — buffering up to the budget and partitioning past
it. The same query now peaks at 63 MB at a 4M budget, flat once the input exceeds
it, and the cost is visible in wall time rather than memory (1.78 s against
2.00 s at 8,000,000 rows). What did not move is stated just as plainly in §45:
group state and the finished result are still unbounded, a budget is not an RSS
cap, and the aggregate `string_agg` got up to 18% slower where the new partition
rule chose more partitions than the old path did.

The partition count was the part that had to be measured rather than chosen. A
floor alone made cheap aggregates slower by splitting every batch 64 ways, and
the js target showed the other end — 2 partitions costing 1.54 s where 16 cost
1.33 s. The final rule is a 32 KiB floor with a cap of 16, measured against the
pre-change control on all three targets; it removed the 64-partition penalty and
cut `string_agg`'s worst case from 40% to 18%, at the price of more files for the
same bytes (269 where 78 were written, every count under a thousand).

0.5.1 is that candidate: the owner renumbered the planned 0.6.0 scope to a patch,
so the release commit `f8e1204` touches version strings and documentation and no
behaviour, and the tree §46 accepted is the tree that was published. The tag is
annotated, the registry returns `200 OK`, the page reports 0.5.1 and passes its
16/16 acceptance, and the consumer suite passes from a fresh cache on native,
wasm-gc and js. The archive is 225 files with no dot-prefixed path.

One error survived the release into the documentation: the README still said a
budgeted `GROUP BY` collects its input because it "would have nothing to spill",
and the `ResultStream` doc comment said a pulled aggregate only happens without a
budget. E5 had made both false, and every check that gate the release reads
versions, archives and behaviour, not prose. They are fixed in two documentation
commits, which is the honest shape of the mistake — the code was right and the
description lagged it by a release.

E6a then asked what the same question is worth one level up: a two-table keyed
join with a `GROUP BY` above it, where neither the join stream nor the aggregate
fold accepts the other, so `drain_join` collects the joined rows first. With the
build side, the group count and the result fixed, the collection dominates —
peak RSS over the scan goes from +16 MB at 1,000,000 joined rows to +154 MB at
4,000,000, while the scan stays at 35 MB, the aggregate state at 35 MB and the
streaming join at 39 MB, and a budget on that query raises the peak (204 MB at
4M) and quadruples the wall time. §48 is the record. It is a baseline taken with
the candidate and the control being the same source, so it also measured the
harness: the quiet-host flags in the new script were parsed and never read, which
is how a gate silently does nothing, and the JSON had no provenance header. Both
are fixed before the record that is cited, and the roadmap's rule — compose the
two paths only if the collection dominates — now has its answer.

Writing the composition contract E6b opens with turned out to be two decisions
and one rule. The column-mapping question answers itself: the join cursor's
output is already the layout the fold's expressions are bound to, because the
collected path hands `aggregate_within_budget` exactly that, so nothing is
projected between them and a second join stays out. The budget question needed a
gate rather than an answer, because a two-table join keeps its build side whole:
the shape is accepted only when that side fits the budget, and an oversized one
keeps the eager path, where the join can be partitioned. The rule is the one E5
already recorded, that a budget bounds the fold's input buffer and never the
group state or the grouped result, and the row counters keep their names while
the spill lines start describing a different plan.

## The join feeds the fold (2026-10-28): E6b

The contract the last entry ended on asked two questions and set one rule. The
code that answers them is three pieces: a shape predicate, a pull over the join
cursor, and a tail the two pulls now share. The predicate is
`streaming_join_source`'s with the aggregate allowed instead of refused, so the
shape it accepts is exactly the shape the join stream declines. `JoinFoldPull`
runs the cursor, applies the deferred predicate to each batch, counts the rows it
passes on and hands them to the fold. `run_agg_pull`'s tail moved into
`fold_pulled` and `finish_agg_pull`, so `HAVING`, the spill lines, the
aggregation, projection, ordering and the result are one sequence for both. The
column-mapping question the contract worried about was already answered by the
collected path: the cursor's batches are the layout the fold's expressions are
bound to. A second step changes that layout, which is why a chain stays out.

The build side is the part that cannot be folded away. A two-table join holds it
whole, so `join_agg_fits` measures the materialized side against the budget and
leaves the eager path in place when it does not fit, where the join can partition
instead. That branch is handed the batches it already read, so the table is not
scanned twice, and it is why the shape predicate never mentions a budget.

Over the harness's five points, at no budget the peak is 39 MB from 1,000,000 to
4,000,000 joined rows, and 39 MB again when the same 4,000,000 rows come from a
four-row build side instead of four million probe rows. The collected control
walks 51, 97, 191 MB on the first route and 153 MB on the second, so the route
that produced the rows mattered and now does not. Under the 4M budget the
composed query peaks at 41 to 46 MB against 53 to 226 MB, and under 16M at 49 to
67 MB against 51 to 193 MB: the peak follows the budget and the fold's buffer,
not the joined rows. The delta over the scan is the resident build side plus one
batch, 3.6 to 3.8 MB, and it does not move across the sweep. All 75 case runs
answer correctly, agree with the control and the 45 grouped ones agree with
DuckDB.

The five row counters needed no new definition and got no new values: same five
lines as the control on the same query, which a whitebox test pins. The spill
lines did change meaning. Under the 4M budget at 4,000,000 rows the collected
path spills twice, the join's grace output in 31 partitions and then the
aggregate in 46, for 115 files and 11.1 MB. The composed query never calls
`join_or_spill`, so it reports one phase of 16 partitions, 394 files and 10.6 MB,
plus the fold's own buffer estimate. More files for fewer bytes is the trade E5
recorded for the aggregate's partition rule.

The part worth writing down is a failure that stopped happening. A join whose
single key outgrows every grace partition used to fail under a budget: the join
wrote its runs, then refused. Composing removes the joined row set, so the same
query now answers, writes nothing and leaves no directory. That made two gates
wrong in the way that reads as a bug: the e2e failure test and the dirty-budget
check in `spill_accept.sh` both pinned the refusal with an INNER join, which is
now the shape that answers. Both were retargeted to RIGHT joins, which the
contract excludes and which still spill and still refuse, and the answering case
got its own test in the corpus gate. A gate that starts failing after an
improvement is pinning the old limitation, not the behaviour, and this is what
that looks like when the limitation was a shape rather than a bug.

Coverage on real queries is narrow and says so. With the predicate instrumented
at sf01, only q14 and q19 compose: q3, q10 and q12 carry an ORDER BY above the
aggregate, q5, q11 and q18 join a third table, q16 and q20 decorrelate into
SEMI/ANTI joins. q19 peaks at 41 MB against 109 MB anyway, and all 33 golden
comparisons pass unchanged. The build side and the group state are still whole,
which E6c measures, and the next widening is ORDER BY above the aggregate: the
grouped result is already one batch and the eager tail already sorts it, so the
exclusion is narrower than the contract makes it sound, but the decision about an
over-budget sort of that batch belongs to its own contract.

## The sort comes after the fold (2026-10-28): E6b, widened

The contract closed on "what composing leaves open", and the first item on that
list was the cheapest to settle: an `ORDER BY` above the composed aggregate.
The reasoning against it was that a sort needs every row before it can emit
one, which is true of the fold's input and false of its output. The grouped
result is one batch, both pull tails already applied the `OFFSET`/`LIMIT`
window to it once the last input row had been folded, and the eager aggregate
path sorts that same batch in memory under a budget without ever sending it to
runs.

So this was not a new operator. `finish_agg_pull` grew a branch that resolves
the `ORDER BY` keys the way the eager path does (an output-column key sorts by
its projection expression, an expression key by its bound form), sorts the
grouped batch, projects, and applies the window; the two shape predicates
stopped refusing an `ORDER BY`. Because the branch sits in the shared tail, it
lifted the exclusion for the single-table aggregate and the composed join at
once.

The decision the contract had left open, whether an over-budget sort of the
grouped batch spills through the run-file pool, went the other way, and §45 had
already decided it: a budget bounds input buffers, and a grouped result is not
input. A spilled sort of a grouped result would have to divide the same budget
the fold is spending and would move where the `LIMIT` stops, so the tail sorts
in memory and a grouped result stays unbounded, which is the limit the roadmap
keeps.

The numbers are the point. TPC-H q1 held its 6,000,000-row input (543 MB) and
now holds the 4-row group table and one batch (35 MB); under a 16 MB budget
both paths spill the aggregate input, and the difference is what is held while
they do (75 against 558 MB). q12 is the only ordered one-join query in the
corpus and drops from 113 to 35 MB. q3 and q10 keep a second join step, were in
the matrix as invariants, and did not move. Answers are byte-identical, the 33
goldens and the 249 unit tests pass, and the record is
`harness/baseline/2026-10-28-ordered-agg.json` (verification §50).

What is left is the shape list that has shrunk one item at a time: a second
join step (q3, q5, q7, q8, q10, q11, q18, q21), DISTINCT, a window, a chain,
RIGHT, SEMI/ANTI and a keyless cross join. The second join step is now the
widest.

### A chain of joins folds too, and the budget decides when (2026-10-28)

The second join step was the widest shape left, and the mapping it was expected
to need was already there. A step's probe layout is the previous step's output
layout, which is what `JoinCursor` hands out and what the collected path feeds
it, so the chain became one cursor per step whose `next_left` is the previous
cursor's `next`, with the fold's expressions bound to the last step's layout and
the per-step filter order copied from `exec_joins`. A linear chain of any length
over lazy base tables, INNER, LEFT or FULL on every step, now folds its joined
rows instead of collecting them.

The measurement then decided the routing, and it said less than the design did.
A chain holds one resident build side per step, so it needs one side's worth of
memory more than a single step does: at SF1 q3 held 32 MB more than collecting
the joined rows, because its chain builds on the two largest tables, and q11
held 63 MB less, because its second step builds on `nation`. Net across the
corpus that trade is positive, but it is not a promise, and the arc's promise is
that a peak follows the budget. So a chain composes only under a budget its
sides fit, and nothing else about it is conditional: the shape, the counters and
the answers are the same either way.

Under a 16 MB budget exactly one corpus chain fits, q11: 99 MB to 26 MB, and the
13 run files the eager path writes are gone. Everything else reports the same
spill file count and the same bytes as the binary from before the change, which
is how "this shape is not claimed" should look from outside. The fit check now
runs on the scans before the layout copies exist, because a chain that keeps the
eager path should not pay for copies it will never use: measured on q18 that
alone was 13 MB.

What would lift the gate is a cheaper index over a build side. The per-key id
lists that a bridge-shaped side allocates are the cost that makes a large build
side a bad trade, and shrinking them would move the no-budget numbers without
touching the fold. That is a separate change, and the roadmap's limits row now
says a chain is composed when its sides fit a budget rather than claiming the
shape outright.

### The index was the gate (2026-10-29)

The chain of joins was done and gated: it composed only under a budget its build
sides fit, because measuring the ungated version said composition cost q3 32 MB
more than collecting the joined rows. The gate was the right call for the code
that existed, and the wrong thing to leave alone, because the reason for the
cost was one data structure.

A build side's fast-path index was a map from key to an allocated list of row
ids. That is fine for a small dimension table and wasteful for a primary key over
millions of rows: every distinct key paid for an object and a right-sized data
array, and `orders` has one row per key. Grouping the ids by key into one
contiguous array with a starts table costs a slot and four bytes per row, so
indexing stops being the dominant term.

That changed the answer the gate was based on. Ungated, the chain now measures at
or below the eager path on every chain in the corpus: q3 is flat, q5 holds 69 MB
less, q10 44 MB less, q11 60 MB less. So the gate is gone: a chain composes when
there is no budget to violate, or when its sides fit the one there is. The price
is two passes over the build keys instead of one, and the wall numbers say it is
a few percent on the multi-step queries, which is what a fold that removes a
materialized intermediate should cost.

The lesson is the one this arc keeps teaching: a routing rule measured against a
slow implementation records the implementation, not the shape. The right response
to "this shape costs 32 MB more" turned out not to be a narrower predicate but a
better index, and the record now says which of the two it was.

The follow-up was the other half of that index: the semi, anti and right joins
still kept a list per key. They take the range index now, and the measurement
said it changes nothing, which retires the lever the previous entry named. The
code is simpler for it and the record says so (verification §53).

The probes after that said the peaks of q18 and q20 were group state, at 288 and
410 bytes a group, and a key and a sum need about a dozen. One integer key over
sums and counts now keeps that state as arrays by group id, and a million groups
fell from 323 MB to 117 MB. q18 fell by less than the probe line promised
because its other half is a build side, which the measurement then named: the
aggregate was never the whole peak (verification §54).

The same fold took a pair of Int32 keys next, packed into one Int64 with NULL
patterns on a side map. q20's single aggregate was most of its peak, so it fell
from 259 MB to 99 MB (verification §55). What is left in the corpus is not group
state: q18's resident `lineitem` build side and q21's semi and anti sides.

The last index change was the lookup itself: surrogate keys are dense, so a
build side that maps keys to slots through a hash map can use an array instead.
q3, q5 and q18 fell by 28 to 63 MB without a budget (verification §56). What is
left in q18 is the resident lineitem build side, which is a planning question.

The plan question was last: a chain holds whichever table was named last, and
q18 names its largest. With a contract written first, the last step now hashes
the few rows before it and streams the big table past them, and q18 fell from
325 MB to 145 MB, the peak of its own subquery (verification §57).

q21 was supposed to gain from indexing 32-bit keys without widening them. It did
not: q3 and q5 fell by 22 and 48 MB and q21 stayed at 603 MB, so the estimate in
the previous record was a transient and not the peak (verification §59). What is
left there is the inner side held twice.

## The peak found, and shipped as an instrument (2026-10-29): E7, 0.6.0

q21 was the last query the memory arc had not explained, and it stayed at 603 MB
through a wider index that should have helped it. The answer took three records.
A structure census now runs beside the executor: every place that collects a
join step's output, collapses it, or builds an index reports what it holds, and
the census keeps the largest point at each label and prints them (verification
§61). It named the collapse of the second chain step at 497.5 MB of a ~600 MB
run, with a probe input, the tables and a collected output around it.

The obvious lever followed: do not hold the copy twice. `concat_batches_releasing`
dropped each source column as it copied, so the named peak fell by 70 MB and the
process peak did not move at all (verification §62). The negative result is in
the record rather than in the code, and the next question was where the peak
actually is — which no count could answer, because a count names structures and
a process has a high-water mark.

So the census learned to read the process: every point now samples resident and
high-water KB from `/proc`, injected through the CLI so the engine still never
touches a file, and absent — not zero — on a target without `/proc` (verification
§63). On q21 the instrument agrees with the harness' peak to the megabyte and
puts it at the second step's collapse: 599.1 MB high-water where 497.5 MB is
named, and the semi/anti points hold 211 MB and 113 MB more than they name. The
peak follows what a run allocates and retains, not the size of one live pair, so
the next lever has to allocate less — not free sooner.

0.6.0 ships that arc's results: the cheaper build-side index, the chain that
composes without a budget, the column-wise group state, and the census as an
opt-in diagnostic. The two negative results ship as records only.

## The budget stops paying for partitions it does not need (2026-10-31): E8, 0.6.1

The instrument built in E7 named the peak but not the cause, and the cause turned
out to be the budget's own machinery. Two readings did the work. The first: q21
with `--memory 16M` takes 17.96 s and takes 17.96 s again when it spills to
`/dev/shm`, so nothing here is disk-bound — it is the encode and decode of every
partitioned side, and the grace path did that to both sides of every step that
did not fit. The second: `join_step` has been streaming its probe side, one batch
at a time, since the join learned to feed the fold; the partitioner was
partitioning a side the step already knew how to stream.

So the budget stopped partitioning what it did not have to. A step whose build
side fits (twice over: the index is roughly the build again) keeps it as the hash
side and lets the probe stream past — q7 at 64 MB went 6.36 s → 2.60 s. A step
whose *accumulated* side fits and whose table side does not swaps the roles
instead, reusing the `SwapCursor` the join+aggregate path already had — q8 went
4.25 s → 1.71 s at 16 MB with its peak down 39%. Both keep the same promise: the
working set is what fits plus the output, which is what the unpartitioned case
next door already allowed.

Two things were measured and refused on the way. Counting the validity array in
the budget unit (not just in the report) bought 0.5–2.8% of wall time for 10 MB
more peak on two cases, and handing a replay's batches on uncollapsed doubled a
downstream partitioner's work: §76 and §80 record both, and both took the same
route — write the contract, measure it, and let the bar the contract set decide.

The census earned its keep twice: it named the empty-partition crash that §76's
extra bytes exposed (fixed in §77), and it found that a budgeted run's peak is
the accumulated output plus the copy that collapses it (§79). What is left is
plan-time choice of the index side; q21's 6.67 s against 2.90 s with no budget is
what it is still paying for.

0.6.1 ships the arc: the split between the budget's unit and the census', the
engine that keeps a fitting side out of the partitioner, and the crash fix. The
refusals ship as records.

## W5 (2026-10-31): 0.6.1 out, the whole set measured, three refusals on the record

### Goal

Ship what the one-sided spill work earned, then measure the whole TPC-H set rather
than the twelve cases the earlier sections watched, and let the numbers choose the
next contract.

### What landed

- 0.6.1 published, tagged, released, playground 16/16 (§83) — renumbered from 0.7.0
  because no public signature moved.
- The full 22-query x 3-budget sweep against 0.6.0 (§85): 61 of 66 cases faster,
  q2 at 64 MB 13.77 -> 2.05 s, q8 at 16 MB 4.32 -> 1.76 s with its peak -42%.
- The census of the shared decode (§86): q15 holds 239 MB for a 2.3x faster answer,
  and no reader can release it earlier without losing the reuse that pays for it.
- The map of what a budget costs when nothing spills (§87, §89): the shared decode is
  off under a budget (q21 +85%), and a further 2.4 s on q2 has no explanation yet.
- The residual's fixed side evaluated once, and the router chunked (§92): q19 128.5 ->
  3.8 s unbudgeted and 3.7 s at every budget (17.8x against 0.6.1), q2 -11% and q13 -5%
  at 16 MB, q7 -24% and q9 -10% from the routing, peaks unmoved, answers identical.
  The record's own attribution of q19 to the batch size was wrong and is corrected in
  §85: one defect produced the 2x at every budget and the budget only made it visible.

- The fold that spilled 199 MB to produce four rows (§93, §94): q1 under a 16 MB
  budget now splits into seventeen segments, carries each segment's group state as
  rows (`avg` as its own sum and count) and re-folds the partials, so it reads 5.04 ->
  2.62 s with its 199,193,427 bytes of spill I/O gone and a peak 13% lower; q20's inner
  sum drops its 17.4 MB of spill for 2.31 -> 2.08 s. A dense key set keeps the
  partitioned path (the merged partials would be as large as the input), and a median or
  a standard deviation has no state that is a row.

### What was refused, and why that is the output

Three contracts were written first and measured after, and all three failed their own
bars: the early semi/anti reorder (§84, the passes cost in proportion to their input),
the coalescing partition router (§85, halving the gathers changed nothing), and the
spilled tee (§88, 20% faster on q18 and 63% slower on q11 because a cheap table pays
the tee's two extra passes). Each has its matrix in `docs/verification.md` and its
result line in the roadmap, so the next attempt starts from evidence instead of from
the same idea.

### Edges

The budget path is 2-3x the unbudgeted path on joins and nobody has attributed the
second half of it (§89). q19's 16 MB time is decided by the scan's batch size, which
is chosen for the cache; the fix needs the budget inside the source reader (§85). The
unbudgeted peak follows the shared decode and has no contract to meet (§86).

## W5 (2026-10-31): a clock, so the next attribution is a run and not a build

### Goal

§89 left q2's 2.4 s attributable to nothing: the plan, the counters and the rows are
identical at 1.53 s and 3.93 s, and four ablations had ruled out the sort, the collapse,
the partitioner and the store. §95 then ruled out the routing as a whole — handing every
budgeted step to plain `join_step` read 1.63 s with identical answers — and refused to fix
it, because both candidate fixes needed to know how long one stage takes and the engine had
no clock. So this round builds the clock.

### What landed

`set_stage_clock` installs a nanoseconds source; the engine's report is unchanged unless one
is installed, which keeps ANALYZE's row and byte counts deterministic and every existing
snapshot intact. The CLI installs one for `--analyze` on native, reading `CLOCK_MONOTONIC`
through `platform/io`; a target without a monotonic clock installs none. Five stages are
named: `collect`, `join step <n>`, `join`, `aggregate`, `sort`/`sort+project`.

The module-level cell is a deliberate trade: threading a clock through `ExecOptions` would
have made 44 literals — most of them tests — learn a new field to serve one report.

### What it found in its first run

q2 at 16 MB: scans 291 -> 249 ms, aggregate and sort 0 ms, and the whole gap in two join
steps — step 1 299 -> 685 ms and step 2 925 -> 2617 ms, where step 2 is the step the census
names `hash join swapped its sides`. The swap costs 2.8x the plain join on the same 800k
output rows, and the collapse 2.3x more, for a run that ends up 1.6x hungrier than no budget
at all. That is the next contract, and it now has a number instead of a hypothesis.

### Edges

The stage sums do not add to the wall time (1785 ms of stages against 1.62 s unbudgeted):
analyze carries a stats array and a census-free run still pays for it, so a duration is for
attribution, not for benchmarks. The scan stage is the one place a stage can be *cheaper*
than reality, because a lazy source's first batch is pulled inside the first join.

## W5 (2026-10-31): a wrapped fit test, and the strategy it was hiding behind

### Goal

§95 refused a fix because it could not attribute the budget's cost. §96 built the clock and
§96's first run put the cost on one swap. This round asked the swap why it was 2.8x, expecting
to find a cursor that emits rows where it should emit runs.

### What landed

It was not the cursor. `routed_join`'s three fit tests compared `Int32` byte counts, two of
them after doubling the count, so a side above 2^31 bytes wrapped negative and answered "this
fits" for any budget at all. q2's step 2 wrapped on a 1.5 GB side and "fitted" 16 MB, then
spent 2,437 of its 2,636 ms building an index over 7.47M hash entries instead of over the
800,000-row side it was given. The comparisons are `Int64` now.

Fixing that alone made q2 four times *slower* (3.64 s -> 14.14 s at 16 MB): with the wrap gone
the step correctly refused the swap and fell through to the partitioner, which is the wrong
tool for a 12.9 MB build side under a 16.7 MB budget. `build_fits` demanded half the budget —
`batches_bytes(right) * 2 <= opts.budget` — while its own comment said the branch means "the
build side fits the budget". Dropping the factor is the second half; together, q2 16 MB goes
3.65 -> 1.96 s at the same peak, q7 3.40 -> 2.31 s, q9 3.44 -> 3.01 s, worst regression +4.4%
(q22), and q7/q9 move only in the last bits of their float sums (2.7e-15, 4.4e-15).

The report also names routing now: a routed step prints `join step 2 hashed the build side`,
`... swapped its sides`, or `... partitioned`, so the next reader does not need a rebuilt
counter binary to know which side became the hash side.

### What it found on the way

q2 is at 1.4 GB because of its FROM order, not its budget: step 1 is `part x supplier` (747
rows x 10,000) and 7.47M rows exist before partsupp's keys can filter them. No hash strategy
avoids holding that; a join reorder would, and it stays refused (§84) until its own contract.

### Edges

`Int32` byte counts are used all over the budget machinery (`batches_bytes` returns `Int32`,
`join_agg_sides_bytes` summed into one). This round widened the two sides of the routing's
comparisons and the join+aggregate composer's gate; the type itself is still `Int32`, so a
6 GB single side would still truncate at the boundary. `estimate_batch_bytes` also saturates
rather than raising — the numbers are estimates, and this round only removed the wrap.
