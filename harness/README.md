# TPC-H cross-validation harness (dev only, not part of the shipped package)

Generates TPC-H data with duckdb's built-in dbgen, exports CSV for
moonlake to scan, and stores duckdb's own query results as golden
files. CI (and local `compare.py`) diffs moonlake output against the
golden files with a 1e-9 relative tolerance on floats.

## Usage

```bash
uv run --with duckdb python harness/gen_tpch.py          # SF 0.01
uv run --with duckdb python harness/gen_tpch.py 0.01     # explicit SF
```

Outputs land in `harness/data/sf<sf>/`:

- `customer.csv` / `orders.csv` / `lineitem.csv` / `part.csv` — the
  tables the golden queries scan
- `lineitem.parquet` — lineitem with decimals cast to double, for the
  parquet scan chain
- `q6_golden.txt`, `q1_golden.txt`, `q3_golden.txt`, `q14_golden.txt`,
  `q6p_golden.txt` — duckdb's answers, pipe-separated with a header
  line (same shape as the moonlake CLI output)

## Compare

`compare.py` skips the header (engines label columns differently) and
compares cells in order: floats with a 1e-9 relative tolerance,
everything else exact; empty and "null" both count as SQL NULL.

```bash
moon run cmd/main -- exec --csv harness/data/sf001/lineitem.csv \
  "$(cat harness/queries/q6.sql)" > /tmp/out.txt
python3 harness/compare.py harness/data/sf001/q6_golden.txt /tmp/out.txt
```

`check_all.sh` runs every golden query through the CLI and diffs each
against its golden file; multi-table queries pass one `--csv` per
table, and the parquet chain passes `--parquet` plus the DATE columns
via `--date-col`. CI runs the same script after regenerating the data
from scratch (job `tpch`).
