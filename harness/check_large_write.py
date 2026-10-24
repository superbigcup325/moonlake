# Check that the writer really crosses the 2 GiB file boundary, and that the
# file it produces is a normal Parquet file to everybody else.
#
# A "does it fit in an offset" bug is invisible at small sizes: 32-bit offsets
# write and read back happily until byte 2^31. This script therefore builds one
# file that is certainly over the line, then checks three independent things:
#
#   1. the footer itself carries an offset past 2^31 (pyarrow's metadata),
#   2. pyarrow and duckdb read the same rows and the same sum from it,
#   3. moonlake reads the same answer back through its range reader, so the
#      offsets are not only written wide but consumed wide.
#
# Usage:
#   uv run --python 3.12 --with-requirements harness/requirements.txt python \
#     harness/check_large_write.py
#   MOONLAKE_BIN=_build/native/release/build/cmd/main/main.exe \
#     python harness/check_large_write.py --keep
#
# Costs a few minutes and about 5 GB of scratch disk (2.35 GB CSV in, 2.41 GB
# Parquet out). Exits non-zero on the first divergence and cleans up after
# itself unless --keep is passed.

from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

# 2^31 bytes is the line, and 2.35 GiB of CSV lands a bit over 2.41 GiB of
# Parquet: far enough past it that the last 1,820 column chunks sit over the
# line, close enough to keep the run short.
TARGET_BYTES = 2350 * 1024 * 1024
TAG = "abcdefghij" * 6
BATCH = 200_000


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def generate_csv(path: pathlib.Path) -> int:
    written = len("id,tag\n")
    rows = 0
    with path.open("w") as f:
        f.write("id,tag\n")
        while written < TARGET_BYTES:
            chunk = "".join(
                f"{rows + i},{TAG}{i % 100:02d}\n" for i in range(BATCH)
            )
            f.write(chunk)
            written += len(chunk)
            rows += BATCH
    return rows


def run(binary: pathlib.Path, *args: str) -> tuple[int, str]:
    proc = subprocess.run(
        [str(binary), *args], capture_output=True, text=True, check=False
    )
    return proc.returncode, (proc.stdout + proc.stderr).strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--binary",
        default=os.environ.get(
            "MOONLAKE_BIN", "_build/native/release/build/cmd/main/main.exe"
        ),
        help="native release CLI",
    )
    parser.add_argument("--workdir", default=None, help="scratch directory")
    parser.add_argument("--keep", action="store_true", help="keep the files")
    args = parser.parse_args()

    binary = pathlib.Path(args.binary)
    if not binary.exists():
        # `moon build cmd/main --target native --release` puts it here
        fail(f"no such binary: {binary}")
    work = pathlib.Path(args.workdir) if args.workdir else pathlib.Path(
        tempfile.mkdtemp(prefix="moonlake-large-")
    )
    work.mkdir(parents=True, exist_ok=True)
    csv = work / "in.csv"
    parquet = work / "out.parquet"

    print(f"generating {TARGET_BYTES / 2**30:.2f} GiB of CSV in {work} ...")
    rows = generate_csv(csv)
    print(f"  {csv.stat().st_size} bytes, {rows} rows")

    print("writing Parquet ...")
    code, out = run(binary, "write", "--csv", str(csv), "--out", str(parquet))
    if code != 0:
        fail(f"write exited {code}: {out}")
    size = parquet.stat().st_size
    print(f"  {size} bytes")

    import pyarrow.parquet as pq
    import duckdb

    meta = pq.ParquetFile(parquet).metadata
    offsets = [
        meta.row_group(group).column(column).data_page_offset
        for group in range(meta.num_row_groups)
        for column in range(meta.num_columns)
    ]
    widest = max(offsets)
    past = sum(1 for offset in offsets if offset > 2**31 - 1)
    print(f"  {meta.num_rows} rows, {meta.num_row_groups} row groups")
    print(f"  widest data_page_offset {widest}, {past} of {len(offsets)} past 2^31")
    if size <= 2**31:
        fail(f"the file is {size} bytes: not past 2 GiB, so the run proves nothing")
    if widest <= 2**31 - 1:
        fail("no offset in the footer is past 2^31")
    if meta.num_rows != rows:
        fail(f"footer says {meta.num_rows} rows, CSV had {rows}")

    print("cross-reading with pyarrow ...")
    table = pq.read_table(parquet, columns=["id", "tag"])
    if table.num_rows != rows:
        fail(f"pyarrow read {table.num_rows} rows, expected {rows}")
    ids = table.column("id").to_pylist()
    want_sum = sum(ids)
    want_first = ids[0]
    want_last = ids[-1]
    # the first and last tag come from the CSV itself, so this compares the
    # written values against the input rather than against a re-derivation
    with csv.open("rb") as f:
        f.readline()  # header
        first_tag = f.readline().decode().strip().split(",")[1]
        f.seek(max(0, csv.stat().st_size - 256))
        lines = f.read().decode().strip().splitlines()
        last_tag = lines[-1].split(",")[1]
    tags = table.column("tag")
    if tags[0].as_py() != first_tag:
        fail(f"pyarrow read first tag {tags[0]!r}, CSV had {first_tag!r}")
    if tags[-1].as_py() != last_tag:
        fail(f"pyarrow read last tag {tags[-1]!r}, CSV had {last_tag!r}")

    print("cross-reading with duckdb ...")
    con = duckdb.connect()
    got = con.execute(
        f"select count(*), sum(id), min(id), max(id) from '{parquet}'"
    ).fetchall()[0]
    if got != (rows, want_sum, want_first, want_last):
        fail(f"duckdb says {got}, expected {(rows, want_sum, want_first, want_last)}")

    print("reading back with moonlake ...")
    code, out = run(
        binary,
        "exec",
        "--parquet",
        str(parquet),
        "select count(*) as n, sum(id) as s from out",
    )
    if code != 0:
        fail(f"moonlake read exited {code}: {out}")
    header, _, values = out.partition("\n")
    fields = values.strip().split("|")
    if fields[:2] != [str(rows), str(want_sum)]:
        fail(f"moonlake read {fields[:2]}, expected {[rows, want_sum]}")

    print("ok: a file past 2 GiB round-trips through three readers")
    if not args.keep:
        shutil.rmtree(work, ignore_errors=True)
    else:
        print(f"kept {work}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
