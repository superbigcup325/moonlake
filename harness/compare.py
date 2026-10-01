# Diff moonlake's table output against the duckdb golden file.
#
# Usage: python3 harness/compare.py <golden.txt> <moonlake-output.txt>
# Both files are '|'-separated with a header line. Header names are not
# compared (engines label columns differently); cells are compared in
# order: floats with a 1e-9 relative tolerance, everything else exact.
# Empty and "null" cells both count as SQL NULL.

import pathlib
import sys

REL_TOL = 1e-9

NULLS = ("", "null")


def rows_of(path: str) -> list[list[str]]:
    lines = [
        line.strip()
        for line in pathlib.Path(path).read_text().splitlines()
        if line.strip()
    ]
    if not lines:
        raise SystemExit(f"{path}: no rows (header expected)")
    return [line.split("|") for line in lines[1:]]  # drop the header


def cell_eq(a: str, b: str) -> bool:
    if a in NULLS and b in NULLS:
        return True
    try:
        fa, fb = float(a), float(b)
    except ValueError:
        return a == b
    denom = max(abs(fb), 1e-300)
    return abs(fa - fb) / denom <= REL_TOL


def main() -> int:
    want_rows = rows_of(sys.argv[1])
    got_rows = rows_of(sys.argv[2])
    if len(got_rows) != len(want_rows):
        print(f"FAIL: row count moonlake {len(got_rows)} vs duckdb {len(want_rows)}")
        return 1
    for lineno, (got, want) in enumerate(zip(got_rows, want_rows), start=2):
        if len(got) != len(want):
            print(f"FAIL: line {lineno}: {len(got)} cols vs {len(want)} cols")
            return 1
        for col, (g, w) in enumerate(zip(got, want)):
            if not cell_eq(g, w):
                print(f"FAIL: line {lineno} col {col}: moonlake {g!r} vs duckdb {w!r}")
                return 1
    print(f"PASS: {len(got_rows)} rows match duckdb golden")
    return 0


if __name__ == "__main__":
    sys.exit(main())
