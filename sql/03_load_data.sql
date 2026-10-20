-- ============================================================
-- 脚本 03：数据导入（9 张 ODS 表）
-- ============================================================
-- 【方案说明：为什么用 LOAD DATA INFILE 而不是 LOCAL】
--   本机数据库与数据文件在同一台机器上，采用「服务端读取」方式：
--   LOAD DATA INFILE 由 MySQL 服务进程直接读文件，速度远快于
--   LOAD DATA LOCAL INFILE（后者要把每行数据通过客户端连接传过去）。
--   真实生产环境也是这个思路：数据文件放在服务器上，用 INFILE 导入。
--
-- 【前置条件 1：文件必须位于 secure-file-priv 目录内】
--   你的 my.ini 中：secure-file-priv="D:/ENV/MySQL/DATA/Uploads"
--   因此文件已放在：D:/ENV/MySQL/DATA/Uploads/olist/
--   这是 MySQL 的安全限制，防止任意读取服务器上的文件。
--
-- 【前置条件 2：执行账号需要 FILE 权限】
--   FILE 是全局权限，GRANT ALL ON olist_db.* 不包含它。
--   需由 root 先授予（见脚本开头）。
--
-- 【前置条件 3：数据已预处理】
--   已通过 00_prepare_data.py 处理：
--     · 去除 BOM
--     · reviews 表 4003 处内嵌换行替换为空格
--     · 统一 UTF-8 + LF 换行
-- ============================================================

USE olist_db;

-- ------------------------------------------------------------
-- 步骤 0：授予 FILE 权限
-- ------------------------------------------------------------
-- ⚠️ 本段需用 root 账号执行一次。
--
-- 注意：只需给「实际存在的账号」授权。
--       本项目创建的是 'olist_dev'@'localhost'，
--       如果你没有建 '@127.0.0.1' 那个账号，
--       就不要再对它 GRANT，否则会报账号不存在的错误。
-- ------------------------------------------------------------
-- GRANT FILE ON *.* TO 'olist_dev'@'localhost';
-- FLUSH PRIVILEGES;


-- ------------------------------------------------------------
-- 步骤 1：清空目标表（保证可重复执行）
-- ------------------------------------------------------------
-- TRUNCATE 比 DELETE 快得多：它直接重建表，不逐行删除、不写 undo log。
-- 实现要点：TRUNCATE 是 DDL，不可回滚；DELETE 是 DML，可回滚但慢。
-- ------------------------------------------------------------
TRUNCATE TABLE ods_customers;
TRUNCATE TABLE ods_sellers;
TRUNCATE TABLE ods_products;
TRUNCATE TABLE ods_category_translation;
TRUNCATE TABLE ods_orders;
TRUNCATE TABLE ods_order_items;
TRUNCATE TABLE ods_order_payments;
TRUNCATE TABLE ods_order_reviews;
TRUNCATE TABLE ods_geolocation;


-- ============================================================
-- 步骤 2：逐表导入
-- ============================================================

-- ------------------------------------------------------------
-- 2.1 客户表（99,441 行，无空值，直接映射）
-- ------------------------------------------------------------
LOAD DATA INFILE 'D:/ENV/MySQL/DATA/Uploads/olist/olist_customers_dataset.csv'
INTO TABLE ods_customers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state);
SHOW WARNINGS;


-- ------------------------------------------------------------
-- 2.2 卖家表（3,095 行，无空值）
-- ------------------------------------------------------------
LOAD DATA INFILE 'D:/ENV/MySQL/DATA/Uploads/olist/olist_sellers_dataset.csv'
INTO TABLE ods_sellers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(seller_id, seller_zip_code_prefix, seller_city, seller_state);
SHOW WARNINGS;


-- ------------------------------------------------------------
-- 2.3 品类翻译表（71 行）
-- 原文件带 BOM，IGNORE 1 LINES 跳过表头时一并丢弃 BOM
-- ------------------------------------------------------------
LOAD DATA INFILE 'D:/ENV/MySQL/DATA/Uploads/olist/product_category_name_translation.csv'
INTO TABLE ods_category_translation
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(product_category_name, product_category_name_english);
SHOW WARNINGS;


-- ------------------------------------------------------------
-- 2.4 商品表（32,951 行）
-- 【关键】数值列有 610 个空值（category/name_len/desc_len/photos）
--         和 2 个空值（weight/length/height/width）
-- 空字符串 '' 写入 INT 列在严格模式下会报 ERROR 1366，
-- 因此必须用 NULLIF(@变量,'') 把空串转成 NULL。
-- ------------------------------------------------------------
LOAD DATA INFILE 'D:/ENV/MySQL/DATA/Uploads/olist/olist_products_dataset.csv'
INTO TABLE ods_products
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(@product_id, @category, @name_len, @desc_len, @photos, @weight, @length, @height, @width)
SET
    product_id                 = @product_id,
    product_category_name      = NULLIF(@category, ''),
    product_name_lenght        = NULLIF(@name_len, ''),
    product_description_lenght = NULLIF(@desc_len, ''),
    product_photos_qty         = NULLIF(@photos, ''),
    product_weight_g           = NULLIF(@weight, ''),
    product_length_cm          = NULLIF(@length, ''),
    product_height_cm          = NULLIF(@height, ''),
    product_width_cm           = NULLIF(@width, '');
