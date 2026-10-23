#!/usr/bin/env python3
"""Replay the window-function differential battery against DuckDB.

`docs/verification.md` §5.1 records a 2026-10-04 experiment: 29 window queries
compared row-by-row against DuckDB on a small fixture. That experiment could not
be re-run from the repository — the fixture and script lived in the commit
history, not on disk. This is the re-runnable replacement: a fixed nine-row
fixture, a fixed case list, and a hard failure for anything that would have let
the old claim rot (a referee error, a missing input, zero executed cases).

What it compares:

* `ordered`   — the query carries a total order, so rows compare in sequence
                cell by cell with `harness/compare.py`'s rules (NULL is exactly
                `null`; integers exactly, including their width; two float
                spellings within 1e-9 relative; NaN/inf by sign).
* `multiset`  — the query has no total order, so rows compare as a multiset
                with duplicate counts (ties must not fake a mismatch).
* `legality`  — the value is implementation-defined (an order-free
                `string_agg` over a partition), so only "it runs and returns the
                right row count" is asserted; counted separately from value
                matches, never as a pass.
* `refusal`   — the engine must reject the query with a specific message, and
                DuckDB must accept it, so a refusal is our documented limit and
                not an invalid query. Counted separately.

A case whose result is nondeterministic by contract gets a unique tie-break key
in its ORDER BY or is downgraded to `legality`; multiset comparison does not
make `row_number` ties deterministic, and pretending otherwise was the old
battery's blind spot.

Usage:
  moon build cmd/main --target native
  MOONLAKE_BIN=_build/native/debug/build/cmd/main/main.exe \
    python3 harness/check_windows.py
  python3 harness/check_windows.py --random 400 --seed 20261023   # nightly

Exit codes: 0 all value cases matched (refusals as expected), 1 any mismatch or
gate failure, 2 environment/referee problem (missing binary/input, DuckDB
error). Deliberately no "skip" path: a case that cannot run is a failure.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass, field
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "harness"))
import compare  # noqa: E402  (same-directory helper; reused so the rules cannot drift)

NULL = "null"

FIXTURE = """id,grp,val,txt
1,a,10,x
2,a,20,x
3,a,20,y
4,b,,y
5,b,30,
6,,40,z
7,c,40,z
8,c,50,
9,a,,w
"""


@dataclass
class Case:
    name: str
    sql: str
    mode: str = "ordered"  # ordered | multiset | legality
    refusal: str | None = None  # expected message fragment when refusing
    # True: the query is valid SQL that we refuse (a documented limit).
    # False: the standard forbids it, so DuckDB must refuse it too.
    duckdb_accepts: bool = False
    note: str = ""


CASES: list[Case] = [
    # the three ranking functions, including ties and a NULL partition key
    Case(
        "row_number_by_id",
        "SELECT id, row_number() OVER (PARTITION BY grp ORDER BY id) AS rn FROM t ORDER BY id",
        note="row_number is only deterministic with a unique ORDER BY key",
    ),
    Case(
        "rank_ties_asc",
        "SELECT id, rank() OVER (ORDER BY val) AS r FROM t ORDER BY id",
        note="ties share a rank; NULL sort key follows DuckDB's default placement",
    ),
    Case(
        "dense_rank_partitioned",
        "SELECT id, dense_rank() OVER (PARTITION BY grp ORDER BY val) AS dr FROM t ORDER BY id",
    ),
    # a running frame with a unique ORDER BY key (RANGE == ROWS here)
    Case(
        "running_sum_partitioned",
        "SELECT id, sum(val) OVER (PARTITION BY grp ORDER BY id) AS s FROM t ORDER BY id",
    ),
    # whole-partition frames: no ORDER BY, so no peers to reason about
    Case(
        "count_whole_partition",
        "SELECT id, count(*) OVER (PARTITION BY grp) AS c FROM t ORDER BY id",
    ),
    Case(
        "count_distinct_partition",
        "SELECT id, count(DISTINCT val) OVER (PARTITION BY grp) AS c FROM t ORDER BY id",
    ),
    # two windows in one select list
    Case(
        "two_windows",
        "SELECT id, sum(val) OVER (PARTITION BY grp) AS s, "
        "count(*) OVER (PARTITION BY grp ORDER BY id) AS c FROM t ORDER BY id",
    ),
    # windows after aggregation, and an aggregate value as a sort key
    Case(
        "aggregate_then_window",
        "SELECT grp, sum(val) AS s, sum(sum(val)) OVER () AS tot FROM t GROUP BY grp ORDER BY grp",
        note="GROUP BY NULL is its own group; NULL ordering is compared, not assumed",
    ),
    Case(
        "aggregate_value_as_sort_key",
        "SELECT grp, sum(val) AS s, rank() OVER (ORDER BY sum(val)) AS r "
        "FROM t GROUP BY grp ORDER BY grp",
    ),
    # a window value inside a row expression
    Case(
        "window_in_expression",
        "SELECT id, sum(val) OVER (PARTITION BY grp) * 2 AS d FROM t ORDER BY id",
    ),
    # ties broken by a unique key, so row_number is deterministic again
    Case(
        "row_number_desc_with_tiebreak",
        "SELECT id, row_number() OVER (ORDER BY val DESC, id) AS rn FROM t ORDER BY id",
    ),
    # alias / ordinal reference to a window output
    Case(
        "alias_and_ordinal_reference",
        "SELECT id, rank() OVER (ORDER BY id) AS r FROM t ORDER BY 1, 2",
    ),
    # no total order: multiset with duplicate counts (integers only, so the
    # cell keys are unambiguous)
    Case(
        "unordered_multiset",
        "SELECT id, count(*) OVER (PARTITION BY grp) AS c FROM t",
        mode="multiset",
    ),
    # order-free aggregate: the concatenation order is implementation-defined
    Case(
        "string_agg_legality",
        "SELECT id, string_agg(txt, ',') OVER (PARTITION BY grp) AS s FROM t",
        mode="legality",
        note="a partition has no order contract, so the string itself is not compared",
    ),
    # documented refusals (message fragments come from engine/binder.mbt and
    # "window function misuse fails with clear errors" in engine/e2e_test.mbt)
    Case(
        "refuse_missing_over",
        "SELECT rank() FROM t",
        refusal="requires an OVER clause",
        note="DuckDB rejects a window function with no OVER as well",
    ),
    Case(
        "refuse_where_position",
        "SELECT id FROM t WHERE rank() OVER () > 1",
        refusal="only allowed in the SELECT list",
    ),
    Case(
        "refuse_order_by_position",
        "SELECT id FROM t ORDER BY row_number() OVER (ORDER BY id)",
        refusal="only allowed in the SELECT list",
        duckdb_accepts=True,
        note="valid SQL that this engine refuses: a documented limit",
    ),
    Case(
        "refuse_explicit_frame",
        "SELECT id, sum(val) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM t",
        refusal="frame clauses",
        duckdb_accepts=True,
        note="explicit frames are out of scope, not invalid SQL",
    ),
    Case(
        "refuse_non_aggregate_over",
        "SELECT upper(txt) OVER () FROM t",
        refusal="aggregates and ranking functions",
    ),
    Case(
        "refuse_nested_window",
        "SELECT row_number() OVER (PARTITION BY row_number() OVER ()) FROM t",
        refusal="nested window",
    ),
    Case(
        "refuse_window_inside_aggregate",
        "SELECT sum(row_number() OVER ()) FROM t",
        refusal="inside aggregate arguments",
    ),
    Case(
        "refuse_group_by_bare_column",
        "SELECT sum(val) OVER () FROM t GROUP BY grp",
        refusal="must appear in GROUP BY",
    ),
]


def moonlake_command() -> list[str]:
    env_bin = os.environ.get("MOONLAKE_BIN")
    if env_bin:
        return [env_bin]
    built = ROOT / "_build/native/debug/build/cmd/main/main.exe"
    if built.exists():
        return [str(built)]
    return ["moon", "run", "cmd/main", "--"]


@dataclass
class Run:
    returncode: int
    stdout: str
    stderr: str


def run_moonlake(sql: str, csv_path: Path) -> Run:
    cmd = [*moonlake_command(), "exec", "--csv", str(csv_path), sql]
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    return Run(proc.returncode, proc.stdout, proc.stderr)


def table_rows(text: str) -> list[list[str]]:
    """CLI rows: header line, then '|'-separated lines (same shape as compare.py)."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines:
        raise ValueError("moonlake printed no header line")
    return [line.split("|") for line in lines[1:]]


