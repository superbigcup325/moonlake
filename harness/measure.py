# Performance + memory measurement for the verification report.
# Runs the native binary (not `moon run`) so process numbers are the
# engine's own: wall time per query (best of 3) and max RSS via
# /usr/bin/time -v. Ingest is measured as the delta between a full
# query run and a `LIMIT 0` run over the same table set (same scan,
# zero projection work).
#
# Usage: python3 harness/measure.py [sf-tag sf-tag ...]
#        default: sf001 sf01  (data must exist: harness/gen_tpch.py)

import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BIN = REPO / "_build/native/debug/build/cmd/main/main.exe"

QUERIES = {
    "q1": ["lineitem"],
    "q6": ["lineitem"],
    "q5": ["customer", "orders", "lineitem", "supplier", "nation", "region"],
    "q2": ["part", "supplier", "partsupp", "nation", "region"],
    "q17": ["lineitem", "part"],
}


WRAPPER = (
    "import resource, subprocess, sys, time;"
    "t0 = time.perf_counter();"
    "p = subprocess.run(sys.argv[1:], capture_output=True);"
    "wall = time.perf_counter() - t0;"
    "rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss;"
    "print(wall, rss, p.returncode)"
)


def run(cmd: list[str]) -> tuple[float, int, int]:
    # an isolated python child per run: its RUSAGE_CHILDREN high-water
    # mark is the measured process's own max RSS
    proc = subprocess.run(
        ["python3", "-c", WRAPPER] + cmd, capture_output=True, text=True
    )
    wall, rss, code = proc.stdout.split()
    return float(wall), int(rss), int(code)


def measure(tag: str) -> None:
    data = REPO / "harness/data" / tag
    if not data.exists():
        print(f"{tag}: no data (run gen_tpch.py), skipped")
        return
    print(f"== {tag}")
    for q, tables in QUERIES.items():
        sql = (REPO / f"harness/queries/{q}.sql").read_text()
        cmd = [str(BIN), "exec"]
        for t in tables:
            cmd += ["--csv", str(data / f"{t}.csv")]
        best = 1e9
        rss = -1
        for _ in range(3):
            wall, r, code = run(cmd + [sql])
            if code != 0:
                print(f"  {q}: FAILED ({r})")
                break
            best = min(best, wall)
            rss = max(rss, r)
        print(f"  {q}: {best * 1000:8.0f} ms   maxRSS {rss / 1024:7.1f} MB")
    # ingest-only: same scans, zero projection (LIMIT 0)
    q1_tables = QUERIES["q1"]
    cmd = [str(BIN), "exec"]
    for t in q1_tables:
        cmd += ["--csv", str(data / f"{t}.csv")]
    wall, rss, code = run(cmd + ["SELECT l_returnflag FROM lineitem LIMIT 0"])
    if code == 0:
        print(f"  ingest scan (lineitem, LIMIT 0): {wall * 1000:8.0f} ms   maxRSS {rss / 1024:7.1f} MB")


if __name__ == "__main__":
    if not BIN.exists():
        print("build first: moon build cmd/main --target native")
        sys.exit(1)
    tags = sys.argv[1:] or ["sf001", "sf01"]
    for tag in tags:
        measure(tag)
