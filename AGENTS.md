# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Repository layout

- `README.mbt.md` — the file readers land on (tutorial + API tour); `README.md`
  is a symlink kept for GitHub.
- `docs/devlog.md` — weekly log: goals, approach and quality boundaries.
- `docs/verification.md`, `docs/spill-survey.md`, `docs/DEMO.md` — verification
  evidence, the memory-spill design survey, and demo notes.
- `CHANGELOG.md` — release notes (Keep a Changelog, SemVer).
- `harness/` — TPC-H harness, golden answers and reference tooling.

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.

## Known Pitfalls

- `moon fmt` once replaced `README.md` with a dangling symlink and swallowed its
  content; the working setup is `README.mbt.md` as the real file with `README.md`
  as a symlink to it.
- On a fresh GitHub Actions runner you must run `moon update && moon install`
  before check/test — a populated local `.mooncakes` cache masks a missing
  install. To verify, wipe `.mooncakes` to simulate a fresh clone.
- Local `moon test` runs the `preferred target` from `moon.mod` (wasm-gc) and does
  not cover native; CI runs `test (native)` separately. Anything touching
  backends that differ (fs, CSV) must be self-tested with
  `moon test --target native`. (2026-10-09: a `scan_files` fixture built a nested
  `target/` with non-recursive `fs.create_dir`; local, JS and wasm-gc were green
  while CI native failed.)
- Recent `moon` (since 0.1.20261012) rejects dependencies that still ship the old
  `moon.mod.json` manifest: `moon install` unpacks as many dependencies as it can,
  then aborts during graph resolution. As of 2026-10-15 this project's dependency
  graph is clean (`moonbitlang/x@0.5.5` + `moonbitlang/quickcheck@0.15.0`; the two
  offenders were `quickcheck@0.14.0` and `mizchi/duckdb@0.6.4` pulled in
  transitively through `mizchi/parquet` — the former cleared by bumping to
  0.15.0, the latter by dropping the dependency once the in-house decoder landed).
  The "on install failure, migrate each directory with `moon fmt`" workaround in
  the three workflows has been removed: a stale-manifest dependency should fail
  **loudly**, so do not reintroduce that loop.
- `moon publish` validates a freshly unpacked copy in a temp directory (the same
  holds for `--dry-run`, which unpacks and runs `moon check`), so no migration or
  patching of `.mooncakes` in CI can rescue it: a single stale-manifest artifact
  anywhere in the dependency graph blocks the release. Gate releases with
  `moon publish --dry-run`. Note that after a successful dry run the CLI may still
  exit non-zero and print `Error: moon publish failed` — treat the
  `Server status: 202 ... Dry run completed successfully` line as the verdict.
- The file set in a release archive is decided **only** by `.gitignore` /
  `.moonignore`. Git's `.git/info/exclude` and the global git ignore config are
  never consulted (files kept out of git solely via `info/exclude` will be packed
  into the public archive), and a `.moonignore` in a directory replaces that
  tree's `.gitignore` (the two are not merged). Dot-prefixed paths are excluded by
  default at every depth, and the package-root `_build/` is always excluded.
  `moon package --list` is the only trustworthy preview.
- The same version of `moon fmt` rewrites `Int` to `Int32` in source (bare `Int`
  remains a valid alias and mixed styles compile even under `--deny-warn`), so any
  commit touching an `.mbt` file may drag that rewrite along.
- The cli.moonbitlang.com install script now reads `MOONBIT_INSTALL_VERSION` / the
  first positional argument (the old `MOONBIT_VERSION` env no longer works in CI),
  and the archive only serves `latest`: pinning any version, including the current
  one, returns 403, so the toolchain cannot be reinstalled at a pinned version. CI
  now installs `latest` and only records `moon version`, non-blocking, without a
  grep gate (2026-10-13).
