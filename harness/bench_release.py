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
import gc
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
    # The spread of this case's own runs is the floor a comparison has to
    # clear: a 3% delta against a case that moved 8% between its own runs is
    # not evidence of anything. Recorded rather than assumed so a later
    # comparison can say "inside this run's spread" with numbers.
    spread = (
        round((max(walls) - min(walls)) / min(walls) * 100.0, 1)
        if runs > 1 and min(walls) > 0
        else None
    )
    return {
        "wall_ms": round(best[0], 1),
        "median_ms": round(statistics.median(walls), 1),
        "cpu_ms": round(best[3], 1),
        "rss_mb": round(best[1] / 1024.0, 1),
        "wall_spread_pct": spread,
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


def _compare_module():
    """harness/compare.py is the one cell-comparison rule set in this repo."""
    sys.path.insert(0, str(REPO / "harness"))
    import compare

    return compare


def _fmt(value) -> str:
    """A DuckDB cell as the CLI would spell it."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


# An answer the timing cases must agree with, evaluated outside the timed
# region. stdout's SHA-256 already says "this case always does the same work";
# it cannot say the work is right — a runner that returns a stable wrong answer
# hashes just as consistently. These are read_csv_auto/read_parquet views over
# the same files, so the reference has its own parser and its own plan.
ORACLES: dict[str, dict] = {
    "scan/count_csv": {
        "sql": "SELECT count(*) FROM lineitem",
        "tables": {"lineitem": ("csv", "lineitem.csv")},
    },
    "scan/filtered_count_csv": {
        "sql": "SELECT count(*) FROM lineitem WHERE l_quantity < 24",
        "tables": {"lineitem": ("csv", "lineitem.csv")},
    },
    "scan/parquet_count": {
        "sql": "SELECT count(*) FROM lineitem",
        "tables": {"lineitem": ("parquet", "lineitem.parquet")},
    },
    "scan/parquet_sum": {
        "sql": "SELECT sum(l_quantity) FROM lineitem",
        "tables": {"lineitem": ("parquet", "lineitem.parquet")},
    },
    "join/two_table_count": {
        "sql": "SELECT count(*) FROM lineitem l JOIN orders o ON l.l_orderkey = o.o_orderkey",
        "tables": {
            "lineitem": ("csv", "lineitem.csv"),
            "orders": ("csv", "orders.csv"),
        },
    },
    "gather/wide_projection": {
        "sql": "SELECT sum(l_extendedprice) FROM (SELECT * FROM lineitem WHERE l_tax > 0.0) t",
        "tables": {"lineitem": ("csv", "lineitem.csv")},
    },
    "gather/self_join_fanout": {
        "sql": "SELECT count(*) FROM lineitem a JOIN lineitem b ON a.l_orderkey = b.l_orderkey AND b.l_linenumber = 1",
        "tables": {"lineitem": ("csv", "lineitem.csv")},
    },
    "spill/order_by_wide": {
        "sql": "SELECT l_orderkey, l_extendedprice FROM lineitem ORDER BY l_extendedprice DESC, l_orderkey LIMIT 3",
        "tables": {"lineitem": ("csv", "lineitem.csv")},
    },
    # Q3's top-10 has no total order (revenue ties), so it compares as a
    # multiset; the golden chain already pins the exact order.
    "join/q3": {
        "sql": (QUERIES / "q3.sql").read_text().strip(),
        "tables": {
            "customer": ("csv", "customer.csv"),
            "orders": ("csv", "orders.csv"),
            "lineitem": ("csv", "lineitem.csv"),
        },
        "mode": "multiset",
    },
}


def duckdb_answer(case_id: str, data: pathlib.Path) -> list[list[str]]:
    import duckdb

    spec = ORACLES[case_id]
    con = duckdb.connect()
    try:
        for name, (kind, filename) in spec["tables"].items():
            path = (data / filename).as_posix()
            source = (
                f"read_csv_auto('{path}', header=true)"
                if kind == "csv"
                else f"read_parquet('{path}')"
            )
            con.execute(f"CREATE VIEW {name} AS SELECT * FROM {source}")
        rows = con.execute(spec["sql"]).fetchall()
    finally:
        con.close()
    return [[_fmt(value) for value in row] for row in rows]


def cli_answer(cmd: list[str], cwd: pathlib.Path) -> list[list[str]]:
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    if proc.returncode != 0:
        raise SystemExit(
            f"oracle run failed ({proc.returncode}): {' '.join(cmd)}\n{proc.stderr[-2000:]}"
        )
    lines = proc.stdout.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines:
        raise SystemExit(f"oracle run printed no header: {' '.join(cmd)}")
    return [line.split("|") for line in lines[1:]]


def _multiset_equal(got: list[list[str]], want: list[list[str]], cell_eq) -> bool:
    """Greedy tolerance-aware multiset equality; the answer sets are tiny."""
    if len(got) != len(want):
        return False
    remaining = list(want)
    for row in got:
        for i, candidate in enumerate(remaining):
            if len(candidate) == len(row) and all(
                cell_eq(a, b) for a, b in zip(row, candidate)
            ):
                remaining.pop(i)
                break
        else:
            return False
    return not remaining


def check_oracles(
    cases: list[dict], specs: list[dict], binary: pathlib.Path, data: pathlib.Path
) -> list[str]:
    """Verify each timed case's answer outside the timed region.

    Mutates every matched case record with `oracle: {rows, matched}` and returns
    the failures; the caller aborts on a non-empty list, so a stable wrong answer
    cannot be recorded as a baseline.
    """
    compare = _compare_module()
    by_id = {spec["id"]: spec for spec in specs}
    failures: list[str] = []
    for case in cases:
        case_id = case["id"]
        if case_id not in ORACLES:
            continue
        spec = by_id[case_id]
        argv = [
            arg.format(spill_dir=str(pathlib.Path(tempfile.mkdtemp(prefix="moonlake-oracle-"))))
            if isinstance(arg, str)
            else str(arg)
            for arg in spec["argv"]
        ]
        want = duckdb_answer(case_id, data)  # referee errors propagate: no skip
        got = cli_answer([str(binary), "exec", *argv], REPO)
        mode = ORACLES[case_id].get("mode", "ordered")
        if mode == "multiset":
            matched = _multiset_equal(got, want, compare.cell_eq)
        else:
            matched = len(got) == len(want) and all(
                len(g) == len(w)
                and all(compare.cell_eq(a, b) for a, b in zip(g, w))
                for g, w in zip(got, want)
            )
        case["oracle"] = {"referee": "duckdb", "rows": len(want), "mode": mode, "matched": matched}
        if not matched:
            failures.append(
                f"{case_id}: the timed answer disagrees with duckdb "
                f"(moonlake {got[:2]} vs duckdb {want[:2]})"
            )
        print(
            f"  oracle {case_id:<28} {'ok' if matched else 'MISMATCH'} "
            f"({len(want)} row(s), {mode})",
            flush=True,
        )
    return failures


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
    print(
        "\n| family | case | wall ms | median ms | cpu ms | peak RSS MB | run spread |"
    )
    print("|---|---|---|---|---|---|---|")
    for case in cases:
        spread = case.get("wall_spread_pct")
        print(
            f"| {case['family']} | {case['id']} | {case['wall_ms']:.1f} | "
            f"{'-' if case['median_ms'] is None else format(case['median_ms'], '.1f')} | "
            f"{'-' if not case.get('cpu_ms') else format(case['cpu_ms'], '.1f')} | "
            f"{case['rss_mb']:.1f} | "
            f"{'-' if spread is None else format(spread, '.1f') + '%'} |"
        )


def toolchain_identity(text) -> str:
    """Compare the toolchain by version, not by where it is installed.

    `moon version` prints `moon 0.1.20261016 (1af328f 2026-10-16) /path/bin/moon`.
    The path is not a measurement condition — a release recorded through a
    scratch MOON_HOME (needed when the default home is not writable) is the same
    toolchain and was being refused as a mismatch.
    """
    if not text:
        return text
    match = re.match(r"moon\s+(\S+)\s+\(([0-9a-f]+)", str(text))
    return f"moon {match.group(1)} ({match.group(2)})" if match else str(text)


def fingerprint(record: dict) -> dict:
    """The conditions a timing is only meaningful under.

    `compare` refuses to print deltas when two records disagree on any of
    these, because the difference would be the machine, the data or the build
    rather than the code — the mistake the 0.3.0 -> 0.3.1 pair made before the
    fields were recorded. Fields absent from an older record ("not recorded")
    are reported and skipped, so a record from before 2026-10-21 stays usable.
    """
    env = record.get("environment") or {}
    method = record.get("method") or {}
    tool = env.get("toolchain") or {}
    return {
        "cpu": env.get("cpu"),
        "cores": env.get("cores"),
        "kernel": env.get("kernel"),
        "toolchain": toolchain_identity(tool.get("moon")),
        "data_sha256": method.get("data_sha256"),
        "build": method.get("build"),
        "runs": method.get("runs"),
        "warmups": method.get("warmups"),
    }


def advisory(old: dict, new: dict) -> None:
    """Conditions that legitimately differ between sessions but colour every
    number: print them, because a reader who cannot see them will read machine
    state as an optimization (0.3.0 -> 0.3.1 was 10-25% faster on identical
    code)."""
    before_env = old.get("environment") or {}
    after_env = new.get("environment") or {}
    notes = []
    for key, label in (
        ("cpu_mhz_at_start", "CPU MHz at start"),
        ("loadavg", "load average"),
        ("governor", "CPU governor"),
    ):
        before, after = before_env.get(key), after_env.get(key)
        if before is not None and after is not None and str(before) != str(after):
            notes.append(f"{label}: {before} -> {after}")
    if notes:
        print("conditions that moved between the records:")
        for line in notes:
            print(f"  {line}")
        print(
            "  deltas across a session boundary are machine state until a"
            " re-measurement in this session shows the same thing; a same-session"
            " spread is in each case's `run spread`."
        )


def num(value):
    return "-" if not value else f"{value:.1f}"


def compare(old: dict, new: dict, allow_env_mismatch: bool = False) -> int:
    old_cases = {case["id"]: case for case in old["cases"]}
    new_cases = {case["id"]: case for case in new["cases"]}
    print(
        f"baseline {old['release'].get('version')} @ {old['release'].get('git_commit', '')[:12]}"
        f" ({old.get('created_at', '')})"
    )
    print(
        f"current  {new['release'].get('version')} @ {new['release'].get('git_commit', '')[:12]}"
    )

    before_fp, after_fp = fingerprint(old), fingerprint(new)
    mismatched, unrecorded = [], []
    for key, before in before_fp.items():
        after = after_fp.get(key)
        if before is None or after is None:
            if before != after:
                unrecorded.append(key)
            continue
        if str(before) != str(after):
            mismatched.append(f"{key}: old {before!r} vs new {after!r}")
    if unrecorded:
        print(f"not compared (one record predates it): {', '.join(unrecorded)}")
    if mismatched:
        print("\nThese records were not taken under the same conditions:")
        for line in mismatched:
            print(f"  {line}")
        if not allow_env_mismatch:
            print(
                "\nrefusing to print deltas: a difference in machine, data or build"
                " is not an optimization. Re-record the earlier release on this"
                " machine in this session (`--json-out`), or pass"
                " --allow-env-mismatch knowing the numbers below mix conditions."
            )
            return 2
        print("continuing anyway (--allow-env-mismatch): the deltas mix conditions.\n")

    advisory(old, new)
    print(
        f"\n| case | wall old | wall new | wall delta | cpu old | cpu new | "
        f"cpu delta | RSS old -> new | note |"
    )
    print("|---|---|---|---|---|---|---|---|---|")
    problems = 0
    outside = 0
    spreads_seen = 0
    for id_, case in new_cases.items():
        before = old_cases.pop(id_, None)
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
        spreads = [
            spread
            for spread in (before.get("wall_spread_pct"), case.get("wall_spread_pct"))
            if spread is not None
        ]
        if spreads:
            spreads_seen += 1
            band = max(spreads)
            if abs(delta * 100.0) <= band:
                note = (note + f" inside the {band:.1f}% run spread").strip()
            else:
                outside += 1
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
    for id_, before in old_cases.items():
        print(f"| {id_} | {before['wall_ms']:.1f} | - | removed from the record | - | |")
    if outside or spreads_seen:
        print(
            f"\n{outside} case(s) moved further than their own run-to-run spread; "
            "everything else is inside the noise those runs already showed."
        )
    else:
        print(
            "\nno run spread in these records (recorded since 2026-10-21), so "
            "these deltas cannot be judged against noise — re-record both sides "
            "in one session before believing a size."
        )
    return 1 if problems else 0


def main() -> int:
    parser = argparse.ArgumentParser(description="moonlake release performance baseline")
    parser.add_argument("--runs", type=int, default=7, help="fastest of N runs (default 7)")
    parser.add_argument("--binary", help="release CLI binary (default: the newest build)")
    parser.add_argument("--json-out", help="write the record here")
    parser.add_argument("--compare", help="compare against an earlier record")
    parser.add_argument(
        "--allow-env-mismatch",
        action="store_true",
        help="print deltas even when machine/data/build differ (they mix conditions)",
    )
    parser.add_argument("--no-build", action="store_true", help="reuse existing binaries")
    parser.add_argument(
        "--no-oracle",
        action="store_true",
        help="skip the DuckDB answer check (timings only; see the README's caveat)",
    )
    parser.add_argument(
        "--check-oracles",
        action="store_true",
        help="verify the cases' answers against DuckDB and exit (no timings, no record)",
    )
    parser.add_argument("--data", default=str(DATA), help="TPC-H SF0.1 data directory")
    args = parser.parse_args()

    data = pathlib.Path(args.data).resolve()
    for needed in ("lineitem.csv", "orders.csv", "customer.csv", "lineitem.parquet"):
        if not (data / needed).exists():
            raise SystemExit(
                f"missing {data / needed}; generate the data with "
                "`uv run --python 3.12 --with-requirements harness/requirements.txt python harness/gen_tpch.py`"
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

    if args.check_oracles:
        specs = case_specs(data)
        failures = check_oracles(
            [{"id": spec["id"]} for spec in specs], specs, binary, data
        )
        if failures:
            for failure in failures:
                print(f"FAIL  {failure}")
            return 1
        print("oracles: every timed case agrees with duckdb")
        return 0

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
            # filled in after the cases run: see `rss_note`
            "data_sha256": None,
            "data_note": "TPC-H SF0.1, tracked in the repository; regenerate "
            "with `python harness/gen_tpch.py 0.1`",
            "build": "native release (`moon build cmd/main --target native --release`)",
            "rss_note": "peak RSS is the child's own ru_maxrss, but a forked "
            "child starts with the parent's resident pages, so anything big in "
            "this process at fork time becomes a floor on every small case "
            "(the 75 MB CSV hash showed up as a 70 MB floor on the Parquet "
            "cases). The parent is therefore kept thin while measuring and the "
            "dataset is hashed afterwards",
        },
        "cases": [],
    }

    print(f"release {record['release']['version']} @ {record['release']['git_commit'][:12]}"
          f"{' (dirty tree)' if record['release']['git_dirty'] else ''}")
    print(f"machine {metrics['cpu']} x{metrics['cores']}, {metrics['mem_gb']} GB, "
          f"governor {metrics['governor']}, {metrics['cpu_mhz_at_start']} MHz at start")
    print(f"data    {record['method']['data']}\n")

    gc.collect()  # a fat parent inflates every child's inherited RSS floor
    with tempfile.TemporaryDirectory(prefix="moonlake-bench-") as tmp:
        scratch = pathlib.Path(tmp)
        specs = case_specs(data)
        cases = run_cases(specs, binary, args.runs, scratch)
        if not args.no_oracle:
            print("verifying the timed answers against duckdb (outside the timed region) ...")
            failures = check_oracles(cases, specs, binary, data)
            if failures:
                for failure in failures:
                    print(f"FAIL  {failure}")
                raise SystemExit(
                    "refusing to record a baseline whose answers disagree with duckdb"
                )
        format_cases, _ = spill_format_cases(args.runs, moon, scratch, args.no_build, data)
        cases.extend(format_cases)
        record["cases"] = cases
    # after the cases, not before: reading every data file to hash it would put
    # ~75 MB in the parent, and the forked children would inherit that as their
    # measured RSS floor (see method.rss_note)
    record["method"]["data_sha256"] = dataset_sha256(data)

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
        status = compare(
            json.loads(pathlib.Path(args.compare).read_text()),
            record,
            allow_env_mismatch=args.allow_env_mismatch,
        )
    return status


if __name__ == "__main__":
    sys.exit(main())
