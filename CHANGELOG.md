# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The README's two library snippets are compiled packages under `examples/`
  and run in CI, with the `moon.pkg` imports a new module needs; the README
  gains a repository layout and the toolchain floor.
- `--analyze` names what a routed join step did with the sides it had: `hashed the build
  side`, `swapped its sides` or `partitioned`.
- `--analyze` names the time each stage took on a target with a monotonic clock: `time
  collect`, `time join step <n>`, `time join`, `time aggregate` and `time sort` in
  milliseconds. The library's report is unchanged unless the caller installs the clock with
  `set_stage_clock`, so row and byte counts stay the deterministic part of ANALYZE.

### Changed

- CI pins `moonc 0.10.18+6c83a7f62` instead of taking whatever `latest` is, and
  asserts the 0.10.16 floor in every job. A nightly `toolchain-latest` job checks
  the upstream release informationally.

### Fixed

- A join step's fit tests compared `Int32` byte counts after doubling them, so a side above
  2^31 bytes wrapped negative and "fitted" any budget: q2 at 16 MB hashed a 1.5 GB side and
  spent 2.4 s of a 2.6 s step doing it. The comparisons are `Int64`, and `build_fits` accepts
  a build side up to the budget instead of half of it, which is what its comment always said.
  q2 16 MB 3.65 -> 1.96 s, q7 3.40 -> 2.31 s, q9 3.44 -> 3.01 s at the same peaks; nothing in
  the 22-query set is slower than +5%. q7 and q9 move in the last bits of their float sums
  (relative 2.7e-15 and 4.4e-15).

## [0.6.3] - 2026-10-31

### Changed

- A GROUP BY under a memory budget whose aggregate state fits in columns splits its fold
  into `budget`-sized segments instead of partitioning the input: q1 at 16 MB reads
  5.04 -> 2.62 s with the 199,193,427 bytes it used to write and read again gone, and q20's
  inner sum reads 2.31 -> 2.08 s. `avg` carries its sum and its count between segments, so
  no average of averages happens; the shapes whose state is not a row (median, standard
  deviations, `string_agg`, count-distinct) keep the partitioned path. The last bits of a
  floating-point sum at a budget move, as they already did per partition. `--analyze`
  reports `fold segments` when the path is taken (verification §94).

## [0.6.2] - 2026-10-31

The join's residual stops rebuilding the side that never moves, and the partitioner
stops paying per scan batch. This is a patch release: a defect fix and two cost fixes,
no public signature moved, and the answers are identical byte for byte.

### Changed

- A budgeted step counts a string column's bytes from the column instead of building one
  `Scalar` per row, which is 11% of q2's and 5% of q13's wall time at 16 MB and 64 MB
  (verification §90). No fit decision moves, because the count is the same to the byte.
- The partitioner routes a side in `budget / 4` chunks instead of in the scan's batches,
  which is 20x fewer gathers: 24% of q7's and 10% of q9's wall time at 16 MB, with peaks
  unchanged (verification §92). Rows, keys and partition numbers do not move, so no
  answer changes.

### Fixed

- The join's residual masks were rebuilt for both sides on every probe batch, although
  the build side does not change between them. q19's OR of three arms over a 200,000-row
  build side against 2,930 probe batches evaluated 1.76 billion tri-states per run: it
  now takes 128.5 s -> 3.8 s unbudgeted and 3.7 s at 16 MB and 64 MB, 17.8x against
  0.6.1. Each half of the state is evaluated once, the answers are identical, and the
  same fix is worth 11% of q2 at 16 MB and 5% of q13. Verification §92, with the whole
  set against 0.6.1 at both budgets: 21 of 22 cases more than 5% faster at 16 MB
  (q19 -94.4%, q2 -76.0%, q21 -49.3%) and 21 of 22 at 64 MB (q19 -94.5%, q2 -87.0%).

## [0.6.1] - 2026-10-31

The memory budget stops paying for partitions it does not need, and the census learns
where a budgeted run's peak actually is. This is a patch release: the plan changes, the
census output and the order of unordered rows are all visible, but no public signature
moved and the previous behaviour was never promised.

### Changed

- An INNER step whose accumulated side fits the budget but whose table side does not now
  swaps its roles instead of spilling: the accumulated rows become the hash side and the
  table streams past them. At SF1 q8 goes 4.25 s → 1.71 s (−60%) at 16 MB with its peak
  down 39%, q5 −52%, q9 −49% at both 16 MB and 64 MB with peaks down 37–41%, q3 −38%, q21
  −22%. No answer changes; unordered output may arrive in the table's order instead of
  partition order. Verification §82.
- A step whose build side fits the budget is no longer partitioned: the build is held as
  the hash side and the probe streams past it a batch at a time. At SF1 q7 goes 6.34 s →
  2.58 s (−59%) at 64 MB and 7.11 s → 4.33 s at 16 MB, q21 9.17 s → 6.05 s at 64 MB and
  12.65 s → 9.00 s at 16 MB, with q21's 64 MB peak down 10%. Answers are unchanged;
  unordered output may arrive in probe order instead of partition order. Verification §81.
- `--mem` now declares a point for each partition a grace join replays, naming the
  replayed left and build partitions and the output accumulated so far. Under a 16 MB
  budget q21's census goes from one point to 106 and names its real peak: 207.9 MB of
  accumulated output at 423 MB resident, with the rest of the 598.5 MB peak being that
  output's collapse copy. Points exist only while a census runs. Verification §79.
- `--mem` now reports each structure's resident bytes, including the validity array a
  column carries (one byte a cell), instead of counting only the cells. At SF1 q18's
  largest point rises to 204.9 MB and covers 86.5% of the resident sample there. Budgets
  keep their old unit on purpose: §76 measured that counting the validity byte in the
  bound costs wall time and raises peaks. Verification §78.
- `--mem` counts a map entry at the measured 60 bytes instead of the unmeasured 24, in the
  join index's slot table and string half and in the fold's `key slots`. At SF1 q18's
  largest point rises from 138.9 MB to 192.9 MB, covering 80.7% of the resident sample
  there. Report-only: no budget, spill threshold or plan choice reads these numbers, and
  the plain matrix is unchanged. Verification §75.
- `--mem` now sizes the group state while a fold grows: a `group state (fold)` point is
  kept per input batch, naming the group slot table, the key arrays and the accumulator
  arrays. At SF1 q18's largest point rises from 90.9 MB to 138.9 MB and becomes the
  resident peak; the state itself is 66 MB. Plain runs are unchanged. Verification §74.
- `--mem` now reports the pulled shapes: a single-table aggregate and a join folded into
  an aggregate keep a `pulled fold finished` point with their finished groups, a composed
  join keeps `composed join fold started` with its build sides, padded copies and key
  indexes, and the subqueries a query runs while it is bound carry the census too. q11
  and q18 used to print nothing or a single cache line; q18's census high-water is now
  within 2.4% of the plain run's peak. A query that reached the earlier points prints
  exactly what it did. Verification §73.
- `--mem` names the shared scan cache: a point is kept when it is filled, and the
  report lists `shared scan cache (<table>)` with its bytes (q18 72.9 MB, q21 97.2 MB at
  SF1). `--mem` and `--analyze` also now run the same shared plan as the plain query,
  which they had stopped doing when sharing landed. Plain runs are unchanged.
  Verification §72.
- A table a query names more than once is decoded once. The decorrelated EXISTS and
  NOT EXISTS sides of q21 each scanned lineitem from the start, so q21 indexed the
  same 773 MB three times; a lazy table named at least twice now shares its decoded
  columns between those scans for the life of one query, and lets go after the last
  of them. At SF1 without a budget q21 fell from 5.30 to 2.94 s with its peak
  unchanged, q18 from 3.30 to 2.15 s at the cost of 82 MB, and nothing moved under a
  budget (which shares nothing) or for a table named once, with every answer
  unchanged. Verification §71.
- A memory budget now counts what a small piece of a batch costs, not only its
  cells: `estimate_batch_bytes` adds about 160 bytes a batch and 64 a column,
  fitted from a probe of resident bytes. A partitioned join or aggregation cuts
  every input batch into many pieces, and the old estimate charged each one 16
  bytes and 4 a column, so the budget believed it held far less than it did. At SF1
  under a 16 MB budget the process peak fell on q9 from 699.2 to 619.1 MB, q8 from
  530.2 to 471.1 MB, q5 from 459.2 to 415.2 MB and q3 from 262.9 to 237.3 MB, below
  what 4096-row batches gave, with every answer and wall time unchanged and nothing
  moving without a budget. Budgeted runs flush earlier as a result; four tests with
  budgets of 64 and 2048 bytes, too small to hold one counted piece, use 512 and
  4096. Verification §70.
- Scans are about 15% faster on TPC-H at SF1, from three changes in the CSV
  reader's inner loops: a field's end is found a word at a time instead of a byte
  at a time, a quoted cell is remembered in a list instead of a flag written per
  cell (96M writes on lineitem saved for a question these files always answer
  "no"), and a batch holds 2048 rows instead of 4096 (1024 was tried first and cost a 16 MB budget up to 100 MB of peak; Verification §68). Without a budget the bench
  harness reports q1 9.64 -> 8.31 s, q7 8.15 -> 7.02 s, q9 9.41 -> 7.78 s and q21
  19.58 -> 16.68 s, with peak RSS unchanged within the spread. `SCAN_BATCH_ROWS`
  is a public constant and it changed value: 16384-row batches proved ~20% slower,
  so the knob is a cache question rather than a call-overhead one. Verification
  §67.
- A chain of joins lets go of a table as soon as its last step has run, instead of
  holding every collected table until the query ends. On q21 at SF1 without a
  budget the process high-water fell from 551.2 MB to 491.2 MB (median of three
  interleaved runs each), q7 by 87.8 MB, and under a 16 MB budget q7 by 87.5 MB
  and q21 by 93.6 MB, with every answer and wall time unchanged; the `--mem`
  census now counts and names only the tables still alive at each point. Keeping
  a table it had finished with is what one of these cost before: 61.0 MB of the
  peak's live set on q21. Verification §66.
