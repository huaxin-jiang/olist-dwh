# 数据导入说明

## 一、这一步做了什么

| 动作      | 说明                                                      |
| ------- | ------------------------------------------------------- |
| 分析文件格式  | 换行符、BOM、空值分布、内嵌换行                                       |
| 编写预处理脚本 | `sql/00_prepare_data.py`，产出 `data/import/`              |
| 复制到导入目录 | `D:/ENV/MySQL/DATA/Uploads/olist/`（secure-file-priv 限制） |
| 编写导入脚本  | `sql/03_load_data.sql`，9 张表逐个导入 + 校验                    |

---

## 二、导入前必须知道的 4 个坑（都已在脚本中处理）

### 坑 1：评价表有 4,003 条评论含内嵌换行

**现象**：`olist_order_reviews_dataset.csv` 物理行数 105,764，但真实记录只有 100,000 条  
→ 有 5,764 个换行符藏在评论内容里。

**后果**：`LOAD DATA` 按 `\n` 切分行，会把一条评论切成两条半，导致字段错位、  
甚至整表导入失败。

**处理**：预处理脚本把字段内的 `\r\n` / `\n` / `\r` 统一替换为空格。  
（原始文件保持不变，只在 `data/import/` 下生成干净副本）

> **要点**：CSV 里「带引号的多行文本」是数据导入的经典陷阱。>   
> 处理思路只有两条：用支持引号转义的解析器（如 Python csv 模块、数据库原生 CSV 解析），>   
> 或者入库前把换行归一化。

### 坑 2：空字符串写入数值/时间列会报错

**现象**：

- `ods_orders` 三个时间列分别有 160 / 1,783 / 2,965 个空值
- `ods_products` 有 610 个空值（品类、名称长度等）、2 个空值（重量尺寸）

**后果**：MySQL 严格模式（`STRICT_TRANS_TABLES`）下，  
`''` 写入 `DATETIME` 报 **ERROR 1292**，写入 `INT` 报 **ERROR 1366**。

**处理**：用用户变量接收原始值，再 `NULLIF(@var, '')` 转成 NULL：

```sql
LOAD DATA INFILE '...'
INTO TABLE ods_orders
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(@order_id, @customer_id, @status, @purchase, @approved, @carrier, @delivered, @estimated)
SET order_approved_at = NULLIF(@approved, '');   -- 空串 → NULL
```

> **要点**：`NULLIF(a, b)` 等价于 `CASE WHEN a = b THEN NULL ELSE a END`，>   
> 常用于「空字符串转 NULL」这种数据清洗场景。

### 坑 3：翻译表带 BOM 头

**现象**：`product_category_name_translation.csv` 前三字节是 `EF BB BF`（UTF-8 BOM）。

**后果**：第一列名会变成 `\ufeffproduct_category_name`，无法与表中的列对应。

**处理**：

- 预处理脚本用 `encoding='utf-8-sig'` 自动剥离 BOM
- 导入时 `IGNORE 1 LINES` 跳过表头，双重保险

### 坑 4：secure-file-priv 限制文件位置

**现象**：`LOAD DATA INFILE '项目路径/xxx.csv'` 报 **ERROR 1290**  
（The MySQL server is running with the --secure-file-priv option）。

**原因**：MySQL 出于安全考虑，只允许从 `secure-file-priv` 指定目录读取文件。  
你的配置是 `D:/ENV/MySQL/DATA/Uploads`。

**处理**：把文件复制到该目录下的 `olist/` 子目录。

> **要点**：`secure-file-priv` 的作用是防止攻击者通过 SQL 读取服务器上的>   
> 任意文件（如 `/etc/passwd`、配置文件）。生产环境应设为专用导入目录，>   
> 且该目录不应有敏感文件。

---

## 三、为什么用 LOAD DATA INFILE 而不是 LOCAL INFILE

| 方式                       | 文件由谁读取             | 速度         | 权限要求                                   |
| ------------------------ | ------------------ | ---------- | -------------------------------------- |
| `LOAD DATA INFILE`       | **MySQL 服务进程**     | 快（本地磁盘直读）  | 需 `FILE` 全局权限 + 文件在 secure-file-priv 内 |
| `LOAD DATA LOCAL INFILE` | **客户端**（Navicat 等） | 慢（逐行经网络传输） | 需客户端和服务端都开启 `local_infile`             |

