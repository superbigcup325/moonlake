# moonlake 正确性与性能验证报告

> 2026-10-06 · 验证弧的沉淀。目标：超越「SF0.01 + 1e-9 相对容差对拍」的
> 表层证据，对向量化、哈希连接、谓词下推给出可复现的规范化验证，并给出
> 性能、内存、溢出、并发、边界的实证数字。所有条目可按文中命令复现。

## 1. 向量化（eval_vec vs 标量解释器）

**方法**：随机性质测试（`engine/property_test.mbt`）。种子化生成器构造
**类型一致**的随机物理表达式树——覆盖全部六种列类型（I32/I64/F64/Str/
Bool/Date），比较与 IS NULL 只作为 Bool 生成、EXTRACT 只作为 Int32、
CASE 分支与目标同型；每列按约 1/9（Str/Bool 为 1/7）布点 NULL。断言
`eval_vec` 与 `eval_scalar` **逐格相等**（值 + NULL 位置），批长覆盖
`0/1/2/3/5/17/4095/4096/4097`（含扫描批大小 4096 及其 ±1 邻居）。两侧
均为 NaN 时视为相等（0/0 合法），其余必须精确一致。60 case × 每case
4 个表达式。

**变异验证**（证明性质有牙）：
- `cmp_vec` 的 Lt/Gt 对调 → 7 个测试失败、性质被证伪 ✓
- `arith_vec` 的 I32 Sub 改为 Add → 性质被证伪 ✓
- 还原后 93/93 全绿。

**开发中顺带修复**：生成器初版把 IsNullE/ExtractE 按任意类型生成
（引擎无错，生成器违反类型纪律），两次证伪均定位为生成器 bug——
性质测试的证伪必须先审生成器再审引擎，这一纪律被记录在案。

## 2. 哈希连接（嵌套循环 oracle 对拍）

**方法**：性质测试内置朴素嵌套循环连接 oracle，对八种连接形态逐格对拍：
inner / LEFT+ON 残差 / LEFT+WHERE 跨表残差 / RIGHT / FULL / semi(EXISTS) /
anti(NOT EXISTS) / anti(NOT IN)。键分布三种病态模式：重复密集（域 {0,1,2}
+ 30% NULL）、散布（近唯一）、近全 NULL（仅 1 个非空键）；残差为跨表
`b.w > a.v`（50% 开关）。80 case。

**变异验证**：把 anti 保留规则 `!matched && (!null_key ||
!null_key_excludes)` 砍成 `!matched` → 性质被证伪 ✓；还原后全绿。

**oracle 直接抓到并修复的真 bug**（`0f03d28`）：
`NOT EXISTS` 在相关键为 NULL 时被 anti join 按 NOT IN 的三值逻辑丢弃。
DuckDB 仲裁：`c=(1,10),(2,NULL),(3,30)`、`o=(10,5)` 时 NOT EXISTS 应返回
{2,3}，修复前 moonlake 返回 {3}。根因：`JoinKind::Anti` 把两种否定语义
混为一谈。修复引入 `AntiLoose`（NOT EXISTS：只有真匹配才丢行；NOT IN：
NULL 探测键为 UNKNOWN 丢弃）。TPC-H 22 条发现不了它——所有相关键非空。

**边界测试**（`engine/e2e_test.mbt`）：
- 批边界 4095/4096/4097 行 ×（过滤 / 分组 / 自连接扇出），模型对拍
- int64 极值键（±2^63-1）哈希互不混淆；NULL 键不匹配；字面量比较
- `parse_f64` 精确性修复（`09539e5`）：十进制累加器把 **2^63**（恰好可被
  double 精确表示）解析到邻居值，`k = -9223372036854775808` 返回 0 行而
  `k >=` 同字面量返回 1 行。现在 ≤20 位十进制整数经 UInt64 精确转换
  （正确舍入），更宽的输入保持 1e-9 相对契约

## 3. 谓词下推（随机差分 vs DuckDB）

**方法**：`harness/fuzz_pushdown.py`——在 INNER/LEFT 连接图（a-b-c，键域
0..40，含 NULL 键）上生成 2–5 个合取项的随机 WHERE 树：单表比较/IN/
BETWEEN/LIKE/IS NULL、跨表等式与非等式、带隐含连接键的 OR（Q19 形状），
逐条与 DuckDB 对拍（1e-9 容差，NULL 语义对齐）。**300 条随机查询：
300/300 一致，0 引擎拒绝**（种子 20261005，可复现）。