def duckdb_rows(sql: str, csv_path: Path) -> list[list[str]]:
    import duckdb

    con = duckdb.connect()
    try:
        con.execute(
            f"CREATE VIEW t AS SELECT * FROM read_csv_auto('{csv_path.as_posix()}', header=true)"
        )
        rows = con.execute(sql).fetchall()
    finally:
        con.close()
    return [["null" if v is None else str(v) for v in row] for row in rows]


def cell_key(cell: str) -> tuple:
    """Canonical multiset key: numbers as exact numbers, everything else exactly.

    `5` and `5.0` are the same key, because the two engines spell an
    integer-valued double differently (`5` here, `5.0` in DuckDB) and a
    multiset cannot use the ordered path's 1e-9 tolerance. Values whose last
    bits disagree therefore need an ordered case, which is how every float
    window case here is written.
    """
    low = cell.lower()
    if cell == NULL:
        return ("null",)
    if low in compare.NAN_WORDS:
        return ("num", "nan")
    if low in compare.INF_WORDS:
        return ("num", "-inf" if low.startswith("-") else "inf")
    if compare.number_kind(cell) is not None:
        try:
            return ("num", Fraction(cell))
        except (ValueError, OverflowError, ZeroDivisionError):
            return ("str", cell)
    return ("str", cell)


