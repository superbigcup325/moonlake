# Resource and correctness evidence for a budgeted GROUP BY fed from the scan.
#
# A GROUP BY under --memory used to collect its whole input before the grace
# partitioning could size itself; it now buffers up to the budget and spills
# only past it. This script measures what that is worth and checks that the
# answers did not move:
#
#   * peak RSS, wall time and spill counters for several group counts, one large
#     per-group state (median, count(DISTINCT)), a string_agg state and a skewed
#     key, at several budgets, with the candidate and an optional control binary
#     interleaved round by round so drift hits both;
#   * the candidate's answer against the control's and, with --duckdb, against
#     DuckDB's (string_agg has no defined order in DuckDB, so that shape is
#     compared with the control only);
#   * that a spilled run leaves no --spill-dir behind.
#
# Wall time is only as good as the machine, so the script waits until the host
# is quiet (1-minute load average under --quiet-load for --quiet-samples
# consecutive samples) before it starts, records the load before and after each
# case, and prints the worst round-to-round spread beside the table. Read that
# line first and rerun rather than keeping a number from a busy host.
#
# Usage:
#   python3 harness/bench_agg_pull.py --candidate <main.exe> [--control <main.exe>]
#       [--duckdb] [--work DIR] [--rows 4000000] [--budgets 4M,16M,32M]
#       [--rounds 4] [--shapes a,b] [--json-out FILE]
#       [--scale-rows N,N,...] [--scale-shape groups-100]
#
# --scale-rows adds one case per row count for a single shape, so the group count
# and the state per group stay fixed while the input grows; that is the
# measurement that shows whether retained input still follows the row count.
# Pass --shapes "" to run only those.
#
# Exit status: 0 all answers agree and nothing was left behind, 1 a mismatch, a
# failed query or a leftover directory, 2 a missing prerequisite.

import argparse
import hashlib
import json
import os
import pathlib
import re
import statistics
import subprocess
import sys
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parent.parent

PLAIN = (
    "select k, count(*) as n, sum(v) as total, min(v) as lo, max(v) as hi "
    "from t group by k"
)

# name -> (group count, key function of the row index, SQL, comparable with DuckDB)
SHAPES = {
    "groups-100": (100, lambda i: i % 100, PLAIN, True),
    "groups-1000": (1000, lambda i: i % 1000, PLAIN, True),
    "groups-100000": (100000, lambda i: i % 100000, PLAIN, True),
    "groups-1000000": (1000000, lambda i: i % 1000000, PLAIN, True),
    "big-state": (
        100,
        lambda i: i % 100,
        "select k, median(v) as m, count(distinct v) as d from t group by k",
        True,
    ),
    "string-state": (
        100,
        lambda i: i % 100,
        "select k, string_agg(s, '|') as joined from t group by k",
        False,
    ),
    "skew": (
        1001,
        # nine rows in ten share key 0; the rest spread over 1..1000
        lambda i: 0 if i % 10 else (i // 10) % 1000 + 1,
        "select k, count(*) as n, median(v) as m from t group by k",
        True,
    ),
}


def die(msg: str, code: int = 2) -> None:
    print(msg, file=sys.stderr)
    sys.exit(code)


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


def make_csv(path: pathlib.Path, rows: int, keyfn) -> None:
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".part")
    with open(tmp, "w") as f:
        f.write("k,v,s\n")
        for i in range(rows):
            f.write(f"{keyfn(i)},{(i * 13) % 1000},s{i % 7}\n")
    tmp.rename(path)


# The measured binary has to be started from a small process. Linux folds the
# parent's peak RSS into a child's ru_maxrss when the child shares or copies its
# memory (Python's subprocess starts children with vfork), so a parent that
# holds a DuckDB table or a sorted answer would put its own high-water mark
# under every measurement: the first version of this script printed the same
# growing RSS for both binaries for exactly that reason. This helper is started
# before anything heavy, stays a few MB, and runs each query with a plain fork.
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
    _io_dir = pathlib.Path(tempfile.mkdtemp(prefix="agg-pull-io-"))
    _helper = subprocess.Popen([sys.executable, "-c", HELPER], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, text=True)


