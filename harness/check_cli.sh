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

echo "cli checks pass"