def compare_rows(min_mode: str, got: list[list[str]], want: list[list[str]]) -> str | None:
    """Return a mismatch description, or None when the rows agree."""
    if len(got) != len(want):
        return f"row count {len(got)} vs duckdb {len(want)}"
    if min_mode == "multiset":
        got_keys = Counter(tuple(cell_key(c) for c in row) for row in got)
        want_keys = Counter(tuple(cell_key(c) for c in row) for row in want)
        if got_keys != want_keys:
            missing = want_keys - got_keys
            extra = got_keys - want_keys
            parts = []
            if missing:
                parts.append(f"missing {list(missing.elements())[:3]}")
            if extra:
                parts.append(f"unexpected {list(extra.elements())[:3]}")
            return "; ".join(parts)
        return None
    for lineno, (got_row, want_row) in enumerate(zip(got, want), start=2):
        if len(got_row) != len(want_row):
            return f"line {lineno}: {len(got_row)} cols vs duckdb {len(want_row)}"
        for col, (g, w) in enumerate(zip(got_row, want_row)):
            if not compare.cell_eq(g, w):
                return f"line {lineno} col {col}: moonlake {g!r} vs duckdb {w!r}"
    return None


@dataclass
class Report:
    matched: list[str] = field(default_factory=list)
    multiset_matched: list[str] = field(default_factory=list)
    legality: list[str] = field(default_factory=list)
    refused: list[str] = field(default_factory=list)
    refused_in_agreement: list[str] = field(default_factory=list)
    failures: list[str] = field(default_factory=list)

    def value_cases(self) -> int:
        return len(self.matched) + len(self.multiset_matched)


def run_cases(cases: list[Case], csv_path: Path, runner=None, referee=None) -> Report:
    # Resolved here rather than as default arguments so a test or a one-off
    # wrapper can replace either side without re-binding the definition.
    runner = runner or run_moonlake
    referee = referee or duckdb_rows
    report = Report()
    for case in cases:
        if case.refusal is not None:
            got = runner(case.sql, csv_path)
            if got.returncode == 0:
                report.failures.append(
                    f"{case.name}: expected a refusal matching {case.refusal!r}, query succeeded"
                )
                continue
            if case.refusal not in got.stderr:
                report.failures.append(
                    f"{case.name}: refused without the expected message "
                    f"{case.refusal!r}: {got.stderr.strip()[:160]}"
                )
                continue
            # Valid SQL that we refuse is a documented limit and DuckDB must
            # run it; SQL the standard forbids must be refused by both, so a
            # refusal cannot quietly become "we cannot do the math".
            referee_error = None
            try:
                referee(case.sql, csv_path)
            except Exception as exc:  # noqa: BLE001 - any referee error fails the gate
                referee_error = exc
            if case.duckdb_accepts and referee_error is not None:
                report.failures.append(
                    f"{case.name}: refused by moonlake, but this is valid SQL and "
                    f"DuckDB ran it ({referee_error})"
                )
                continue
            if not case.duckdb_accepts and referee_error is None:
                report.failures.append(
                    f"{case.name}: moonlake refused it, but DuckDB accepted this query, "
                    "so the case wrongly claims the standard forbids it"
                )
                continue
            if case.duckdb_accepts:
                report.refused.append(case.name)
            else:
                report.refused_in_agreement.append(case.name)
            continue

        want = referee(case.sql, csv_path)  # referee errors propagate: never skip
        got = runner(case.sql, csv_path)
        if got.returncode != 0:
            report.failures.append(
                f"{case.name}: moonlake failed ({got.returncode}): {got.stderr.strip()[:200]}"
            )
            continue
        if case.mode == "legality":
            rows = table_rows(got.stdout)
            if len(rows) != len(want):
                report.failures.append(
                    f"{case.name}: legality row count {len(rows)} vs duckdb {len(want)}"
                )
            else:
                report.legality.append(case.name)
            continue
        rows = table_rows(got.stdout)
        mismatch = compare_rows(case.mode, rows, want)
        if mismatch:
            report.failures.append(f"{case.name}: {mismatch}")
        elif case.mode == "multiset":
            report.multiset_matched.append(case.name)
        else:
            report.matched.append(case.name)
    return report


