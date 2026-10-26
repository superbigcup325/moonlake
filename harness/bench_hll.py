# What does a grouped `approx_count_distinct` actually cost after colenc 0.1.2?
#
# H0 in the roadmap exists because the only SQL crossover we have is the 0.1.1
# one: a 64 KiB register array per group, measured on one 1,000-group shape, with
# the crossover at about 750 distinct values per group. 0.1.2 stores the same
# registers as bytes, so the dense payload is 16 KiB, and the temptation is to
# divide 750 by four. That is not a measurement: the group map, the per-group
# accumulator box, the scan's own batch and the exact set on the other side all
# stay where they were, and the shape that matters (many small groups) is not the
# shape the old table measured.
#
# So this script builds the matrix itself and measures every cell in one process
# per query:
#
#   count(s)                          decode the column, no state at all
#   count(DISTINCT s)                 exact, one set per group
#   approx_count_distinct(s)          dense 0.1.2 sketch, one per group
#   k, count(s) GROUP BY k            decode + group map, still no per-group set
#   k, count(DISTINCT s) GROUP BY k   exact state per group
#   k, approx_count_distinct(s) ...   sketch state per group
#
# The controls are the reason the numbers can be read: `k, count(s)` separates the
# scan and the group map from the state under test, so `approx - count` over the
# group count is the sketch's own footprint, and `exact - approx` is the crossover.
#
# Every measurement also records the answer, so an estimate that drifts with the
# representation fails here rather than in a footnote — as a fingerprint for a
# grouped query (row count, sum, extremes) rather than 20,000 copies of it. A NULL
# variant of the same table runs the pair through the NULL-skipping path.
#
# Usage:
#   python3 harness/bench_hll.py                  # the full matrix
#   python3 harness/bench_hll.py --quick          # two fixtures, one repeat
#   python3 harness/bench_hll.py --json-out harness/baseline/2026-10-26-h0.json
#
# The engine under test is the native release binary
# (_build/native/release/build/cmd/main/main.exe) built from this tree, and the
# parquet fixtures are generated here, not committed: `target/hll-bench/` is
# ignored.
#
# Peak RSS is `ru_maxrss` of one child process and nothing else. The measured
# binary runs under a tiny helper because a forked child shares its parent's
# resident pages until `exec`, and this script holds a DuckDB connection. Wall
# clocks are best-of-N on one machine, so the claim is bytes and memory first.

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
import time

import duckdb

REPO = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_DIR = REPO / "target" / "hll-bench"

# Where the native release binary lands. A plain checkout builds it at the flat
# path; a `moon.work` workspace (the colenc co-development setup) nests every
# artifact under the module name and leaves the flat one behind, stale. Both can
# exist, so the newest one wins and the choice is printed: a number is only as
# good as the binary it came from. `--bin` overrides both.
BIN_CANDIDATES = [
    REPO / "_build/native/release/build/cmd/main/main.exe",
    REPO / "_build/native/release/build/superbigcup325/moonlake/cmd/main/main.exe",
]


def find_bin() -> pathlib.Path:
    present = [c for c in BIN_CANDIDATES if c.exists()]
    if not present:
        raise SystemExit(
            "no native release binary; run `moon build --release --target native` "
            f"(looked in {', '.join(str(c) for c in BIN_CANDIDATES)})"
        )
    return max(present, key=lambda c: c.stat().st_mtime)

# (label, groups, distinct per group, copies per distinct value)
#
# The diagonal holds the row count at 1,000,000 while the group count grows by
# 100x, so the sketch's per-group cost and the exact set's per-value cost move in
# opposite directions across it. The three "small" rows are the shape that could
# justify sparse state: many groups holding very few values each. The duplicate
# row repeats every value ten times, so it separates update cost from distinct
# count. The last rows sweep distinct-per-group at a fixed 1,000 groups, which is
# the crossover itself.
FIXTURES: list[tuple[str, int, int, int]] = [
    ("one-big-group", 1, 1_000_000, 1),
    ("d100", 100, 10_000, 1),
    ("d1k", 1_000, 1_000, 1),
    ("d10k", 10_000, 100, 1),
    ("small-5k", 5_000, 10, 1),
    ("small-20k", 20_000, 10, 1),
    ("small-20k-1", 20_000, 1, 1),
    ("dup-10x", 1_000, 100, 10),
    ("xover-1", 1_000, 1, 1),
    ("xover-10", 1_000, 10, 1),
    ("xover-100", 1_000, 100, 1),
    ("xover-200", 1_000, 200, 1),
    ("xover-300", 1_000, 300, 1),
    ("xover-400", 1_000, 400, 1),
    ("xover-500", 1_000, 500, 1),
    ("xover-700", 1_000, 700, 1),
    ("xover-1000", 1_000, 1_000, 1),
    ("xover-10000", 1_000, 10_000, 1),
]

QUICK_FIXTURES = ["d1k", "small-20k"]

