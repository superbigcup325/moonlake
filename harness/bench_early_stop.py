# What a query costs its source, before and after the executor learns to stop
# early: rows the scan pulled, peak RSS, wall time, and whether the answer is
# right.
#
# The case that matters is `select ... limit 10` over a file far larger than
# the result. Today it reads the whole file and only then cuts the result, so
# its scan row count is the table's row count and its RSS tracks the input.
# After a batched scan with backpressure that count falls to a batch or two,
# and the recorded baseline is how a later run notices. The counts that must
# NOT fall are pinned too: an aggregate, an unindexed ORDER BY and a derived
# table still need every row, and a change that shrank those would be dropping
# rows it still owes.
#
# Usage:
#   python3 harness/bench_early_stop.py                    # measure, print a table
#   python3 harness/bench_early_stop.py --json-out harness/baseline/2026-10-25-early-stop.json
#   python3 harness/bench_early_stop.py --compare harness/baseline/2026-10-25-early-stop.json
#   python3 harness/bench_early_stop.py --quick            # fewer rows, one run
#
# Peak RSS is read with `os.wait4` for that one child, but the waiting process
# is a tiny stdlib-only helper rather than this script: a forked child shares
# its parent's resident pages until `exec`, so a parent holding a DuckDB result
# would report its own RSS as the query's. The helper's floor is measured once
# with `/bin/true` and recorded, so a case that looks free says how free.
#
# The fixture is generated from a seed and hashed, so a second agent gets the
# same bytes from the same command: the data is described in the record, not
# committed to the repository. Peak RSS comes from `os.wait4`'s rusage for that
# one child (never a running maximum across children), and stdout goes to a
# file whose SHA-256 is recorded, so a case whose output changed has changed
# its work. Correctness is judged against DuckDB, which reads the same file
# through its own CSV/Parquet readers.

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import random
import subprocess
import sys
import tempfile

import duckdb

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import bench_release as br  # noqa: E402  (same directory: reuse the measurement code)

REPO = br.REPO
DATA = REPO / "harness" / "data" / "early-stop"
SCHEMA = 1

# The fixture's columns, in order, with the type each value is compared as. A
# comparison that told "3" from "3.0" by text would call a formatting
# difference an answer difference.
COLUMNS = [
    ("id", "int"),
    ("i32", "int"),
    ("i64", "int"),
    ("f64", "float"),
    ("cat", "str"),
    ("flag", "int"),
]
TYPES = dict(COLUMNS) | {"n": "int"}  # `n` aliases COUNT(*)
CATS = ["alpha", "beta", "gamma", "delta", "epsilon"]


def typed(value, kind: str):
    """One cell as its column type, so both sides compare as values."""
    if kind == "float":
        return float(value)
    if kind == "int":
        return int(value)
    return str(value)


def write_fixture(path: pathlib.Path, rows: int, seed: int) -> None:
    """Write the fixture deterministically: same seed and rows, same bytes."""
    rng = random.Random(seed)
    with open(path, "w", encoding="utf-8", newline="\n") as out:
        out.write(",".join(name for name, _ in COLUMNS) + "\n")
        for i in range(rows):
            cat = CATS[rng.randrange(len(CATS))]
            # halves, so a float prints the same way to both readers
            f64 = rng.randrange(-4000, 4000) / 2.0
            out.write(
                f"{i},{rng.randrange(-1000, 1000)},{rng.randrange(-10**12, 10**12)},"
                f"{f64},{cat},{rng.randrange(2)}\n"
            )


def fixture(rows: int, seed: int, binary: pathlib.Path) -> tuple[pathlib.Path, dict]:
    """CSV and Parquet of the same rows; the Parquet is written by this CLI.

    The directory is named by the parameters, so a run can never reuse bytes
    that a different row count or seed produced — a stale fixture would make
    two records look comparable when they are not.
    """
    dir_ = DATA / f"rows{rows}-seed{seed}"
    dir_.mkdir(parents=True, exist_ok=True)
    csv = dir_ / "t.csv"
    parquet = dir_ / "t.parquet"
    if not csv.exists():
        write_fixture(csv, rows, seed)
    if not parquet.exists():
        subprocess.run(
            [str(binary), "write", "--csv", str(csv), "--out", str(parquet)],
            check=True,
            capture_output=True,
        )
    csv_sha = hashlib.sha256(csv.read_bytes()).hexdigest()
    return dir_, {
        "rows": rows,
        "seed": seed,
        "columns": [name for name, _ in COLUMNS],
        "csv_sha256": csv_sha,
        "csv_bytes": csv.stat().st_size,
        "parquet_bytes": parquet.stat().st_size,
    }


