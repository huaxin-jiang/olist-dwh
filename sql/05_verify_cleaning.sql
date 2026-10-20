-- ============================================================
-- 脚本 05：第 4 步清洗结果验证（可重复执行）
-- ============================================================
-- 用途：每次清洗后跑一遍，确认 8 张 DWD 表数据正确。
-- 这些检查也是验证思路可以这样说明的「我怎么验证清洗结果」。
-- ============================================================

USE olist_db;


-- ------------------------------------------------------------
-- 校验 1：八张表行数
-- ------------------------------------------------------------
SELECT 'dim_geolocation' AS 表, COUNT(*) AS 行数, 19015 AS 期望 FROM dim_geolocation
UNION ALL SELECT 'dim_customer',      COUNT(*), 96096   FROM dim_customer
UNION ALL SELECT 'dim_product',       COUNT(*), 32951   FROM dim_product
UNION ALL SELECT 'dim_seller',        COUNT(*), 3095    FROM dim_seller
UNION ALL SELECT 'dwd_orders',        COUNT(*), 99441   FROM dwd_orders
UNION ALL SELECT 'dwd_order_items',   COUNT(*), 112650  FROM dwd_order_items
UNION ALL SELECT 'dwd_payments',      COUNT(*), 99440   FROM dwd_payments
UNION ALL SELECT 'dwd_reviews',       COUNT(*), 99441   FROM dwd_reviews;


-- ------------------------------------------------------------
-- 校验 2：★ 维度表 JOIN 不膨胀（去重是否成功的硬标准）
-- 期望：两行都是 99,441
-- ------------------------------------------------------------
SELECT '不JOIN' AS 场景, COUNT(*) AS 行数 FROM dwd_orders
UNION ALL
SELECT 'JOIN customer + geolocation', COUNT(*)
FROM dwd_orders o
LEFT JOIN dim_customer c    ON o.customer_unique_id = c.customer_unique_id
LEFT JOIN dim_geolocation g ON c.zip_code_prefix    = g.zip_code_prefix;


-- ------------------------------------------------------------
-- 校验 3：★ 复购率两种口径（核心业务陷阱）
-- 期望：第一行 0.00%（错误口径），第二行 3.12%（正确口径）
-- ------------------------------------------------------------
SELECT '用 customer_id（错误）' AS 口径,
       COUNT(*) AS 客户数,
       SUM(order_count > 1) AS 复购人数,
       ROUND(SUM(order_count > 1) * 100.0 / COUNT(*), 2) AS 复购率
FROM (SELECT customer_id, COUNT(*) AS order_count FROM ods_orders GROUP BY customer_id) t
UNION ALL
SELECT '用 customer_unique_id（正确）',
       COUNT(*), SUM(order_count > 1),
       ROUND(SUM(order_count > 1) * 100.0 / COUNT(*), 2)
FROM dim_customer;


-- ------------------------------------------------------------
-- 校验 4：GMV 三种口径（报数必须说明口径）
-- ------------------------------------------------------------
SELECT '商品金额(仅price)'        AS 口径, ROUND(SUM(price), 2)       AS 金额 FROM dwd_order_items
UNION ALL SELECT '明细金额(price+freight)', ROUND(SUM(item_total), 2)  FROM dwd_order_items
UNION ALL SELECT '支付金额(payment_total)', ROUND(SUM(payment_total), 2) FROM dwd_payments;


-- ------------------------------------------------------------
-- 校验 5：配送时效指标
-- 期望：已签收 96,478｜延迟率 6.77%｜时间异常 2 条
-- （注：延迟率原为 8.11%，第 5 步发现 is_late 用时间戳比较会把
--   "当天送达"误判为延迟，已于 06a_修正延迟口径.sql 统一为按天判断）
-- ------------------------------------------------------------
SELECT
    COUNT(*)                                 AS 已签收订单,
    ROUND(AVG(delivery_days), 2)             AS 平均配送天数,
    ROUND(AVG(estimated_days), 2)            AS 平均承诺天数,
    SUM(is_late)                             AS 延迟订单数,
    ROUND(SUM(is_late) * 100.0 / COUNT(*), 2) AS 延迟率,
    SUM(is_time_anomaly)                     AS 时间异常标记
FROM dwd_orders
WHERE is_delivered = 1;


-- ------------------------------------------------------------
-- 校验 6：评价去重效果
-- 期望：订单 99,441｜多次评价 555｜有文字评论 41,545｜平均分 4.07
-- ------------------------------------------------------------
SELECT
    COUNT(*)                        AS 订单数,
    SUM(review_count > 1)           AS 被多次评价订单,
    SUM(comment_message IS NOT NULL) AS 有文字评论,
    ROUND(AVG(review_score), 2)     AS 平均分
FROM dwd_reviews;


-- ------------------------------------------------------------
-- 校验 7：★ 数据边界（做时间趋势前必查）
-- 2016-09~12 和 2018-09~10 数据不完整，分析窗口应为 2017-01 ~ 2018-08
-- ------------------------------------------------------------
SELECT purchase_year AS 年, purchase_month AS 月, COUNT(*) AS 订单数
FROM dwd_orders
GROUP BY purchase_year, purchase_month
ORDER BY purchase_year, purchase_month;


-- ------------------------------------------------------------
-- 校验 8：无支付记录的订单（源数据缺陷，查询需用 LEFT JOIN）
-- 期望：1 条（bfbd0f9bdef84302105ad712db648a6c）
-- ------------------------------------------------------------
SELECT o.order_id, o.order_status, o.purchase_ts
FROM dwd_orders o
LEFT JOIN dwd_payments p ON o.order_id = p.order_id
WHERE p.order_id IS NULL;


-- ------------------------------------------------------------
-- 校验 9：维度表完整性抽查
-- ------------------------------------------------------------
-- 9.1 商品品类补全情况（应为 0 个空品类名）
SELECT
    COUNT(*)                          AS 商品数,
    SUM(category_en = 'unknown')      AS 品类未知,
    SUM(has_category = 0)             AS 源数据品类缺失
FROM dim_product;

-- 9.2 地域维度覆盖率（经纬度为空说明该邮编全是越界坐标）
SELECT
    COUNT(*)                      AS 邮编数,
    SUM(latitude IS NULL)         AS 无有效坐标,
    SUM(city IS NULL)             AS 无城市
FROM dim_geolocation;

-- 9.3 客户维度：下过单 vs 没下过单
SELECT
    COUNT(*)                      AS 客户总数,
    SUM(order_count = 0)          AS 无订单客户,
    SUM(order_count = 1)          AS 单次客户,
    SUM(order_count > 1)          AS 复购客户
FROM dim_customer;
