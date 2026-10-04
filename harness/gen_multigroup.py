# Generate a multi-row-group parquet fixture with known per-group bounds
# and duckdb's answers as goldens. The TPC-H parquet export is a single
# row group at SF0.01 (60k rows < duckdb's default group size), so the
# reader's multi-group path needs its own fixture: 4 groups x 2048 rows
# (duckdb's minimum ROW_GROUP_SIZE), each group's `v` in a disjoint
# range [grp*100000, grp*100000 + 2047], which is also the shape promised
# to mizchi/parquet#4 as a pushdown test asset.
#
# Usage: uv run --with duckdb python harness/gen_multigroup.py

import pathlib

import duckdb

out = pathlib.Path(__file__).parent / "data" / "multigroup"
out.mkdir(parents=True, exist_ok=True)

N_ROWS = 8192
GROUP = 2048

con = duckdb.connect()
con.execute(
    f"""
    CREATE TABLE multigroup AS
    SELECT
      (i // {GROUP}) AS grp,
      (i // {GROUP}) * 100000 + (i % {GROUP}) AS v,
      date '2024-01-01' + CAST(i // {GROUP} AS INTEGER) AS d,
      CASE WHEN i % 7 = 0 THEN NULL ELSE 's' || (i % 3) END AS s
    FROM range(0, {N_ROWS}) AS t0(i)
    """
)
con.execute(
    f"COPY multigroup TO '{out / 'multigroup.parquet'}' "
    f"(FORMAT PARQUET, ROW_GROUP_SIZE {GROUP})"
)
groups = con.execute(
    f"SELECT num_row_groups FROM "
    f"parquet_file_metadata('{out / 'multigroup.parquet'}')"
).fetchone()[0]
assert groups == N_ROWS // GROUP, f"expected {N_ROWS // GROUP} groups, got {groups}"
print(f"multigroup.parquet: {groups} row groups x {GROUP} rows")


def fmt(v):
    return "null" if v is None else str(v)


QUERIES = {
    # full multi-group read: every row, every type (int, date, nullable string)
    "mgfull": "SELECT grp, v, d, s FROM multigroup ORDER BY v",
    # selective filter: bounds hit groups 2..3 only; a stats-aware scanner
    # would skip groups 0..1 entirely
    "mgfilter": "SELECT v FROM multigroup WHERE v >= 200000 AND v < 300047 ORDER BY v",
    "mgagg": "SELECT grp, sum(v) AS s1, count(s) AS c FROM multigroup GROUP BY grp ORDER BY grp",
    "mgwin": "SELECT grp, v, rn FROM (SELECT grp, v, row_number() OVER (PARTITION BY grp ORDER BY v DESC) AS rn FROM multigroup) WHERE rn <= 2 ORDER BY grp, v",
}

for name, sql in QUERIES.items():
    cur = con.execute(sql)
    lines = ["|".join(col[0] for col in cur.description)]
    for row in cur.fetchall():
        lines.append("|".join(fmt(v) for v in row))
    (out / f"{name}_golden.txt").write_text("\n".join(lines) + "\n")
    print(f"{name}_golden.txt: {len(lines) - 1} rows")
