# Resource evidence for a chain of joins under an aggregate.
#
# One join step over two lazy tables is folded from the join's own batches (§49):
# the build side stays resident because it has to, the probe side arrives a batch
# at a time, and the joined rows never exist as an array. This script measures the
# next widening, a chain of steps, where each step's cursor feeds the next one and
# the fold receives the last step's output. The cost moves entirely into the build
# sides: one resident side (and the index built over it) per step.
#
# That trade is not free, and this script is how it was decided rather than
# assumed. A chain of joins over TPC-H holds the joining tables whole, and when
# one of them is a large table the resident index can cost more than collecting
# the joined rows the eager path would have held: at SF1 that was q3, which is
# why verification §51 gated composition on a budget the sides fit. §52 made the
# index over a build side cheaper and measured the trade again, so both runs
# below compose; the no-budget rows are the ones that show what a resident chain
# costs. That index is the hash join's own, so a case that never composes still
# moves (q9, q20 under a budget).
#
# The queries are the TPC-H texts the golden corpus already runs, read from a
# `--data` directory of CSVs, so the evidence is over the shapes the gate covers:
#
#   q3 q5 q7 q8 q9 q10 q11 q18 q20 q21   chains of two or more steps
#   q1 q12                               single-step compositions (invariants)
#
# q1 and q12 are in the matrix as invariants: they compose one step, they
# composed before this change, and their peaks must not move.
#
# Each case runs the candidate and the control alternately, round by round, and
# reports the median peak RSS and wall time. Wall time is only as good as the
# machine, so the script waits until the host is quiet, records the load before
# and after, and prints the worst round-to-round spread: read that line first and
# rerun rather than keeping a number from a busy host. The same query's output is
# compared byte for byte between the two binaries.
#
# Usage:
#   python3 harness/bench_join_chain.py --candidate <main.exe> [--control <main.exe>]
#       [--data harness/data/sf1] [--budgets none,16M] [--rounds 3]
#       [--cases q3,q11] [--json-out FILE] [--quiet-load 1.5]
#
# A budget of `none` (or the empty string) runs the query without --memory.
#
# Exit status: 0 every answer agreed, 1 a mismatch or a failed query, 2 a missing
# prerequisite.

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

REPO = pathlib.Path(__file__).resolve().parent.parent
QUERIES = REPO / "harness/queries"

# name -> the CSV tables the query selects from, in the order the CLI takes them
CASES = {
    # chains: an aggregate over two or more join steps
    "q3": ["customer", "orders", "lineitem"],
    "q5": ["customer", "orders", "lineitem", "supplier", "nation", "region"],
    "q7": ["supplier", "lineitem", "orders", "customer", "nation"],
    "q8": ["part", "supplier", "lineitem", "orders", "customer", "nation",
           "region"],
    "q9": ["part", "supplier", "lineitem", "partsupp", "orders", "nation"],
    "q10": ["customer", "orders", "lineitem", "nation"],
    "q11": ["partsupp", "supplier", "nation"],
    "q18": ["customer", "orders", "lineitem"],
    "q20": ["supplier", "nation", "partsupp", "part", "lineitem"],
    "q21": ["supplier", "lineitem", "orders", "nation"],
    # invariants: one step, composed before this change
    "q1": ["lineitem"],
    "q12": ["orders", "lineitem"],
}


def die(msg: str, code: int = 2) -> None:
    print(msg, file=sys.stderr)
    sys.exit(code)