# One child per query: the peak is the measured binary's own, never this
# script's. `stderr` is kept so a failure reports the engine's message.
CHILD = r"""
import json, resource, subprocess, sys, time
cmd = json.loads(sys.argv[1])
start = time.perf_counter()
proc = subprocess.run(cmd, capture_output=True)
wall = (time.perf_counter() - start) * 1000.0
peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024.0
sys.stdout.write(json.dumps({"wall_ms": wall, "peak_mb": peak,
                             "code": proc.returncode,
                             "stdout": proc.stdout.decode(),
                             "stderr": proc.stderr.decode()[-2000:]}))
"""


def run_child(cmd: list[str]) -> dict:
    out = subprocess.run(
        [sys.executable, "-c", CHILD, json.dumps(cmd)],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        raise SystemExit(f"helper failed: {out.stderr[-500:]}")
    return json.loads(out.stdout)


def measure(args: list[str], repeats: int) -> dict:
    """Best wall time, worst peak RSS, and the answer of the last run."""
    best = None
    for _ in range(repeats):
        result = run_child(args)
        if result["code"] != 0:
            raise SystemExit(
                f"{' '.join(args)} exited {result['code']}: {result['stderr']}"
            )
        if best is None:
            best = result
        else:
            best["wall_ms"] = min(best["wall_ms"], result["wall_ms"])
            best["peak_mb"] = max(best["peak_mb"], result["peak_mb"])
            best["stdout"] = result["stdout"]
    return best


def rows_of(stdout: str) -> list[str]:
    """The result rows, without the header line the text output prints first."""
    lines = [line for line in stdout.splitlines() if line.strip()]
    return lines[1:]


# The string column: a fixed-width value, so the exact set's per-value cost is
# comparable with the 0.1.1 table (which measured about 88 B per distinct value)
# instead of depending on how long this run's strings happen to be.
FIXTURE_SQL = """
CREATE TABLE t AS
SELECT
  CAST(i // {block} AS INTEGER) AS k,
  's' || lpad(CAST(((i // {block}) * 1000003 + (i % {block}) // {copies}) AS VARCHAR), 9, '0') AS s,
  CASE WHEN i % 7 = 0 THEN NULL ELSE
    's' || lpad(CAST(((i // {block}) * 1000003 + (i % {block}) // {copies}) AS VARCHAR), 9, '0')
  END AS sn
FROM range(0, {rows}) AS t0(i)
"""

WRITE_SQL = (
    "COPY t TO '{path}' (FORMAT PARQUET, ROW_GROUP_SIZE 65536, COMPRESSION SNAPPY)"
)


def build_fixture(
    con: duckdb.DuckDBPyConnection,
    out_dir: pathlib.Path,
    label: str,
    groups: int,
    distinct: int,
    copies: int,
) -> pathlib.Path:
    rows = groups * distinct * copies
    path = out_dir / f"t_hll_{label.replace('-', '_')}.parquet"
    con.execute(
        FIXTURE_SQL.format(block=distinct * copies, rows=rows, copies=copies)
        .replace("CREATE TABLE t AS", "CREATE OR REPLACE TABLE t AS")
    )
    con.execute(WRITE_SQL.format(path=path))
    return path


def queries(stem: str) -> list[tuple[str, str]]:
    """(label, sql) for the ungrouped and grouped forms of each shape."""
    table = stem
    return [
        ("count(s)", f"select count(s) from {table}"),
        ("count(DISTINCT s)", f"select count(DISTINCT s) from {table}"),
        ("approx_count_distinct(s)", f"select approx_count_distinct(s) from {table}"),
        (
            "k, count(s)",
            f"select k, count(s) from {table} group by k",
        ),
        (
            "k, count(DISTINCT s)",
            f"select k, count(DISTINCT s) from {table} group by k",
        ),
        (
            "k, approx_count_distinct(s)",
            f"select k, approx_count_distinct(s) from {table} group by k",
        ),
        (
            "k, count(DISTINCT sn)",
            f"select k, count(DISTINCT sn) from {table} group by k",
        ),
        (
            "k, approx_count_distinct(sn)",
            f"select k, approx_count_distinct(sn) from {table} group by k",
        ),
    ]


def scalar_answer(rows: list[str]) -> int | None:
    if len(rows) != 1:
        return None
    try:
        return int(rows[0])
    except ValueError:
        return None


def answer_record(answer: int | None | list[int | None]) -> dict | int | None:
    """A compact, comparable record of an answer.

    A grouped answer is kept as a fingerprint rather than 20,000 numbers: the row
    count, the sum, and the extremes. The full answer is still checked in the run
    (a grouped query must return exactly one row per group); the record has to be
    small enough to commit beside the timings, not a second copy of the result.
    """
    if not isinstance(answer, list):
        return answer
    seen = [value for value in answer if value is not None]
    return {
        "rows": len(answer),
        "sum": sum(seen),
        "min": min(seen) if seen else None,
        "max": max(seen) if seen else None,
        "nulls": len(answer) - len(seen),
    }


def grouped_answers(rows: list[str]) -> list[int | None]:
    out: list[int | None] = []
    for line in rows:
        parts = line.split("|")
        if len(parts) != 2:
            return []
        try:
            out.append(int(parts[1]))
        except ValueError:
            out.append(None)
    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", type=pathlib.Path, default=DEFAULT_DIR)
    parser.add_argument("--bin", type=pathlib.Path)
    parser.add_argument("--json-out", type=pathlib.Path)
    parser.add_argument("--repeats", type=int, default=2)
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--keep", action="store_true", help="keep the parquet fixtures")
    args = parser.parse_args(argv)

    binary = args.bin if args.bin else find_bin()
    if not binary.exists():
        raise SystemExit(f"no binary at {binary}")
    print(
        f"binary {binary.relative_to(REPO) if binary.is_relative_to(REPO) else binary}"
        f"  built {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(binary.stat().st_mtime))}"
    )

    out_dir = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    fixtures = [
        f for f in FIXTURES if not args.quick or f[0] in QUICK_FIXTURES
    ]

    con = duckdb.connect()
    record: dict = {
        "binary": str(binary),
        "binary_mtime": time.strftime(
            "%Y-%m-%d %H:%M:%S", time.localtime(binary.stat().st_mtime)
        ),
        "repeats": args.repeats,
        "fixtures": [],
    }

    print(
        f"{'fixture':14} {'groups':>7} {'distinct':>9} {'rows':>10} "
        f"{'size':>9}"
    )
    built: list[tuple[tuple[str, int, int, int], pathlib.Path]] = []
    for spec in fixtures:
        label, groups, distinct, copies = spec
        path = build_fixture(con, out_dir, label, groups, distinct, copies)
        size_mb = path.stat().st_size / (1024 * 1024)
        print(
            f"{label:14} {groups:7d} {distinct:9d} {groups * distinct * copies:10d} "
            f"{size_mb:8.1f}M"
        )
        built.append((spec, path))

    for spec, path in built:
        label, groups, distinct, copies = spec
        stem = path.stem
        entry: dict = {
            "fixture": label,
            "groups": groups,
            "distinct_per_group": distinct,
            "copies": copies,
            "rows": groups * distinct * copies,
            "file_bytes": path.stat().st_size,
            "queries": {},
        }
        print(f"\n== {label} ({groups} groups x {distinct} distinct x {copies})")
        for qlabel, sql in queries(stem):
            result = measure(
                [str(binary), "exec", "--parquet", str(path), sql], args.repeats
            )
            rows = rows_of(result["stdout"])
            entry["queries"][qlabel] = {
                "sql": sql,
                "peak_mb": round(result["peak_mb"], 1),
                "wall_ms": round(result["wall_ms"], 1),
                "answer": answer_record(
                    scalar_answer(rows)
                    if "group by" not in sql
                    else grouped_answers(rows)
                ),
            }
            print(
                f"  {qlabel:28} {result['peak_mb']:8.1f} MB "
                f"{result['wall_ms']:9.1f} ms"
            )
        # Every group has to come back: a truncated or lost group would make the
        # resource numbers describe a smaller query than the one claimed.
        control = entry["queries"]["k, count(s)"]["answer"]
        if control["rows"] != groups:
            raise SystemExit(
                f"{label}: the grouped control returned {control['rows']} groups, "
                f"expected {groups}"
            )
        record["fixtures"].append(entry)

    # The two derived numbers H0 is actually about. Both subtract the group-map
    # control, because the map is paid whether or not a sketch is kept.
    print("\n== derived per-group cost (approx - count, over the group count)")
    print(f"{'fixture':14} {'groups':>7} {'per group':>10}")
    for entry in record["fixtures"]:
        q = entry["queries"]
        approx = q["k, approx_count_distinct(s)"]["peak_mb"]
        control = q["k, count(s)"]["peak_mb"]
        per_group = (approx - control) * 1024 * 1024 / entry["groups"]
        entry["per_group_bytes"] = round(per_group, 1)
        print(f"{entry['fixture']:14} {entry['groups']:7d} {per_group:9.0f} B")

    print("\n== crossover: exact vs sketch at 1,000 groups")
    print(f"{'distinct':>9} {'exact':>10} {'approx':>10} {'exact-approx':>13}")
    for entry in record["fixtures"]:
        if entry["groups"] != 1000 or entry["copies"] != 1:
            continue
        q = entry["queries"]
        exact = q["k, count(DISTINCT s)"]["peak_mb"]
        approx = q["k, approx_count_distinct(s)"]["peak_mb"]
        print(
            f"{entry['distinct_per_group']:9d} {exact:9.1f}M {approx:9.1f}M "
            f"{(exact - approx):12.1f}M"
        )

    if not args.keep:
        for _, path in built:
            path.unlink(missing_ok=True)

    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        print(f"\nrecord in {args.json_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
