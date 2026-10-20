# Cross-check the Parquet writer against two independent readers, in both
# directions:
#
#   moonlake -> pyarrow / duckdb   (does the file we write look like a Parquet
#                                   file to software that did not write it?)
#   duckdb   -> moonlake           (and can we read what a different writer
#                                   produces, annotations and all?)
#
# Row counts are not enough here: the point is the schema. A written DATE used
# to be a bare INT32 and a written string an unannotated byte array (a BLOB to
# DuckDB), which no count can see.
#
# Usage:
#   uv run --with duckdb --with pyarrow python harness/check_writer_interop.py
#   MOONLAKE_BIN=_build/native/release/build/cmd/main/main.exe \
#     python harness/check_writer_interop.py
#
# Exits non-zero on the first divergence.

from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

# The fixture is small on purpose: it is about types and annotations, and the
# TPC-H chain already covers volume. Rows: 4, with NULLs in every column.
HEADER = "i32,i64,f64,s,b,d"
ROWS = [
    "1,10,1.5,alpha,true,1992-01-04",
    "2,-20,-2.25,,false,1998-11-29",  # NULL string
    "3,3000000000,0.0,gamma delta,true,2000-02-29",  # past int32: forces BIGINT
    "4,,4.5,é-accent,false,1970-01-01",  # NULL int64, non-ASCII string
]


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def moonlake_bin() -> str:
    env = os.environ.get("MOONLAKE_BIN")
    if env:
        return env
    subprocess.run(
        ["moon", "build", "cmd/main", "--target", "native"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    return str(ROOT / "_build/native/debug/build/cmd/main/main.exe")


def run(binary: str, *args: str) -> str:
    proc = subprocess.run([binary, *args], capture_output=True, text=True)
    if proc.returncode != 0:
        fail(f"moonlake {' '.join(args)} failed:\n{proc.stderr.strip()}")
    return proc.stdout.strip()


def write_fixture(work: pathlib.Path) -> pathlib.Path:
    path = work / "t.csv"
    path.write_text("\n".join([HEADER, *ROWS]) + "\n", encoding="utf-8")
    return path


def check_pyarrow(path: pathlib.Path, label: str) -> None:
    import pyarrow.parquet as pq

    table = pq.read_table(path)
    schema = table.schema
    want = {
        "i32": "int32",
        "i64": "int64",
        "f64": "double",
        "s": "string",
        "b": "bool",
        "d": "date32[day]",
    }
    for name, expected in want.items():
        got = str(schema.field(name).type)
        if got != expected:
            fail(f"{label}: pyarrow reads {name} as {got}, expected {expected}")
    data = table.to_pydict()
    if data["s"][1] is not None:
        fail(f"{label}: pyarrow lost the NULL in s: {data['s']}")
    if data["i64"][3] is not None:
        fail(f"{label}: pyarrow lost the NULL in i64: {data['i64']}")
    if data["d"][0].isoformat() != "1992-01-04":
        fail(f"{label}: pyarrow reads d[0] as {data['d'][0]!r}")
    if data["s"][2] != "gamma delta":
        fail(f"{label}: pyarrow reads s[2] as {data['s'][2]!r}")
    if data["s"][3] != "é-accent":
        fail(f"{label}: pyarrow reads the non-ASCII string as {data['s'][3]!r}")
    print(f"ok: {label} — pyarrow sees STRING/DATE and every NULL")


def check_duckdb(path: pathlib.Path, label: str) -> None:
    import duckdb

    con = duckdb.connect()
    try:
        types = dict(
            con.sql(
                f"select column_name, column_type from (describe select * from read_parquet('{path}'))"
            ).fetchall()
        )
        want = {
            "i32": "INTEGER",
            "i64": "BIGINT",
            "f64": "DOUBLE",
            "s": "VARCHAR",
            "b": "BOOLEAN",
            "d": "DATE",
        }
        for name, expected in want.items():
            got = types.get(name)
            if got != expected:
                fail(f"{label}: duckdb reads {name} as {got}, expected {expected}")
        row = con.sql(
            f"select count(*), min(d), max(s), count(*) filter (where s is null) "
            f"from read_parquet('{path}')"
        ).fetchone()
        if row[0] != 4 or str(row[1]) != "1970-01-01" or row[2] != "é-accent" or row[3] != 1:
            fail(f"{label}: duckdb values differ: {row}")
    finally:
        con.close()
    print(f"ok: {label} — duckdb sees VARCHAR/DATE and the same values")


def duckdb_reference(path: pathlib.Path, csv: pathlib.Path) -> None:
    """Let duckdb write the same table, so moonlake has to read a file it did
    not write — annotations included."""
    import duckdb

    con = duckdb.connect()
    try:
        con.sql(
            f"copy (select i32::integer as i32, i64::bigint as i64, f64::double as f64, "
            f"s::varchar as s, b::boolean as b, d::date as d from read_csv('{csv}', header=true)) "
            f"to '{path}' (format parquet, compression snappy)"
        )
    finally:
        con.close()


def check_moonlake_reads(binary: str, path: pathlib.Path, label: str) -> None:
    out = run(
        binary,
        "exec",
        "--parquet",
        str(path),
        # no --date-col: the DATE annotation has to carry it
        f"select count(*) as n, min(d) as first, max(d) as last, "
        f"sum(case when s is null then 1 else 0 end) as nulls from {path.stem}",
    )
    lines = out.splitlines()
    if lines[0] != "n|first|last|nulls":
        fail(f"{label}: unexpected header {lines[0]!r}")
    if lines[1] != "4|1970-01-01|2000-02-29|1":
        fail(f"{label}: moonlake reads {lines[1]!r}, expected 4|1970-01-01|2000-02-29|1")
    print(f"ok: {label} — moonlake reads it without --date-col")


def main() -> int:
    binary = moonlake_bin()
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        csv = write_fixture(work)
        raw = work / "raw.parquet"
        snappy = work / "snappy.parquet"
        foreign = work / "duckdb.parquet"

        run(binary, "write", "--csv", str(csv), "--out", str(raw))
        run(binary, "write", "--csv", str(csv), "--out", str(snappy), "--snappy")

        for path, label in ((raw, "moonlake/raw"), (snappy, "moonlake/snappy")):
            check_pyarrow(path, label)
            check_duckdb(path, label)
            check_moonlake_reads(binary, path, label)

        duckdb_reference(foreign, csv)
        check_moonlake_reads(binary, foreign, "duckdb->moonlake")

        # Compression is a size claim, so it needs data where size can move:
        # four rows are all page header.
        big_csv = work / "big.csv"
        with open(big_csv, "w", encoding="utf-8") as f:
            f.write("k,s\n")
            for i in range(4000):
                f.write(f"{i},row-{i % 8}-moonlake-parquet-page\n")
        big_raw = work / "big_raw.parquet"
        big_snappy = work / "big_snappy.parquet"
        run(binary, "write", "--csv", str(big_csv), "--out", str(big_raw))
        run(
            binary,
            "write",
            "--csv",
            str(big_csv),
            "--out",
            str(big_snappy),
            "--snappy",
        )
        if big_snappy.stat().st_size >= big_raw.stat().st_size:
            fail(
                "--snappy did not shrink a 4000-row file: "
                f"{big_snappy.stat().st_size} >= {big_raw.stat().st_size}"
            )
        print(
            "ok: --snappy shrinks 4000 rows "
            f"{big_raw.stat().st_size} -> {big_snappy.stat().st_size} bytes"
        )
        # and the compressed file still reads back to the same content
        out = run(
            binary,
            "exec",
            "--parquet",
            str(big_snappy),
            "select count(*) as n, max(k) as hi from big_snappy",
        )
        if out.splitlines()[-1] != "4000|3999":
            fail(f"compressed file reads back as {out.splitlines()[-1]!r}")

    print("writer interop: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
