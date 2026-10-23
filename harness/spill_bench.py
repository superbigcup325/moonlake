#!/usr/bin/env python3
"""Measure the spill format: write and read wall time, size, peak RSS.

Builds the release binary, then runs write and read separately, best of N,
with an isolated child per run so RUSAGE_CHILDREN is that process's own peak.

Usage:
    python3 harness/spill_bench.py [--csv file] [--runs 3] [--no-build]
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import pathlib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = Path("/tmp/moonlake-spill-bench.bin")
BUILD = "moon build --target native --release harness/spill_bench"


def newest_binary() -> Path:
    """The release driver the current toolchain produced.

    The path gained a module prefix once and lost it again, and a stale binary
    under the old one measured the old format while the source said otherwise —
    so locate it by name and take the newest instead of hardcoding the layout.
    """
    found = sorted(
        REPO.glob("_build/native/release/build/**/spill_bench.exe"),
        key=lambda p: p.stat().st_mtime,
    )
    if not found:
        raise SystemExit(f"spill_bench: no release binary; run `{BUILD}`")
    return found[-1]


def newest_source() -> float:
    """Mtime of the most recently touched input the driver is built from.

    `moon.mod` is deliberately not consulted: a version bump does not change
    the driver's code, but `moon build` has nothing to rebuild for it, so
    including its mtime would report a fresh binary as stale (0.3.1 hit this).
    The packages the driver actually links are checked instead.
    """
    stamps = []
    for root in (
        REPO / "harness/spill_bench",
        REPO / "types",
        REPO / "catalog",
        REPO / "sources/csv",
    ):
        stamps += [p.stat().st_mtime for p in root.rglob("*.mbt")]
    return max(stamps)

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


def csv_fingerprint(path: pathlib.Path) -> tuple[int, str]:
    """Rows and the first column's text checksum, read without the engine.

    The driver checksums the spill format's write against its own read, which
    only proves the format round-trips — the same encoder and decoder could be
    wrong together. This is the outside view: the CSV's own first-field text,
    hashed with the same FNV-1a 64 the driver uses (mix the bytes, then a 0
    separator after every value).
    """
    rows = 0
    h = 14695981039346656037
    with path.open("r", encoding="utf-8", newline="") as handle:
        next(handle, None)  # header
        for line in handle:
            line = line.rstrip("\r\n")
            if not line:
                continue
            rows += 1
            for byte in line.split(",", 1)[0].encode("utf-8"):
                h = ((h ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
            h = ((h ^ 0) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return rows, format(h, "x")


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
        subprocess.run(BUILD.split(), cwd=REPO, check=True, capture_output=True)

    bin_path = newest_binary()
    if bin_path.stat().st_mtime < newest_source():
        raise SystemExit(
            f"spill_bench: {bin_path} is older than the sources it is built "
            f"from; rebuild with `{BUILD}` (a stale driver reports the old "
            "format's numbers)"
        )

    writes = []
    write_out = ""
    for _ in range(args.runs):
        wall, rss, out = measure(
            [str(bin_path), "--mode", "write", "--csv", args.csv, "--out", str(OUT)]
        )
        writes.append((wall, rss))
        write_out = out
    reads = []
    read_out = ""
    for _ in range(args.runs):
        wall, rss, out = measure([str(bin_path), "--mode", "read", "--in", str(OUT)])
        reads.append((wall, rss))
        read_out = out

    w_wall, w_rss = min(writes)
    r_wall, r_rss = min(reads)
    size = OUT.stat().st_size
    w_sum = checksum(write_out, "write")
    r_sum = checksum(read_out, "read")
    if w_sum != r_sum:
        raise SystemExit(f"checksum mismatch: write {w_sum} read {r_sum}")
    write_rows = int(write_out.split("rows=")[1].split()[0])
    csv_rows, csv_col0 = csv_fingerprint(pathlib.Path(args.csv))
    driver_col0 = {}
    for tag, text in (("write", write_out), ("read", read_out)):
        match = re.search(r"col0=([0-9a-f]+)", text)
        if not match:
            raise SystemExit(f"driver did not report the {tag} col0 text checksum: {text}")
        driver_col0[tag] = match.group(1)
    if write_rows != csv_rows:
        raise SystemExit(f"row count: driver {write_rows}, CSV has {csv_rows} data rows")
    if driver_col0["write"] != csv_col0 or driver_col0["read"] != csv_col0:
        raise SystemExit(
            "first column does not match the CSV: "
            f"csv {csv_col0}, write {driver_col0['write']}, read {driver_col0['read']}"
        )

    print(f"rows     {write_rows} (CSV data rows {csv_rows}, first column verified)")
    print(f"bytes    {size} ({size / (1 << 20):.2f} MiB)")
    print(f"write    {w_wall * 1000:.1f} ms   peak RSS {w_rss / 1024:.1f} MiB")
    print(f"read     {r_wall * 1000:.1f} ms   peak RSS {r_rss / 1024:.1f} MiB")
    print(f"checksum {w_sum}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
