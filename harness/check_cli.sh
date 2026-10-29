#!/usr/bin/env bash
# CLI edges that live in cmd/main argument handling rather than in the
# engine: they need no TPC-H data, only the native binary.
#
# Usage: bash harness/check_cli.sh
#   (build first: moon build cmd/main --target native)
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=${MOONLAKE_BIN:-_build/native/debug/build/cmd/main/main.exe}
if [ ! -x "$BIN" ]; then
  echo "missing $BIN; run: moon build cmd/main --target native" >&2
  exit 1
fi

fail() { echo "FAIL: $*" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# an expression-only query needs no --csv/--parquet (empty catalog)
echo "== exec without inputs"
out=$("$BIN" exec "SELECT 1 + 1 AS two, upper('ab') AS u")
[ "$out" = "two|u
2|AB" ] || fail "unexpected output: $out"

# a misspelled command is an error, not the usage text on stdout
echo "== unknown command exits 1"
set +e
"$BIN" nosuchcmd >"$work/out" 2>"$work/err"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "unknown command exited $rc, want 1"
grep -q "unknown command" "$work/err" || fail "no unknown-command message"
[ -s "$work/out" ] && fail "usage text leaked to stdout"

# --out may not be one of the inputs: the write would replace the source
echo "== write refuses to overwrite an input"
printf 'a,b\n1,2\n' > "$work/t.csv"
set +e
"$BIN" write --csv "$work/t.csv" --out "$work/t.csv" >"$work/wout" 2>"$work/werr"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "same-path write exited 0"
grep -q "would replace the source file" "$work/werr" ||
  fail "no same-path message: $(cat "$work/werr")"
head -1 "$work/t.csv" | grep -q '^a,b' || fail "source CSV was replaced"

# Output arrives a batch at a time: one JSON document whose lines are batches,
# so a scan never has to become one string. The row count is what proves the
# rows survived; the line count is what proves they came out in pieces.
echo "== --json streams one document over several batch lines"
{ echo "a"; seq 1 20000; } > "$work/rows.csv"
"$BIN" exec --csv "$work/rows.csv" --json "SELECT a FROM rows" >"$work/j1"
python3 - "$work/j1" <<'PYCLI'
import json
import sys

text = open(sys.argv[1], encoding="utf-8").read()
rows = json.loads(text)
assert len(rows) == 20000, f"{len(rows)} rows, want 20000"
assert rows[0] == {"a": 1}, rows[0]
assert rows[-1] == {"a": 20000}, rows[-1]
assert text.count("\n") > 1, "one line: nothing streamed"
assert text.count("[") == 1 and text.count("]") == 1, "not one array"
PYCLI

# a result that fits one batch stays one line, byte-identical to the encoding
# of the whole result
"$BIN" exec --csv "$work/rows.csv" --json "SELECT a FROM rows LIMIT 2" >"$work/j2"
[ "$(wc -l < "$work/j2")" -eq 1 ] || fail "single-batch JSON is not one line"
[ "$(cat "$work/j2")" = '[{"a":1},{"a":2}]' ] || fail "unexpected single-batch JSON"

# text output: one header, one line per row, the same rows the JSON document has
"$BIN" exec --csv "$work/rows.csv" "SELECT a FROM rows" >"$work/t1"
[ "$(wc -l < "$work/t1")" -eq 20001 ] || fail "text output is not header plus 20000 rows"
[ "$(head -1 "$work/t1")" = "a" ] || fail "text header is not 'a'"
[ "$(tail -1 "$work/t1")" = "20000" ] || fail "last text row is not 20000"

# A failure that arrives after output began: the rows already printed stay on
# stdout, the message goes to stderr, and the exit status is 1 — so a pipeline
# sees a clean failure rather than a panic trace.
echo "== a scan that fails mid-result keeps what it already printed"
python3 - "$work/boom.csv" <<'PYCLI'
import sys

with open(sys.argv[1], "w", encoding="utf-8") as out:
    out.write("a\n")
    for i in range(1, 4097):
        out.write(f"{i}\n")
    out.write("3000000000\n")  # past int32: the reader cannot parse it
PYCLI
set +e
"$BIN" exec --csv "$work/boom.csv" "SELECT a FROM boom" >"$work/po" 2>"$work/pe"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "a mid-scan failure exited $rc, want 1"
[ "$(wc -l < "$work/po")" -gt 1 ] || fail "nothing was printed before the failure"
[ "$(wc -l < "$work/po")" -lt 4098 ] || fail "the whole table was printed despite the failure"
[ "$(tail -1 "$work/po")" -gt 0 ] || fail "the last printed line is not a data row"
grep -q "cannot parse" "$work/pe" || fail "the scan error is not on stderr"
grep -q "PanicError" "$work/pe" && fail "the failure printed a panic trace"

# --mem runs the query with the structure census on and prints its blocks
# instead of rows; the plain run over the same file still answers. The census
# is off unless asked for, and a pulled shape reaches no declared point, so it
# prints nothing rather than an empty header.
echo "== --mem prints the census, and only with the flag"
printf 'k,w\n1,10\n2,20\n' > "$work/m.csv"
sql="SELECT count(*) AS c FROM m a WHERE EXISTS (SELECT 1 FROM m b WHERE b.k = a.k)"
plain=$("$BIN" exec --csv "$work/m.csv" "$sql")
[ "$plain" = "c
2" ] || fail "plain run answered '$plain'"
mem=$("$BIN" exec --csv "$work/m.csv" --mem "$sql")
case $mem in
  "-- resident by structure"*) ;;
  *) fail "--mem printed no census header: $mem" ;;
esac
printf '%s\n' "$mem" | grep -q '^# collected FROM tables: ' || fail "no tables block"
printf '%s\n' "$mem" | grep -q '^scan m: ' || fail "no scan entry"
out=$("$BIN" exec --csv "$work/m.csv" --mem "SELECT sum(w) AS s FROM m")
[ -z "$out" ] || fail "a pulled shape printed a census: $out"

echo "cli checks pass"
