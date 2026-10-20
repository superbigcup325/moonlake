# A/B the scan layer: wall time and peak RSS for the queries that exercise
# column pruning (CSV and Parquet), scan-time filtering and row-group
# statistics. Informational, like bench.py: reproducible numbers, no promise
# of superiority.
#
# Usage:
#   moon build cmd/main --target native
#   python3 harness/bench_scan.py                     # current build only
#   python3 harness/bench_scan.py --base OLD_BINARY   # A/B against a build of
#                                                     # an older commit
#   python3 harness/bench_scan.py --big               # + a generated 1Mi-row,
#                                                     # 8-row-group parquet
#
# --big needs pyarrow: run with `uv run --with pyarrow python harness/bench_scan.py`.
# Timings are the fastest of --runs after one warm-up; RSS is the peak of the
# fastest run (os.wait4 rusage of the child), including process startup.

from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parent.parent
data = root / "harness" / "data" / "sf001"
here = root / "harness" / "queries"

DEFAULT = root / "_build" / "native" / "debug" / "build" / "superbigcup325" / "moonlake" / "cmd" / "main" / "main.exe"
FLAT = root / "_build" / "native" / "debug" / "build" / "cmd" / "main" / "main.exe"


def query(name: str) -> str:
    return (here / f"{name}.sql").read_text()


def peak_rss(pid: int) -> int:
    """VmHWM of a live process, in KiB; 0 when /proc is not readable."""
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmHWM:"):
                    return int(line.split()[1])
    except OSError:
        return 0
    return 0


def run_once(binary: pathlib.Path, argv: list[str]) -> tuple[float, int]:
    # sample VmHWM while the child runs: it is a high-water mark, so the last
    # observation is the peak, and unlike child rusage it is not polluted by
    # the parent's address space at fork time
    import subprocess

    t0 = time.monotonic()
    with open(os.devnull, "wb") as devnull:
        proc = subprocess.Popen([str(binary), *argv], stdout=devnull)
        peak = 0
        while proc.poll() is None:
            peak = max(peak, peak_rss(proc.pid))
            time.sleep(0.003)
        peak = max(peak, peak_rss(proc.pid))
    elapsed = time.monotonic() - t0
    if proc.returncode != 0:
        raise SystemExit(f"{binary.name} failed: {' '.join(argv)}")
    return elapsed * 1000.0, peak


def bench(binary: pathlib.Path, argv: list[str], runs: int) -> tuple[float, int]:
    run_once(binary, argv)  # warm the page cache
    best = None
    for _ in range(runs):
        ms, rss = run_once(binary, argv)
        if best is None or ms < best[0]:
            best = (ms, rss)
    assert best is not None
    return best


def cases(big: pathlib.Path | None) -> list[tuple[str, list[str]]]:
    lineitem = str(data / "lineitem.csv")
    pq = str(data / "lineitem.parquet")
    dates = ["--date-col", "l_shipdate", "--date-col", "l_commitdate", "--date-col", "l_receiptdate"]
    out: list[tuple[str, list[str]]] = [
        ("csv q1 (8 cols)", ["exec", "--csv", lineitem, query("q1")]),
        ("csv q6 (4 cols)", ["exec", "--csv", lineitem, query("q6")]),
        ("csv count(*)", ["exec", "--csv", lineitem, "select count(*) as c from lineitem"]),
        (
            "csv q3 (3 tables)",
            [
                "exec",
                "--csv",
                str(data / "customer.csv"),
                "--csv",
                str(data / "orders.csv"),
                "--csv",
                lineitem,
                query("q3"),
            ],
        ),
        ("parquet q6p (all cols)", ["exec", "--parquet", pq, *dates, query("q6p")]),
        ("parquet sum(quantity)", ["exec", "--parquet", pq, *dates, "select sum(l_quantity) as s from lineitem"]),
    ]
    if big is not None:
        path = str(big)
        out += [
            ("big count(*) no filter", ["exec", "--parquet", path, "select count(*) as c from big"]),
            ("big filter 6/8 groups", ["exec", "--parquet", path, "select count(*) as c from big where v >= 500000 and v < 600000"]),
            ("big filter 1/8 groups", ["exec", "--parquet", path, "select sum(v) as s from big where v >= 900000"]),
        ]
    return out


def make_big(rows: int, groups: int) -> pathlib.Path:
    import pyarrow as pa
    import pyarrow.parquet as pq

    group = rows // groups
    table = pa.table(
        {
            "v": pa.array(range(rows), pa.int64()),
            "k": pa.array([i % 1000 for i in range(rows)], pa.int32()),
            "s": pa.array([f"tag{i % 5000:05d}" for i in range(rows)], pa.string()),
        }
    )
    path = pathlib.Path(tempfile.mkdtemp(prefix="moonlake-scan-bench")) / "big.parquet"
    pq.write_table(
        table,
        path,
        row_group_size=group,
        compression="none",
        use_dictionary=False,
        data_page_version="1.0",
        write_statistics=True,
    )
    print(f"generated {path}: {rows} rows in {groups} row groups of {group}", file=sys.stderr)
    return path


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base", help="binary of the comparison build")
    ap.add_argument("--new", default=str(DEFAULT if DEFAULT.exists() else FLAT), help="binary under test")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--big", action="store_true", help="include a generated 1Mi-row parquet")
    ap.add_argument("--big-rows", type=int, default=1 << 20)
    ap.add_argument("--big-groups", type=int, default=8)
    args = ap.parse_args()

    new = pathlib.Path(args.new)
    if not new.exists():
        raise SystemExit(f"no binary at {new}: run `moon build cmd/main --target native`")
    base = pathlib.Path(args.base) if args.base else None
    if base is not None and not base.exists():
        raise SystemExit(f"no binary at {base}")

    big = make_big(args.big_rows, args.big_groups) if args.big else None
    for title, argv in cases(big):
        print(f"== {title}")
        if base is not None:
            ms, rss = bench(base, argv, args.runs)
            print(f"   {'base':<8} {ms:9.1f} ms  {rss:8d} KB")
        ms, rss = bench(new, argv, args.runs)
        print(f"   {'new':<8} {ms:9.1f} ms  {rss:8d} KB")


if __name__ == "__main__":
    main()