def random_cases(rows: int, seed: int) -> tuple[str, list[Case]]:
    """A deterministic pseudo-random fixture for the nightly run (bigger N)."""
    import random

    rng = random.Random(seed)
    lines = ["id,grp,val,txt"]
    for i in range(1, rows + 1):
        grp = "" if rng.random() < 0.1 else rng.choice("abcde")
        val = "" if rng.random() < 0.1 else str(rng.randint(-20, 20))
        txt = "" if rng.random() < 0.1 else rng.choice("xyzw")
        lines.append(f"{i},{grp},{val},{txt}")
    fixture = "\n".join(lines) + "\n"
    cases = [
        Case("rand_row_number", "SELECT id, row_number() OVER (PARTITION BY grp ORDER BY id) AS rn FROM t ORDER BY id"),
        Case("rand_rank", "SELECT id, rank() OVER (ORDER BY val) AS r FROM t ORDER BY id"),
        Case("rand_dense_rank", "SELECT id, dense_rank() OVER (PARTITION BY grp ORDER BY val) AS dr FROM t ORDER BY id"),
        Case("rand_running_sum", "SELECT id, sum(val) OVER (PARTITION BY grp ORDER BY id) AS s FROM t ORDER BY id"),
        Case("rand_whole_partition", "SELECT id, count(*) OVER (PARTITION BY grp) AS c FROM t ORDER BY id"),
        Case("rand_count_distinct", "SELECT id, count(DISTINCT val) OVER (PARTITION BY grp) AS c FROM t ORDER BY id"),
        Case("rand_two_windows", "SELECT id, sum(val) OVER (PARTITION BY grp) AS s, count(*) OVER (PARTITION BY grp ORDER BY id) AS c FROM t ORDER BY id"),
        Case("rand_group_then_window", "SELECT grp, sum(val) AS s, sum(sum(val)) OVER () AS tot FROM t GROUP BY grp ORDER BY grp"),
    ]
    return fixture, cases


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--random", type=int, default=0, help="use N pseudo-random rows (nightly)")
    ap.add_argument("--seed", type=int, default=20261023, help="seed for --random")
    ap.add_argument("--fixture", type=Path, help="replay against an existing CSV named t (must have a header)")
    ap.add_argument("--keep", action="store_true", help="keep the generated fixture")
    args = ap.parse_args(argv)

    if args.fixture is not None and args.random:
        print("FAIL: --fixture and --random are mutually exclusive", file=sys.stderr)
        return 1
    if args.fixture is not None:
        if not args.fixture.is_file():
            print(f"FAIL: fixture {args.fixture} does not exist", file=sys.stderr)
            return 2
        if not args.fixture.read_text(encoding="utf-8").strip():
            print(f"FAIL: fixture {args.fixture} is empty", file=sys.stderr)
            return 2
        fixture, cases = None, CASES
    elif args.random:
        fixture, cases = random_cases(args.random, args.seed)
    else:
        fixture, cases = FIXTURE, CASES
    if not cases:
        print("FAIL: no cases to run", file=sys.stderr)
        return 1

    try:
        import duckdb  # noqa: F401  (fail as an environment problem, not a skip)
    except ImportError as exc:
        print(f"FAIL: reference tools are missing ({exc}); install harness/requirements.txt", file=sys.stderr)
        return 2

    workdir = Path(tempfile.mkdtemp(prefix="moonlake-windows-"))
    csv_path = workdir / "t.csv"
    try:
        # The CLI names a table after the file stem, and every case says `t`, so
        # a supplied fixture is copied in under that name instead of renamed in
        # place (the caller's file is never touched).
        if fixture is None:
            shutil.copyfile(args.fixture, csv_path)
        else:
            csv_path.write_text(fixture, encoding="utf-8")
        report = run_cases(cases, csv_path)
    finally:
        if args.keep:
            print(f"fixture kept at {csv_path}")
        else:
            shutil.rmtree(workdir, ignore_errors=True)


    print(
        f"value cases: {report.value_cases()} matched "
        f"({len(report.matched)} ordered, {len(report.multiset_matched)} multiset); "
        f"legality-only: {len(report.legality)}; "
        f"refused as documented: {len(report.refused)}; "
        f"refused in agreement with DuckDB: {len(report.refused_in_agreement)}"
    )
    for name in report.refused:
        print(f"  refused (valid SQL, our limit)  {name}")
    for name in report.refused_in_agreement:
        print(f"  refused (both engines reject)   {name}")
    for failure in report.failures:
        print(f"FAIL  {failure}")
    if report.value_cases() == 0:
        print("FAIL: no value case actually ran", file=sys.stderr)
        return 1
    if report.failures:
        return 1
    print("window differential: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
