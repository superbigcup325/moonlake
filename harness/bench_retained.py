#!/usr/bin/env python3
# Is a budgeted GROUP BY's retained input bounded on this target?
#
# Peak RSS alone does not answer that: every target has a baseline (about 175 MB
# for the wasm-gc runtime, about 315 MB for node at these sizes, under 60 MB for
# a native process) and a scan whose own high-water mark grows with the rows
# read. What separates them is a comparison inside one target, at one row count,
# between three runs of the same binary:
#
#   scan      select count(*)              nothing retained but the scan itself
#   spill     the grouped query under a budget smaller than the input
#   retain    the same query under a budget larger than the input, so the
#             engine keeps every row exactly as it did before this change
#
# `retain` minus `scan` is the collected input made visible; `spill` minus
# `scan` is what the partition buffer adds. The engine's own
# "buffered bytes peak (estimated)" is printed beside them, because on a target
# whose scan costs more than the input the last two can be equal and only the
# counter still shows the bound.
#
# Usage:
#   python3 harness/bench_retained.py --candidate <wrapper or main.exe>
#       [--rows 1000000,2000000,4000000,8000000] [--budgets 4M,512M]
#       [--repeats 3] [--work DIR] [--quiet-load 0.9] [--json-out FILE]
#
# --candidate is anything executable that takes the CLI's arguments, which is how
# the wasm-gc build runs under `moonrun` and the js build under `node`.
#
# --input parquet reads the same rows through the columnar reader instead of the
# CSV reader. That is not a formality: the CSV reader is what grows the footprint
# on the wasm-gc and js targets (verification section 45), so with CSV input the
# scan's own peak can sit above what the input would retain and hide the
# difference. Parquet decodes fixed-size column batches and stays flat, which is
# where the three-way comparison separates on every target.
#
# Exit status: 0 all runs answered, 1 a query failed, 2 a missing prerequisite.

import argparse
import json
import os
import pathlib
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_agg_pull import (  # noqa: E402
    SHAPES,
    make_csv,
    run_once,
    start_helper,
    stop_helper,
    wait_quiet,
)

GROUPED = (
    "select k, count(*) as n, sum(v) as s, min(v) as lo, max(v) as hi "
    "from t group by k"
)
SCAN = "select count(*) as n from t"

COUNTERS = ("scan t", "spill partitions", "buffered bytes peak (estimated)",
            "largest partition spilled (estimated)", "aggregate", "spill files")


def counters(text: str) -> dict:
    out = {}
    for line in text.splitlines():
        if ":" in line and not line.startswith("--"):
            k, v = line.split(":", 1)
            if k.strip() in COUNTERS:
                out[k.strip()] = v.strip()
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--rows", default="1000000,2000000,4000000,8000000")
    ap.add_argument("--budgets", default="4M,512M")
    ap.add_argument("--input", choices=["csv", "parquet"], default="csv")
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--work")
    ap.add_argument("--quiet-load", type=float, default=0.9)
    ap.add_argument("--quiet-samples", type=int, default=3)
    ap.add_argument("--quiet-interval", type=float, default=10.0)
    ap.add_argument("--quiet-timeout", type=float, default=3600.0)
    ap.add_argument("--json-out")
    args = ap.parse_args()

    work = pathlib.Path(args.work or tempfile.mkdtemp(prefix="retained-"))
    spill = work / "spill"
    spill.mkdir(parents=True, exist_ok=True)
    rows = [int(x) for x in args.rows.split(",")]
    small, large = args.budgets.split(",")
    keyfn = SHAPES["groups-100"][1]

    print(f"data under {work}", flush=True)
    quiet = wait_quiet(args.quiet_load, args.quiet_samples, args.quiet_interval,
                       args.quiet_timeout)
    print(f"host quiet: load {quiet:.2f}; starting", flush=True)

    start_helper()
    report = []
    failed = False
    try:
        for n in rows:
            csv = work / f"groups-100-{n}" / "t.csv"
            make_csv(csv, n, keyfn)
            if args.input == "parquet":
                import duckdb  # imported late: only --input parquet needs it

                out = csv.with_suffix(".parquet")
                if not out.exists():
                    duckdb.sql(f"COPY (SELECT k, v, s FROM read_csv_auto('{csv}')) "
                               f"TO '{out}' (FORMAT parquet)")
                csv = out
            line = {"rows": n, "scan": None, "spill": None, "retain": None}
            for tag, budget, sql in (("scan", None, SCAN),
                                     ("spill", small, GROUPED),
                                     ("retain", large, GROUPED)):
                rss = 0.0
                cnt = {}
                for _ in range(args.repeats):
                    wall, peak, code, out, err = run_once(
                        args.candidate, csv, budget or large, sql, spill,
                        analyze=True, kind=args.input)
                    if code != 0:
                        print(f"FAIL {n} rows {tag}: {err.strip()[:200]}", flush=True)
                        failed = True
                        break
                    rss = max(rss, peak)
                    cnt = counters(out)
                line[tag] = {"rss": round(rss, 1), "counters": cnt}
                shown = " ".join(f"{k}={v}" for k, v in cnt.items())
                print(f"{n:>9} {tag:>6} {rss:6.1f} MB | {shown}", flush=True)
            report.append(line)
            scan_rss = line["scan"]["rss"]
            for tag in ("spill", "retain"):
                if line[tag]:
                    print(f"{n:>9} {tag} minus scan: "
                          f"{line[tag]['rss'] - scan_rss:+.1f} MB", flush=True)
    finally:
        stop_helper()

    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump(report, f, indent=1)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
