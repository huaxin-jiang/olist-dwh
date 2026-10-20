-- ============================================================
-- 脚本 03b：修复评价表主键并重新导入
-- ============================================================
-- 【问题】
--   导入评价表时报：
--     ERROR 1062 - Duplicate entry 'xxxx' for key 'ods_order_reviews.PRIMARY'
--
-- 【原因（已实测确认）】
--   数据源里的 review_id 并不唯一：
--     总记录 100,000 条，review_id 唯一值只有 99,173 个
--     802 个 review_id 重复（777 个重复 2 次、25 个重复 3 次）
--     共多出 827 行
--   重复的内容完全相同（评分、评论、时间戳都一样），
--   只有 order_id 不同 —— 是源系统把同一评价挂到了多个订单上。
--
-- 【验证结论】
--   (review_id, order_id) 组合：100,000 条，全部唯一，零重复
--   → 用联合主键即可完整保留全部数据，不需要删任何行
--
-- 【设计取舍（实现说明）】
--   方案1：单列主键 review_id        → 报错，数据源不支持
--   方案2：联合主键 (review_id, order_id) → 保留全量，最忠实于源数据 ✅
--   方案3：代理键 id 自增 + review_id 普通索引 → 也可行，但多一列冗余
--   方案4：按 review_id 去重（只留一条）  → 会丢 827 行，ODS 层不应丢数据 ❌
--   原始层（ODS）的职责是「忠实保存」，去重属于清洗层（DWD）的决策。
-- ============================================================

USE olist_db;

-- ------------------------------------------------------------
-- 步骤 1：清空表（导入失败后可能有残留）
-- ------------------------------------------------------------
TRUNCATE TABLE ods_order_reviews;

-- ------------------------------------------------------------
-- 步骤 2：改主键为联合主键
-- ------------------------------------------------------------
-- 先删旧主键，再建新主键。
-- 表为空时改结构最快；有数据时 MySQL 需要重建整张表。
-- ------------------------------------------------------------
ALTER TABLE ods_order_reviews DROP PRIMARY KEY;

ALTER TABLE ods_order_reviews
    ADD PRIMARY KEY (review_id, order_id);

-- 确认主键已生效
SHOW INDEX FROM ods_order_reviews WHERE Key_name = 'PRIMARY';

-- ------------------------------------------------------------
-- 步骤 3：重新导入
-- ------------------------------------------------------------
LOAD DATA INFILE 'D:/ENV/MySQL/DATA/Uploads/olist/olist_order_reviews_dataset.csv'
INTO TABLE ods_order_reviews
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(review_id, order_id, review_score, review_comment_title,
 review_comment_message, review_creation_date, review_answer_timestamp);
SHOW WARNINGS;

-- ------------------------------------------------------------
-- 步骤 4：验证
-- ------------------------------------------------------------
-- 期望：总行数 100,000；review_id 唯一值 99,173；order_id 唯一值 99,441
SELECT
    COUNT(*)                    AS 总行数,
    COUNT(DISTINCT review_id)   AS review_id唯一数,
    COUNT(DISTINCT order_id)    AS order_id唯一数,
    SUM(review_score IS NULL)   AS 评分为空数
FROM ods_order_reviews;

-- 抽查：确认重复的 review_id 都完整保留下来了
SELECT review_id, COUNT(*) AS 出现次数
FROM ods_order_reviews
GROUP BY review_id
HAVING COUNT(*) > 1
ORDER BY 出现次数 DESC
LIMIT 5;
