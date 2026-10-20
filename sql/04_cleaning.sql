-- ============================================================
-- 脚本 04：数据清洗（ODS → DWD）
-- ============================================================
-- 产出 8 张表：4 张维度表 + 4 张事实表
--
-- 【总原则】
--   清洗 ≠ 删除。异常数据一律「打标」，由查询层按需过滤。
--   理由：删除会丢数据且不可回溯；打标保留完整性，随时能统计异常规模。
--
-- 【执行顺序】
--   维度表先建（事实表要 JOIN 维度表补充字段），事实表后建。
--
-- 【依赖】
--   需先执行完 03_load_data.sql / 03c / 03d，ODS 层 9 张表数据完整。
-- ============================================================

USE olist_db;

-- 可重复执行：先删旧表
DROP TABLE IF EXISTS dim_geolocation;
DROP TABLE IF EXISTS dim_customer;
DROP TABLE IF EXISTS dim_product;
DROP TABLE IF EXISTS dim_seller;
DROP TABLE IF EXISTS dwd_orders;
DROP TABLE IF EXISTS dwd_order_items;
DROP TABLE IF EXISTS dwd_payments;
DROP TABLE IF EXISTS dwd_reviews;


-- ============================================================
-- 任务 1：dim_geolocation —— 邮编地域维度（100 万行 → 1.9 万行）
-- ============================================================
-- 【核心问题】
--   原表 1,000,163 行，只有 19,015 个唯一邮编，平均每邮编 52.6 行，
--   最严重的邮编 24220 有 1,146 行。
--   若直接 JOIN 事实表，订单行数会被放大 52 倍 → GMV 等指标全部虚高。
--   这是数据仓库里最经典的事故之一。
--
-- 【聚合规则】
--   经纬度：AVG()，但先剔除越界坐标（42 条超出巴西范围）
--           —— 越界值会把均值拉飞，先剔除再加权平均
--   城市/州：众数（出现次数最多的），用 ROW_NUMBER() 取第 1
--           —— 551 个邮编对应多个城市名（拼写不一致），众数最稳
--   源行数：保留 COUNT(*)，便于回溯「这个邮编当时有多少条记录」
--
-- 【为什么不用 MIN/MAX 或任取一条】
--   任取一条 → 不可复现，重跑结果会变
--   MIN/MAX  → 会取到离群值
--   AVG+去异常 → 稳定、可复现、可解释
-- ============================================================
CREATE TABLE dim_geolocation (
    zip_code_prefix VARCHAR(5)   NOT NULL COMMENT '邮编前5位',
    latitude        DECIMAL(10,6) NULL    COMMENT '纬度（同邮编均值，已剔除越界值）',
    longitude       DECIMAL(10,6) NULL    COMMENT '经度（同邮编均值，已剔除越界值）',
    city            VARCHAR(50)  NULL     COMMENT '城市（同邮编众数）',
    state           CHAR(2)      NULL     COMMENT '州（同邮编众数）',
    source_rows     INT          NOT NULL DEFAULT 0 COMMENT '该邮编在原始表中的行数',
    PRIMARY KEY (zip_code_prefix),
    KEY idx_state_city (state, city)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='邮编地域维度（已按邮编聚合去重）';

-- 注意：以「全表邮编清单」为基准 LEFT JOIN，
-- 保证那 42 条越界坐标涉及的邮编不会整体丢失（只是经纬度为 NULL）
INSERT INTO dim_geolocation (zip_code_prefix, latitude, longitude, city, state, source_rows)
SELECT
    z.zip,
    c.lat,
    c.lng,
    r.city,
    r.state,
    COALESCE(c.cnt, 0)
FROM (SELECT DISTINCT geolocation_zip_code_prefix AS zip FROM ods_geolocation) z
LEFT JOIN (
    -- 剔除越界坐标后按邮编求均值
    SELECT geolocation_zip_code_prefix AS zip,
           ROUND(AVG(geolocation_lat), 6) AS lat,
           ROUND(AVG(geolocation_lng), 6) AS lng,
           COUNT(*)                       AS cnt
    FROM ods_geolocation
    WHERE geolocation_lat BETWEEN -34 AND 5
      AND geolocation_lng BETWEEN -74 AND -34
    GROUP BY geolocation_zip_code_prefix
) c ON z.zip = c.zip
LEFT JOIN (
    -- 每个邮编取出现次数最多的城市/州组合
    SELECT zip, city, state
    FROM (
        SELECT geolocation_zip_code_prefix AS zip,
               geolocation_city           AS city,
               geolocation_state          AS state,
               ROW_NUMBER() OVER (
                   PARTITION BY geolocation_zip_code_prefix
                   ORDER BY COUNT(*) DESC, geolocation_city
               ) AS rn
        FROM ods_geolocation
        GROUP BY geolocation_zip_code_prefix, geolocation_city, geolocation_state
    ) t
    WHERE rn = 1
) r ON z.zip = r.zip;


-- ============================================================
-- 任务 2：dim_customer —— 真实客户维度（99,441 → 96,096）
-- ============================================================
-- 【本项目的核心业务陷阱】
--   customer_id        ：每下一个订单就生成一个新值（99,441 个）
--   customer_unique_id ：同一个人的真实身份，跨订单不变（96,096 个）
--
--   若用 customer_id 算复购率 → 结果恒为 0%，因为每个 customer_id 只出现一次，
--   而且不会报错，你会得到一个「看起来正常但完全错误」的结论。
--
-- 【设计】
--   以 customer_unique_id 为主键，冗余首单信息 + 订单数 + 首末单时间。
--   城市/邮编取该用户所有记录中的最小值，仅作画像参考；
--   精确地址以订单级（dwd_orders）为准。
-- ============================================================
CREATE TABLE dim_customer (
    customer_unique_id VARCHAR(32) NOT NULL COMMENT '真实客户ID（跨订单不变）',
    first_customer_id  VARCHAR(32) NULL     COMMENT '首个订单对应的 customer_id',
    zip_code_prefix    VARCHAR(5)  NULL     COMMENT '邮编（取最小值，仅画像参考）',
    city               VARCHAR(50) NULL     COMMENT '城市',
    state              CHAR(2)     NULL     COMMENT '州',
    first_order_ts     DATETIME    NULL     COMMENT '首单时间',
    last_order_ts      DATETIME    NULL     COMMENT '末单时间',
    order_count        INT         NOT NULL DEFAULT 0 COMMENT '累计订单数',
    PRIMARY KEY (customer_unique_id),
    KEY idx_state (state),
    KEY idx_order_count (order_count)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='真实客户维度（按 customer_unique_id 聚合）';

INSERT INTO dim_customer (
    customer_unique_id, first_customer_id, zip_code_prefix, city, state,
    first_order_ts, last_order_ts, order_count
)
SELECT
    c.customer_unique_id,
    MIN(c.customer_id),
    MIN(c.customer_zip_code_prefix),
    MIN(c.customer_city),
    MIN(c.customer_state),
    MIN(o.order_purchase_timestamp),
    MAX(o.order_purchase_timestamp),
    COUNT(DISTINCT o.order_id)
FROM ods_customers c
LEFT JOIN ods_orders o ON c.customer_id = o.customer_id
GROUP BY c.customer_unique_id;


-- ============================================================
-- 任务 3：dim_product —— 商品维度（32,951）
-- ============================================================
-- 品类补全：610 条缺失 + 13 条翻译表没有 → 统一填 'unknown'
-- 【为什么不删】
--   这些商品有真实成交记录，删掉会低估 GMV 和销量。
--   填 'unknown' 让它们进入「未知品类」桶，总量不丢，分析时可单独查看。
-- ============================================================
CREATE TABLE dim_product (
    product_id            VARCHAR(32)  NOT NULL COMMENT '商品ID',
    category_pt           VARCHAR(100) NULL     COMMENT '品类（葡语原名）',
    category_en           VARCHAR(100) NULL     COMMENT '品类（英文）',
    weight_g              INT          NULL     COMMENT '重量（克）',
    length_cm             INT          NULL     COMMENT '长（厘米）',
    height_cm             INT          NULL     COMMENT '高（厘米）',
    width_cm              INT          NULL     COMMENT '宽（厘米）',
    name_length           INT          NULL     COMMENT '商品名长度',
    description_length    INT          NULL     COMMENT '描述长度',
    photos_qty            INT          NULL     COMMENT '图片数量',
    has_category          TINYINT      NOT NULL DEFAULT 1 COMMENT '是否有品类（0=缺失）',
    PRIMARY KEY (product_id),
    KEY idx_category_en (category_en)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='商品维度';

INSERT INTO dim_product (
    product_id, category_pt, category_en, weight_g, length_cm, height_cm, width_cm,
    name_length, description_length, photos_qty, has_category
)
SELECT
    p.product_id,
    p.product_category_name,
    COALESCE(t.product_category_name_english, 'unknown'),
    p.product_weight_g,
    p.product_length_cm,
    p.product_height_cm,
    p.product_width_cm,
    p.product_name_lenght,          -- 源数据拼写就是 lenght（已确认）
    p.product_description_lenght,
    p.product_photos_qty,
    IF(p.product_category_name IS NULL, 0, 1)
FROM ods_products p
LEFT JOIN ods_category_translation t
       ON p.product_category_name = t.product_category_name;


-- ============================================================
-- 任务 4：dim_seller —— 卖家维度（3,095）
-- ============================================================
CREATE TABLE dim_seller (
    seller_id       VARCHAR(32) NOT NULL COMMENT '卖家ID',
    zip_code_prefix VARCHAR(5)  NULL     COMMENT '邮编',
    city            VARCHAR(50) NULL     COMMENT '城市',
    state           CHAR(2)     NULL     COMMENT '州',
    PRIMARY KEY (seller_id),
    KEY idx_state (state)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='卖家维度';

INSERT INTO dim_seller (seller_id, zip_code_prefix, city, state)
SELECT seller_id, seller_zip_code_prefix, seller_city, seller_state
FROM ods_sellers;


-- ============================================================
-- 任务 5：dwd_orders —— 订单事实（99,441）
-- ============================================================
-- 【派生指标】这是可直接引用的指标：
--   delivery_days   实际配送天数
--   estimated_days  承诺配送天数
--   late_days       延迟天数（负值=提前送达）
--   is_late         是否延迟（仅在已签收时有值）
--   is_time_anomaly 发货比下单早超过 24 小时（严重逻辑错误，仅 2 条）
--   is_delivered    是否已签收
--
-- 【为什么保留非 delivered 订单】
--   取消率、缺货率本身就是业务指标。过滤动作放在查询层：
--   WHERE is_delivered = 1
--
-- 【为什么 is_time_anomaly 阈值设 24 小时】
--   实测 166 条「发货早于下单」中，160 条只是同小时内分钟顺序颠倒
--   （提前 0-1 小时，属采集精度问题），真正的严重异常只有 2 条。
--   阈值 24 小时能把噪音和真异常分开。
-- ============================================================
CREATE TABLE dwd_orders (
    order_id           VARCHAR(32) NOT NULL COMMENT '订单ID',
    customer_id        VARCHAR(32) NULL     COMMENT '订单级客户ID（每单唯一）',
    customer_unique_id VARCHAR(32) NULL     COMMENT '真实客户ID（跨订单）',
    order_status       VARCHAR(20) NULL     COMMENT '订单状态',
    purchase_ts        DATETIME    NULL     COMMENT '下单时间',
    approved_ts        DATETIME    NULL     COMMENT '审核通过时间',
    carrier_ts         DATETIME    NULL     COMMENT '交付承运商时间',
    delivered_ts       DATETIME    NULL     COMMENT '客户签收时间',
    estimated_ts       DATETIME    NULL     COMMENT '预计送达时间',
    delivery_days      INT         NULL     COMMENT '实际配送天数',
    estimated_days     INT         NULL     COMMENT '承诺配送天数',
    late_days          INT         NULL     COMMENT '延迟天数（负=提前）',
    is_late            TINYINT     NULL     COMMENT '是否延迟（仅已签收有效）',
    is_time_anomaly    TINYINT     NOT NULL DEFAULT 0 COMMENT '是否严重时间异常',
    is_delivered       TINYINT     NOT NULL DEFAULT 0 COMMENT '是否已签收',
    purchase_date      DATE        NULL     COMMENT '下单日期',
    purchase_year      SMALLINT    NULL     COMMENT '下单年',
    purchase_month     TINYINT     NULL     COMMENT '下单月',
    PRIMARY KEY (order_id),
    KEY idx_purchase_ts (purchase_ts),
    KEY idx_customer (customer_unique_id),
    KEY idx_status (order_status),
    KEY idx_delivered (is_delivered),
    KEY idx_year_month (purchase_year, purchase_month)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单事实表（含配送派生指标）';

INSERT INTO dwd_orders (
    order_id, customer_id, customer_unique_id, order_status,
    purchase_ts, approved_ts, carrier_ts, delivered_ts, estimated_ts,
    delivery_days, estimated_days, late_days, is_late,
    is_time_anomaly, is_delivered, purchase_date, purchase_year, purchase_month
)
SELECT
    o.order_id,
    o.customer_id,
    c.customer_unique_id,
    o.order_status,
    o.order_purchase_timestamp,
    o.order_approved_at,
    o.order_delivered_carrier_date,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,
    -- 实际配送天数：只有已签收才有意义
    DATEDIFF(o.order_delivered_customer_date, o.order_purchase_timestamp),
    -- 承诺配送天数
    DATEDIFF(o.order_estimated_delivery_date, o.order_purchase_timestamp),
    -- 延迟天数：早到为负
    DATEDIFF(o.order_delivered_customer_date, o.order_estimated_delivery_date),
    -- 是否延迟：仅已签收时判断，否则 NULL（不是 0，避免统计时被算成"准时"）
    -- 【口径说明】按"天"判断，不用时间戳直接比较。
    -- 原写法 `delivered_ts > estimated_ts` 有缺陷：estimated 的时间部分是 00:00:00，
    -- 当天下午送达也会被判为延迟，导致 is_late=1 但 late_days=0 自相矛盾（实测 1,292 单）。
    -- 业务含义是"承诺某日送达"，当日达成本就算准时，因此必须用 DATEDIFF > 0。
    CASE
        WHEN o.order_delivered_customer_date IS NULL THEN NULL
        WHEN DATEDIFF(o.order_delivered_customer_date, o.order_estimated_delivery_date) > 0 THEN 1
        ELSE 0
    END,
    -- 严重时间异常：发货比下单早 24 小时以上
    CASE
        WHEN o.order_delivered_carrier_date IS NOT NULL
         AND o.order_delivered_carrier_date < DATE_SUB(o.order_purchase_timestamp, INTERVAL 24 HOUR)
        THEN 1 ELSE 0
    END,
    IF(o.order_status = 'delivered', 1, 0),
    DATE(o.order_purchase_timestamp),
    YEAR(o.order_purchase_timestamp),
    MONTH(o.order_purchase_timestamp)
FROM ods_orders o
LEFT JOIN ods_customers c ON o.customer_id = c.customer_id;


-- ============================================================
-- 任务 6：dwd_order_items —— 订单明细事实（112,650）
-- ============================================================
-- 冗余 customer_unique_id：避免每次分析都要多 JOIN 一层，
-- 是数仓常见的「适度冗余换查询效率」。
-- ============================================================
CREATE TABLE dwd_order_items (
    order_id           VARCHAR(32)   NOT NULL COMMENT '订单ID',
    order_item_id      INT           NOT NULL COMMENT '订单内商品行号',
    product_id         VARCHAR(32)   NULL     COMMENT '商品ID',
    seller_id          VARCHAR(32)   NULL     COMMENT '卖家ID',
    customer_unique_id VARCHAR(32)   NULL     COMMENT '真实客户ID（冗余）',
    shipping_limit_date DATETIME     NULL     COMMENT '卖家承诺发货截止时间',
    price              DECIMAL(10,2) NULL     COMMENT '商品单价',
    freight_value      DECIMAL(10,2) NULL     COMMENT '运费',
    item_total         DECIMAL(10,2) NULL     COMMENT '商品+运费',
    PRIMARY KEY (order_id, order_item_id),
    KEY idx_product (product_id),
    KEY idx_seller (seller_id),
    KEY idx_customer (customer_unique_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单明细事实表';

INSERT INTO dwd_order_items (
    order_id, order_item_id, product_id, seller_id, customer_unique_id,
    shipping_limit_date, price, freight_value, item_total
)
SELECT
    i.order_id,
    i.order_item_id,
    i.product_id,
    i.seller_id,
    c.customer_unique_id,
    i.shipping_limit_date,
    i.price,
    i.freight_value,
    i.price + i.freight_value
FROM ods_order_items i
LEFT JOIN ods_orders o    ON i.order_id = o.order_id
LEFT JOIN ods_customers c ON o.customer_id = c.customer_id;


-- ============================================================
-- 任务 7：dwd_payments —— 支付聚合到订单级（103,886 → 99,441）
-- ============================================================
-- 【必须聚合的原因】
--   原表 103,886 行 > 99,441 个订单 → 一单可能多笔支付（组合支付）。
--   若直接 JOIN 订单明细，订单金额会被重复计算 → GMV 虚高。
--
-- 【main_payment_type 取金额最大的那种】
--   不用众数：众数取的是「笔数最多」，但组合支付里可能是小额支付笔数多，
--   金额最大的才代表主要支付方式。
--
-- 【9 条支付金额为 0】
--   保留并标记 has_zero_payment，可能是全额优惠/赠品订单。
-- ============================================================
CREATE TABLE dwd_payments (
    order_id            VARCHAR(32)   NOT NULL COMMENT '订单ID',
    payment_total       DECIMAL(12,2) NULL     COMMENT '支付总额',
    payment_count       INT           NOT NULL DEFAULT 0 COMMENT '支付笔数',
    max_installments    INT           NULL     COMMENT '最大分期数',
    main_payment_type   VARCHAR(20)   NULL     COMMENT '主要支付方式（金额最大）',
    has_zero_payment    TINYINT       NOT NULL DEFAULT 0 COMMENT '是否含0元支付记录',
    PRIMARY KEY (order_id),
    KEY idx_payment_type (main_payment_type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单支付汇总（已聚合到订单粒度）';

INSERT INTO dwd_payments (
    order_id, payment_total, payment_count, max_installments,
    main_payment_type, has_zero_payment
)
SELECT
    order_id,
    SUM(payment_value),
    COUNT(*),
    MAX(payment_installments),
    -- 按金额降序拼接后取第一个，即金额最大的支付方式
    SUBSTRING_INDEX(GROUP_CONCAT(payment_type ORDER BY payment_value DESC, payment_type), ',', 1),
    MAX(payment_value = 0)
FROM ods_order_payments
GROUP BY order_id;


-- ============================================================
-- 任务 8：dwd_reviews —— 评价去重（100,000 → 99,441）
-- ============================================================
-- 【555 个订单有多条评价，取最新一条】
--
-- 【为什么取最新而不是平均/第一条】
--   取平均分 → 4.5 这种小数，破坏「1-5 星整数」的语义
--   取第一条 → 可能是误点后重评，不代表最终态度
--   取最新   → 代表用户的最终评价，重评通常是修正
--
-- 【保留 review_count】
--   让下游知道这个订单被评过几次。反复改评价的订单本身可能有故事。
-- ============================================================
CREATE TABLE dwd_reviews (
    order_id        VARCHAR(32)  NOT NULL COMMENT '订单ID',
    review_id       VARCHAR(32)  NULL     COMMENT '评价ID（最新一条）',
    review_score    TINYINT      NULL     COMMENT '评分 1-5',
    comment_title   VARCHAR(255) NULL     COMMENT '评价标题',
    comment_message TEXT         NULL     COMMENT '评价内容',
    creation_ts     DATETIME     NULL     COMMENT '评价创建时间',
    answer_ts       DATETIME     NULL     COMMENT '评价回复时间',
    review_count    INT          NOT NULL DEFAULT 1 COMMENT '该订单被评价次数',
    PRIMARY KEY (order_id),
    KEY idx_score (review_score)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单评价（一单一条，取最新）';

INSERT INTO dwd_reviews (
    order_id, review_id, review_score, comment_title, comment_message,
    creation_ts, answer_ts, review_count
)
SELECT
    order_id, review_id, review_score, review_comment_title, review_comment_message,
    review_creation_date, review_answer_timestamp, review_count
FROM (
    SELECT
        r.*,
        COUNT(*) OVER (PARTITION BY r.order_id) AS review_count,
        ROW_NUMBER() OVER (
            PARTITION BY r.order_id
            ORDER BY r.review_creation_date DESC, r.review_answer_timestamp DESC, r.review_id
        ) AS rn
    FROM ods_order_reviews r
) t
WHERE rn = 1;


-- ============================================================
-- 校验：8 张表行数
-- ============================================================
SELECT 'dim_geolocation' AS 表, COUNT(*) AS 行数, 19015 AS 期望 FROM dim_geolocation
UNION ALL SELECT 'dim_customer',      COUNT(*), 96096   FROM dim_customer
UNION ALL SELECT 'dim_product',       COUNT(*), 32951   FROM dim_product
UNION ALL SELECT 'dim_seller',        COUNT(*), 3095    FROM dim_seller
UNION ALL SELECT 'dwd_orders',        COUNT(*), 99441   FROM dwd_orders
UNION ALL SELECT 'dwd_order_items',   COUNT(*), 112650  FROM dwd_order_items
UNION ALL SELECT 'dwd_payments',      COUNT(*), 99441   FROM dwd_payments
UNION ALL SELECT 'dwd_reviews',       COUNT(*), 99441   FROM dwd_reviews;
