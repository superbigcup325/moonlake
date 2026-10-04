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
  check_in "$DATA" "$@"
}

check_in() { # <golden-dir> <name> <csv...>
  local dir=$1 name=$2
  shift 2
  echo "== $name"
  moon run cmd/main -- exec "$@" "$(cat "harness/queries/$name.sql")" \
    > "$work/$name.txt"
  python3 harness/compare.py "$dir/${name}_golden.txt" "$work/$name.txt"
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
# multi-row-group parquet fixture (scale-independent, not part of $DATA):
# the SF0.01 parquet export is a single row group, so the reader's
# multi-group path gets its own file with known per-group bounds
check_in harness/data/multigroup mgfull --parquet harness/data/multigroup/multigroup.parquet --date-col d
check_in harness/data/multigroup mgfilter --parquet harness/data/multigroup/multigroup.parquet --date-col d
check_in harness/data/multigroup mgagg --parquet harness/data/multigroup/multigroup.parquet --date-col d
check_in harness/data/multigroup mgwin --parquet harness/data/multigroup/multigroup.parquet --date-col d
# external-sort equivalence: the same non-aggregate ORDER BY under a
# tiny memory budget must match the in-memory run row-for-row
echo "== spillorder (external sort == in-memory)"
moon run cmd/main -- exec --csv "$DATA/lineitem.csv" "$(cat harness/queries/spillorder.sql)" \
  > "$work/spillorder_plain.txt"
moon run cmd/main -- exec --csv "$DATA/lineitem.csv" --memory 200K \
  "$(cat harness/queries/spillorder.sql)" > "$work/spillorder_spilled.txt"
python3 harness/compare.py "$work/spillorder_plain.txt" "$work/spillorder_spilled.txt"
echo "all 27 golden queries pass (22 TPC-H + the parquet variant + 3 multi-row-group parquet) + the external-sort equivalence check"
