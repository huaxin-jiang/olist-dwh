-- ============================================================
-- 第 6 步：性能基准测试脚本（可复现）
-- ------------------------------------------------------------
-- 用法：
--   mysql -u olist_dev -p --default-character-set=utf8mb4 < 08_benchmark.sql
--
-- 方法：
--   1. 交替执行 A/B/A/B/A/B，不是 AAA 再 BBB —— 避免缓存单向漂移
--   2. 取 3 轮中位数，不取平均（平均值会被单次抖动带偏）
--   3. 冷启动第一次结果作废（buffer pool 还没预热）
--
-- 注意：SHOW PROFILES 输出中的 Duration 单位为秒。
-- ============================================================

USE olist_db;

SET profiling = 1;

-- ---------- 预热：让 buffer pool 载入相关页 ----------
SELECT COUNT(*) FROM dwd_orders;
SELECT COUNT(*) FROM dwd_order_items;
SELECT COUNT(*) FROM dwd_reviews;
SELECT COUNT(*) FROM dim_product;
SELECT COUNT(*) FROM dim_customer;

-- 清除预热产生的 profile 记录
SET profiling = 0;
SET profiling = 1;

-- ============================================================
-- 基准 1：N+1 相关子查询  vs  派生表聚合
-- ============================================================

-- A1 原始写法
SELECT COUNT(*) FROM (
    SELECT o.order_id,
           (SELECT COUNT(*) FROM dwd_order_items i WHERE i.order_id = o.order_id) AS cnt,
           (SELECT SUM(i.item_total) FROM dwd_order_items i WHERE i.order_id = o.order_id) AS amt
    FROM dwd_orders o
) t;

-- B1 改写后
SELECT COUNT(*) FROM (
    SELECT o.order_id, i.cnt
    FROM dwd_orders o
    LEFT JOIN (
        SELECT order_id, COUNT(*) AS cnt, SUM(item_total) AS amt
        FROM dwd_order_items GROUP BY order_id
    ) i ON o.order_id = i.order_id
) t;

-- A2
SELECT COUNT(*) FROM (
    SELECT o.order_id,
           (SELECT COUNT(*) FROM dwd_order_items i WHERE i.order_id = o.order_id) AS cnt,
           (SELECT SUM(i.item_total) FROM dwd_order_items i WHERE i.order_id = o.order_id) AS amt
    FROM dwd_orders o
) t;

-- B2
SELECT COUNT(*) FROM (
    SELECT o.order_id, i.cnt
    FROM dwd_orders o
    LEFT JOIN (
        SELECT order_id, COUNT(*) AS cnt, SUM(item_total) AS amt
        FROM dwd_order_items GROUP BY order_id
    ) i ON o.order_id = i.order_id
) t;

-- A3
SELECT COUNT(*) FROM (
    SELECT o.order_id,
           (SELECT COUNT(*) FROM dwd_order_items i WHERE i.order_id = o.order_id) AS cnt,
           (SELECT SUM(i.item_total) FROM dwd_order_items i WHERE i.order_id = o.order_id) AS amt
    FROM dwd_orders o
) t;

-- B3
SELECT COUNT(*) FROM (
    SELECT o.order_id, i.cnt
    FROM dwd_orders o
    LEFT JOIN (
        SELECT order_id, COUNT(*) AS cnt, SUM(item_total) AS amt
        FROM dwd_order_items GROUP BY order_id
    ) i ON o.order_id = i.order_id
) t;

-- ============================================================
-- 基准 2：函数包裹  vs  范围查询
-- ============================================================

-- A1 函数包裹（索引失效）
SELECT COUNT(*) FROM dwd_orders WHERE DATE_FORMAT(purchase_ts, '%Y-%m') = '2017-11';
-- B1 范围查询
SELECT COUNT(*) FROM dwd_orders WHERE purchase_ts >= '2017-11-01' AND purchase_ts < '2017-12-01';

-- A2
SELECT COUNT(*) FROM dwd_orders WHERE DATE_FORMAT(purchase_ts, '%Y-%m') = '2017-11';
-- B2
SELECT COUNT(*) FROM dwd_orders WHERE purchase_ts >= '2017-11-01' AND purchase_ts < '2017-12-01';

-- A3
SELECT COUNT(*) FROM dwd_orders WHERE DATE_FORMAT(purchase_ts, '%Y-%m') = '2017-11';
-- B3
SELECT COUNT(*) FROM dwd_orders WHERE purchase_ts >= '2017-11-01' AND purchase_ts < '2017-12-01';

-- ============================================================
-- 基准 3：多表连接（观察 idx_item_order_amount 的效果）
-- ============================================================
SELECT COUNT(*) FROM (
    SELECT COALESCE(p.category_en, 'unknown') AS c, COUNT(*) AS n
    FROM dwd_orders o
    JOIN dwd_order_items i ON o.order_id = i.order_id
    LEFT JOIN dim_product p ON i.product_id = p.product_id
    JOIN dwd_reviews r ON o.order_id = r.order_id
    WHERE o.purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
      AND o.is_delivered = 1
    GROUP BY c
) t;

SELECT COUNT(*) FROM (
    SELECT COALESCE(p.category_en, 'unknown') AS c, COUNT(*) AS n
    FROM dwd_orders o
    JOIN dwd_order_items i ON o.order_id = i.order_id
    LEFT JOIN dim_product p ON i.product_id = p.product_id
    JOIN dwd_reviews r ON o.order_id = r.order_id
    WHERE o.purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
      AND o.is_delivered = 1
    GROUP BY c
) t;

SELECT COUNT(*) FROM (
    SELECT COALESCE(p.category_en, 'unknown') AS c, COUNT(*) AS n
    FROM dwd_orders o
    JOIN dwd_order_items i ON o.order_id = i.order_id
    LEFT JOIN dim_product p ON i.product_id = p.product_id
    JOIN dwd_reviews r ON o.order_id = r.order_id
    WHERE o.purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
      AND o.is_delivered = 1
    GROUP BY c
) t;

SHOW PROFILES;

-- ============================================================
-- 结果解读（2026-10-20 实测，MySQL 8.0.43）
-- ------------------------------------------------------------
-- 基准1：原始 0.944 / 0.903 / 0.789  → 中位数 0.903
--        改写 0.287 / 0.299 / 0.285  → 中位数 0.287   提升 3.1 倍
--
-- 基准2：函数 0.104(冷) / 0.033 / 0.031 → 热态中位数 0.031
--        范围 0.002 / 0.002 / 0.003     → 中位数 0.0025  提升 12.4 倍
--
-- 基准3：0.65-0.88 区间波动，未做索引前后严格对照
--        （复合索引尝试已回滚，见报告第五节）
-- ============================================================