def case_specs(rows: int) -> list[dict]:
    half = rows // 2
    """The cases, each with the columns it returns and the check it gets.

    `check` is how the answer is judged:
      exact   - the rows as a multiset
      ordered - the rows in order (a query that defines an order)
      shape   - row count plus the sum of one column, for a result too large to
                hold, against the analytic answer
      subset  - the count is exact and every row exists: what a LIMIT without
                ORDER BY actually promises (the engine picks no particular
                rows, so neither does the check)
    `scan_rows` is today's baseline pull count for a case whose count is
    expected to move (a LIMIT). `scan_check` states what a count must satisfy
    no matter what: "all" the table's rows, "none" of them, or a predicate the
    scanned rows must exactly match — so the cases that may not shrink are
    pinned by a rule and not by a remembered number.
    """
    every = [name for name, _ in COLUMNS]
    return [
        {
            "id": "scan/count",
            "what": "COUNT(*) over the whole file",
            "sql": "select count(*) as n from t",
            "cols": ["n"],
            "check": "exact",
            "scan_check": "all",
        },
        {
            "id": "scan/limit",
            "what": "SELECT * LIMIT 10: the case early stop is about",
            "sql": "select * from t limit 10",
            "cols": every,
            "check": "subset",
            "scan_rows": rows,
        },
        {
            "id": "scan/limit_narrow",
            "what": "one projected column, LIMIT 10",
            "sql": "select id from t limit 10",
            "cols": ["id"],
            "check": "subset",
            "scan_rows": rows,
        },
        {
            "id": "scan/filter_limit",
            "what": "a filter that keeps nothing, LIMIT 10",
            "sql": "select * from t where i32 < -1000 limit 10",
            "cols": every,
            "check": "subset",
            "scan_check": "none",
        },
        {
            "id": "scan/filter_count",
            "what": "filter plus aggregate: reads every row on purpose",
            "sql": "select count(*) as n from t where i32 < 0",
            "cols": ["n"],
            "check": "exact",
            "scan_check": {"predicate": "i32 < 0"},
        },
        {
            "id": "scan/sort_limit",
            "what": "ORDER BY on two columns, LIMIT 10",
            "sql": "select id, i32 from t order by i32, id limit 10",
            "cols": ["id", "i32"],
            "check": "ordered",
            "scan_check": "all",
        },
        {
            "id": "scan/offset",
            "what": "OFFSET deep into an ordered result",
            "sql": f"select id from t order by id limit 5 offset {half}",
            "cols": ["id"],
            "check": "ordered",
            "scan_check": "all",
        },
        {
            "id": "scan/derived_limit",
            "what": "a derived table under an outer LIMIT",
            "sql": "select * from (select id from t) s limit 10",
            "cols": ["id"],
            "check": "subset",
            "scan_rows": rows,
            "analyze": False,  # EXPLAIN does not descend into derived tables yet
        },
        {
            "id": "scan/full",
            "what": "every row printed: the collector path",
            "sql": "select id from t",
            "cols": ["id"],
            "check": "shape",
            "scan_check": "all",
            "sum_column": "id",
        },
        {
            "id": "scan/parquet_count",
            "what": "COUNT(*) over the Parquet file",
            "sql": "select count(*) as n from t",
            "cols": ["n"],
            "check": "exact",
            "scan_check": "all",
            "format": "parquet",
        },
        {
            "id": "scan/parquet_limit",
            "what": "SELECT * LIMIT 10 over the Parquet file",
            "sql": "select * from t limit 10",
            "cols": every,
            "check": "subset",
            "scan_rows": rows,
            "format": "parquet",
        },
    ]


MEASURER = r"""
import json, os, subprocess, sys, tempfile, time
out_path = sys.argv[1]
with tempfile.TemporaryFile() as err:
    t0 = time.monotonic()
    with open(out_path, "wb") as out:
        proc = subprocess.Popen(sys.argv[2:], stdout=out, stderr=err)
        try:
            _, status, usage = os.wait4(proc.pid, 0)
        except AttributeError:  # non-POSIX: no rusage, report zeros
            proc.wait()
            status, usage = None, None
    wall_ms = (time.monotonic() - t0) * 1000.0
    rc = os.waitstatus_to_exitcode(status) if status is not None else proc.returncode
    if rc != 0:
        err.seek(0)
        print(json.dumps({
            "rc": rc, "wall_ms": wall_ms, "rss_mb": 0.0, "cpu_ms": 0.0,
            "error": err.read().decode(errors="replace")[-2000:],
        }))
    else:
        peak = usage.ru_maxrss if usage is not None else 0
        cpu = (usage.ru_utime + usage.ru_stime) * 1000.0 if usage is not None else 0.0
        print(json.dumps({"rc": 0, "wall_ms": wall_ms, "rss_mb": peak / 1024.0, "cpu_ms": cpu}))
"""


