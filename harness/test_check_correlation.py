"""The correlation differential gate must fail on the things that used to hide rot.

§28's 39-query differential was never committed, so its "all 39 agree" claim
would have rotted the first time `engine/correlate.mbt` changed. These tests pin
the replacement's failure paths: a wrong value, a reordered row the multiset mode
must tolerate, a refusal whose message went missing, a referee error that must
not become a skip, and an invocation with nothing to run. The seeded fixtures
get their own tests, because a generator that stops being reproducible stops
being evidence. `harness/test_check_windows.py` is the same idea for the sibling
gate.
"""

import builtins
import contextlib
import io
import pathlib
import tempfile
import unittest
from unittest.mock import patch

import check_correlation as correlation
import differential


def run(returncode, stdout="", stderr=""):
    return differential.Run(returncode, stdout, stderr)


class CompareTests(unittest.TestCase):
    def test_ordered_rows_match_and_a_wrong_value_fails(self):
        case = differential.Case("c", "SELECT 1")
        path = pathlib.Path("unused.csv")
        ok = differential.run_cases([case], path, lambda _, __: run(0, "h\n1\n"), lambda _, __: [["1"]])
        self.assertEqual(ok.matched, ["c"])
        self.assertEqual(ok.failures, [])
        bad = differential.run_cases([case], path, lambda _, __: run(0, "h\n2\n"), lambda _, __: [["1"]])
        self.assertEqual(bad.matched, [])
        self.assertTrue(any("moonlake '2' vs duckdb '1'" in f for f in bad.failures), bad.failures)

    def test_multiset_ignores_row_order_but_not_duplicate_counts(self):
        case = differential.Case("c", "SELECT 1", mode="multiset")
        path = pathlib.Path("unused.csv")
        same = differential.run_cases(
            [case], path,
            lambda _, __: run(0, "h\n1\n1\n2\n"),
            lambda _, __: [["1"], ["2"], ["1"]],
        )
        self.assertEqual(same.multiset_matched, ["c"], same.failures)
        different = differential.run_cases(
            [case], path,
            lambda _, __: run(0, "h\n1\n1\n2\n"),
            lambda _, __: [["1"], ["1"], ["1"]],
        )
        self.assertEqual(different.multiset_matched, [])
        self.assertTrue(different.failures)

    def test_boolean_spellings_agree_in_both_modes(self):
        # DuckDB prints True/False, MoonBit true/false: the same SQL value.
        self.assertEqual(differential.cell_key("true"), differential.cell_key("True"))
        self.assertTrue(differential.cells_equal("true", "True"))
        self.assertTrue(differential.cells_equal("FALSE", "false"))
        self.assertFalse(differential.cells_equal("true", "false"))
        self.assertFalse(differential.cells_equal("true", "1"))
        self.assertFalse(differential.cells_equal("true", "null"))
        case = differential.Case("c", "SELECT 1", mode="multiset")
        report = differential.run_cases(
            [case], pathlib.Path("x.csv"),
            lambda _, __: run(0, "h\ntrue\n"),
            lambda _, __: [["True"]],
        )
        self.assertEqual(report.multiset_matched, ["c"], report.failures)

    def test_engine_failure_on_a_value_case_is_a_failure(self):
        case = differential.Case("c", "SELECT 1")
        report = differential.run_cases(
            [case], pathlib.Path("x.csv"),
            lambda _, __: run(1, "", "sql error (bind): boom"),
            lambda _, __: [["1"]],
        )
        self.assertTrue(any("sql error (bind): boom" in f for f in report.failures))

    def test_refusal_needs_its_message(self):
        case = differential.Case("c", "SELECT 1", refusal="cannot be decorrelated", duckdb_accepts=True)
        report = differential.run_cases(
            [case], pathlib.Path("x.csv"),
            lambda _, __: run(1, "", "sql error (bind): something else"),
            lambda _, __: [["1"]],
        )
        self.assertTrue(any("without the expected message" in f for f in report.failures))

    def test_valid_sql_refusal_must_be_accepted_by_the_referee(self):
        case = differential.Case("c", "SELECT 1", refusal="cannot be decorrelated", duckdb_accepts=True)

        def referee(_, __):
            raise RuntimeError("DuckDB rejected it")

        report = differential.run_cases([case], pathlib.Path("x.csv"), lambda _, __: run(1, "", "cannot be decorrelated"), referee)
        self.assertTrue(any("valid SQL" in f for f in report.failures))

    def test_documented_refusal_is_counted_apart_from_matches(self):
        case = differential.Case("c", "SELECT 1", refusal="cannot be decorrelated", duckdb_accepts=True)
        report = differential.run_cases(
            [case], pathlib.Path("x.csv"),
            lambda _, __: run(1, "", "sql error (bind): cannot be decorrelated because"),
            lambda _, __: [["1"]],
        )
        self.assertEqual(report.refused, ["c"])
        self.assertEqual(report.value_cases(), 0)
        self.assertEqual(report.failures, [])


