# Out-of-core survey: how each system handles data larger than memory

> 2026-10-04. The goal is not to settle a design but to map how each system
> handles "query data exceeds memory", so that moonlake's spill design doc can
> be scoped. Background numbers are in `docs/verification.md` §5: memory grows
> near-linearly with data, SF0.1 ≈ 353 MB, extrapolating to SF1.0 ≈ 3.5 GB —
> under the current architecture, exceeding memory means the query cannot run.

## 1. Six systems at a glance

**DuckDB** (in-process OLAP, C++). `memory_limit` (a soft limit, ~80% of
physical RAM by default) plus `temp_directory`. When over budget, operators
spill intermediate blocks and keep going: radix-partitioned parallel
out-of-core hash join, hash aggregation (partitions written to disk, merged on
exit), external merge sort, window. Key defaults: a **file-backed database has
spill on by default** (temp dir = a `.tmp` beside the database file); a
**`:memory:` database has an empty `temp_directory` by default = no spilling,
an error once over budget**, unless a directory is given explicitly. External
CSV/Parquet scans stream and are not materialized wholesale; a persistent
database keeps base tables on disk behind a buffer manager.

**PostgreSQL** (server, row-store iterators). The textbook shape: every
execution node is bounded by `work_mem`, and degrades inside the operator once
exceeded — hash join splits into batches (build side spilled by hash, probe
aligned to the same batch), sort generates tuplesort runs + a multi-way merge,
hash agg partitions. Temp data lands in `base/pgsql_tmp`. The budget is a
per-node session setting; there is no global accounting.

**ClickHouse** (server, column store). Also self-managed per operator:
`max_bytes_before_external_sort` / `max_bytes_before_external_group_by` are
**per-operator** settings (not a global limit); once exceeded, sort/aggregation
state is written to `tmp_path` (a configurable disk policy) and merged on exit.
Aggregation spills partial state above the threshold and merges — the same
family as Postgres, varied by being configurable per operator.

