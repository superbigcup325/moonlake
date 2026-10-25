"""A failed referee or missing input must never make the corpus gate green."""

import contextlib
import io
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import duckdb

import check_parquet_corpus as corpus


class CorpusGateTests(unittest.TestCase):
    def test_reference_reads_a_real_parquet_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "t.parquet"
            con = duckdb.connect()
            try:
                con.execute(
                    f"COPY (SELECT * FROM range(3)) TO '{path}' (FORMAT PARQUET)"
                )
            finally:
                con.close()
            self.assertEqual(corpus.duckdb_count(path), 3)

    def test_invalid_parquet_is_a_duckdb_refusal(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "invalid.parquet"
            path.write_bytes(b"not a parquet file")
            self.assertTrue(corpus.duckdb_count(path).startswith("duckdb: "))

    def test_refusal_on_stdout_is_still_a_refusal(self):
        # wasm-gc has no stderr (eprintln falls back to stdout), so the default
        # `moon run` runner must not read every refusal as a failure
        result = corpus.refusal_or_failure(
            [], 'sql error (scan): parquet: column "c": the dictionary page holds no entries'
        )
        self.assertEqual(result["class"], "refused")
        self.assertIn("on stdout", result["why"])
        # a run with no message at all is still a failure
        self.assertEqual(corpus.refusal_or_failure([])["class"], "failing")

    def test_python_api_error_is_not_a_refusal(self):
        con = Mock()
        con.execute.side_effect = AttributeError("removed DuckDB API")
        with patch.object(duckdb, "connect", return_value=con):
            with self.assertRaisesRegex(AttributeError, "removed DuckDB API"):
                corpus.duckdb_count(pathlib.Path("t.parquet"))
        con.close.assert_called_once()

    def run_gate(self, files, reference=3, update=False):
        with (
            patch.object(corpus, "corpus_files", return_value=["t.parquet"]),
            patch.object(corpus, "fetch", return_value=files),
            patch.object(
                corpus, "load_expected", return_value={"t.parquet": {"class": "decoded"}}
            ),
            patch.object(corpus, "duckdb_count", return_value=reference),
            patch.object(
                corpus, "classify",
                return_value={"class": "decoded", "why": "sample matches"},
            ),
            patch.object(
                corpus.subprocess, "run",
                return_value=subprocess.CompletedProcess([], 0, stdout="moon test-toolchain"),
            ),
            patch.object(corpus, "write_expected") as write_expected,
            patch(
                "sys.argv", ["check_parquet_corpus.py", *(["--update"] if update else [])]
            ),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            code = corpus.main()
            write_expected.assert_not_called()
            return code

    def test_recorded_file_must_be_verified(self):
        self.assertEqual(self.run_gate({"t.parquet": pathlib.Path("t.parquet")}), 0)

    def test_skipping_every_recorded_file_fails(self):
        self.assertEqual(
            self.run_gate({"t.parquet": pathlib.Path("t.parquet")}, "duckdb: cannot read"),
            1,
        )

    def test_missing_download_fails(self):
        self.assertEqual(self.run_gate({}), 1)

    def test_empty_update_does_not_erase_the_record(self):
        self.assertEqual(self.run_gate({}, update=True), 1)


if __name__ == "__main__":
    unittest.main()
