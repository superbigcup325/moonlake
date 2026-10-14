# 性能优化：ingest 双重解析与装箱、字符串哈希键、装箱拷贝路径

基线（当前 HEAD，SF0.01 bench）：q1 547 / q3 586 / q5 599 / q6 483 / q7 678 / q10 574 / q12 571 / q14 496 ms。静态成本分析：q6 只有一遍扫描+过滤+聚合，引擎计算应为个位数毫秒——**绝大头是 CSV ingest**（7.4MB → NyaCSV 逐 cell 96 万个 String → build_batch 再逐 cell parse 并装箱一个 `Scalar` 写入向量，又一个 96 万装箱点）。引擎侧次热点是 join/聚合每行的 `canonical_key` 字符串构造与 take_rows/concat 的装箱拷贝。

## Phase 0：测量基线（动手前先跑）

`exec --explain`（只付启动+ingest，不跑引擎）vs 全量运行，各 ×3，得出 ingest/引擎耗时占比；此后每个 Phase 结束复测一次，最后跑 bench A/B。一切以数字说话：如果实测推翻静态分析（ingest 占比不高），优先级就地重排。

## Phase 1：ingest 直写类型化向量（sources/csv/scan.mbt + types/vector.mbt）

- `build_batch` 改为直接构造 `I32/I64/F64/BoolV/StrV/DateV` 的 FixedArray 对，cell parse 后**直写数组**，validity 数组同步维护——消除每 cell 的 `Scalar` 装箱与 `set` 的双 match（SF0.01 少 ~96 万、SF0.1 少 ~960 万个临时 Scalar）。Str 列直接移动 NyaCSV 产出的 String，不再二次装箱。
- CLI 路径改 `read_file_to_bytes` + NyaCSV `parse_bytes`，BOM 剥离移到字节层（省一次 7.4MB 全文件 String 解码）；`scan_string` 保持 String 路径（库用户与 playground 桥不变）。
- 推断阶段不动（100 行样本，成本可忽略）。

## Phase 2：join/聚合的有类型哈希键（exec.mbt）

- `join_step` 单键 fast path：键恰一列且类型 Int32/Int64（binder 已提升为同型）→ `Map[Int64, Array[Int]]` 直接读列值哈希，跳过 `canonical_key` 字符串构造；NULL 键用 validity 判断，语义与字符串键严格等价。多键/字符串键走原路径。TPC-H 全部连接键都是单整型列。
- `aggregate` 单整型组键同理（`Map[Int64, Int]`），多组键/字符串组键回退。

## Phase 3：消除装箱拷贝（exec.mbt）

- `take_rows`（filter 压缩 + order/limit 共用）复用已有 typed `gather`，替换逐 cell 装箱 get/set。
- `concat_batches` 按 variant 写类型化拷贝循环（join 两侧拼接是 join-heavy 查询的必经路径）。

## Phase 4：闸门 + A/B + 文档

- 三 target 77/77、TPC-H 双 scale 15/15、q6/q3 explain 探针。
- bench A/B（SF0.01；若 SF0.1 单次可接受也顺带跑，75MB 文件对 ingest 优化最敏感）+ README 基准表 + CHANGELOG。
- 提交按 Phase 切 3~4 个，pre-commit 闸门逐个过，不 push。

## 明确不做（本轮）

- 替换/分叉 NyaCSV（每 cell String 是依赖边界内的地板；README 生态叙事把 CSV 解析定位在 NyaCSV，换库需你拍板另立事项）
- 并行/多线程（wasm 目标不可用，破坏单一代码库承诺）
- 位图 validity、列式编码、数学内核 micro-opt（覆盖面/收益比不划算）
