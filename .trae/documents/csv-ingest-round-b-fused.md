# 优化：CSV Round B — fused 单遍扫描+物化（105ms → 预期 ~80-88ms）

## Context

Round A（PR #12）后 ingest 剩 ~105ms，插桩定位：扫描段（offset 数组 + 字节循环）~42ms、物化段（二遍 offset 读 + parse/decode）~57ms。两遍结构的根因是类型推断需要先有 offset 视图。本轮把**物化融合进扫描单遍**：一次字节循环里逐 cell 直接 parse 进类型向量，消掉 starts/ends/quoted/rows 四个 offset 数组的写入（290 万次 push）、trim 拷贝与二遍读取。

语义网已确认（[scan_test.mbt](file:///home/cyanthus/repos/moonlake/sources/csv/scan_test.mbt) 覆盖引号/转义/CRLF/空行/BOM/分批/零行/glob 错误头），27 金标 + 双 target 测试兜底。

## 设计

### fused 状态机（新文件 [sources/csv/fused.mbt](file:///home/cyanthus/repos/moonlake/sources/csv/fused.mbt)）

`fused_batches(dtypes : Array[@types.DataType], buf : Bytes) -> Array[@types.DataBatch] raise @types.SqlError`

单遍逐字节（保留 unsafe_get，同 Round A）：逐 cell 分派到当前批的列向量（4096 行/批，BATCH_SIZE 复用）。关键语义逐条对齐现 scanner（[reader.mbt](file:///home/cyanthus/repos/moonlake/sources/csv/reader.mbt) `scan_csv`）：

- 引号 cell：`"` 进入引号态，`""` 折叠，闭引号后到分隔符的字节仍属 cell（lenient）；Str 用 `decode_range`（见下）去引号解码；**非 Str 类型 parse 的字节范围含引号**（与现状一致：带引号的数值 cell 报 scan error）
- 空 cell = 未引号空 或 裸 `""`（quoted && e-s==2）→ NULL
- CRLF：未引号 cell 末尾 `\r` 归属终止符（含 EOF 前的 `\r`，与现状一致）
- 空行：行仅含一个未引号空 cell → 跳过整行
- EOF 终止最后一行（无尾随换行也算行）
- 错误消息逐字对齐：`row \{r+2} column \{c}: cannot parse "\{decoded}" as <type>`（r 为 0-based 数据行）
- **行为变更（仅畸形输入）**：ragged 行不再跨行错位——短行缺列补 NULL、超长列忽略。现 scanner 对 ragged 输入会把下一行的 cell 错位读进本列（潜在 bug）。测试钉住新行为
- 零数据行 → 一个空批（列结构可见）

`RawCsv::decode` 重构：抽出 `decode_range(buf, s, e, quoted) -> String`（引号剥离 + `""` 折叠 + `@utf8.decode_lossy`），`RawCsv::decode` 变为薄包装，fused 直接用 decode_range。

### 类型推断走前缀（[scan.mbt](file:///home/cyanthus/repos/moonlake/sources/csv/scan.mbt)）

`infer_prefix(buf) -> (header, dtypes)`：`scan_csv(buf[:64K])`（BOM 已剥）→ 若 buf 比 64K 长则丢弃前缀最后一个数据行（可能被截断损坏）→ 复用现有 `infer_types`（前 100 行采样逻辑不变，只对小前缀跑，成本 ~1ms）。文件 ≤64K 时全量精确推断，语义不变；>64K 且 <100 数据行的病态文件丢 1 行采样（文档记录）。

### scan.mbt 接线

- `scan_bytes`：BOM → `infer_prefix` → `fused_batches` → entry
- `scan_files`：首文件同上；后续文件 dtypes 已知直接 fused（`validate_header` 改为只扫前 4K 取头行——头行必短，4K 无换行则回落全扫；glob 不再为验头付整文件扫描）
- **删除死代码**：`build_column` / `build_batch` / `build_entry` / `append_batches`（unsafe 版本随 fused 保留同构逻辑）；`infer_types` / `strip_bom` / `read_bytes` / `validate_header` 保留
- [reader.mbt](file:///home/cyanthus/repos/moonlake/sources/csv/reader.mbt)：`scan_csv` 保留（前缀推断 + validate_header 用），Grow 64k 起步与 unsafe push 不动

### 不做的

- validate_header 引号新行头 cell（病态，现有行为已如此）
- memchr/FFI 式分隔符跳跃（963k 次 FFI 调用开销抵消收益，实测前不做）
- 多线程/切片并行（MoonBit 无线程 API）

## 验证

1. scan_test 现有 8 个测试**原样全绿**（语义网）+ 新增 3 个：>64K 少行文件推断精确、ragged 行钉住新行为、带引号数值 cell 的 scan error 消息逐字对齐
2. `moon test` + `moon test --target native` 全绿
3. `bash harness/check_all.sh` 27 金标 byte-identical
4. A/B（min-of-9）：ingest 105 → 预期 ~80-88ms；`harness/bench.py` 22 条相应下移无回退；fuzz_pushdown 不受影响（无 CSV 变更面）
5. `moon info && moon fmt`；.mbti 预期无变化（scan_file/scan_string/scan_files 签名不动）