def sha256_of(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tool(*args: str) -> str:
    try:
        return subprocess.run(list(args), capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def load1() -> float:
    return float(pathlib.Path("/proc/loadavg").read_text().split()[0])


def wait_quiet(max_load: float, samples: int, interval: float, timeout: float) -> float:
    """Block until `samples` consecutive load readings are under `max_load`."""
    start = time.monotonic()
    good = 0
    last = load1()
    while True:
        last = load1()
        good = good + 1 if last < max_load else 0
        if good >= samples:
            return last
        if time.monotonic() - start > timeout:
            die(f"host never went quiet: load {last:.2f} >= {max_load} after {timeout:.0f}s")
        print(f"waiting for a quiet host: load {last:.2f}", flush=True)
        time.sleep(interval)


# The measured binary is started from a small helper process. Linux folds a
# parent's peak RSS into a child's ru_maxrss when the child shares or copies its
# memory (Python's subprocess starts children with vfork), so measuring from a
# parent that holds anything heavy would put its high-water mark under every
# sample. The helper is started before anything else, stays a few MB, and forks a
# plain child per query (the same arrangement bench_agg_pull.py documents).
HELPER = r"""
import json, os, sys, time
for line in sys.stdin:
    req = json.loads(line)
    with open(req["out"], "wb") as out, open(req["err"], "wb") as err:
        t0 = time.perf_counter()
        pid = os.fork()
        if pid == 0:
            try:
                os.dup2(out.fileno(), 1)
                os.dup2(err.fileno(), 2)
                os.execv(req["cmd"][0], req["cmd"])
            finally:
                os._exit(127)
        _, status, usage = os.wait4(pid, 0)
        wall = time.perf_counter() - t0
    print(json.dumps({"wall": wall, "rss": usage.ru_maxrss / 1024.0,
                      "code": os.waitstatus_to_exitcode(status)}), flush=True)
"""

_helper = None
_io_dir = None


def start_helper() -> None:
    global _helper, _io_dir
    _io_dir = pathlib.Path(tempfile.mkdtemp(prefix="join-chain-io-"))
    _helper = subprocess.Popen([sys.executable, "-c", HELPER], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, text=True)


def stop_helper() -> None:
    global _helper
    if _helper is not None:
        _helper.stdin.close()
        _helper.wait()
        _helper = None


def run_one(binary: str, data: pathlib.Path, tables: list, budget: str, sql: str,
            spill: pathlib.Path):
    """One query in its own process: wall seconds, peak RSS in MB, exit code,
    stdout text. An empty `budget` runs without --memory at all."""
    cmd = [binary, "exec"]
    for table in tables:
        cmd += ["--csv", str(data / f"{table}.csv")]
    if budget:
        cmd += ["--memory", budget, "--spill-dir", str(spill)]
    cmd.append(sql)
    out_p = _io_dir / "out.txt"
    err_p = _io_dir / "err.txt"
    _helper.stdin.write(json.dumps({"cmd": cmd, "out": str(out_p), "err": str(err_p)}) + "\n")
    _helper.stdin.flush()
    reply = json.loads(_helper.stdout.readline())
    err = err_p.read_text(errors="replace")
    if reply["code"] != 0:
        die(f"{cmd[0]} failed on {sql[:40]}...: {err[-400:]}", 1)
    return reply["wall"], reply["rss"], out_p.read_text(errors="replace")


def spread(values: list) -> float:
    lo, hi = min(values), max(values)
    med = statistics.median(values)
    return (hi - lo) / med if med else 0.0


def provenance(bins: dict, args, quiet_load: float) -> dict:
    return {
        "schema": 1,
        "kind": "moonlake-join-chain-baseline",
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
        "fixtures": f"TPC-H CSVs in {args.data}",
        "params": {"rounds": args.rounds, "budgets": args.budgets.split(","),
                   "cases": sorted(args.cases)},
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--control")
    ap.add_argument("--data", default="harness/data/sf1")
    ap.add_argument("--budgets", default="none,16M")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--cases", default=",".join(CASES))
    ap.add_argument("--work")
    ap.add_argument("--json-out")
    ap.add_argument("--quiet-load", type=float, default=1.5)
    ap.add_argument("--quiet-samples", type=int, default=3)
    ap.add_argument("--quiet-interval", type=float, default=10.0)
    ap.add_argument("--quiet-timeout", type=float, default=3600.0)
    args = ap.parse_args()

    bins = {"candidate": args.candidate}
    if args.control:
        bins["control"] = args.control
    for b in bins.values():
        if not os.access(b, os.X_OK):
            die(f"not an executable: {b}")
    args.cases = [c for c in args.cases.split(",") if c]
    for case in args.cases:
        if case not in CASES:
            die(f"unknown case {case}; known: {', '.join(CASES)}")
    data = pathlib.Path(args.data)
    for case in args.cases:
        for table in CASES[case]:
            if not (data / f"{table}.csv").exists():
                die(f"missing fixture {data / f'{table}.csv'}")

    work = pathlib.Path(args.work or tempfile.mkdtemp(prefix="join-chain-"))
    work.mkdir(parents=True, exist_ok=True)
    spill = work / "spill"
    spill.mkdir(exist_ok=True)

    quiet_load = wait_quiet(args.quiet_load, args.quiet_samples, args.quiet_interval,
                            args.quiet_timeout)
    start_helper()
    print(f"quiet load {quiet_load:.2f}; data {data}; rounds {args.rounds}")
    cases_out = {}
    mismatches = 0
    worst = 0.0
    try:
        for budget in [b for b in args.budgets.split(",") if b and b != "none"] + [""]:
            for case in args.cases:
                sql = (QUERIES / f"{case}.sql").read_text()
                samples = {name: [] for name in bins}
                answers = {}
                for _ in range(args.rounds):
                    for name, binary in bins.items():
                        wall, rss, answer = run_one(binary, data, CASES[case], budget, sql, spill)
                        samples[name].append((rss, wall))
                        answers[name] = answer
                row = {}
                for name, values in samples.items():
                    row[f"{name}_mb"] = round(statistics.median(v[0] for v in values), 1)
                    row[f"{name}_s"] = round(statistics.median(v[1] for v in values), 2)
                    worst = max(worst, spread([v[0] for v in values]))
                same = len(set(answers.values())) == 1
                row["same_answer"] = same
                if not same:
                    mismatches += 1
                cases_out[f"{case}/{budget or 'no budget'}"] = row
                if "control_mb" in row:
                    print(f"{case:>5} {budget or 'no budget':>9}  "
                          f"rss {row['control_mb']:7.1f} -> {row['candidate_mb']:7.1f} MB  "
                          f"wall {row['control_s']:5.2f} -> {row['candidate_s']:5.2f} s  "
                          f"same {same}", flush=True)
                else:
                    print(f"{case:>5} {budget or 'no budget':>9}  "
                          f"rss {row['candidate_mb']:7.1f} MB  "
                          f"wall {row['candidate_s']:5.2f} s", flush=True)
    finally:
        stop_helper()

    print(f"worst peak-RSS spread across rounds: {worst * 100:.0f}%")
    if args.json_out:
        record = provenance(bins, args, quiet_load)
        record["answer_mismatches"] = mismatches
        record["worst_spread"] = round(worst, 3)
        record["cases"] = cases_out
        pathlib.Path(args.json_out).write_text(json.dumps(record, indent=1) + "\n")
        print(f"wrote {args.json_out}")
    if mismatches:
        die(f"{mismatches} case(s) disagreed between candidate and control", 1)


main()
