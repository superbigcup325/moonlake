# Generate TPC-H data via duckdb's built-in dbgen and store duckdb's
# answers as golden files for moonlake to diff against.
#
# Usage: uv run --with duckdb python harness/gen_tpch.py [sf]

import pathlib
import sys

import duckdb

sf = sys.argv[1] if len(sys.argv) > 1 else "0.01"
tag = f"sf{sf.replace('.', '')}"
out = pathlib.Path(__file__).parent / "data" / tag
out.mkdir(parents=True, exist_ok=True)

con = duckdb.connect()
con.execute("CALL dbgen(sf = ?)", [float(sf)])

# W1 scans lineitem only; more tables ship with the join milestones.
con.execute(
    f"COPY lineitem TO '{out / 'lineitem.csv'}' (HEADER, DELIMITER ',')"
)
rows = con.execute("SELECT count(*) FROM lineitem").fetchone()
print(f"lineitem rows: {rows[0]}")

Q6 = """
select sum(l_extendedprice * l_discount) as revenue
from lineitem
where
    l_shipdate >= date '1994-01-01'
    and l_shipdate < date '1995-01-01'
    and l_discount between 0.02 and 0.04
    and l_quantity < 24
"""
revenue = con.execute(Q6).fetchone()[0]
(out / "q6_golden.txt").write_text(f"{revenue}\n")
print(f"q6 golden revenue: {revenue}")
