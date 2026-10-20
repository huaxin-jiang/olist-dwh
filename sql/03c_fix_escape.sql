-- ============================================================
-- 脚本 03c：修复 LOAD DATA 转义问题（reviews 少 10 行 + sellers 数据损坏）
-- ============================================================
-- 【现象】
--   1) ods_order_reviews 只有 99,990 行（应为 100,000），少 10 行
--      review_id 唯一数 99,163（应 99,173），order_id 唯一数 99,431（应 99,441）
--      → 三个数同时少 10，说明是 10 条独立记录整段消失
--   2) ods_sellers 行数正确（3,095），但有一条 seller_city 内容损坏：
--      'rio de janeiro \rio de janeiro' 被存成 'rio de janeiro ' + CR + 'io de janeiro'
--
-- 【根因（已实测确认）】
--   MySQL 的 LOAD DATA 默认 FIELDS ... ESCAPED BY '\\'，
--   即把反斜杠 \ 当作转义字符。
--
--   ▸ reviews 文件第 78546 行的评论结尾是：  não chegou nada :\" 
--     （反斜杠紧挨着结束引号）
--     MySQL 把 \" 视为「被转义的双引号」，不认它作字段结束符，
--     于是继续往下读找闭合引号，一路吞到第 78556 行 —— 中间 10 条记录被整段
--     塞进了那条评论里（实测该记录评论长度异常膨胀到 1,487 字符）。
--
--   ▸ sellers 文件里的 '\rio de janeiro'，MySQL 把 \r 解析成「回车符」，
--     于是城市名里多了一个 0x0D，且字母 r 消失。行数没少，但数据被静默改坏。
--
-- 【为什么之前没发现】
--   这类问题不报错、不产生 WARNING，属于「静默数据损坏」，
--   只有拿源文件记录数逐一比对才能发现。
--
-- 【修复方案】
--   在 LOAD DATA 中显式声明 ESCAPED BY ''（空字符串）＝ 关闭转义语义。
--   ▸ 数据是标准 CSV：引号内的引号用 "" 双写表示，不依赖反斜杠转义
--   ▸ 关掉转义后，\" 会被正确解析为「反斜杠 + 字段结束引号」，忠实还原源数据
--   ▸ 不去改源文件内容，保持 ODS 层对原始数据的忠实性
--
-- 【实现说明】
--   「LOAD DATA 默认 ESCAPED BY '\\'，当数据内容里出现反斜杠且紧邻引号时，
--     会导致引号配对错乱、整段记录被吞。这类问题不报错，必须靠行数比对发现。」
--   —— 这属于「静默失败」，比报错更难排查，是数据工程的经典陷阱。
-- ============================================================

USE olist_db;


-- ------------------------------------------------------------
-- 修复 1：评价表重新导入（清空后用 ESCAPED BY '' 重导）
-- ------------------------------------------------------------
TRUNCATE TABLE ods_order_reviews;

LOAD DATA INFILE 'D:/ENV/MySQL/DATA/Uploads/olist/olist_order_reviews_dataset.csv'
INTO TABLE ods_order_reviews
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(@review_id, @order_id, @review_score, @review_title, @review_msg,
 @review_creation, @review_answer)
SET
    review_id               = @review_id,
    order_id                = @order_id,
    review_score            = NULLIF(@review_score, ''),
    review_comment_title    = NULLIF(@review_title, ''),
    review_comment_message  = NULLIF(@review_msg, ''),
    review_creation_date    = NULLIF(@review_creation, ''),
    review_answer_timestamp = NULLIF(@review_answer, '');
SHOW WARNINGS;


-- ------------------------------------------------------------
-- 修复 2：卖家表重新导入（修复被 \r 破坏的城市名）
-- ------------------------------------------------------------
TRUNCATE TABLE ods_sellers;

LOAD DATA INFILE 'D:/ENV/MySQL/DATA/Uploads/olist/olist_sellers_dataset.csv'
INTO TABLE ods_sellers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(seller_id, seller_zip_code_prefix, seller_city, seller_state);
SHOW WARNINGS;


