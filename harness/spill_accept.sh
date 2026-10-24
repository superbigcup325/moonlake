#!/usr/bin/env bash
# Spill lifecycle acceptance: a query that spills must not leave temp
# files behind, on success or on failure, and ANALYZE must show what it
# spilled. Also checks that --spill-dir is only ever cleaned of the run
# files moonlake writes, never of a caller's own files, and that two
# processes can share one --spill-dir without deleting each other's runs.
#
# The last checks cover the owner protocol: a directory left by a killed
# query is reclaimed by the next one, while a directory whose owner is
# still running (or cannot be judged) is left alone.
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

# 4. ANALYZE under a budget reports the spill, with byte counts. A run count of
#    zero would make this check pass while proving nothing, so the query below is
#    one that does spill under 200K; if an engine change makes it stop spilling,
#    pick another query rather than dropping the assertion.
dir=$work/d
out=$($rel exec --csv "$DATA/lineitem.csv" --memory 200K --spill-dir "$dir" --analyze \
  "SELECT l_orderkey FROM lineitem ORDER BY l_quantity LIMIT 3")
for k in "spill runs:" "spill files:" "spill bytes written:" "spill bytes read:"; do
  grep -q "$k" <<<"$out" || fail "ANALYZE output is missing '$k': $out"
done
grep -Eq "spill runs: [1-9]" <<<"$out" \
  || fail "ANALYZE reported no spill runs for a query that is expected to spill: $out"
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

# 7. A subdirectory with no owner marker is kept: nothing records who owned it,
#    so it cannot be judged dead, and deleting on a guess would break a running
#    query. The next query moves on to the next index instead.
dir=$work/f
mkdir -p "$dir/moonlake-spill-0"
printf 'leftover' > "$dir/moonlake-spill-0/run0.bin"
$rel exec --csv "$DATA/lineitem.csv" --memory 200K --spill-dir "$dir" \
  "SELECT l_orderkey FROM lineitem ORDER BY l_quantity LIMIT 3" >/dev/null
[ -f "$dir/moonlake-spill-0/run0.bin" ] || fail "a directory with no marker was removed"
[ -z "$(ls -A "$dir" | grep -v '^moonlake-spill-0$')" ] || fail "the accepting run left something behind"
pass "a directory with no owner marker is left alone, the next query still spills"

# 8. A directory of a query that was killed is reclaimed by the next one: the
#    marker records a pid, and that pid no longer exists. The query is frozen as
#    soon as it claims its directory — waiting for its run files would race a
#    spill that only lasts part of the run — and the run file a mid-sort kill
#    would have left is written in by hand.
dir=$work/g
mkdir -p "$dir"
$rel exec --csv "$DATA/lineitem.csv" --memory 200K --spill-dir "$dir" \
  "SELECT l_orderkey FROM lineitem ORDER BY l_quantity LIMIT 3" >"$work/g.out" 2>&1 &
victim=$!
for _ in $(seq 1 500); do
  ls "$dir"/moonlake-spill-*/owner >/dev/null 2>&1 && break
  sleep 0.01
done
ls "$dir"/moonlake-spill-*/owner >/dev/null 2>&1 || fail "the query to be killed never claimed a spill directory"
kill -STOP "$victim" 2>/dev/null || true
leaked=$(ls -d "$dir"/moonlake-spill-*)
kill -9 "$victim" 2>/dev/null || true
wait "$victim" 2>/dev/null || true
[ -d "$leaked" ] || fail "the killed query's directory vanished before the next run"
printf 'stale run' > "$leaked/run0.bin"
out=$($rel exec --csv "$DATA/lineitem.csv" --memory 200K --spill-dir "$dir" \
  "SELECT l_orderkey FROM lineitem ORDER BY l_quantity LIMIT 3" 2>"$work/g2.err")
[ -n "$out" ] || fail "the reclaiming query printed nothing"
[ -e "$leaked" ] && fail "the killed query's directory was not reclaimed: $(ls -A "$leaked")"
[ -z "$(ls -A "$dir")" ] || fail "a killed run's leftovers survived: $(ls -A "$dir")"
grep -q "reclaimed" "$work/g2.err" || fail "no note about the reclaim: $(cat "$work/g2.err")"
pass "a killed query's directory is reclaimed by the next query"

# 9. A directory whose marker names a live process is not touched, even though
#    that process has nothing to do with the query: the pid is running with the
#    recorded start time, so the owner is live.
dir=$work/h
mkdir -p "$dir/moonlake-spill-0"
printf 'leftover' > "$dir/moonlake-spill-0/run0.bin"
sleep 30 &
live=$!
boot_id=$(tr -d '\n' < /proc/sys/kernel/random/boot_id)
starttime=$(sed 's/.*) //' "/proc/$live/stat" | awk '{print $20}')
printf 'version=1\npid=%s\nboot_id=%s\nstarttime=%s\nnonce=1-0\ncreated_at=0\n' \
  "$live" "$boot_id" "$starttime" > "$dir/moonlake-spill-0/owner"
$rel exec --csv "$DATA/lineitem.csv" --memory 200K --spill-dir "$dir" \
  "SELECT l_orderkey FROM lineitem ORDER BY l_quantity LIMIT 3" >/dev/null 2>"$work/h.err"
[ -f "$dir/moonlake-spill-0/run0.bin" ] || fail "a live owner's directory was removed"
grep -q "reclaimed" "$work/h.err" && fail "a live owner's directory was reclaimed: $(cat "$work/h.err")"
[ -z "$(ls -A "$dir" | grep -v '^moonlake-spill-0$')" ] || fail "the accepting run left something behind"
kill "$live" 2>/dev/null || true
wait "$live" 2>/dev/null || true
pass "a live owner's directory is left alone"

# 10. A marker this version does not understand is kept and reported: a newer
#     moonlake may write a format this build must not delete.
dir=$work/i
mkdir -p "$dir/moonlake-spill-0"
printf 'version=9\npid=1\nboot_id=x\nstarttime=1\n' > "$dir/moonlake-spill-0/owner"
$rel exec --csv "$DATA/lineitem.csv" --memory 200K --spill-dir "$dir" \
  "SELECT l_orderkey FROM lineitem ORDER BY l_quantity LIMIT 3" >/dev/null 2>"$work/i.err"
[ -f "$dir/moonlake-spill-0/owner" ] || fail "an unknown marker's directory was reclaimed"
grep -q "not one this version understands" "$work/i.err" \
  || fail "no warning about the unknown marker: $(cat "$work/i.err")"
pass "an unknown marker is kept and reported"

echo "spill acceptance: all checks passed"
