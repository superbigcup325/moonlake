"""The comparison has to refuse what it cannot compare, and say why.

Every rule here exists because a past comparison got it wrong: deltas across
machines or builds (the 0.3.0 -> 0.3.1 "optimization" that was the machine), a
changed stdout hash read as a speedup, an unstable case averaged into a
conclusion, and a record from before a field existed silently skipped.

These tests feed `compare()` synthetic records, and `check_oracles()` a fake
referee/CLI, so no data, binary or timing run is involved — the correctness of
the comparator is what a per-PR check can afford.
"""

import contextlib
import io
import unittest
from unittest import mock

import bench_release as bench


def case(id_="scan/count_csv", **over):
    base = {
        "id": id_,
        "family": "scan",
        "wall_ms": 10.0,
        "median_ms": 10.5,
        "cpu_ms": 5.0,
        "rss_mb": 20.0,
        "wall_spread_pct": 5.0,
        "output_sha256": "hash-a",
        "output_stable": True,
        "sql": "SELECT 1",
    }
    base.update(over)
    return base


def record(cases=None, **over):
    base = {
        "release": {"version": "0.4.0-dev", "git_commit": "a" * 40},
        "created_at": "2026-10-23T00:00:00",
        "environment": {
            "cpu": "same-cpu",
            "cores": 16,
            "kernel": "same-kernel",
            "toolchain": {"moon": "0.1.20261016"},
        },
        "method": {
            "data_sha256": "data-a",
            "build": "native release",
            "runs": 7,
            "warmups": 2,
        },
        "cases": cases if cases is not None else [case()],
    }
    base.update(over)
    return base


class CompareTests(unittest.TestCase):
    def run_compare(self, old, new, allow=False):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = bench.compare(old, new, allow_env_mismatch=allow)
        return code, out.getvalue()

    def test_same_conditions_compare(self):
        code, out = self.run_compare(record(), record())
        self.assertEqual(code, 0)
        self.assertIn("inside the 5.0% run spread", out)

    def test_machine_mismatch_refuses_to_print_deltas(self):
        new = record()
        new["environment"]["cpu"] = "other-cpu"
        code, out = self.run_compare(record(), new)
        self.assertEqual(code, 2)
        self.assertIn("not taken under the same conditions", out)
        self.assertIn("cpu: old 'same-cpu' vs new 'other-cpu'", out)

    def test_data_mismatch_refuses_too(self):
        new = record()
        new["method"]["data_sha256"] = "data-b"
        code, out = self.run_compare(record(), new)
        self.assertEqual(code, 2)
        self.assertIn("data_sha256", out)

    def test_mismatch_can_be_overridden_explicitly(self):
        new = record()
        new["environment"]["cpu"] = "other-cpu"
        code, _ = self.run_compare(record(), new, allow=True)
        self.assertEqual(code, 0)  # deltas printed, nothing else wrong

    def test_output_change_is_not_an_optimization(self):
        code, out = self.run_compare(record(), record([case(output_sha256="hash-b")]))
        self.assertEqual(code, 1)
        self.assertIn("output changed", out)

    def test_unstable_output_fails(self):
        code, out = self.run_compare(record(), record([case(output_stable=False)]))
        self.assertEqual(code, 1)
        self.assertIn("output unstable", out)

    def test_missing_field_is_reported_not_assumed_equal(self):
        old = record()
        del old["method"]["runs"]
        code, out = self.run_compare(old, record())
        self.assertIn("not compared (one record predates it): runs", out)
        self.assertEqual(code, 0)

    def test_new_and_removed_cases_are_shown(self):
        old = record([case("scan/count_csv"), case("join/q3")])
        new = record([case("scan/count_csv"), case("gather/wide_projection")])
        code, out = self.run_compare(old, new)
        self.assertEqual(code, 0)
        self.assertIn("gather/wide_projection | - | 10.0 | new case", out)
        self.assertIn("join/q3 | 10.0 | - | removed from the record", out)

    def test_delta_inside_the_run_spread_is_labelled(self):
        new = record([case(wall_ms=10.2)])  # +2% inside the 5% spread
        code, out = self.run_compare(record(), new)
        self.assertEqual(code, 0)
        self.assertIn("inside the 5.0% run spread", out)

    def test_delta_outside_the_spread_is_counted(self):
        new = record([case(wall_ms=12.0, cpu_ms=6.0)])  # +20%
        code, out = self.run_compare(record(), new)
        self.assertEqual(code, 0)
        self.assertNotIn("inside the 5.0% run spread", out)
        self.assertIn("1 case(s) moved further than their own run-to-run spread", out)

    def test_no_spread_means_no_noise_verdict(self):
        old = record([case(wall_spread_pct=None)])
        new = record([case(wall_spread_pct=None)])
        code, out = self.run_compare(old, new)
        self.assertEqual(code, 0)
        self.assertIn("cannot be judged against noise", out)


class OracleTests(unittest.TestCase):
    def test_a_stable_wrong_answer_is_a_failure(self):
        spec = {"id": "scan/count_csv", "argv": ["--csv", "x.csv", "SELECT count(*) FROM x"]}
        with (
            mock.patch.object(bench, "duckdb_answer", return_value=[["3"]]),
            mock.patch.object(bench, "cli_answer", return_value=[["4"]]),
        ):
            cases = [{"id": "scan/count_csv"}]
            failures = bench.check_oracles(cases, [spec], bench.REPO / "bin", bench.REPO)
        self.assertEqual(len(failures), 1)
        self.assertIn("disagrees with duckdb", failures[0])
        self.assertFalse(cases[0]["oracle"]["matched"])

    def test_a_matching_answer_is_recorded_on_the_case(self):
        spec = {"id": "scan/count_csv", "argv": ["--csv", "x.csv", "SELECT count(*) FROM x"]}
        with (
            mock.patch.object(bench, "duckdb_answer", return_value=[["3"]]),
            mock.patch.object(bench, "cli_answer", return_value=[["3"]]),
        ):
            cases = [{"id": "scan/count_csv"}]
            failures = bench.check_oracles(cases, [spec], bench.REPO / "bin", bench.REPO)
        self.assertEqual(failures, [])
        self.assertTrue(cases[0]["oracle"]["matched"])
        self.assertEqual(cases[0]["oracle"]["referee"], "duckdb")

    def test_referee_error_is_not_a_skip(self):
        spec = {"id": "scan/count_csv", "argv": []}
        with mock.patch.object(
            bench, "duckdb_answer", side_effect=RuntimeError("duckdb API changed")
        ):
            with self.assertRaises(RuntimeError):
                bench.check_oracles([{"id": "scan/count_csv"}], [spec], bench.REPO / "bin", bench.REPO)


if __name__ == "__main__":
    unittest.main()