**Apache DataFusion** (in-process columnar, Rust — architecturally closest to
moonlake). MemoryPool is **reservation-based**: operators ask for memory, and
when the pool cannot grant it they spill and retry; the pool offers
fair/untracked/greedy strategies. Spilling goes through a uniform
SpillManager/DiskManager abstraction, and a spill file is just Arrow IPC
(compression supported from 49.0). Its maturity trajectory is worth copying:
**sort landed first** (50.0 claims "almost all sort queries no longer OOM"),
while **hash join spill was still a proposal as of 2025-08** (#17267);
aggregation's intermediate merge can stay on disk until the final replay.

**Polars** (in-process DataFrame, Rust). A third path: don't change operators,
change the execution model. The new streaming engine (default since Polars 2.0)
advances the whole pipeline in bounded batches, so memory is bounded by
construction; running past memory relies on the streaming itself with spill as
a backstop. Its maturity lessons are equally valuable: the multi-join-chain
memory-accumulation issue (#24206) is still open, and early community feedback
that the streaming engine "OOMs earlier than DuckDB/DataFusion" shows the
engineering depth this path demands.

**SQLite** (embedded, page store). The odd one out: there is no notion of
operator-level spill — all data (including temp B-trees and sort intermediates)
is pages, managed uniformly by the pager; when the cache falls short, dirty
pages are written back and temp objects go to a temp file (`temp_store` =
default/file/memory). The cost is that a page-based storage engine is a
prerequisite — which is itself its product shape.

## 2. Shape comparison

| | Trigger model | Spill location | Operators covered | Needs a storage engine? | Prerequisite refactor |
|---|---|---|---|---|---|
| DuckDB | global soft limit | temp directory | join/agg/sort/window | yes for persistent DBs (buffer manager) | none (in-memory DB can spill too) |
| PostgreSQL | per-node work_mem | pgsql_tmp | join/sort/agg | no | none |
| ClickHouse | per-operator setting | tmp_path / disk policy | sort/agg | no | none |
| DataFusion | MemoryPool reservations | SpillManager (Arrow IPC) | sort (mature) → agg → join | no | none |
| Polars streaming | bounded batches + streaming scheduler | streaming framework backstop | whole pipeline | no | **the entire execution model** |
| SQLite | unified page cache | pager write-back | everything (implicit) | **yes** (the page engine is the premise) | everything |

Reduced to four shapes:

- **A. Unified page cache** (SQLite, DuckDB persistent DBs): operators are
  unaware; the storage layer absorbs it. Requires a page-based storage engine —
  i.e. becoming a database first.
- **B. Operator-managed spill** (Postgres, ClickHouse, DuckDB in-memory,
  DataFusion): blocking operators partition/merge on their own once over
  budget, with a budget interface and a temp-file abstraction injected. No
  storage engine needed; can land incrementally.
- **C. Bounded streaming** (Polars' new engine): rewrite the execution model
  as a bounded streaming pipeline, with spill only as a backstop. Highest
  ceiling, largest refactor, most maturity pitfalls.
- **D. Pure in-memory + explicit failure** (the default of every in-memory DB,
  and moonlake's current state): honest semantics, the fallback state of A/B/C,
  not a destination.

## 3. Where moonlake lands (constraints → shape)

moonlake's constraints: in-process library + native CLI dual release; the
wasm/js playground must compile (the engine package carrying zero fs
dependencies is existing discipline); pure columnar batches; eager full
materialization; an explicit "not a database" boundary claim.

- **Shape A is out**: a page-based storage engine violates the product boundary,
  and the wasm target would have to carry it too.
- **Shape C is out (for now)**: overturning the eager execution model amounts to
  rewriting the engine; Polars' current state shows this path's maturity curve
  is measured in years.
- **Shape B is the only natural landing spot**: a budget handle + a temp-file
  abstraction injected (the engine stays fs-free, the native CLI injects the
  real implementation, wasm falls back to shape D "explicit failure") —
  DuckDB's in-memory semantics ("don't spill by default, only when a directory
  is given") are naturally isomorphic to this dual target.
- **The milestone order already has backing**: DataFusion took years to make
  sort spill mature, and hash join is still a proposal in 2025. moonlake's order
  of sort → hash join → aggregation → set operations matches it; that is not
  conservatism, it is reality.
- **A moonlake-specific problem for the spill format**: DataFusion reuses Arrow
  IPC, but moonlake has no ready-made columnar serialization. Candidates:
  (a) a small hand-written batch serializer (controllable, dependency-free);
  (b) **use mizchi/parquet's writer/reader directly as the spill format** — zero
  new serialization code, columnar compression for free, and a spill run maps
  naturally onto a row group (once upstream gains #4's row-group-level reading,
  spill replay benefits too); the cost is a trade-off against writer maturity
  and encoding overhead. This is the real decision point in the design doc.
- **Base-table materialization is a problem independent of shape B**: even if
  every operator spills, the scan layer materializing a whole table remains the
  memory hog. The design doc must decide the scope of scan laziness (external
  files supplied batch-by-batch is enough; catalog semantics unchanged) or
  settle first for "operator spill + large tables scanned multiple times within
  a query" as a transition.

## 3.5 Spill-format bake-off (2026-10-04, measured on branches)

Decision point ② from §4 no longer rests on paper: two branches each
implemented the same spill-format interface, on the same workload (SF0.01
lineitem, 60175 rows × 16 columns, covering int/date/string/double and NULL),
with the same two-phase driver (write scans the CSV and serializes; read
deserializes and recomputes an FNV checksum over the scalar stream; write/read
checksums matching across arms = semantic equivalence), best-of-3 wall clock
plus isolated `getrusage` maxRSS (release build, the process including the CSV
scan baseline):

| Branch | write | read | file | write RSS | read RSS |
|---|---|---|---|---|---|
| `spill/raw-fmt` (hand-written MLSPILL1) | 158 ms | 114 ms | 8.48 MB | 66.4 MB | 32.2 MB |
| `spill/parquet-fmt` (mizchi/parquet wrapper) | 248 ms | 125 ms | 7.53 MB | 48.6 MB | 32.6 MB |

Subtracting the shared scan baseline (~115 ms), the format's own write cost is
~43 ms vs 133 ms — the parquet arm ~3×, because upstream's write path is
row-oriented only (`new_parquet_file` takes `Array[Array[Value]]`; the columnar
structure cannot be built outside the package), paying a column→row transcode
per batch.

Harder than the numbers are two upstream facts unearthed along the way (0.2.2):

1. **The writer's type coverage is Int32 | Int64 | String | Binary.** Double and
   Boolean simply cannot be written; the parquet arm only round-tripped by
   hacking bit patterns (Double→Int64 IEEE bits, Bool→Int32 0/1) — until
   upstream adds the types, "reuse the writer" is not slow, it is semantically
   invalid.
2. The read path (`read_bytes_columnar`) is columnar and works well, and the
   file is 11% smaller (string compression); combined with mizchi/parquet#4
   landing row-group-level reads, a spill run aligns naturally with a row
   group — **kept as a future re-evaluation item, not now**.

Verdict: **the hand-written compact format wins** — 1.6× faster writes, equal
reads, zero type hacks, no envelope, and the hot path free of upstream version
dependencies. Both branches are retained as evidence and as a future
re-evaluation baseline.

> 2026-10-17 addendum: MLSPILL1 has been replaced by MLSPILL2, which encodes
> each column with colenc and picks the smallest of PLAIN, DELTA_BINARY_PACKED,
> DELTA_LENGTH_BYTE_ARRAY, DELTA_BYTE_ARRAY and DICTIONARY. Measured on the
> same workload (SF0.01 lineitem, 60,175 rows), best-of-3, release build, same
> machine, with `harness/spill_bench.py` (write includes the CSV scan; RSS is
> isolated per process):
>
> | format | write | read | file | write RSS | read RSS |
> |---|---|---|---|---|---|
> | MLSPILL1 (hand-written) | 78.7 ms | 38.8 ms | 8.08 MiB | 66.4 MiB | 32.4 MiB |
> | MLSPILL2 (colenc encodings) | 115.0 ms | 44.9 ms | 4.86 MiB | 48.6 MiB | 28.5 MiB |
>
> The file shrinks 40% and both RSS peaks drop. Writes are 1.46× slower because
> a column may be encoded two or three times while the smallest candidate is
> chosen; a 4096-value sample decides whether the expensive candidates
> (dictionary, DELTA_BYTE_ARRAY) are worth trying at all. This table supersedes
> the raw-arm rows above for present-day comparisons — the older numbers came
> from a different toolchain snapshot. Null flags are still one byte per row;
> bit-packing them is the next size lever if it matters.

> 2026-10-15 addendum: the parquet dependency has been removed from the project
> (a stale upstream artifact manifest blocked publishing and installation; we
> switched to an in-house decoder, see CHANGELOG 0.2.0). So if "re-evaluate
> parquet as a spill format later" is ever revived, the write path would have to
> be in-house too — the comparison numbers and upstream facts in this section
> still hold, but the premise has changed.

## 4. Hand-off points for the design doc

When drafting the dedicated design doc, start from three decision points:
① the shape of the budget injection interface (DataFusion's reservation model
vs a moonlake simplification of DuckDB's global soft limit); ② the spill file
format (hand-written vs parquet reuse); ③ the minimal scope of scan laziness.
Verification strategy follows repo convention: force spilling with a small
budget and compare against TPC-H goldens bit-for-bit + a spill/ memory
equivalence property + a `measure.py` maxRSS ceiling check.
