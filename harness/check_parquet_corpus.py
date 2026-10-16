# Cross-check the in-house Parquet reader against the apache/parquet-testing
# corpus: for every file in scope the row count must match DuckDB's, and
# every file out of scope must be refused with a pointed scan error (a wrong
# answer or a crash is a failure either way).
#
# The corpus is downloaded to a cache directory rather than committed: it is
# third-party data, and the point is to be able to re-run against whatever
# the upstream repository carries today.
#
# Usage: python3 harness/check_parquet_corpus.py [--keep]
#   MOONLAKE_BIN: path to a prebuilt native CLI (defaults to `moon run cmd/main`)

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
import urllib.request

CACHE = pathlib.Path.home() / ".cache" / "moonlake-parquet-corpus"
BASE = "https://raw.githubusercontent.com/apache/parquet-testing/master/data"

# out-of-scope messages the reader is expected to produce; anything else is a
# failure to investigate, not a documented refusal
REFUSALS = (
    "nested schemas are not supported",
    "repeated fields are not supported",
    "INT96 timestamps are not supported",
    "FIXED_LEN_BYTE_ARRAY is not supported",
    "data page v2 is not supported",
    "GZIP compression is not supported",
    "compression codec",
    "encoding DELTA",
    "encoding BYTE_STREAM_SPLIT",
    "encoding RLE",
    "PLAIN BYTE_ARRAY",  # decimal/interval BYTE_ARRAY without UTF8 is refused at registration
    "timestamp",
    "the dictionary page holds no entries",
    "dictionary index",
    "and none of them is PLAIN or a dictionary encoding",
    "TIMESTAMP is not supported",
)

SCHEMA = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


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
            import json

            entries = json.load(r)
        names = sorted(e["name"] for e in entries if e["name"].endswith(".parquet"))
        listing.write_text("\n".join(names))
    return [n for n in listing.read_text().splitlines() if n]


def duckdb_count(path: pathlib.Path) -> int | str:
    # a fresh connection per file: a failed read aborts the transaction and
    # would poison every later query on the same connection
    import duckdb

    con = duckdb.connect()
    try:
        return con.sql(f"select count(*) from read_parquet('{path}')").fetchone()[0]
    except Exception as e:  # noqa: BLE001 - duckdb cannot read it either
        return f"duckdb: {str(e).splitlines()[0][:90]}"
    finally:
        con.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.parse_args()

    files = fetch(corpus_files())
    print(f"corpus: {len(files)} files cached in {CACHE}")

    ok = refused = failed = 0
    for name in sorted(files):
        path = files[name]
        stem = path.stem
        if not SCHEMA.match(stem):
            stem = f'"{stem}"'
        query = f"select count(*) from {stem}"
        proc = subprocess.run(
            ["moon", "run", "cmd/main", "--", "exec", "--parquet", str(path), query],
            capture_output=True,
            text=True,
        )
        got = proc.stdout.strip().splitlines()[-1] if proc.stdout.strip() else ""
        err = proc.stderr.strip().splitlines()
        err = [l for l in err if "sql error" in l]
        want = duckdb_count(path)

        if isinstance(want, str):
            print(f"SKIP  {name}: {want}")
            continue
        if got.isdigit() and int(got) == want:
            ok += 1
            print(f"PASS  {name}: {want} rows")
        elif err:
            message = err[0]
            if any(r in message for r in REFUSALS):
                refused += 1
                print(f"REFUSE {name}: {message.split('parquet: ', 1)[-1][:80]}")
            else:
                failed += 1
                print(f"FAIL  {name}: unexpected refusal: {message[:100]}")
        else:
            failed += 1
            print(f"FAIL  {name}: moonlake {got!r} vs duckdb {want} (rc={proc.returncode})")

    print(f"\n{ok} read, {refused} refused by design, {failed} failing")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
