# 表结构设计说明

> 项目：Olist 电商订单数据分析平台>   
> 数据库名：`olist_db`>   
> 存储引擎：InnoDB　字符集：utf8mb4　排序规则：utf8mb4_general_ci

---

## 一、整体设计思路

### 分层设计（这是数仓思维的雏形）

```
原始层 (ods_*)     —— 与 CSV 字段一一对应，不做任何加工，原样导入
    ↓
清洗层 (dwd_*)     —— 去重、补空、类型规范、建立外键关系
    ↓
分析层 (dws_*)     —— 指标汇总表（第 5 步再做）
```

**为什么要分层？** 设计评审常问。三个理由：

1. **可追溯**：原始数据保留不动，清洗规则出错时能回溯重跑
2. **可复现**：每次重跑清洗脚本都能得到相同结果
3. **职责清晰**：出问题时能快速定位是"数据源问题"还是"加工逻辑问题"

**这一步先建 9 张 `ods_` 原始表**（第 4 步再建 `dwd_` 清洗层）。

---

## 二、字段类型设计（设计重点，逐个讲理由）

### 通用规则

| 类型              | 什么时候用          | 为什么                   |
| --------------- | -------------- | --------------------- |
| `VARCHAR(n)`    | ID、名称、状态等变长字符串 | 不定长，省空间               |
| `CHAR(n)`       | 州缩写（固定2位）、邮编前缀 | 定长，查询更快               |
| `INT`           | 序号、数量          | 整数                    |
| `DECIMAL(10,2)` | **金额**         | **精确小数，绝不丢精度**        |
| `DECIMAL(11,8)` | 经纬度            | 需要高精度小数位              |
| `DATETIME`      | 时间戳            | 范围 1000-9999 年，不受时区影响 |
| `TINYINT`       | 评分（1-5）        | 极小整数，省空间              |

### 【设计要点 1】订单 ID 为什么用 VARCHAR 而不是 INT？

Olist 的 `order_id` 形如 `e481f51cbdc54678b7cc49136f2d6af7`，是一个 **32 位的十六进制字符串**（MD5 风格）。

**为什么不用 INT/BIGINT？**

- 字符串里含 `a-f` 字母，不是纯数字，`INT` 根本存不了
- 就算能转成数字，32 位十六进制 = 128 bit，`BIGINT` 只有 64 bit，**存不下**
- 业务上订单号不用自增数字，是为了**防爬取和防猜测**（自增 ID 能被遍历）

**为什么不用 CHAR(32)？**

- 可以，但 `VARCHAR(32)` 更通用（万一以后 ID 长度变短不浪费空间）

### 【设计要点 2】金额为什么用 DECIMAL 而不是 FLOAT/DOUBLE？

这是数据库设计里的**经典问题。**

```sql
-- FLOAT/DOUBLE 是浮点数，二进制存不下精确十进制小数
SELECT 0.1 + 0.2;  -- 某些数据库返回 0.30000000000000004

-- DECIMAL 是定点数，按十进制精确存储
-- 金额必须精确，差一分钱都是事故
```

**结论**：凡涉及**金额、价格、数量**，必须用 `DECIMAL(M,D)`。

- `M` = 总位数，`D` = 小数位数
- `DECIMAL(10,2)` 表示最多 10 位数字，其中 2 位小数 → 最大 `99999999.99`

### 【设计要点 3】DATETIME 还是 TIMESTAMP？

|      | DATETIME                | TIMESTAMP               |
| ---- | ----------------------- | ----------------------- |
| 存储空间 | 8 字节                    | 4 字节                    |
| 时间范围 | 1000-01-01 ~ 9999-12-31 | 1970-01-01 ~ 2038-01-19 |
| 时区   | **不受影响**，存什么读什么         | **受时区影响**，会转换           |
| 适用   | 业务时间（下单时间、签收时间）         | 记录行的创建/更新时间             |

**本项目选 DATETIME**：订单时间是业务事件时间，不能被时区悄悄改掉。而且 2038 问题是 TIMESTAMP 的硬伤。

---

## 三、9 张表设计详解

### 1. `ods_orders` — 订单主表（99,441 行）

| 字段                            | 类型            | 说明                      |
| ----------------------------- | ------------- | ----------------------- |
| order_id                      | VARCHAR(32)   | **主键**                  |
| customer_id                   | VARCHAR(32)   | 客户ID，建**普通索引**（用于 JOIN） |
| order_status                  | VARCHAR(20)   | 状态，建索引（后续按状态筛选）         |
| order_purchase_timestamp      | DATETIME      | 下单时间，建索引（时间范围查询多）       |
| order_approved_at             | DATETIME NULL | 支付时间                    |
| order_delivered_carrier_date  | DATETIME NULL | 交物流时间                   |
| order_delivered_customer_date | DATETIME NULL | 签收时间                    |
| order_estimated_delivery_date | DATETIME NULL | 预计送达                    |

