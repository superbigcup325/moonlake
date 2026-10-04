# Generate TPC-H data via duckdb's built-in dbgen and store duckdb's
# answers as golden files for moonlake to diff against.
#
# Usage: uv run --with duckdb python harness/gen_tpch.py [sf]

import pathlib
import re
import sys
from datetime import date
from decimal import Decimal

import duckdb

sf = sys.argv[1] if len(sys.argv) > 1 else "0.01"
tag = f"sf{sf.replace('.', '')}"
out = pathlib.Path(__file__).parent / "data" / tag
out.mkdir(parents=True, exist_ok=True)

con = duckdb.connect()
con.execute("CALL dbgen(sf = ?)", [float(sf)])

# All tables the golden queries scan.
for table in [
    "customer",
    "orders",
    "lineitem",
    "part",
    "supplier",
    "nation",
    "region",
    "partsupp",
]:
    con.execute(f"COPY {table} TO '{out / f'{table}.csv'}' (HEADER, DELIMITER ',')")
    rows = con.execute(f"SELECT count(*) FROM {table}").fetchone()
    print(f"{table} rows: {rows[0]}")

# Parquet export of lineitem for the parquet scan adapter. Decimals cast
# to DOUBLE (the upstream writer/reader surface the engine maps);
# dates keep the parquet DATE logical type, which the reader surfaces as
# int32 epoch days and moonlake lifts via --date-col.
CASTS = """SELECT
    l_orderkey, l_partkey, l_suppkey, l_linenumber,
    CAST(l_quantity AS DOUBLE) AS l_quantity,
    CAST(l_extendedprice AS DOUBLE) AS l_extendedprice,
    CAST(l_discount AS DOUBLE) AS l_discount,
    CAST(l_tax AS DOUBLE) AS l_tax,
    l_returnflag, l_linestatus,
    l_shipdate, l_commitdate, l_receiptdate,
    l_shipinstruct, l_shipmode, l_comment
FROM lineitem"""
con.execute(f"COPY ({CASTS}) TO '{out / 'lineitem.parquet'}' (FORMAT PARQUET)")
print("lineitem.parquet written")


def fmt(v) -> str:
    if v is None:
        return "null"  # explicit: a bare empty line would be ambiguous
    if isinstance(v, Decimal):
        v = float(v)
    if isinstance(v, date):
        return v.isoformat()
    if isinstance(v, float):
        return repr(v)
    return str(v)


def golden(name: str, sql: str) -> None:
    cur = con.execute(sql)
    rows = cur.fetchall()
    lines = ["|".join(d[0] for d in cur.description)]
    for row in rows:
        lines.append("|".join(fmt(v) for v in row))
    (out / f"{name}_golden.txt").write_text("\n".join(lines) + "\n")
    print(f"{name} golden rows: {len(rows)}")


# Every golden query lives in harness/queries/ as the official TPC-H
# text (annex parameter values substituted; dbgen directives stripped;
# q15 in its sanctioned WITH form — see that file's header). Goldens
# are generated from the exact same text moonlake runs.
QUERIES = {}
qdir = pathlib.Path(__file__).parent / "queries"
for f in sorted(qdir.glob("q*.sql")):
    QUERIES[f.stem] = f.read_text()

QUERIES["q6p"] = re.sub(r"from\s+lineitem", f"from ({CASTS}) as li", QUERIES["q6"])

for name, sql in QUERIES.items():
    golden(name, sql)
