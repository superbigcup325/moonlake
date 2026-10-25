# The dictionary survey is a measurement tool, so what it must get right is the
# parts that could silently produce a wrong table: the fixture has to be the same
# bytes from the same seed, the file stems have to be table names the engine can
# resolve, and the answer comparison has to accept a double sum that differs in
# the last bits while still rejecting a different count.

from __future__ import annotations

import pathlib
import unittest

import dict_survey as ds


class FixtureTest(unittest.TestCase):
    def test_same_seed_is_the_same_table(self) -> None:
        a = ds.build_table(200, 7)
        b = ds.build_table(200, 7)
        self.assertEqual(a.column_names, b.column_names)
        for name in ds.NAMES:
            self.assertEqual(a.column(name).to_pylist(), b.column(name).to_pylist())

    def test_a_different_seed_is_a_different_table(self) -> None:
        a = ds.build_table(200, 7)
        b = ds.build_table(200, 8)
        self.assertNotEqual(a.column("uid").to_pylist(), b.column("uid").to_pylist())

    def test_the_columns_are_the_roles_the_report_claims(self) -> None:
        table = ds.build_table(400, 11)
        self.assertEqual(table.column_names, ds.NAMES)
        # The two nullable columns really carry NULLs, or the definition-level
        # half of the survey would be measuring nothing.
        for name in ("device", "note"):
            values = table.column(name).to_pylist()
            self.assertIn(None, values)
            self.assertGreater(len(set(values)), 1)
        # A monotonic clock and a low-cardinality string, i.e. the two ends.
        self.assertEqual(len(set(table.column("ts").to_pylist())), 400)
        self.assertLess(len(set(table.column("country").to_pylist())), 41)


class NamingTest(unittest.TestCase):
    def test_a_stem_the_engine_can_resolve(self) -> None:
        workdir = pathlib.Path("/tmp/x")
        self.assertEqual(ds.file_for(workdir, "plain+snappy").name, "t_plain_snappy.parquet")
        self.assertEqual(ds.file_for(workdir, "dict-all").name, "t_dict_all.parquet")
        path = ds.file_for(workdir, "dict-chosen")
        self.assertEqual(ds.our_sql(path), ds.CHECK_SQL.replace("from t", "from t_dict_chosen"))


class AnswerTest(unittest.TestCase):
    # count, three sums: the shape `duck_answer` returns.
    def test_identical_answers_agree(self) -> None:
        self.assertTrue(ds.same_answer((10, 1, 2.5, 3), (10, 1, 2.5, 3)))

    def test_a_float_sum_may_differ_in_the_last_bits(self) -> None:
        self.assertTrue(ds.same_answer((10, 1, 22536024.10099997, 3), (10, 1, 22536024.10100001, 3)))

    def test_a_different_count_does_not(self) -> None:
        self.assertFalse(ds.same_answer((10, 1, 2.5, 3), (11, 1, 2.5, 3)))

    def test_a_different_sum_does_not(self) -> None:
        self.assertFalse(ds.same_answer((10, 1, 2.5, 3), (10, 2, 2.5, 3)))
        self.assertFalse(ds.same_answer((10, 1, 2.5, 3), (10, 1, 2.6, 3)))

    def test_a_null_is_not_a_value(self) -> None:
        self.assertFalse(ds.same_answer((10, 1, None, 3), (10, 1, 0.0, 3)))


if __name__ == "__main__":
    unittest.main()
