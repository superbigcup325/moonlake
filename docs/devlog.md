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
