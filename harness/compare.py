# Diff moonlake's table output against the duckdb golden file.
#
# Usage: python3 harness/compare.py <golden.txt> <moonlake-output.txt>
# Both files are '|'-separated with a header line and one newline-terminated
# line per row (the CLI prints every row with println, the generators write
# "\n".join(...) + "\n"), so a cell may contain any text but '|' and newline.
# Header names are not compared (engines label columns differently).
#
# Cells compare in order:
#   - identical text is equal, so NULL == NULL and "" == "";
#   - SQL NULL is exactly the cell 'null' (both engines print that marker)
#     and equals nothing else -- in particular not the empty string;
#   - integer literals compare exactly: "001" != "1" and 64-bit ids keep
#     their digits instead of round-tripping through a double;
#   - when a side is a floating-point literal, numbers compare within a
#     1e-9 relative tolerance (engines format doubles differently); NaN
#     equals NaN and infinities equal themselves, upper or lower case;
#   - everything else compares exactly, whitespace included.
#
# Blank lines are rows, not padding: a single-column "" value is a blank
# line. Only the line terminator of the last row is dropped.

import math
import pathlib
import re
import sys

REL_TOL = 1e-9

# The text Scalar::to_string and both golden generators use for SQL NULL. A
# string value spelled exactly "null" is therefore indistinguishable from
# NULL; nothing in the corpus is, and a '|' separated format has no other
# free marker (see harness/check_compare.py, which pins this down).
NULL = "null"

INT_RE = re.compile(r"[+-]?[0-9]+")
FLOAT_RE = re.compile(r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?")

# float() also accepts "1_000" and padded text, and Python and the engines
# disagree on the spelling of non-finite values, so name those explicitly
# instead of letting the numeric parse decide.
NAN_WORDS = frozenset(("nan", "+nan", "-nan"))
INF_WORDS = frozenset(("inf", "+inf", "infinity", "+infinity", "-inf", "-infinity"))


def rows_of(path: str) -> list[list[str]]:
    # Text mode (universal newlines) plus a split on '\n' only: str.splitlines
    # would also split on \v, \f, \u2028 ... inside a cell.
    lines = pathlib.Path(path).read_text(encoding="utf-8").split("\n")
    # Every line is terminated, so the final element is that terminator --
    # exactly one, never "all trailing blank lines" (those are real rows).
    if lines and lines[-1] == "":
        lines.pop()
    if not lines:
        raise SystemExit(f"{path}: no rows (header expected)")
    return [line.split("|") for line in lines[1:]]  # drop the header


def number_kind(cell: str):
    if INT_RE.fullmatch(cell):
        return "int"
    if FLOAT_RE.fullmatch(cell):
        return "float"
    return None


def cell_eq(a: str, b: str) -> bool:
    if a == b:
        return True
    if a == NULL or b == NULL:
        return False
    low_a, low_b = a.lower(), b.lower()
    if low_a in NAN_WORDS or low_b in NAN_WORDS:
        return low_a in NAN_WORDS and low_b in NAN_WORDS
    if low_a in INF_WORDS or low_b in INF_WORDS:
        return (
            low_a in INF_WORDS
            and low_b in INF_WORDS
            and low_a.startswith("-") == low_b.startswith("-")
        )
    kind_a, kind_b = number_kind(a), number_kind(b)
    if kind_a is None or kind_b is None:
        return False
    if kind_a == kind_b == "int":
        return False  # equal text was already ruled out above
    fa, fb = float(a), float(b)
    if not (math.isfinite(fa) and math.isfinite(fb)):
        return False  # out-of-range literal such as 1e999: only its text counts
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
