-- ============================================================
-- 第 5 步前置修复：统一"延迟"口径
-- ------------------------------------------------------------
-- 问题：dwd_orders.is_late 用时间戳直接比较
--         delivered_ts > estimated_ts
--       estimated_ts 的时间部分固定是 00:00:00，所以"当天下午送达"
--       会被判成延迟，但 late_days = DATEDIFF(...) = 0。
--       结果：is_late=1 却 late_days=0，两个字段自相矛盾。
--
-- 实测：1,292 单属于这种情况，占"延迟订单"的 14.2%。
--       延迟率被虚高：8.11% → 实际 6.77%
--
-- 修复：is_late 改为 DATEDIFF(delivered, estimated) > 0
--       即"按天判断，当日达成本就算准时"
-- ============================================================

USE olist_db;

-- 修复前对比
SELECT '修复前' AS 阶段,
       SUM(is_late = 1)                              AS 延迟订单,
       SUM(is_late = 1 AND late_days = 0)             AS 其中当天送达,
       ROUND(SUM(is_late = 1) * 100.0 / COUNT(*), 2)  AS 延迟率
FROM dwd_orders
WHERE is_delivered = 1;

-- 执行修复
UPDATE dwd_orders
SET is_late = CASE
        WHEN delivered_ts IS NULL THEN NULL
        WHEN DATEDIFF(delivered_ts, estimated_ts) > 0 THEN 1
        ELSE 0
    END
WHERE is_delivered = 1;

-- 修复后验证
SELECT '修复后' AS 阶段,
       SUM(is_late = 1)                              AS 延迟订单,
       SUM(is_late = 1 AND late_days = 0)             AS 其中当天送达,
       ROUND(SUM(is_late = 1) * 100.0 / COUNT(*), 2)  AS 延迟率
FROM dwd_orders
WHERE is_delivered = 1;

-- 一致性校验：is_late 与 late_days 必须完全一致
SELECT SUM(is_late = 1 AND late_days <= 0) AS 矛盾_延迟但天数非正,
       SUM(is_late = 0 AND late_days > 0)  AS 矛盾_准时但天数超期,
       SUM(is_late IS NULL AND delivered_ts IS NOT NULL) AS 矛盾_已签收却无标记
FROM dwd_orders;
