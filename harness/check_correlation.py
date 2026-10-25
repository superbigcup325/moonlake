#!/usr/bin/env python3
"""Replay the correlated-subquery differential against DuckDB.

`docs/verification.md` §28 records the work that turned "a correlated subquery
whose correlation is not an equality is refused" into an answer, and its
evidence: a 39-query differential over four fixtures, agreeing on all 39. That
run happened from a script that was never committed, so the claim would have
rotted the first time `engine/correlate.mbt` changed — the same way §5.1's 29
window queries died of old age. This is the re-runnable replacement: committed
fixtures, a fixed case list, and failure modes chosen so nothing can quietly
stop being true.

Fixtures (`harness/data/correlation/`) and what each one is for:

* `o` — the outer side: a duplicated row (`id = 1` twice, so a repeated outer
  row must not multiply a correlated aggregate), NULL keys and NULL values, a
  date column, and `nan` / `inf` / `-inf` in a float column.
* `i` — the inner side: a repeated key, a NULL key, a NULL value.
* `n` — a NULL-rich inner side for `IN` / `NOT IN` three-valued logic.
* `one` — a single-column table, where a subquery cannot lean on `SELECT *`.
* `e` — a header-only file: an empty input, where a correlated aggregate has to
  return its empty-group value (0 / NULL) instead of dropping the outer row.
  The file has no rows, so both engines type its columns from the header alone
  and every case over it casts (`CAST(e.v AS INT)`); a bare `e.v > 5` is a type
  error in both engines, which would only measure the fixture's typing.

Answers compare as row multisets unless the query carries a total order: a
decorrelated query has no defined row order, so sorting both sides would let a
wrong row order pass as correct. Dates and non-finite floats are spelled
differently by the two engines (`1992-01-04` on both; `NaN` / `Infinity` /
`-Infinity` here, `nan` / `inf` in DuckDB) and compare by value through
`harness/differential.py`.

Exit codes: 0 every value case matched (refusals as expected), 1 a mismatch or a
gate failure (a wrong answer, a refusal without its message, zero value cases),
2 an environment problem (a missing or empty fixture, no DuckDB, a referee
error). There is no skip path: a case that cannot run is a failure.

Usage:
  moon build cmd/main --target native
  python3 harness/check_correlation.py
  python3 harness/check_correlation.py --random 400 --seed 20261025   # nightly
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

FIXTURES = ROOT / "harness" / "data" / "correlation"
# The CLI names a table after the file stem, and the cases say `o`, `i`, ...
TABLE_FILES = ("o.csv", "i.csv", "n.csv", "one.csv", "e.csv")

sys.path.insert(0, str(ROOT / "harness"))
from differential import Case, run_cases  # noqa: E402  (same-directory helper)

CASES: list[Case] = [
    # The equality shape that 0.5.0 shipped: the general rewrite must not
    # disturb it (hash-keyed semi/anti join, grouped LEFT join for the scalar).
    Case("eq_exists", "SELECT id FROM o WHERE EXISTS (SELECT 1 FROM i WHERE i.k = o.k)", mode="multiset"),
    Case("eq_not_exists", "SELECT id FROM o WHERE NOT EXISTS (SELECT 1 FROM i WHERE i.k = o.k)", mode="multiset"),
    Case(
        "eq_in",
        "SELECT id FROM o WHERE o.k IN (SELECT i.k FROM i)",
        mode="multiset",
        note="i.k holds a NULL, so IN and NOT IN are both three-valued here",
    ),
    Case("eq_not_in", "SELECT id FROM o WHERE o.k NOT IN (SELECT i.k FROM i)", mode="multiset"),
    Case("eq_scalar_max", "SELECT id, (SELECT max(v) FROM i WHERE i.k = o.k) AS m FROM o", mode="multiset"),
    Case(
        "eq_scalar_count_distinct",
        "SELECT id, (SELECT count(DISTINCT v) FROM i WHERE i.k = o.k) AS c FROM o",
        mode="multiset",
    ),
    # Keyless EXISTS: no equality pair, so every inner row sits under the one
    # empty hash key and the predicate is the join residual.
    Case("theta_exists_lt", "SELECT id FROM o WHERE EXISTS (SELECT 1 FROM i WHERE i.v < o.v)", mode="multiset"),
    Case("theta_exists_ne_keys", "SELECT id FROM o WHERE EXISTS (SELECT 1 FROM i WHERE i.k <> o.k)", mode="multiset"),
    Case(
        "theta_exists_between",
        "SELECT id FROM o WHERE EXISTS (SELECT 1 FROM i WHERE i.v BETWEEN o.v - 11 AND o.v + 11)",
        mode="multiset",
    ),
    Case(
        "theta_exists_or",
        "SELECT id FROM o WHERE EXISTS (SELECT 1 FROM i WHERE i.k = o.k OR i.v > o.v * 3)",
        mode="multiset",
    ),
    Case(
        "theta_exists_outer_only_conjunct",
        "SELECT id FROM o WHERE EXISTS (SELECT 1 FROM i WHERE i.v < o.v AND o.k > 1)",
        mode="multiset",
        note="o.k > 1 touches only the outer row: a parameter, not a refusal",
    ),
    Case("theta_not_exists_gt", "SELECT id FROM o WHERE NOT EXISTS (SELECT 1 FROM i WHERE i.v > o.v)", mode="multiset"),
    Case("theta_exists_null_values", "SELECT id FROM o WHERE EXISTS (SELECT 1 FROM n WHERE n.v > o.v)", mode="multiset"),
    Case(
        "theta_exists_join_inside",
        "SELECT id FROM o WHERE EXISTS (SELECT 1 FROM i JOIN n ON n.k = i.k WHERE n.v > o.v)",
        mode="multiset",
    ),
    Case(
        "group_by_inside_exists",
        "SELECT id FROM o WHERE EXISTS (SELECT 1 FROM i WHERE i.v > o.v GROUP BY i.txt)",
        mode="multiset",
        note="a GROUP BY without HAVING cannot change whether a matching row exists, so it is dropped",
    ),
    # Keyless IN / NOT IN, and sets that contain NULL.
    Case(
        "theta_in_keyless",
        "SELECT id FROM o WHERE o.v IN (SELECT i.v FROM i WHERE i.k < o.k)",
        mode="multiset",
    ),
    Case(
        "not_in_no_null_correlated",
        "SELECT id FROM o WHERE o.v NOT IN (SELECT a FROM one WHERE a < o.k)",
        mode="multiset",
        note="the inner column holds no NULL, so the anti join answers instead of the poison check",
    ),
    Case(
        "not_in_uncorrelated_null_set",
        "SELECT id FROM o WHERE o.v NOT IN (SELECT n.v FROM n)",
        mode="multiset",
        note="a NULL in an uncorrelated set: no outer row can pass, which is an answer",
    ),
    Case(
        "not_in_empty_set_null_probe",
        "SELECT id FROM o WHERE o.v NOT IN (SELECT i.v FROM i WHERE i.k > 30)",
        mode="multiset",
        note="an empty correlated set makes NOT IN true even for a NULL probe value",
    ),
    Case("in_set_with_null", "SELECT id, o.v IN (SELECT n.v FROM n) AS r FROM o", mode="multiset"),
    Case("not_in_set_with_null", "SELECT id, o.v NOT IN (SELECT n.v FROM n) AS r FROM o", mode="multiset"),
    # A scalar aggregate over a non-equality correlation: computed once over the
    # distinct outer combinations and left-joined back on the row key.
    Case("scalar_count_gt", "SELECT id, (SELECT count(*) FROM i WHERE i.v > o.v) AS c FROM o", mode="multiset"),
    Case("scalar_sum_lt", "SELECT id, (SELECT sum(i.v) FROM i WHERE i.v < o.v) AS s FROM o", mode="multiset"),
    Case("scalar_max_ne", "SELECT id, (SELECT max(i.v) FROM i WHERE i.v <> o.v) AS m FROM o", mode="multiset"),
    Case(
        "scalar_count_distinct_theta",
        "SELECT id, (SELECT count(DISTINCT i.v) FROM i WHERE i.v > o.v) AS c FROM o",
        mode="multiset",
    ),
    Case(
        "scalar_repeated_outer_row",
        "SELECT o.id, (SELECT count(*) FROM i WHERE i.v > o.v) AS c FROM o JOIN n ON n.k = o.k",
        mode="multiset",
        note="o holds id = 1 twice: a repeated outer row must not multiply the count",
    ),
    Case(
        "scalar_in_where",
        "SELECT id FROM o WHERE (SELECT max(v) FROM i WHERE i.v < o.v) > 4",
        mode="multiset",
    ),
    Case(
        "scalar_in_arithmetic",
        "SELECT id, (SELECT count(*) FROM i WHERE i.v > o.v) * 2 + o.id AS x FROM o",
        mode="multiset",
    ),
    Case(
        "scalar_in_case",
        "SELECT id, CASE WHEN (SELECT count(*) FROM i WHERE i.v > o.v) > 2 THEN 'many' ELSE 'few' END AS c FROM o",
        mode="multiset",
    ),
    # EXISTS and IN as values, and under NOT / OR / CASE.
    Case("exists_as_value", "SELECT id, EXISTS (SELECT 1 FROM i WHERE i.v > o.v) AS e FROM o", mode="multiset"),
    Case("not_exists_as_value", "SELECT id, NOT EXISTS (SELECT 1 FROM i WHERE i.v > o.v) AS e FROM o", mode="multiset"),
    Case("in_as_value", "SELECT id, o.v IN (SELECT i.v FROM i WHERE i.v > o.v) AS r FROM o", mode="multiset"),
    Case(
        "not_in_as_value",
        "SELECT id, o.v NOT IN (SELECT n.v FROM n WHERE n.v <> o.v) AS r FROM o",
        mode="multiset",
    ),
    Case(
        "exists_under_not_or",
        "SELECT id FROM o WHERE NOT (EXISTS (SELECT 1 FROM i WHERE i.v > o.v) OR o.k > 20)",
        mode="multiset",
    ),
    Case(
        "exists_in_case_where",
        "SELECT id FROM o WHERE CASE WHEN EXISTS (SELECT 1 FROM i WHERE i.v > o.v) THEN 1 ELSE 0 END = 1",
        mode="multiset",
    ),
    # Empty inputs: the empty group's value, not a dropped outer row.
    Case(
        "empty_exists",
        "SELECT id FROM o WHERE EXISTS (SELECT 1 FROM e WHERE CAST(e.v AS INT) < o.v)",
        mode="multiset",
    ),
    Case(
        "empty_not_exists",
        "SELECT id FROM o WHERE NOT EXISTS (SELECT 1 FROM e WHERE CAST(e.v AS INT) < o.v)",
        mode="multiset",
    ),
    Case(
        "empty_scalar_count",
        "SELECT id, (SELECT count(*) FROM e WHERE CAST(e.v AS INT) > o.v) AS c FROM o",
        mode="multiset",
    ),
    Case(
        "empty_scalar_max",
        "SELECT id, (SELECT max(CAST(e.v AS INT)) FROM e WHERE CAST(e.v AS INT) > o.v) AS m FROM o",
        mode="multiset",
    ),
    Case("empty_in", "SELECT id FROM o WHERE o.v IN (SELECT CAST(e.v AS INT) FROM e)", mode="multiset"),
    # NULL keys, a one-column table, and the two output spellings that differ
    # between the engines.
    Case(
        "null_key_scalar",
        "SELECT id, (SELECT count(*) FROM i WHERE i.k = o.k) AS c FROM o",
        mode="multiset",
        note="o.k and i.k both hold NULL: an equality matches nothing, not everything",
    ),
    Case(
        "one_column_table",
        "SELECT id, (SELECT max(a) FROM one WHERE one.a < o.v) AS m FROM o",
        mode="multiset",
    ),
    Case(
        "ordered_dates",
        "SELECT id, d FROM o ORDER BY id, d",
        mode="ordered",
        note="a total order over distinct rows, so equal rows may tie",
    ),
    Case("non_finite_values", "SELECT id, f FROM o", mode="multiset"),
    Case(
        "date_through_correlation",
        "SELECT id, d FROM o WHERE (SELECT count(*) FROM i WHERE i.v > o.v) > 1",
        mode="multiset",
    ),
    # Refusals: each names its limit and points at a join. Every one is valid SQL
    # that DuckDB runs, so a refusal here is our documented limit and not a
    # query the standard forbids.
    Case(
        "refuse_derived_table_in_from",
        "SELECT id FROM o WHERE EXISTS (SELECT 1 FROM (SELECT k FROM i) AS s WHERE s.k = o.k)",
        refusal="it must read plain tables",
        duckdb_accepts=True,
    ),
    Case(
        "refuse_distinct_in_subquery",
        "SELECT id FROM o WHERE EXISTS (SELECT DISTINCT k FROM i WHERE i.k = o.k)",
        refusal="it must read plain tables",
        duckdb_accepts=True,
    ),
    Case(
        "refuse_limit_in_subquery",
        "SELECT id FROM o WHERE EXISTS (SELECT 1 FROM i WHERE i.k = o.k LIMIT 5)",
        refusal="it must read plain tables",
        duckdb_accepts=True,
    ),
    Case(
        "refuse_offset_in_subquery",
        "SELECT id FROM o WHERE EXISTS (SELECT 1 FROM i WHERE i.k = o.k OFFSET 1)",
        refusal="it must read plain tables",
        duckdb_accepts=True,
    ),
    Case(
        "refuse_not_in_null_in_set",
        "SELECT id FROM o WHERE o.v NOT IN (SELECT i.v FROM i WHERE i.k < o.k)",
        refusal="cannot be decorrelated",
        duckdb_accepts=True,
        note=(
            "the inner column holds a NULL and the key residual narrows the set per outer row, "
            "so whether that NULL is in a given row's set is a per-row question the anti join "
            "cannot answer yet (E4c); DuckDB's answer here is 1,1,2,4,5 by empty-set semantics"
        ),
    ),
    Case(
        "refuse_set_operation_in_subquery",
        "SELECT id FROM o WHERE EXISTS (SELECT 1 FROM i WHERE i.k = o.k UNION ALL SELECT 1 FROM n)",
        refusal="found identifier",
        duckdb_accepts=True,
        note="the parser refuses a set operation inside a subquery before the decorrelator sees it",
    ),
    Case(
        "refuse_two_levels_out",
        "SELECT id FROM o WHERE EXISTS (SELECT 1 FROM i WHERE EXISTS (SELECT 1 FROM n WHERE n.k = o.k))",
        refusal="unknown table or alias",
        duckdb_accepts=True,
        note=(
            "a reference two levels out still reaches the binder's unknown-table error instead "
            "of the rewriter's explanation; the limit is real, the wording is a known rough edge"
        ),
    ),
    Case(
        "refuse_scalar_without_aggregate",
        "SELECT id, (SELECT i.v FROM i WHERE i.k = o.k AND i.v = 99) AS s FROM o",
        refusal="correlated scalar subquery must select an aggregate",
        duckdb_accepts=True,
        note="the predicate makes DuckDB's cardinality check pass, so only the shape is under test",
    ),
    Case(
        "refuse_select_position_under_group_by",
        "SELECT id, (SELECT max(i.v) FROM i WHERE i.k = o.id) AS m FROM o GROUP BY id",
        refusal="its value would have to appear in the GROUP BY",
        duckdb_accepts=True,
    ),
    Case(
        "refuse_having_position",
        "SELECT id, count(*) FROM o GROUP BY id HAVING EXISTS (SELECT 1 FROM i WHERE i.v > o.id)",
        refusal="in a HAVING clause cannot be decorrelated",
        duckdb_accepts=True,
    ),
    Case(
        "refuse_join_on_position",
        "SELECT o.id FROM o JOIN n ON EXISTS (SELECT 1 FROM i WHERE i.v > o.v)",
        refusal="in a JOIN ON clause cannot be decorrelated",
        duckdb_accepts=True,
    ),
]


def fixture_problems(root: Path) -> list[str]:
    """A missing or empty fixture is an environment problem, never a skip."""
    problems = []
    for name in TABLE_FILES:
        path = root / name
        if not path.is_file():
            problems.append(f"{path} is missing")
        elif not path.read_text(encoding="utf-8").strip():
            problems.append(f"{path} is empty")
    return problems


def random_fixtures(rows: int, seed: int, root: Path) -> list[Path]:
    """Nightly: the same five tables with different numbers, seeded so a failure replays.

    `one` and `e` stay as committed: a single column and an empty file are
    shapes, not data, and randomizing them would only test the generator.
    """
    import random

    rng = random.Random(seed)
    dates = ("1992-01-04", "1992-02-01", "1992-03-15", "")
    floats = ("1.5", "nan", "inf", "-inf", "2.25", "-0.5", "")
    keys = ("10", "20", "30")

    def maybe_null(text: str, chance: float) -> str:
        return "" if rng.random() < chance else text

    outer = ["id,k,v,d,f"]
    for _ in range(rows):
        outer.append(
            ",".join(
                (
                    str(rng.randint(1, max(2, rows // 4))),
                    maybe_null(rng.choice(keys), 0.2),
                    maybe_null(str(rng.randint(-5, 9)), 0.15),
                    rng.choice(dates),
                    rng.choice(floats),
                )
            )
        )
    inner = ["k,v,txt"]
    for _ in range(rows):
        inner.append(
            ",".join(
                (
                    maybe_null(rng.choice(keys), 0.2),
                    maybe_null(str(rng.randint(0, 9)), 0.15),
                    rng.choice(("a", "b", "c")),
                )
            )
        )
    nulls = ["k,v"]
    for _ in range(max(1, rows // 2)):
        nulls.append(",".join((rng.choice(("1", "2", "3", "10")), maybe_null(str(rng.randint(0, 9)), 0.5))))

    root.mkdir(parents=True, exist_ok=True)
    for name, text in (("o.csv", outer), ("i.csv", inner), ("n.csv", nulls)):
        (root / name).write_text("\n".join(text) + "\n", encoding="utf-8")
    for name in ("one.csv", "e.csv"):
        shutil.copyfile(FIXTURES / name, root / name)
    return [root / name for name in TABLE_FILES]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--random", type=int, default=0, help="use N pseudo-random rows per table (nightly)")
    ap.add_argument("--seed", type=int, default=20261025, help="seed for --random")
    ap.add_argument("--keep", action="store_true", help="keep the generated fixtures")
    args = ap.parse_args(argv)

    if not CASES:
        print("FAIL: no cases to run", file=sys.stderr)
        return 1
    try:
        import duckdb  # noqa: F401  (fail as an environment problem, not a skip)
    except ImportError as exc:
        print(f"FAIL: reference tools are missing ({exc}); install harness/requirements.txt", file=sys.stderr)
        return 2

    workdir = Path(tempfile.mkdtemp(prefix="moonlake-correlation-"))
    try:
        if args.random:
            paths = random_fixtures(args.random, args.seed, workdir)
        else:
            problems = fixture_problems(FIXTURES)
            if problems:
                for problem in problems:
                    print(f"FAIL: {problem}", file=sys.stderr)
                return 2
            paths = [FIXTURES / name for name in TABLE_FILES]
        try:
            report = run_cases(CASES, paths)
        except Exception as exc:  # noqa: BLE001 - any referee error fails the gate
            print(f"FAIL: referee error: {exc!r}", file=sys.stderr)
            return 2
    finally:
        if args.random and args.keep:
            print(f"fixtures kept at {workdir}")
        else:
            shutil.rmtree(workdir, ignore_errors=True)

    print(
        f"value cases: {report.value_cases()} matched "
        f"({len(report.matched)} ordered, {len(report.multiset_matched)} multiset); "
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
    print("correlation differential: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
