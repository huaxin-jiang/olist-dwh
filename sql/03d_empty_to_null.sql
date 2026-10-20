-- ============================================================
-- 脚本 03d：把「空字符串」统一转为 NULL
-- ============================================================
-- 【问题】
--   导入后有三个字段的空值是 ''（空字符串），而不是 NULL：
--     products.product_category_name       610 条
--     reviews.review_comment_title      88,285 条
--     reviews.review_comment_message    58,245 条
--
-- 【原因】
--   CSV 里的空字段被解析成空字符串 ''。脚本中其他字段都用了
--   NULLIF(@var,'') 转 NULL，但这三个文本字段漏了（直接赋值 @var）。
--   严格说这不是「导入错误」——ODS 层存 '' 也算忠实；
--   但 '' 与 NULL 语义不同，会导致后续统计出错。
--
-- 【'' 和 NULL 的语义区别（实现说明）】
--   ''   = 「有值，值就是空」   → COUNT(col) 会算进去
--   NULL = 「值未知 / 不存在」  → COUNT(col) 不计，IS NULL 可筛出
--
-- 【不修的后果（真实的分析陷阱）】
--   1) 算「商品品类完整度」：
--        COUNT(product_category_name)/COUNT(*) 会把 610 个空算成「有品类」，
--        完整度虚高（99.99% 而非 98.15%）
--   2) 筛「品类缺失的商品」：
--        WHERE product_category_name IS NULL → 查出 0 条，但那 610 条明明缺失
--   3) 算「评论率」：
--        COUNT(review_comment_message) 会把 58,245 个空串算成「有评论」，
--        评论率虚高到 41.8%（真实评论率约 41.8% 里的空串要扣掉，
--        实际有内容的仅 41,755 条 ≈ 41.8% → 41,755/100,000）
--   4) 字符串比较：
--        '' = '' 为真，NULL = NULL 为 NULL（三值逻辑），
--        JOIN 和 GROUP BY 的行为也不同
--
-- 【修复策略】
--   直接 UPDATE 把 '' 改成 NULL。
--   比重新导入快（不用重跑 LOAD DATA），且不影响主键和行数。
--   同时已改 03_load_data.sql 里的对应字段加 NULLIF，保证以后重跑一致。
-- ============================================================

USE olist_db;


-- ------------------------------------------------------------
-- 修复 1：商品品类（610 条）
-- ------------------------------------------------------------
UPDATE ods_products
SET product_category_name = NULL
WHERE product_category_name = '';


-- ------------------------------------------------------------
-- 修复 2：评价标题（88,285 条）
-- ------------------------------------------------------------
UPDATE ods_order_reviews
SET review_comment_title = NULL
WHERE review_comment_title = '';


-- ------------------------------------------------------------
-- 修复 3：评价内容（58,245 条）
-- ------------------------------------------------------------
UPDATE ods_order_reviews
SET review_comment_message = NULL
WHERE review_comment_message = '';


-- ============================================================
-- 验证：三个字段的 NULL 数应与源文件的空值数一致
-- ============================================================
SELECT 'products.product_category_name' AS 字段,
       SUM(product_category_name IS NULL) AS 是NULL,
       SUM(product_category_name = '')    AS 空串,
       610 AS 期望NULL
FROM ods_products
UNION ALL
SELECT 'reviews.review_comment_title',
       SUM(review_comment_title IS NULL),
       SUM(review_comment_title = ''),
       88285
FROM ods_order_reviews
UNION ALL
SELECT 'reviews.review_comment_message',
       SUM(review_comment_message IS NULL),
       SUM(review_comment_message = ''),
       58245
FROM ods_order_reviews;


-- ============================================================
-- 验证：行数不受影响（更新不应改变行数）
-- ============================================================
SELECT 'ods_products' AS 表, COUNT(*) AS 行数, 32951 AS 期望 FROM ods_products
UNION ALL SELECT 'ods_order_reviews', COUNT(*), 100000 FROM ods_order_reviews;


-- ============================================================
-- 附带：修正后的「商品品类完整度」真实值
-- 修复前会算成 100%，修复后应显示 98.15%
-- ============================================================
SELECT
    COUNT(*)                                   AS 商品总数,
    COUNT(product_category_name)               AS 有品类,
    ROUND(COUNT(product_category_name) * 100.0 / COUNT(*), 2) AS 完整度百分比
FROM ods_products;
