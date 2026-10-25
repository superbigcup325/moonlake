# Cross-check the in-house Parquet reader against the apache/parquet-testing
# corpus, at the level a reader actually has to get right.
#
# A footer-only `select count(*)` is not a read: it never touches a data page,
# so a file whose pages need a codec or a page version this reader refuses
# still "passes" it. That is how the corpus once reported 35 read / 33 refused
# when only 17 of the 35 could decode a single column. Every file is therefore
# classified by what it takes to read data:
#
#   decoded  — every column decodes (`count(<col>)` per column), the row count
#              matches DuckDB's, and a value sample from up to three columns
#              matches DuckDB's cell for cell
#   refused  — the reader refuses for a documented reason, at registration or
#              at a page; the message must match REFUSALS
#   skip     — DuckDB cannot read the file either, so there is nothing to agree
#   failing  — anything else: a wrong answer, a crash, an unexplained refusal
#
# The class of every file is pinned in `harness/parquet_corpus_expected.json`
# (`--update` rewrites it). A known file that changes class fails the check:
# "refused -> decoded" is good news that has to be recorded, and
# "decoded -> refused" is a regression nobody would notice from a count.
#
# The corpus is downloaded to a cache directory rather than committed: it is
# third-party data, and the point is to be able to re-run against whatever the
# upstream repository carries today. Files upstream adds are reported as new
# and do not fail the check; a maintainer classifies them with `--update`.
#
# Usage:
#   python3 harness/check_parquet_corpus.py             # check, exit 1 on regression
#   python3 harness/check_parquet_corpus.py --update    # record the classes seen
#   MOONLAKE_BIN=/path/to/main python3 harness/check_parquet_corpus.py
#     (skips `moon run`'s build-and-launch cost per file)

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import re
import subprocess
import sys
import urllib.request

CACHE = pathlib.Path.home() / ".cache" / "moonlake-parquet-corpus"
BASE = "https://raw.githubusercontent.com/apache/parquet-testing/master/data"
EXPECTED = pathlib.Path(__file__).resolve().parent / "parquet_corpus_expected.json"

# Out-of-scope messages the reader is expected to produce; anything else is a
# failure to investigate, not a documented refusal. Deliberately does not
# include the DELTA / BYTE_STREAM_SPLIT encodings: those are decoded now, so a
# refusal naming one is a regression, not a design choice.
REFUSALS = (
    "nested schemas are not supported",
    "repeated fields are not supported",
    "INT96 timestamps are not supported",
    "FIXED_LEN_BYTE_ARRAY is not supported",
    "data page v2 is not supported",
    # a page that needs bytes the file does not have: a genuinely truncated
    # file, refused by name instead of decoding whatever follows it. A page
    # that merely overruns the footer's `total_compressed_size` is readable and
    # is read (`nation.dict-malformed`), so this message must only appear when
    # the bytes are really missing
    "payload bytes, past the end of the file",
    "GZIP compression is not supported",
    "compression codec",
    "the dictionary page holds no entries",
    "dictionary index",
    "and none of them is PLAIN or a dictionary encoding",
    "TIMESTAMP is not supported",
    # annotations the reader has no faithful engine type for: reading them as
    # text (DECIMAL byte arrays) or as signed integers (UINT) would return
    # wrong values rather than fail
    "DECIMAL is not supported",
    "UINT_64 is not supported",
    "UINT_32 is not supported",
)

SCHEMA = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

# DuckDB types whose values this engine also produces, so a cell-for-cell
# comparison is meaningful. BLOB/LIST/STRUCT/MAP/DECIMAL/TIMESTAMP are not
# engine types: a file carrying one is refused at registration.
COMPARABLE = (
    "BOOLEAN",
    "TINYINT",
    "SMALLINT",
    "INTEGER",
    "BIGINT",
    "FLOAT",
    "DOUBLE",
    "VARCHAR",
    "DATE",
)
FLOATS = ("FLOAT", "DOUBLE")
INTEGERS = ("TINYINT", "SMALLINT", "INTEGER", "BIGINT")


def fetch(names: list[str]) -> dict[str, pathlib.Path]:
    CACHE.mkdir(parents=True, exist_ok=True)
    out = {}
    for name in names:
        path = CACHE / name
        if not path.exists():
            try:
                with urllib.request.urlopen(f"{BASE}/{name}", timeout=30) as r:
                    path.write_bytes(r.read())
            except Exception as e:  # noqa: BLE001 - report and skip
                print(f"  download failed: {name}: {e}")
                continue
        out[name] = path
    return out


