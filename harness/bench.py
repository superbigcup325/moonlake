# Benchmark the golden queries: moonlake (native binary, best of 3) vs
# duckdb (best of 3, in-process). Purely informational — the plan
# promises reproducible numbers, not superiority.
#
# Usage:
#   moon build cmd/main                      # compile first
#   uv run --with duckdb python harness/bench.py

import pathlib
import subprocess
import sys
import time

import duckdb

root = pathlib.Path(__file__).parent.parent
data = root / "harness" / "data" / "sf001"

BIN = root / "_build" / "native" / "debug" / "build" / "cmd" / "main" / "main.exe"

# query name -> csv files it scans (the parquet chain is excluded)
CSV = {
    "q1": ["lineitem"],
    "q3": ["customer", "orders", "lineitem"],
    "q5": ["customer", "orders", "lineitem", "supplier", "nation", "region"],
    "q6": ["lineitem"],
    "q7": ["supplier", "lineitem", "orders", "customer", "nation", "nation"],
    "q10": ["customer", "orders", "lineitem", "nation"],
    "q12": ["orders", "lineitem"],
    "q14": ["lineitem", "part"],
}


def best_of(fn, n=3) -> float:
    best = float("inf")
    for _ in range(n):
        t0 = time.perf_counter()
        fn()
        best = min(best, time.perf_counter() - t0)
    return best


def main() -> int:
    if not BIN.exists():
        print(f"missing {BIN}; run `moon build cmd/main` first", file=sys.stderr)
        return 1
    con = duckdb.connect()
    con.execute("CALL dbgen(sf = 0.01)")

    print("| query | moonlake native (best of 3) | duckdb (best of 3) |")
    print("|---|---|---|")
    for name in sorted(CSV):
        sql = (root / "harness" / "queries" / f"{name}.sql").read_text()
        csvs = []
        for t in CSV[name]:
            csvs += ["--csv", str(data / f"{t}.csv")]
        def moonlake():
            subprocess.run(
                [str(BIN), "exec", *csvs, sql],
                check=True,
                stdout=subprocess.DEVNULL,
            )
        ml = best_of(moonlake)
        def duck():
            con.execute(sql).fetchall()
        db = best_of(duck)
        print(f"| {name} | {ml * 1000:.0f} ms | {db * 1000:.1f} ms |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
