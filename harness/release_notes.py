"""Print the release notes for one version: the CHANGELOG section, verbatim.

The CHANGELOG is the record; a GitHub release page is a *view* of it. Every
release body is generated from this script, so the two cannot drift, and the
release title is the bare version (`0.6.3`, not `v0.6.3` and not a sentence).

    python3 harness/release_notes.py 0.6.3            # the release body
    python3 harness/release_notes.py --lint           # structure of the file
    python3 harness/release_notes.py --list           # versions the file has
    python3 harness/release_notes.py 0.6.3 --plain    # just the section
    python3 harness/release_notes.py --check 0.6.3 < body.txt

Every rendering ends with the two lines a release page carries: where the record
lives, and how to install the version; `--plain` drops them. `--check` exits 1 when the file given on
stdin is not what this script would emit, which is how a release body is
asserted to be the section it claims to be.
"""

import re
import sys

CHANGELOG = "CHANGELOG.md"
REPO = "superbigcup325/moonlake"


def sections():
    """The file split into (version, date, body) in file order."""
    text = open(CHANGELOG, encoding="utf-8").read()
    heads = list(re.finditer(r"(?m)^## \[([^\]]+)\](?: - (\S+))?$", text))
    out = []
    for i, m in enumerate(heads):
        end = heads[i + 1].start() if i + 1 < len(heads) else len(text)
        body = text[m.end() : end].strip("\n")
        out.append((m.group(1), m.group(2), body))
    return out


ORDER = ["Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"]


def lint():
    """Every version dated, every subsection a Keep a Changelog one, in order."""
    bad = []
    for version, date, body in sections():
        if version != "Unreleased" and not date:
            bad.append(f"{version}: no release date")
        names = re.findall(r"(?m)^### (\S+)$", body)
        unknown = [n for n in names if n not in ORDER]
        if unknown:
            bad.append(f"{version}: not a Keep a Changelog subsection: {unknown}")
        ranks = [ORDER.index(n) for n in names if n in ORDER]
        if ranks != sorted(ranks):
            bad.append(f"{version}: subsections out of order: {names}")
        if not names:
            bad.append(f"{version}: no subsection")
    if bad:
        print("\n".join(bad), file=sys.stderr)
        return 1
    print(f"{CHANGELOG}: {len(sections())} sections, all dated and in order")
    return 0


def pick(version):
    for v, date, body in sections():
        if v == version:
            return v, date, body
    names = ", ".join(v for v, _, _ in sections())
    raise SystemExit(f"no section for {version}; the file has: {names}")


def with_link(version, date, body):
    return (
        f"{body}\n\n"
        f"---\n\n"
        f"Full record: [CHANGELOG.md §{version}]"
        f"(https://github.com/{REPO}/blob/v{version}/{CHANGELOG})"
        f" (released {date}).\n"
        f"Install: `moon add {REPO}@{version}`\n"
    )


def main(argv):
    if len(argv) < 2 or argv[1] in {"-h", "--help"}:
        print(__doc__, file=sys.stderr)
        return 2
    if argv[1] == "--lint":
        return lint()
    if argv[1] == "--list":
        for v, date, _ in sections():
            print(f"{v}\t{date or '-'}")
        return 0
    check = argv[1] == "--check"
    version = argv[2] if check else argv[1]
    v, date, body = pick(version)
    # a published body always carries the trailer, so --check compares against
    # the trailer by default; --plain is for a caller that wants the section
    text = with_link(v, date, body) if "--plain" not in argv else body
    if check:
        want = sys.stdin.read()
        if want.strip() != text.strip():
            print(
                f"release notes for {v} differ from {CHANGELOG}\n"
                f"  file: {len(want)} bytes, changelog: {len(text)} bytes",
                file=sys.stderr,
            )
            return 1
        return 0
    sys.stdout.write(text)
    if not text.endswith("\n"):
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
