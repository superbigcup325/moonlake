# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

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

## Known Pitfalls（实战沉淀，2026-10-02 自 agent 记忆迁入）

- moon fmt 曾把 README.md 替换成悬空软链吞内容；定式 = README.mbt.md 真身 + README.md 软链
- GitHub Actions fresh runner 必须先 `moon update && moon install` 再 check/test（本地 .mooncakes 缓存会掩盖，验证法 = wipe .mooncakes 模拟 fresh clone）
- 本地 `moon test` 走 `moon.mod` 的 preferred target（wasm-gc），不覆盖 native；CI 另跑 `test (native)`。改到 fs/CSV 这类后端有差异的路径必须 `moon test --target native` 自测（2026-10-09 实录：`scan_files` fixture 用 `fs.create_dir` 非递归建 `target/` 子目录，本地与 JS/wasm-gc 全绿、CI native 红）
- 新 moon（0.1.20261012 起）拒收仍带旧版 `moon.mod.json` manifest 的依赖，`moon install` 会在解包尽量多的依赖后于图解析阶段中止。**2026-10-15 起本项目依赖图已干净**（`moonbitlang/x@0.5.5` + `moonbitlang/quickcheck@0.15.0`；当时的两个 offender 是 quickcheck@0.14.0 与经 mizchi/parquet 传递引入的 mizchi/duckdb@0.6.4，前者升 0.15.0 解决、后者随 parquet 自研解码移除），三个 workflow 里的「install 失败就逐目录 `moon fmt` 迁移」绕过已撤掉——再出现旧 manifest 依赖应当**失败得响亮**，不要把绕过循环加回来
- **`moon publish` 的校验在解包后的临时目录里做全新解析**（`--dry-run` 同样解包并跑 `moon check`），CI 里对 `.mooncakes` 的任何迁移/修补都救不了它；依赖图里有一个旧 manifest 制品就发不出去。发布前用 `moon publish --dry-run` 当门：CLI 在 dry-run 成功后仍可能非 0 退出并打印 `Error: moon publish failed`，以 `Server status: 202 ... Dry run completed successfully` 那行为准
- **发布归档的文件集只由 `.gitignore` / `.moonignore` 决定**：`.git/info/exclude` 与全局 git ignore **一律不读**（只躺在 info/exclude 里的内部件会被打进公开包），同目录有 `.moonignore` 时替换该目录的 `.gitignore`（不合并），点开头路径默认全排除，包根 `_build/` 永久排除；`moon package --list` 是唯一可信预览
- 同版 `moon fmt` 会把源码里的 `Int` 规范改写为 `Int32`（`Int` 仍是合法别名，混合风格可编译过 `--deny-warn`），故任何 commit 触到 .mbt 文件都可能顺带带入该重写
- cli.moonbitlang.com 安装脚本已改读 `MOONBIT_INSTALL_VERSION`/首个位置参数（CI 旧 `MOONBIT_VERSION` env 失效），且归档只服务 latest，显式 pin 任何版本（含当前版号）都 403，工具链无法回装或钉版；CI 改为装 latest 并只记录 `moon version` 不做 grep 门禁（2026-10-13 实录）
