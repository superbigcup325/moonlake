# 超内存处理方案调研：形态对比（外排设计前哨）

> 2026-10-04。目标不是定设计，而是把"查询数据超过内存"这个问题上各家
> 的处理形态摸清，为 moonlake 的外排（spill）设计稿圈定落点。
> 背景数字见 `docs/verification.md` §5：内存随数据近线性，SF0.1 ≈ 353 MB，
> 外推 SF1.0 ≈ 3.5 GB——当前架构下超内存即不可查询。

## 1. 六个系统的速写

**DuckDB**（进程内 OLAP，C++）。`memory_limit`（默认约物理内存 80%，软
限制）+ `temp_directory`。超预算时算子把中间块溢写继续跑：radix 分区的
并行外存 hash join、hash 聚合（分区落盘出口归并）、外归并排序、窗口。
关键默认：**file-backed 库默认 spill 开**（temp 目录 = 库文件旁 `.tmp`）；
**`:memory:` 库 temp_directory 默认为空 = 不落盘，超了直接报错**，除非
显式给目录。外部 CSV/Parquet 流式扫描不整体进内存；持久库基表走磁盘
存储 + buffer manager。

**PostgreSQL**（服务端，行存迭代器）。教科书形态：每个执行节点受
`work_mem` 约束，超了在算子内部降级——hash join 分 batch（build 侧按
哈希落盘、probe 对齐同 batch）、排序走 tuplesort 的 run 生成 + 多路
归并、hash agg 分区。临时数据进 `base/pgsql_tmp`。预算是 per-node 的
会话设置，没有全局统一记账。

**ClickHouse**（服务端列存）。同样算子自持：`max_bytes_before_external_sort`
/ `max_bytes_before_external_group_by` 是**按算子**的设置（而非全局
limit），超了把排序/聚合状态写到 `tmp_path`（可配 disk policy），出口
归并。聚合超阈值时部分状态落盘再合并，是和 Postgres 同族但按算子配
参的变体。

**Apache DataFusion**（进程内列式，Rust——与 moonlake 架位最像）。
MemoryPool **预留制**：算子先申请内存，池子给不出就 spill 后重试；池子
有 fair/untracked/greedy 几种策略。落盘统一走 SpillManager/DiskManager
抽象，spill 文件就是 Arrow IPC（49.0 起支持压缩）。成熟轨迹值得抄作业：
**排序先落地**（50.0 宣称"几乎所有排序查询不再 OOM"），**hash join spill
到 2025-08 还是 proposal**（#17267），聚合的中间归并可留在盘上直到最终
回放。

**Polars**（进程内 DataFrame，Rust）。代表第三条路：不改算子、改执行
模型。新流式引擎（Polars 2.0 起 default）按有界批推进整个流水线，内存
天然有界，超内存靠流式本身 + 落盘兜底。成熟度教训同样有价值：多 join
链内存累积的 issue（#24206）至今开放，早期流式引擎"比 DuckDB/DataFusion
更早 OOM"的社区反馈说明这条路的工程深度。

**SQLite**（嵌入式，页存）。形态最另类：没有算子级 spill 概念，一切
数据（含临时 B 树、排序中间态）都是页，pager 统一管理；cache 不够时
脏页写回、临时对象进 temp 文件（`temp_store` 可选 default/file/memory）。
代价是必须先有页式存储引擎——这本身就是它的产品形态。

## 2. 形态对比

| | 触发模型 | 落盘位置 | 覆盖算子 | 需要存储引擎？ | 前提重构 |
|---|---|---|---|---|---|
| DuckDB | 全局 soft limit | temp 目录 | join/agg/sort/window | 持久库需要（buffer manager） | 无（内存库也可 spill） |
| PostgreSQL | per-node work_mem | pgsql_tmp | join/sort/agg | 否 | 无 |
| ClickHouse | per-op 设置 | tmp_path/disk policy | sort/agg | 否 | 无 |
| DataFusion | MemoryPool 预留制 | SpillManager（Arrow IPC） | sort（成熟）→ agg → join | 否 | 无 |
| Polars 流式 | 有界批 + 流式调度 | 流式框架兜底 | 全流水线 | 否 | **整个执行模型** |
| SQLite | 统一页缓存 | pager 页写回 | 全部（隐式） | **是**（页引擎是前提） | 全部 |

归纳为四种形态：

- **A 统一页缓存**（SQLite、DuckDB 持久库）：算子无感知，存储层兜底。
  前提是页式存储引擎——等于先成为数据库。
- **B 算子自持外排**（Postgres、ClickHouse、DuckDB 内存库、DataFusion）：
  阻塞算子超预算自己分桶/归并，预算接口 + 临时文件抽象注入。不需要
  存储引擎，增量可落地。
- **C 有界流式**（Polars 新引擎）：重写执行模型为有界批流式，落盘只是
  兜底。能力上限最高，重构面最大，成熟坑最多。
- **D 纯内存 + 明确失败**（各家内存库默认、moonlake 现状）：语义诚实，
  是 A/B/C 的回退态，不是终点。

## 3. moonlake 的落点论证（约束 → 形态）

moonlake 的约束：进程内库 + native CLI 双发布、wasm/js playground 必须
可编译（engine 包零 fs 依赖是既有纪律）、纯列式批、eager 全物化、
"不是数据库"的边界声明。

- **形态 A 出局**：页式存储引擎违反产品边界，且 wasm 目标要跟着背。
- **形态 C 出局（现阶段）**：推翻 eager 执行模型相当于重写引擎；Polars
  的现状证明这条路的成熟曲线以年计。
- **形态 B 是唯一自然落点**：预算句柄 + 临时文件抽象注入（engine 保持
  零 fs，native CLI 注入真实现，wasm 侧落在形态 D"明确失败"）——
  DuckDB 内存库"默认不落盘、显式给目录才开"的语义与这个双目标天然同构。
- **里程碑排序有现成背书**：DataFusion 用了多年才让排序 spill 成熟、
  hash join 2025 年仍是提案。moonlake 的 M1 排序 → M2 hash join →
  M3 聚合 → M4 集合操作 的次序与其一致，不是保守，是现实。
- **落盘格式的 moonlake 特有问题**：DataFusion 复用 Arrow IPC，moonlake
  没有现成列式序列化。候选：(a) 自写精简批序列化（可控、无依赖）；
  (b) **直接用 mizchi/parquet 的 writer/reader 当 spill 格式**——零新
  序列化代码、自带列式压缩，且外排 run 天然对应行组（将来上游接了
  #4 的行组级读取，spill 回放也受益）；代价是引入 writer 成熟度与
  编码开销的权衡。这是设计稿里真正要拍板的点。
- **基表物化问题独立于形态 B 存在**：即便算子都会 spill，扫描层整表
  物化仍是内存大头。设计稿需决定扫描懒化的范围（外部文件按批供数即可，
  不动 catalog 语义）还是先以"算子 spill + 大表走查询内多次扫描"过渡。

## 4. 设计稿的接续点

专场起草时从三个拍板点切入：① 预算注入的接口形状（DataFusion 预留制
vs DuckDB 全局软限制的 moonlake 简化版）；② spill 文件格式（自写 vs
parquet 复用）；③ 扫描懒化的最小范围。验证策略沿用仓库惯例：小预算
强制 spill 对 TPC-H 金标准逐位比对 + spill/内存等价 property + measure.py
maxRSS 封顶验证。
