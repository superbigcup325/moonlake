# Release provenance check: prove that what is about to ship is the thing the
# repository says it is.
#
# Three claims are checked, in the order a reader would check them:
#
#   1. every place that carries the version agrees — `moon.mod`, the library's
#      `VERSION` constant, the newest CHANGELOG heading, and (when the check
#      runs on a tag) the tag name itself. 0.3.0 shipped after a manual review
#      that found three of these four; nothing made them agree by construction.
#   2. the archive `moon publish` would upload holds the files it should and
#      none it should not. Only `moon package --list` answers this: `.gitignore`
#      and `.git/info/exclude` are not consulted for packaging, and a
#      `.moonignore` in a directory replaces that tree's `.gitignore`.
#   3. optionally, `moon publish --dry-run` passes — the gate the project has
#      always used, which unpacks the archive in a temp directory and checks it
#      there. It needs credentials (run `moon login` first), so it is opt-in.
#
# Usage:
#   python3 harness/check_release.py                 # offline checks only
#   python3 harness/check_release.py --publish-dry-run
#   python3 harness/check_release.py --tag v0.3.1    # explicit tag (CI derives it)
#   python3 harness/check_release.py --json-out r.json
#
# Exits non-zero on the first failed claim.

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# What a published archive must contain, and what it must never contain.
REQUIRED = ("moon.mod", "README.md", "LICENSE", "moonlake.mbt")
FORBIDDEN = (
    ".internal/",
    "moon.work",
    ".mooncakes/",
    "_build/",
    "/target/",
    "__pycache__/",
    "harness/data/",
    "harness/spill_bench/",
    "harness/kernel_bench/",
    "hooks/",
    ".venv/",
    ".env",
)


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, **kw)


def read_version_from_mod() -> str:
    text = (ROOT / "moon.mod").read_text(encoding="utf-8")
    match = re.search(r'(?m)^version\s*=\s*"([^"]+)"', text)
    if not match:
        fail("moon.mod has no version line")
    return match.group(1)


def read_version_from_lib() -> str:
    text = (ROOT / "moonlake.mbt").read_text(encoding="utf-8")
    match = re.search(r'VERSION\s*:\s*String\s*=\s*"([^"]+)"', text)
    if not match:
        fail("moonlake.mbt has no VERSION constant")
    return match.group(1)


def read_version_from_changelog() -> str:
    text = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    for line in text.splitlines():
        match = re.match(r"^##\s+\[([^\]]+)\]", line)
        if not match:
            continue
        name = match.group(1)
        # An Unreleased section is the work in progress, not a version claim.
        if name.lower() in ("unreleased", "unreleased)"):
            continue
        return name
    fail("CHANGELOG.md has no versioned heading")


def check_versions(tag: str | None) -> dict:
    mod = read_version_from_mod()
    lib = read_version_from_lib()
    log = read_version_from_changelog()
    claims = {"moon.mod": mod, "moonlake.mbt": lib, "CHANGELOG.md": log}
    if tag:
        claims["tag"] = tag.lstrip("v")
    distinct = set(claims.values())
    if len(distinct) != 1:
        detail = ", ".join(f"{k}={v}" for k, v in claims.items())
        fail(f"the version claims disagree: {detail}")
    version = distinct.pop()
    print(f"ok: version {version} agrees across {', '.join(claims)}")
    return {"version": version, "claims": claims}


def check_archive() -> dict:
    proc = run(["moon", "package", "--list"])
    if proc.returncode != 0:
        # `moon package --list` runs `moon check` first and prints the failure
        fail(f"moon package --list failed:\n{proc.stdout[-2000:]}{proc.stderr[-2000:]}")
    # The list goes to stderr, mixed with the check's progress lines (the CLI
    # keeps stdout empty for this command); accept either stream.
    combined = (proc.stdout + "\n" + proc.stderr).splitlines()
    files = [
        line.strip()
        for line in combined
        if line.strip()
        and not line.startswith(
            ("Running ", "Finished.", "Check ", "Package to ", "Error", "warning")
        )
    ]
    if not files:
        fail("moon package --list produced no file list")
    for want in REQUIRED:
        if want not in files:
            fail(f"the archive is missing {want}")
    for pattern in FORBIDDEN:
        hits = [f for f in files if pattern in f]
        if hits:
            fail(f"the archive carries {len(hits)} file(s) matching {pattern}: {hits[:3]}")
    print(f"ok: archive holds {len(files)} files, none matching a forbidden pattern")
    return {"files": len(files), "required": list(REQUIRED)}


def check_git() -> dict:
    describe = run(["git", "describe", "--tags", "--always", "--dirty"]).stdout.strip()
    commit = run(["git", "rev-parse", "HEAD"]).stdout.strip()
    dirty = run(["git", "status", "--porcelain"]).stdout.strip()
    if dirty:
        fail(f"the working tree is not clean:\n{dirty[:500]}")
    print(f"ok: git {describe} at {commit[:12]}, clean tree")
    return {"describe": describe, "commit": commit}


def check_publish_dry_run() -> dict:
    proc = run(["moon", "publish", "--dry-run"])
    out = proc.stdout + proc.stderr
    # The dry run ends in `202 Accepted` and the CLI still exits non-zero; the
    # status line is the verdict (a successful publish prints 200 OK).
    if "Server status: 202" not in out and "Dry run completed successfully" not in out:
        fail(f"moon publish --dry-run did not report a successful dry run:\n{out[-3000:]}")
    print("ok: moon publish --dry-run validated the archive")
    return {"dry_run": "202 Accepted"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", help="release tag being checked (default: none)")
    parser.add_argument("--publish-dry-run", action="store_true")
    parser.add_argument("--json-out")
    args = parser.parse_args()

    if args.tag is None and os.environ.get("GITHUB_REF_TYPE") == "tag":
        args.tag = os.environ.get("GITHUB_REF_NAME")

    record = {
        "schema": 1,
        "kind": "moonlake-release-provenance",
        "versions": check_versions(args.tag),
        "archive": check_archive(),
        "git": check_git(),
    }
    if args.publish_dry_run:
        record["publish"] = check_publish_dry_run()
    else:
        print("skip: moon publish --dry-run (needs credentials; pass --publish-dry-run)")

    if args.json_out:
        pathlib.Path(args.json_out).write_text(json.dumps(record, indent=1) + "\n")
        print(f"recorded {args.json_out}")
    print("release provenance: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
