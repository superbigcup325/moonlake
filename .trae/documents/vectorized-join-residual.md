# 优化：hash join residual 向量化（q19 407ms → 预期 ~125ms）

## Context

22 条 TPC-H 全量基线（SF0.01, native, best-of-3）显示：lineitem CSV 摄取 ~110ms 构成 18/22 条查询的地板价；**q19 离群 415ms**。成本分解 + 等价改写对照实验（UNION ALL 三臂 145ms vs 官方 OR 407ms）锁定根因：

- 跨表 OR 谓词无法下推，整棵 OrE 树作为 `JoinStep.residual` 在 hash join 的 probe 循环里**逐候选行求值**
- `residual_passes`（[exec.mbt:1223](file:///home/cyanthus/repos/moonlake/engine/exec.mbt#L1223)）每对候选调用 `combined_row`（[exec.mbt:1296](file:///home/cyanthus/repos/moonlake/engine/exec.mbt#L1296)）——为每对候选**装箱两侧行的全部列**（q19：60k 对 × 25 列 Array[Scalar] 分配）再走 `eval_row`
- q19 = 60k 候选对 × ~24 节点 OR 树 × 全列装箱 ≈ 287ms

方案：**residual 预分解为臂，按侧预计算三值位图，仅跨侧合取式逐对求值**。Kleene 三值逻辑在 reassociation 下精确（∧=min、∨=max），语义与现状逐位等价。

## 现状关键事实（已核实）

- residual 在 Flat 布局（left ++ build）上引用列：`ColRef(i < left_width)` 为左、`i >= left_width` 为 build；`right_offset` 即左宽（binder.mbt:113-124, 1106）
- `eval_vec`（vec.mbt:9-124）Bool 结果 = `BoolV(data, valid)`，valid=false ⇒ NULL；kernel 与 `eval_row`/`eval_scalar` 镜像同一三值逻辑（logic_vec vec.mbt:445-480）；InSetE/LikeE/CaseE/FuncE/CastE 走 fallback 逐行但仍产 validity
- 现有 `eval_mask`（eval.mbt:496-514）折叠 unknown→false，不满足三值需求；**无现成 tri-state 工具**
- 六个调用点分属三函数，均以固定 (left_batch, build_batch) 在嵌套循环内逐对调用：join_step 1139/1183（INNER/LEFT/FULL，产出 id 对数组后 gather），join_semi 1404/1415（SEMI/ANTI），join_swapped 1503/1544（RIGHT，实参顺序 (build,id,probe,r)，"左槽"=acc 批）
- probe 信任 hash 相等不复查 key；NULL key 进不了候选
- 语义防线（改后必须全绿）：property_test.mbt:1022 join oracle（80 seeds，kinds 0-7 含跨表 residual 与 NULL 模型）、e2e_test.mbt:1176-1252 semi/anti/LEFT residual 组、harness/fuzz_pushdown.py（q19 形态 OR 对拍 duckdb）、22 条金标链

## 实施步骤（全部在 engine/exec.mbt，约 +150 行）

1. **分解器** `residual_plan(residual, left_width) -> ResidualPlan?`：
   - 顶层 OrE 链拆臂（非 OrE ⇒ 单臂）；臂内顶层 AndE 链拆合取式（非 AndE ⇒ 单合取式）
   - 每合取式按引用的 ColRef 下标分类：全 < left_width → Left 桶；全 ≥ → Build 桶；混合 → Spanning（保留 PhysExpr + 引用下标表）
   - 桶内多合取式用 `AndE` 合成一个子表达式；记录 `left_width` 供分类
   - 结构体：`ResidualPlan { arms : Array[ArmPlan] }`，`ArmPlan { left : PhysExpr?, build : PhysExpr?, spanning : Array[(PhysExpr, Array[Int32])] }`
2. **三值求值** `tri_state(e, batch) -> (FixedArray[Bool] /*true*/, FixedArray[Bool] /*unknown*/)`：
   - `eval_vec(e, batch)` → BoolV(d, v)：true[r] = v[r] && d[r]，unknown[r] = !v[r]
   - 非 BoolV ⇒ 逐行 fallback 兜底（同 eval_mask 的防御）
3. **状态准备** `ResidualState`：对每臂分别 eval 左/右批（各函数进入循环前算一次；build 批整步一份，左批每步一份——输入已 concat 整批）。空桶 = 恒 True
4. **逐对判定**（替换现 `residual_passes` 内核，签名加 plan/state 或改为方法）：
   - 编码 T=2/U=1/F=0；`pair = max over arms( min(L[lrow], B[brow], S(lrow,brow)) )`；通过 ⇔ pair==2
   - `S` = 该臂 spanning 合取式逐个 `eval_row` 于**仅含引用列的缩减行**（按下标表装箱，不再全列装箱），多合取式 min 合并；无 spanning = 2
5. **六个调用点**统一改走新路径；`join_swapped` 的 (build,id,probe,r) 槽位语义不变（plan 按调用点传入的首/次批分类，状态按对应批准备）
6. `residual_passes`/`combined_row` 旧路径删除（`combined_row` 若无其他引用则一并删）；`--explain` 的 residual 打印不受影响（JoinStep.residual 原样保留）

## 不做的

- join-key 等值冗余消除（spanning 里 `p_partkey=l_partkey` 对候选对恒真，可再省 ~3ms，非本轮）
- OR-to-UNION 改写、CSV 摄取 110ms 优化（独立工作流，后续单独立项）

## 验证

1. `moon test`（wasm-gc 默认）+ `moon test --target native` 全绿（join oracle 80 seeds 是主防线）
2. `bash harness/check_all.sh`：27 金标 byte-identical（q19 输出不变）
3. `uv run --with duckdb python harness/fuzz_pushdown.py`：300 棵谓词树对拍 duckdb
4. 基准前后对照（/tmp/decomp.py + harness/bench.py）：q19 407ms → 预期 ≤130ms（回到 ingest 地板）；q7（169ms，含跨表 OR）应同步受益；其余查询不回退
5. `moon info && moon fmt`，.mbti 应无可见变化（新函数均私有）