def measure_one(cmd: list[str], out_path: pathlib.Path) -> dict:
    """Run `cmd` once in its own process; its own peak RSS, wall and CPU."""
    proc = subprocess.run(
        [sys.executable, "-c", MEASURER, str(out_path), *cmd],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        raise SystemExit(
            f"the measurement helper failed ({proc.returncode}): {' '.join(cmd)}\n"
            f"{proc.stdout[-500:]}{proc.stderr[-2000:]}"
        )
    return json.loads(proc.stdout)


def measure_isolated(
    cmd: list[str], runs: int, scratch: pathlib.Path, floor_mb: float
) -> dict:
    """Two warm-ups then `runs` samples, the fastest one recorded.

    `rss_mb` is the child's peak minus the floor a bare `/bin/true` reports
    through this path: a forked child carries its parent's resident pages until
    it execs, so the raw number has a constant in it and only the part above
    the floor is the query's own.
    """
    out_path = scratch / "stdout.txt"
    for _ in range(br.WARMUPS):
        measure_one(cmd, out_path)
    samples = []
    digests = set()
    for _ in range(runs):
        sample = measure_one(cmd, out_path)
        if sample["rc"] != 0:
            raise SystemExit(
                f"bench case failed ({sample['rc']}): {' '.join(cmd)}\n"
                f"{sample.get('error', '')}"
            )
        samples.append(sample)
        digests.add(hashlib.sha256(out_path.read_bytes()).hexdigest())
    if len(digests) != 1:
        raise SystemExit(
            f"{' '.join(cmd)}: output changed between runs, so the timings "
            "describe different work"
        )
    walls = [s["wall_ms"] for s in samples]
    best = min(samples, key=lambda s: s["wall_ms"])
    digest = digests.pop()
    spread = (
        round((max(walls) - min(walls)) / min(walls) * 100.0, 1)
        if runs > 1 and min(walls) > 0
        else None
    )
    return {
        "wall_ms": round(best["wall_ms"], 1),
        "median_ms": round(sorted(walls)[len(walls) // 2], 1),
        "cpu_ms": round(best["cpu_ms"], 1),
        "rss_mb": round(max(best["rss_mb"] - floor_mb, 0.0), 1),
        "rss_raw_mb": round(best["rss_mb"], 1),
        "wall_spread_pct": spread,
        "output_sha256": digest,
    }


def analyze_pulls(binary: pathlib.Path, argv: list[str]) -> tuple[int, int]:
    """(rows the scan pulled, rows the query returned) from `--analyze`.

    The scan's own count is the deterministic observable: it says how much of
    the input the executor asked for, which is the number a batched scan moves.
    """
    proc = subprocess.run(
        [str(binary), "exec", "--analyze", *argv], capture_output=True, text=True
    )
    if proc.returncode != 0:
        raise SystemExit(
            f"ANALYZE failed ({proc.returncode}): {' '.join(argv)}\n"
            f"{proc.stderr[-2000:]}"
        )
    pulled = returned = None
    for line in proc.stdout.splitlines():
        if line.startswith("scan ") and ":" in line:
            pulled = int(line.rsplit(":", 1)[1].strip())
        elif line.startswith("result:"):
            returned = int(line.split(":", 1)[1].strip())
    if pulled is None or returned is None:
        raise SystemExit(
            f"ANALYZE printed no scan/result row for {argv[-1]!r}: {proc.stdout[-800:]}"
        )
    return pulled, returned


def oracle_conn(path: pathlib.Path, fmt: str):
    """A DuckDB connection with the fixture registered as `t`."""
    con = duckdb.connect()
    if fmt == "parquet":
        con.execute(f"create view t as select * from read_parquet('{path.as_posix()}')")
    else:
        con.execute(
            f"create view t as select * from read_csv_auto('{path.as_posix()}', header=true)"
        )
    return con


def parse_rows(text: str, cols: list[str]) -> list[tuple]:
    """The answer rows, header dropped: the CLI prints column names first."""
    kinds = [TYPES[name] for name in cols]
    lines = [line for line in text.splitlines() if line]
    return [
        tuple(typed(cell, kind) for cell, kind in zip(line.split("|"), kinds))
        for line in lines[1:]
    ]


def oracle_rows(con, sql: str, cols: list[str]) -> list[tuple]:
    kinds = [TYPES[name] for name in cols]
    return [
        tuple(typed(cell, kind) for cell, kind in zip(row, kinds))
        for row in con.execute(sql).fetchall()
    ]


def check_answer(spec: dict, text: str, con) -> None:
    """Fail loudly when the answer differs from the independent oracle."""
    ours = parse_rows(text, spec["cols"])
    kind = spec["check"]
    if kind == "shape":
        column = spec["sum_column"]
        want = con.execute(
            f"select count(*), sum({column}) from ({spec['sql']}) q"
        ).fetchall()[0]
        index = spec["cols"].index(column)
        got = (len(ours), sum(row[index] for row in ours))
        if got != (int(want[0]), int(want[1])):
            raise SystemExit(
                f"{spec['id']}: {got[0]} rows / sum {got[1]}, oracle says "
                f"{want[0]} / {want[1]}"
            )
        return
    want = oracle_rows(con, spec["sql"], spec["cols"])
    if kind == "ordered":
        if ours != want:
            raise SystemExit(f"{spec['id']}: rows differ from the oracle in order")
        return
    if kind == "exact":
        if sorted(ours) != sorted(want):
            raise SystemExit(f"{spec['id']}: rows differ from the oracle")
        return
    if kind == "subset":
        if len(ours) != len(want):
            raise SystemExit(
                f"{spec['id']}: {len(ours)} rows, the oracle's LIMIT returned {len(want)}"
            )
        # The fixture's `id` is unique, so one lookup per row decides whether
        # the rows the engine returned are rows of the table.
        index = spec["cols"].index("id")
        for row in ours:
            found = con.execute("select count(*) from t where id = ?", [row[index]])
            if found.fetchall()[0][0] != 1:
                raise SystemExit(f"{spec['id']}: id {row[index]} is not in the table")
        return
    raise SystemExit(f"{spec['id']}: unknown check {kind}")


def check_pull(spec: dict, pulled: int, table_rows: int, con) -> None:
    """Enforce the pull-side invariant a case declares, if it declares one."""
    rule = spec.get("scan_check")
    if rule is None:
        return
    if rule == "all" and pulled != table_rows:
        raise SystemExit(
            f"{spec['id']}: the scan pulled {pulled} of {table_rows} rows, but this "
            "query needs every row; stopping early here would drop rows it still owes"
        )
    if rule == "none" and pulled != 0:
        raise SystemExit(
            f"{spec['id']}: the scan emitted {pulled} rows for a predicate that keeps "
            "none of them"
        )
    if isinstance(rule, dict) and con is not None:
        want = con.execute(
            f"select count(*) from t where {rule['predicate']}"
        ).fetchall()[0][0]
        if pulled != want:
            raise SystemExit(
                f"{spec['id']}: the scan emitted {pulled} rows for "
                f"`{rule['predicate']}`, which keeps {want}: the pushdown lost or "
                "invented rows"
            )


def run_cases(
    specs: list[dict],
    binary: pathlib.Path,
    runs: int,
    scratch: pathlib.Path,
    dir_: pathlib.Path,
    table_rows: int,
    floor_mb: float,
) -> list[dict]:
    results = []
    for spec in specs:
        fmt = spec.get("format", "csv")
        path = dir_ / ("t.parquet" if fmt == "parquet" else "t.csv")
        argv = [f"--{fmt}", str(path), spec["sql"]]
        pulled = returned = None
        if spec.get("analyze", True):
            pulled, returned = analyze_pulls(binary, argv)
            if spec.get("scan_rows") is not None and pulled != spec["scan_rows"]:
                print(
                    f"  ! {spec['id']}: the scan pulled {pulled} rows, the baseline "
                    f"was {spec['scan_rows']} — the pull side moved, which is what "
                    "this script exists to show; re-record deliberately",
                    flush=True,
                )
        measured = measure_isolated(
            [str(binary), "exec", *argv], runs, scratch, floor_mb
        )
        # measure() drains every run's stdout into scratch/stdout.txt; the last
        # run's text is what the oracle checks, and `output_stable` says all
        # runs agreed.
        text = (scratch / "stdout.txt").read_text()
        con = oracle_conn(path, fmt)
        try:
            if pulled is not None:
                check_pull(spec, pulled, table_rows, con)
            check_answer(spec, text, con)
        finally:
            con.close()
        record = {
            "id": spec["id"],
            "what": spec["what"],
            "sql": spec["sql"],
            "scan_rows": pulled,
            "result_rows": returned,
            **measured,
        }
        results.append(record)
        print(
            f"  {record['id']:<20} {record['wall_ms']:>8.1f} ms  "
            f"RSS {record['rss_mb']:>6.1f} MB  scan {str(pulled):>8} rows  "
            f"out {str(returned):>6} rows",
            flush=True,
        )
    return results


def compare(record: dict, previous: dict) -> int:
    """Print what moved since a previous record; non-zero when answers moved."""
    if record["fixture"]["csv_sha256"] != previous["fixture"]["csv_sha256"]:
        print(
            "fixture differs: the two records describe different bytes, so this "
            "is not a before/after"
        )
        return 1
    print("\n| case | scan pulled | peak RSS MB | wall ms | answer |")
    print("|---|---|---|---|---|")
    problems = 0
    for case in record["cases"]:
        old = next((c for c in previous["cases"] if c["id"] == case["id"]), None)
        if old is None:
            print(f"| {case['id']} | new case | | | |")
            continue
        pulled = (
            f"{old['scan_rows']} -> {case['scan_rows']}"
            if old["scan_rows"] != case["scan_rows"]
            else str(case["scan_rows"])
        )
        answer = (
            "ok"
            if old.get("output_sha256") == case.get("output_sha256")
            else "CHANGED"
        )
        if answer == "CHANGED":
            problems += 1
        print(
            f"| {case['id']} | {pulled} | {old['rss_mb']} -> {case['rss_mb']} | "
            f"{old['wall_ms']} -> {case['wall_ms']} | {answer} |"
        )
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="early-stop baseline")
    parser.add_argument("--rows", type=int, default=2_000_000)
    parser.add_argument("--seed", type=int, default=20261025)
    parser.add_argument("--runs", type=int, default=2)
    parser.add_argument("--binary", type=pathlib.Path)
    parser.add_argument("--json-out", type=pathlib.Path)
    parser.add_argument("--compare", type=pathlib.Path)
    parser.add_argument("--quick", action="store_true", help="200k rows, one run")
    args = parser.parse_args(argv)

    rows = 200_000 if args.quick else args.rows
    runs = 1 if args.quick else args.runs
    if rows < 1000:
        raise SystemExit("--rows must be at least 1000, or the cases measure nothing")

    binary = args.binary or br.release_binary()
    if not binary.exists():
        raise SystemExit(f"binary not found: {binary} (build it, or pass --binary)")

    print(f"fixture: {rows} rows, seed {args.seed}")
    dir_, data = fixture(rows, args.seed, binary)
    print(
        f"  csv {data['csv_bytes'] / 2**20:.1f} MiB sha {data['csv_sha256'][:16]}  "
        f"parquet {data['parquet_bytes'] / 2**20:.1f} MiB  in {dir_.relative_to(REPO)}"
    )

    scratch = pathlib.Path(tempfile.mkdtemp(prefix="moonlake-early-stop-"))
    floor = measure_one(["/bin/true"], scratch / "floor.txt")["rss_mb"]
    print(
        f"  measurement floor: {floor:.1f} MB (what /bin/true costs through it; "
        "RSS below is reported above that floor)"
    )
    specs = case_specs(rows)
    print(f"{len(specs)} cases, {runs} timed run(s) each")
    cases = run_cases(specs, binary, runs, scratch, dir_, rows, floor)

    record = {
        "schema": SCHEMA,
        "what": "what a query costs its source: scan rows pulled, RSS, time",
        "toolchain": br.toolchain(br.find_moon()),
        "git": br.git_state(),
        "machine": br.machine(),
        "fixture": data,
        "measure_floor_mb": round(floor, 1),
        "binary": (
            str(binary.relative_to(REPO)) if binary.is_relative_to(REPO) else str(binary)
        ),
        "cases": cases,
    }
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(record, indent=2) + "\n")
        print(f"\nrecord: {args.json_out}")
    problems = compare(record, json.loads(args.compare.read_text())) if args.compare else 0
    print("\n| case | scan pulled | result rows | wall ms | peak RSS MB |")
    print("|---|---|---|---|---|")
    for case in cases:
        print(
            f"| {case['id']} | {case['scan_rows']} | {case['result_rows']} | "
            f"{case['wall_ms']} | {case['rss_mb']} |"
        )
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
