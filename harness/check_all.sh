#!/usr/bin/env bash
# Run every golden query through the moonlake CLI and diff each against
# the duckdb golden file. Exits non-zero on the first mismatch.
#
# Usage: bash harness/check_all.sh   (data must exist: see README)
set -euo pipefail
cd "$(dirname "$0")/.."

DATA=harness/data/sf001
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

check() { # <name> <csv...>
  local name=$1
  shift
  echo "== $name"
  moon run cmd/main -- exec "$@" "$(cat "harness/queries/$name.sql")" \
    > "$work/$name.txt"
  python3 harness/compare.py "$DATA/${name}_golden.txt" "$work/$name.txt"
}

check q6 --csv "$DATA/lineitem.csv"
check q1 --csv "$DATA/lineitem.csv"
check q3 --csv "$DATA/customer.csv" --csv "$DATA/orders.csv" --csv "$DATA/lineitem.csv"
check q14 --csv "$DATA/lineitem.csv" --csv "$DATA/part.csv"
echo "all golden queries pass"