def corpus_files() -> list[str]:
    CACHE.mkdir(parents=True, exist_ok=True)
    listing = pathlib.Path(CACHE) / "listing.txt"
    if not listing.exists():
        url = "https://api.github.com/repos/apache/parquet-testing/contents/data"
        with urllib.request.urlopen(url, timeout=30) as r:
            entries = json.load(r)
        names = sorted(e["name"] for e in entries if e["name"].endswith(".parquet"))
        listing.write_text("\n".join(names))
    return [n for n in listing.read_text().splitlines() if n]


def quote(name: str) -> str:
    return name if SCHEMA.match(name) else '"' + name.replace('"', '""') + '"'


def table(stem: str) -> str:
    return quote(stem)


def duckdb_count(path: pathlib.Path) -> int | str:
    # a fresh connection per file: a failed read aborts the transaction and
    # would poison every later query on the same connection
    import duckdb

    con = duckdb.connect()
    try:
        return con.execute(f"select count(*) from read_parquet('{path}')").fetchall()[0][0]
    except duckdb.Error as e:
        # Only a DuckDB read error makes a file unjudgeable. A Python/API error
        # must fail the gate, not silently turn every file into a successful skip.
        return f"duckdb: {str(e).splitlines()[0][:90]}"
    finally:
        con.close()


def duckdb_columns(path: pathlib.Path) -> list[tuple[str, str]]:
    import duckdb

    con = duckdb.connect()
    try:
        rows = con.sql(f"describe select * from read_parquet('{path}')").fetchall()
        return [(row[0], row[1].upper()) for row in rows]
    finally:
        con.close()


def duckdb_rows(path: pathlib.Path, column: str, limit: int) -> list:
    import duckdb

    con = duckdb.connect()
    try:
        sql = f"select {quote(column)} from read_parquet('{path}') limit {limit}"
        return [row[0] for row in con.sql(sql).fetchall()]
    finally:
        con.close()


def moonlake(
    runner: list[str], sql: str, path: pathlib.Path
) -> tuple[int, str, list[str]]:
    proc = subprocess.run(
        [*runner, "exec", "--parquet", str(path), sql],
        capture_output=True,
        text=True,
    )
    errors = [line for line in proc.stderr.strip().splitlines() if "sql error" in line]
    return proc.returncode, proc.stdout.strip(), errors


def refusal_or_failure(errors: list[str], out: str = "") -> dict:
    message = errors[0] if errors else "no sql error on stderr"
    if not errors and "sql error" in out:
        # `eprintln` has no stderr channel on wasm-gc and falls back to stdout
        # (moonbitlang/core documents it), so the default `moon run cmd/main`
        # invocation still shows the refusal, on the other stream. Native and
        # js write it to stderr; MOONLAKE_BIN=...a native build... is how CI runs.
        line = next(l for l in out.splitlines() if "sql error" in l)
        message = f"{line} (on stdout: wasm-gc has no stderr)"
    if any(r in message for r in REFUSALS):
        return {"class": "refused", "why": message.split("parquet: ", 1)[-1][:90]}
    return {"class": "failing", "why": f"unexpected refusal: {message[:110]}"}


def normalise(value, kind: str) -> tuple[bool, str]:
    """The text the CLI should print for one DuckDB cell, and whether the cell
    can be compared at all."""
    if value is None:
        return True, "null"
    if kind == "BOOLEAN":
        return True, "true" if value else "false"
    if kind in INTEGERS:
        return True, str(int(value))
    if kind in FLOATS:
        number = float(value)
        if math.isnan(number):
            return True, "NaN"
        if number.is_integer():
            return True, str(int(number))
        return True, repr(number)
    text = str(value)
    if "\n" in text or "|" in text or text == "null" or text == "":
        # the CLI's cell format cannot carry this value unambiguously
        return False, text
    return True, text