SHOW WARNINGS;


-- ------------------------------------------------------------
-- 2.5 订单主表（99,441 行）
-- 【关键】时间列有大量空值：
--         order_approved_at 160 个
--         delivered_carrier_date 1783 个
--         delivered_customer_date 2965 个
-- 空串写入 DATETIME 会报 ERROR 1292，必须 NULLIF 转 NULL
-- ------------------------------------------------------------
LOAD DATA INFILE 'D:/ENV/MySQL/DATA/Uploads/olist/olist_orders_dataset.csv'
INTO TABLE ods_orders
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(@order_id, @customer_id, @status, @purchase, @approved, @carrier, @delivered, @estimated)
SET
    order_id                      = @order_id,
    customer_id                   = @customer_id,
    order_status                  = @status,
    order_purchase_timestamp      = NULLIF(@purchase,  ''),
    order_approved_at             = NULLIF(@approved,  ''),
    order_delivered_carrier_date  = NULLIF(@carrier,   ''),
    order_delivered_customer_date = NULLIF(@delivered, ''),
    order_estimated_delivery_date = NULLIF(@estimated, '');
SHOW WARNINGS;


-- ------------------------------------------------------------
-- 2.6 订单明细表（112,650 行，无空值）
-- ------------------------------------------------------------
LOAD DATA INFILE 'D:/ENV/MySQL/DATA/Uploads/olist/olist_order_items_dataset.csv'
INTO TABLE ods_order_items
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value);
SHOW WARNINGS;


-- ------------------------------------------------------------
-- 2.7 支付表（103,886 行，无空值）
-- ------------------------------------------------------------
LOAD DATA INFILE 'D:/ENV/MySQL/DATA/Uploads/olist/olist_order_payments_dataset.csv'
INTO TABLE ods_order_payments
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, payment_sequential, payment_type, payment_installments, payment_value);
SHOW WARNINGS;


-- ------------------------------------------------------------
-- 2.8 评价表（100,000 行）
-- 【关键1】原始文件有 4,003 条评论含内嵌换行，已于预处理阶段
--         替换为空格，否则本行会因错位而导入失败或数据串行。
-- 【关键2】必须加 ESCAPED BY ''：
--         有 1 条评论结尾是 `...nada :\"`，反斜杠紧邻结束引号，
--         MySQL 默认转义会把 \" 当作转义双引号 → 引号配对错乱，
--         导致后续 10 条记录被整段吞进这条评论（实测少 10 行）。
-- 【关键3】标题/内容列必须用 NULLIF 转 NULL：
--         空字段会解析成 ''，源文件里 88,285 条空标题、58,245 条空内容
--         应存为 NULL，否则 COUNT() 会把空串算成「有评论」，评论率虚高。
-- ------------------------------------------------------------
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
-- 2.9 地理位置表（1,000,163 行）★ 最大，导入最慢
-- 无主键、无空值，直接映射
-- 【加速技巧（可选）】百万行带索引插入较慢，
--   可先 DROP INDEX、导入完再 ADD INDEX。
--   如需尝试，取消下面三行注释，并把本段放在导入前/后相应位置。
-- ------------------------------------------------------------
-- ALTER TABLE ods_geolocation DROP INDEX idx_geo_zip;

LOAD DATA INFILE 'D:/ENV/MySQL/DATA/Uploads/olist/olist_geolocation_dataset.csv'
INTO TABLE ods_geolocation
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(geolocation_zip_code_prefix, geolocation_lat, geolocation_lng, geolocation_city, geolocation_state);
SHOW WARNINGS;

-- ALTER TABLE ods_geolocation ADD INDEX idx_geo_zip (geolocation_zip_code_prefix);


-- ============================================================
-- 步骤 3：导入结果校验
-- ============================================================
-- 期望行数（与源文件记录数一致）：
--   ods_customers            99,441
--   ods_sellers               3,095
--   ods_products             32,951
--   ods_category_translation     71
--   ods_orders               99,441
--   ods_order_items         112,650
--   ods_order_payments      103,886
--   ods_order_reviews       100,000
--   ods_geolocation       1,000,163
--   合计                  1,551,698
-- ------------------------------------------------------------
SELECT 'ods_customers'            AS 表名, COUNT(*) AS 实际行数, 99441     AS 期望行数 FROM ods_customers
UNION ALL SELECT 'ods_sellers',              COUNT(*), 3095                 FROM ods_sellers
UNION ALL SELECT 'ods_products',             COUNT(*), 32951                FROM ods_products
UNION ALL SELECT 'ods_category_translation', COUNT(*), 71                   FROM ods_category_translation
UNION ALL SELECT 'ods_orders',               COUNT(*), 99441                FROM ods_orders
UNION ALL SELECT 'ods_order_items',          COUNT(*), 112650               FROM ods_order_items
UNION ALL SELECT 'ods_order_payments',       COUNT(*), 103886               FROM ods_order_payments
UNION ALL SELECT 'ods_order_reviews',        COUNT(*), 100000               FROM ods_order_reviews
UNION ALL SELECT 'ods_geolocation',          COUNT(*), 1000163              FROM ods_geolocation;
