# The release performance baseline: one machine, one build, four operator
# families (scan, join, gather, spill), recorded as JSON so two releases can
# be compared record-to-record instead of memory-to-memory.
#
# Usage:
#   python3 harness/bench_release.py                       # measure, print a table
#   python3 harness/bench_release.py --json-out harness/baseline/2026-10-20.json
#   python3 harness/bench_release.py --compare harness/baseline/2026-10-20.json
#   python3 harness/bench_release.py --binary /path/to/main.exe --no-build
#
# All timings are the fastest wall time of --runs runs after two warm-ups, with
# stdout drained to a temp file (its SHA-256 is recorded: a case whose output
# changes has changed its work, and --compare flags it). Peak RSS is VmHWM
# sampled while the child runs. Data is TPC-H SF0.01 (harness/gen_tpch.py).
#
# What each family holds:
#   scan   - the lazy scan: bytes read, column pruning, parquet row groups.
#   join   - the columnar hash join, from a bare count to the full Q3 pipeline.
#   gather - the paths that assemble output rows with per-column typed gathers
#            (filter + wide projection, and a self-join that emits 60k wide
#            rows); `gather` itself is package-private, so these are measured
#            end to end. Scan and stdout formatting are part of the number.
#   spill  - the in-query external sort under a 2 MB budget (asserting it
#            really spilled) plus the MLSPILL3 format's write and read.

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
DATA = REPO / "harness" / "data" / "sf01"
QUERIES = REPO / "harness" / "queries"
BASELINE_DIR = REPO / "harness" / "baseline"
SCHEMA = 1


def find_moon() -> str:
    found = shutil.which("moon")
    if found:
        return found
    fallback = pathlib.Path.home() / ".moon" / "bin" / "moon"
    if fallback.exists():
        return str(fallback)
    raise SystemExit("moon not found on PATH (or in ~/.moon/bin)")


def release_binary() -> pathlib.Path:
    """The native release CLI, wherever this toolchain laid it out."""
    matches = sorted(
        REPO.glob("_build/native/release/build/**/cmd/main/main.exe"),
        key=lambda p: p.stat().st_mtime,
    )
    if not matches:
        raise SystemExit(
            "no release CLI binary; run `moon build cmd/main --target native --release`"
        )
    return matches[-1]


def version_of_mod() -> str:
    text = (REPO / "moon.mod").read_text()
    match = re.search(r'^version\s*=\s*"([^"]+)"', text, re.M)
    return match.group(1) if match else "unknown"


def toolchain(moon: str) -> dict:
    proc = subprocess.run(
        [moon, "version", "--all"], capture_output=True, text=True, check=False
    )
    return {
        "raw": proc.stdout.strip().splitlines(),
        "moon": next(
            (line for line in proc.stdout.splitlines() if line.startswith("moon ")), ""
        ),
    }


def machine() -> dict:
    cpu_model = ""
    cpu_count = os.cpu_count()
    try:
        for line in pathlib.Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                cpu_model = line.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    mem_kb = 0
    try:
        for line in pathlib.Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                mem_kb = int(line.split()[1])
                break
    except OSError:
        pass
    governor = ""
    mhz = None
    try:
        governor = pathlib.Path(
            "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
        ).read_text().strip()
        mhz = round(
            int(
                pathlib.Path(
                    "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
                ).read_text()
            )
            / 1000
        )
    except (OSError, ValueError):
        pass
    return {
        "cpu": cpu_model,
        "cores": cpu_count,
        "mem_gb": round(mem_kb / (1024 * 1024), 1) if mem_kb else None,
        "governor": governor or None,
        "cpu_mhz_at_start": mhz,
        "kernel": platform.release(),
        "os": platform.platform(),
        "loadavg": list(os.getloadavg()) if hasattr(os, "getloadavg") else None,
        "python": platform.python_version(),
    }


def git_state() -> dict:
    def git(*args: str) -> str:
        try:
            return subprocess.run(
                ["git", *args], cwd=REPO, capture_output=True, text=True, check=False
            ).stdout.strip()
        except OSError:
            return ""

    dirty = bool(git("status", "--porcelain", "--untracked-files=no"))
    return {
        "commit": git("rev-parse", "HEAD"),
        "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
        "subject": git("log", "-1", "--format=%s"),
        "dirty": dirty,
    }


