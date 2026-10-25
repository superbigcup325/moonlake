# Does a per-column dictionary pay on a second dataset, and would one fixed rule
# choose the right columns?
#
# The writing row of the roadmap says a per-column dictionary is worth about a
# third of a TPC-H `lineitem` file, and that the choice has to be per column
# because a dictionary *grows* a column with nothing to repeat. That was one
# table. W0 is the second: a web access log, built here from a seed rather than
# committed, whose columns are chosen to disagree with each other — a monotonic
# timestamp, a medium-cardinality id, two tiny enumerations, a long repetitive
# path, a long near-unique query string, a boolean, a nullable medium-cardinality
# note.
#
# The script measures the encoding question the writing row is about, and
# separates the half that is a hypothetical from the half that is ours:
#
#  1. PyArrow writes the same rows plain+snappy, dictionary-on-everything and
#     dictionary-on-a-chosen-subset with one page and row-group layout. Its
#     per-column files say which columns a dictionary helps and which it hurts,
#     and the footer's `encodings` list says whether PyArrow actually used one
#     rather than falling back and leaving the column plain.
#  2. Moonlake writes the same rows itself and reads every file back. That half
#     is the implementation result: what our writer emits today, and what our
#     reader costs when it has to decode someone else's dictionary.
#
# Every file must return the same answer, so a smaller file that lost rows or
# strings fails here rather than in a note under a benchmark table.
#
# Usage:
#   python3 harness/dict_survey.py                    # 500k rows, print the tables
#   python3 harness/dict_survey.py --rows 1000000     # a bigger table
#   python3 harness/dict_survey.py --quick            # 50k rows, one repeat
#   python3 harness/dict_survey.py --json-out harness/baseline/2026-10-26-dict.json
#
# Peak RSS is `ru_maxrss` of one child and nothing else: the measured binary runs
# under a tiny helper, because a forked child shares its parent's resident pages
# until `exec` and this script holds a PyArrow table and a DuckDB result. Wall
# clocks are best-of-N on one machine, so the claim is bytes and memory first and
# milliseconds second.

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import random
import statistics
import subprocess
import sys
import tempfile
import time

import duckdb
import pyarrow as pa
import pyarrow.parquet as pq

REPO = pathlib.Path(__file__).resolve().parent.parent

# The row-group size our writer uses (4,096 rows, one per scan batch), so the
# comparison is between encodings and not between layouts. `--row-group` changes
# it, and the control block at the end runs the chosen set at PyArrow's own
# 65,536 to show the win is not an artifact of the smaller group.
ROW_GROUP = 4096
CONTROL_ROW_GROUP = 65536
REPEATS = 3

# A web access log. `kind` is the column's role in the experiment and is how the
# per-column table is read: high cardinality, tiny enumeration, repetitive long
# string, unique long string, nullable.
COLUMNS = [
    ("ts", "int64", "monotonic"),
    ("uid", "int64", "medium"),
    ("country", "string", "tiny"),
    ("device", "string", "tiny null"),
    ("path", "string", "repetitive"),
    ("query", "string", "unique"),
    ("status", "int32", "tiny"),
    ("latency", "double", "unique"),
    ("size", "int64", "unique"),
    ("flag", "bool", "tiny"),
    ("note", "string", "medium null"),
]
NAMES = [c for c, _, _ in COLUMNS]
KINDS = {c: k for c, _, k in COLUMNS}

# The aggregate every file must agree on: counts, sums, and the two NULL counts
# that pin the definition levels, plus string lengths that pin the string pages.
CHECK_SQL = (
    "select count(*), sum(ts), sum(uid), sum(status), sum(latency), sum(size), "
    "count(device), count(note), sum(length(path)), sum(length(query)) from t"
)


