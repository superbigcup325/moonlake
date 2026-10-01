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


QUERIES = {
    "q6": """
select sum(l_extendedprice * l_discount) as revenue
from lineitem
where
    l_shipdate >= date '1994-01-01'
    and l_shipdate < date '1995-01-01'
    and l_discount between 0.02 and 0.04
    and l_quantity < 24
""",
    "q1": """
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
""",
    "q3": """
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
""",
    "q14": """
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
""",
    "q5": """
select
    n_name,
    sum(l_extendedprice * (1 - l_discount)) as revenue
from
    customer,
    orders,
    lineitem,
    supplier,
    nation,
    region
where
    c_custkey = o_custkey
    and l_orderkey = o_orderkey
    and l_suppkey = s_suppkey
    and c_nationkey = n_nationkey
    and n_regionkey = r_regionkey
    and r_name = 'ASIA'
    and s_nationkey = n_nationkey
    and o_orderdate >= date '1994-01-01'
    and o_orderdate < date '1995-01-01'
group by
    n_name
order by
    revenue desc
""",
    "q7": """
select
    supp_nation,
    cust_nation,
    l_year,
    sum(volume) as revenue
from
    (
        select
            n1.n_name as supp_nation,
            n2.n_name as cust_nation,
            extract(year from l_shipdate) as l_year,
            l_extendedprice * (1 - l_discount) as volume
        from
            supplier,
            lineitem,
            orders,
            customer,
            nation n1,
            nation n2
        where
            s_suppkey = l_suppkey
            and o_orderkey = l_orderkey
            and c_custkey = o_custkey
            and s_nationkey = n1.n_nationkey
            and c_nationkey = n2.n_nationkey
            and (
                (n1.n_name = 'FRANCE' and n2.n_name = 'GERMANY')
                or (n1.n_name = 'GERMANY' and n2.n_name = 'FRANCE')
            )
            and l_shipdate between date '1995-01-01' and date '1996-12-31'
    ) as shipping
group by
    supp_nation,
    cust_nation,
    l_year
order by
    supp_nation,
    cust_nation,
    l_year
""",
    "q8": """
select
    o_year,
    sum(case
        when nation = 'BRAZIL' then volume
        else 0
    end) / sum(volume) as mkt_share
from
    (
        select
            extract(year from o_orderdate) as o_year,
            l_extendedprice * (1 - l_discount) as volume,
            n2.n_name as nation
        from
            part,
            supplier,
            lineitem,
            orders,
            customer,
            nation n1,
            nation n2,
            region
        where
            p_partkey = l_partkey
            and s_suppkey = l_suppkey
            and l_orderkey = o_orderkey
            and o_custkey = c_custkey
            and c_nationkey = n1.n_nationkey
            and n1.n_regionkey = r_regionkey
            and r_name = 'AMERICA'
            and s_nationkey = n2.n_nationkey
            and n2.n_name = 'BRAZIL'
            and o_orderdate between date '1995-01-01' and date '1996-12-31'
            and p_type = 'ECONOMY ANODIZED STEEL'
    ) as all_nations
group by
    o_year
order by
    o_year
""",
    "q10": """
select
    c_custkey,
    c_name,
    sum(l_extendedprice * (1 - l_discount)) as revenue,
    c_acctbal,
    n_name,
    c_address,
    c_phone,
    c_comment
from
    customer,
    orders,
    lineitem,
    nation
where
    c_custkey = o_custkey
    and l_orderkey = o_orderkey
    and o_orderdate >= date '1993-10-01'
    and o_orderdate < date '1994-01-01'
    and l_returnflag = 'R'
    and c_nationkey = n_nationkey
group by
    c_custkey,
    c_name,
    c_acctbal,
    c_phone,
    n_name,
    c_address,
    c_comment
order by
    revenue desc
limit 20
""",
    "q12": """
select
    l_shipmode,
    sum(case
        when o_orderpriority = '1-URGENT'
            or o_orderpriority = '2-HIGH'
            then 1
        else 0
    end) as high_line_count,
    sum(case
        when o_orderpriority <> '1-URGENT'
            and o_orderpriority <> '2-HIGH'
            then 1
        else 0
    end) as low_line_count
from
    orders,
    lineitem
where
    o_orderkey = l_orderkey
    and l_shipmode in ('MAIL', 'SHIP')
    and l_commitdate < l_receiptdate
    and l_shipdate < l_commitdate
    and l_receiptdate >= date '1994-01-01'
    and l_receiptdate < date '1995-01-01'
group by
    l_shipmode
order by
    l_shipmode
""",
    "q13": """
select
    c_count,
    count(*) as custdist
from
    (
        select
            c_custkey,
            count(o_orderkey) as c_count
        from
            customer
            left outer join orders on
                c_custkey = o_custkey
                and o_comment not like '%special%requests%'
        group by
            c_custkey
    ) as c_orders
group by
    c_count
order by
    custdist desc,
    c_count asc
""",
    "q19": """
select
    sum(l_extendedprice * (1 - l_discount)) as revenue
from
    lineitem,
    part
where
    (
        p_partkey = l_partkey
        and p_brand = 'Brand#12'
        and p_container in ('SM CASE', 'SM BOX', 'SM PACK', 'SM PKG')
        and l_quantity >= 1
        and l_quantity <= 11
        and p_size between 1 and 5
        and l_shipmode in ('AIR', 'AIR REG')
        and l_shipinstruct = 'DELIVER IN PERSON'
    )
    or (
        p_partkey = l_partkey
        and p_brand = 'Brand#23'
        and p_container in ('MED BAG', 'MED BOX', 'MED PKG', 'MED PACK')
        and l_quantity >= 10
        and l_quantity <= 20
        and p_size between 1 and 10
        and l_shipmode in ('AIR', 'AIR REG')
        and l_shipinstruct = 'DELIVER IN PERSON'
    )
    or (
        p_partkey = l_partkey
        and p_brand = 'Brand#34'
        and p_container in ('SM CASE', 'SM BOX', 'SM PACK', 'SM PKG')
        and l_quantity >= 20
        and l_quantity <= 30
        and p_size between 1 and 15
        and l_shipmode in ('AIR', 'AIR REG')
        and l_shipinstruct = 'DELIVER IN PERSON'
    )
""",
    "q11": """
select
    ps_partkey,
    sum(ps_supplycost * ps_availqty) as value
from
    partsupp,
    supplier,
    nation
where
    ps_suppkey = s_suppkey
    and s_nationkey = n_nationkey
    and n_name = 'GERMANY'
group by
    ps_partkey
having
    sum(ps_supplycost * ps_availqty) > (
        select
            sum(ps_supplycost * ps_availqty) * 0.0001
        from
            partsupp,
            supplier,
            nation
        where
            ps_suppkey = s_suppkey
            and s_nationkey = n_nationkey
            and n_name = 'GERMANY'
    )
order by
    value desc
""",
    "q16": """
select
    p_brand,
    p_type,
    p_size,
    count(distinct ps_suppkey) as supplier_cnt
from
    partsupp,
    part
where
    p_partkey = ps_partkey
    and p_brand <> 'Brand#45'
    and p_type not like 'MEDIUM POLISHED%'
    and p_size in (49, 14, 23, 45, 19, 3, 36, 9)
    and ps_suppkey not in (
        select
            s_suppkey
        from
            supplier
        where
            s_comment = '%Customer%Complaints%'
    )
group by
    p_brand,
    p_type,
    p_size
order by
    supplier_cnt desc,
    p_brand,
    p_type,
    p_size
""",
    # Q15 rewritten for the moonlake subset: the CTE is inlined as a
    # derived table (twice) and the max becomes a scalar subquery over
    # the second copy. Same numbers as the official WITH form.
    "q15r": """
select
    s_suppkey,
    s_name,
    s_address,
    s_phone,
    total_revenue
from
    supplier,
    (
        select
            l_suppkey as supplier_no,
            sum(l_extendedprice * (1 - l_discount)) as total_revenue
        from
            lineitem
        where
            l_shipdate >= date '1996-01-01'
            and l_shipdate < date '1996-04-01'
        group by
            l_suppkey
    ) as revenue0
where
    s_suppkey = supplier_no
    and total_revenue = (
        select
            max(total_revenue)
        from
            (
                select
                    l_suppkey as supplier_no,
                    sum(l_extendedprice * (1 - l_discount)) as total_revenue
                from
                    lineitem
                where
                    l_shipdate >= date '1996-01-01'
                    and l_shipdate < date '1996-04-01'
                group by
                    l_suppkey
            ) as revenue0
    )
order by
    s_suppkey
""",
}

for name, sql in QUERIES.items():
    golden(name, sql)