def run_once(
    cmd: list[str], stdout_path: pathlib.Path
) -> tuple[float, int, str, float]:
    """Run one child; return wall ms, peak RSS KiB, stdout SHA-256.

    `os.wait4` hands back that child's own rusage, so a 3 ms case still gets a
    real peak RSS (sampling /proc misses short-lived processes entirely) and
    the wall time carries no polling sleep. CPU time is recorded too: on a
    busy host wall time moves with preemption while user+sys does not.
    """
    t0 = time.monotonic()
    with open(stdout_path, "wb") as out, tempfile.TemporaryFile() as err:
        proc = subprocess.Popen(cmd, stdout=out, stderr=err)
        try:
            _, status, usage = os.wait4(proc.pid, 0)
        except AttributeError:  # non-POSIX: fall back to the Popen wait
            proc.wait()
            status, usage = None, None
        wall_ms = (time.monotonic() - t0) * 1000.0
        if usage is not None:
            proc.returncode = os.waitstatus_to_exitcode(status)
            peak = usage.ru_maxrss
            cpu_ms = (usage.ru_utime + usage.ru_stime) * 1000.0
        else:
            peak, cpu_ms = 0, 0.0
        if proc.returncode != 0:
            err.seek(0)
            raise SystemExit(
                f"bench case failed ({proc.returncode}): {' '.join(cmd)}\n"
                f"{err.read().decode(errors='replace')[-2000:]}"
            )
    digest = hashlib.sha256(stdout_path.read_bytes()).hexdigest()
    return wall_ms, peak, digest, cpu_ms


WARMUPS = 2


def measure(cmd: list[str], runs: int, scratch: pathlib.Path) -> dict:
    out = scratch / "stdout.txt"
    # two warm-ups: the page cache, and the CPU governor ramping up (on
    # `powersave` one warm-up leaves the first timed run at a lower clock)
    for _ in range(WARMUPS):
        run_once(cmd, out)
    samples = [run_once(cmd, out) for _ in range(runs)]
    walls = [s[0] for s in samples]
    cpus = [s[3] for s in samples]
    best = min(samples, key=lambda s: s[0])
    digests = {s[2] for s in samples}
    return {
        "wall_ms": round(best[0], 1),
        "median_ms": round(statistics.median(walls), 1),
        "cpu_ms": round(best[3], 1),
        "rss_mb": round(best[1] / 1024.0, 1),
        "output_sha256": best[2],
        "output_stable": len(digests) == 1,
    }


def dataset_sha256(data: pathlib.Path) -> str:
    """Hash the dataset the record describes, file names included.

    A path is not an identity: regenerating SF0.1 with a different generator
    version (or a different SF rounding) produces the same names and different
    numbers, and the two records would compare as if nothing had changed.
    """
    digest = hashlib.sha256()
    for path in sorted(p for p in data.iterdir() if p.is_file()):
        digest.update(path.name.encode())
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def csv_flags(data: pathlib.Path, *names: str) -> list[str]:
    return [arg for name in names for arg in ("--csv", str(data / name))]


