# Olist 电商订单数据仓库：从原始 CSV 到查询优化的完整链路

> 一个用 MySQL 8.0 从零搭建的电商数据仓库实践项目。>   
> 数据源为 Olist（巴西电商平台）公开脱敏数据集，覆盖 2016-09 ~ 2018-10 共 99,441 笔订单。>   
> 全部表结构、SQL、踩坑记录均可复现。

---

## 一、项目要解决的问题

拿到一份 9 个 CSV、150 万行的原始电商数据，交付一份**能被业务方直接用于决策**的分析结论，并且保证：

1. 每个指标的口径都说得清"为什么这么定"
2. 每个数字都能追溯到具体 SQL
3. 每条查询在生产数据量下不会崩

这不是一个"跑通几个 SQL"的练习。项目里真正的价值在于**三次"不报错但算错"的排查**（见第五节）——数据工程里最危险的不是报错，是静默失败。

---

## 二、数据规模

| 层   | 表                        | 行数            | 说明                 |
| --- | ------------------------ | ------------- | ------------------ |
| ODS | ods_orders               | 99,441        | 订单主表               |
| ODS | ods_order_items          | 112,650       | 订单明细（一单多行）         |
| ODS | ods_order_payments       | 103,886       | 支付流水（一单可多笔）        |
| ODS | ods_order_reviews        | 100,000       | 评价                 |
| ODS | ods_customers            | 99,441        | 客户（customer_id 粒度） |
| ODS | ods_products             | 32,951        | 商品                 |
| ODS | ods_sellers              | 3,095         | 卖家                 |
| ODS | ods_geolocation          | 1,000,163     | 邮编坐标（百万行）          |
| ODS | ods_category_translation | 71            | 品类葡→英映射            |
|     | **小计**                   | **1,551,698** |                    |
| DWD | dwd_orders               | 99,441        | 订单事实（含延迟标记）        |
| DWD | dwd_order_items          | 112,650       | 明细事实（含金额口径）        |
| DWD | dwd_payments             | 99,440        | 支付事实（按订单聚合）        |
| DWD | dwd_reviews              | 99,441        | 评价事实               |
| DIM | dim_customer             | 96,096        | 客户维（unique_id 去重）  |
| DIM | dim_product              | 32,951        | 商品维（品类已翻译）         |
| DIM | dim_seller               | 3,095         | 卖家维                |
| DIM | dim_geolocation          | 19,015        | 地域维（邮编前缀聚合）        |
|     | **总计**                   | **2,113,827** |                    |

> 说明：`dwd_reviews` 99,441 ≠ ODS 的 100,000。原因是同一订单存在多条评价——100,000 条评价只对应 99,441 个 `order_id`，DWD 层按订单粒度去重后差 559 条。另：`review_id` 有 827 个重复值（`COUNT(DISTINCT review_id)` = 99,173），这正是 ODS 表主键必须设为联合主键 `(review_id, order_id)` 的原因——用单一 `review_id` 做主键会在导入时触发 1062 报错并丢行。

---

## 三、分层设计

```
CSV (9 files, 1.55M rows)
   │  LOAD DATA LOCAL INFILE（预处理：剥离 BOM、修复 4003 处内嵌换行）
   ▼
ODS  ── 原样入仓，不做任何转换。目的是"出问题时能回到原点重跑"
   │  清洗：空串转 NULL、日期标准化、类型统一、去重、派生标记
   ▼
DWD  ── 事实表，一行一个业务事件，含派生指标（is_late / late_days / item_total）
   │
DIM  ── 维度表，一行一个实体，必须做唯一性校验（防 JOIN 膨胀）
   ▼
分析查询（11 个业务问题）
   │  EXPLAIN → 索引设计 → A/B 测量
   ▼
优化结果（3.1 倍 / 13 倍）
```

**为什么先落 ODS 再清洗，而不是直接导入干净表？**

