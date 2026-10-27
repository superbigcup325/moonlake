"""The join/aggregate benchmark's answer check has to be able to fail.

`bench_join_agg.py` calls a run correct when it matches an exact count
recomputed from the fixtures' key and value functions. That oracle is the only
thing between a retained-intermediate finding and a reported number, so these
tests feed it the right answer and the ways an answer goes wrong — a lost group,
an extra group, a wrong count, a duplicated key, a truncated join — and check
that the fixture writer produces the rows the oracle assumes. No binary, data
set or timing run is involved.

"""

import pathlib
import shutil
import tempfile
import unittest

import bench_join_agg as bja


def grouped_answer(rows, groups, fanout):
    counts, sums = bja.reference(rows, groups)
    lines = ["k|n|total"]
    for g in range(min(groups, rows)):
        lines.append(f"{g}|{counts[g] * fanout}|{sums[g] * fanout}")
    return "\n".join(lines) + "\n"


class AnswerCheck(unittest.TestCase):
    def test_accepts_the_exact_answer(self):
        for case in ("agg-only", "join-agg", "join-left-agg"):
            fanout = 1 if case == "agg-only" else 3
            text = grouped_answer(40, 5, fanout)
            self.assertEqual(bja.check_answer(case, text, 40, 5, fanout), "")

    def test_rejects_a_wrong_count(self):
        lines = grouped_answer(40, 5, 2).split("\n")
        cells = lines[1].split("|")
        cells[1] = str(int(cells[1]) + 1)
        lines[1] = "|".join(cells)
        reason = bja.check_answer("join-agg", "\n".join(lines), 40, 5, 2)
        self.assertIn("wrong", reason)

    def test_rejects_a_lost_group(self):
        lines = grouped_answer(40, 5, 2).split("\n")
        del lines[2]
        reason = bja.check_answer("join-agg", "\n".join(lines), 40, 5, 2)
        self.assertIn("missing", reason)

    def test_rejects_an_extra_group(self):
        text = grouped_answer(40, 5, 2) + "9|4|8\n"
        reason = bja.check_answer("join-agg", text, 40, 5, 2)
        self.assertIn("extra", reason)

    def test_rejects_a_duplicated_key(self):
        lines = grouped_answer(40, 5, 2).split("\n")
        lines.append(lines[1])
        reason = bja.check_answer("join-agg", "\n".join(lines), 40, 5, 2)
        self.assertIn("duplicate", reason)

    def test_rejects_a_wrong_answer_header(self):
        text = grouped_answer(40, 5, 2).replace("k|n|total", "k|count|total", 1)
        self.assertIn("header", bja.check_answer("join-agg", text, 40, 5, 2))

    def test_rejects_an_empty_answer(self):
        self.assertIn("empty", bja.check_answer("join-agg", "", 40, 5, 2))

    def test_rejects_a_truncated_join(self):
        rows = "".join(f"{i % 5}|{i}\n" for i in range(40 * 2 - 1))
        reason = bja.check_answer("join-only", "k|v\n" + rows, 40, 5, 2)
        self.assertIn("expected 80", reason)

    def test_rejects_a_wrong_scan_count(self):
        self.assertEqual(bja.check_answer("scan-only", "n\n40\n", 40, 5, 1), "")
        self.assertIn("counted 39", bja.check_answer("scan-only", "n\n39\n", 40, 5, 1))

    def test_reference_matches_a_brute_force_count(self):
        counts, sums = bja.reference(97, 7)
        for g in range(7):
            idx = [i for i in range(97) if i % 7 == g]
            self.assertEqual(counts[g], len(idx))
            self.assertEqual(sums[g], sum((13 * i) % 1000 for i in idx))


class RowCount(unittest.TestCase):
    def test_body_row_count(self):
        self.assertEqual(bja.body_row_count("k|v\n0|1\n1|2\n"), 2)
        self.assertEqual(bja.body_row_count("k|v\n"), 0)
        self.assertEqual(bja.body_row_count(""), 0)


class Fixtures(unittest.TestCase):
    def setUp(self):
        self.work = pathlib.Path(tempfile.mkdtemp(prefix="join-agg-test-"))
        self.addCleanup(shutil.rmtree, self.work)

    def test_writes_the_rows_the_oracle_assumes(self):
        probe, build = bja.make_fixtures(self.work, 10, 3, 2)
        probe_rows = probe.read_text().rstrip("\n").split("\n")
        build_rows = build.read_text().rstrip("\n").split("\n")
        self.assertEqual(probe_rows[0], "id,k,v")
        self.assertEqual(len(probe_rows) - 1, 10)
        self.assertEqual(probe_rows[1], "0,0,0")
        self.assertEqual(probe_rows[2], "1,1,13")
        self.assertEqual(build_rows[0], "k,w")
        self.assertEqual(len(build_rows) - 1, 3 * 2)

    def test_keeps_an_existing_fixture(self):
        probe, _build = bja.make_fixtures(self.work, 5, 2, 1)
        before = probe.read_text()
        again, _build = bja.make_fixtures(self.work, 5, 2, 1)
        self.assertEqual(before, again.read_text())


class Counters(unittest.TestCase):
    def test_reads_only_advertised_counters(self):
        text = "-- sql\nscan probe: 40\njoins: 80\naggregate: 5\nnonsense: 3\nexplain me\n"
        self.assertEqual(bja.counters(text),
                         {"scan probe": 40, "joins": 80, "aggregate": 5})


if __name__ == "__main__":
    unittest.main()