def build_table(rows: int, seed: int) -> pa.Table:
    """The log from a seed: the same rows and seed give the same bytes."""
    rng = random.Random(seed)
    countries = [f"c{chr(ord('a') + i % 26)}{i // 26}" for i in range(40)]
    devices = ["desktop", "mobile", "tablet", "tv", "bot", "unknown"]
    resources = [
        "orders", "order-items", "customers", "products", "search", "cart",
        "checkout", "session", "recommendations", "inventory", "pricing", "auth",
    ]
    buckets = max(rows // 2000, 1)

    ts: list[int] = []
    uid: list[int] = []
    country: list[str] = []
    device: list[str | None] = []
    path: list[str] = []
    query: list[str] = []
    status: list[int] = []
    latency: list[float] = []
    size: list[int] = []
    flag: list[bool] = []
    note: list[str | None] = []
    for i in range(rows):
        ts.append(1_700_000_000 + i)
        uid.append(rng.randrange(20_000))
        country.append(countries[rng.randrange(len(countries))])
        device.append(None if rng.randrange(100) < 3 else devices[rng.randrange(len(devices))])
        resource = resources[rng.randrange(len(resources))]
        path.append(f"/api/v2/{resource}/{rng.randrange(buckets)}?expand=owner%2Citems")
        query.append(f"?q=term{rng.randrange(10**6)}&page={i % 50}&sort=relevance")
        status.append(
            rng.choice([200, 200, 200, 200, 201, 204, 301, 304, 400, 404, 429, 500])
        )
        latency.append(round(rng.random() * 900.0, 3))
        size.append(rng.randrange(0, 4_000_000))
        flag.append(rng.randrange(10) < 4)
        note.append(
            None
            if rng.randrange(10) < 4
            else f"edge node {rng.randrange(2000)} served this request"
        )

    return pa.table(
        {
            "ts": pa.array(ts, pa.int64()),
            "uid": pa.array(uid, pa.int64()),
            "country": pa.array(country, pa.string()),
            "device": pa.array(device, pa.string()),
            "path": pa.array(path, pa.string()),
            "query": pa.array(query, pa.string()),
            "status": pa.array(status, pa.int32()),
            "latency": pa.array(latency, pa.float64()),
            "size": pa.array(size, pa.int64()),
            "flag": pa.array(flag, pa.bool_()),
            "note": pa.array(note, pa.string()),
        }
    )


def write_pyarrow(
    table: pa.Table, path: pathlib.Path, row_group: int = ROW_GROUP, **kwargs
) -> None:
    pq.write_table(
        table,
        path,
        compression="snappy",
        data_page_version="1.0",
        row_group_size=row_group,
        **kwargs,
    )


def median_ms(fn, repeats: int) -> float:
    times = []
    for _ in range(repeats):
        start = time.perf_counter()
        fn()
        times.append((time.perf_counter() - start) * 1000.0)
    return statistics.median(times)


def column_encodings(path: pathlib.Path) -> list[list[str]]:
    """The footer's encodings, one list per column of the first row group."""
    group = pq.ParquetFile(path).metadata.row_group(0)
    return [list(group.column(i).encodings) for i in range(group.num_columns)]


# Runs one command and reports that child's wall time and peak RSS. It is a
# separate process so this script's own resident pages are never counted.
CHILD = r"""
import json, resource, subprocess, sys, time
cmd = json.loads(sys.argv[1])
start = time.perf_counter()
proc = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
wall = (time.perf_counter() - start) * 1000.0
peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024.0
sys.stdout.write(json.dumps({"wall_ms": wall, "peak_mb": peak,
                             "code": proc.returncode,
                             "stderr": proc.stderr.decode()[-2000:]}))
"""


def run_child(cmd: list[str], growl: bool = True) -> dict:
    out = subprocess.run(
        [sys.executable, "-c", CHILD, json.dumps(cmd)],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        raise SystemExit(f"helper failed: {out.stderr[-500:]}")
    result = json.loads(out.stdout)
    if growl and result["code"] != 0:
        raise SystemExit(f"{cmd[0]} exited {result['code']}: {result['stderr']}")
    return result


# Our engine names a table after the file's stem, so a file it is asked to
# screen has to have a stem that is a plain identifier: t_dict_chosen, not
# dict-chosen. The variant's name stays readable in the tables; only the file on
# disk is sanitized.
def file_for(workdir: pathlib.Path, name: str) -> pathlib.Path:
    return workdir / f"t_{name.replace('+', '_').replace('-', '_')}.parquet"


def our_sql(path: pathlib.Path) -> str:
    return CHECK_SQL.replace("from t", f"from {path.stem}")


DUCK = duckdb.connect()


def duck_sql(path: pathlib.Path) -> str:
    return CHECK_SQL.replace("from t", f"from read_parquet('{path}')")


def duck_answer(path: pathlib.Path) -> tuple:
    return tuple(DUCK.execute(duck_sql(path)).fetchall()[0])


def duck_read_ms(path: pathlib.Path, repeats: int) -> float:
    return median_ms(lambda: DUCK.execute(duck_sql(path)).fetchall(), repeats)


def same_answer(a: tuple, b: tuple) -> bool:
    """Same cells: floats to a relative tolerance, everything else exactly.

    A double sum is not associative, and the two writers decode their pages into
    different batch shapes, so `sum(latency)` can differ in the last bits for two
    files that hold the same values. Integers, counts and string lengths have no
    such excuse.
    """
    if len(a) != len(b):
        return False
    for left, right in zip(a, b):
        if left is None or right is None:
            if left is not right:
                return False
        elif isinstance(left, float) or isinstance(right, float):
            if abs(left - right) > 1e-9 * max(1.0, abs(left), abs(right)):
                return False
        elif left != right:
            return False
    return True


def refuse(reason: str) -> None:
    sys.stderr.write(f"dict_survey: {reason}\n")
    raise SystemExit(2)


def find_binary() -> pathlib.Path:
    for candidate in (
        os.environ.get("MOONLAKE_BIN"),
        str(REPO / "_build" / "native" / "release" / "build" / "cmd" / "main" / "main.exe"),
        str(REPO / "_build" / "native" / "debug" / "build" / "cmd" / "main" / "main.exe"),
    ):
        if candidate and pathlib.Path(candidate).exists():
            return pathlib.Path(candidate)
    refuse("no moonlake binary: set MOONLAKE_BIN or build cmd/main first")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rows", type=int, default=500_000)
    parser.add_argument("--row-group", type=int, default=ROW_GROUP)
    parser.add_argument("--seed", type=int, default=20261026)
    parser.add_argument("--out-dir", type=pathlib.Path)
    parser.add_argument("--json-out", type=pathlib.Path)
    parser.add_argument("--quick", action="store_true")
    args = parser.parse_args(argv)

    binary = find_binary()
    rows = 50_000 if args.quick else args.rows
    row_group = args.row_group
    repeats = 1 if args.quick else REPEATS
    workdir = args.out_dir or pathlib.Path(tempfile.mkdtemp(prefix="dict-survey-"))
    workdir.mkdir(parents=True, exist_ok=True)

    print(f"rows {rows:,} seed {args.seed} row group {row_group:,} -> {workdir}")
    table = build_table(rows, args.seed)
    values_mb = sum(table.column(i).nbytes for i in range(table.num_columns)) / 1e6
    print(f"in memory: {table.num_rows:,} rows, {values_mb:.1f} MB of values")
    record: dict = {
        "rows": rows,
        "seed": args.seed,
        "row_group": row_group,
        "columns": NAMES,
        "variants": {},
        "per_column": {},
    }

    # -- per column: which ones a dictionary helps, and which it hurts ---------
    per_column: dict[str, dict] = {}
    print()
    print("| column | role | distinct | plain B | dict B | delta | dict used |")
    print("|---|---|---|---|---|---|---|")
    for name in NAMES:
        single = table.select([name])
        plain = workdir / f"col-{name}-plain.parquet"
        dictd = workdir / f"col-{name}-dict.parquet"
        write_pyarrow(single, plain, row_group, use_dictionary=False)
        write_pyarrow(single, dictd, row_group, use_dictionary=True)
        plain_bytes, dict_bytes = plain.stat().st_size, dictd.stat().st_size
        encodings = column_encodings(dictd)[0]
        used = any("DICTIONARY" in e for e in encodings)
        distinct = len(set(table.column(name).to_pylist()))
        delta = (dict_bytes - plain_bytes) / plain_bytes * 100.0
        per_column[name] = {
            "plain_bytes": plain_bytes,
            "dict_bytes": dict_bytes,
            "distinct": distinct,
            "dict_used": used,
            "encodings": encodings,
        }
        print(
            f"| `{name}` | {KINDS[name]} | {distinct:,} | {plain_bytes:,} | "
            f"{dict_bytes:,} | {delta:+.0f}% | {'yes' if used else 'no'} |"
        )
    record["per_column"] = per_column

    chosen = [
        n for n in NAMES
        if per_column[n]["dict_used"] and per_column[n]["dict_bytes"] < per_column[n]["plain_bytes"]
    ]
    fell_back = [n for n in NAMES if not per_column[n]["dict_used"]]
    grew = [
        n for n in NAMES
        if per_column[n]["dict_used"] and per_column[n]["dict_bytes"] >= per_column[n]["plain_bytes"]
    ]
    print()
    print(f"chosen:            {', '.join(chosen) or '(none)'}")
    print(f"fell back to plain: {', '.join(fell_back) or '(none)'}")
    print(f"dictionary, no win: {', '.join(grew) or '(none)'}")
    record |= {"chosen": chosen, "fell_back": fell_back, "no_win": grew}

    # -- whole file: three pyarrow encodings, then our own writer -------------
    plain_path = file_for(workdir, "plain+snappy")
    files = {
        "plain+snappy": (plain_path, {"use_dictionary": False}),
        "dict-all": (file_for(workdir, "dict-all"), {"use_dictionary": True}),
        "dict-chosen": (file_for(workdir, "dict-chosen"), {"use_dictionary": chosen}),
    }
    for name, (path, kwargs) in files.items():
        write_pyarrow(table, path, row_group, **kwargs)
        record["variants"][name] = {
            "bytes": path.stat().st_size,
            "write_ms": median_ms(
                lambda p=path, k=kwargs: write_pyarrow(table, p, row_group, **k), repeats
            ),
            "duck_read_ms": duck_read_ms(path, repeats),
            "answer": list(duck_answer(path)),
        }

    # Our writer re-reads the plain file, so both writers encode the same rows.
    ours = file_for(workdir, "ours-snappy")
    written = run_child(
        [str(binary), "write", "--parquet", str(plain_path), "--out", str(ours), "--snappy"]
    )
    files["ours-snappy"] = (ours, {})
    record["variants"]["ours-snappy"] = {
        "bytes": ours.stat().st_size,
        "write_ms": written["wall_ms"],
        "write_peak_mb": written["peak_mb"],
        "duck_read_ms": duck_read_ms(ours, repeats),
        "answer": list(duck_answer(ours)),
    }

    # -- one answer for every file, then our reader on each -------------------
    answers = {name: tuple(entry["answer"]) for name, entry in record["variants"].items()}
    reference = answers["plain+snappy"]
    disagreeing = [n for n, a in answers.items() if not same_answer(a, reference)]
    if disagreeing:
        for name in disagreeing:
            print(f"  {name}: {answers[name]}")
        print(f"  plain+snappy: {reference}")
        refuse("the encodings do not agree on the answer")

    plain_bytes = record["variants"]["plain+snappy"]["bytes"]
    print()
    print("| variant | bytes | vs plain | write ms | duck read ms | our read ms | our read MB |")
    print("|---|---|---|---|---|---|---|")
    for name, (path, _) in files.items():
        entry = record["variants"][name]
        read = run_child([str(binary), "exec", "--parquet", str(path), our_sql(path)])
        entry["read_ms"] = read["wall_ms"]
        entry["read_peak_mb"] = read["peak_mb"]
        delta = (entry["bytes"] - plain_bytes) / plain_bytes * 100.0
        print(
            f"| `{name}` | {entry['bytes']:,} | {delta:+.1f}% | "
            f"{entry['write_ms']:.0f} | {entry['duck_read_ms']:.0f} | "
            f"{entry['read_ms']:.0f} | {entry['read_peak_mb']:.0f} |"
        )

    ours_bytes = record["variants"]["ours-snappy"]["bytes"]
    chosen_bytes = record["variants"]["dict-chosen"]["bytes"]
    print()
    print(f"ours+snappy vs pyarrow plain+snappy: {ours_bytes - plain_bytes:+,} B "
          f"({(ours_bytes - plain_bytes) / plain_bytes * 100.0:+.1f}%)")
    print(f"pyarrow dict-chosen vs plain+snappy:  {chosen_bytes - plain_bytes:+,} B "
          f"({(chosen_bytes - plain_bytes) / plain_bytes * 100.0:+.1f}%)")
    print(f"ours+snappy vs pyarrow dict-chosen:  {ours_bytes - chosen_bytes:+,} B "
          f"({(ours_bytes - chosen_bytes) / plain_bytes * 100.0:+.1f}% of plain)")
    record["summary"] = {
        "plain_bytes": plain_bytes,
        "ours_snappy_bytes": ours_bytes,
        "dict_chosen_bytes": chosen_bytes,
        "dict_all_bytes": record["variants"]["dict-all"]["bytes"],
        "ours_over_plain": (ours_bytes - plain_bytes) / plain_bytes,
        "dict_win": (chosen_bytes - plain_bytes) / plain_bytes,
    }

    # The control: the same plain-versus-chosen comparison at PyArrow's own
    # 65,536-row group, so a win that came from the smaller group would not
    # look like a win for the encoding.
    control = {}
    if row_group != CONTROL_ROW_GROUP:
        for name, kwargs in (
            ("plain", {"use_dictionary": False}),
            ("chosen", {"use_dictionary": chosen}),
        ):
            path = workdir / f"t_control_{name}.parquet"
            write_pyarrow(table, path, CONTROL_ROW_GROUP, **kwargs)
            control[name] = path.stat().st_size
        print()
        print(f"control at row group {CONTROL_ROW_GROUP:,}: plain {control['plain']:,} B, "
              f"chosen {control['chosen']:,} B "
              f"({(control['chosen'] - control['plain']) / control['plain'] * 100.0:+.1f}%)")
        record["control"] = control

    print()
    print(f"files in {workdir}")
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        print(f"record in {args.json_out}")
    print(f"plain+snappy sha256 {hashlib.sha256(plain_path.read_bytes()).hexdigest()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