因为清洗规则一定会改。项目里清洗脚本改了 4 版（`03b` ~ `03d` 三次修复 + `06a` 一次口径修正），每次都要重跑。如果原始层被覆盖，就只能重新下载。ODS 层的成本是"多占一份空间"，换来的是"清洗逻辑可反复迭代"。

---

## 四、业务发现（5 个可直接汇报的结论）

### 1. 复购率 3.04% 里有 29% 是假的

按 `customer_id` 算复购率恒为 0（每个订单一个 customer_id）；改用 `customer_unique_id` 得 3.04%。但拆开复购间隔后发现 **928 次"复购"发生在同一天**——那是同一笔购买因商品来自不同卖家被拆成多单，不是复购。

剔除拆单后真实复购率 **2.17%**，98% 的客户只买一次。

> 业务含义：这个平台没有复购红利。预算不该投在会员体系，该投在拉新效率和新客首单体验上。

### 2. 配送延迟 3 天是差评的断崖点

| 延迟情况      | 订单数    | 平均评分     | 差评率        |
| --------- | ------ | -------- | ---------- |
| 准时/提前     | 89,672 | 4.28     | 9.52%      |
| 延迟 1-3 天  | 1,869  | 3.28     | 32.42%     |
| 延迟 4-7 天  | 1,802  | **2.09** | **68.04%** |
| 延迟 8-15 天 | 1,637  | 1.67     | 80.21%     |

延迟 3 天内差评率 32%，到第 4 天直接跳到 68%——**不是线性下降，是断崖**。超过 7 天后见顶（80%），说明客户已彻底失望，再多延迟也不会更差。

> 结论：物流预警阈值应设在"预计延迟第 3 天"，此时还有挽回空间。

### 3. 物流优化优先级不能按延迟率排，要按"延迟率 × 订单量"

| 州      | 订单数        | 延迟率        | 影响面（延迟单数） |
| ------ | ---------- | ---------- | --------- |
| SP     | 41,005     | 4.50%      | 1,845     |
| **RJ** | **12,653** | **12.15%** | **1,537** |
| AL     | 397        | **21.41%** | 85        |

AL 延迟率全国最高（21.41%），但只有 397 单；RJ 延迟率 12.15%，却有 1.2 万单。**改善 RJ 一州的物流，影响面是 AL 的 18 倍。**

### 4. 15.8% 的客户贡献了 29.4% 的收入，且已流失一年

RFM 分层后发现「重要流失预警」客群：14,984 人（15.82%），平均消费 307.97 元（全站均值的 1.9 倍），但平均 **394 天**没下单。这群人贡献了 29.4% 的历史收入，是召回 ROI 最高的对象。

与之对比，「一般流失客户」22,898 人（24.18%）但平均消费仅 72.74 元——召回成本不划算。**分层运营的核心就是区分这两类流失客户。**

### 5. 品类差评要先排除物流因素，再归因商品

`office_furniture` 差评率 21.88%（全站 15.03%），但延迟率 8.09% 只略高于全站 6.77%——**物流解释不了 1.46 倍的差评差距**，问题在商品本身（组装复杂／实物不符／运输损坏）。

判断方法：对比"该品类延迟率 vs 全站延迟率"。差评高但延迟正常 → 不是物流问题。

---

## 五、三个"不报错但算错"的问题（本项目最有价值的部分）

这三个 bug 的共同点：SQL 正常返回、结果看起来合理、结论完全错误。

### 坑 1：留存率全是 0，SQL 一声不响

```sql
-- 错误写法
PERIOD_DIFF(DATE_FORMAT(o.purchase_ts,'%Y%m'),
            DATE_FORMAT(f.cohort_month,'%Y%m'))
```

`cohort_month` 已经是 `'2017-01'` 字符串，`DATE_FORMAT('2017-01','%Y%m')` **返回 NULL 而不是报错**，`PERIOD_DIFF` 跟着返回 NULL，所有月份编号都不等于 1/2/3，留存率全部算成 0。

```sql
-- 正确写法
PERIOD_DIFF(DATE_FORMAT(o.purchase_ts,'%Y%m'), REPLACE(f.cohort_month,'-',''))
```

