# Diff moonlake's Q6 output against the duckdb golden value.
#
# Usage: python3 harness/compare.py <golden.txt> <moonlake-output.txt>
# The moonlake output is the CLI stdout: header line, then one value line.

import pathlib
import sys

REL_TOL = 1e-9


def main() -> int:
    golden = float(pathlib.Path(sys.argv[1]).read_text().strip())
    lines = [
        line.strip()
        for line in pathlib.Path(sys.argv[2]).read_text().splitlines()
        if line.strip()
    ]
    # the CLI prints a header row, then one value row (| separated)
    value_line = lines[1]
    got = float(value_line.split("|")[0])
    diff = abs(got - golden)
    denom = max(abs(golden), 1e-300)
    if diff / denom <= REL_TOL:
        print(f"PASS: moonlake {got!r} vs duckdb {golden!r}")
        return 0
    print(f"FAIL: moonlake {got!r} vs duckdb {golden!r}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