本机数据库与文件同机，用 `INFILE` 更合适，也贴近生产实践。

**注意**：`FILE` 是**全局权限**，`GRANT ALL ON olist_db.*` 不包含它。  
需由 root 执行一次：

```sql
GRANT FILE ON *.* TO 'olist_dev'@'localhost';
FLUSH PRIVILEGES;
```

> 只对**实际存在的账号**授权。若没有创建 `'olist_dev'@'127.0.0.1'`，>   
> 对它执行 GRANT 会因账号不存在而失败（这是正常现象，不是配置错误）。

---

## 四、操作步骤

1. **用 root 账号**执行上面三行 GRANT（只需一次）
2. 切到 `olist_dev` 连接
3. 执行 `sql/03_load_data.sql` 全文
4. 看最后一张校验表，9 行数字应与「期望行数」完全一致

**预计耗时**：1-3 分钟（geolocation 100 万行占大头）

---

## 五、报错对照表

| 报错                                                     | 原因                                                                      | 解决                                                                      |
| ------------------------------------------------------ | ----------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| ERROR 1290 (secure-file-priv)                          | 文件不在指定目录                                                                | 确认文件在指定目录                                                               |
| ERROR 29 (File not found)                              | 路径写错或用反斜杠                                                               | 用正斜杠 `/`，检查文件名拼写                                                        |
| **ERROR 1045 (Access denied ... using password: YES)** | **不是密码错！** 是缺 FILE 权限。`LOAD DATA INFILE` 的权限检查返回的错误码就是 1045，消息模板与密码错误相同 | root 执行 `GRANT FILE ON *.* TO 'olist_dev'@'localhost';`，或直接用 root 跑导入脚本 |
| ERROR 1227 (needs FILE privilege)                      | 同类问题，部分版本返回此码                                                           | 同上                                                                      |
| ERROR 1292 (Incorrect datetime)                        | 空串写入 DATETIME                                                           | 用 `NULLIF(@var,'')`                                                     |
| ERROR 1366 (Incorrect integer)                         | 空串写入 INT                                                                | 同上                                                                      |
| ERROR 1261 (Row doesn't contain data for all columns)  | 列数与文件不匹配                                                                | 检查字段列表顺序                                                                |
| **ERROR 1062 (Duplicate entry ... for key 'PRIMARY')** | **数据源的主键字段实际不唯一**。评价表 `review_id` 有 802 个重复值                            | 改用联合主键 `(review_id, order_id)`，见 `03b_修复reviews表.sql`                   |
| 行数比预期少                                                 | 有内嵌换行导致切分错位                                                             | 确认用的是 `data/import/` 下的文件                                               |
| 行数比预期多                                                 | 有重复导入                                                                   | 确认 TRUNCATE 已执行                                                         |

> **关于 1062 的处理思路**：不要第一反应就 `DELETE` 重复行或加 `IGNORE` 跳过。>   
> 先查清楚「到底哪个字段组合才是真正唯一的」。>   
> 本项目实测：`review_id` 有 802 个重复，但 `(review_id, order_id)` 组合 100,000 条全唯一>   
> → 用联合主键可以**一行都不丢**地保留全量数据。
>
> ODS 原始层的职责是忠实保存，去重是清洗层（DWD）的决策。这个边界感是数据工程的基本功。

> **排查原则**：`1045` 出现在**连接时**才是账号/密码问题；>   
> 出现在**连接成功、执行某条语句时**，是语句级权限检查，>   
> 与密码无关。不要因为看到「using password: YES」就去改密码。

> **实践建议**：导入这类批量运维操作由高权限账号（root）执行，>   
> 日常查询与分析用受限账号（olist_dev）。这正是「最小权限原则」的正确用法。

---

## 六、加速技巧（可选，第 6 步会深入）

百万行的 geolocation 带索引插入较慢。两种优化：

1. **先删索引、导入后再建索引**
   ```sql
   ALTER TABLE ods_geolocation DROP INDEX idx_geo_zip;
   -- 导入
   ALTER TABLE ods_geolocation ADD INDEX idx_geo_zip (geolocation_zip_code_prefix);
   ```
   原理：B+ 树索引在插入时需要不断调整结构（页分裂），先建索引可避免这个开销；     
   批量建索引比逐行维护快得多。
2. **调大 `innodb_buffer_pool_size`**     
   当前 128M，偏小。若机器内存充足，可调到 1G 以上（物理内存的 50%-70%）。

---

## 七、设计问答

1. `LOAD DATA INFILE` 和 `LOAD DATA LOCAL INFILE` 有什么区别？
2. 什么是 `secure-file-priv`？为什么要限制？
3. `NULLIF` 的作用是什么？在数据清洗里怎么用？
4. 大批量导入如何加速？至少说出 3 种方法。
5. CSV 里有内嵌换行和逗号，如何正确解析？
6. `TRUNCATE` 和 `DELETE` 的区别？为什么导入前用 TRUNCATE？
7. 严格模式（STRICT_TRANS_TABLES）有什么作用？关掉它有什么风险？
8. 为什么空字符串不能直接写入 DATETIME 列？

---

## 八、★ 转义陷阱：少 10 行 + 数据静默损坏（已修复）

这是这一步最有价值的一个坑，务必看懂。

### 现象

`ods_order_reviews` 导入后只有 **99,990 行**（应为 100,000），且：

| 指标            | 实际     | 期望      | 差值      |
| ------------- | ------ | ------- | ------- |
| 总行数           | 99,990 | 100,000 | **-10** |
| review_id 唯一数 | 99,163 | 99,173  | **-10** |
| order_id 唯一数  | 99,431 | 99,441  | **-10** |

三个数同时少 10 → 说明是 **10 条互相独立的记录整段消失**，不是去重合并。

### 定位过程

1. 导出数据库全部 `(review_id, order_id)`，与源文件做差集 → 定位到缺失的是**文件里连续的 10 行**（第 78547–78556 行）。
2. 检查这 10 行前一行（78546）的原始字节，发现评论结尾是：
   ```
   não chegou nada :\"      ← 反斜杠紧挨着结束引号
   ```
3. 查数据库里第 78546 行那条记录，评论字段长度**异常膨胀到 1,487 字符**，尾部是     
   `4e4167b83a370,5,,"Ainda não posso opinar...` —— 后面 10 行的原始文本被整段吞了进来。

### 根因

`LOAD DATA` 默认 `FIELDS ... ESCAPED BY '\\'`，**把反斜杠当转义符**。

MySQL 看到 `\"` 就认为这是「被转义的双引号」，不认它作字段结束符，于是继续往下找闭合引号——一路吃到第 78556 行的 `"`，把这中间的 10 条记录全塞进了一条评论里。

### 同一个雷的第二个受害者：sellers 表

`sellers` 文件里有一条城市名写成 `rio de janeiro \rio de janeiro`（源数据把 `/` 打成 `\`）。

MySQL 把 `\r` 解析成**回车符**，存进库里变成：

```
rio de janeiro  + 0x0D + io de janeiro
```

**行数没少，但数据被静默改坏了** —— 这种问题比少 10 行更危险，因为它不会触发任何报警，只有逐字段核查才能发现。

### 全部文件的反斜杠扫描结果

| 文件                              | 反斜杠数 | 危险组合 `\"`     |
| ------------------------------- | ---- | ------------- |
| olist_order_reviews_dataset.csv | 9    | **1** ← 元凶    |
| olist_sellers_dataset.csv       | 1    | 0（但 `\r` 被吃掉） |
| 其余 7 个文件                        | 0    | 0             |

### 修复方案

在 `LOAD DATA` 中显式声明 **`ESCAPED BY ''`**（空字符串）＝ **关闭转义语义**：

```sql
LOAD DATA INFILE '...'
INTO TABLE ods_order_reviews
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(...);
```

**为什么不改源文件？** 因为数据本身是标准 CSV——引号内的引号用 `""` 双写表示，不依赖反斜杠转义。关掉转义后，`\"` 被正确解析为「反斜杠字符 + 字段结束引号」，**忠实还原源数据**，符合 ODS 层「不改动原始数据」的职责。

### 修复结果（已实测）

| 校验项             | 修复前      | 修复后           |
| --------------- | -------- | ------------- |
| 总行数             | 99,990   | **100,000** ✅ |
| review_id 唯一数   | 99,163   | **99,173** ✅  |
| order_id 唯一数    | 99,431   | **99,441** ✅  |
| 78546 那条评论长度    | 1,487 字符 | **65 字符** ✅   |
| 缺失的 10 条        | 0        | **10** ✅      |
| sellers 城市名 hex | 含 `0D`   | 含 `5C`（反斜杠）✅  |

修复脚本：`sql/03c_修复转义问题.sql`

### 实现说明

> 导入评价表时发现少了 10 行，但不报错、无 WARNING。我用源文件记录数比对定位到缺失的是连续 10 行，追查发现前一行评论结尾有 `\"`，MySQL 默认 `ESCAPED BY '\'` 把它当成转义引号，导致引号配对错乱、后续 10 行被整段吞掉。修复方式是显式声明 `ESCAPED BY ''` 关闭转义语义。
>
> 顺带发现 sellers 表有同类问题：`\r` 被解析成回车符，行数没少但数据被静默改坏。

**这段话的价值**：区分了「报错」和「静默失败」——静默失败才是数据工程里最危险的，只能靠行数校验和字段核查发现。

---

## 九、空串 vs NULL：三个字段的空值不统一（已修复）

导入后发现有三个文本字段的空值是 `''`（空字符串）而不是 `NULL`：

| 字段                             | 空值条数   | 修复前  | 修复后      |
| ------------------------------ | ------ | ---- | -------- |
| products.product_category_name | 610    | `''` | `NULL` ✅ |
| reviews.review_comment_title   | 88,285 | `''` | `NULL` ✅ |
| reviews.review_comment_message | 58,245 | `''` | `NULL` ✅ |

**原因**：CSV 里的空字段被解析成 `''`。脚本中其他字段都用了 `NULLIF(@var,'')`，但这三个文本字段漏了，直接赋值。

### 为什么这不是小事（真实的分析陷阱）

`''` 和 `NULL` 语义完全不同：

|              | `''`    | `NULL`       |
| ------------ | ------- | ------------ |
| 含义           | 有值，值是空  | 值未知 / 不存在    |
| `COUNT(col)` | **算进去** | 不算           |
| `IS NULL`    | 查不到     | 能查到          |
| `col = ''`   | 为真      | 为 NULL（三值逻辑） |

具体后果：

1. **商品品类完整度会算成 100%**（610 个空被当作有品类），真实值是 **98.15%**
2. **`WHERE product_category_name IS NULL` 查出 0 条**，但那 610 条明明缺失
3. **评论率虚高**：`COUNT(review_comment_message)` 会把 58,245 个空串算成「有评论」

### 修复方式

直接 `UPDATE ... SET col = NULL WHERE col = ''`，比重新导入快，且不影响主键和行数。  
脚本：`sql/03d_空串转NULL.sql`；`03_load_data.sql` 中对应字段已加 `NULLIF`，保证以后重跑一致。

### 实现说明

> 导入完成后我做了空值分布核查，发现三个文本字段的空值是 `''` 而非 `NULL`。这两者语义不同：`''` 是「有值但为空」，`NULL` 是「值未知」，而 `COUNT()` 只跳过 `NULL` 不跳过 `''`。如果不修，算「商品品类完整度」会得到 100%，而真实值是 98.15%；算「评论率」也会虚高。
>
> 所以数据导入后不能只看行数，还要核对空值的**存储形态**。

---

## 十、状态

- [x] 文件格式分析完成
- [x] 预处理脚本完成并执行（4,003 处换行已修正）
- [x] 文件已复制到 secure-file-priv 目录
- [x] 导入脚本完成（已补 `ESCAPED BY ''`）
- [x] **九张表全部导入完成，行数校验 9/9 通过**
- [x] 转义陷阱已定位并修复（`03c_修复转义问题.sql`）
- [x] 空串统一转 NULL（`03d_空串转NULL.sql`）
- [ ] 下一步：**第 4 步数据清洗**

### 最终行数（全部 OK，合计 1,551,698 行）

| 表                        | 行数        |
| ------------------------ | --------- |
| ods_geolocation          | 1,000,163 |
| ods_order_items          | 112,650   |
| ods_order_payments       | 103,886   |
| ods_order_reviews        | 100,000   |
| ods_orders               | 99,441    |
| ods_customers            | 99,441    |
| ods_products             | 32,951    |
| ods_sellers              | 3,095     |
| ods_category_translation | 71        |