**发现方式**：留存率不可能全为 0（哪怕是垃圾数据也会有随机重合）。是"结果违反业务常识"触发的排查，不是报错触发的。

### 坑 2：延迟订单的平均超时是 −8.7 天

```sql
-- 错误写法：把 88,644 条提前送达的负值也平均进去了
AVG(o.late_days)
```

`AVG()` 会平均整列，不会自动过滤。一个"延迟订单平均超时"的指标算出负数——**分母不是你以为的那群人**。

```sql
-- 正确写法
AVG(CASE WHEN is_late = 1 THEN late_days END)
```

### 坑 3：is_late 和 late_days 自相矛盾

清洗时 `is_late` 用时间戳比较（`delivered_ts > estimated_ts`），`late_days` 用 `DATEDIFF`。而 `estimated_ts` 的时间部分是 `00:00:00`，所以**当天下午送达**会得到 `is_late = 1` 但 `late_days = 0`。

实测 1,292 单（占延迟订单 14.2%）属于这种矛盾。修正后延迟率 **8.11% → 6.77%**。

**交叉校验**：`SUM(is_late=1 AND late_days<=0)` 必须等于 0。同一个业务概念在两个字段里用了不同口径，是最隐蔽的数据质量问题。

---

## 六、性能优化

### 6.1 方法论：毫秒级耗时会骗人

同一个查询冷缓存 vs 热缓存能差 3 倍以上：

| 查询               | 首次（冷）  | 稳定（热）  |
| ---------------- | ------ | ------ |
| `DATE_FORMAT` 过滤 | 0.104s | 0.031s |

把冷启动的 0.104s 和热态的 0.0025s 对比会得出"快 42 倍"——**这是假的**。

本项目采用两条纪律：

1. **A/B/A/B/A/B 交替执行 3 轮取中位数**（不是 AAA 再 BBB）
2. **以 `EXPLAIN` 的 `type` / `rows` 为主要证据**，耗时作辅助

`rows` 是优化器的确定性估算，换机器结论不变。"扫描行数从 98,267 降到 14,030"比"快了 13 倍"更经得起追问。

### 6.2 优化 1：消除 N+1 相关子查询（0.90s → 0.29s）

```sql
-- 问题写法
SELECT o.order_id,
       (SELECT COUNT(*) FROM dwd_order_items i WHERE i.order_id = o.order_id),
       (SELECT SUM(i.item_total) FROM dwd_order_items i WHERE i.order_id = o.order_id)
FROM dwd_orders o;
```

`EXPLAIN` 显示 `select_type = DEPENDENT SUBQUERY`，单次 `rows=1` 很快——但 `DEPENDENT` 意味着**外层每一行都触发一次**：

> 98,267 订单 × 2 个子查询 = **196,534 次独立查询**>   
> × 每次固定开销约 4.5μs ≈ **0.88s**

耗时几乎全部来自调用次数，不是数据量。这就是 N+1。

```sql
-- 优化写法：一次聚合 + 一次连接
SELECT o.order_id, i.cnt, i.amt
FROM dwd_orders o
LEFT JOIN (SELECT order_id, COUNT(*) cnt, SUM(item_total) amt
           FROM dwd_order_items GROUP BY order_id) i
  ON o.order_id = i.order_id;
```

| 指标         | 优化前                    | 优化后                 |
| ---------- | ---------------------- | ------------------- |
| 耗时（3 轮中位数） | 0.903s                 | **0.287s（3.1 倍）**   |
| 执行次数       | 196,534 次索引查找          | 2 次表扫描              |
| 执行计划       | DEPENDENT SUBQUERY × 2 | DERIVED（覆盖索引）+ JOIN |

**一次失败的尝试也记录在案**：直接 `JOIN + GROUP BY` 不建派生表，实测 0.33s，比派生表写法（0.29s）更慢——99,441 个分组要建临时表。**不是所有"看起来更简洁"的改写都更快，改完必须测。**

