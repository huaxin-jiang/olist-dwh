-- ============================================================
-- Olist 电商订单数据分析平台
-- 脚本 02：建表（ODS 原始层，共 9 张表）
-- 数据库：olist_db
-- 引擎：InnoDB　字符集：utf8mb4
-- ============================================================
-- 建表顺序说明：被引用的表先建（虽然本项目不建物理外键，
-- 但保持逻辑顺序，便于理解和后续维护）
-- ============================================================

USE olist_db;

-- ------------------------------------------------------------
-- 1. 客户表（原始层）
-- 注意：customer_id 是"订单级"ID（每单一个），
--       customer_unique_id 才是"自然人"ID（跨订单不变）
--       算复购/留存必须用 customer_unique_id
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ods_customers;
CREATE TABLE ods_customers (
    customer_id              VARCHAR(32)  NOT NULL COMMENT '客户ID（订单级，每单一个）',
    customer_unique_id       VARCHAR(32)  NOT NULL COMMENT '客户唯一ID（自然人级，跨订单不变）',
    customer_zip_code_prefix VARCHAR(5)   NULL     COMMENT '客户邮编前缀',
    customer_city            VARCHAR(50)  NULL     COMMENT '客户所在城市',
    customer_state           CHAR(2)      NULL     COMMENT '客户所在州（2位缩写）',
    PRIMARY KEY (customer_id),
    KEY idx_customer_unique_id (customer_unique_id) COMMENT '用于复购/留存分析'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='客户表（原始）';


-- ------------------------------------------------------------
-- 2. 卖家表（原始层）
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ods_sellers;
CREATE TABLE ods_sellers (
    seller_id              VARCHAR(32) NOT NULL COMMENT '卖家ID',
    seller_zip_code_prefix VARCHAR(5)  NULL     COMMENT '卖家邮编前缀',
    seller_city            VARCHAR(50) NULL     COMMENT '卖家所在城市',
    seller_state           CHAR(2)     NULL     COMMENT '卖家所在州',
    PRIMARY KEY (seller_id),
    KEY idx_seller_zip (seller_zip_code_prefix) COMMENT '用于关联地理表'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='卖家表（原始）';


-- ------------------------------------------------------------
-- 3. 商品表（原始层）
-- 注意：product_name_lenght / product_description_lenght
--       是数据源本身的拼写错误（应为 length），
--       这里保留原拼写以保证与源文件一致，但注释标明
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ods_products;
CREATE TABLE ods_products (
    product_id                 VARCHAR(32)  NOT NULL COMMENT '商品ID',
    product_category_name      VARCHAR(100) NULL     COMMENT '商品品类名（葡萄牙语，有缺失）',
    product_name_lenght        INT          NULL     COMMENT '商品名称长度（源字段拼写如此，实为length）',
    product_description_lenght INT          NULL     COMMENT '商品描述长度（源字段拼写如此，实为length）',
    product_photos_qty         INT          NULL     COMMENT '商品图片数量',
    product_weight_g           INT          NULL     COMMENT '商品重量（克）',
    product_length_cm          INT          NULL     COMMENT '商品长度（厘米）',
    product_height_cm          INT          NULL     COMMENT '商品高度（厘米）',
    product_width_cm           INT          NULL     COMMENT '商品宽度（厘米）',
    PRIMARY KEY (product_id),
    KEY idx_product_category (product_category_name) COMMENT '用于按品类分析'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='商品表（原始）';


-- ------------------------------------------------------------
-- 4. 品类翻译表（原始层）
-- 注意：CSV 文件带 BOM 头，导入时需处理
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ods_category_translation;
CREATE TABLE ods_category_translation (
    product_category_name         VARCHAR(100) NOT NULL COMMENT '品类名（葡萄牙语）',
    product_category_name_english VARCHAR(100) NULL     COMMENT '品类名（英文）',
    PRIMARY KEY (product_category_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='品类名称翻译表（葡→英）';


-- ------------------------------------------------------------
-- 5. 订单主表（原始层）
-- 核心表：所有订单维度的分析都从这里出发
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ods_orders;
CREATE TABLE ods_orders (
    order_id                      VARCHAR(32) NOT NULL COMMENT '订单ID',
    customer_id                   VARCHAR(32) NOT NULL COMMENT '客户ID（关联 ods_customers）',
    order_status                  VARCHAR(20) NOT NULL COMMENT '订单状态：delivered/shipped/canceled等',
    order_purchase_timestamp      DATETIME    NULL     COMMENT '下单时间',
    order_approved_at             DATETIME    NULL     COMMENT '支付通过时间（未支付为NULL）',
    order_delivered_carrier_date  DATETIME    NULL     COMMENT '交给物流时间（未发货为NULL）',
    order_delivered_customer_date DATETIME    NULL     COMMENT '客户签收时间（未签收为NULL）',
    order_estimated_delivery_date DATETIME    NULL     COMMENT '预计送达时间',
    PRIMARY KEY (order_id),
    KEY idx_customer_id    (customer_id)                COMMENT '用于关联客户表',
    KEY idx_order_status   (order_status)               COMMENT '用于按状态筛选',
    KEY idx_purchase_time  (order_purchase_timestamp)   COMMENT '用于时间范围查询'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单主表（原始）';


-- ------------------------------------------------------------
-- 6. 订单明细表（原始层）
-- 核心表：金额、商品、卖家的分析都从这里出发
-- 联合主键：(order_id, order_item_id)
--   一个订单可含多个商品行，单独任一字段都不唯一
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ods_order_items;
CREATE TABLE ods_order_items (
    order_id           VARCHAR(32)    NOT NULL COMMENT '订单ID',
    order_item_id      INT            NOT NULL COMMENT '订单内商品行序号（1,2,3...）',
    product_id         VARCHAR(32)    NOT NULL COMMENT '商品ID',
    seller_id          VARCHAR(32)    NOT NULL COMMENT '卖家ID',
    shipping_limit_date DATETIME      NULL     COMMENT '发货截止时间',
    price              DECIMAL(10,2)  NULL     COMMENT '商品单价（必须用DECIMAL保证精确）',
    freight_value      DECIMAL(10,2)  NULL     COMMENT '运费',
    PRIMARY KEY (order_id, order_item_id),
    KEY idx_product_id (product_id),
    KEY idx_seller_id  (seller_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单明细表（原始）';


-- ------------------------------------------------------------
-- 7. 支付表（原始层）
-- 一个订单可有多笔支付，故用联合主键
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ods_order_payments;
CREATE TABLE ods_order_payments (
    order_id             VARCHAR(32)   NOT NULL COMMENT '订单ID',
    payment_sequential   INT           NOT NULL COMMENT '同一订单内的第N笔支付',
    payment_type         VARCHAR(20)   NULL     COMMENT '支付方式：credit_card/boleto/voucher/debit_card',
    payment_installments INT           NULL     COMMENT '分期数',
    payment_value        DECIMAL(10,2) NULL     COMMENT '支付金额',
    PRIMARY KEY (order_id, payment_sequential),
    KEY idx_payment_type (payment_type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='支付记录表（原始）';


-- ------------------------------------------------------------
-- 8. 评价表（原始层，100,000 行）
-- 【重要】review_id 并不唯一！
--   实测：802 个 review_id 重复（777 个重复 2 次、25 个重复 3 次），
--   共多出 827 行。源系统把同一个 review_id 挂到了不同订单上，
--   内容与时间戳完全相同，仅 order_id 不同。
--   (review_id, order_id) 组合经验证 100,000 条全部唯一 → 用联合主键。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ods_order_reviews;
CREATE TABLE ods_order_reviews (
    review_id               VARCHAR(32)  NOT NULL COMMENT '评价ID（单独不唯一，需与order_id组合）',
    order_id                VARCHAR(32)  NOT NULL COMMENT '订单ID',
    review_score            TINYINT      NULL     COMMENT '评分（1-5）',
    review_comment_title    VARCHAR(255) NULL     COMMENT '评价标题（大量为空）',
    review_comment_message  TEXT         NULL     COMMENT '评价内容（大量为空，用TEXT）',
    review_creation_date    DATETIME     NULL     COMMENT '评价创建时间',
    review_answer_timestamp DATETIME     NULL     COMMENT '评价回复时间',
    PRIMARY KEY (review_id, order_id),
    KEY idx_review_order_id (order_id),
    KEY idx_review_score    (review_score)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单评价表（原始）';


-- ------------------------------------------------------------
-- 9. 地理位置表（原始层）★ 100万行，性能优化主战场
-- 不设主键：同一邮编有大量重复记录，没有唯一字段
-- 这张表在第 4 步需要按邮编去重聚合
-- ------------------------------------------------------------
DROP TABLE IF EXISTS ods_geolocation;
CREATE TABLE ods_geolocation (
    geolocation_zip_code_prefix VARCHAR(5)     NULL COMMENT '邮编前缀',
    geolocation_lat             DECIMAL(11,8)  NULL COMMENT '纬度（-90~90）',
    geolocation_lng             DECIMAL(11,8)  NULL COMMENT '经度（-180~180）',
    geolocation_city            VARCHAR(50)    NULL COMMENT '城市',
    geolocation_state           CHAR(2)        NULL COMMENT '州（2位缩写）',
    KEY idx_geo_zip (geolocation_zip_code_prefix) COMMENT '用于按邮编关联'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='地理位置表（原始，100万行）';


-- ------------------------------------------------------------
-- 验证：查看所有表及其注释
-- ------------------------------------------------------------
SELECT
    TABLE_NAME    AS 表名,
    TABLE_COMMENT AS 说明,
    TABLE_ROWS    AS 预估行数
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'olist_db'
ORDER BY TABLE_NAME;
