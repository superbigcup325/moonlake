#!/usr/bin/env python3
"""Verify the Parquet encoding evidence, at the page, not the footer.

Three kinds of evidence are kept apart on purpose:

1. **Embedded fixtures** (`sources/parquet/colenc_integration_test.mbt`, hex
   constants) — they run on wasm-gc and js without a file system, and this
   script checks them independently: an embedded fixture's SHA-256, the page
   type/version/encoding read from its bytes, and the values PyArrow decodes —
   not the values the MoonBit test asserts.
2. **Regenerable set** (`harness/data/parquet/colenc/`, built by
   `harness/gen_colenc_fixtures.py`) — the committed files, their digests, the
   settings that produced them, and a per-column value comparison against both
   PyArrow and the moonlake CLI.
3. **Upstream corpus** (`harness/check_parquet_corpus.py`) — somebody else's
   files; it is the only source that can prove interoperability, and the only
   one whose bytes we do not control.

The audit's lesson is enforced here: `parquet_metadata()` lists the footer's
encoding claims, and a file whose data pages are v2 or a different encoding
would still look supported. So every case asserts the *observed* page
encoding/version, and a case that stops demonstrating its encoding fails.

Usage:
  moon build cmd/main --target native
  MOONLAKE_BIN=_build/native/debug/build/cmd/main/main.exe \
    uv run --python 3.12 --with-requirements harness/requirements.txt \
    python harness/check_colenc_fixtures.py

Exit codes: 0 all evidence verified, 1 a case failed, 2 missing tool/manifest.
No skip path: a missing file, digest mismatch or unreadable fixture fails.
"""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "harness"))
import compare  # noqa: E402
import parquet_pages  # noqa: E402

MANIFEST = ROOT / "harness" / "colenc_fixtures.json"
MOONBIT_TEST = ROOT / "sources" / "parquet" / "colenc_integration_test.mbt"

# What the embedded bytes must be, checked without trusting the .mbt assertions:
# (column type, exact values, expected data-page encoding). Digests pin the bytes
# so an edit to the constants is visible in review.
EMBEDDED = {
    "DELTA_INT32": {
        "sha256": "66170fca2e02c7ba8375d3687bbb43961eec2d7820c426b7fcefe5b5eff609f0",
        "encoding": "DELTA_BINARY_PACKED",
        "values": [1, 5, 4, 9, -3, 8, 8, 2],
    },
    "DELTA_INT64": {
        "sha256": "18d4b67bf1c77fb1827cd271641298cab6fb853160032f1ebc389fb06886c209",
        "encoding": "DELTA_BINARY_PACKED",
        "values": [7, 10, 13, 14, 20],
    },
    "DELTA_LENGTH": {
        "sha256": "05bba0aeaeb5950b47c5f5e8b121f8b0fa987bcef75059a4c2ac3f9b37a906fd",
        "encoding": "DELTA_LENGTH_BYTE_ARRAY",
        "values": ["aa", "bbb", "", "cc"],
    },
    "DELTA_BYTE_ARRAY": {
        "sha256": "7e9c29b775d0a41e70408d98e754539e3dbe0a511b45b3b079734f1505c08648",
        "encoding": "DELTA_BYTE_ARRAY",
        "values": ["shared-1", "shared-2", "other", "shared-3"],
    },
    "BSS_FLOAT": {
        "sha256": "4ccb86b64fc70e9c6e67b81bba43e574e998f3785f831a1c24f5c69aee5bc033",
        "encoding": "BYTE_STREAM_SPLIT",
        "values": [1.5, -2.25, 0.0, 3.5],
    },
    "BSS_DOUBLE": {
        "sha256": "6610b50eced2eb96cfba93cc03ca5a0025d7fa4824256127672b08ace41a63ec",
        "encoding": "BYTE_STREAM_SPLIT",
        "values": [1.5, -2.25, 0.0, 3.5],
    },
    "RLE_BOOL": {
        "sha256": "98f3b6a8c95f9b1bdbac8109f33a5a9dedbb40a9a89882f65eb929c99331c780",
        "encoding": "RLE",
        "values": [True, True, False, False, True, True, True, False, True],
    },
    "DICT_INT32": {
        "sha256": "617a87ab0d1f894f16202832a0ecff627edd72782f72ae82e1d3fce71910f2fa",
        "encoding": "RLE_DICTIONARY",
        "values": [5, 7, 5, 9, 7],
    },
}


def fmt(value) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        return repr(value)
    return str(value)


def moonlake_command() -> list[str]:
    env_bin = os.environ.get("MOONLAKE_BIN")
    if env_bin:
        return [env_bin]
    built = ROOT / "_build/native/debug/build/cmd/main/main.exe"
    if built.exists():
        return [str(built)]
    return ["moon", "run", "cmd/main", "--"]


def cli_column(path: pathlib.Path, sql: str = "SELECT c FROM t") -> tuple[list[str], str]:
    """Run the CLI on one file and return the single output column's cells."""
    proc = subprocess.run(
        [*moonlake_command(), "exec", "--parquet", str(path), sql],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"exit {proc.returncode}")
    lines = proc.stdout.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines:
        raise RuntimeError("no header line")
    cells = []
    for line in lines[1:]:
        parts = line.split("|")
        if len(parts) != 1:
            raise RuntimeError(f"expected one column, got {len(parts)}: {line!r}")
        cells.append(parts[0])
    return cells, proc.stdout


def embedded_fixtures() -> dict[str, bytes]:
    text = MOONBIT_TEST.read_text(encoding="utf-8")
    found = dict(re.findall(r'const (\w+) : String = "([0-9a-f]+)"', text))
    return {name: bytes.fromhex(hexstr) for name, hexstr in found.items()}


