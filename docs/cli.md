# The `moonlake` command

Two subcommands: `exec` runs one query over registered files, `write` converts a
registered table to Parquet. Build the binary from a checkout with
`moon build cmd/main --target native --release` (the artifact is
`_build/native/release/build/cmd/main/main.exe`), or run the same code with
`moon run cmd/main -- …`.

## `moonlake exec`

### Tables

- `--csv <path>` registers one CSV file as one table, one flag per table
- `--parquet <path>` scans a Parquet file. An *unannotated* file whose DATE
  columns are stored as epoch days is declared with `--date-col`; a file that
  carries the standard DATE annotation needs nothing
- a `--csv` argument may carry one `*`, and only in its final path segment
  (`data/part-*.csv`): the matches are read as one table, named after the file
  stem when there is one match and after the pattern's own stem when there are
  several (a bare `*.csv` is refused, since it leaves no name)

### The query

The SQL is one quoted argument or a file via `--file` (no shell quoting, a
trailing semicolon is fine). With no `--csv`/`--parquet` at all the query runs
against an empty catalog, so `moonlake exec "SELECT 1 + 1"` needs no data file.

### Output

- text, one row per line, `|` between columns
- `--json` emits machine-readable output: one JSON array per result, printed as
  it arrives. The opening `[` starts the first line and each batch is one more
  line, so a scan never has to become one string (a result that fits one batch
  is a single line, byte-identical to the encoding of the whole array). SQL NULL
  is `null`, DATE is a quoted calendar date, and the non-finite doubles JSON
  cannot spell are the strings `"Infinity"`, `"-Infinity"` and `"NaN"`
- text and JSON output are both consumed batch by batch, so neither accumulates
  the result
- a query that fails after printing rows leaves those rows on stdout, the
  message on stderr and exit status 1

### Plans

`--explain` prints the physical plan. `--analyze` reports what the run did:
stage timings and, under a budget, the spill counters listed below.

## Larger than memory

`exec --memory <n>[K|M|G] [--spill-dir <dir>]` bounds the blocking operators.

- `ORDER BY` becomes sorted runs whose final merge streams into
  projection/DISTINCT/OFFSET/LIMIT (a LIMIT query holds only its output window)
- a hash join partitions the sides that do not fit, splits an over-budget
  partition again, and swaps the sides when the table side is the one that
  overflows (0.6.1, verification §82)
- a `GROUP BY` partitions its input and aggregates each partition one spill file
  at a time, while an `ORDER BY` over a `GROUP BY` sorts that grouped result in
  memory once the fold ends, since a grouped result is not input and the budget
  does not bound it (verification §45, §50). So a hot group key is fine, while a
  single join key holding most of a side is refused with that reason, unless the
  query is a shape the fold accepts and the join is never collected
  (verification §49)

`--analyze` under a budget reports `spill runs` / `spill files` /
`spill bytes written` / `spill bytes read` (plus `fold segments` when a budgeted
`GROUP BY` splits its fold instead of partitioning), and the CLI removes its
temp directory on both exit paths.

A query spills into its own `moonlake-spill-<n>` subdirectory of `--spill-dir`
(or `TMPDIR`), so two processes may share one `--spill-dir` without touching each
other's runs, and a caller's own files there are never read or deleted. A
subdirectory is claimed with an `owner` marker naming the pid, the boot id and
the pid's start time, so a run killed outright no longer leaks: the next query
removes that subdirectory when the marker proves its owner is gone (another boot,
a pid that no longer exists, a pid whose start time changed), and keeps — and
reports — any directory it cannot judge, such as one with no marker.

The library form is `execute_with` with `ExecOptions` and a `SpillStore`: the
engine itself never touches the filesystem.

## `moonlake write`

`moonlake write --csv in.csv --out out.parquet [--snappy]` converts a registered
table to Parquet.

- it refuses an `--out` that is one of its own inputs (the write would replace
  the source)
- a failed write is reported as `sql error (execute):` and leaves any previous
  file intact
- a write killed outright can leave a `<out>.moonlake-tmp-<pid>-<n>` file beside
  the target — the publication is a `rename`, so that leftover is a partial temp
  file, never a half-written `--out`

The writer's format scope and its streaming behaviour are in
[sources.md](sources.md).