def classify(runner: list[str], path: pathlib.Path, want_rows: int) -> dict:
    tbl = table(path.stem)

    # 1. the footer agrees: row count, schema and annotations readable
    code, out, errors = moonlake(runner, f"select count(*) from {tbl}", path)
    if code != 0:
        return refusal_or_failure(errors, out)
    got = out.splitlines()[-1] if out else ""
    if not got.isdigit():
        return {"class": "failing", "why": f"count(*) printed {got!r}"}
    if int(got) != want_rows:
        return {"class": "failing", "why": f"count(*) {got} vs duckdb {want_rows}"}

    # 2. every column's pages decode: count(col) reads values, so codec, page
    #    version, dictionary and encoding decisions all have to hold
    try:
        columns = duckdb_columns(path)
    except Exception as e:  # noqa: BLE001
        return {
            "class": "failing",
            "why": f"duckdb cannot describe: {str(e).splitlines()[0][:80]}",
        }
    for column, _ in columns:
        code, out, errors = moonlake(
            runner, f"select count({quote(column)}) from {tbl}", path
        )
        if code != 0:
            return refusal_or_failure(errors, out)

    # 3. a value sample matches, cell for cell, on up to three columns whose
    #    values cannot be confused with the pipe separator or the null spelling
    sampled = 0
    for column, kind in columns:
        if kind not in COMPARABLE or sampled >= 3:
            continue
        code, out, _ = moonlake(runner, f"select {quote(column)} from {tbl} limit 5", path)
        if code != 0:
            return {"class": "failing", "why": f"sample of {column} failed"}
        try:
            want = duckdb_rows(path, column, 5)
        except Exception as e:  # noqa: BLE001
            return {
                "class": "failing",
                "why": f"duckdb sample of {column}: {str(e).splitlines()[0][:60]}",
            }
        lines = out.splitlines()
        payload = lines[1:] if len(lines) > 1 else []
        if len(payload) != len(want):
            return {
                "class": "failing",
                "why": f"sample of {column}: {len(payload)} rows vs {len(want)}",
            }
        comparable = True
        for raw, expected in zip(payload, want):
            ok, expected_text = normalise(expected, kind)
            if not ok:
                comparable = False
                break
            if raw != expected_text:
                return {
                    "class": "failing",
                    "why": f"{column}: moonlake {raw!r} vs duckdb {expected_text!r}",
                }
        if comparable:
            sampled += 1
    return {"class": "decoded", "why": f"{len(columns)} columns, {sampled} sampled"}


def load_expected() -> dict[str, dict]:
    if not EXPECTED.exists():
        return {}
    data = json.loads(EXPECTED.read_text(encoding="utf-8"))
    return data.get("files", {})


def write_expected(files: dict[str, dict], toolchain: str) -> None:
    record = {
        "schema": 1,
        "note": "Class of every apache/parquet-testing file this reader has been "
        "checked against. `decoded` means every column's pages decode and a value "
        "sample matches DuckDB; `refused` means a documented refusal. Regenerate "
        "with `python3 harness/check_parquet_corpus.py --update` after reviewing "
        "the diff.",
        "checked_with": toolchain,
        "files": dict(sorted(files.items())),
    }
    EXPECTED.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(f"recorded {len(files)} classes in {EXPECTED.name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--update", action="store_true", help="record the classes seen")
    parser.add_argument("--json-out", help="write the classification record here")
    args = parser.parse_args()

    names = corpus_files()
    files = fetch(names)
    print(f"corpus: {len(files)} files cached in {CACHE}")

    bin_env = os.environ.get("MOONLAKE_BIN")
    runner = [bin_env] if bin_env else ["moon", "run", "cmd/main", "--"]
    proc = subprocess.run(["moon", "version"], capture_output=True, text=True)
    toolchain = proc.stdout.strip().splitlines()[0] if proc.stdout.strip() else "unknown"

    expected = load_expected()
    seen: dict[str, dict] = {}
    counts = {"decoded": 0, "refused": 0, "failing": 0}
    new: list[str] = []
    changed: list[str] = []

    for name in sorted(files):
        path = files[name]
        want = duckdb_count(path)
        if isinstance(want, str):
            print(f"SKIP  {name}: {want}")
            continue
        result = classify(runner, path, want)
        cls = result["class"]
        seen[name] = result
        counts[cls] += 1
        mark = {"decoded": "READ", "refused": "REFUSE", "failing": "FAIL"}[cls]
        print(f"{mark:6} {name}: {result['why']}")
        before = expected.get(name, {}).get("class")
        if before is None:
            new.append(name)
        elif before != cls:
            changed.append(f"{name}: {before} -> {cls} ({result['why']})")

    print(
        f"\n{counts['decoded']} decoded by value, {counts['refused']} refused by "
        f"design, {counts['failing']} failing"
    )
    if new:
        print(f"new: {len(new)} file(s) not in the record: {', '.join(new[:5])}")
    if changed:
        print("class changed for files in the record:")
        for line in changed:
            print(f"  {line}")
    missing = sorted(expected.keys() - seen.keys())
    if missing:
        print("recorded files not verified (download missing or DuckDB skipped):")
        for name in missing:
            print(f"  {name}")
    if not seen:
        print("no files were verified")
        return 1

    if args.json_out:
        pathlib.Path(args.json_out).write_text(
            json.dumps({"schema": 1, "files": seen}, indent=1) + "\n", encoding="utf-8"
        )

    if args.update:
        write_expected(seen, toolchain)
        return 0

    if missing:
        return 1
    if counts["failing"]:
        return 1
    if not expected:
        print("no record yet: run --update once, review the diff, commit it")
        return 1
    if changed:
        print("run --update after reviewing the changes above")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
