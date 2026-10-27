#!/usr/bin/env python3
# Does a join that feeds an aggregate retain its intermediate rows?
#
# Roadmap E6a. A two-table hash join already probes a batch at a time and a
# single-table aggregate already folds its scan, so the open question is what
# happens when the second sits above the first: `streaming_join_source` declines
# an aggregate over the join and `streaming_agg_source` accepts one table, so the
# composition is not built and the intermediate rows have to go somewhere.
#
# Peak RSS alone cannot say where that cost comes from, so every point of the
# matrix is measured against three controls that share the same fixtures:
#
#   scan-only      select count(*) from probe    the scan's own footprint
#   agg-only       GROUP BY over probe           the aggregate state, no join
#   join-only      the joined rows, collected    the intermediate rows
#   join-agg       GROUP BY over the join        the target shape
#
# Probe rows and fanout are swept while the build side, the group count and the
# final result stay fixed, because both sweeps multiply intermediate rows:
# growing the probe at fanout 1 and growing the fanout at a fixed probe both
# make `rows x fanout` bigger while `groups` stays where it is. A retained
# intermediate result therefore shows up as RSS that follows the product rather
# than the probe input, and scan-only is what to subtract before calling the
# rest retained.
#
# The answers are checked against an exact independent count recomputed here
# from the fixtures' key and value functions, not against another engine's
# formatting; `--duckdb` adds the three-way check when the reference
# environment is available.
#
# Usage:
#   python3 harness/bench_join_agg.py --candidate <main.exe> [--control <main.exe>]
#       [--work DIR] [--rows 1000000] [--rows-scale 500000,1000000,2000000]
#       [--fanout 1,2,4] [--groups 100] [--budgets 0,4M] [--rounds 3]
#       [--cases scan-only,agg-only,join-only,join-agg,join-left-agg]
#       [--duckdb] [--json-out FILE] [--quiet-load 0.9]
#
# `--rows-scale` runs every case at each probe row count with fanout 1;
# `--fanout` runs every case at `--rows` with each fanout. A budget of `0` (or
# `none`) runs the query without `--memory` at all.
#
# Wall time is only as good as the machine: the script waits until the host is
# quiet, interleaves candidate and control round by round, and prints the worst
# round-to-round spread. Read that line first and rerun rather than keeping a
# number from a busy host.
#
# Exit status: 0 every answer and lifecycle check passed, 1 a mismatch, a failed
# query or a leftover spill directory, 2 a missing prerequisite.

import argparse
import hashlib
import json
import os
import pathlib
import statistics
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_agg_pull import (  # noqa: E402
    compare_with_duckdb,
    die,
    digest,
    load1,
    run_inputs,
    start_helper,
    stop_helper,
    wait_quiet,
)

REPO = pathlib.Path(__file__).resolve().parent.parent

CASES = {
    "scan-only": "select count(*) as n from probe",
    "agg-only": "select k, count(*) as n, sum(v) as total from probe group by k",
    "join-only": "select b.k as k, p.v as v from probe p join build b on p.k = b.k",
    "join-agg": (
        "select b.k as k, count(*) as n, sum(p.v) as total "
        "from probe p join build b on p.k = b.k group by b.k"
    ),
    "join-left-agg": (
        "select b.k as k, count(*) as n, sum(p.v) as total "
        "from probe p left join build b on p.k = b.k group by b.k"
    ),
}

COUNTERS = (
    "scan probe",
    "scan build",
    "joins",
    "aggregate",
    "result",
    "spill partitions",
    "spill files",
    "spill bytes written",
    "buffered bytes peak (estimated)",
    "largest partition spilled (estimated)",
)

# the fixture's value function, stated once: probe row i has k = i % groups and
# v = (13 * i) % 1000. The reference below and make_fixtures both use it.
def probe_key(i: int, groups: int) -> int:
    return i % groups


def probe_value(i: int) -> int:
    return (i * 13) % 1000


def make_fixtures(work: pathlib.Path, rows: int, groups: int, fanout: int):
    """The probe table (id, k, v) and the build table (k, w), generated once.

    The build table carries `fanout` rows per key, so an inner keyed join emits
    `fanout` output rows per probe row while the grouped answer keeps `groups`
    rows."""
    probe_dir = work / f"probe-{rows}-{groups}"
    build_dir = work / f"build-{groups}-{fanout}"
    probe = probe_dir / "probe.csv"
    build = build_dir / "build.csv"
    if not probe.exists():
        probe_dir.mkdir(parents=True, exist_ok=True)
        tmp = probe.with_suffix(".part")
        with open(tmp, "w") as f:
            f.write("id,k,v\n")
            for i in range(rows):
                f.write(f"{i},{probe_key(i, groups)},{probe_value(i)}\n")
        tmp.rename(probe)
    if not build.exists():
        build_dir.mkdir(parents=True, exist_ok=True)
        tmp = build.with_suffix(".part")
        with open(tmp, "w") as f:
            f.write("k,w\n")
            for k in range(groups):
                for w in range(fanout):
                    f.write(f"{k},{w}\n")
        tmp.rename(build)
    return probe, build