### 6.3 优化 2：消除函数包裹导致的索引失效（0.031s → 0.0025s）

| 写法                                               | type      | key             | rows       |
| ------------------------------------------------ | --------- | --------------- | ---------- |
| `DATE_FORMAT(purchase_ts,'%Y-%m')='2017-11'`     | **ALL**   | NULL            | **98,267** |
| `purchase_ts >= '2017-11-01' AND < '2017-12-01'` | **range** | idx_purchase_ts | **14,030** |

索引明明存在却完全用不上——B+ 树里存的是原始值，不是 `DATE_FORMAT` 之后的字符串。

扫描行数降 85.7%，耗时降 12.4 倍。

> 注意：这个查询只用了 31ms，按"慢查询 >1s"的标准完全正常。**它是全表扫描，但看起来不慢。** 数据量涨 100 倍它就是 3 秒——这就是必须看 `EXPLAIN` 而不能只看耗时的原因。

### 6.4 8 类索引失效场景实测（含 2 条辟谣）

| # | 场景              | 失效写法                       | type / rows    | 结论                    |
| - | --------------- | -------------------------- | -------------- | --------------------- |
| 1 | 函数包裹列           | `DATE_FORMAT(ts,'%Y-%m')=` | ALL / 98,267   | ✅ 确实失效                |
| 2 | 隐式类型转换          | `varchar_col = 1037`       | ALL / 19,288   | ✅ 确实失效                |
| 3 | 前导模糊            | `LIKE '%table%'`           | index / 32,915 | ✅ 确实失效                |
| 4 | OR 跨未索引列        | `state='SP' OR city='x'`   | ALL / 95,532   | ✅ 确实失效                |
| 5 | `!=` / `NOT IN` | `status <> 'delivered'`    | range / 2,963  | ❌ **辟谣：没失效**          |
| 6 | 跳过最左前缀          | `month = 11`               | range / 9,826  | ⚠️ **有 Skip Scan 兜底** |
| 7 | 列参与运算           | `cnt + 1 > 2`              | index / 95,532 | ✅ 确实失效                |
| 8 | 选择性过低           | `is_delivered = 1`         | ref / 49,133   | ⚠️ 用了索引等于没用           |

**辟谣 1：`!=` 和 `NOT IN` 在 MySQL 8 上不会失效。** 优化器会改写成 `< x OR > x` 两个区间。真正的规律是**代价驱动**：

```
status <> 'delivered'   → range / 2,963    （排除的少，索引很好用）
status != 'canceled'    → range / 49,135   （排除了 50%，扫半张表，索引形同虚设）
```

**辟谣 2：跳过最左前缀，MySQL 8.0.13+ 有 Skip Scan。** 前导列基数极低时（本例 `purchase_year` 只有 3 个值），优化器会枚举前导值逐个跳查，`Extra: Using index for skip scan`。但换成高基数前导列立刻退化：

```sql
-- PRIMARY(order_id, order_item_id)，order_id 基数 98,666
WHERE order_item_id = 1  →  type=index, rows=111,435  ← 退化为全索引扫描
```

**最左前缀原则依然成立，只是 MySQL 8 在特定条件下提供了兜底。**

### 6.5 反例：加了一个"看起来合理"的索引，慢了 15%

多表查询里有 `is_delivered = 1 AND purchase_date BETWEEN ...`，直觉上该建复合索引：

```sql
ALTER TABLE dwd_orders ADD INDEX idx_deliv_date (is_delivered, purchase_date);
```

| 状态   | 3 轮耗时                            | 中位数             |
| ---- | -------------------------------- | --------------- |
| 加索引前 | 0.65 / 0.70 / 0.65               | **0.68s**       |
| 加索引后 | 0.71 / 0.76 / 0.78 / 0.84 / 0.79 | **0.78s（−15%）** |

原因：查一下过滤条件能筛掉多少数据——

```sql
SELECT COUNT(*) FROM dwd_orders
WHERE purchase_date BETWEEN '2017-01-01' AND '2018-08-31';  -- 99,092
```