**变异验证**：把保留侧守卫（LEFT WHERE 逃逸修复 `5aa02c4`）禁用后，
150 条内即被抓住——失败形状恰为「LEFT JOIN + WHERE 形式跨表等式」：
`... LEFT JOIN c ON b.k2 = c.k2 WHERE c.s IS NULL AND b.k2 = a.k1`，
moonlake -9753 vs duckdb -7743。fuzzer 特意包含该判别性模板（WHERE 形式
跨表等式是 key 放置 vs 延迟过滤唯一可区分的形状）。

## 4. 溢出与边界（定义语义钉死）

`engine/e2e_test.mbt` 溢出电池 + `types/types_test.mbt`：
- CSV 推断越界即加宽：2147483648 保持精确（Int64）、9223372036854775808
  转 Float64——**从不回绕**
- 字面量算术回绕为**定义语义**：2147483647+1 → -2^31；9223372036854775807+1
  → -2^63
- 除法恒为 DOUBLE：`x/0` → ±inf、`0/0` → nan；`%0` → NULL
- 越界 CAST = 干净的 bind 错误（绝不回绕）
- 月份运算月尾钳制：1996-03-31 + 1 month = 1996-04-30

**已记录的边界限制**（文档化行为，非 bug）：
1. 全空 CSV 列推断为 STRING——全 NULL 键列之间无法连接（类型错误拒绝，
   不静默错答）
2. SELECT 列表的裸 NULL 需要类型上下文（用 `CAST(NULL AS T)`）
3. 含超 int64 值的整列整体推断为 Float64——行级精确性受列类型约束

## 5. 性能与内存

`harness/measure.py`（native 二进制直接测量，非 `moon run`；隔离子进程
`getrusage(RUSAGE_CHILDREN)` 取 maxRSS；best-of-3）：

| 查询 | SF0.01 | SF0.1 | 时间比 | RSS SF0.01 | RSS SF0.1 |
|---|---|---|---|---|---|
| q1（聚合扫全表） | 198 ms | 2099 ms | 10.6x | 41.3 MB | 370.6 MB |
| q6（选择性过滤） | 140 ms | 1476 ms | 10.5x | 41.3 MB | 370.3 MB |
| q5（6 表连接） | 167 ms | 1813 ms | 10.9x | 47.3 MB | 405.4 MB |
| q2（相关标量子查询） | 24 ms | 281 ms | 11.7x | 13.3 MB | 67.2 MB |
| q17（相关聚合子查询） | 161 ms | 1727 ms | 10.7x | 41.3 MB | 377.2 MB |
| 摄入（lineitem LIMIT 0） | 142 ms | 1374 ms | 9.7x | 41.1 MB | 377.2 MB |

结论：时间与内存对数据量**近线性**（10 倍数据 → 8.5–11.7 倍时间、~9 倍
内存）；全量物化（eager）的架构使 RSS ≈ 数据体量的常数倍（SF0.1 约
370 MB / 60 万行 lineitem）。测试机：本地 Linux，单次运行，数字为该机
参考值。复现：`moon build cmd/main --target native && python3
harness/measure.py`。

## 6. 并发

- **全局状态审计**：engine/types/catalog/sources 无任何包级可变全局
  （`let mut` 顶层 / `Ref` / 原子变量均为零）。`execute(sql, catalog)`
  的全部状态在调用栈内——库形态的线程安全契约 = 每线程独立 Catalog
  （或外部同步共享只读 Catalog）。
- **并行进程确定性**：8 个并发 CLI 进程对同一数据集执行 q5，输出
  md5 全部一致（1 个唯一哈希）。
- MoonBit 语言层未向用户暴露线程原语，进程内并行不在契约范围。

## 7. 复现命令

```bash
moon test                                            # 111 项（含全部性质）
uv run --with duckdb python harness/gen_tpch.py      # SF0.01 数据+金标准
bash harness/check_all.sh                            # 23 goldens
uv run --with duckdb python harness/gen_tpch.py 0.1  # SF0.1
MOONLAKE_DATA=harness/data/sf01 bash harness/check_all.sh
uv run --with duckdb python harness/fuzz_pushdown.py 300 20261005
moon build cmd/main --target native
python3 harness/measure.py sf001 sf01
```
