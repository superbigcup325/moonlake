#!/usr/bin/env python3
"""Shared plumbing for the DuckDB-refereed differential gates.

Two gates ask the same question of two engines: `check_windows.py` over window
functions and `check_correlation.py` over correlated subqueries. What a case
means, how the CLI's `|`-separated table output splits into cells, when two
cells agree (delegated to `compare.py`, which the golden comparator also uses)
and how each engine is invoked must therefore have one implementation, not two
that drift apart.

A gate still owns what is specific to it: its fixtures, its case list and how
the referee sees those fixtures. Nothing here decides pass or fail — a `Report`
counts what happened, and the gate decides which counts it requires, because
"refused as documented" is evidence for a limit and never evidence that an
answer is right.
"""

from __future__ import annotations

import os
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass, field
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "harness"))
import compare  # noqa: E402  (same-directory helper; the comparison rules live there)

NULL = compare.NULL

CLI_BUILD = ROOT / "_build/native/debug/build/cmd/main/main.exe"


def moonlake_command() -> list[str]:
    env_bin = os.environ.get("MOONLAKE_BIN")
    if env_bin:
        return [env_bin]
    if CLI_BUILD.exists():
        return [str(CLI_BUILD)]
    return ["moon", "run", "cmd/main", "--"]


def as_paths(inputs) -> list[Path]:
    """One path or a sequence of them, always as `Path` objects."""
    if isinstance(inputs, (str, os.PathLike)):
        return [Path(inputs)]
    return [Path(p) for p in inputs]


@dataclass
class Run:
    returncode: int
    stdout: str
    stderr: str


def run_moonlake(sql: str, inputs) -> Run:
    """Run one query over one or more inputs (`exec --csv a.csv --csv b.csv ...`)."""
    cmd = [*moonlake_command(), "exec"]
    for path in as_paths(inputs):
        flag = "--csv" if path.suffix == ".csv" else "--parquet"
        cmd += [flag, str(path)]
    cmd.append(sql)
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


def duckdb_rows(sql: str, inputs) -> list[list[str]]:
    """Run `sql` in DuckDB with one view per input file, named after the file stem.

    A gate passes one path or several; the window gate uses a fixture copied to
    `t.csv` (view `t`), the correlation gate its `o`/`i`/`n`/`one`/`e` files.
    An empty CSV cell is NULL, which is what both engines' inference does
    (`read_csv_auto`'s default nullstr is the empty string).
    """
    import duckdb

    con = duckdb.connect()
    try:
        for path in as_paths(inputs):
            con.execute(
                f"CREATE VIEW {path.stem} AS SELECT * FROM "
                f"read_csv_auto('{path.as_posix()}', header=true)"
            )
        rows = con.execute(sql).fetchall()
    finally:
        con.close()
    return [[NULL if v is None else str(v) for v in row] for row in rows]


def cell_key(cell: str) -> tuple:
    """Canonical multiset key: numbers as exact numbers, everything else exactly.

    `5` and `5.0` are the same key, because the two engines spell an
    integer-valued double differently (`5` here, `5.0` in DuckDB) and a
    multiset cannot use the ordered path's 1e-9 tolerance. Values whose last
    bits disagree therefore need an ordered case.

    Non-finite spellings agree here as they do in `compare.cell_eq` — MoonBit
    prints `NaN`/`Infinity`/`-Infinity`, Python and DuckDB `nan`/`inf`/`inf` —
    and so do dates, because both engines spell an epoch-day date `1992-01-04`,
    and booleans, because DuckDB prints `True`/`False` to MoonBit's
    `true`/`false`. The words carry the value, not the formatting.
    """
    low = cell.lower()
    if cell == NULL:
        return ("null",)
    if low in compare.NAN_WORDS:
        return ("num", "nan")
    if low in compare.INF_WORDS:
        return ("num", "-inf" if low.startswith("-") else "inf")
    if bool_value(cell) is not None:
        return ("bool", bool_value(cell))
    if compare.number_kind(cell) is not None:
        try:
            return ("num", Fraction(cell))
        except (ValueError, OverflowError, ZeroDivisionError):
            return ("str", cell)
    return ("str", cell)


def bool_value(cell: str) -> bool | None:
    """The value of a boolean spelling, or None when the cell is not one.

    DuckDB renders a boolean as `True`/`False` and MoonBit as `true`/`false`;
    both are the same SQL value, so the gates read the word rather than the
    case.
    """
    return {"true": True, "false": False}.get(cell.lower())


def cells_equal(got: str, want: str) -> bool:
    """One cell equal to another: booleans by value, the rest as `compare` does."""
    got_bool, want_bool = bool_value(got), bool_value(want)
    if got_bool is not None or want_bool is not None:
        return got_bool is not None and got_bool == want_bool
    return compare.cell_eq(got, want)


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
            if not cells_equal(g, w):
                return f"line {lineno} col {col}: moonlake {g!r} vs duckdb {w!r}"
    return None


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


def run_cases(cases: list[Case], inputs, runner=None, referee=None) -> Report:
    """Run one case list against one input set: ours answers, DuckDB referees.

    `inputs` is one path or several, handed unchanged to both sides (the
    window gate passes its `t.csv`, the correlation gate all five fixtures).
    """
    # Resolved here rather than as default arguments so a test or a one-off
    # wrapper can replace either side without re-binding the definition.
    runner = runner or run_moonlake
    referee = referee or duckdb_rows
    report = Report()
    for case in cases:
        if case.refusal is not None:
            got = runner(case.sql, inputs)
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
                referee(case.sql, inputs)
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

        want = referee(case.sql, inputs)  # referee errors propagate: never skip
        got = runner(case.sql, inputs)
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
