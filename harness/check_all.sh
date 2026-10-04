#!/usr/bin/env bash
# Run every golden query through the moonlake CLI and diff each against
# the duckdb golden file. Exits non-zero on the first mismatch.
#
# All queries are the official TPC-H texts (annex parameter values;
# q15 in its sanctioned WITH form — see harness/queries/q15.sql).
#
# Usage: bash harness/check_all.sh   (data must exist: see README)
set -euo pipefail
cd "$(dirname "$0")/.."

DATA=${MOONLAKE_DATA:-harness/data/sf001}
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
check q6p --parquet "$DATA/lineitem.parquet" --date-col l_shipdate --date-col l_commitdate --date-col l_receiptdate
check q5 --csv "$DATA/customer.csv" --csv "$DATA/orders.csv" --csv "$DATA/lineitem.csv" --csv "$DATA/supplier.csv" --csv "$DATA/nation.csv" --csv "$DATA/region.csv"
check q10 --csv "$DATA/customer.csv" --csv "$DATA/orders.csv" --csv "$DATA/lineitem.csv" --csv "$DATA/nation.csv"
check q12 --csv "$DATA/orders.csv" --csv "$DATA/lineitem.csv"
check q7 --csv "$DATA/supplier.csv" --csv "$DATA/lineitem.csv" --csv "$DATA/orders.csv" --csv "$DATA/customer.csv" --csv "$DATA/nation.csv"
check q8 --csv "$DATA/part.csv" --csv "$DATA/supplier.csv" --csv "$DATA/lineitem.csv" --csv "$DATA/orders.csv" --csv "$DATA/customer.csv" --csv "$DATA/nation.csv" --csv "$DATA/region.csv"
check q13 --csv "$DATA/customer.csv" --csv "$DATA/orders.csv"
check q19 --csv "$DATA/lineitem.csv" --csv "$DATA/part.csv"
check q16 --csv "$DATA/partsupp.csv" --csv "$DATA/part.csv" --csv "$DATA/supplier.csv"
check q11 --csv "$DATA/partsupp.csv" --csv "$DATA/supplier.csv" --csv "$DATA/nation.csv"
check q15 --csv "$DATA/supplier.csv" --csv "$DATA/lineitem.csv"
check q2 --csv "$DATA/part.csv" --csv "$DATA/supplier.csv" --csv "$DATA/partsupp.csv" --csv "$DATA/nation.csv" --csv "$DATA/region.csv"
check q4 --csv "$DATA/orders.csv" --csv "$DATA/lineitem.csv"
check q9 --csv "$DATA/part.csv" --csv "$DATA/supplier.csv" --csv "$DATA/lineitem.csv" --csv "$DATA/partsupp.csv" --csv "$DATA/orders.csv" --csv "$DATA/nation.csv"
check q17 --csv "$DATA/lineitem.csv" --csv "$DATA/part.csv"
check q18 --csv "$DATA/customer.csv" --csv "$DATA/orders.csv" --csv "$DATA/lineitem.csv"
check q20 --csv "$DATA/supplier.csv" --csv "$DATA/nation.csv" --csv "$DATA/partsupp.csv" --csv "$DATA/part.csv" --csv "$DATA/lineitem.csv"
check q21 --csv "$DATA/supplier.csv" --csv "$DATA/lineitem.csv" --csv "$DATA/orders.csv" --csv "$DATA/nation.csv"
check q22 --csv "$DATA/customer.csv" --csv "$DATA/orders.csv"
echo "all 23 golden queries pass (22 TPC-H queries + the parquet variant)"
