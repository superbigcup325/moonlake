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

- `lineitem.csv` (W1 scans this table only)
- `q6_golden.txt` — duckdb's revenue for the Q6 query

## Compare

```bash
moon run cmd/main -- exec --csv harness/data/sf001/lineitem.csv \
  "$(cat harness/queries/q6.sql)"
python3 harness/compare.py harness/data/sf001/q6_golden.txt <moonlake-output>
```

`compare.py` reads the second line of the moonlake output (header is
the first line) and the golden value, applying the tolerance above.