**99,092 / 99,441 = 99.65%。** 第二列（`purchase_date`）没有任何过滤能力，索引退化成只有第一列有用；而 `is_delivered` 只有 2 个值，选择性 0.002%。多出来的索引页还挤占了 buffer pool。

已 `DROP INDEX`。

> **"这个列在 WHERE 里" ≠ "这个列该建索引"。** 判断标准是选择性：`不同值个数 / 总行数`，低于 10% 单独建索引基本没有价值。

### 6.6 最终只加了 1 个索引

| 索引                                             | 动作    | 理由                               |
| ---------------------------------------------- | ----- | -------------------------------- |
| `idx_item_order_amount (order_id, item_total)` | 新增    | 让派生表实现覆盖索引扫描（`Using index`），避免回表 |
| `idx_deliv_date (is_delivered, purchase_date)` | 新增后删除 | 第二列无过滤能力，实测慢 15%                 |
| 其余                                             | 保留    | 服务于主键/外键连接与高频过滤                  |

这不是保守，是实测结论——**在这个数据量和查询模式下，真正的瓶颈是查询写法，不是索引缺失。**

---

## 七、目录结构

```
olist-dwh/
├── sql/                              15 个脚本，按文件名序号执行
│   ├── 00_prepare_data.py            预处理：剥离 BOM、修复 4,003 处内嵌换行
│   ├── 00_create_user.sql            建应用账号（只读 + 最小权限）
│   ├── 00b_fix_account.sql           账号连不上时的诊断与三种修复方案
│   ├── 01_create_database.sql
│   ├── 02_create_tables.sql          9 张 ODS 表（含字段类型与主键选择）
│   ├── 03_load_data.sql              9 段 LOAD DATA（含 ESCAPED BY ''）
│   ├── 03b_fix_reviews_pk.sql        复合主键修复（review_id 有重复）
│   ├── 03c_fix_escape.sql            反斜杠转义修复（吞行问题）
│   ├── 03d_empty_to_null.sql         空字符串转 NULL
│   ├── 04_cleaning.sql               8 张 DWD / DIM，含口径定义
│   ├── 05_verify_cleaning.sql        清洗前后校验
│   ├── 06_business_queries.sql       业务查询：留存 / RFM / 延迟 / 品类
│   ├── 06a_fix_late_metric.sql       延迟口径修正（标记与天数对齐）
│   ├── 07_index_invalidation.sql     8 类索引失效复现 + 2 条辟谣
│   └── 08_benchmark.sql              优化前后 A/B 基准测试
├── docs/                             设计说明与结论，对应实施各阶段
│   ├── 01_schema_design.md           字段类型 / 主键 / 索引的设计理由
│   ├── 02_data_loading.md            导入报错对照表（1045、1062、1261…）
│   ├── 03_data_cleaning.md           8 张表的清洗规则与校验口径
│   ├── 04_business_analysis.md       业务结论与每个指标的口径来源
│   └── 05_performance_tuning.md      EXPLAIN 分析 + 优化前后对比
├── .gitignore
├── LICENSE
└── README.md
```

原始 CSV 未纳入版本库（合计约 123 MB）。数据获取方式见第八节。

---

## 八、如何复现

**前置：获取数据**

数据源为 Olist 公开数据集（Kaggle）：<https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce>

下载后把 9 个 CSV 放入 `data/`，并在 `sql/03_load_data.sql` 中确认 `LOAD DATA` 的绝对路径与本地一致。


