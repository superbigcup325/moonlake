"""The encoding gate must fail when the evidence stops being evidence.

Each test walks one way the old footer-only claim could rot: a file that is no
longer the one the digest pinned, a page encoding that is not the claimed one, a
missing fixture, a manifest with nothing in it, and an embedded fixture whose
bytes drifted from the values the script expects.
"""

import contextlib
import io
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch

import check_colenc_fixtures as gate
import parquet_pages


class PageParserTests(unittest.TestCase):
    def test_reads_the_actual_data_page_encoding(self):
        path = gate.ROOT / "harness/data/parquet/colenc/delta_int32/t.parquet"
        data_pages = [
            p
            for p in parquet_pages.column_pages(path)["c"]
            if p["type"] in ("DATA_PAGE", "DATA_PAGE_V2")
        ]
        self.assertEqual({p["encoding"] for p in data_pages}, {"DELTA_BINARY_PACKED"})
        self.assertEqual({p["version"] for p in data_pages}, {1})
        self.assertEqual(sum(p["num_values"] for p in data_pages), 9)

    def test_walks_past_a_dictionary_page(self):
        path = gate.ROOT / "harness/data/parquet/dict_types/dict/t.parquet"
        pages = parquet_pages.column_pages(path)
        kinds = {p["type"] for column in pages.values() for p in column}
        self.assertIn("DICTIONARY_PAGE", kinds)
        encodings = {
            p["encoding"]
            for column in pages.values()
            for p in column
            if p["type"] in ("DATA_PAGE", "DATA_PAGE_V2")
        }
        # DuckDB writes v1-style PLAIN_DICTIONARY indices; the key point is that
        # the walker crossed the dictionary page and still found the data pages.
        self.assertTrue(encodings & {"PLAIN_DICTIONARY", "RLE_DICTIONARY"}, encodings)

    def test_truncated_header_is_an_error_not_a_guess(self):
        with self.assertRaises(ValueError):
            parquet_pages.parse_pages(b"\x15", 0, 1)


class GateTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(gate.MANIFEST.read_text(encoding="utf-8"))

    def run_gate(self, manifest):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "manifest.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            out, err = io.StringIO(), io.StringIO()
            with (
                patch.object(gate, "MANIFEST", path),
                patch.object(gate, "EMBEDDED", {}),
                contextlib.redirect_stdout(out),
                contextlib.redirect_stderr(err),
            ):
                return gate.main(), out.getvalue(), err.getvalue()

    def test_committed_manifest_passes(self):
        code, out, _ = self.run_gate(self.manifest)
        self.assertEqual(code, 0, out)
        self.assertIn("regenerable", out)

    def test_digest_mismatch_fails(self):
        broken = json.loads(json.dumps(self.manifest))
        broken["cases"][0]["sha256"] = "0" * 64
        code, out, _ = self.run_gate(broken)
        self.assertEqual(code, 1)
        self.assertIn("sha256", out)

    def test_wrong_page_encoding_fails(self):
        broken = json.loads(json.dumps(self.manifest))
        case = next(c for c in broken["cases"] if c["name"] == "delta_byte_array")
        case["encoding"] = "PLAIN"
        code, out, _ = self.run_gate(broken)
        self.assertEqual(code, 1)
        self.assertIn("footer-only check would have missed this", out)

    def test_missing_fixture_fails(self):
        broken = json.loads(json.dumps(self.manifest))
        broken["cases"][0]["path"] = "harness/data/parquet/colenc/does-not-exist/t.parquet"
        code, out, _ = self.run_gate(broken)
        self.assertEqual(code, 1)
        self.assertIn("missing file", out)

    def test_empty_manifest_fails(self):
        code, out, _ = self.run_gate({"cases": []})
        self.assertEqual(code, 1)
        self.assertIn("manifest has no cases", out)

    def test_embedded_digest_drift_fails(self):
        expected = {"sha256": "0" * 64, "encoding": "DELTA_BINARY_PACKED", "values": [1]}
        with tempfile.TemporaryDirectory() as tmp:
            manifest = pathlib.Path(tmp) / "m.json"
            manifest.write_text(json.dumps({"cases": self.manifest["cases"]}), encoding="utf-8")
            out = io.StringIO()
            with (
                patch.object(gate, "MANIFEST", manifest),
                patch.object(gate, "EMBEDDED", {"DELTA_INT32": expected}),
                contextlib.redirect_stdout(out),
            ):
                code = gate.main()
        self.assertEqual(code, 1)
        self.assertIn("bytes changed", out.getvalue())


if __name__ == "__main__":
    unittest.main()
