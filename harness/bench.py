# Benchmark the TPC-H queries: moonlake (native binary, best of 3) vs
# duckdb (best of 3, in-process). Purely informational — the plan
# promises reproducible numbers, not superiority.
#
# Usage:
#   moon build cmd/main --target native     # compile first: the module's
#                                           # preferred target is wasm-gc
#   uv run --python 3.12 --with-requirements harness/requirements.txt python harness/bench.py      # SF0.01
#   uv run --python 3.12 --with-requirements harness/requirements.txt python harness/bench.py 0.1  # SF0.1

import pathlib
import re
import subprocess
import sys
import time

import duckdb

root = pathlib.Path(__file__).parent.parent
sf = sys.argv[1] if len(sys.argv) > 1 else "0.01"
tag = f"sf{sf.replace('.', '')}"
data = root / "harness" / "data" / tag

BIN = root / "_build" / "native" / "debug" / "build" / "cmd" / "main" / "main.exe"

TABLES = (
    "customer",
    "lineitem",
    "nation",
    "orders",
    "part",
    "partsupp",
    "region",
    "supplier",
)
QUERIES = sorted((f"q{i}" for i in range(1, 23)), key=lambda q: int(q[1:]))


# the csv files a query scans, derived from the official text (the
# parquet chain is excluded). String literals are stripped first so
# pattern words can never look like tables; tables follow FROM, JOIN
# or a comma in a FROM list.
def tables_for(sql: str) -> list[str]:
    bare = re.sub(r"'[^']*'", "''", sql)
    found: list[str] = []
    for m in re.finditer(rf"(?:\bfrom\b|\bjoin\b|,)\s+({'|'.join(TABLES)})\b", bare, re.I):
        t = m.group(1).lower()
        if t not in found:
            found.append(t)
    return found


def best_of(fn, n=3) -> float:
    best = float("inf")
    for _ in range(n):
        t0 = time.perf_counter()
        fn()
        best = min(best, time.perf_counter() - t0)
    return best


def main() -> int:
    if not BIN.exists():
        print(
            f"missing {BIN}; run `moon build cmd/main --target native` first",
            file=sys.stderr,
        )
        return 1
    con = duckdb.connect()
    con.execute(f"CALL dbgen(sf = {float(sf)})")

    print("| query | moonlake native (best of 3) | duckdb (best of 3) |")
    print("|---|---|---|")
    for name in QUERIES:
        sql = (root / "harness" / "queries" / f"{name}.sql").read_text()
        csvs = []
        for t in tables_for(sql):
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