def run_once(binary: str, csv: pathlib.Path, budget: str, sql: str, spill: pathlib.Path,
             analyze: bool = False):
    """One query in its own process: wall seconds, peak RSS in MB, exit code,
    stdout text, stderr text."""
    cmd = [binary, "exec", "--csv", str(csv), "--memory", budget,
           "--spill-dir", str(spill)]
    if analyze:
        cmd.append("--analyze")
    cmd.append(sql)
    out_p = _io_dir / "out.txt"
    err_p = _io_dir / "err.txt"
    _helper.stdin.write(json.dumps({"cmd": cmd, "out": str(out_p), "err": str(err_p)}) + "\n")
    _helper.stdin.flush()
    reply = json.loads(_helper.stdout.readline())
    return (reply["wall"], reply["rss"], reply["code"],
            out_p.read_text(errors="replace"), err_p.read_text(errors="replace"))


def sort_key(line: str):
    first = line.split("|", 1)[0]
    return (0, int(first), "") if re.fullmatch(r"-?[0-9]+", first) else (1, 0, line)


def normalized(text: str) -> list[str]:
    lines = text.rstrip("\n").split("\n")
    return [lines[0]] + sorted(lines[1:], key=sort_key)


def digest(text: str) -> str:
    return hashlib.sha256("\n".join(normalized(text)).encode()).hexdigest()[:12]


def counters(text: str) -> dict:
    found = {}
    for key in ("aggregate", "spill partitions", "spill files", "spill bytes written",
                "spill bytes read"):
        m = re.search(re.escape(key) + r": (\d+)", text)
        found[key] = int(m.group(1)) if m else 0
    return found


def duckdb_rows(csv: pathlib.Path, sql: str) -> str:
    import duckdb  # imported late: only --duckdb needs it

    con = duckdb.connect()
    con.execute(f"create table t as select * from read_csv('{csv}', header=true)")
    cur = con.execute(sql)
    head = "|".join(d[0] for d in cur.description)
    lines = [head]
    for row in cur.fetchall():
        cells = []
        for c in row:
            cells.append("null" if c is None else repr(c) if isinstance(c, float) else str(c))
        lines.append("|".join(cells))
    return "\n".join(lines) + "\n"


