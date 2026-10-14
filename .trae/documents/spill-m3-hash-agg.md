# Spill M3：grace hash aggregation（GROUP BY 落盘）

## Context

M1（ORDER BY 外排）与 M2（grace hash join，[extjoin.mbt](file:///home/cyanthus/repos/moonlake/engine/extjoin.mbt)）已上线。survey 既定里程碑的下一站：**M3 聚合 spill**。现状缺口：GROUP BY 的 `aggregate()`（[exec.mbt:454-724](file:///home/cyanthus/repos/moonlake/engine/exec.mbt#L454)）把全部输入 + 组状态放在内存——budget 对聚合完全未被消费。

核心洞察（与 M2 同构）：**按 group key 哈希分区 ⇒ 同一组的所有行落同一分区 ⇒ 每分区的聚合结果就是最终结果**——不需要 combine/merge 阶段，median/string_agg/count-distinct 等不可合并 accumulator 也天然正确（它们的状态永远不跨分区）。

## 设计

### 触发点（[engine.mbt:179-186](file:///home/cyanthus/repos/moonlake/engine/engine.mbt#L179)）

```
bq.aggregate 且 group_exprs 非空 且 budget > 0 且 joined 字节 > budget：
    spill Some → grace_agg(...)；spill None → SqlError::Execute（提示 --spill-dir/--memory）
其余（全局聚合无 GROUP BY、budget 内、budget≤0）→ 现有 aggregate() 原路径
```

全局聚合（无 GROUP BY）不走分区：它是逐行流式折叠、状态 O(聚合数) 有界（median/string_agg 的全局状态例外，文档记录为现存边界）。

### grace_agg（新文件 [engine/extagg.mbt](file:///home/cyanthus/repos/moonlake/engine/extagg.mbt)，~120 行）

1. `P = clamp(4 × joined_bytes / budget + 1, 2, 64)`（对齐 M2 公式，每分区 ≈ budget/4）
2. **分区写入**：逐输入批复用 M2 的 `partition_side(batch, group_exprs, writers)`（[extjoin.mbt](file:///home/cyanthus/repos/moonlake/engine/extjoin.mbt)——group_exprs 同样是 joined 扁平列空间上的 PhysExpr，`eval_vec` 直接可用）；P 个 `RunWriter`（budget/4 flush）
3. **逐分区回放**：`read_partition` 读回 → 非空则 `aggregate(part, group_exprs, group_types, aggs)`（**复用现聚合，组状态不跨分区**）→ out；分区输入字节 > budget → SqlError::Execute（组 key 偏斜/预算过小）
4. **拼接**：`concat_batches(out, dtypes)`，dtypes 取自第一个非空分区输出的列类型（布局 = group_types ++ 各 agg out_type，天然一致）；errdefer 全程清理 spill 文件（对齐 extsort/extjoin 模式）
5. **统计**：`stats.push(("spill partitions", P))`
6. 空分区跳过（P > 组数时正常发生）；触发路径要求 joined 非空，故 out 至少一个非空分区

### 接线

`engine.mbt` 聚合分支改为经 `aggregate_within_budget(joined, group_exprs, group_types, aggs, opts, stats)` 分发（新函数放 extagg.mbt）：budget≤0 / 无 GROUP BY / 预算内 → 现有 `aggregate()`；超预算有 store → grace_agg；无 store → 报错。HAVING/projection/ORDER BY 下游零改动（分区输出布局与 aggregate 完全一致）。

### 明确边界

- **单 key 偏斜**：一个组的输入字节超预算 → 报错（组状态无法再分；median/string_agg 状态随行数增长，字节估算已覆盖）
- **全局聚合**（无 GROUP BY）：不 spill（流式状态有界；median/string_agg 全局状态例外 = 现存行为）
- GROUP BY + 无 ORDER BY 的**行顺序**：分区序 ≠ 内存哈希序——本就未定义（无 ORDER BY 的组行序不承诺），测试一律 ORDER BY 组列

### 复用清单

`partition_side`（M2）、`RunWriter`/`estimate_batch_bytes`（M1）、`read_partition` 模式（M2）、`aggregate()` 本体、errdefer 清理模式。aggregate 本体与下游零改动。

## 验证

1. **等价性 e2e**：GROUP BY 查询族（count/sum/min/max/median/string_agg/count-distinct 混合 + 含 NULL 组 key + HAVING）in-memory vs tiny-budget+mem_store 逐行比对（ORDER BY 组列定序）
2. **20k 行 × 97 组**：budget 64K 强制 P≈50，每组跨 ~206 行但只落一个分区——sum/count/median 与内存版一致
3. 错误路径：无 spill 报错；单 key × 5000 行 median 偏斜报错
4. `check_all.sh` 新增 **spillagg 检查**（lineitem GROUP BY l_returnflag 聚合，plain vs --memory 200K，compare.py 比对）
5. `moon test` 双 target 全绿 + 27 金标（金标链无 --memory 不受影响）+ bench 无回归 + `moon info && moon fmt`（新函数私有，.mbti 应无变化）