def check_embedded(failures: list[str], checked: list[str]) -> None:
    fixtures = embedded_fixtures()
    if not fixtures:
        failures.append("no embedded fixtures found in colenc_integration_test.mbt")
        return
    import pyarrow as pa
    import pyarrow.parquet as pq

    for name, expected in EMBEDDED.items():
        data = fixtures.get(name)
        if data is None:
            failures.append(f"embedded {name}: constant is gone from the MoonBit test")
            continue
        digest = hashlib.sha256(data).hexdigest()
        if digest != expected["sha256"]:
            failures.append(
                f"embedded {name}: bytes changed (sha256 {digest[:12]}… vs {expected['sha256'][:12]}…); "
                "update EMBEDDED with the decoded values and re-review the fixture"
            )
            continue
        tmp = ROOT / "_build" / "colenc-embedded" / f"{name}.parquet"
        tmp.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_bytes(data)
        data_pages = [
            p
            for pages in parquet_pages.column_pages(tmp).values()
            for p in pages
            if p["type"] in ("DATA_PAGE", "DATA_PAGE_V2")
        ]
        if not data_pages:
            failures.append(f"embedded {name}: no data page")
            continue
        encodings = {p["encoding"] for p in data_pages}
        versions = {p["version"] for p in data_pages}
        if encodings != {expected["encoding"]}:
            failures.append(f"embedded {name}: pages carry {sorted(encodings)}, expected {expected['encoding']}")
            continue
        if versions != {1}:
            failures.append(f"embedded {name}: data page version {sorted(versions)}, expected v1")
            continue
        values = pq.read_table(pa.BufferReader(data)).column(0).to_pylist()
        if [fmt(v) for v in values] != [fmt(v) for v in expected["values"]]:
            failures.append(f"embedded {name}: pyarrow values {values} != expected {expected['values']}")
            continue
        checked.append(f"embedded/{name} ({expected['encoding']}, {len(values)} values)")


def check_manifest(failures: list[str], checked: list[str]) -> None:
    if not MANIFEST.is_file():
        raise SystemExit(f"missing {MANIFEST.relative_to(ROOT)}; run harness/gen_colenc_fixtures.py")
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    cases = manifest.get("cases") or []
    if not cases:
        failures.append("manifest has no cases")
        return
    import pyarrow as pa
    import pyarrow.parquet as pq

    for case in cases:
        name = case["name"]
        path = ROOT / case["path"]
        if not path.is_file():
            failures.append(f"{name}: missing file {case['path']}")
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != case["sha256"]:
            failures.append(f"{name}: sha256 {digest[:12]}… != manifest {case['sha256'][:12]}…")
            continue
        meta = pq.ParquetFile(path).metadata
        if meta.num_row_groups != case["row_groups"]:
            failures.append(f"{name}: {meta.num_row_groups} row groups, manifest says {case['row_groups']}")
            continue
        data_pages = [
            p
            for pages in parquet_pages.column_pages(path).values()
            for p in pages
            if p["type"] in ("DATA_PAGE", "DATA_PAGE_V2")
        ]
        encodings = {p["encoding"] for p in data_pages}
        versions = {p["version"] for p in data_pages}
        if encodings != {case["encoding"]}:
            failures.append(
                f"{name}: pages carry {sorted(encodings)}, expected {case['encoding']} "
                "(a footer-only check would have missed this)"
            )
            continue
        if versions != {1}:
            failures.append(f"{name}: data page version {sorted(versions)}, expected v1")
            continue
        expected = [fmt(v) for v in case["values_text"]]
        values = [fmt(v) for v in pq.read_table(path).column(0).to_pylist()]
        if values != expected:
            failures.append(f"{name}: pyarrow values differ from the manifest")
            continue
        try:
            cells, _ = cli_column(path)
        except Exception as exc:  # noqa: BLE001 - any CLI problem fails this case
            failures.append(f"{name}: moonlake could not read it: {exc}")
            continue
        if len(cells) != len(expected):
            failures.append(f"{name}: moonlake returned {len(cells)} rows, expected {len(expected)}")
            continue
        bad = [
            (i, got, want)
            for i, (got, want) in enumerate(zip(cells, expected))
            if not compare.cell_eq(got, want)
        ]
        if bad:
            i, got, want = bad[0]
            failures.append(f"{name}: row {i} moonlake {got!r} vs expected {want!r}")
            continue
        checked.append(f"{name} ({case['encoding']}, {len(cells)} values, {meta.num_row_groups} rg)")


def main() -> int:
    checked: list[str] = []
    failures: list[str] = []
    try:
        import pyarrow  # noqa: F401
    except ImportError as exc:
        print(f"FAIL: reference tools missing ({exc}); install harness/requirements.txt", file=sys.stderr)
        return 2

    check_embedded(failures, checked)
    check_manifest(failures, checked)

    channel = os.environ.get("MOONLAKE_BIN") or (
        "_build/native/debug/build/cmd/main/main.exe"
        if (ROOT / "_build/native/debug/build/cmd/main/main.exe").exists()
        else "moon run cmd/main --"
    )
    print(f"CLI: {channel}")
    for line in checked:
        print(f"  ok  {line}")
    for failure in failures:
        print(f"FAIL  {failure}")
    if not checked:
        print("FAIL: no fixture was actually verified", file=sys.stderr)
        return 1
    if failures:
        return 1
    embedded = sum(1 for c in checked if c.startswith("embedded/"))
    print(
        f"parquet encoding evidence: {embedded} embedded + {len(checked) - embedded} regenerable "
        "cases verified at page level"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