def compare_with_duckdb(work: pathlib.Path, ours: str, theirs: str) -> bool:
    a = work / "ours.txt"
    b = work / "duckdb.txt"
    a.write_text("\n".join(normalized(ours)) + "\n")
    b.write_text("\n".join(normalized(theirs)) + "\n")
    r = subprocess.run([sys.executable, str(REPO / "harness/compare.py"), str(b), str(a)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-600:] + r.stderr[-600:])
    return r.returncode == 0


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--control")
    ap.add_argument("--duckdb", action="store_true")
    ap.add_argument("--work")
    ap.add_argument("--rows", type=int, default=4_000_000)
    ap.add_argument("--budgets", default="4M,16M,32M")
    ap.add_argument("--rounds", type=int, default=4)
    ap.add_argument("--shapes", default=",".join(SHAPES))
    ap.add_argument("--scale-rows", default="")
    ap.add_argument("--scale-shape", default="groups-100")
    ap.add_argument("--json-out")
    ap.add_argument("--quiet-load", type=float, default=1.0)
    ap.add_argument("--quiet-samples", type=int, default=3)
    ap.add_argument("--quiet-interval", type=float, default=10.0)
    ap.add_argument("--quiet-timeout", type=float, default=3600.0)
    args = ap.parse_args()
    start_helper()

    for b in (args.candidate, args.control):
        if b and not os.access(b, os.X_OK):
            die(f"not an executable: {b}")
    if args.duckdb:
        try:
            import duckdb  # noqa: F401
        except ImportError:
            die("--duckdb needs the duckdb package (see harness/requirements.txt)")
    shapes = [x for x in args.shapes.split(",") if x]
    if args.scale_shape not in SHAPES:
        die(f"unknown shape {args.scale_shape}; known: {', '.join(SHAPES)}")
    for s in shapes:
        if s not in SHAPES:
            die(f"unknown shape {s}; known: {', '.join(SHAPES)}")
    budgets = args.budgets.split(",")

    work = pathlib.Path(args.work or tempfile.mkdtemp(prefix="agg-pull-"))
    work.mkdir(parents=True, exist_ok=True)
    spill = work / "spill"
    spill.mkdir(exist_ok=True)

    print(f"data: {args.rows} rows per shape under {work}", flush=True)
    cases = []
    for s in shapes:
        make_csv(work / s / "t.csv", args.rows, SHAPES[s][1])
        cases.append((s, work / s / "t.csv", SHAPES[s][2], SHAPES[s][3]))
    if args.scale_rows:
        sh = SHAPES[args.scale_shape]
        for n in (int(x) for x in args.scale_rows.split(",")):
            path = work / f"{args.scale_shape}-{n}" / "t.csv"
            make_csv(path, n, sh[1])
            cases.append((f"{args.scale_shape}@{n}", path, sh[2], sh[3]))

    quiet = wait_quiet(args.quiet_load, args.quiet_samples, args.quiet_interval,
                       args.quiet_timeout)
    print(f"host quiet: load {quiet:.2f}; starting", flush=True)

    bins = {"candidate": args.candidate}
    if args.control:
        bins["control"] = args.control
    failed = False
    report = []
    worst_spread = 0.0
    worst_load = quiet

    for s, csv, sql, vs_duck in cases:
        want_duck = None
        if args.duckdb and vs_duck:
            want_duck = duckdb_rows(csv, sql)
        for budget in budgets:
            load_before = load1()
            samples = {name: [] for name in bins}
            answers = {}
            for rnd in range(args.rounds):
                order = list(bins) if rnd % 2 == 0 else list(bins)[::-1]
                for name in order:
                    run_dir = spill / f"{s}-{budget}-{name}-{rnd}"
                    wall, rss, code, out, err = run_once(bins[name], csv, budget, sql, run_dir)
                    if code != 0:
                        print(f"FAIL {s} {budget} {name}: exit {code}: {err[:200]}")
                        failed = True
                        continue
                    if run_dir.exists():
                        print(f"FAIL {s} {budget} {name}: spill dir left behind: {run_dir}")
                        failed = True
                    samples[name].append((wall, rss))
                    answers[name] = out
            load_after = load1()
            worst_load = max(worst_load, load_before, load_after)
            _w, _r, _c, analyzed, _e = run_once(bins["candidate"], csv, budget, sql,
                                                spill / f"{s}-{budget}-analyze", analyze=True)
            stat = counters(analyzed)
            verdicts = []
            if "candidate" in answers and "control" in answers:
                same = digest(answers["candidate"]) == digest(answers["control"])
                verdicts.append("control " + ("same" if same else "DIFFERENT"))
                failed |= not same
            if want_duck is not None and "candidate" in answers:
                ok = compare_with_duckdb(work, answers["candidate"], want_duck)
                verdicts.append("duckdb " + ("same" if ok else "DIFFERENT"))
                failed |= not ok
            row = {"shape": s, "budget": budget, "load_before": load_before,
                   "load_after": load_after, "counters": stat, "answers": verdicts}
            for name, got in samples.items():
                if not got:
                    continue
                walls = [w for w, _ in got]
                med = statistics.median(walls)
                spread = (max(walls) - min(walls)) / med if med else 0.0
                worst_spread = max(worst_spread, spread)
                row[name] = {"wall_median": round(med, 3), "wall_spread": round(spread, 3),
                             "rss_mb": round(max(r for _, r in got), 1)}
            report.append(row)
            line = f"{s:24s} {budget:>4s}"
            for name in bins:
                if name in row:
                    r = row[name]
                    line += (f" | {name} {r['wall_median']:.2f}s (+-{r['wall_spread'] * 100:.0f}%)"
                             f" {r['rss_mb']:.0f}MB")
            line += (f" | parts {stat['spill partitions']} files {stat['spill files']}"
                     f" written {stat['spill bytes written']} groups {stat['aggregate']}")
            line += " | " + (", ".join(verdicts) or "no answer check")
            print(line, flush=True)

    print(f"worst round-to-round wall spread {worst_spread * 100:.0f}%, "
          f"highest load seen {worst_load:.2f}")
    # the load average includes this script's own benchmark runs (about one CPU
    # busy), so it cannot judge the run afterwards; the spread between rounds can
    if worst_spread > 0.10:
        print("WARNING: a case moved more than 10% between rounds; rerun before trusting its wall times")
    if args.json_out:
        pathlib.Path(args.json_out).write_text(json.dumps(
            {"rows": args.rows, "rounds": args.rounds, "worst_spread": worst_spread,
             "worst_load": worst_load, "cases": report}, indent=1))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
