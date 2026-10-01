# Generate TPC-H data via duckdb's built-in dbgen and store duckdb's
# answers as golden files for moonlake to diff against.
#
# Usage: uv run --with duckdb python harness/gen_tpch.py [sf]

import pathlib
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

# Tables moonlake scans: Q1 (lineitem), Q3 (customer/orders/lineitem),
# Q14 (part/lineitem).
for table in ["customer", "orders", "lineitem", "part"]:
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
        return ""
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


Q6 = """
select sum(l_extendedprice * l_discount) as revenue
from lineitem
where
    l_shipdate >= date '1994-01-01'
    and l_shipdate < date '1995-01-01'
    and l_discount between 0.02 and 0.04
    and l_quantity < 24
"""

Q1 = """
select
    l_returnflag,
    l_linestatus,
    sum(l_quantity) as sum_qty,
    sum(l_extendedprice) as sum_base_price,
    sum(l_extendedprice * (1 - l_discount)) as sum_disc_price,
    sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)) as sum_charge,
    avg(l_quantity) as avg_qty,
    avg(l_extendedprice) as avg_price,
    avg(l_discount) as avg_disc,
    count(*) as count_order
from lineitem
where l_shipdate <= date '1998-09-02'
group by l_returnflag, l_linestatus
order by l_returnflag, l_linestatus
"""

Q3 = """
select
    l_orderkey,
    sum(l_extendedprice * (1 - l_discount)) as revenue,
    o_orderdate,
    o_shippriority
from
    customer,
    orders,
    lineitem
where
    c_mktsegment = 'BUILDING'
    and c_custkey = o_custkey
    and l_orderkey = o_orderkey
    and o_orderdate < date '1995-03-15'
    and l_shipdate > date '1995-03-15'
group by
    l_orderkey,
    o_orderdate,
    o_shippriority
order by
    revenue desc,
    l_orderkey
limit 10
"""

Q14 = """
select
    100.00 * sum(case
        when p_type like 'PROMO%'
            then l_extendedprice * (1 - l_discount)
        else 0
    end) / sum(l_extendedprice * (1 - l_discount)) as promo_revenue
from
    lineitem,
    part
where
    l_partkey = p_partkey
    and l_shipdate >= date '1995-09-01'
    and l_shipdate < date '1995-10-01'
"""

golden("q6", Q6)
golden("q1", Q1)
golden("q3", Q3)
golden("q14", Q14)

# Q6 over the parquet-shaped lineitem (doubles instead of decimals):
# the golden for the parquet scan adapter chain. The CASTS subquery is
# byte-identical to the exported parquet, so duckdb computes the same
# numbers moonlake will see.
Q6P = Q6.replace("from lineitem", f"from ({CASTS}) as li")
golden("q6p", Q6P)