class FixtureTests(unittest.TestCase):
    def test_committed_fixtures_are_present_and_non_empty(self):
        self.assertEqual(correlation.fixture_problems(correlation.FIXTURES), [])

    def test_the_seeded_fixtures_replay_and_stay_distinct(self):
        with tempfile.TemporaryDirectory() as one, tempfile.TemporaryDirectory() as two, tempfile.TemporaryDirectory() as three:
            first = correlation.random_fixtures(40, 7, pathlib.Path(one))
            again = correlation.random_fixtures(40, 7, pathlib.Path(two))
            other = correlation.random_fixtures(40, 8, pathlib.Path(three))
            self.assertEqual([p.name for p in first], list(correlation.TABLE_FILES))
            for a, b in zip(first, again):
                self.assertEqual(a.read_text(encoding="utf-8"), b.read_text(encoding="utf-8"), a.name)
            self.assertTrue(
                any(a.read_text(encoding="utf-8") != b.read_text(encoding="utf-8") for a, b in zip(first, other)),
                "a different seed must generate different data",
            )
            # the single-column and empty shapes are copied, not generated
            for name in ("one.csv", "e.csv"):
                self.assertEqual(
                    (pathlib.Path(one) / name).read_text(encoding="utf-8"),
                    (correlation.FIXTURES / name).read_text(encoding="utf-8"),
                )


class MainTests(unittest.TestCase):
    def test_no_cases_fails(self):
        with (
            patch.object(correlation, "CASES", []),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(correlation.main([]), 1)

    def test_missing_fixture_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            with (
                patch.object(correlation, "FIXTURES", pathlib.Path(tmp)),
                contextlib.redirect_stderr(io.StringIO()),
            ):
                self.assertEqual(correlation.main([]), 2)

    def test_empty_fixture_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in correlation.TABLE_FILES:
                (pathlib.Path(tmp) / name).write_text("", encoding="utf-8")
            with (
                patch.object(correlation, "FIXTURES", pathlib.Path(tmp)),
                contextlib.redirect_stderr(io.StringIO()),
            ):
                self.assertEqual(correlation.main([]), 2)

    def test_missing_reference_tool_is_an_environment_failure(self):
        real_import = builtins.__import__

        def fake_import(name, *args, **kwargs):
            if name == "duckdb":
                raise ImportError("no duckdb")
            return real_import(name, *args, **kwargs)

        with patch("builtins.__import__", side_effect=fake_import), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(correlation.main([]), 2)

    def test_referee_error_is_an_environment_failure(self):
        case = differential.Case("c", "SELECT 1")
        with (
            patch.object(correlation, "CASES", [case]),
            patch.object(correlation, "run_cases", side_effect=AttributeError("removed DuckDB API")),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(correlation.main([]), 2)

    def test_a_run_with_only_refusals_fails(self):
        # Refusals are evidence, not proof that the correlation math is right.
        case = differential.Case("c", "SELECT 1", refusal="cannot be decorrelated", duckdb_accepts=True)
        report = differential.Report(refused=["c"])
        with (
            patch.object(correlation, "CASES", [case]),
            patch.object(correlation, "run_cases", return_value=report),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(correlation.main([]), 1)


if __name__ == "__main__":
    unittest.main()