**设计要点**：

- 三个时间字段允许 NULL（未完成订单确实没有这些时间，不可强填）
- `order_id` 唯一且非空 → 做主键（InnoDB 主键即聚簇索引）

### 2. `ods_order_items` — 订单明细（112,650 行）

| 字段                  | 类型            | 说明                |
| ------------------- | ------------- | ----------------- |
| order_id            | VARCHAR(32)   | **联合主键之一**        |
| order_item_id       | INT           | **联合主键之二**（订单内序号） |
| product_id          | VARCHAR(32)   | 商品ID，建索引          |
| seller_id           | VARCHAR(32)   | 卖家ID，建索引          |
| shipping_limit_date | DATETIME      | 发货截止              |
| price               | DECIMAL(10,2) | 商品单价              |
| freight_value       | DECIMAL(10,2) | 运费                |

**设计要点（重点）**：

- **联合主键 `(order_id, order_item_id)`**：一个订单可以有多个商品行，单独 `order_id` 不唯一，    
  单独 `order_item_id` 也不唯一，只有组合起来才唯一 → 这就是联合主键的典型场景
- 复合索引 `(order_id, order_item_id)` 天然形成，无需额外建

### 3. `ods_order_payments` — 支付记录（103,886 行）

| 字段                   | 类型            | 说明                                         |
| -------------------- | ------------- | ------------------------------------------ |
| order_id             | VARCHAR(32)   | 联合主键之一                                     |
| payment_sequential   | INT           | 联合主键之二（同一订单的第 N 笔支付）                       |
| payment_type         | VARCHAR(20)   | 支付方式：credit_card/boleto/voucher/debit_card |
| payment_installments | INT           | 分期数                                        |
| payment_value        | DECIMAL(10,2) | 支付金额                                       |

**设计要点**：一个订单可有多笔支付（如先用券再刷卡），所以也是**联合主键**。

### 4. `ods_order_reviews` — 评价（100,000 行）

| 字段                      | 类型                | 说明                  |
| ----------------------- | ----------------- | ------------------- |
| review_id               | VARCHAR(32)       | **联合主键之一**（单独不唯一）   |
| order_id                | VARCHAR(32)       | **联合主键之二**，另建索引     |
| review_score            | TINYINT           | 评分 1-5              |
| review_comment_title    | VARCHAR(255) NULL | 标题（93,578 条为空）      |
| review_comment_message  | TEXT NULL         | 内容（63,871 条为空，且含换行） |
| review_creation_date    | DATETIME          | 创建时间                |
| review_answer_timestamp | DATETIME          | 回复时间                |

**设计要点（实测修正，重要）**：

- **`review_id` 并不唯一**（这是导数据时才暴露出来的）：
  - 总记录 100,000 条，`review_id` 唯一值只有 **99,173** 个
  - **802 个 review_id 重复**（777 个重复 2 次、25 个重复 3 次），共多出 827 行
  - 重复记录的内容、评分、时间戳**完全相同**，只有 `order_id` 不同
  - 推测原因：源系统把同一条评价挂到了多个订单上
- **`(review_id, order_id)` 组合经验证 100,000 条全部唯一 → 采用联合主键**
- 另有 **555 个订单存在多条评价**（`order_id` 唯一值 99,441 < 100,000）    
  → 第 4、5 步 按订单聚合评价时必须先确定「取哪一条」的规则
- 评论内容用 `TEXT` 而不是 `VARCHAR(255)`：长度不可控，且含 `\r\n` 换行

> **纠正一处早期误判**：最初看到文件物理行数 105,764 > orders 的 99,441，>   
> 误以为「一单多评导致行数变多」。实际情况是文件里有 **4,003 条评论内容内嵌换行符**>   
> （多出 5,764 个物理行），真实记录数只有 100,000 条。>   
> 教训：**`wc -l` 统计的是物理行数，不等于 CSV 记录数**，带引号的多行字段会让两者不等。

### 5. `ods_customers` — 客户（99,441 行）

| 字段                       | 类型          | 说明              |
| ------------------------ | ----------- | --------------- |
| customer_id              | VARCHAR(32) | 主键（**订单级客户ID**） |
| customer_unique_id       | VARCHAR(32) | **真实自然人ID**，建索引 |
| customer_zip_code_prefix | VARCHAR(5)  | 邮编前缀            |
| customer_city            | VARCHAR(50) | 城市              |
| customer_state           | CHAR(2)     | 州缩写（固定2位）       |

**设计要点（极其重要的踩坑点）**：

- ⚠️ **`customer_id` 和 `customer_unique_id` 不是一回事！**
  - `customer_id`：**每下一个订单就生成一个新的**，与订单一一对应
  - `customer_unique_id`：**同一个人的真实身份**，跨订单不变
- **算复购率、用户留存必须用 `customer_unique_id`**！用错的话，    
  每个人都会变成"只买过一次的新客"，复购率永远为 0。
