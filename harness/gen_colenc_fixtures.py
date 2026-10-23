#!/usr/bin/env python3
"""Rebuild the small Parquet encoding fixtures and their manifest.

`sources/parquet/colenc_integration_test.mbt` embeds tiny PyArrow-written files
as hex so the decoder can be tested on every target without a file system. The
commit that added them did not record how to make them, so nobody could rebuild
the evidence or add a sibling case.

This script is that missing generator for the *regenerable* set: one Parquet
file per supported encoding, written by PyArrow with the same settings the
embedded fixtures use (format 2.6, data page v1, statistics off), covering the
combinations the reader claims: DELTA_BINARY_PACKED for int32/int64,
DELTA_LENGTH_BYTE_ARRAY and DELTA_BYTE_ARRAY for strings, BYTE_STREAM_SPLIT for
float/double, each with NULLs and edge values, plus SNAPPY, multi-row-group and
multi-page variants. `harness/colenc_fixtures.json` records the tool versions,
the exact write parameters, each file's SHA-256, the pages as observed in the
file (not the footer's encoding list), and the expected values.

`harness/check_colenc_fixtures.py` verifies the committed output; it never
regenerates. Regenerate only with the pinned tool versions in
`harness/requirements.txt` — a different PyArrow version may produce different
bytes, and then the digests must be refreshed in the same commit.

Usage:
  uv run --python 3.12 --with-requirements harness/requirements.txt \
    python harness/gen_colenc_fixtures.py
"""

from __future__ import annotations

import hashlib
import json
import pathlib
import sys
from datetime import date
from decimal import Decimal

import pyarrow as pa
import pyarrow.parquet as pq

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import parquet_pages  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = ROOT / "harness" / "data" / "parquet" / "colenc"
MANIFEST = ROOT / "harness" / "colenc_fixtures.json"

BASE_WRITE = {
    "version": "2.6",
    "data_page_version": "1.0",
    "use_dictionary": False,
    "write_statistics": False,
}

# (case name, arrow type, values, encoding, extra write kwargs)
CASES: list[tuple[str, pa.DataType, list, str, dict]] = [
    (
        "delta_int32",
        pa.int32(),
        [1, 2, 3, 9, -3, 2, 2147483647, -2147483648, None],
        "DELTA_BINARY_PACKED",
        {"compression": "NONE"},
    ),
    (
        "delta_int64",
        pa.int64(),
        [7, 10, 13, 14, 20, 4611686018427387904, -4611686018427387904, None],
        "DELTA_BINARY_PACKED",
        {"compression": "NONE"},
    ),
    (
        "delta_length",
        pa.string(),
        ["aa", "bbb", "", "cc", "shared-1", None],
        "DELTA_LENGTH_BYTE_ARRAY",
        {"compression": "NONE"},
    ),
    (
        "delta_byte_array",
        pa.string(),
        ["shared-1", "shared-2", "other", "shared-3", "", None],
        "DELTA_BYTE_ARRAY",
        {"compression": "NONE"},
    ),
    (
        "bss_float",
        pa.float32(),
        [1.5, -2.25, 0.0, -0.0, 3.5, None],
        "BYTE_STREAM_SPLIT",
        {"compression": "NONE"},
    ),
    (
        "bss_double",
        pa.float64(),
        [1.5, -2.25, 0.0, 3.5, -1e300, None],
        "BYTE_STREAM_SPLIT",
        {"compression": "NONE"},
    ),
    (
        "delta_int32_snappy",
        pa.int32(),
        [1, 2, 3, 9, -3, 2, None],
        "DELTA_BINARY_PACKED",
        {"compression": "SNAPPY"},
    ),
    (
        "delta_int32_multigroup",
        pa.int32(),
        [(i * 7) % 1000 for i in range(4096)],
        "DELTA_BINARY_PACKED",
        {"compression": "NONE", "row_group_size": 1024},
    ),
    (
        "delta_int64_multipage",
        pa.int64(),
        [i * 13 for i in range(5000)],
        "DELTA_BINARY_PACKED",
        {"compression": "NONE", "data_page_size": 64},
    ),
]


