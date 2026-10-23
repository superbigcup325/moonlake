"""The window differential gate must fail on the things that used to hide rot.

The 2026-10-04 battery could not be re-run, so its 29/29 claim died of old age.
These tests pin the replacement's failure paths: a wrong value, a reordered row
that the multiset mode must tolerate, a refusal that nobody explained, a
referee error that must not become a skip, and an invocation with nothing to
run. `harness/test_parquet_corpus.py` is the same idea for the corpus gate.
"""

import builtins
import contextlib
import io
import pathlib
import tempfile
import unittest
from unittest.mock import patch

import check_windows as windows


def run(returncode, stdout="", stderr=""):
    return windows.Run(returncode, stdout, stderr)


class CompareTests(unittest.TestCase):
    def test_ordered_rows_match_and_a_wrong_value_fails(self):
        case = windows.Case("c", "SELECT 1")
        path = pathlib.Path("unused.csv")
        ok = windows.run_cases([case], path, lambda _, __: run(0, "h\n1\n"), lambda _, __: [["1"]])
        self.assertEqual(ok.matched, ["c"])
        self.assertEqual(ok.failures, [])
        bad = windows.run_cases([case], path, lambda _, __: run(0, "h\n2\n"), lambda _, __: [["1"]])
        self.assertEqual(bad.matched, [])
        self.assertTrue(any("moonlake '2' vs duckdb '1'" in f for f in bad.failures), bad.failures)

    def test_multiset_ignores_row_order_but_not_duplicate_counts(self):
        case = windows.Case("c", "SELECT 1", mode="multiset")
        path = pathlib.Path("unused.csv")
        same = windows.run_cases(
            [case], path,
            lambda _, __: run(0, "h\n1\n1\n2\n"),
            lambda _, __: [["1"], ["2"], ["1"]],
        )
        self.assertEqual(same.multiset_matched, ["c"], same.failures)
        different = windows.run_cases(
            [case], path,
            lambda _, __: run(0, "h\n1\n2\n2\n"),
            lambda _, __: [["1"], ["1"], ["2"]],
        )
        self.assertEqual(different.multiset_matched, [])
        self.assertTrue(different.failures)

    def test_float_spellings_and_null_agree_in_a_multiset(self):
        keys = [windows.cell_key("5"), windows.cell_key("5.0"), windows.cell_key("null")]
        self.assertEqual(keys[0], keys[1])
        self.assertEqual(keys[2], ("null",))
        self.assertNotEqual(keys[0], keys[2])

    def test_engine_failure_on_a_value_case_is_a_failure(self):
        case = windows.Case("c", "SELECT 1")
        report = windows.run_cases(
            [case], pathlib.Path("x.csv"),
            lambda _, __: run(1, "", "sql error (bind): boom"),
            lambda _, __: [["1"]],
        )
        self.assertTrue(any("sql error (bind): boom" in f for f in report.failures))

    def test_referee_error_is_not_a_skip(self):
        case = windows.Case("c", "SELECT 1")

        def referee(_, __):
            raise AttributeError("removed DuckDB API")

        with self.assertRaises(AttributeError):
            windows.run_cases([case], pathlib.Path("x.csv"), lambda _, __: run(0, "h\n1\n"), referee)

    def test_refusal_needs_its_message(self):
        case = windows.Case("c", "SELECT 1", refusal="frame clauses", duckdb_accepts=True)
        report = windows.run_cases(
            [case], pathlib.Path("x.csv"),
            lambda _, __: run(1, "", "sql error (bind): something else"),
            lambda _, __: [["1"]],
        )
        self.assertTrue(any("without the expected message" in f for f in report.failures))

    def test_valid_sql_refusal_must_be_accepted_by_the_referee(self):
        case = windows.Case("c", "SELECT 1", refusal="frame clauses", duckdb_accepts=True)

        def referee(_, __):
            raise RuntimeError("DuckDB rejected it")

        report = windows.run_cases([case], pathlib.Path("x.csv"), lambda _, __: run(1, "", "frame clauses"), referee)
        self.assertTrue(any("valid SQL" in f for f in report.failures))

    def test_standard_refusal_must_also_be_refused_by_the_referee(self):
        case = windows.Case("c", "SELECT 1", refusal="nested window")
        report = windows.run_cases(
            [case], pathlib.Path("x.csv"),
            lambda _, __: run(1, "", "nested window functions are not allowed"),
            lambda _, __: [["1"]],
        )
        self.assertTrue(any("DuckDB accepted" in f for f in report.failures))

    def test_documented_refusal_is_counted_apart_from_matches(self):
        case = windows.Case("c", "SELECT 1", refusal="frame clauses", duckdb_accepts=True)
        report = windows.run_cases(
            [case], pathlib.Path("x.csv"),
            lambda _, __: run(1, "", "frame clauses are not supported"),
            lambda _, __: [["1"]],
        )
        self.assertEqual(report.refused, ["c"])
        self.assertEqual(report.value_cases(), 0)
        self.assertEqual(report.failures, [])


class MainTests(unittest.TestCase):
    def test_no_cases_fails(self):
        with (
            patch.object(windows, "CASES", []),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(windows.main([]), 1)

    def test_missing_fixture_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = pathlib.Path(tmp) / "absent.csv"
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(windows.main(["--fixture", str(missing)]), 2)

    def test_empty_fixture_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            empty = pathlib.Path(tmp) / "t.csv"
            empty.write_text("", encoding="utf-8")
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(windows.main(["--fixture", str(empty)]), 2)

    def test_missing_reference_tool_is_an_environment_failure(self):
        real_import = builtins.__import__

        def fake_import(name, *args, **kwargs):
            if name == "duckdb":
                raise ImportError("no duckdb")
            return real_import(name, *args, **kwargs)

        with patch("builtins.__import__", side_effect=fake_import), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(windows.main([]), 2)

    def test_a_run_with_only_refusals_fails(self):
        # Refusals are evidence, not proof that the window math is right.
        case = windows.Case("c", "SELECT 1", refusal="frame clauses", duckdb_accepts=True)
        report = windows.Report(refused=["c"])
        with (
            patch.object(windows, "CASES", [case]),
            patch.object(windows, "run_cases", return_value=report),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(windows.main([]), 1)


if __name__ == "__main__":
    unittest.main()