- 这是第 5 步做留存分析的核心陷阱，也是**业务理解上的关键点**。

### 6. `ods_products` — 商品（32,951 行）

| 字段                         | 类型                | 说明                  |
| -------------------------- | ----------------- | ------------------- |
| product_id                 | VARCHAR(32)       | 主键                  |
| product_category_name      | VARCHAR(100) NULL | 品类名（葡萄牙语，有空值）       |
| product_name_lenght        | INT NULL          | 名称长度（**原字段名就是拼错的**） |
| product_description_lenght | INT NULL          | 描述长度（**同样拼错**）      |
| product_photos_qty         | INT NULL          | 图片数量                |
| product_weight_g           | INT NULL          | 重量（克）               |
| product_length_cm          | INT NULL          | 长度（厘米）              |
| product_height_cm          | INT NULL          | 高度（厘米）              |
| product_width_cm           | INT NULL          | 宽度（厘米）              |

**设计要点**：

- **保留原始字段名的拼写错误**（`lenght` 应为 `length`）。理由：与数据源严格一致，    
  便于比对；如果改名，后续导入映射容易出错。**但要在注释里标注**，免得自己忘。
- 尺寸重量全部允许 NULL（部分商品未填）

### 7. `ods_sellers` — 卖家（3,095 行）

| 字段                     | 类型          | 说明               |
| ---------------------- | ----------- | ---------------- |
| seller_id              | VARCHAR(32) | 主键               |
| seller_zip_code_prefix | VARCHAR(5)  | 邮编前缀，建索引（用于关联地理） |
| seller_city            | VARCHAR(50) | 城市               |
| seller_state           | CHAR(2)     | 州                |

### 8. `ods_geolocation` — 地理位置（1,000,163 行）★

| 字段                          | 类型            | 说明       |
| --------------------------- | ------------- | -------- |
| geolocation_zip_code_prefix | VARCHAR(5)    | 邮编前缀，建索引 |
| geolocation_lat             | DECIMAL(11,8) | 纬度       |
| geolocation_lng             | DECIMAL(11,8) | 经度       |
| geolocation_city            | VARCHAR(50)   | 城市       |
| geolocation_state           | CHAR(2)       | 州        |

**设计要点（关键）**：

- **不设主键**！因为同一邮编有大量重复记录，没有唯一字段。    
  这在生产里是常见的"日志类/明细类"表设计。
- 纬度范围 -90~~90，经度 -180~~180，用 `DECIMAL(11,8)` 精度足够（约 1 米级）
- **这张表是第 6 步性能优化的主战场**：100 万行 + 无主键 + 需要按邮编聚合去重

### 9. `ods_category_translation` — 品类翻译（70 行）

| 字段                            | 类型           | 说明       |
| ----------------------------- | ------------ | -------- |
| product_category_name         | VARCHAR(100) | 主键（葡萄牙语） |
| product_category_name_english | VARCHAR(100) | 英文名      |

**设计要点**：CSV 文件带 **BOM 头**（`\ufeff`），导入时要注意，否则第一列名会变成乱码。

---

## 四、索引设计（初步，第 6 步验证优化）

```sql
-- 外键关联字段（JOIN 高频）
orders.customer_id
order_items.product_id
order_items.seller_id
order_reviews.order_id
customers.customer_unique_id

-- 过滤/排序字段
orders.order_status
orders.order_purchase_timestamp

-- 地理关联
geolocation.geolocation_zip_code_prefix
sellers.seller_zip_code_prefix
```

**原则**：

- 建索引的字段 = 高频出现在 `WHERE`、`JOIN ON`、`ORDER BY` 里的字段
- 索引不是越多越好（占空间 + 拖慢写入）
- 低区分度字段（如 `order_status` 只有几个值）建索引要谨慎，但初期可以建，第 6 步再评估

---

## 五、产出清单

- [x] `sql/01_create_database.sql` — 建库脚本
- [x] `sql/02_create_tables.sql` — 9 张建表脚本（带中文注释）
- [x] 本文档（设计说明）

**下一步**：在 Navicat 里执行这两个脚本，建库建表。

---

## 六、设计自查

1. 订单 ID 为什么用 VARCHAR 不用 INT？
2. 金额字段为什么必须用 DECIMAL？
3. DECIMAL(10,2) 能存的最大值是多少？
4. DATETIME 和 TIMESTAMP 的区别？为什么选 DATETIME？
5. `ods_order_items` 为什么用联合主键？联合主键和单列主键的取舍？
6. `customer_id` 和 `customer_unique_id` 有什么区别？算复购率该用哪个？
7. 为什么 `ods_geolocation` 不设主键？
8. 哪些字段该建索引？建索引的依据是什么？
9. utf8 和 utf8mb4 的区别？
10. 什么是聚簇索引？InnoDB 的主键和聚簇索引是什么关系？
