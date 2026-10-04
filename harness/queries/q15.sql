-- TPC-H Q15 (Top Supplier) in the sanctioned WITH form: the official
-- text materializes a view (CREATE VIEW ...; SELECT ...; DROP VIEW ...) and
-- the engine executes single SELECT statements; this is the standard modern
-- spelling of the same query and duckdb answers it identically.
with revenue1 as (
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
)
select
    s_suppkey,
    s_name,
    s_address,
    s_phone,
    total_revenue
from
    supplier,
    revenue1
where
    s_suppkey = supplier_no
    and total_revenue = (
        select
            max(total_revenue)
        from
            revenue1
    )
order by
    s_suppkey