```bash
# 1. 建库建表
mysql -u root -p < sql/01_create_database.sql
mysql -u root -p olist_db < sql/02_create_tables.sql

# 2. 预处理（必须执行：剥离 BOM + 修复 4,003 处内嵌换行，否则行数必然错乱）
python sql/00_prepare_data.py

# 3. 导入（需 FILE 全局权限，或把数据目录加入 secure-file-priv）
mysql -u root -p --local-infile=1 olist_db < sql/03_load_data.sql

# 4. 校验 ODS 行数（9 张表合计应为 1,551,698）
mysql -u olist_dev -p olist_db -e "
SELECT 'ods_orders', COUNT(*) FROM ods_orders UNION ALL
SELECT 'ods_order_items', COUNT(*) FROM ods_order_items UNION ALL
SELECT 'ods_order_payments', COUNT(*) FROM ods_order_payments UNION ALL
SELECT 'ods_order_reviews', COUNT(*) FROM ods_order_reviews UNION ALL
SELECT 'ods_customers', COUNT(*) FROM ods_customers UNION ALL
SELECT 'ods_products', COUNT(*) FROM ods_products UNION ALL
SELECT 'ods_sellers', COUNT(*) FROM ods_sellers UNION ALL
SELECT 'ods_geolocation', COUNT(*) FROM ods_geolocation UNION ALL
SELECT 'ods_category_translation', COUNT(*) FROM ods_category_translation;"

# 5. 清洗，生成 4 张事实表 + 4 张维度表
mysql -u olist_dev -p olist_db < sql/04_cleaning.sql

# 6. 校验清洗结果（延迟率应为 6.77%，DWD 合计 410,972 行）
mysql -u olist_dev -p olist_db < sql/05_verify_cleaning.sql

# 7. 业务查询（留存 / RFM / 延迟与评分 / 品类）
mysql -u olist_dev -p olist_db < sql/06_business_queries.sql

# 8. 索引失效场景复现 + 优化前后 A/B 基准测试
mysql -u olist_dev -p olist_db < sql/07_index_invalidation.sql
mysql -u olist_dev -p olist_db < sql/08_benchmark.sql
```

> 步骤 3 若报 `ERROR 1045 (using password: YES)`，**多数情况不是密码错**，而是账号缺少 `FILE` 权限——两种错误的返回码和消息模板相同。排查过程见 `docs/02_data_loading.md`。

**导入环节的三个必要动作**（不做必然出错，详见 `docs/02_data_loading.md`）：

1. `ESCAPED BY ''` —— 否则评价内容里的 `\"` 会被当成转义序列，连续吞掉多行（本项目实测吞掉 10 行）
2. 所有可能为空的字段包 `NULLIF(@var, '')` —— 否则空值被存成空字符串，`IS NULL` 查不到
3. 预处理剥离 UTF-8 BOM —— 否则第一个字段名带不可见字符，`LOAD DATA` 报列不存在

---

## 九、已知局限（主动说明）

1. **单机 MySQL，未涉及分布式组件。** 本项目在 MySQL 8.0.43 单实例上完成，未使用 Hive / Spark / Flink。数据量 155 万行，属于"单机能跑但已能暴露写法问题"的规模。千万级以上需要列存 + 分布式，是下一步的学习方向。
2. **Windows 环境。** 开发在 Windows 上完成（MySQL 8.0.43 Windows 版）。目录结构、权限模型、`my.ini` 配置与 Linux 一致，但服务管理方式不同（Windows 服务 vs systemd），**未做过 Linux 上的实例部署与运维**。
3. **延迟与差评只能证明相关，不能证明因果。** 延迟 4-7 天差评率 68%，但可能存在混淆变量（偏远地区订单既慢、商品质量也可能更差）。要证因果需控制品类和价格带分层对比，或做 A/B 测试。
4. **公开数据集，非真实业务系统。** 没有上游系统对接、没有增量同步、没有调度。数仓的"工程"部分（调度、血缘、数据质量监控）本项目未覆盖，只覆盖了建模、清洗、口径、优化这条分析链路。

---

## 十、技术栈

MySQL 8.0.43（窗口函数 / CTE / `EXPLAIN ANALYZE` / Skip Scan）、SQL（`LOAD DATA`、多表 JOIN、窗口函数、CTE、相关子查询）、Python（仅用于 CSV 预处理）、Windows 环境下的 MySQL 运维（`my.ini` 参数调整、`secure-file-priv`、用户与权限管理）。
