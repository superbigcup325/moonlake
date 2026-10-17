#!/usr/bin/env python3
"""Measure the spill format: write and read wall time, size, peak RSS.

Builds the release binary, then runs write and read separately, best of N,
with an isolated child per run so RUSAGE_CHILDREN is that process's own peak.

Usage:
    python3 harness/spill_bench.py [--csv file] [--runs 3] [--no-build]
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BIN = (
    REPO
    / "_build/native/release/build/superbigcup325/moonlake/harness/spill_bench/spill_bench.exe"
)
OUT = Path("/tmp/moonlake-spill-bench.bin")

WRAPPER = (
    "import resource, subprocess, sys, time;"
    "t0 = time.perf_counter();"
    "p = subprocess.run(sys.argv[1:], capture_output=True, text=True);"
    "wall = time.perf_counter() - t0;"
    "rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss;"
    "print(wall, rss, p.returncode);"
    "print(p.stdout, end='')"
)


def measure(args: list[str]) -> tuple[float, int, str]:
    proc = subprocess.run(
        [sys.executable, "-c", WRAPPER] + args, capture_output=True, text=True, check=False
    )
    if proc.returncode != 0:
        raise SystemExit(f"bench failed: {proc.stderr or proc.stdout}")
    lines = proc.stdout.splitlines()
    wall, rss, code = lines[0].split()
    if code != "0":
        raise SystemExit(f"bench exited {code}: {lines[1:]}")
    return float(wall), int(rss), "\n".join(lines[1:])


def checksum(output: str, tag: str) -> str:
    for line in output.splitlines():
        if line.startswith(tag) and "checksum=" in line:
            return line.split("checksum=")[1].split()[0]
    raise SystemExit(f"missing {tag} checksum in: {output}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--csv", default="harness/data/sf001/lineitem.csv")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--no-build", action="store_true")
    args = parser.parse_args()

    if not args.no_build:
        subprocess.run(
            ["moon", "build", "--target", "native", "--release", "harness/spill_bench"],
            cwd=REPO,
            check=True,
            capture_output=True,
        )

    writes = []
    write_out = ""
    for _ in range(args.runs):
        wall, rss, out = measure(
            [str(BIN), "--mode", "write", "--csv", args.csv, "--out", str(OUT)]
        )
        writes.append((wall, rss))
        write_out = out
    reads = []
    read_out = ""
    for _ in range(args.runs):
        wall, rss, out = measure([str(BIN), "--mode", "read", "--in", str(OUT)])
        reads.append((wall, rss))
        read_out = out

    w_wall, w_rss = min(writes)
    r_wall, r_rss = min(reads)
    size = OUT.stat().st_size
    w_sum = checksum(write_out, "write")
    r_sum = checksum(read_out, "read")
    if w_sum != r_sum:
        raise SystemExit(f"checksum mismatch: write {w_sum} read {r_sum}")

    print(f"rows     {write_out.split('rows=')[1].split()[0]}")
    print(f"bytes    {size} ({size / (1 << 20):.2f} MiB)")
    print(f"write    {w_wall * 1000:.1f} ms   peak RSS {w_rss / 1024:.1f} MiB")
    print(f"read     {r_wall * 1000:.1f} ms   peak RSS {r_rss / 1024:.1f} MiB")
    print(f"checksum {w_sum}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