- A chain of joins no longer copies each step's output into one batch before
  handing it to the next step: the collected batches are passed on, and only a
  consumer that needs one batch (a budgeted run's partitioner, the composed
  fold's build side, the grace merge) collapses. On q21 at SF1 without a budget
  the process high-water fell from 604.9 MB to 546.7 MB (median of three
  interleaved runs each) and q7 by 112.0 MB, with every answer, counter and wall
  time unchanged; the `--mem` census now names six points instead of nine,
  because a step no longer declares a collapse it does not make. Under a memory
  budget the collapse is kept, as it was: a partitioner slices each input batch
  into every partition, and handing it many small batches measured 4.4x slower.
  Verification §65.

### Fixed

- A semi or anti join no longer aborts when grace partitioning leaves a partition with no
  inner rows: the inner side is concatenated with its own layout, so an empty side is an
  empty batch instead of a batch with no columns to probe. Two thousand distinct keys
  against four aborted at every budget from 512 bytes to 4 KB before this. Verification §77.

## [0.6.0] - 2026-10-29

Everything since 0.5.1 is in this version, and each entry carries the
verification section it was decided by: two of them — the cheaper build-side
index and the composed chain — were gated on a budget until the measurements
let the gate go, and two attempts at memory are recorded as negative results
rather than shipped (§60, §62).

### Added

- `harness/bench_join_agg.py`: resource evidence for a two-table keyed join that
  feeds a `GROUP BY`, against scan-only, aggregate-only and collected-join
  controls over one fixture set, with the answer oracle recomputed from the
  fixtures and checked by `harness/test_bench_join_agg.py`. The baseline it
  produced is `harness/baseline/2026-10-27-e6a-join-agg.json`; the measurement
  is verification §48. No engine behaviour changed.
- `harness/baseline/2026-10-28-e6b-join-agg.json`: the same matrix after the
  composition below, candidate against the released 0.5.1 control.
- `harness/bench_ordered_agg.py` and its baseline
  `harness/baseline/2026-10-28-ordered-agg.json`: peak RSS and wall time for
  the TPC-H queries that carry an `ORDER BY` over an aggregate, the ordered
  one-table and one-join shapes against a control binary, with the two-join
  shapes kept in the matrix as invariants. The measurement is verification §50.
- `harness/bench_join_chain.py` and its baselines
  `harness/baseline/2026-10-28-chain-agg.json` and
  `harness/baseline/2026-10-29-chain-index.json`: peak RSS and wall time for the
  TPC-H queries that carry an aggregate over two or more join steps, the
  candidate against the binary before the change, with the single-step
  compositions kept in the matrix as invariants. The measurements are
  verification §51 and §52.
- `exec --mem` now also reports where the peak is: at every census point it
  records the process's resident and high-water KB (native, from `/proc`) and
  the header names the point whose sample was the largest. On a target without
  `/proc` the fields are absent rather than zero, so an absent readout never
  passes for a small one. The measurement is verification §63.
- `exec --mem`: a structure census that runs a query with the census on and
  prints one block per checkpoint label — the collected tables, a join step's
  collecting and collapsing output, a semi/anti join's inner copy and index —
  each sized from the structures themselves, with the contract in
  `docs/ROADMAP.md` and the q21 measurement in verification §61. Off unless the
  flag is given; answers and counters are the plain run's.

### Changed

- The index a hash join holds over its build side is one contiguous row-id range
  with a start per distinct key, not an allocated list per key, so a primary key
  over millions of rows costs four bytes a row instead of an object each. Every
  keyed INNER, LEFT and FULL hash join is smaller for it (q3 27 MB, q5 66 MB,
  q9 42 MB, q10 20 MB, q20 12 MB at 16 MB). That also removed the reason a chain
  of joins needed a budget: with the cheaper index no composed chain measures
  worse than the tree it replaced (q3 level, q5 64 MB lower, q10 44 MB lower,
  q11 64 MB lower), so a chain of join steps above a `GROUP BY` now composes
  with or without a budget and only a budget it does not fit sends it to the
  eager path. Answers are unchanged and the wall cost is two passes over the
  build keys where there was one (verification §52).
- A `GROUP BY` over one `Int32` or `Int64` key whose aggregates are all `sum`,
  `count(expr)` or `count(*)` keeps its group state as arrays indexed by group id
  instead of a key row and an accumulator row per group, so a group costs about
  82 bytes where it cost 288: one million groups of a `sum` peak at 117 MB, not
  323 MB, and q18 at SF1 drops from 477 MB to 389 MB. Answers are unchanged, and
  any other key or aggregate takes the general fold as before (verification
  §54).
  A pair of `Int32` keys takes the same fold: q20 at SF1 drops from 259 MB to
  99 MB, and 800,000 groups of `(l_partkey, l_suppkey)` from 354 MB to 109 MB
  (verification §55).
- A hash join's key index looks a key up in one array when the build keys sit in
  a compact range (the TPC-H surrogate keys), instead of a hash map entry per
  distinct key. With no budget q3 holds 28 MB less, q5 62 MB and q18 63 MB, with
  identical answers (verification §56).
- The last step of a join chain under a `GROUP BY` runs with its sides swapped
  when the earlier steps produce few rows (at most 65,536): those rows become the
  hash side and the last table streams past them, so a large table named last is
  no longer held whole. q18 at SF1 drops from 325 MB to 145 MB without a budget
  and from 227 MB to 71 MB under 16 MB. Rows reach the fold in a different order,
  so the order of groups without a total ORDER BY can differ (verification §57).
- A hash join over one `Int32` key indexes the key column in place instead of
  widening it to `Int64` first. Without a budget q3 holds 22 MB less and q5 48 MB,
  with identical answers (verification §59).
- A two-table keyed join that feeds a `GROUP BY` is folded from the join's own
  batches instead of collecting them first, when the kind is INNER, LEFT or FULL,
  both `FROM` items are lazy base tables, the key lists are non-empty, and there
  is no `ORDER BY`, window or `SELECT DISTINCT` above it. Peak RSS over the scan
  stops following the joined rows: 39 MB from 1,000,000 to 4,000,000 of them,
  against 51 to 191 MB before, and 41 to 67 MB under the 4M and 16M budgets
  against 51 to 226 MB. Answers and the five `--analyze` row counters
  (`scan <probe>`, `scan <build>`, `joins`, `aggregate`, `result`) are unchanged;
  the spill lines now describe one phase, because these queries no longer run
  `join_or_spill`. A budget the materialized build side does not fit keeps the
  eager path, which can partition the join instead, and reuses the scan it
  already has. A query that used to refuse under a budget because its join skewed
  answers when it has this shape, since the fold needs no joined row set.
  Measurement: verification §49. Every other shape (a longer chain, RIGHT,
  SEMI/ANTI, a keyless cross join, `DISTINCT`, a window) still runs the eager
  path; the `ORDER BY` exclusion this composition drew was lifted afterwards, as
  the next entry says.
- A query with `ORDER BY` above a `GROUP BY` is now fed from the scan or from
  the join instead of collecting its input, for both the single-table and the
  one-join shape: the sort runs on the grouped batch once the fold ends, and it
  is the same in-memory sort the eager aggregate path applies to that batch, so
  a budget still bounds input buffers and a grouped result stays unbounded.
  TPC-H q1 drops from 543 to 35 MB of peak RSS (558 to 75 MB under a 16 MB
  budget) and q12 from 113 to 35 MB, with answers byte-identical to the previous
  binary; q3 and q10 keep a second join step and are unchanged. Measurement:
  verification §50.
- An aggregate over a chain of join steps (three or more lazy base tables,
  INNER, LEFT or FULL on every step, with no `DISTINCT` or window above it) is
  folded as the rows arrive instead of collecting the chain's output, one
  hash-probing cursor per step, each fed by the previous step's batches. It
  composes only under a budget its build sides fit, because a chain holds one
  resident build side per step: with a 16 MB budget TPC-H q11 drops from 99 to
  25 MB of peak RSS, stops partitioning and writes no spill file at all
  (13 files, 22.4 MB before), and answers are byte-identical with the same
  `--analyze` counters in the same order. Without a budget the eager path is
  kept: measured on the same corpus, the ungated chain held 32 MB more than
  the eager path on q3 and 60 MB less on q11, so the shape waits for the bound
  that makes its promise true. A single-step composition still composes with or
  without a budget. Measurement: verification §51.

## [0.5.1] - 2026-10-27

Everything since 0.5.0 belongs to this version, and its
[0.5.1 delivery plan](docs/ROADMAP.md#051-delivery-plan) is complete: one
candidate passed the whole acceptance list, recorded in `verification.md` §36 and
in the performance pair at the end of `docs/bench-baseline.md`. The later Parquet
fix has targeted evidence in §37, the colenc 0.1.1 upgrade in §38, the two
approximate aggregates in §39, and the final candidate passed the same list again
in §40. The entries below describe implemented changes; proposed index work stays
in the roadmap. The source is pushed and the whole acceptance list passed again
on the candidate that carries it (verification §46). It is published as
`superbigcup325/moonlake@0.5.1`, with the tag `v0.5.1` on `f8e1204` and a
[GitHub release](https://github.com/superbigcup325/moonlake/releases/tag/v0.5.1);
the registry consumer check for 0.5.1 passes on all three targets (verification
§47). The
scope was planned as 0.6.0 until 2026-10-27, when the repository owner numbered
the release 0.5.1; nothing in it changed but the number, and the documents, the
delivery-plan heading and the recorded baseline filenames were renumbered with
it. The dependency upgrade's cost is closed rather
than accepted: colenc 0.1.1 was about 10% slower on wide CSV scans because its
generic dispatch kept the bitmap reachable from this tree, colenc 0.1.2 publishes
the split that removes it, and the re-record puts those cases 6-11% below the
0.1.1 control (`docs/bench-baseline.md`, verification §41).

### Added

- `approx_count_distinct(expr)`: a HyperLogLog estimate of the distinct
  non-NULL count, at fixed precision 14 (16,384 registers, about 0.81%
  standard error), returning int64. It hashes the same value equivalence the
  exact path keeps — type-tagged, so int32 1 and int64 1 differ; both zeros are
  one value and every NaN is one value, matching what their text form does —
  and it skips NULL, so an empty or all-NULL input answers 0. The dense colenc
  sketch state has 16 KiB of register payload plus object overhead; colenc 0.1.3
  keeps a small group's registers sparse until it outgrows them.
  `COUNT(DISTINCT ...)` stays exact and no optimizer rewrites one into the other.
  The original measurement with colenc 0.1.1, on a 1,000,000-row string column
  where every value is distinct, reports 1,010,708 against the exact 1,000,000,
  at 56.6 MB of peak RSS against the exact path's 144.7 MB (a decode-only
  `count(s)` is 56.6 MB). That measurement used the old 64 KiB register payload.
  Grouped, the current state costs about 20 KB per group (20,358 B measured at
  20,000 groups): at 1,000 groups it crosses the exact set near 200 distinct
  values per group, and 20,000 groups of one value hold 408.0 MB against 17.2 MB
  for `count(DISTINCT ...)`
  (`docs/sketches.md`, verification §43). That measurement promoted sparse sketch
  state in colenc, which 0.1.3 releases; this version consumes it (§44), so a
  grouped sketch on 20,000 groups of ten values costs 17.3 MB instead of 403.6 MB
- `approx_quantile(expr, q)`: a t-digest estimate of a quantile at fixed
  compression 100, returning float64. `q` must be a constant literal in [0, 1]
  and is checked at bind time, so a query with no rows or under a LIMIT fails
  the same way; a non-numeric input is a bind error; NULL is skipped and an
  empty or all-NULL input answers NULL, like `median()`. NaN and infinity input
  is a SQL error raised when the aggregate finishes, because the fold itself
  cannot raise. On 1,000,000 doubles (0..999,999) `q = 0.5` and `q = 0.9`
  matched `median()` and the exact 90th percentile, at 33.9 MB of peak RSS
  against `median()`'s 44.4 MB. [docs/sketches.md](docs/sketches.md) is the
  contract: input types, equivalence, parameters, and the measured state costs
- `moonlake exec` runs an expression-only query with no input files. It used
  to print the usage text and exit 1 when no `--csv`/`--parquet` was given, so
  checking a formula (`moonlake exec "SELECT 1 + 1"`) needed a dummy file; the
  empty catalog is now allowed and the usage line shows the file group as
  optional. A query that names a table still fails with `unknown table`.
- `harness/bench_hll.py`: the grouped `approx_count_distinct` rig. It generates
  Parquet fixtures with DuckDB, runs decode-only, exact-count and sketch queries
  over 18 group shapes (few large groups, many small groups, duplicates, a 1-in-7
  NULL variant) each in its own child process, and reports peak RSS, wall time and
  the answer for every query, so the per-group state cost and the crossover are
  reproducible instead of extrapolated. The records are
  `harness/baseline/2026-10-26-h0-hll.json` for the released dependency and
  `-sparse.json` for the state the measurement promoted
- `harness/check_cli.sh`: CLI-level edges that live in argument handling rather
  than in the engine (no input files, an unknown command's exit code, `write`
  refusing `--out` on top of its input), wired into the `tpch` CI job next to
  the native build.
- `harness/check_correlation.py`: the correlated-subquery differential is a
  committed gate now. §28's 39-query agreement was recorded from a script that
  was never checked in, so it could not be re-run; the cases and their fixtures
  (`harness/data/correlation/`: a duplicated outer row, NULL keys and values,
  `nan` / `inf`, a date column, an empty table, a one-column table) run against
  DuckDB on every push, and the same cases run over seeded random fixtures
  nightly. `harness/differential.py` holds the plumbing the window gate grew, so
  both gates agree on what "equal", "refused" and "failure" mean; a wrong
  answer, a missing fixture, a referee error, a refusal without its message or a
  run with no value cases fails. Committing it found three defects (below).
- `harness/dict_survey.py`: the second dataset the standard-writing row asked
  for before a dictionary heuristic could be tuned. It builds a seeded
  500,000-row access log — a monotonic clock, a 20,000-valued id, tiny
  enumerations, a repetitive long string, a near-unique long string, a boolean
  and a 40%-NULL note — writes it with PyArrow as plain+snappy, dictionary on
  everything and dictionary on the columns that win, writes the same rows with
  `moonlake write --snappy`, and reports per-column byte deltas, whole-file
  bytes, write time, DuckDB read time, our reader's time and peak RSS at both
  row-group layouts; every file must return the same answer or it refuses to
  print. The survey did not start a writer change: a per-column dictionary is
  worth −14% of that file at our 4,096-row groups and −28% at 65,536-row
  groups, a dictionary on every column is 1.6% *larger* than plain, and the
  bigger groups cost the reader 13 MB → 57 MB of peak memory, so the row-group
  size is the lever that comes first (verification §35).
- `@moonlake.stream` / `stream_with`: a result can be consumed a batch at a
  time. `@engine.ResultStream` reports `names()` and `types()` before the first
  row and `next()` yields one `@types.DataBatch` per call until it returns
  `None`. A single-table query whose remaining work is a pushed build filter, a
  `WHERE`, a projection or an `OFFSET`/`LIMIT` window is pulled from the source,
  so no caller collects it and a windowed query stops reading when its window is
  full. At that release aggregation, joins, `ORDER BY`, `SELECT DISTINCT` and set
  operations were computed first and handed back as one batch, because their
  answer does not exist until every row is in; aggregation, a budgeted `ORDER BY`
  and a two-table join are pulled now (see Changed). `execute` / `execute_with` keep their signatures
  and read the same pull, so the collected and streamed deliveries cannot
  disagree; `run_select_stream` / `run_select_stream_opts` are the engine-level
  names. `close()` stops the pull, a pull that raises ends the stream, and
  dropping an unfinished one releases everything it held. On a 2,000,000-row
  16-column result, `--json` went from 1,090.6 MB of peak RSS to 35.2 MB
  (verification §31). An `ORDER BY` under a budget streams as well and is the
  one stream that owns files — see Changed (§33).
- `@engine.JsonRow`: the JSON row encoder the CLI and `SelectResult::to_json`
  share (`new(names)`, `render(batch, row)`, `batch(batch)`), so a caller that
  prints a batch at a time does not build the whole document as one string. The
  output bytes are unchanged.
- `@types.round_half_away`, the rounding convention `round()` and the
  float → integer casts use.
- Decorrelation is general: the correlation no longer has to be an
  `inner.col = outer.col` equality. A `<`, `>`, `<>`, `BETWEEN`, an `OR` or a
  conjunct on the outer row alone is answered, not refused — `EXISTS` / `IN`
  with no equality pair become keyless semi/anti joins (one bucket, each
  candidate tested against the predicate), and a scalar subquery or an
  `EXISTS` / `IN` used as a value becomes a theta aggregate over the distinct
  combinations of the outer expressions the subquery reads, joined back on a
  canonical row key so a repeated outer row cannot multiply the matches.
  `WHERE EXISTS (SELECT 1 FROM u WHERE u.v < t.a)`, `o.v IN (SELECT i.v FROM i
  WHERE i.k < o.k)` and `SELECT (SELECT max(i.v) FROM i WHERE i.v < o.v) FROM o`
  all answer now; the same queries are the differential cases against DuckDB.
- A correlated `EXISTS` / `IN` works in any expression position, not only as a
  top-level WHERE conjunct: `SELECT EXISTS (SELECT 1 FROM i WHERE i.v > o.v)
  FROM o`, `WHERE NOT (EXISTS (...) OR k > 2)`, `CASE WHEN EXISTS (...) ...`.
  It lowers to a count over the same theta aggregate (`> 0`, and for `IN` / `NOT
  IN` a CASE over the match count, the row count and the count of NULL values,
  which reproduces SQL's three-valued result including the empty set).
- An `EXISTS` / `IN` subquery whose only outer reference is on the outer row
  itself (`WHERE i.v < o.v AND o.k > 1`) is answered instead of refused: an
  outer-only conjunct is a parameter of the correlation and rides in the join
  predicate (or in the theta aggregate) as written.
- `@types.Scalar::arith_checked` and `@types.int_arith_checked`: the same
  arithmetic as `Scalar::arith`, but int32/int64 `+`/`-`/`*` raise
  `SqlError::Execute` on overflow instead of wrapping. `Scalar::arith` keeps
  its wrapping behaviour, documented as such; the engine now evaluates through
  the checked form on both the scalar and the vectorized path, and a caller that
  embeds the engine can pick either.
- `@spill.run_file_name` and `@spill.is_run_file_name`. The files a spill
  directory holds are named by the store, and a host that points `--spill-dir`
  at a directory of its own has to tell them from its own files before removing
  anything: `run_file_name(id)` is the name a run gets, and
  `is_run_file_name(name)` answers whether a name is one of them ("run", one or
  more digits, ".bin"). The CLI's cleanup already asked exactly this question;
  the rule is public now so a second caller does not have to restate it.

### Changed

- A `GROUP BY` under `--memory` now reads the scan as it arrives instead of collecting it first. Batches are buffered up to the budget; only past it are they routed into hash partitions that share one `budget / 4` buffer pool and spilled, so retained input stays at the budget plus one scan batch however many rows follow (100 groups, 8,000,000 rows, 4M budget: peak RSS 195 MB -> 63 MB, answers equal to the collected path and DuckDB). A query that fits its budget behaves as before and needs no spill store. Group state and the result stay unbounded, so `--memory` is still not an RSS cap. `--analyze` adds `spill partitions`, an estimated buffered-bytes peak and an estimated largest-partition spill when it spills, and the collected grace aggregation now registers its cleanup before it writes, which closes a leak on a failure during partitioning (verification section 45)
- `superbigcup325/colenc` 0.1.0 → 0.1.1. The new artifact adds the Roaring
  bitmap, the HLL and t-digest sketches, and three encoding-error variants. No
  code in this tree changed: the reader and writer reach the type only through
  `EncodingError::message`, so the additions are compatible, and the interface's
  `Int` to `Int32` respelling is the same type (`moon info` produces no `.mbti`
  diff). The sketches and the bitmap are available and unused — nothing here is
  an approximate SQL function or an automatic index. This is C0 of the
  [follow-up plan](docs/ROADMAP.md#follow-up-after-colenc-011); the evidence is
  verification §38
- `superbigcup325/colenc` 0.1.1 → 0.1.2, the published artifact that carries the
  reachability fix and the kernel work behind it: PLAIN word loads, the
  dictionary early exit, byte-sized HLL registers, the bitmap query methods, the
  t-digest compression change and reusable FSST models. Two colenc API changes
  are visible to callers — the generic `encode_column` / `decode_column` refuse
  `Encoding::Roaring`, and `HllSketch::registers()` returns a snapshot — and
  neither touches this tree, because the engine reaches the bitmap through the
  dedicated entry points where it reaches it at all. No source change here, so
  the tests, goldens, corpus and packaged consumer are the same gates on a new
  artifact. This is C1 of the [follow-up plan](docs/ROADMAP.md#follow-up-after-colenc-011);
  the acceptance rerun and the performance pair are verification §41
- `superbigcup325/colenc` 0.1.2 → 0.1.3: the sketch state change, and nothing
  else. `HllSketch` now keeps either the dense register array or a sorted array of
  its live entries, promoting above `min(128, m / 8)`, with the hash, the rank
  rule, the estimator, the merge law, the v1 serialized bytes and the public
  interface unchanged — no source change here and no `.mbti` diff. What moves is
  what a grouped approximate aggregate holds: 20,000 groups of one value drop from
  408.0 MB to 15.4 MB, 10,000 groups of 100 from 206.8 to 15.4, while the shapes
  whose groups all promote keep their memory (1,000 × 1,000 reads 35.2 MB against
  33.7) and pay the sorted-array shift on the way through. The eleven release cases
  are unchanged within their own run-to-run spread against a control pinned to
  0.1.2. Verification §44 reruns the acceptance list and re-measures the matrix
- Aggregation folds its input as the scan delivers it. A single-table `GROUP BY`
  or a global aggregate now builds its group state one batch at a time instead
  of being handed the whole input, so the operator holds its state and one batch
  rather than every row it read: `select cat, count(*) from t group by cat` over
  2,000,000 rows and 16 columns went from 109.7 MB to 35.3 MB of peak RSS
  (verification §32). A budgeted `GROUP BY` still collects its input, because the
  grace path sizes its spill partitions from it, and `SELECT DISTINCT` and
  window functions still see the whole row set. Answers, `--analyze` counters and
  the spill path are unchanged; the TPC-H goldens compare the folded answer to
  DuckDB's.
- A two-table join probes a batch at a time instead of collecting both sides.
  `JoinCursor` reads the build side once, probes the other side as the scan
  delivers it, and hands the joined rows back in batches of at most 4096, so a
  probe row never waits for the probe side to end and a caller can stop early:
  a 1,000-row build appended to a 2,000,000-row 16-column probe went from
  270.8 MB to 35.3 MB of peak RSS, and the same join under `--memory 8M` no
  longer spills at all (1.99 s → 0.41 s) because the stream is smaller than the
  budget (verification §34). `join_step` runs on the same cursor, so the
  collected and streamed answers cannot diverge, and duplicate keys on both
  sides, an empty build or probe side, `LEFT`/`FULL` unmatched rows, residual
  predicates and `NULL` keys are compared against `execute`. A chain of three or
  more joins, a `RIGHT` or `SEMI`/`ANTI` join, and anything with `ORDER BY`,
  `GROUP BY`, `DISTINCT` or a window above the join stay collected and yield one
  batch; so does a keyless cross join, because the budget path refuses one that
  overflows it instead of partitioning it. `--analyze` counters are the
  collected path's and are unchanged.
- `ORDER BY` under a memory budget sorts its scan and merges as it goes. The
  runs are now built from the scan's batches instead of from a collected input
  array, and the final merge is a cursor rather than one concatenated batch, so
  neither the input nor the sorted answer is materialized: `select * from t
  order by id` over 2,000,000 rows and 16 columns went from 506.8 MB to 178.8 MB
  of peak RSS, and the same sort with `limit 10` from 335.0 MB to 168.7 MB
  (verification §33). `stream`/`stream_with` hand that merge out one batch at a
  time; a sorted stream owns its run files and removes them when the merge
  ends, when `close()` stops it and when a pull raises, so a caller that drops
  one unfinished leaves them to the store's owner (the CLI removes its
  per-query directory at exit). The unbudgeted sort runs through the same
  `build_runs`/`MergeCursor` code, so the collected and streamed answers cannot
  disagree; `--analyze` counters, spill files and bytes are unchanged. What
  remains above the budget is the merge's decoded run set, recorded as a known
  limit in §33 and not fixed here.
- `concat(a, b, ...)` is variadic, casts its arguments, and skips NULL ones:
  `concat(1, 2)` is `'12'` and `concat('a', NULL, 'b')` is `'ab'`, as in
  DuckDB. `||` keeps its own semantics (two string operands, NULL propagates)
  under its own lowering, so `'a' || NULL` is still NULL.
- `round()` rounds half away from zero on both sides. It was MoonBit's
  `Double::round`, which rounds half toward +infinity: `round(-2.5)` gave -2
  while `round(2.5)` gave 3, and `round(-1.2345, 2)` gave -1.23 against 1.24 for
  the positive value. It now matches DuckDB and PostgreSQL on both sides.
- `cast(<double> AS int)` / `AS int64` round rather than truncate, so
  `cast(2.5 AS int)` is 3 and `cast(-2.5 AS int)` is -3 (DuckDB and PostgreSQL;
  C, SQLite and MySQL truncate). A value that does not fit the target type now
  raises `out of range` instead of saturating, and NaN/infinity are refused the
  same way. The README states the convention next to `round`.
- A correlated `EXISTS` whose subquery carries a `GROUP BY` is decorrelated
  rather than refused. Existence does not depend on the grouping, so it is
  dropped; a `HAVING` is kept when the user grouped by exactly the correlation
  keys (the grouping the decorrelator builds anyway) and refused with that
  reason otherwise, since regrouping would change what the HAVING means.
  `exists (select 1 from orders where orders.custkey = c.id group by
  orders.custkey having count(*) > 2)` answers now, and matches DuckDB on the
  same fixture; `group by orders.status having ...` is refused.
- An untyped `NULL` literal is accepted wherever a call or `IS [NOT] NULL`
  demands a type: `length(NULL)`, `upper(NULL)`, `abs(NULL)`, `substring(x,
  NULL)` and `NULL IS NULL` are NULL/TRUE now instead of the v1 "untyped NULL
  is only supported as a comparison or arithmetic operand" refusal. A
  non-NULL argument of the wrong type still errors.
- Parquet write failures report `sql error (execute):`, not `sql error
  (scan):` — a `cannot create <out>.moonlake-tmp-...` pointed at the reading
  stage. Scan errors on the input keep their `scan` label.
- The Parquet writer no longer refuses files larger than 2 GiB. A column
  chunk's `file_offset` and its `data_page_offset` are file positions, so they
  are written and counted as 64-bit now; the only 32-bit length left is a page's
  own body, and a page holds one batch, so that bound is the batch size rather
  than the file size. Writing 2.35 GiB of CSV produces a 2.41 GiB Parquet file
  in 13.5 s at 22 MB of peak RSS, with 1,820 of its 16,798 column chunks past
  2^31, and moonlake, pyarrow and DuckDB read the same rows and sums back from
  it (`harness/check_large_write.py`). Nothing public changed: `write_bytes`,
  `write_file` and `write_file_with` keep their signatures, and files under
  2 GiB are byte-identical to 0.5.0's.
- A single-table `LIMIT` stops its scan when the window is full. The executor
  used to materialize a whole table before the window saw a row: `select * from
  t limit 10` over 2,000,000 rows (75 MB of CSV) read all of them, taking 483 ms
  and 252 MB of peak RSS above the measurement floor, and 278 ms / 250 MB over
  the same rows as Parquet. It now pulls one batch of 4,096 rows: 13.9 ms and
  13 MB on CSV, 4.9 ms on Parquet, with `--analyze` reporting the 4,096 rows the
  scan emitted instead of 2,000,000. What a LIMIT cannot stream — a join, an
  aggregate, `ORDER BY` or `DISTINCT` above it, or a derived table on the outer
  side — behaves exactly as before, and all eleven benchmark shapes return the
  same rows as 0.5.0 when checked against DuckDB on the same fixture. Nothing
  public changed then; the pull it introduced is the public `stream` path for
  every single-table scan now (see Added).
- `--json` prints its array as it arrives: one line per batch instead of one
  line for the whole result. It is still one JSON array — a result that fits one
  batch is byte-identical to 0.5.0's output — but 2,000,000 rows now print as
  489 lines while the rows are still being read, and the CLI never concatenates
  the document. Text output keeps its header plus one line per row and is
  consumed the same way.
- A CLI failure exits 1 with its message on stderr even when it happens after
  output began, and an input that cannot be parsed no longer ends the process
  with a panic trace and status 134. Rows already printed stay on stdout, which
  is what the README now states.
- `--snappy` output is about 13% smaller. The compressor wrote every match as a
  three-byte `copy2` tag even when the match was short and close behind, which
  is what most of a text page looks like; a length of 4–11 at an offset below
  2048 is now a two-byte `copy1`. The SF1 `lineitem` table (6,001,215 rows)
  drops from 333.0 MB to 289.2 MB, against 287.9 MB for pyarrow writing the
  same rows as plain+snappy. Only the encoder's tag choice changed, so the
  decoded bytes are the same ones as before.

### Fixed

- A Parquet file whose footer understates a column chunk decodes again. Some
  writers leave the page headers out of `total_compressed_size`:
  apache/parquet-testing's `nation.dict-malformed.parquet` declares 2002 bytes
  for a 2017-byte page chain, so its last data page ends 15 bytes past the
  declared extent while the bytes are inside the file (footer at 2608, page
  payload 2580–2608). Since 0.5.0's ranged reads the chunk was sized from that
  number and the page was refused as "past the end of the file"; 0.5.0 and 0.5.1
  both refused it, the whole-file reads before 0.5.0 decoded it, and PyArrow and
  DuckDB read it (25 rows × 4 columns, cell for cell). The reader now follows
  the page headers as they do: a page that overruns the declared extent is read
  again up to the end of the file, and only a page that really runs past the end
  is refused. That refusal names the file offset now: the old one reported the
  chunk-relative offset as if it were one (`sources/parquet/reader.mbt`).
- `x IN (SELECT ...)` returns NULL instead of FALSE when the set holds a NULL
  and `x` is not in it. The three-valued rule was gated behind `NOT IN`, so
  `SELECT o.v IN (SELECT n.v FROM n) FROM o` answered `false` where DuckDB
  answers NULL for three of five rows — and `NOT IN` gave FALSE where SQL says
  NULL for an empty set (see the anti-join fix below). `IN` and `NOT IN` now
  read the same rule in both directions (`engine/eval.mbt`).
- A correlated `NOT IN` over a set that cannot be narrowed per row answers
  instead of collapsing into an internal refusal, and the shapes it cannot
  answer yet say so by name. The NULL-poison detection returned the same
  "unsupported" a genuinely unanswerable shape does, and its first repair
  dropped the whole result — `o.v NOT IN (SELECT i.v FROM i WHERE i.k < o.k)`
  came back empty where DuckDB returns five rows — because the conjunct loop's
  early exit discarded the `false` filter the fix had added. Keeping the poison
  is right only when the set cannot be narrowed; narrowing needs a per-row count
  of the NULLs the anti join never compares, so that shape is now refused with
  `cannot be decorrelated` and the gate pins it until the join contract owns it.
- `NOT IN` over an empty correlated set keeps a row whose probe value is NULL.
  The anti join read "NULL correlation key" as UNKNOWN without asking whether
  the row's set had a member, so `SELECT oid FROM orders WHERE custkey NOT IN
  (SELECT cid FROM customers WHERE cid > 10)` lost the row whose `custkey` is
  NULL; SQL says TRUE, because there is nothing to be unknown about. The join now
  asks its residual whether any inner row could be a member of that row's set,
  which is the question it already answers for a match.
- `ORDER BY` on a qualified column no longer binds to a same-named *output*
  alias: `SELECT k AS z, flag AS k FROM a ORDER BY a.k DESC` sorted by the
  alias. This also produced the reported "outer join ORDER BY / NULLS LAST
  ignored" and "LIMIT over a left join returns the wrong rows" symptoms, which
  were the same misbinding. A bare (unqualified) name still resolves to the
  last same-named output column, as DuckDB does.
- A CSV `True`/`FALSE` (any letter case) is inferred as BOOL. Only lowercase
  `true`/`false` were recognised, so a pandas export turned into a string
  column and `WHERE flag` failed with `build filter must evaluate to bool, got
  string`.
- `moonlake write` refuses an `--out` that is one of its inputs. It used to
  replace the source file: `write --csv t.csv --out t.csv` exited 0 and left a
  Parquet file at the CSV's path. The check is lexical (`./t.csv`, `sub/../t.csv`
  and a glob match all count) and covers `--parquet` inputs.
- A correlated subquery whose correlation is not an equality now says what is
  still out of reach, instead of naming a shape that works. It used to fail
  with `unknown table or alias "t" in FROM`, then with a message that claimed
  only `inner.col = outer.col` correlations were supported — which stopped
  being true once the general rewrite landed. The refusal names the real
  boundaries now (a derived table in the subquery's FROM, `DISTINCT` / `LIMIT`
  / `OFFSET` / a set operation, a grouping that is not the correlation keys) and
  still points at rewriting it as a join. A reference to a table two levels out
  is still refused by the binder (`unknown table or alias <name> in FROM`), which
  the README now says instead of claiming a named message; the correlation gate
  pins that text with a note. A
  correlated scalar subquery that selects no aggregate keeps its own reason, and
  the positions the rewriter does not reach name themselves instead of letting
  the inner bind report the outer table as missing: the select list of a
  `GROUP BY` query (its value would have to appear in the `GROUP BY`), a
  `HAVING` clause (it runs against grouped rows) and a `JOIN ON` clause (the
  synthetic table would join after it).
- A CSV row with the wrong number of fields is a scan error naming the file and
  the row (`part-3.csv: row 1201 has 1 field, expected 3`), on both the
  registration path (the inference sample) and the scanning path (every row of
  each 4 MB range). Before, a short row's cell offsets ran into the next row's
  cells: a 5,000-row file answered with its neighbour's values, and a short row
  that landed on the sampled boundary — or on a range's last row, where the
  offsets run past the cell arrays — crashed the process (a 400-row file with
  the short row at data row 100 exited 134). Every ragged fixture under
  `sources/csv`'s blackbox tests and the release battery now fails cleanly, and
  a file that is only *reached* past the sample is refused when its scan opens,
  not silently.
- A CSV header that repeats a name gets DuckDB's `read_csv` rename: the second
  `a` becomes `a_1` (and a generated name never collides with one the header
  already uses). Both columns used to bind to the first, so `a,a` over `1,2`
  answered `1|1` and `--json` emitted `{"a":1,"a":2}`, a JSON object with a
  repeated key. `SelectResult::to_json` makes a repeated output alias unique the
  same way, so `SELECT a, b AS a` is strict JSON a parser can round-trip.
- Non-finite float values read instead of degrading the column: `NaN`, `inf`,
  `+inf`, `-inf` and the `Infinity` spellings (either case) are float64 in a CSV
  cell and in `CAST(... AS DOUBLE)`, which is what pandas, numpy and the JSON
  emitters write. The old parser also refused every finite value with an
  exponent past 300 (`1e307` is a normal double) and now takes the whole double
  range, overflowing to `inf` the way a DuckDB cast does.
- A correlated `count(*)` (also `count(x)` and `count(DISTINCT x)`) over an
  outer row with no matching inner row answers 0 instead of NULL. The
  decorrelated form is a grouped LEFT JOIN, so the probe side saw NULL where SQL
  says the aggregate's identity: `(SELECT count(*) FROM n1 WHERE n1.k = u3.k)`
  over keys 1,2,3 against a one-key table answered `1|1`, `2|NULL`, `3|NULL`
  and now matches DuckDB's `1,0,0`. `sum`/`min`/`max` keep NULL, which is
  their empty-group value.
- `--explain` and `--analyze` of a `SELECT` without `FROM` print the plan
  instead of aborting. `explain` bound the query with no FROM item, so the plan
  had no step and rendering indexed past the empty list (exit 134 on
  `--explain "SELECT 1"`); it now uses the same zero-column `__one` dummy table
  the executor already drove, and the plan reads `scan __one (0 cols)`.
- The `js` build finds its subcommand. `node main.js exec …` fell through to the
  usage text and exited 0: on js `@env.args()` prepends the script path as a
  second launcher entry, so `args[1]` was never `exec`. The launcher entry is
  dropped once, before the commands see the argument list, which also makes a
  bare `node main.js` print usage like the other targets.
- An unknown command exits 1 with `unknown command "…"` instead of printing the
  usage text and exiting 0, where a pipeline would read the help as data.
- `--memory` refuses a value past 2147483647 bytes instead of wrapping. `4G`
  wrapped to 0, which means *no* budget, so a 4 GiB cap ran unbounded; a value
  just past the bound wrapped to a few KB. The parse accumulates in int64 and
  reports the value and the bound.
- `--css`-style bare globs with no name are refused: a `--csv '*.csv'` that
  matched several files used to register them all under table `""`, which only a
  quoted empty identifier could reach. The error asks for a shared prefix
  (`part-*.csv`); one match keeps its file stem, as before.
- Two inputs that resolve to the same table name are refused
  (`two inputs register as table "a" (x/a.csv and y/a.csv)`). `--csv x/a.csv
  --csv y/a.csv` used to register both under `a`, last one wins, so a query
  answered from one of the two files with nothing in the output saying which.
- `--date-col` with no Parquet input is refused. On a CSV-only invocation the
  flag was validated by name and then ignored: `--date-col k` over a CSV int
  column left it an int (`EXTRACT` still said `got int32`), and a name that
  matched nothing emitted no message at all.

## [0.5.0] - 2026-10-24

> First release since 0.4.0. The theme is that a query's memory no longer grows
> with the size of its input files: Parquet and CSV scans read byte ranges
> instead of whole files, and native Parquet output streams as it encodes
> instead of building the archive in one buffer. `count(*)` over a 287 MB
> Parquet file drops from 295 MB of peak RSS to 12 MB, and over a 302 MB CSV
> file from 1063 MB to 35 MB. It also closes what a killed query left behind:
> a spill directory is claimed with an owner marker and reclaimed by the next
> query only when that marker proves the owner is dead. One signature was
> added, native-only (`pub type Emit`, the sink `write_file_with` writes
> through); every other public signature and every produced file is unchanged,
> byte for byte.

### Added

- 2026-10-23 native Parquet file output streams instead of buffering: a new
  native-only `platform/io` package (C stub, `FileSink`) writes pages as they are
  encoded and renames a temporary file over the target on success, so a failed or
  interrupted write leaves the previous file intact. `write_file_with` keeps one
  signature on all three backends (wasm-gc/js keep the whole-file write their
  hosts require) and the public interface gains only `pub type Emit`. Measured
  peak RSS on a Parquet input drops 326 → 101 MB raw and 199 → 101 MB Snappy, and
  the produced archives are byte-identical to 0.4.0's; with a CSV input the
  archive-sized copy is likewise gone (427 → 337 MB at 75 MB of output). The
  remaining CSV growth is the scan, tracked separately

### Changed

- 2026-10-24 a query killed outright no longer leaks its spill directory: each
  `moonlake-spill-<n>` is claimed with an `owner` marker (pid, boot id, the pid's
  start time from `/proc`) created exclusively, and the next query removes a
  directory only when that marker proves the owner is dead — another boot, a pid
  that no longer exists, or a pid whose start time changed. A directory with no
  marker, an unknown marker version, or a live owner is kept, and the first two
  are reported on stderr. Reclaiming renames the marker away first, so
  concurrent reapers cannot both empty one directory, and it deletes only the
  run files and marker names it wrote. Backends without `/proc` (wasm-gc/js, and
  macOS, which has no boot id to record) keep the previous behaviour: nothing is
  recorded and nothing is reclaimed. The rules live in the `cmd/main`
  executable, so no published signature changed; `platform/io` grew the
  exclusive create, a rename that tolerates a vanished source, a pseudo-file
  read for `/proc`, and the clock. Details and the ten-check acceptance are in
  `docs/verification.md` §22


- 2026-10-24 CSV files are scanned in byte ranges instead of whole: `scan_file`
  reads a 64 KB prefix at registration (header plus the inference sample) and
  one 4 MB range at a time while a query runs, indexing and materializing each
  range before dropping it, so peak RSS no longer grows with the file or with
  a per-cell offset table for all of it. `count(*)` over a 302 MB SF0.1 lineitem
  copy drops from 1062.7 MB to 35.2 MB and `write --csv` from 1062.7 MB to
  34.9 MB, with byte-identical archives and DuckDB-identical results; wall time
  roughly halves. Memory inputs and the wasm-gc/js builds keep their existing
  behaviour behind the same signatures, so the public interface is unchanged.
  Measured numbers and the range-level tests are in `docs/verification.md` §21

- 2026-10-23 Parquet files are read in byte ranges instead of whole: the native
  `platform/io` binding gained positioned reads (`pread` plus a size from
  `fstat`) and a `FileReader`, and `scan_file` now reads the 8-byte trailer and
  the footer at registration and one column chunk per projected column per row
  group when a query runs. Peak RSS for a scan no longer grows with the file —
  `count(*)` over a 287 MB archive drops from 295 MB to 12 MB (585 → 12 MB at
  574 MB) and a one-column aggregate from 323 MB to 37 MB — and wall time falls
  with the removed copy pass. Memory inputs (`scan_bytes`) and the wasm-gc/js
  builds keep their existing behaviour behind the same signatures, so the public
  interface is unchanged. Measured numbers and the range-level tests are in
  `docs/verification.md` §20

## [0.4.0] - 2026-10-23

> First release since 0.3.1. It carries everything that landed on `main` in
> between: the session playground (several files, cross-file JOIN, plan panel),
> the in-house Parquet writer (NULLs, STRING/DATE annotations, statistics,
> SNAPPY, one-pass streaming input), file-level Parquet pruning, the packed
> two-key join, the spill isolation fixes, the archive-consumer gate, and the
> correctness fixes below (non-finite JSON, spilled-sort ordering). 0.2.0 was
> never published on its own.

### Added

- 2026-10-23 the release benchmark verifies answers instead of only hashing
  stdout: every timed case is compared against DuckDB over the same files
  outside the timed region (`--check-oracles` runs just that check, `--no-oracle`
  opts out), `kernel_bench` checks each case against the table it built and
  `spill_bench.py` recomputes the first column's checksum from the CSV. A
  mismatch aborts the record. Comparator behaviour gained 14 self-tests
  (environment/data refusal, output change and instability, missing fields,
  added/removed cases, spread band); the check immediately found the wrong
  spilled-sort answer fixed above
- 2026-10-23 the Parquet encoding evidence is now rebuildable and page-level:
  `harness/gen_colenc_fixtures.py` writes the DELTA int32/int64, DELTA length and
  byte-array, BYTE_STREAM_SPLIT float/double cases (nulls, empty strings,
  boundaries, −0.0, SNAPPY, four row groups, three pages per group) and records
  the PyArrow version, the exact write arguments and the digests in
  `harness/colenc_fixtures.json`; `harness/check_colenc_fixtures.py` reads the
  actual page headers of both those files and the embedded `colenc_integration_test`
  fixtures, then compares values from PyArrow and from the CLI. A v2 page or a
  different encoding fails even when the footer still lists the claimed one. The
  `tpch` CI job and nightly run the gate
- 2026-10-23 `harness/check_windows.py` replays the window-function differential
  that `docs/verification.md` §5.1 had only as history: a fixed nine-row fixture
  plus a 22-case list, DuckDB-refereed. Total-order results compare in sequence,
  unordered ones as a multiset with duplicate counts, an order-free `string_agg`
  is row count only, and refusals are counted apart — valid SQL we refuse must
  run in DuckDB, SQL the standard forbids must be refused by both. No skip path:
  a referee error, a missing fixture or zero executed value cases fail the gate.
  The `tpch` CI job runs the fixed list and nightly runs `--random 400`
- 2026-10-22 `harness/check_consumer.py`: the packaged library is extracted
  into a temporary workspace and used by an independent consumer on native,
  wasm-gc and JS, resolving dependencies from a fresh registry/cache. The
  version, CSV query, raw/Snappy Parquet round-trips, DATE/NULL values and
  table removal must agree. Per-PR CI and release provenance run the gate;
  `--registry-version` checks the published current API after a release, with
  no workspace override. No credentials or package upload are needed
- 2026-10-22 browser acceptance now requires the exact engine version from
  `moon.mod` (or `MOONLAKE_EXPECT_VERSION`), so a stale deployed page cannot
  pass merely because it loads and reports a version
- 2026-10-21 `TableEntry::stream(request)` returns the scan a `TableEntry::scan`
  would return, as a `BatchStream` cursor instead of an `Array[DataBatch]`, so a
  caller that consumes batches one at a time never materializes the table. The
  Parquet writer is the first user; the engine keeps `scan` because its
  operators are still eager
- 2026-10-21 the release record carries the dataset's SHA-256 and each case's
  `sql`. A path is not an identity (regenerating SF0.1 with a different
  generator yields the same names and different numbers), and a prose `what` is
  not a workload. The `spill/*` cases now prove the spill with `ANALYZE` and
  assert the spill directory is empty afterwards, because the engine removes its
  run files — the old check counted the leaked ones
- 2026-10-21 `harness/check_release.py` and a `release` workflow on `v*` tags:
  the version claims (`moon.mod`, the library `VERSION`, the newest CHANGELOG
  heading, the tag name) have to agree, `moon package --list` has to hold the
  files a release needs and none of the dev-only ones (dot-directories,
  `moon.work`, `harness/data/`, the bench drivers, `hooks/`), the tree has to be
  clean, and
  `--publish-dry-run` optionally runs the publish gate. 0.3.0 shipped after a
  manual review found three of those four agreeing; nothing made them agree by
  construction. `/harness/kernel_bench/` is excluded from the archive like the
  other dev driver
- 2026-10-21 the playground holds a session instead of one table per run: the
  bridge exports `add_csv` / `add_parquet` / `drop_table` / `tables` / `query`
  / `plan` / `reset`, so several files can be registered, listed with their
  schema, dropped, and joined across. A duplicate table name is refused rather
  than silently replacing the old table, the page has a Plan panel
  (`engine.explain`, including the scan row counts), and `Catalog::drop` is the
  library-side equivalent
- 2026-10-21 `harness/playground_accept.cjs` grew to 15 checks and the new CI
  job `playground` runs it in headless Chromium on every PR: two files at once,
  a cross-file JOIN, the plan panel, a duplicate name, a dropped table, a clear,
  CSV and Parquet agreeing cell for cell, both error paths and no uncaught JS
  error
- 2026-10-21 `harness/kernel_bench`: in-memory operators measured without the
  CSV ingest every release-record case contains, with case pairs chosen so a
  difference isolates one structural cost. The same run recorded two
  candidates that did *not* justify work: gather over nullable columns is not
  slower than over non-nullable ones (so bit-packing the validity channel has
  no measured cost to recover), and the whole-side concat in `join_step` is
  small against the int-key control
- 2026-10-21 `EXPLAIN` states a scan's row count: exact when the format knows
  it (`rows: 600572` from a Parquet footer or a materialized table) and `?` when
  it does not (a lazy CSV scan). No estimates are printed — the engine has no
  cardinality model, and a guess beside an exact count invites trusting it
- 2026-10-21 Snappy compression on the write path: `--snappy` (CLI) or
  `write_bytes_with` / `write_file_with` (library). The compressor is ~120
  lines of LZ77 in the Snappy block format (`sources/parquet/snappy.mbt`), so
  the writer still has no dependency the reader does not already need. On a
  4000-row text table the file goes 140,274 → 24,323 bytes
- 2026-10-21 `moonlake write (--csv|--parquet …)+ --out <file.parquet>
  [--table <name>] [--snappy]`: the writer's only way out of the library, which
  is what lets a round trip be scripted and checked
- 2026-10-21 `harness/check_writer_interop.py`: moonlake → pyarrow → DuckDB and
  DuckDB → moonlake, checking the schema (VARCHAR vs BLOB, DATE vs INTEGER), the
  values, the NULLs and a non-ASCII string; `--snappy` shrinking is asserted on
  a table large enough for it to show. A new CI job `writer` runs it on every
  PR
- 2026-10-21 a grace hash join partition that still exceeds the budget is
  partitioned again (up to two extra levels, 256 partitions each) instead of
  failing at the first level: a small budget against a large input used to be
  reported as "hash skew" even when no key dominated. What no re-partitioning
  can split is one key holding most of a side, and that error now says so
- 2026-10-21 grace aggregation pulls a partition one spill file at a time
  instead of materializing it (`BatchSeq`), so a hot group key no longer puts
  a whole partition in memory on top of the budget
- 2026-10-21 `harness/spill_accept.sh`: seven checks over the spill lifecycle —
  no directory after a successful sort, none after a failed query, `--spill-dir`
  keeps files moonlake did not write, `ANALYZE` reports the counters, and an
  in-memory `ANALYZE` stays silent; concurrent queries sharing a directory do
  not collide, and a new query leaves an interrupted query's directory alone

### Changed

- 2026-10-21 the Parquet writer speaks the format, not just the encoding: it
  writes the standard `STRING` and `DATE` annotations (both the deprecated
  `converted_type` and the current `logicalType`, because readers disagree on
  which they look at), and per-column-chunk statistics marked exact. Before
  this a written DATE was a bare INT32 and a written string an unannotated byte
  array — a BLOB to DuckDB, an integer to anyone else. A file moonlake writes is
  now prunable by moonlake's own row-group skipping
- 2026-10-21 the Parquet reader acts on those annotations: an annotated DATE
  column needs no `--date-col`, and an annotation with no faithful engine type
  is refused instead of silently misread — `DECIMAL` (its bytes are not text)
  and `UINT_32`/`UINT_64` (values past the signed maximum would read as
  negative) now fail with a message naming the column and the reason. Six
  apache/parquet-testing files moved from "read" to "refused by design"
- 2026-10-21 `bench_release.py --compare` refuses to print deltas when the two
  records were not taken under the same conditions (CPU, cores, kernel,
  toolchain, dataset SHA-256, build, runs, warm-ups; `--allow-env-mismatch`
  overrides), prints clock/load/governor as advisory lines instead of refusing
  on them, labels a delta that sits inside the case's own run-to-run spread,
  and records that spread per case — so the ±7% rule is measured rather than
  assumed. Records from before the spread field say so instead of implying
  their deltas are significant
- 2026-10-21 the baseline's per-case peak RSS carried a fork-inherited floor:
  hashing the dataset read all 75 MB of CSV into the harness process before the
  cases ran, and a forked child starts with its parent's resident pages, so the
  two Parquet cases (25 and 39 MB on their own) both reported 94.9 MB. The hash
  runs after the measurements and the parent is collected before they start;
  the controlled check (150 MB of ballast → an 11 ms case reported 164 MB) is
  written down in `docs/bench-baseline.md`
- 2026-10-21 the Parquet writer streams its input. It used to call
  `entry.scan(...)` — the whole projected table in memory — and walk it twice:
  once to decide REQUIRED vs OPTIONAL per column (the schema is file-wide, the
  pages are written before the footer), once to write. Every column is now
  written OPTIONAL with definition levels, which is the only schema that can be
  declared before the first page and still describe a NULL arriving later, so
  the pre-pass is gone and one `BatchStream` feeds pages as batches arrive.
  Cost: 18,816 bytes on the SF0.1 lineitem file (0.03% — hybrid RLE turns a run
  of ones into a few bytes). Peak RSS: 407 → 328 MB writing from
  `lineitem.parquet` (286 → 203 with `--snappy`), 456 → 421 MB from the CSV.
  What still bounds it is not the writer: sources read whole files (the fs API
  has no range reads) and `write_bytes` still accumulates the archive before
  `write_bytes_to_file`; an incremental file handle would be needed for that

- 2026-10-21 a join on two int32 equality keys is 4.9x faster (69.3 → 14.0 ms
  on a 100k x 100k join, same session, single-key control unchanged at
  ~13 ms). It was falling back to the general path, which builds a canonical
  string per row on both sides; the two keys are now packed into one exact
  Int64, `(a << 32) | (b & 0xFFFFFFFF)`, which is injective so no collision
  handling is needed, and a NULL in either component still never matches. This
  is the partsupp-on-(partkey, suppkey) shape of TPC-H Q9. Strings, Int64 pairs
  and three-plus keys keep the general path

### Fixed

- 2026-10-23 a spilled `ORDER BY` could return a wrong answer: the run writer
  accumulated several independently sorted chunks and wrote them back to back,
  while the final k-way merge reads each run file as one sorted stream. A run
  that held pieces of more than one sorted batch was only piecewise sorted, so
  the merge leaked chunk heads into the result — over SF0.1 at `--memory 1M`,
  `ORDER BY l_extendedprice DESC LIMIT 3` reported 95799.5 as its maximum
  instead of 95949.5. A 200 KB budget happened to keep one chunk per run, which
  is why the acceptance check stayed green; the regression came from the new
  benchmark oracle that compares answers, not stdout hashes. A run is now
  sorted before it is written (bounded by `budget/4`), and join/aggregation
  partition writers keep their unsorted runs. Recorded spill timings taken
  before this fix are not comparable
- 2026-10-23 `--json` (and the playground, whose `JSON.parse` runs on the same
  string) emitted a non-finite DOUBLE as a bare `Infinity`, `-Infinity` or
  `NaN` token, so one such value made the whole line invalid JSON — a division
  by zero, which this engine deliberately keeps as IEEE inf/NaN, was enough.
  Those three values now render as strings, keeping the output strictly
  parseable and still distinct from a finite number and from SQL NULL; finite
  doubles stay JSON numbers
- 2026-10-22 DuckDB 2.0 removed `fetchone()` from its relation API, breaking
  Parquet fixture generation and writer interop. Single-row reads now use the
  connection cursor API. The corpus gate only skips DuckDB read errors, lets
  Python/API errors fail, and refuses success when a recorded file was not
  verified; an all-skipped run could previously pass. CI uses Python 3.12 and
  the DuckDB/PyArrow versions in `harness/requirements.txt`
- 2026-10-22 the nightly and pre-commit hook labelled a bare `moon test` as
  native, but the module had no preferred target and it ran wasm. Both now
  select native explicitly, and `moon.mod` sets wasm-gc as the default target
- 2026-10-22 the README and harness guide still described the old single-table
  playground and five spill checks, and claimed all current features shipped
  in 0.3.1. They now describe the session UI, seven spill checks and the
  development/release boundary; quickstarts refresh the registry first and
  acknowledgements include the colenc dependency
- 2026-10-22 unsupported Parquet physical-type and encoding errors now
  interpolate the actual column name instead of printing literal placeholders
- 2026-10-21 two spilled queries sharing one `--spill-dir` corrupted each
  other: every query wrote `run0.bin`, `run1.bin` … into the directory it was
  given and then removed every `run<n>.bin` it found there, so a concurrent
  pair failed on both sides with `spill read: No such file or directory`. A
  query now spills into its own `moonlake-spill-<n>` subdirectory (`create_dir`
  is the lock) and the cleanup only looks inside the directory it created, so a
  caller's own files in `--spill-dir` are never listed, let alone deleted. A
  killed process still leaves its subdirectory behind: the filesystem API has
  no pid, clock or file timestamp, so a dead owner cannot be told from a live
  one and the next run does not guess — that boundary is pinned by the
  acceptance instead of staying invisible
- 2026-10-21 the Parquet corpus check counted a footer-only `select count(*)`
  as a read, so 18 of its 35 "read" files were ones whose data pages this reader
  refuses (LZ4/ZSTD/GZIP codecs, v2 pages, an empty dictionary page). It now
  decodes every column and compares a five-row sample against DuckDB cell for
  cell, and pins each file's class in `harness/parquet_corpus_expected.json`, so
  a file that stops decoding fails the nightly instead of hiding inside a count.
  The honest classification is 17 decoded by value, 51 refused by design, 0
  failing
- 2026-10-21 a spilled sort leaked its intermediate run files on the success
  path: `reduce_and_merge` recorded the files it produced while merging and
  then only removed them through `errdefer`, so every successful spilled
  `ORDER BY` left them behind. The CLI's `remove_dir` is not recursive, so the
  directory survived too — one temp tree per spilled query, until a query
  failed mid-spill on a full disk. The intermediates are now removed after the
  merge returns, and the CLI purges a spill directory of `run<n>.bin` files
  (its own names only — `--spill-dir` may point at a caller's directory) and
  reports a directory it cannot remove instead of swallowing the error
- 2026-10-21 `ANALYZE` could not report a spill: `explain_analyze` ran with
  `ExecOptions::in_memory()` hard-coded, so the spill counters it collected
  were never reachable. `explain_analyze_with` takes the caller's options, the
  CLI passes `--memory`, and the engine counts files and bytes at the store
  boundary (`spill files` / `spill bytes written` / `spill bytes read`)

## [0.3.1] - 2026-10-20

> Patch release. 0.3.0's wasm did not instantiate in a browser (so the
> playground never loaded) and `--json` was invalid for any DATE column;
> both are fixed here. No API changes — a 0.3.0 consumer upgrades by changing
> the version.

### Added

- 2026-10-20 `harness/bench_release.py`: one release performance record covering
  scan, join, gather and spill, with the toolchain, machine, git commit and
  binary hash alongside the numbers, stdout hashes to prove the work did not
  change, and `--compare` for release-to-release deltas. The first record is
  [`harness/baseline/2026-10-20-0.3.1.json`](harness/baseline/2026-10-20-0.3.1.json),
  with the 0.3.0-era record beside it, read in
  [`docs/bench-baseline.md`](docs/bench-baseline.md)
- 2026-10-20 `harness/playground_accept.cjs`: drives the playground in headless
  Chromium — CSV and Parquet uploads with DATE columns, two error paths, a
  cross-file JOIN (refused by name) and a same-file self-join

### Fixed

- 2026-10-20 the browser playground's wasm did not instantiate at all:
  `playground.wasm` imported the wasm host's `__moonbit_fs_unstable` module
  (12 functions) because the lazy-scan refactor routed `scan_string` and
  `scan_bytes` through the same `read_input` as their `scan_file`
  siblings, keeping `@fs` reachable. The page passes no imports, so it threw
  at `WebAssembly.instantiate` and never enabled Run. Scan inputs now carry
  their reader as a function field: a build that only scans in-memory content
  links no filesystem module (imports 12 → 0). CI builds the wasm and fails on
  any import beyond the js-string builtins
- 2026-10-20 `--json` emitted invalid JSON for DATE columns (a bare
  `1992-01-04` token); `SelectResult::to_json` now quotes a DATE as a calendar
  date, matching DuckDB's own JSON output, with a test for the quoted value
  and for `null` inside a DATE column
- 2026-10-20 the playground left the previous result's status on screen when a
  query threw or its result failed to parse; both paths now report `failed`
- 2026-10-20 the pages workflow only rebuilt on `playground/**` changes, so the
  deployed page still served `engine 0.1.0` while main carried 0.3.0. Engine,
  sources, types, sql, catalog, spill and the module manifests now trigger it

## [0.3.0] - 2026-10-20

> First release since `0.1.0` (published 2026-10-03). The `0.2.0` entries
> below record an internal development milestone that was never published on
> its own; everything since `0.1.0` ships in this version.

### Added

- 2026-10-20 the scan layer is lazy and pushdown-aware. A table entry now
  carries either materialized batches or a `ScanSource`, so the catalog needs
  the table's schema and nothing else. `@csv`/`@parquet` registration returns a
  source: `scan_file` keeps the path and re-reads it when a query opens the
  scan, `scan_string`/`scan_bytes` keep the caller's bytes, and typed columns
  exist only while a batch is live. `TableEntry::scan(ScanRequest)` is the new
  read path; `TableEntry::new(schema, batches)` builds a materialized entry as
  before
- 2026-10-20 scanners yield batches instead of a whole table: `BatchStream`
  produces `SCAN_BATCH_ROWS` (4096) row batches, CSV chunked by data rows and
  Parquet one batch per row group (sliced at 4096). An empty table still emits
  one zero-row batch so the engine sees the column layout
- 2026-10-20 column pruning reaches the sources. The engine passes the pruned
  column list it already computed (`table_cols`) as
  `ScanRequest.projection`; CSV parses and Parquet decodes only those columns,
  in projection order, and a zero-column projection (a bare `count(*)`) decodes
  nothing. A column outside the projection can no longer fail a query: a value
  that does not parse is only an error when the query reads that column
- 2026-10-20 Parquet row-group skipping from column-chunk statistics:
  `min_value`/`max_value` and `null_count` decide whether a group can be ruled
  out before a page is read. Bounds are used only when provably usable
  (explicitly inexact bounds, the deprecated signed-order pair on BYTE_ARRAY
  and non-UTF-8 string bounds are all refused), an all-NULL chunk satisfies no
  comparison, and the operator is taken into account (a group whose column is
  constant `c` is skipped for `col <> c`, one whose range is below the constant
  for `col >= c`, and so on). Float columns only prune on the strict
  comparisons: this engine's `Scalar::compare` treats NaN as equal to every
  value, while writers leave NaN out of their statistics, so `=`, `<=`, `>=`
  and `<>` could otherwise drop a group that holds a matching NaN. Hints come
  only from the table's build filter —
  the expression the engine already applies to that table's rows before
  joining it — and the engine still applies its own filter, so a hint can cost
  work but never a row
- 2026-10-20 scan-time filtering: a lazy table's build filter runs on each
  incoming batch while it is drained, so a selective scan never accumulates
  the table's rows (`EXPLAIN` prints the pushed predicates and
  `row groups: N of M read (K skipped by statistics)`). On TPC-H SF0.01, best
  of 5 native debug runs against the previous commit: q1 130→94 ms, q6
  111→67 ms, q3 130→73 ms, `count(*)` over lineitem 105→48 ms, peak RSS
  42→36 MB (q3 46→34 MB). On a generated 1Mi-row, 8-row-group Parquet table:
  `count(*)` 446→57 ms, a filter keeping 6 groups 438→51 ms, one keeping a
  single group 424→47 ms, peak RSS 130→32-39 MB; `harness/bench_scan.py`
  reproduces the comparison

- 2026-10-19 the spill format is MLSPILL3: presence is a bitmap instead of one
  byte per row. A column with no NULLs costs a single mode byte and a nullable
  one `ceil(rows / 8)` bytes, so the bake-off file drops from 5.10 MB to 4.13 MB
  (-19%) with write and read inside noise (125 vs 130 ms, 52 vs 51 ms) and an
  18% lower write RSS; the checksum over every scalar is unchanged. The
  benchmark driver also stopped trusting a hardcoded release path — it locates
  the newest build and refuses to measure a binary older than its sources,
  which is how a first run reported the previous format's numbers
- 2026-10-17 the Parquet reader decodes the remaining page encodings through
  colenc: DELTA_BINARY_PACKED (INT32/INT64), DELTA_LENGTH_BYTE_ARRAY and
  DELTA_BYTE_ARRAY (BYTE_ARRAY), BYTE_STREAM_SPLIT (FLOAT/DOUBLE) and RLE
  boolean values. The encoding gate accepts them, decode errors surface as
  pointed scan errors with the colenc message, and eight small embedded
  fixtures pin each path on every target. colenc is published as
  `superbigcup325/colenc@0.1.0`, so the dependency resolves from the registry
  and a plain checkout builds
- 2026-10-17 a Parquet writer (`sources/parquet/write.mbt`): `write_bytes` and
  `write_file` turn a `TableEntry` into one row group per batch with one PLAIN
  data page per column, encoding page bodies through colenc. Scope matches the
  reader: flat columns, v1 pages, UNCOMPRESSED, INT32/INT64/DOUBLE/
  BYTE_ARRAY/BOOLEAN; a column that holds a NULL anywhere is written OPTIONAL
  with an RLE definition-level section per page, everything else REQUIRED.
  Round-trip tests cover every physical type, NULLs, and multiple row groups;
  DuckDB and pyarrow read the output back
- 2026-10-17 the spill format is MLSPILL2: each column is a dense colenc
  stream (non-null values only) and the writer picks the smallest of PLAIN,
  DELTA_BINARY_PACKED, DELTA_LENGTH_BYTE_ARRAY, DELTA_BYTE_ARRAY and
  DICTIONARY per column, with a sample deciding whether the expensive
  candidates are tried. On SF0.01 lineitem the file drops from 8.08 to
  4.86 MiB; write is 1.46× and read 1.16× the old cost, and both RSS peaks
  fall. `harness/spill_bench.py` reproduces the measurement

### Changed

- 2026-10-20 the Parquet scan no longer concatenates row groups into one
  batch; the reader decodes one chunk of one row group at a time, which is
  what makes streaming and skipping possible. A full 16-column read (the shape
  of q6p's derived table) is 152→142 ms but needs ~3 MB more, because the
  scan's batches are what the engine then materializes
- 2026-10-20 `write_bytes`/`write_file` materialize a lazy entry before
  writing it, so a CSV or Parquet table can be written out without a separate
  copy step
- 2026-10-20 `moonbitlang/x` 0.5.5 → 0.5.6 (the latest `quickcheck`, 0.15.0,
  and `colenc` 0.1.0 are unchanged). Nothing in this tree changes behavior: it
  already uses `moonbitlang/core/encoding/utf8` rather than the now-deprecated
  `@unicode` helpers, and the new `@time` zone loading is unused here. The one
  upstream behavior change that reaches us is
  `@fs.read_file_to_string`, which the CLI uses for `--file <f>`: malformed
  UTF-8 now decodes to U+FFFD instead of dropping the trailing bytes. 200 tests
  on wasm-gc/native/js and the 27-query golden chain are unchanged

- 2026-10-19 `superbigcup325/colenc@0.1.0` is on mooncakes, so the module
  resolves its encoding kernel from the registry like any other dependency: a
  plain checkout builds after `moon update` (the dependency graph downloads on
  the first check/build/test), CI needs no workspace definition, and
  `moon publish --dry-run` validates a clean unpack again. The local-only
  `moon.work` + symlink setup is gone; the README keeps the recipe for editing
  both modules side by side

### Fixed

- 2026-10-20 a Parquet file that is both out of scope and internally
  inconsistent now reports the scope refusal: registering a table ran the
  footer row-count check before the schema gate, so a file with an unsupported
  schema *and* a wrong `num_rows` (apache/parquet-testing's
  `repeated_no_annotation.parquet` carries `num_rows = 0` over a 6-row group)
  failed with "row groups hold 6 rows, the file metadata says 0" instead of
  "nested schemas are not supported". The schema gate runs first again, so
  `harness/check_parquet_corpus.py` is back to 39 read / 29 refused by design /
  0 failing

- 2026-10-20 `harness/compare.py` judged the goldens too loosely in five ways,
  each able to pass a real divergence: an empty cell counted as SQL NULL (so
  `""` and `null` were interchangeable), every line was `strip()`ed (and TPC-H
  comments really do end in spaces, so whitespace at a row's edges was never
  compared), any numeric-looking cell was re-parsed as a double (`"001"`
  matched `"1"`, and 64-bit ids past 2^53 collapsed onto their neighbours),
  non-finite values fell through the tolerance and matched nothing — not even
  themselves — and *all* trailing blank lines were dropped although a
  single-column `""` row is a blank line. Cells now compare exact text first,
  integers exactly, decimals/exponents within 1e-9 with NaN and infinities
  handled as values, and only the terminating newline of the last row is
  dropped. `harness/check_compare.py` pins 27 cases (12 of which fail on the
  old comparator) and `check_all.sh` runs it before diffing a golden; the
  full sweep still passes

## [0.2.0] - 2026-10-16

> Not published on its own: this milestone's changes ship in `0.3.0`.

### Added

- 2026-10-15 Parquet fixtures and their DuckDB goldens (`harness/gen_parquet_fixtures.py`, `harness/data/parquet`): one shape per type and coding mix — every physical type with NULLs, a low-cardinality shape that gets dictionary pages, a two-row-group shape — each generated in the codec variants the reader claims (plain/uncompressed, plain/snappy, dictionary/snappy, dictionary/uncompressed) and diffed in `check_all.sh` (now 27 goldens) so a decode bug fails the same gate the TPC-H answers do; plus fourteen decoder unit tests on hand-built buffers (compact-protocol integers and generic skipping, PLAIN layouts, the hybrid RLE/bit-packed stream including the byte-advance between runs, definition levels, malformed input raising scan errors instead of trapping)
- 2026-10-13 grace hash aggregation — when a GROUP BY's input exceeds the memory budget, the input partitions by the group-key hash into per-partition spill runs and the in-memory aggregate replays one partition at a time — equal keys land in the same partition, so each partition's group rows are final and non-combinable accumulators (median, string_agg, count-distinct) need no merge phase. Low-cardinality keys whose single partition still exceeds the budget fall back to an in-memory pass for that partition (group state cannot be split without a combine phase); over budget without a spill store is a clean error; global aggregates keep the streaming fold. Equivalence pinned by accumulator-family in-memory-vs-spilled tests over NULL-carrying keys, a 20k-row 97-group e2e with median, and a `spillagg` golden check in `check_all.sh`
- 2026-10-13 grace hash join — when a join's inputs exceed the memory budget, both sides partition by the join-key hash into per-partition spill runs and the in-memory join replays one partition at a time (all eight join flavors, the vectorized residual included); over budget without a spill store, key-less cross joins and single-key hash skew are clean errors pointing at `--memory`/`--spill-dir`. Equivalence pinned by seven-flavor in-memory-vs-spilled property tests, a 20k-row many-partition e2e, and a `spilljoin` golden check in `check_all.sh`
- 2026-10-13 CSV ingest pass — unchecked byte and array access in the scan and materialization hot paths (every index is scanner-constructed), a 9-digit int32 parse fast path with the int64 parser as fallback, single byte reads in the field loops and 64k-entry growable offset arrays: SF0.01 lineitem ingest 117 -> 105 ms (A/B, min of 9, scan phase 62 -> 42 ms), the TPC-H bench shifts down accordingly with all 27 goldens byte-identical
- 2026-10-13 join residual vectorization — a non-pushable join predicate (e.g. q19's three-way spanning OR) now decomposes into arms whose single-side conjuncts precompute Kleene true/unknown masks per joined batch pair through the vectorized kernels; only both-side conjuncts stay per-pair against a reduced row. q19 415 -> 162 ms, semantics pinned by the join oracle property, the semi/anti residual e2e battery, the 27 goldens and the duckdb-referenced pushdown fuzzer
- 2026-10-05 hot-path perf arc — typed group indexes for hash aggregation (single int/date keys hash raw `Int64`s, a single string key hashes the column's own strings, composite keys share one reusable `StringBuilder` and materialize the boxed key row once per group instead of once per row); mutable accumulator payloads allocated once per group instead of an enum rebuild per fold step; numeric aggregate inputs (sum/avg/count/stddev/variance/median over `INT`/`FLOAT64`) fold straight from the typed arrays with no boxed `Scalar` per cell; `ORDER BY` sorts the key `ColumnVector`s directly via typed comparators (no boxed decoration, no `Option` per comparison — `Scalar::compare_nn` is the new non-null total compare, also used by the spill merge and min/max folds). SF0.1 Q1 2015 -> ~1.6 s (-21%), SF0.01 Q1 187 -> 136 ms (-27%), raw-table ORDER BY -4% (scan-dominated); all 27 duckdb goldens byte-identical throughout
- 2026-10-04 external sort for ORDER BY — `ExecOptions { budget, spill }` (library `execute_with`, CLI `--memory <n>[K|M|G]` + `--spill-dir`) turns the blocking ORDER BY of non-aggregate queries into sorted runs on disk with a streaming k-way merge feeding projection/DISTINCT/OFFSET/LIMIT, so a LIMIT query's memory is the output window; engine stays fs-free via an injected SpillStore; equivalence tests (tiny budget vs in-memory, five shapes) plus a golden-chain self-consistency check pin correctness
- 2026-10-04 multi-row-group parquet coverage — the SF0.01 parquet export is a single row group, so the reader's multi-group path had never been exercised; `harness/gen_multigroup.py` writes a 4-group x 2048-row fixture with known per-group bounds (the same asset promised upstream in mizchi/parquet#4), four golden queries (full read, bounds-selective filter, aggregate over NULLs, window) run in `check_all.sh` (23 -> 27) and regenerate in both CI workflows
- 2026-10-04 window functions — `row_number()` / `rank()` / `dense_rank()` and every aggregate as `agg(expr) OVER (PARTITION BY ... ORDER BY ...) [NULLS FIRST|LAST]` in the select list, duckdb-diffed over a 29-query battery (ranking ties, NULL partition/order keys, running RANGE frames with peer sharing, GROUP BY interplay via `sum(sum(x)) OVER ()`, DISTINCT/WHERE/LIMIT composition); window markers compose inside item expressions (`v + sum(v) OVER (...)`) and outputs are referenceable by alias; explicit frame clauses and window placement outside the select list are pointed errors
- 2026-10-06 SQL-surface arc (audit gaps closed): `INTERSECT` / `EXCEPT` with ALL / DISTINCT (INTERSECT binds tighter, NULL-safe row comparison, multiset counts); correlated scalar subqueries in the select list; `EXISTS` / `NOT EXISTS` with a HAVING clause; `coalesce` / `nullif` / `greatest` / `least`; `date_trunc` / `date_diff`; `string_agg` (literal separator); `stddev` (+samp/pop), `variance` (+samp/pop), `median` (Welford); `GROUP BY` ordinals; `SELECT` without FROM; bare `NULL` select items as INTEGER
- 2026-10-06 usability arc — standalone-binary startup (`moon build cmd/main --target native --release` + one `install` line puts `moonlake` on PATH; README quickstart), `exec --file <q.sql>` to skip shell quoting entirely (trailing semicolons fine), a pointed hint when data flags are passed without the `exec` subcommand, and a CSV-reader perf pass: per-cell offsets moved from boxed arrays to trimmed FixedArrays — SF0.1 ingest -16% (1374 -> 1150 ms), end-to-end queries -11-18%, maxRSS below the previous baseline (370 -> 353 MB)
- 2026-10-06 verification arc — normalized correctness evidence beyond the SF0.01/1e-9 differential: a randomized vec-vs-scalar differential property over generated typed expression trees (batch sizes 0..4097, mutation-verified), a nested-loop hash-join oracle property across eight join flavors with hostile key distributions (mutation-verified), and `harness/fuzz_pushdown.py` (300 random predicate trees over INNER/LEFT joins, duckdb-refereed; catches WHERE-vs-key placement regressions at LEFT joins — verified by re-introducing the escape bug)
- 2026-10-05 acceptance arc — all 22 TPC-H queries now pass on their official texts (annex parameter values, duckdb-diffed within 1e-9 on SF0.01 and SF0.1; q15 in its sanctioned `WITH` form, see `harness/queries/q15.sql`):
  - `DATE +/- INTERVAL n day|month|year` arithmetic — calendar-aware month/year shifts with day-of-month clamping (`1996-03-31 + interval '1' month` = `1996-04-30`), vectorized, NULL-propagating; an `INTERVAL` literal outside date arithmetic is a bind error, and the TPC-H dbgen precision suffix (`interval '90' day (3)`) parses and is dropped
  - Correlated scalar subqueries (`expr <op> (SELECT agg(...) ... WHERE inner.col = outer.col ...)`) decorrelate into LEFT joins against the inner query grouped by the correlation keys — empty groups NULL-extend and the comparison filters, which is exactly scalar-subquery NULL semantics; the select item must contain an aggregate so groups stay single-row, and nesting works to the depth q20 asks (two correlation columns one level out)
  - Derived-table column alias lists (`FROM (SELECT ...) AS t (a, b)`) rename positionally, arity-checked
  - Non-recursive statement-level `WITH` CTEs: each body re-parses per reference (decorrelation rewrites the AST in place), a CTE name shadows catalog tables and qualifies its columns when no alias is given, later CTEs may reference earlier ones
  - The harness now carries the official TPC-H texts verbatim (`harness/queries/q1..q22.sql`), goldens are generated from the exact bytes moonlake runs, and `check_all.sh` covers 23 goldens (22 + the parquet variant) at any scale via `MOONLAKE_DATA`
- `IS NULL` / `IS NOT NULL` — the first way to test NULL-ness in a WHERE or CASE condition
- Columnar evaluation core (the first vectorization pass): `eval_vec` evaluates expressions over whole batches with typed kernels — column refs shared zero-copy, constant broadcast, same-type int32/int64/float64 arithmetic, three-valued comparison, NULL-aware AND/OR/NOT — with a per-row fallback for the remaining shapes; nine differential tests pin the vector path to the scalar interpreter cell-for-cell
- Filter, projection, aggregation inputs and ORDER BY run on the vector path: masks come from the vectorized boolean result, each output column is one pass, group keys and aggregate inputs are evaluated once per batch, and sort keys are materialized before the comparator runs
- Columnar hash join: both sides concatenate once into single batches, keys evaluate once per side, probe hits collect (left row, build row) integer pairs, and output assembles by typed per-column gathers — no row-major boxed Scalar arrays. NULL-key, residual and LEFT NULL-extension semantics are unchanged
- Bind-time projection pruning: the executor walks the bound plan, drops every unreferenced column from the pipeline (zero-copy vector subsets) and rewrites all column references. TPC-H lineitem scans narrow from 16 columns to the 2–6 the query touches; `--explain` reports the narrowed counts and renders the executed plan. `SELECT *` degenerates to an identity rewrite
- The NyaCSV-backed CSV scan is replaced by a built-in byte-level reader: one pass records per-cell offsets (RFC-4180 dialect — quoted fields with `""` escapes, commas and newlines inside quotes, LF/CRLF terminators, blank lines skipped, BOM stripped), and materialization parses numeric/boolean/date cells straight from their byte ranges, so text columns are the only ones that ever build Strings. Ingest of a 7.4 MB lineitem.csv drops 386 -> 132 ms and every bench query lands at 137–205 ms; the public `scan_string`/`scan_file` API and the wasm playground path are unchanged
- Performance pass over ingest and the join core: CSV cells materialize straight into typed FixedArrays (no boxed Scalar per cell — about a million temporaries per lineitem.csv load at SF0.01), `scan_file` reads bytes and hands them to NyaCSV without a full-file String decode, single-int join keys hash `Int64`s directly instead of building a key string per row, and row selection/batch concatenation copy FixedArray ranges instead of boxed cells. Best-of-3 on one machine: every bench query drops 16–29%, q7 (six-table join) 1040 → 483 ms cumulative against the row-at-a-time build; ingest is now the dominant remaining cost
- `NOT BETWEEN` (postfix form, three-valued negation of BETWEEN)
- `NULL` as a comparison or arithmetic operand: `v = NULL` is UNKNOWN per row, `NOT IN (1, NULL)` is empty, `v + NULL` propagates (the literal takes its type from the other operand; standalone `SELECT NULL` remains unsupported)
- `SELECT *` — expands to every FROM column, each table in FROM order; also inside derived tables

### Changed

- 2026-10-15 the Parquet path is in-house: `sources/parquet` decodes Parquet itself — Thrift compact-protocol footer and page headers, row groups, v1 data pages, PLAIN and dictionary (RLE/bit-packed hybrid) encodings, definition levels, `UNCOMPRESSED` and `SNAPPY` — and `mizchi/parquet`, together with the `mizchi/duckdb` it dragged in, is gone from the dependency graph. Scope is deliberate, not accidental: flat schemas, v1 pages, those codecs and encodings; nested fields, INT96, v2 pages, DELTA/byte-stream-split encodings and the other codecs raise pointed scan errors. Two reasons to write it: the transitive `mizchi/duckdb` shipped a legacy `moon.mod.json` that the current toolchain refuses, which made the module both unpublishable and uninstallable for consumers, and the reader was the last single-maintainer dependency in the graph. Dropping it also let `moonbitlang/quickcheck` move to 0.15.0, whose generator API now lives in `moonbitlang/core/quickcheck`
- 2026-10-13 the in-house SQL front-end (lexer, parser, AST) moved out of `engine` into its own `sql` package: the engine imports `@sql`, the AST types (`Select`, `LExpr`, `AggFn`, …) live at `@sql.*`, and the parser-side `contains_win_marker` helper is now public there; the unused `moonbit-community/sqlparser` dependency was dropped from `moon.mod`; the in-house front-end is the roadmap and sqlparser remains upstream cooperation (visibility issues/PR), not a planned swap-in
- Division and modulo follow DuckDB: `/` is true division and always yields DOUBLE (integer operands promote, `x/0` is ±inf, `0/0` is nan) instead of C-style integer division returning NULL on a zero divisor; `%` follows fmod — the result takes the dividend's sign (`-10.5 % 3` is `-1.5`) — and `x % 0` is NULL. `--json` renders non-finite floats as bare `Infinity`/`NaN` tokens, byte-identical to DuckDB's own JSON output (Python's `json` module round-trips them; strict RFC 8259 parsers do not)

### Fixed

- 2026-10-05 spilled ORDER BY over more than 4096 result rows crashed on a destination overrun: `OutputBuilder::build` hands out capacity-sized vectors (4096) whose length exceeds `row_count`, and `copy_vec_range` copied by vector length, so `final_merge`'s multi-chunk `concat_batches` wrote past the destination (reproduced as a `check_range` trap; the existing spill fixtures stayed under one chunk, masking it). The copy now takes the live row count explicitly; regression tests cover the unit shape and a 5000-row spill merge with and without LIMIT
- 2026-10-04 mixed `ORDER BY output_col, expression` dropped the output-column key whenever an expression key was present (a two-phase sort applied only the expression keys); the binder now resolves both shapes into one written-order key list that sorts jointly — caught by the window-function tests
- 2026-10-06 silent-wrong-answer guards: `sum()` over int64 raises on overflow instead of wrapping (duckdb promotes to HUGEINT); ORDER BY / LIMIT / OFFSET on a UNION branch is a parse error instead of silently truncating that branch
- Playground: loading a CSV in the browser threw `csvText is not defined` (a leftover write to an undeclared variable in the module script), so the drag-and-drop / file-pick path silently never enabled the Run button; only the Parquet path worked. The dead store is gone and the CSV path runs end to end in the browser again
- Explicit `JOIN (SELECT ...) AS t (a, b)` syntax rejected derived tables ("expected table name after FROM") — only comma-list FROM accepted them; the shared table-reference parser now handles subqueries, WITH names, aliases and column lists on both paths
- LEFT JOIN pushdown soundness: WHERE conjuncts referencing only the build (right) table were applied as build filters, dropping build rows and letting NULL-extended probe rows survive a predicate they cannot satisfy (e.g. `... LEFT JOIN orders ON ... WHERE orders.amount > 15` returned the unmatched rows with NULL amounts). They now stay a deferred post-join filter; probe-side pushdown and ON-clause placement are unchanged
- CLI exit codes: every error path (bad SQL, unknown table/column, unreadable file, usage violation) exited 0. Errors now print a single-line message to stderr and exit 1 via a clean process exit (`moonbitlang/x/sys`), so no runtime abort stack trace trails the message; success, `--help` and `--version` remain 0
- Integer overflow wrapped silently: CSV inference and SQL literals shared a parser that ignored the int32 range, so `2147483648` came back as `-2147483648` and past int64 the sign flipped (`9223372036854775807` → `-1`). Integer parsing is now range-checked end to end: CSV columns widen int32 → int64 → float64 (DuckDB-style sniffing), SQL literals widen int32 → int64 → float64, sign-only inputs (`-`) no longer parse as `0`. The float parser's int64 digit accumulator had the same wrap on 20-digit inputs; it now accumulates in double precision (accuracy contract unchanged: 1e-9 relative)
- Keywords `year`/`month`/`day`/`date` were unusable as column names in any form (bare, qualified, aliased) and double-quoted identifiers were not supported at all — a CSV with a `day` column had no way to reference it. The DATE-part keywords now parse as names in name positions, and `"quoted"` identifiers (with `""` escape) reach every other reserved word
- A scalar subquery over zero rows raised a bind error; SQL semantics say it yields NULL, so only more than one row is now an error
- CLI: a `--date-col` naming no scanned column was a silent no-op (exit 0) that surfaced later as a confusing type mismatch — it is now a usage error; words after the quoted SQL silently glued onto the query (a stray word became a table alias) — the SQL must now be one quoted argument; a UTF-8 BOM glued onto the first CSV header cell's name — it is now stripped

## [0.1.0] - 2026-10-03

### Added

- MoonBit module skeleton (`superbigcup325/moonlake`): library package and CLI entry point (`cmd/main`)
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
