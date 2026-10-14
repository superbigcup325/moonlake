# Spill M2：grace hash join（等值 join 落盘）

## Context

M1（已上线）把 ORDER BY 外排化了（[extsort.mbt](file:///home/cyanthus/repos/moonlake/engine/extsort.mbt)：`estimate_batch_bytes` + `RunWriter`（budget/4 flush）+ `to_spill_bytes` 序列化 + errdefer 清理）。[spill-survey.md §3](file:///home/cyanthus/repos/moonlake/docs/spill-survey.md) 既定里程碑：M1 排序 → **M2 hash join** → M3 聚合 → M4 集合操作；形态 B（算子自持外排 + 注入 SpillStore，engine 零 fs）。

现状缺口：join 的 build 侧 `concat_batches(right, ...)` 与 probe 侧 `acc`（此前 join 的物化输出）**无条件全内存**——两表 join 在 budget>0 时超预算即 OOM/失控，且 budget 对 join 完全未被消费（只有 ORDER BY 读它）。

本轮 = **grace hash join**：按 join key 哈希把两侧输入分区落盘，逐分区重跑现有内存 join。 survey 里程碑既定、M1 全部机制可复用。

## 设计

### 触发点（[exec.mbt](file:///home/cyanthus/repos/moonlake/engine/exec.mbt) `exec_joins` 循环 i>0）

```
acc_bytes = Σ estimate_batch_bytes(acc)
right_bytes = Σ estimate_batch_bytes(right)
budget > 0 且 acc_bytes + right_bytes > budget：
    spill = Some(store) → grace_join(acc, right, step, budget, store, stats)
    spill = None        → SqlError::Execute("join input exceeds memory budget …（给出 --memory/--spill-dir 提示）")
budget > 0 且不超 → 走现有内存 join_step（预算内即守约）
budget ≤ 0 → 现状不变
```

`exec_joins` 签名加 `opts : ExecOptions`（engine.mbt:171 调用点同步）；`join_step` 本体不动，grace 路径**逐分区调它**——INNER/LEFT/RIGHT/FULL/SEMI/ANTI/AntiLoose、residual（ResidualState 按分区对重建）、join_swapped 角色互换全部自动继承。

### grace 机制（新文件 [engine/extjoin.mbt](file:///home/cyanthus/repos/moonlake/engine/extjoin.mbt)，~200 行）

1. **分区数**：`P = clamp(2 × (acc_bytes + right_bytes) / budget, 2, 64)`（build 侧每分区 ≤ budget/2，留 probe 工作内存）
2. **分区落盘**：两侧各 P 个 `RunWriter`（复用 [extsort.mbt](file:///home/cyanthus/repos/moonlake/engine/extsort.mbt) 的 budget/4 flush 与 `to_spill_bytes`）。逐输入批：`eval_vec` 求一次 key 向量 → 每行算分区号 → 按分区聚合行号 → `take_rows` 逐分区切批 push。key 哈希与 join 等值语义一致：单 int key 用 Int64 值哈希、多 key 用既有 `canonical_key` 字符串哈希；NULL key 落任意固定分区（内存路径本就排除 NULL key 匹配，语义不变）
3. **逐分区回放**：读回该分区全部 run（`from_spill_bytes` + `concat_batches`，复用 M1 读回模式）→ `join_step(left_p, build_p, step)` → 累加输出 → `store.remove` 该分区文件（errdefer 全程兜底，对齐 extsort:265-281 模式）
4. **统计**：`stats.push(("spill partitions", P))`（对齐 M1 的 "spill runs"，explain_analyze 可见）

### 明确边界（M2 不做，错误消息写清）

- **无 key 的 join（CROSS / 笛卡尔）**：无法按 key 分区 → 超预算时报错（块式嵌套循环分区留 M4 后）
- **key 偏斜**：单 key 大分区超过 budget → 报错（grace hash 对偏斜无解，递归再分区是 M2 之后的演进）；P 由输入字节估算一次性选定，均匀分布下不触发
- hash agg spill = survey 的 M3，本轮不做

### 复用清单

`estimate_batch_bytes` / `RunWriter`（extsort.mbt:129-197）、`take_rows`（exec.mbt:43）、`to_spill_bytes`/`from_spill_bytes`（types/spillfmt.mbt）、`concat_batches`、errdefer 清理模式（extsort.mbt:265）、`eval_vec`。join_step 全家（含 M2 前刚落地的 residual 向量化）零改动。

## 验证

1. **等价性 property**（对齐 M1 的五形态模式，engine/property_test.mbt 或 e2e 新增）：同一 join 查询在 `in_memory` vs `tiny budget + mem_store` 下结果逐位一致——覆盖 INNER/LEFT/RIGHT/FULL/SEMI/ANTI + 跨表 residual + NULL key 七形态
2. **e2e**：合成 2 万行双表（超 tiny budget 强制 P>1）走 mem_store，count/sum 与内存版一致；倾斜单 key 报错消息；budget>0 无 spill 报错消息
3. `check_all.sh` 增加 join-spill 等价性检查（对齐 M1 的 spillorder 模式）
4. `moon test` 双 target + 27 金标（金标链无 --memory，不受影响）+ fuzz
5. `moon info && moon fmt`：.mbti 变化 = ExecOptions 无变化、新函数私有 → 应无外部可见变化