def case_specs(data: pathlib.Path) -> list[dict]:
    def csv_case(id_, family, what, tables, sql, extra=None):
        return {
            "id": id_,
            "family": family,
            "what": what,
            "sql": sql,
            # the CLI takes the SQL as ONE argument, newlines and all
            "argv": [*csv_flags(data, *tables), sql],
            "extra": extra or {},
        }

    q3 = (QUERIES / "q3.sql").read_text().strip()
    return [
        csv_case(
            "scan/count_csv",
            "scan",
            "count(*) over lineitem.csv: schema only, no column decoded",
            ("lineitem.csv",),
            "SELECT count(*) FROM lineitem",
        ),
        csv_case(
            "scan/filtered_count_csv",
            "scan",
            "count(*) with a one-column predicate: decode + filter",
            ("lineitem.csv",),
            "SELECT count(*) FROM lineitem WHERE l_quantity < 24",
        ),
        {
            "id": "scan/parquet_count",
            "family": "scan",
            "what": "count(*) over lineitem.parquet: footer only, no column chunk read",
            "sql": "SELECT count(*) FROM lineitem",
            "argv": [
                "--parquet",
                str(data / "lineitem.parquet"),
                "SELECT count(*) FROM lineitem",
            ],
            "extra": {},
        },
        {
            "id": "scan/parquet_sum",
            "family": "scan",
            "what": "sum(l_quantity) over lineitem.parquet: one column chunk per group",
            "sql": "SELECT sum(l_quantity) FROM lineitem",
            "argv": [
                "--parquet",
                str(data / "lineitem.parquet"),
                "SELECT sum(l_quantity) FROM lineitem",
            ],
            "extra": {},
        },
        csv_case(
            "join/two_table_count",
            "join",
            "lineitem x orders hash join, count(*) only",
            ("lineitem.csv", "orders.csv"),
            "SELECT count(*) FROM lineitem l JOIN orders o ON l.l_orderkey = o.o_orderkey",
        ),
        csv_case(
            "join/q3",
            "join",
            "TPC-H Q3 official text over three CSV tables (build+probe+group+top-N)",
            ("customer.csv", "orders.csv", "lineitem.csv"),
            q3,
        ),
        csv_case(
            "gather/wide_projection",
            "gather",
            "filter then wide projection inside a derived table: the 16 "
            "materialized columns are assembled by per-column gathers, and "
            "only one output row is printed",
            ("lineitem.csv",),
            "SELECT sum(l_extendedprice) FROM "
            "(SELECT * FROM lineitem WHERE l_tax > 0.0) t",
        ),
        csv_case(
            "gather/self_join_fanout",
            "gather",
            "self-join emitting 600k wide rows, counted: join-output assembly "
            "gathers 16 columns per output row",
            ("lineitem.csv",),
            "SELECT count(*) FROM lineitem a JOIN lineitem b "
            "ON a.l_orderkey = b.l_orderkey AND b.l_linenumber = 1",
        ),
        {
            "id": "spill/order_by_wide",
            "family": "spill",
            "what": "two-column external sort over 600k rows under a 2 MB budget "
            "(must actually spill)",
            "argv": [
                "--csv",
                str(data / "lineitem.csv"),
                "--memory",
                "2M",
                "--spill-dir",
                "{spill_dir}",
                "SELECT l_orderkey, l_extendedprice FROM lineitem "
                "ORDER BY l_extendedprice DESC, l_orderkey LIMIT 3",
            ],
            "extra": {"budget": "2M"},
        },
    ]


