#!/usr/bin/env bash
# Spill lifecycle acceptance: a query that spills must not leave temp
# files behind, on success or on failure, and ANALYZE must show what it
# spilled. Also checks that --spill-dir is only ever cleaned of the run
# files moonlake writes, never of a caller's own files, and that two
# processes can share one --spill-dir without deleting each other's runs.
#
# Usage: bash harness/spill_accept.sh
set -euo pipefail
cd "$(dirname "$0")/.."

bin=_build/native/debug/build/cmd/main/main.exe
moon build cmd/main --target native >/dev/null
moon build cmd/main --target native --release >/dev/null
rel=_build/native/release/build/cmd/main/main.exe

DATA=${MOONLAKE_DATA:-harness/data/sf001}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# Two small tables: t1 has a single hot join key, so grace hashing runs
# out of partitions and has to refuse; t2 is the probe side.
python3 - "$work" <<'PY'
import sys
d = sys.argv[1]
with open(f"{d}/hot.csv", "w") as f:
    f.write("id,k,pad\n")
    for i in range(5000):
        f.write(f"{i},1,{'x' * 60}\n")
with open(f"{d}/small.csv", "w") as f:
    f.write("id,k\n")
    for i in range(10):
        f.write(f"{i},1\n")
PY

# 1. A spilled ORDER BY purges its directory on success.
dir=$work/a
$bin exec --csv "$DATA/lineitem.csv" --memory 200K --spill-dir "$dir" \
  "SELECT l_orderkey, l_quantity FROM lineitem ORDER BY l_quantity LIMIT 3" >/dev/null \
  || fail "spilled sort exited non-zero"
[ -e "$dir" ] && fail "spill dir survived a successful sort: $(ls -A "$dir" | wc -l) files"
pass "a spilled sort leaves no directory behind"

# 2. A failed query purges its directory too.
dir=$work/b
if $bin exec --csv "$work/hot.csv" --csv "$work/small.csv" --memory 8K --spill-dir "$dir" \
  "SELECT count(*) FROM hot JOIN small ON hot.k = small.k" >/dev/null 2>"$work/err"; then
  fail "the skewed join was expected to fail"
fi
grep -q "exceeds the memory budget" "$work/err" || fail "skew error message changed: $(cat "$work/err")"
[ -e "$dir" ] && fail "spill dir survived a failed query: $(ls -A "$dir" | wc -l) files"
pass "a failed query leaves no directory behind"

# 3. --spill-dir belongs to the caller: only run files are removed.
dir=$work/c
mkdir -p "$dir"
echo "keep me" > "$dir/notes.txt"
echo "not ours" > "$dir/runx.bin"
$bin exec --csv "$DATA/lineitem.csv" --memory 200K --spill-dir "$dir" \
  "SELECT l_orderkey FROM lineitem ORDER BY l_quantity LIMIT 3" >/dev/null 2>/dev/null || true
[ -f "$dir/notes.txt" ] || fail "a caller's file in --spill-dir was deleted"
[ -f "$dir/runx.bin" ] || fail "a non-run file matching no pattern was deleted"
pass "--spill-dir keeps files moonlake did not write"

# 4. ANALYZE under a budget reports the spill, with byte counts.
dir=$work/d
out=$($rel exec --csv "$DATA/lineitem.csv" --memory 200K --spill-dir "$dir" --analyze \
  "SELECT l_orderkey FROM lineitem ORDER BY l_quantity LIMIT 3")
for k in "spill runs:" "spill files:" "spill bytes written:" "spill bytes read:"; do
  grep -q "$k" <<<"$out" || fail "ANALYZE output is missing '$k': $out"
done
[ -e "$dir" ] && fail "ANALYZE left its spill dir behind"
pass "ANALYZE reports spill counters"

# 5. ANALYZE without a budget reports no spill at all.
out=$($rel exec --csv "$DATA/lineitem.csv" --analyze \
  "SELECT l_orderkey FROM lineitem ORDER BY l_quantity LIMIT 3")
grep -q "spill files:" <<<"$out" && fail "in-memory ANALYZE reported a spill"
pass "in-memory ANALYZE stays silent about spilling"

# 6. Two spilled queries sharing one --spill-dir run at the same time. Each
#    gets its own subdirectory; before that they both started at run0.bin,
#    overwrote each other and deleted each other's runs ("spill read: No such
#    file or directory" on both sides, measured against the previous binary).
dir=$work/e
mkdir -p "$dir"
$rel exec --csv "$DATA/lineitem.csv" --memory 200K --spill-dir "$dir" \
  "SELECT count(*) FROM (SELECT l_orderkey FROM lineitem ORDER BY l_quantity LIMIT 7)" \
  >"$work/e1.out" 2>&1 &
p1=$!
$rel exec --csv "$DATA/lineitem.csv" --memory 200K --spill-dir "$dir" \
  "SELECT count(*) FROM (SELECT l_orderkey FROM lineitem ORDER BY l_quantity DESC LIMIT 9)" \
  >"$work/e2.out" 2>&1 &
p2=$!
wait $p1 || fail "the first of two concurrent spills failed: $(cat "$work/e1.out")"
wait $p2 || fail "the second of two concurrent spills failed: $(cat "$work/e2.out")"
grep -q "7" "$work/e1.out" || fail "concurrent spill 1 printed $(cat "$work/e1.out")"
grep -q "9" "$work/e2.out" || fail "concurrent spill 2 printed $(cat "$work/e2.out")"
[ -z "$(ls -A "$dir")" ] || fail "concurrent spills left $(ls -A "$dir" | wc -l) entries behind"
pass "two queries share one --spill-dir and clean up after themselves"

# 7. A subdirectory an interrupted (killed) query left behind is not removed
#    by the next run: the fs API exposes no pid, clock or file timestamp, so a
#    dead owner cannot be told from a live one, and deleting on a guess would
#    break a running query. This pins the documented boundary.
dir=$work/f
mkdir -p "$dir/moonlake-spill-0"
printf 'leftover' > "$dir/moonlake-spill-0/run0.bin"
$rel exec --csv "$DATA/lineitem.csv" --memory 200K --spill-dir "$dir" \
  "SELECT l_orderkey FROM lineitem ORDER BY l_quantity LIMIT 3" >/dev/null
[ -f "$dir/moonlake-spill-0/run0.bin" ] || fail "an interrupted run's directory was removed"
[ -z "$(ls -A "$dir" | grep -v '^moonlake-spill-0$')" ] || fail "the accepting run left something behind"
pass "an interrupted run's directory is left alone, the next query still spills"

echo "spill acceptance: all checks passed"