-- ------------------------------------------------------------
-- 修复 3：地理位置表导入（1,000,163 行，之前尚未导入）
-- 同样加 ESCAPED BY '' 保持一致
-- 预计 1-3 分钟
-- ------------------------------------------------------------
TRUNCATE TABLE ods_geolocation;

LOAD DATA INFILE 'D:/ENV/MySQL/DATA/Uploads/olist/olist_geolocation_dataset.csv'
INTO TABLE ods_geolocation
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(geolocation_zip_code_prefix, geolocation_lat, geolocation_lng,
 geolocation_city, geolocation_state);
SHOW WARNINGS;


-- ============================================================
-- 验证 1：九张表行数总览
-- ============================================================
SELECT 'ods_customers'           AS 表名, COUNT(*) AS 行数, 99441    AS 期望 FROM ods_customers
UNION ALL SELECT 'ods_geolocation',         COUNT(*),              1000163       FROM ods_geolocation
UNION ALL SELECT 'ods_order_items',         COUNT(*),              112650        FROM ods_order_items
UNION ALL SELECT 'ods_order_payments',      COUNT(*),              103886        FROM ods_order_payments
UNION ALL SELECT 'ods_order_reviews',       COUNT(*),              100000        FROM ods_order_reviews
UNION ALL SELECT 'ods_orders',              COUNT(*),              99441         FROM ods_orders
UNION ALL SELECT 'ods_products',            COUNT(*),              32951         FROM ods_products
UNION ALL SELECT 'ods_sellers',             COUNT(*),              3095          FROM ods_sellers
UNION ALL SELECT 'ods_category_translation',COUNT(*),              71            FROM ods_category_translation;


-- ============================================================
-- 验证 2：评价表三项指标（重点看是否补齐 10 行）
-- 期望：总行数 100,000｜review_id 唯一 99,173｜order_id 唯一 99,441｜评分为空 0
-- ============================================================
SELECT
    COUNT(*)                    AS 总行数,
    COUNT(DISTINCT review_id)   AS review_id唯一数,
    COUNT(DISTINCT order_id)    AS order_id唯一数,
    SUM(review_score IS NULL)   AS 评分为空数
FROM ods_order_reviews;


-- ============================================================
-- 验证 3：之前被吞掉的那条记录，评论长度应恢复正常（原为 1487）
-- 正常值在 100 字符左右，且不再包含逗号分隔的原始行内容
-- ============================================================
SELECT review_id,
       CHAR_LENGTH(review_comment_message) AS 评论长度,
       review_comment_message               AS 评论内容
FROM ods_order_reviews
WHERE review_id = '636b237e87574ba29654deaba9eb9797';


-- ============================================================
-- 验证 4：确认那 10 条记录已回来
-- 用它们的 review_id 查，应全部命中（10 行）
-- ============================================================
SELECT COUNT(*) AS 应等于10
FROM ods_order_reviews
WHERE review_id IN (
    '29a50943bdeaba02e4a222241a4b583a',
    'ceef71ec8c12263b2435a71d581b4716',
    '0f6f2d7bf861d9c5bd08e35bf357a176',
    '97b84f8184d84f1d179ae16f4d1803d8',
    'db3da397381df45c239ed1e89e550275',
    'bf95de6d0d04a83da663096e8797978d',
    'c4a96ce7760c441272973ca589a3c7f4',
    'd58e4a045e87101c547aa0eeb1c0424c',
    'c7436ab65eb8f485013709c5e8149b47',
    'bd796e51f63763f665b3f6e55dbe5272'
);


-- ============================================================
-- 验证 5：确认卖家城市名已修复
-- 修复后应显示 'rio de janeiro \rio de janeiro'（反斜杠是源数据里就有的笔误）
-- 关键看：HEX 里不再出现 0D，而是出现 5C（反斜杠）
-- ============================================================
SELECT seller_city,
       CHAR_LENGTH(seller_city) AS 长度,
       HEX(seller_city)         AS 十六进制
FROM ods_sellers
WHERE seller_city LIKE 'rio de janeiro%'
  AND CHAR_LENGTH(seller_city) > 17
LIMIT 1;
