# Generate the small Parquet fixtures the in-house reader's tests decode,
# plus the duckdb goldens the CLI checks diff against.
#
# These are deliberately tiny (KB, not MB) so they can live in the repository
# next to the golden answers, and they cover the physical types and the
# codec/encoding combinations the reader claims to support. The TPC-H
# exports in harness/data/sf001 and sf01 come from gen_tpch.py instead.
#
# Layout: one directory per *shape*, one directory per codec variant of that
# shape. The table name the CLI registers is the file stem, so every fixture
# is called t.parquet and the queries in harness/queries reference "t"; the
# golden lives in the shape directory, and every variant points its --parquet
# at its own t.parquet while diffing against that one golden.
#
# Usage: python3 harness/gen_parquet_fixtures.py   (needs duckdb, like gen_tpch.py)

from __future__ import annotations

import pathlib
from datetime import date
from decimal import Decimal

import duckdb

root = pathlib.Path(__file__).resolve().parent / "data" / "parquet"

con = duckdb.connect()

# 'all': one column per physical type the reader supports, plus a nullable
# column and a DATE column that reaches the engine through --date-col.
con.execute(
    """
    CREATE TABLE all_types AS SELECT
      i::INTEGER                                       AS i32,
      (i * 1000000000)::BIGINT                          AS i64,
      (i * 1.5)::FLOAT                                  AS f32,
      (i * 1.25)::DOUBLE                                AS f64,
      ('v' || (i % 5))::VARCHAR                         AS s,
      (i % 2 = 0)                                       AS b,
      (DATE '1996-01-01' + INTERVAL (i % 7) DAY)::DATE   AS d,
      CASE WHEN i % 3 = 0 THEN NULL ELSE i::BIGINT END   AS n
    FROM range(0, 12) tbl(i)
    """
)

# 'dict': low-cardinality columns big enough that duckdb writes dictionary
# pages, plus a NULL-carrying value column for the definition levels.
con.execute(
    """
    CREATE TABLE dict_types AS SELECT
      (i % 7)::INTEGER                                          AS k,
      ('tag' || (i % 11))::VARCHAR                              AS tag,
      CASE WHEN i % 13 = 0 THEN NULL ELSE (i % 250)::BIGINT END   AS v
    FROM range(0, 512) tbl(i)
    """
)

# 'multigroup': duckdb floors ROW_GROUP_SIZE at 2048, so 4096 rows split in two
con.execute(
    """
    CREATE TABLE multi AS SELECT
      i::BIGINT              AS k,
      (i % 7)::INTEGER       AS v,
      ('g' || (i // 2048))::VARCHAR AS s
    FROM range(0, 4096) tbl(i)
    """
)

SHAPES = {
    "all_types": ("all_types", 12),
    "dict_types": ("dict_types", 512),
    "multigroup": ("multi", 4096),
}

# (shape directory, variant directory, COPY options)
VARIANTS = [
    ("all_types", "plain", "COMPRESSION UNCOMPRESSED"),
    ("all_types", "snappy", "COMPRESSION SNAPPY"),
    ("dict_types", "dict", "COMPRESSION SNAPPY"),
    ("dict_types", "dict_uncompressed", "COMPRESSION UNCOMPRESSED"),
    ("multigroup", "two_groups", "COMPRESSION SNAPPY, ROW_GROUP_SIZE 2048"),
]

for shape, variant, options in VARIANTS:
    table, rows = SHAPES[shape]
    d = root / shape / variant
    d.mkdir(parents=True, exist_ok=True)
    path = d / "t.parquet"
    con.execute(f"COPY {table} TO '{path}' (FORMAT PARQUET, {options})")
    groups, got_rows = con.sql(
        f"select num_row_groups, num_rows from parquet_file_metadata('{path}')"
    ).fetchone()
    codec = con.sql(f"select distinct compression from parquet_metadata('{path}')").fetchone()[0]
    encodings = sorted(
        {e for (e,) in con.sql(f"select distinct encodings from parquet_metadata('{path}')").fetchall()}
    )
    assert got_rows == rows, f"{path}: {got_rows} rows, expected {rows}"
    print(
        f"{shape}/{variant}: {got_rows} rows, {groups} row group(s), {codec}, "
        f"{','.join(encodings)}, {path.stat().st_size} bytes"
    )


# ---------------------------------------------------------------- goldens

def fmt(v) -> str:
    if v is None:
        return "null"
    # the engine renders booleans lowercase; compare.py diffs cells as text
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, Decimal):
        v = float(v)
    if isinstance(v, date):
        return v.isoformat()
    if isinstance(v, float):
        return repr(v)
    return str(v)


def golden(shape: str, name: str, sql: str) -> None:
    cur = con.execute(sql)
    rows = cur.fetchall()
    lines = ["|".join(d[0] for d in cur.description)]
    for row in rows:
        lines.append("|".join(fmt(v) for v in row))
    path = root / shape / f"{name}_golden.txt"
    path.write_text("\n".join(lines) + "\n")
    print(f"{shape}/{name}_golden.txt: {len(rows)} rows")


golden(
    "all_types",
    "pqall",
    "select i32, i64, f32, f64, s, b, d, n from all_types order by i32",
)
golden(
    "dict_types",
    "pqdict",
    "select k, tag, v from dict_types order by k, tag, v nulls last",
)
golden(
    "dict_types",
    "pqdictagg",
    "select k, count(*), count(v), sum(v) from dict_types group by k order by k",
)
golden("multigroup", "pqgroups", "select count(*), sum(v) from multi")