_ref_cache = {}


def reference(rows: int, groups: int):
    """Per key: how many probe rows have it and what their `v` values sum to."""
    key = (rows, groups)
    if key not in _ref_cache:
        counts = [0] * groups
        sums = [0] * groups
        for i in range(rows):
            g = probe_key(i, groups)
            counts[g] += 1
            sums[g] += probe_value(i)
        _ref_cache[key] = (counts, sums)
    return _ref_cache[key]


def parse_answer(text: str):
    lines = text.rstrip("\n").split("\n")
    if not lines or lines[0] == "":
        return None
    head = lines[0].split("|")
    body = [line.split("|") for line in lines[1:] if line != ""]
    return head, body


def body_row_count(text: str) -> int:
    """Rows under the header, counted without building them: the collected join
    control can be tens of millions of lines and only its count is checked."""
    return max(0, text.count("\n") - 1)


def check_answer(case: str, text: str, rows: int, groups: int, fanout: int) -> str:
    """'' when the answer is the exact one this fixture forces, else a reason."""
    parsed = parse_answer(text)
    if parsed is None:
        return "empty output"
    head, body = parsed
    counts, sums = reference(rows, groups)
    if case == "scan-only":
        if head != ["n"] or len(body) != 1:
            return f"scan answer shape {head} {len(body)} rows"
        if body[0][0] != str(rows):
            return f"scan counted {body[0][0]}, expected {rows}"
        return ""
    if case == "join-only":
        want = rows * fanout
        if head != ["k", "v"] or body_row_count(text) != want:
            return f"join emitted {body_row_count(text)} rows, expected {want}"
        return ""
    want = {}
    for g in range(min(groups, rows)):
        n = counts[g] * (fanout if case != "agg-only" else 1)
        total = sums[g] * (fanout if case != "agg-only" else 1)
        want[str(g)] = (str(n), str(total))
    if head != ["k", "n", "total"]:
        return f"grouped answer header {head}"
    got = {row[0]: (row[1], row[2]) for row in body}
    if len(got) != len(body):
        return "duplicate group keys in the answer"
    if got != want:
        missing = sorted(set(want) - set(got))
        extra = sorted(set(got) - set(want))
        wrong = [k for k in want if k in got and got[k] != want[k]]
        return (f"grouped answer differs: {len(missing)} missing, {len(extra)} extra, "
                f"{len(wrong)} wrong" + (f" (first key {wrong[0]}: {got[wrong[0]]} vs {want[wrong[0]]})" if wrong else ""))
    return ""


def duckdb_rows(probe: pathlib.Path, build: pathlib.Path, sql: str) -> str:
    import duckdb

    con = duckdb.connect()
    con.execute(f"create table probe as select * from read_csv('{probe}', header=true)")
    con.execute(f"create table build as select * from read_csv('{build}', header=true)")
    cur = con.execute(sql)
    head = "|".join(d[0] for d in cur.description)
    lines = [head]
    for row in cur.fetchall():
        cells = []
        for c in row:
            cells.append("null" if c is None else repr(c) if isinstance(c, float) else str(c))
        lines.append("|".join(cells))
    return "\n".join(lines) + "\n"


def counters(text: str) -> dict:
    found = {}
    for line in text.splitlines():
        if ":" not in line or line.startswith("--"):
            continue
        key, value = line.split(":", 1)
        key, value = key.strip(), value.strip()
        if key in COUNTERS and value.isdigit():
            found[key] = int(value)
    return found


def rows_line(report: dict) -> str:
    out = f"{report['case']:14s} rows {report['rows']:>8} fanout {report['fanout']}"
    out += f" budget {report['budget'] or 'none':>4s}"
    for name, r in report["runs"].items():
        out += (f" | {name} {r['wall_median']:.2f}s (+-{r['wall_spread'] * 100:.0f}%)"
                f" {r['rss_mb']:.0f}MB")
    c = report["counters"]
    out += f" | joins {c.get('joins', 0)} groups {c.get('aggregate', 0)}"
    out += f" parts {c.get('spill partitions', 0)} files {c.get('spill files', 0)}"
    verdicts = report["answers"]
    out += " | " + (", ".join(verdicts) if verdicts else "no answer check")
    return out


