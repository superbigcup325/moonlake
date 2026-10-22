"""Run a separate consumer against a packaged or published moonlake.

The pre-publish mode uses only files extracted from `moon package`, never the
working checkout as a workspace member. A fresh MOON_HOME fetches the public
dependency graph; only the installed compiler/core are reused, not credentials,
registry indexes or .mooncakes. Nothing is uploaded or published.

After publishing the current API, --registry-version checks the registry copy
instead, with no workspace override. Both modes run native, wasm-gc and JS.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODULE = "superbigcup325/moonlake"
TARGETS = ("native", "wasm-gc", "js")
ROWS = (
    '[{"region":"north","total":15,"first_day":"2024-01-01","notes":2},'
    '{"region":"south","total":20,"first_day":"2024-01-03","notes":0}]'
)


def command(args: list[str], cwd: pathlib.Path, env: dict | None = None) -> str:
    proc = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)
    if proc.returncode:
        raise RuntimeError(
            f"{' '.join(args)} exited {proc.returncode}:\n"
            f"{proc.stdout[-2000:]}{proc.stderr[-4000:]}"
        )
    return proc.stdout.strip()


def package_archive() -> pathlib.Path:
    proc = subprocess.run(["moon", "package"], cwd=ROOT, capture_output=True, text=True)
    if proc.returncode:
        raise RuntimeError(f"moon package failed:\n{proc.stdout[-2000:]}{proc.stderr[-4000:]}")
    for line in (proc.stdout + "\n" + proc.stderr).splitlines():
        if line.startswith("Package to "):
            path = pathlib.Path(line.removeprefix("Package to ").strip())
            path = path if path.is_absolute() else ROOT / path
            if path.is_file():
                return path
    raise RuntimeError("moon package did not identify an existing archive")


def unpack_archive(archive: pathlib.Path, dest: pathlib.Path) -> str:
    with zipfile.ZipFile(archive) as packed:
        for entry in packed.infolist():
            path = pathlib.PurePosixPath(entry.filename)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError(f"archive path escapes its package: {entry.filename}")
        packed.extractall(dest)
    mod = (dest / "moon.mod").read_text(encoding="utf-8")
    name = re.search(r'(?m)^name\s*=\s*"([^"]+)"', mod)
    version = re.search(r'(?m)^version\s*=\s*"([^"]+)"', mod)
    if not name or name.group(1) != MODULE or not version:
        raise ValueError("archive must contain moonlake's module name and version")
    if (dest / "moon.work").exists() or (dest / ".mooncakes").exists():
        raise ValueError("archive carries a workspace override or a dependency cache")
    return version.group(1)


def fresh_moon_home(dest: pathlib.Path) -> None:
    executable = shutil.which("moon")
    if not executable:
        raise RuntimeError("moon is not on PATH")
    toolchain = pathlib.Path(executable).resolve().parent.parent
    dest.mkdir()
    for name in ("bin", "lib", "include"):
        source = toolchain / name
        if not source.is_dir():
            raise RuntimeError(f"cannot locate installed toolchain directory: {source}")
        (dest / name).symlink_to(source, target_is_directory=True)


def check_output(output: str, version: str) -> None:
    expected = "\n".join(
        [f"version|{version}", *(f"{name}|{ROWS}" for name in ("csv", "raw", "snappy")), "drop|ok"]
    )
    if output != expected:
        raise ValueError(f"consumer output differs:\nexpected:\n{expected}\ngot:\n{output}")


def check_consumer(
    archive: pathlib.Path | None = None,
    registry_version: str | None = None,
) -> dict:
    if archive is not None and registry_version is not None:
        raise ValueError("choose an archive or a registry version, not both")
    archive = archive.resolve() if archive is not None else None
    if registry_version is None and archive is None:
        archive = package_archive()
    record = {
        "schema": 1,
        "source": "archive" if archive else "registry",
        "toolchain": command(["moon", "version", "--all"], ROOT),
        "targets": {},
    }
    if archive:
        with archive.open("rb") as stream:
            record["archive_sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()

    with tempfile.TemporaryDirectory(prefix="moonlake-consumer-") as tmp:
        work = pathlib.Path(tmp)
        if archive:
            version = unpack_archive(archive, work / "package")
            # Only the archive and the consumer are members. No source checkout
            # or local colenc checkout can silently satisfy an import here.
            (work / "moon.work").write_text(
                'members = ["./package", "./consumer"]\n', encoding="utf-8"
            )
        else:
            version = registry_version
        record["version"] = version
        consumer = work / "consumer"
        consumer.mkdir()
        for name in ("main.mbt", "moon.pkg"):
            shutil.copyfile(ROOT / "harness" / "consumer" / name, consumer / name)
        (consumer / "moon.mod").write_text(
            'name = "moonlake-acceptance/consumer"\nversion = "0.0.0"\n'
            f'import {{ {json.dumps(MODULE + "@" + version)} }}\n',
            encoding="utf-8",
        )
        moon_home = work / "moon-home"
        fresh_moon_home(moon_home)
        env = dict(os.environ, MOON_HOME=str(moon_home))
        print(f"consumer: {record['source']} {version}; fresh registry and dependency cache", flush=True)
        command(["moon", "update"], consumer, env)
        for target in TARGETS:
            output = command(["moon", "run", "--target", target, "--deny-warn", "."], consumer, env)
            check_output(output, version)
            record["targets"][target] = "passed"
            print(f"ok: consumer {target} — version, CSV, Parquet raw/Snappy, DATE/NULL, drop", flush=True)
    return record


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--archive", type=pathlib.Path, help="default: build with moon package")
    source.add_argument("--registry-version", help="check the current API after publishing this version")
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args()
    try:
        record = check_consumer(args.archive, args.registry_version)
    except (RuntimeError, ValueError, OSError, zipfile.BadZipFile) as error:
        print(f"FAIL: {error}")
        return 1
    if args.json_out:
        args.json_out.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print("consumer acceptance: all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
