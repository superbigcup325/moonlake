# 优化：CSV ingest Round A（目标 113ms → ~85-95ms）

## Context

22 条 TPC-H 全量基线 + 变体探针归因完成：**CSV 摄取 ~113ms（lineitem 60k 行 × 16 列 / 7.4MB）是 18/22 条查询的地板价**。分解：

- `scan_csv` 字节切分 ≈ 30-45ms（α≈4-7ms/MB：逐字节循环 + 每 cell 3 次 Grow push + 倍增拷贝 + trim）
- 物化 ≈ 80ms（~86ns/cell）：数值/日期 ~80-90ns、Str ~117ns（decode_lossy 每 cell 分配 FixedArray[UInt16]+String）
- parse_*_bytes 已是手写无分配字节循环（[bytes.mbt](file:///home/cyanthus/repos/moonlake/types/bytes.mbt)），不是瓶颈
- 已排除：parquet 式 SIMD（纯 MoonBit 不可用）、ASCII 快路径省 String 分配（省不掉最终 String，收益不确定）、fused 单遍（重构大、预估仅再省 10-15ms，**本轮不做**，留 Round B 依测量决策）

本轮 = 五项低风险微优化（[reader.mbt](file:///home/cyanthus/repos/moonlake/sources/csv/reader.mbt)、[scan.mbt](file:///home/cyanthus/repos/moonlake/sources/csv/scan.mbt)、[bytes.mbt](file:///home/cyanthus/repos/moonlake/types/bytes.mbt)），诚实预期 -15~25%。

## 实施步骤

1. **scan_csv 内循环收紧**（reader.mbt:161-168 等）：非引号字段循环每字节调 `buf[pos].to_int()` 两次（逗号、换行各判一次），改为单次读入局部再比较；引号尾随循环同理。语义不变（RFC-4180 路径原样）。
2. **Grow 容量起步 1024 → 64k**（reader.mbt:18/47）：963k cell 从 10 次倍增降到 4 次，省倍增增量拷贝；trim 保留（SF0.1 下 doubled 数组过大，trim 语义不变）。rows/starts/ends/quoted 四个 Grow 都改。
3. **build_column 热循环内联访问器**（scan.mbt:271-410）：`raw.row_start(r+1)` / `raw.is_empty_cell(i)` 方法调用替换为直读 `rows_data/starts_data/ends_data/quoted_data` 局部变量；空 cell 判定手工内联并**保持精确语义**（`s == e || (quoted && e - s == 2)`）。六个类型分支同构改写。
4. **parse_i32_bytes 专用快路径**（bytes.mbt:8）：≤9 位纯数字直接 Int32 累加（负号 + 上界 999999999 检查），其余（长数字/溢出边界）回落现有 parse_i64 路径，语义逐位等价。lineitem 4 个 i32 列 240k cell 受益。
5. **infer_types 早退**（scan.mbt:204-263）：每 cell 现在盲跑 5 个 parser；改为 `all_i32` 等五标志短路——flag 已 false 就不再跑该 parser（`if all_i32 && parse_i32_bytes(...) is None { all_i32 = false }` 等）。

## 不做的（依证据）

- fused 单遍扫描+物化（省 offset 数组与二遍，预估再 -10-15ms，重构触及类型推断顺序与引号语义，Round B 依本轮测量决策）
- Str decode 换 ASCII 手工解码（省不掉最终 String 分配，收益不确定）
- 引号内数值 cell 的潜在解析缺陷（`"5"` 会带引号进 parser）——现存行为，TPC-H 无此形态，单独 issue 化处理，不在性能 PR 混入

## 验证

1. `moon test`（wasm-gc）+ `moon test --target native` 全绿；sources/csv/scan_test.mbt 覆盖引号/空值/CRLF 语义
2. `bash harness/check_all.sh` 27 金标 byte-identical
3. 变体探针（/tmp/ingest_probe.py + /tmp/decomp.py）+ `harness/bench.py` 前后对照：ingest 113ms → 预期 ~85-95ms；22 条 TPC-H 相应下移且无回退
4. `moon info && moon fmt`，.mbti 无变化预期（全部私有路径）