def sha256_of(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tool(*args: str) -> str:
    """A provenance line from an external command, empty when it is absent:
    the record has to say what produced it, and a reader may not have these."""
    try:
        done = subprocess.run(args, capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return ""
    return done.stdout.strip()


def provenance(bins: dict, args, quiet_load: float) -> dict:
    return {
        "schema": 1,
        "kind": "moonlake-join-agg-baseline",
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "git": {
            "commit": tool("git", "rev-parse", "HEAD"),
            "branch": tool("git", "rev-parse", "--abbrev-ref", "HEAD"),
            "subject": tool("git", "log", "-1", "--format=%s"),
            "dirty": bool(tool("git", "status", "--porcelain")),
        },
        "machine": {
            "cpu_count": os.cpu_count(),
            "quiet_gate": args.quiet_load,
            "quiet_load": round(quiet_load, 2),
        },
        "python": sys.version.split()[0],
        "toolchain": tool("moon", "version", "--all").splitlines(),
        "binaries": {name: {"path": str(path), "sha256": sha256_of(pathlib.Path(path))}
                     for name, path in bins.items()},
        "fixture": {"probe": "id,k,v with k = i % groups and v = (13 * i) % 1000",
                    "build": "k,w with fanout rows per key"},
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--control")
    ap.add_argument("--work")
    ap.add_argument("--rows", type=int, default=1_000_000)
    ap.add_argument("--rows-scale", default="500000,1000000,2000000")
    ap.add_argument("--fanout", default="1,2,4")
    ap.add_argument("--groups", type=int, default=100)
    ap.add_argument("--budgets", default="0,4M")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--cases", default=",".join(CASES))
    ap.add_argument("--duckdb", action="store_true")
    ap.add_argument("--json-out")
    ap.add_argument("--quiet-load", type=float, default=0.9)
    ap.add_argument("--quiet-samples", type=int, default=3)
    ap.add_argument("--quiet-interval", type=float, default=10.0)
    ap.add_argument("--quiet-timeout", type=float, default=3600.0)
    args = ap.parse_args()

    for b in (args.candidate, args.control):
        if b and not os.access(b, os.X_OK):
            die(f"not an executable: {b}")
    known = ", ".join(CASES)
    cases = [c for c in args.cases.split(",") if c]
    for c in cases:
        if c not in CASES:
            die(f"unknown case {c}; known: {known}")
    budgets = ["" if b in ("0", "none") else b for b in args.budgets.split(",")]
    if args.groups < 1:
        die("--groups must be positive")
    if args.duckdb:
        try:
            import duckdb  # noqa: F401
        except ImportError:
            die("--duckdb needs the duckdb package (see harness/requirements.txt)")

    points = []
    if args.rows_scale:
        for n in (int(x) for x in args.rows_scale.split(",")):
            points.append((n, 1))
    for f in (int(x) for x in args.fanout.split(",") if x):
        points.append((args.rows, f))
    points = list(dict.fromkeys(points))

    work = pathlib.Path(args.work or tempfile.mkdtemp(prefix="join-agg-"))
    work.mkdir(parents=True, exist_ok=True)
    spill = work / "spill"
    spill.mkdir(exist_ok=True)

    quiet_load = wait_quiet(args.quiet_load, args.quiet_samples, args.quiet_interval,
                            args.quiet_timeout)
    print(f"host quiet: load {quiet_load:.2f}; starting", flush=True)

    start_helper()
    bins = {"candidate": args.candidate}
    if args.control:
        bins["control"] = args.control
    failed = False
    report_rows = []
    worst_spread = 0.0
    worst_load = 0.0
    try:
        for rows, fanout in points:
            probe, build = make_fixtures(work, rows, args.groups, fanout)
            print(f"data: {rows} probe rows x fanout {fanout}, {args.groups} groups,"
                  f" tables {probe.name}/{build.name} under {work}", flush=True)
            # the fixture is what the reference is computed from; do it before
            # any process starts so it cannot lift a measurement
            reference(rows, args.groups)
            for budget in budgets:
                for case in cases:
                    sql = CASES[case]
                    want_duck = None
                    if args.duckdb and case in ("agg-only", "join-agg", "join-left-agg"):
                        want_duck = duckdb_rows(probe, build, sql)
                    samples = {name: [] for name in bins}
                    answers = {}
                    load_before = load1()
                    for rnd in range(args.rounds):
                        order = list(bins) if rnd % 2 == 0 else list(bins)[::-1]
                        for name in order:
                            run_dir = spill / f"{case}-{rows}-{fanout}-{budget or 'none'}-{name}-{rnd}"
                            wall, rss, code, out, err = run_inputs(
                                bins[name], [("csv", probe), ("csv", build)],
                                budget, sql, run_dir)
                            if code != 0:
                                print(f"FAIL {case} rows {rows} fanout {fanout} "
                                      f"budget {budget or 'none'} {name}: exit {code}: {err[:300]}")
                                failed = True
                                continue
                            if run_dir.exists():
                                print(f"FAIL {case} rows {rows} fanout {fanout} "
                                      f"budget {budget or 'none'} {name}: spill directory left behind")
                                failed = True
                            samples[name].append((wall, rss))
                            answers[name] = out
                    load_after = load1()
                    worst_load = max(worst_load, load_before, load_after)
                    _w, _r, code, analyzed, err = run_inputs(
                        bins["candidate"], [("csv", probe), ("csv", build)],
                        budget, CASES[case], spill / "analyze", analyze=True)
                    if code != 0:
                        print(f"FAIL {case} rows {rows} fanout {fanout} "
                              f"budget {budget or 'none'} analyze: exit {code}: {err[:300]}")
                        failed = True
                    stat = counters(analyzed)
                    verdicts = []
                    for name, out in answers.items():
                        reason = check_answer(case, out, rows, args.groups, fanout)
                        if reason:
                            verdicts.append(f"{name} WRONG ({reason})")
                            failed = True
                        else:
                            verdicts.append(f"{name} answer ok")
                    if "control" in answers and "candidate" in answers:
                        if case == "join-only":
                            same = (body_row_count(answers["candidate"])
                                    == body_row_count(answers["control"]))
                        else:
                            same = digest(answers["candidate"]) == digest(answers["control"])
                        verdicts.append("control " + ("same" if same else "DIFFERENT"))
                        failed |= not same
                    if want_duck is not None and "candidate" in answers:
                        ok = compare_with_duckdb(work, answers["candidate"], want_duck)
                        verdicts.append("duckdb " + ("same" if ok else "DIFFERENT"))
                        failed |= not ok
                    row = {"case": case, "rows": rows, "fanout": fanout,
                           "groups": args.groups, "budget": budget,
                           "intermediate_rows": rows * fanout,
                           "counters": stat, "answers": verdicts, "runs": {}}
                    for name, got in samples.items():
                        if not got:
                            continue
                        walls = [w for w, _ in got]
                        med = statistics.median(walls)
                        spread = (max(walls) - min(walls)) / med if med else 0.0
                        worst_spread = max(worst_spread, spread)
                        row["runs"][name] = {
                            "wall_median": round(med, 3),
                            "wall_spread": round(spread, 3),
                            "rss_mb": round(max(r for _, r in got), 1),
                        }
                    report_rows.append(row)
                    print(rows_line(row), flush=True)
            # a query that exits early still may leave nothing behind; the checked
            # runs above cover that, so this directory only needs to be empty
            leftover = sorted(p.name for p in spill.iterdir())
            if leftover:
                print(f"FAIL spill directories were left behind under {spill}: {leftover[:5]}")
                failed = True
    finally:
        stop_helper()

    print(f"worst round-to-round wall spread {worst_spread * 100:.0f}%, "
          f"highest load seen {worst_load:.2f}")
    if worst_spread > 0.10:
        print("WARNING: a case moved more than 10% between rounds; rerun before trusting its wall times")
    # the separation this script exists to show: at each fixed point, what the
    # scan alone costs and what the collected intermediate rows add to it
    print("\nseparation (peak RSS in MB, candidate only):")
    for rows, fanout in points:
        for budget in budgets:
            at = {(r["case"], r["budget"]): r for r in report_rows
                  if r["rows"] == rows and r["fanout"] == fanout}
            if not at:
                continue
            cells = []
            for case in ("scan-only", "agg-only", "join-only", "join-agg", "join-left-agg"):
                r = at.get((case, budget))
                cell = r["runs"].get("candidate", {}).get("rss_mb") if r else None
                cells.append(f"{case} {cell:.0f}" if cell is not None else f"{case} -")
            print(f"  rows {rows:>8} fanout {fanout} budget {budget or 'none':>4s}: "
                  + ", ".join(cells))
    if args.json_out:
        record = provenance(bins, args, quiet_load)
        record.update({
            "params": {"groups": args.groups, "rounds": args.rounds,
                       "budgets": budgets, "cases": cases, "duckdb": bool(args.duckdb)},
            "points": points,
            "worst_spread": worst_spread,
            "worst_load": worst_load,
            "cases": report_rows,
        })
        pathlib.Path(args.json_out).write_text(json.dumps(record, indent=1))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