def spill_format_cases(
    runs: int, moon: str, scratch: pathlib.Path, no_build: bool, data: pathlib.Path
) -> tuple[list[dict], dict]:
    """The MLSPILL3 format's write/read numbers, through the dev driver."""
    driver_pkg = REPO / "harness" / "spill_bench"
    if not no_build:
        subprocess.run(
            [moon, "build", "--target", "native", "--release", str(driver_pkg)],
            cwd=REPO,
            check=True,
            capture_output=True,
        )
    script = REPO / "harness" / "spill_bench.py"
    proc = subprocess.run(
        [
            sys.executable,
            str(script),
            "--no-build",
            "--runs",
            str(runs),
            "--csv",
            str(data / "lineitem.csv"),
        ],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise SystemExit(f"spill format bench failed:\n{proc.stdout}\n{proc.stderr}")
    text = proc.stdout
    numbers = {
        "rows": int(re.search(r"rows\s+(\d+)", text).group(1)),
        "bytes": int(re.search(r"bytes\s+(\d+)", text).group(1)),
        "checksum": re.search(r"checksum\s+(\S+)", text).group(1),
    }
    write = re.search(r"write\s+([\d.]+) ms\s+peak RSS ([\d.]+) MiB", text)
    read = re.search(r"read\s+([\d.]+) ms\s+peak RSS ([\d.]+) MiB", text)
    if not write or not read:
        raise SystemExit(f"could not parse spill_bench output:\n{text}")
    cases = [
        {
            "id": "spill/format_write",
            "family": "spill",
            "what": "MLSPILL3 encode+write of every lineitem batch (release driver)",
            "wall_ms": round(float(write.group(1)), 1),
            "median_ms": None,  # the driver reports its own best-of
            "cpu_ms": None,
            "rss_mb": round(float(write.group(2)), 1),
            "output_sha256": numbers["checksum"],
            "output_stable": True,
            "extra": {"rows": numbers["rows"], "bytes": numbers["bytes"]},
        },
        {
            "id": "spill/format_read",
            "family": "spill",
            "what": "MLSPILL3 read+decode of the same file (release driver)",
            "wall_ms": round(float(read.group(1)), 1),
            "median_ms": None,  # the driver reports its own best-of
            "cpu_ms": None,
            "rss_mb": round(float(read.group(2)), 1),
            "output_sha256": numbers["checksum"],
            "output_stable": True,
            "extra": {"rows": numbers["rows"], "bytes": numbers["bytes"]},
        },
    ]
    return cases, numbers


def run_cases(
    specs: list[dict], binary: pathlib.Path, runs: int, scratch: pathlib.Path
) -> list[dict]:
    results = []
    for spec in specs:
        spill_dir = scratch / ("spill-" + spec["id"].replace("/", "-"))
        argv = [
            arg.format(spill_dir=str(spill_dir)) if isinstance(arg, str) else str(arg)
            for arg in spec["argv"]
        ]
        if spec["id"].startswith("spill/"):
            spill_dir.mkdir(parents=True, exist_ok=True)
        cmd = [str(binary), "exec", *argv]
        if spec["id"].startswith("spill/"):
            # The engine removes its run files when the query ends (it used to
            # leak them, which is how this case first "proved" a spill: by
            # counting leftovers). Ask ANALYZE instead, once, before timing.
            probe = [str(binary), "exec", "--analyze", *argv]
            probe_out = subprocess.run(probe, capture_output=True, text=True)
            if "spill files:" not in probe_out.stdout:
                raise SystemExit(
                    f"{spec['id']}: ANALYZE reports no spill under this budget, so the "
                    "case no longer measures the out-of-core path; the workload or the "
                    "budget has drifted"
                )
        try:
            measured = measure(cmd, runs, scratch)
        except SystemExit:
            raise
        record = {
            "id": spec["id"],
            "family": spec["family"],
            "what": spec["what"],
            # the workload itself, so a number can be traced back to a query
            # rather than to a prose description of one
            "sql": spec.get("sql"),
            **measured,
            "extra": dict(spec["extra"]),
        }
        if spec["id"].startswith("spill/"):
            # the query is over, so its files must be gone: that is the
            # lifecycle guarantee, and leftovers mean the cleanup regressed
            files = len(list(spill_dir.glob("*")))
            record["extra"]["leftover_files"] = files
            if files != 0:
                raise SystemExit(
                    f"{spec['id']}: {files} file(s) left in {spill_dir} after the query; "
                    "the spill cleanup regressed"
                )
        results.append(record)
        median = (
            f"{record['median_ms']:>7.1f}" if record["median_ms"] is not None else "      -"
        )
        cpu = f"{record['cpu_ms']:>8.1f}" if record.get("cpu_ms") else "       -"
        print(
            f"  {record['id']:<28} {record['wall_ms']:>8.1f} ms  "
            f"median {median}  cpu {cpu}  RSS {record['rss_mb']:>6.1f} MB"
            + ("" if record["output_stable"] else "  [unstable output]"),
            flush=True,
        )
    return results


def print_table(cases: list[dict]) -> None:
    print("\n| family | case | wall ms | median ms | cpu ms | peak RSS MB |")
    print("|---|---|---|---|---|---|")
    for case in cases:
        print(
            f"| {case['family']} | {case['id']} | {case['wall_ms']:.1f} | "
            f"{'-' if case['median_ms'] is None else format(case['median_ms'], '.1f')} | "
            f"{'-' if not case.get('cpu_ms') else format(case['cpu_ms'], '.1f')} | "
            f"{case['rss_mb']:.1f} |"
        )


def compare(old: dict, new: dict) -> int:
    old_cases = {case["id"]: case for case in old["cases"]}
    new_cases = {case["id"]: case for case in new["cases"]}
    print(
        f"baseline {old['release'].get('version')} @ {old['release'].get('git_commit', '')[:12]}"
        f" ({old.get('created_at', '')})"
    )
    print(
        f"current  {new['release'].get('version')} @ {new['release'].get('git_commit', '')[:12]}"
    )
    print(
        f"\n| case | wall old | wall new | wall delta | cpu old | cpu new | "
        f"cpu delta | RSS old -> new | note |"
    )
    print("|---|---|---|---|---|---|---|---|---|")
    problems = 0
    for id_, case in new_cases.items():
        before = old_cases.get(id_)
        if not before:
            print(f"| {id_} | - | {case['wall_ms']:.1f} | new case | - | |")
            continue
        delta = (case["wall_ms"] - before["wall_ms"]) / max(before["wall_ms"], 1e-9)
        note = ""
        if before.get("output_sha256") != case.get("output_sha256"):
            note = "output changed — not comparable"
            problems += 1
        if not case.get("output_stable", True):
            note = (note + " output unstable").strip()
            problems += 1
        def num(value):
            return "-" if not value else f"{value:.1f}"

        cpu_delta = "-"
        if before.get("cpu_ms") and case.get("cpu_ms"):
            d = (case["cpu_ms"] - before["cpu_ms"]) / before["cpu_ms"]
            cpu_delta = f"{d * 100:+.1f}%"
        print(
            f"| {id_} | {before['wall_ms']:.1f} | {case['wall_ms']:.1f} | "
            f"{delta * 100:+.1f}% | {num(before.get('cpu_ms'))} | "
            f"{num(case.get('cpu_ms'))} | {cpu_delta} | "
            f"{before['rss_mb']:.1f} -> {case['rss_mb']:.1f} MB | {note} |"
        )
    return 1 if problems else 0


def main() -> int:
    parser = argparse.ArgumentParser(description="moonlake release performance baseline")
    parser.add_argument("--runs", type=int, default=7, help="fastest of N runs (default 7)")
    parser.add_argument("--binary", help="release CLI binary (default: the newest build)")
    parser.add_argument("--json-out", help="write the record here")
    parser.add_argument("--compare", help="compare against an earlier record")
    parser.add_argument("--no-build", action="store_true", help="reuse existing binaries")
    parser.add_argument("--data", default=str(DATA), help="TPC-H SF0.1 data directory")
    args = parser.parse_args()

    data = pathlib.Path(args.data).resolve()
    for needed in ("lineitem.csv", "orders.csv", "customer.csv", "lineitem.parquet"):
        if not (data / needed).exists():
            raise SystemExit(
                f"missing {data / needed}; generate the data with "
                "`uv run --with duckdb python harness/gen_tpch.py`"
            )

    moon = find_moon()
    if not args.no_build:
        print("building release binaries ...", flush=True)
        subprocess.run(
            [moon, "build", "cmd/main", "--target", "native", "--release"],
            cwd=REPO,
            check=True,
            capture_output=True,
        )
    binary = pathlib.Path(args.binary) if args.binary else release_binary()
    if not binary.exists():
        raise SystemExit(f"missing binary {binary}")

    metrics = machine()
    git = git_state()
    record = {
        "schema": SCHEMA,
        "kind": "moonlake-release-baseline",
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "release": {
            "version": version_of_mod(),
            "git_commit": git["commit"],
            "git_branch": git["branch"],
            "git_subject": git["subject"],
            "git_dirty": git["dirty"],
            "binary": str(binary.relative_to(REPO)),
            "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        },
        "environment": {
            "toolchain": toolchain(moon),
            **metrics,
        },
        "method": {
            "runs": args.runs,
            "warmups": WARMUPS,
            "statistic": "fastest wall time after the warm-ups",
            "stdout": "drained to a temp file and hashed (SHA-256), not stored",
            "data": str(data.relative_to(REPO)) if data.is_relative_to(REPO) else str(data),
            "data_sha256": dataset_sha256(data),
            "data_note": "TPC-H SF0.1, tracked in the repository; regenerate "
            "with `python harness/gen_tpch.py 0.1`",
            "build": "native release (`moon build cmd/main --target native --release`)",
        },
        "cases": [],
    }

    print(f"release {record['release']['version']} @ {record['release']['git_commit'][:12]}"
          f"{' (dirty tree)' if record['release']['git_dirty'] else ''}")
    print(f"machine {metrics['cpu']} x{metrics['cores']}, {metrics['mem_gb']} GB, "
          f"governor {metrics['governor']}, {metrics['cpu_mhz_at_start']} MHz at start")
    print(f"data    {record['method']['data']}\n")

    with tempfile.TemporaryDirectory(prefix="moonlake-bench-") as tmp:
        scratch = pathlib.Path(tmp)
        specs = case_specs(data)
        cases = run_cases(specs, binary, args.runs, scratch)
        format_cases, _ = spill_format_cases(args.runs, moon, scratch, args.no_build, data)
        cases.extend(format_cases)
        record["cases"] = cases

    print_table(cases)
    unstable = [case["id"] for case in cases if not case["output_stable"]]
    if unstable:
        print(f"\nwarning: unstable output in {', '.join(unstable)}")

    if args.json_out:
        out = pathlib.Path(args.json_out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(record, indent=2) + "\n")
        print(f"\nwrote {out}")

    status = 0
    if args.compare:
        status = compare(json.loads(pathlib.Path(args.compare).read_text()), record)
    return status


if __name__ == "__main__":
    sys.exit(main())
