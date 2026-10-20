#!/usr/bin/env python3
# Self-test for compare.py: the diff tool is the judge of every golden in
# this directory, so its own false-green and false-red edges are pinned down
# here. Plain python3, no pytest (the tpch CI job has no test runner).
#
# Usage: python3 harness/check_compare.py [path/to/compare.py]
# The optional argument points the cases at a different comparator (useful
# to check that a case actually has teeth against an older version).

import pathlib
import subprocess
import sys
import tempfile

COMPARE = pathlib.Path(
    sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).with_name("compare.py")
)

# label, golden text, moonlake text, expected exit code, expected stdout substring
CASES = [
    ("identical table", "a|b\n1|x\n", "a|b\n1|x\n", 0, "PASS"),
    ("header names ignored", "n\n5\n", "other\n5\n", 0, "PASS"),
    ("NULL equals NULL", "v\nnull\n", "v\nnull\n", 0, "PASS"),
    # a NULL cell must not pass as an empty string (a real value)
    ("NULL is not the empty string", "v\nnull\n", "v\n\n", 1, "line 2 col 0"),
    ("empty string is not NULL", "v\n\n", "v\nnull\n", 1, "line 2 col 0"),
    ("empty string equals empty string", "v\n\n", "v\n\n", 0, "PASS"),
    # whitespace in a cell is data, not layout
    ("trailing space is data", "s\na \n", "s\na\n", 1, "line 2 col 0"),
    ("leading space is data", "s\n a\n", "s\na\n", 1, "line 2 col 0"),
    ("trailing space on last cell", "a|b\n1|x \n", "a|b\n1|x\n", 1, "col 1"),
    # integer literals must match exactly, whatever their width
    ("leading zero is a difference", "v\n001\n", "v\n1\n", 1, "line 2 col 0"),
    ("same integer passes", "v\n1\n", "v\n1\n", 0, "PASS"),
    (
        "64-bit ids keep their digits",
        "v\n9007199254740993\n",
        "v\n9007199254740992\n",
        1,
        "line 2 col 0",
    ),
    # floats (a decimal point or an exponent) keep the relative tolerance
    (
        "float formatting tolerance",
        "v\n588352.24\n",
        "v\n588352.2400000002\n",
        0,
        "PASS",
    ),
    ("float mismatch is caught", "v\n1.0\n", "v\n1.000001\n", 1, "line 2 col 0"),
    ("int and float of one value agree", "v\n3\n", "v\n3.0\n", 0, "PASS"),
    # non-finite values compare as values, not through a tolerance
    ("NaN equals NaN in any case", "v\nnan\n", "v\nNaN\n", 0, "PASS"),
    ("infinity equals infinity", "v\ninf\n", "v\nInfinity\n", 0, "PASS"),
    ("signed infinity equals itself", "v\n-inf\n", "v\n-infinity\n", 0, "PASS"),
    ("opposite infinities differ", "v\ninf\n", "v\n-inf\n", 1, "line 2 col 0"),
    ("NaN is not a number", "v\nnan\n", "v\n1\n", 1, "line 2 col 0"),
    (
        "overflowing literal is not infinity",
        "v\n1e999\n",
        "v\ninf\n",
        1,
        "line 2 col 0",
    ),
    (
        "non-ASCII digits are not numbers",
        "v\n\u0661\u0662\u0663\n",
        "v\n123\n",
        1,
        "line 2 col 0",
    ),
    # blank lines are rows; only the last row's terminator is dropped
    ("trailing blank row is a row", "v\na\n\n", "v\na\n", 1, "row count"),
    ("blank rows in the middle survive", "v\na\n\nb\n", "v\na\n\nb\n", 0, "PASS"),
    ("terminating newline is not a row", "v\na\n", "v\na\n", 0, "PASS"),
    ("column count mismatch", "a|b\n1|2\n", "a|b\n1\n", 1, "cols"),
    # documented limitation of a bare '|' format: a value spelled "null" is
    # indistinguishable from SQL NULL; this case records the decision
    ("string 'null' is the NULL marker", "v\nnull\n", "v\nnull\n", 0, "PASS"),
]


def run(golden: str, out: str):
    with tempfile.TemporaryDirectory() as tmp:
        g = pathlib.Path(tmp, "golden.txt")
        o = pathlib.Path(tmp, "out.txt")
        g.write_text(golden)
        o.write_text(out)
        proc = subprocess.run(
            [sys.executable, str(COMPARE), str(g), str(o)],
            capture_output=True,
            text=True,
        )
    return proc.returncode, proc.stdout.strip()


def main() -> int:
    failures = 0
    for label, golden, out, want_code, want_text in CASES:
        code, text = run(golden, out)
        if code == want_code and want_text in text:
            print(f"ok   {label}")
        else:
            failures += 1
            print(
                f"FAIL {label}: exit {code} (want {want_code}), "
                f"stdout {text!r} (want {want_text!r})"
            )
    if failures:
        print(f"{failures}/{len(CASES)} compare.py self-test cases failed")
        return 1
    print(f"{len(CASES)} compare.py self-test cases pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
