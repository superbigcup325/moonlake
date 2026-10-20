# Generate the row-group-statistics fixtures the scan tests embed as hex:
# four row groups of three rows, with per-group value ranges that are known
# in advance, plus a string column that is entirely NULL in one group and a
# long string column whose statistics are truncated by the writer.
#
# pyarrow is used instead of duckdb because duckdb floors ROW_GROUP_SIZE at
# 2048 rows, which would make the fixture far too large to commit and embed.
# The files stay inside the subset the in-house reader accepts: data page v1,
# PLAIN encoding, no compression, flat schema.
#
# Usage:
#   UV_CACHE_DIR=$PWD/.uv-cache uv run --with pyarrow python harness/gen_parquet_stats.py
#
# The script prints the hex of each file; `sources/parquet/lazy_test.mbt`
# carries the bytes and asserts against the ranges documented here.

from __future__ import annotations

import pathlib

import pyarrow as pa
import pyarrow.parquet as pq

out = pathlib.Path(__file__).resolve().parent / "data" / "parquet" / "stats"
out.mkdir(parents=True, exist_ok=True)

GROUPS = 4
ROWS = 3
# group g holds v in [g * 1000, g * 1000 + 2], d = 18262 + g (2020-01-01 + g),
# and s = None for the whole of group 1 and "g<g>" elsewhere
grp, v, d, s = [], [], [], []
for g in range(GROUPS):
    for i in range(ROWS):
        grp.append(g)
        v.append(g * 1000 + i)
        d.append(18262 + g)
        s.append(None if g == 1 else f"g{g}")

table = pa.table(
    {
        "grp": pa.array(grp, pa.int32()),
        "v": pa.array(v, pa.int64()),
        "d": pa.array(d, pa.int32()),
        "s": pa.array(s, pa.string()),
    }
)


def write(name: str, t: pa.Table) -> None:
    path = out / name
    pq.write_table(
        t,
        path,
        row_group_size=ROWS,
        compression="none",
        use_dictionary=False,
        data_page_version="1.0",
        write_statistics=True,
    )
    md = pq.ParquetFile(path).metadata
    assert md.num_row_groups == GROUPS, (name, md.num_row_groups)
    assert md.num_rows == GROUPS * ROWS
    print(f"# {name}: {md.num_row_groups} groups x {ROWS} rows, {path.stat().st_size} bytes")
    for rg in range(md.num_row_groups):
        cols = []
        for c in range(md.row_group(rg).num_columns):
            col = md.row_group(rg).column(c)
            st = col.statistics
            cols.append(
                f"{col.path_in_schema}=[{st.min if st and st.has_min_max else '-'},"
                f"{st.max if st and st.has_min_max else '-'}]"
            )
        print(f"#   group {rg}: " + " ".join(cols))
    print(name, path.read_bytes().hex())


write("mg_stats.parquet", table)

# Two single-row groups whose strings share the first 64 bytes: the writer
# truncates string statistics there and marks them inexact, so a scanner must
# not treat the stored value as a usable upper bound. `s > 'a'*64` must return
# the first row, never an empty result.
trunc = pa.table(
    {
        "s": pa.array(["a" * 64 + "b", "z"], pa.string()),
    }
)
pq.write_table(
    trunc,
    out / "trunc.parquet",
    row_group_size=1,
    compression="none",
    use_dictionary=False,
    data_page_version="1.0",
    write_statistics=True,
)
print("trunc.parquet", (out / "trunc.parquet").read_bytes().hex())

# Two groups whose DOUBLE column holds a NaN next to 5.0 (group 0) and 10.0
# (group 1). NaN is deliberately written with a regular value so the writer's
# statistics ignore it: the bounds of group 0 are [5, 5], yet the engine's
# comparison treats NaN as equal to everything, so a NaN row satisfies
# `f = 7.0`. A scanner must not let the stats rule that group out.
nan = pa.table(
    {
        "f": pa.array([float("nan"), 5.0, 10.0], pa.float64()),
    }
)
pq.write_table(
    nan,
    out / "nan.parquet",
    row_group_size=2,
    compression="none",
    use_dictionary=False,
    data_page_version="1.0",
    write_statistics=True,
)
md = pq.ParquetFile(out / "nan.parquet").metadata
for rg in range(md.num_row_groups):
    st = md.row_group(rg).column(0).statistics
    print(f"# nan group {rg}: f=[{st.min}, {st.max}]")
print("nan.parquet", (out / "nan.parquet").read_bytes().hex())

# one group where the string column is all NULL, and nothing else: the plan
# must skip it for any comparison on the string column
conly = pa.table(
    {
        "k": pa.array([0, 1, 2], pa.int64()),
        "n": pa.array([None, None, None], pa.string()),
    }
)
pq.write_table(
    conly,
    out / "nullable.parquet",
    row_group_size=3,
    compression="none",
    use_dictionary=False,
    data_page_version="1.0",
    write_statistics=True,
)
print("nullable.parquet", (out / "nullable.parquet").read_bytes().hex())