def fmt(value) -> str:
    """The text both the CLI and the checks use for a cell."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, Decimal):
        return fmt(float(value))
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, float):
        return repr(value)
    return str(value)


# Structural minimums a case is supposed to demonstrate; a case that silently
# collapses back into one page/group is not evidence for that path.
MIN_DATA_PAGES = {"delta_int64_multipage": 2}
EXACT_ROW_GROUPS = {"delta_int32_multigroup": 4}


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    if pa.__version__ != "26.0.0":
        print(
            f"warning: this generator was pinned to pyarrow 26.0.0, found {pa.__version__}; "
            "the archive bytes may differ",
            file=sys.stderr,
        )
    DATA.mkdir(parents=True, exist_ok=True)
    cases = []
    for name, arrow_type, values, encoding, extra in CASES:
        case_dir = DATA / name
        case_dir.mkdir(parents=True, exist_ok=True)
        path = case_dir / "t.parquet"
        write = {**BASE_WRITE, **extra, "column_encoding": {"c": encoding}}
        table = pa.table({"c": pa.array(values, type=arrow_type)})
        pq.write_table(table, path, **write)

        meta = pq.ParquetFile(path).metadata
        pages = parquet_pages.column_pages(path)
        if "c" not in pages:
            print(f"FAIL: {name}: no page for column c", file=sys.stderr)
            return 1
        data_pages = [p for p in pages["c"] if p["type"] in ("DATA_PAGE", "DATA_PAGE_V2")]
        observed = {p["encoding"] for p in data_pages}
        if observed != {encoding}:
            print(f"FAIL: {name}: pages carry {sorted(observed)}, expected {encoding}", file=sys.stderr)
            return 1
        if {p["version"] for p in data_pages} != {1}:
            print(f"FAIL: {name}: pages are not v1", file=sys.stderr)
            return 1
        if len(data_pages) < MIN_DATA_PAGES.get(name, 1):
            print(
                f"FAIL: {name}: {len(data_pages)} data page(s), expected at least "
                f"{MIN_DATA_PAGES[name]}",
                file=sys.stderr,
            )
            return 1
        want_groups = EXACT_ROW_GROUPS.get(name)
        if want_groups is not None and meta.num_row_groups != want_groups:
            print(
                f"FAIL: {name}: {meta.num_row_groups} row group(s), expected {want_groups}",
                file=sys.stderr,
            )
            return 1

        cases.append(
            {
                "name": name,
                "path": str(path.relative_to(ROOT)),
                "type": str(arrow_type),
                "encoding": encoding,
                "compression": write.get("compression", "NONE"),
                "write": {
                    **BASE_WRITE,
                    **extra,
                    "column_encoding": {"c": encoding},
                },
                "created_by": meta.created_by,
                "sha256": sha256(path),
                "rows": table.num_rows,
                "row_groups": meta.num_row_groups,
                "pages": [
                    {
                        "type": p["type"],
                        "version": p.get("version"),
                        "encoding": p.get("encoding"),
                        "num_values": p.get("num_values"),
                    }
                    for p in pages["c"]
                ],
                "values_text": [fmt(v) for v in table.column(0).to_pylist()],
            }
        )
        print(
            f"{name}: {table.num_rows} rows, {meta.num_row_groups} row group(s), "
            f"{len(data_pages)} data page(s), {encoding}, {path.stat().st_size} bytes"
        )

    manifest = {
        "generator": {
            "script": "harness/gen_colenc_fixtures.py",
            "pyarrow": pa.__version__,
            "created_by": cases[0]["created_by"] if cases else None,
            "note": "regenerate only with harness/requirements.txt versions",
        },
        "cases": cases,
    }
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {MANIFEST.relative_to(ROOT)} ({len(cases)} cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
