-- ============================================================
-- 第 5 步：业务分析查询（10 个核心查询 + RFM 分层）
-- 数据库：olist_db
-- 数据层：DWD / DIM
-- ------------------------------------------------------------
-- 【全局口径约定】
--   1. 时间窗口：2017-01-01 ~ 2018-08-31
--      原因：2016 年数据刚起步（2016-11 整月为 0），2018-09 之后
--            数据被截断（仅 20 单）。不限定会导致趋势图首尾断崖。
--   2. GMV 口径：order_status NOT IN ('canceled','unavailable')
--      canceled / unavailable 的订单未真实成交，计入会虚增 GMV。
--   3. GMV 金额口径：SUM(item_total) 即 price + freight_value
--      若只看商品金额用 SUM(price)，两者差 16.5%（运费）
--   4. 复购口径：customer_unique_id（真实人），不是 customer_id
-- ============================================================

USE olist_db;

-- ============================================================
-- Q1  月度 GMV 趋势 + 环比增长率
-- ------------------------------------------------------------
-- 业务问题：业务在增长还是萎缩？增速如何？
-- 技术点：CTE + LAG() 窗口函数算环比（不用自连接，避免 O(n²) 扫描）
-- 实现要点：为什么用 LAG 而不是 self-join？
--         LAG 只需一次排序扫描；self-join 需要两次扫描 + 连接。
-- ============================================================
WITH monthly AS (
    SELECT o.purchase_year * 100 + o.purchase_month AS ym,
           COUNT(DISTINCT o.order_id)               AS order_cnt,
           SUM(i.item_total)                        AS gmv
    FROM dwd_orders o
    JOIN dwd_order_items i ON o.order_id = i.order_id
    WHERE o.purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
      AND o.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY ym
)
SELECT ym                                          AS 年月,
       order_cnt                                   AS 订单数,
       ROUND(gmv, 2)                               AS GMV,
       LAG(ROUND(gmv, 2)) OVER (ORDER BY ym)        AS 上月GMV,
       ROUND(gmv / LAG(gmv) OVER (ORDER BY ym) * 100 - 100, 2) AS 环比增长率
FROM monthly
ORDER BY ym;


-- ============================================================
-- Q2  订单金额分布：均值 / 中位数 / P90 / 最大值
-- ------------------------------------------------------------
-- 业务问题：客单价到底是多少？"平均"能代表真实情况吗？
-- 技术点：PERCENT_RANK / CUME_DIST / NTILE 求分位数
--         先聚合到订单粒度再算分位，不能对明细行算（否则按商品行算，
--         一个多商品订单会被拆成多份，结论完全错）
-- 实现要点：为什么电商客单价必须报中位数而不是平均值？
--         金额分布右偏（少数大额订单拉高均值），均值 > 中位数。
-- ============================================================
WITH order_amount AS (
    SELECT o.order_id, SUM(i.item_total) AS amt
    FROM dwd_orders o
    JOIN dwd_order_items i ON o.order_id = i.order_id
    WHERE o.purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
      AND o.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY o.order_id
),
ranked AS (
    SELECT amt,
           ROW_NUMBER() OVER (ORDER BY amt)   AS rn,
           COUNT(*)    OVER ()                AS total
    FROM order_amount
)
SELECT ROUND(AVG(amt), 2)      AS 均值,
       ROUND(MAX(CASE WHEN rn = CEIL(total * 0.50) THEN amt END), 2) AS 中位数P50,
       ROUND(MAX(CASE WHEN rn = CEIL(total * 0.90) THEN amt END), 2) AS P90,
       ROUND(MAX(CASE WHEN rn = CEIL(total * 0.99) THEN amt END), 2) AS P99,
       ROUND(MAX(amt), 2)      AS 最大值,
       COUNT(*)                AS 订单数
FROM ranked;


-- ============================================================
-- Q3  品类 GMV 排行 + 帕累托累计占比
-- ------------------------------------------------------------
-- 业务问题：哪些品类是收入支柱？收入集中度如何（是否符合二八法则）？
-- 技术点：SUM() OVER (ORDER BY ...) 累计求和 = 帕累托分析
-- 实现要点：品类名要用 dim_product 的英文名；有 610 个商品无品类，
--         清洗时已填 'unknown'，这里要能看到它占了多少（数据质量暴露）
-- ============================================================
WITH cat AS (
    SELECT COALESCE(p.category_en, 'unknown') AS category,
           SUM(i.item_total)                  AS gmv,
           COUNT(DISTINCT i.order_id)         AS order_cnt
    FROM dwd_order_items i
    JOIN dwd_orders  o ON i.order_id   = o.order_id
    LEFT JOIN dim_product p ON i.product_id = p.product_id
    WHERE o.purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
      AND o.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY category
)
SELECT RANK() OVER (ORDER BY gmv DESC)                     AS 排名,
       category                                            AS 品类,
       ROUND(gmv, 2)                                       AS GMV,
       order_cnt                                           AS 订单数,
       ROUND(gmv / SUM(gmv) OVER () * 100, 2)              AS 占比,
       ROUND(SUM(gmv) OVER (ORDER BY gmv DESC)
             / SUM(gmv) OVER () * 100, 2)                  AS 累计占比
FROM cat
ORDER BY gmv DESC
LIMIT 15;


-- ============================================================
-- Q4  州维度市场分布（GMV / 订单 / 客单价 / 延迟率 四合一）
-- ------------------------------------------------------------
-- 业务问题：哪个州是主力市场？各州的服务质量是否均衡？
-- 技术点：多个 LEFT JOIN 聚合，注意先聚合到订单粒度再去 JOIN 维度，
--         否则订单明细的行数会被放大，GMV 会翻倍。
-- 实现要点：一个 customer_unique_id 只属于一个州吗？（是，取首单地址）
-- 【口径一致】延迟率必须按"订单数"加权，不能先算每个客户的延迟率再平均，
--           否则每个客户权重相同，"买了 10 单都延迟"和"买 1 单延迟"等价，
--           结果会与 Q7 对不上（SP 会算成 5.91% 而不是 4.50%）。
-- ============================================================
WITH order_level AS (
    SELECT o.order_id,
           o.customer_unique_id,
           o.is_delivered,
           o.delivery_days,
           o.is_late,
           SUM(i.item_total) AS amt
    FROM dwd_orders o
    JOIN dwd_order_items i ON o.order_id = i.order_id
    WHERE o.purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
      AND o.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY o.order_id, o.customer_unique_id, o.is_delivered, o.delivery_days, o.is_late
)
SELECT c.state                                  AS 州,
       COUNT(*)                                 AS 订单数,
       ROUND(SUM(ol.amt), 2)                    AS GMV,
       ROUND(AVG(ol.amt), 2)                    AS 客单价,
       ROUND(SUM(ol.amt) / SUM(SUM(ol.amt)) OVER () * 100, 2) AS GMV占比,
       ROUND(AVG(CASE WHEN ol.is_delivered = 1 THEN ol.delivery_days END), 1) AS 平均配送天数,
       ROUND(SUM(CASE WHEN ol.is_delivered = 1 AND ol.is_late = 1 THEN 1 ELSE 0 END)
             * 100.0 / NULLIF(SUM(ol.is_delivered = 1), 0), 2)              AS 延迟率
FROM order_level ol
JOIN dim_customer c ON ol.customer_unique_id = c.customer_unique_id
GROUP BY c.state
ORDER BY GMV DESC
LIMIT 12;


-- ============================================================
-- Q5  复购率与复购间隔
-- ------------------------------------------------------------
-- 业务问题：客户会回来买第二次吗？多久回来一次？
-- 技术点：LAG() 按客户分区算下单间隔；DATEDIFF 求天数
-- 实现要点：【核心陷阱】复购必须用 customer_unique_id。
--         用 customer_id 会算出 0% 复购率——因为每笔订单都生成新
--         的 customer_id，系统不报错，结论完全错误。
-- ============================================================
-- 5.1 复购率总览
SELECT COUNT(*)                                  AS 客户数,
       SUM(order_count > 1)                      AS 复购客户数,
       ROUND(SUM(order_count > 1) * 100.0 / COUNT(*), 2) AS 复购率
FROM dim_customer;

-- 5.2 复购间隔分布（只看有复购的客户）
WITH seq AS (
    SELECT customer_unique_id,
           purchase_ts,
           LAG(purchase_ts) OVER (PARTITION BY customer_unique_id
                                  ORDER BY purchase_ts) AS prev_ts
    FROM dwd_orders
    WHERE purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
      AND order_status NOT IN ('canceled', 'unavailable')
)
SELECT CASE
         WHEN gap <= 30  THEN '1. 30天内'
         WHEN gap <= 60  THEN '2. 31-60天'
         WHEN gap <= 90  THEN '3. 61-90天'
         WHEN gap <= 180 THEN '4. 91-180天'
         ELSE                 '5. 180天以上'
       END                        AS 复购间隔区间,
       COUNT(*)                   AS 复购次数,
       ROUND(AVG(gap), 1)         AS 平均天数
FROM (SELECT DATEDIFF(purchase_ts, prev_ts) AS gap
      FROM seq WHERE prev_ts IS NOT NULL) t
GROUP BY 复购间隔区间
ORDER BY 复购间隔区间;

-- 5.3 剔除"拆单"后的真实复购率
-- ------------------------------------------------------------
-- 【为什么要做这一步】复购间隔里 928/3,203（29%）是"同一天下单"，
-- 这不是真的复购，而是同一笔购买被拆成多个订单（不同卖家分开发货）。
-- 直接报 3.04% 会高估客户忠诚度，真实跨日复购只有 2.17%。
-- 实现要点：指标不能只用一种口径，必须验证"这个数在业务上说得通吗"。
WITH per_cust AS (
    SELECT customer_unique_id,
           COUNT(DISTINCT order_id)      AS orders,
           COUNT(DISTINCT purchase_date) AS distinct_days
    FROM dwd_orders
    WHERE purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
      AND order_status NOT IN ('canceled', 'unavailable')
    GROUP BY customer_unique_id
)
SELECT COUNT(*)                                     AS 客户数,
       SUM(orders > 1)                              AS 含拆单复购人数,
       ROUND(SUM(orders > 1) * 100.0 / COUNT(*), 2) AS 复购率_含拆单,
       SUM(distinct_days > 1)                       AS 真实跨日复购人数,
       ROUND(SUM(distinct_days > 1) * 100.0 / COUNT(*), 2) AS 复购率_剔除拆单
FROM per_cust;


-- ============================================================
-- Q6  用户留存：按首购月份分组（Cohort 分析）
-- ------------------------------------------------------------
-- 业务问题：某月新客，后面几个月还回来买吗？留存曲线什么样？
-- 技术点：FIRST_VALUE() 取首购月 → 计算 "第N月" → 透视成留存表
--         这是数仓/数据岗常见的高频问题，也是最能体现窗口函数功力的题
-- 实现要点：留存的分母是"该月新增客户数"，不是该月订单数
-- ============================================================
WITH first_order AS (
    SELECT customer_unique_id,
           DATE_FORMAT(MIN(purchase_ts), '%Y-%m') AS cohort_month
    FROM dwd_orders
    WHERE purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
      AND order_status NOT IN ('canceled', 'unavailable')
    GROUP BY customer_unique_id
),
activity AS (
    SELECT DISTINCT
           o.customer_unique_id,
           f.cohort_month,
           -- 【坑】cohort_month 已是 'YYYY-MM' 字符串，不能再 DATE_FORMAT
           -- 直接 DATE_FORMAT('2017-01','%Y%m') 会返回 NULL，
           -- 导致 PERIOD_DIFF 全是 NULL、所有留存率算成 0。
           -- 正确做法：先用 REPLACE 去掉横线，得到 'YYYYMM'。
           PERIOD_DIFF(DATE_FORMAT(o.purchase_ts, '%Y%m'),
                       REPLACE(f.cohort_month, '-', '')) AS month_no
    FROM dwd_orders o
    JOIN first_order f ON o.customer_unique_id = f.customer_unique_id
    WHERE o.purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
      AND o.order_status NOT IN ('canceled', 'unavailable')
),
cohort_size AS (
    SELECT cohort_month, COUNT(*) AS customers
    FROM first_order GROUP BY cohort_month
)
SELECT a.cohort_month                                   AS 首购月,
       cs.customers                                     AS 新增客户数,
       COUNT(DISTINCT CASE WHEN month_no = 1 THEN a.customer_unique_id END) AS M1,
       COUNT(DISTINCT CASE WHEN month_no = 2 THEN a.customer_unique_id END) AS M2,
       COUNT(DISTINCT CASE WHEN month_no = 3 THEN a.customer_unique_id END) AS M3,
       ROUND(COUNT(DISTINCT CASE WHEN month_no = 1 THEN a.customer_unique_id END)
             * 100.0 / cs.customers, 2)                 AS M1留存率,
       ROUND(COUNT(DISTINCT CASE WHEN month_no = 2 THEN a.customer_unique_id END)
             * 100.0 / cs.customers, 2)                 AS M2留存率,
       ROUND(COUNT(DISTINCT CASE WHEN month_no = 3 THEN a.customer_unique_id END)
             * 100.0 / cs.customers, 2)                 AS M3留存率
FROM activity a
JOIN cohort_size cs ON a.cohort_month = cs.cohort_month
GROUP BY a.cohort_month, cs.customers
ORDER BY a.cohort_month;


-- ============================================================
-- Q7  配送时效：按州的平均配送天数与延迟率
-- ------------------------------------------------------------
-- 业务问题：物流表现如何？哪些州是短板？
-- 技术点：NULLIF 防除零；只统计 is_delivered=1（未签收的没有配送天数）
-- 实现要点：分母必须排除未签收订单，否则延迟率被稀释
-- ============================================================
SELECT c.state                                          AS 州,
       COUNT(*)                                         AS 已签收订单,
       ROUND(AVG(o.delivery_days), 1)                   AS 平均配送天数,
       ROUND(AVG(o.estimated_days), 1)                  AS 平均承诺天数,
       SUM(o.is_late)                                   AS 延迟订单,
       ROUND(SUM(o.is_late) * 100.0 / COUNT(*), 2)      AS 延迟率,
       -- 【坑】必须只对延迟订单求平均。写成 AVG(o.late_days) 会把
       --       88,644 条提前送达（负值）算进去，结果出现"延迟订单平均
       --       超时 -8.7 天"这种荒谬数字。
       ROUND(AVG(CASE WHEN o.is_late = 1 THEN o.late_days END), 1) AS 延迟订单平均超时天数
FROM dwd_orders o
JOIN dim_customer c ON o.customer_unique_id = c.customer_unique_id
WHERE o.purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
  AND o.is_delivered = 1
GROUP BY c.state
HAVING COUNT(*) >= 100
ORDER BY 延迟率 DESC
LIMIT 12;


-- ============================================================
-- Q8  延迟对评分的影响（这是"用数据证明因果关系"的典型场景）
-- ------------------------------------------------------------
-- 业务问题：晚到真的会导致差评吗？影响有多大？
-- 技术点：分桶对比 + 条件聚合
-- 实现要点：不能直接说"延迟导致差评"，这里只能证明"相关"。
--         真正的因果需要控制品类、价格等变量（进阶可做）。
-- ============================================================
SELECT CASE
         WHEN o.late_days <= 0  THEN '1. 准时/提前'
         WHEN o.late_days <= 3  THEN '2. 延迟1-3天'
         WHEN o.late_days <= 7  THEN '3. 延迟4-7天'
         WHEN o.late_days <= 15 THEN '4. 延迟8-15天'
         ELSE                        '5. 延迟15天以上'
       END                                     AS 延迟情况,
       COUNT(*)                                AS 订单数,
       ROUND(AVG(r.review_score), 2)           AS 平均评分,
       ROUND(SUM(r.review_score <= 2) * 100.0 / COUNT(*), 2) AS 差评率,
       ROUND(SUM(r.review_score = 5) * 100.0 / COUNT(*), 2)  AS 五星率
FROM dwd_orders o
JOIN dwd_reviews r ON o.order_id = r.order_id
WHERE o.purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
  AND o.is_delivered = 1
GROUP BY 延迟情况
ORDER BY 延迟情况;


-- ============================================================
-- Q9  差评特征归因：1-2 分订单 vs 4-5 分订单有什么不同
-- ------------------------------------------------------------
-- 业务问题：差评订单集中在哪？是物流、品类还是价格问题？
-- 技术点：一条 SQL 里做多维对比（条件聚合），避免跑 4 次查询
-- 实现要点：只看"差评率"不够，要同时看"基数"——某品类差评率 40%
--         但只有 5 单，不能作为结论。这是统计显著性的直觉。
-- ============================================================
WITH order_fact AS (
    SELECT o.order_id,
           o.delivery_days,
           o.is_late,
           COALESCE(p.category_en, 'unknown') AS category,
           SUM(i.item_total)                 AS amt,
           r.review_score
    FROM dwd_orders o
    JOIN dwd_order_items i ON o.order_id = i.order_id
    LEFT JOIN dim_product p ON i.product_id = p.product_id
    JOIN dwd_reviews r ON o.order_id = r.order_id
    WHERE o.purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
      AND o.is_delivered = 1
    GROUP BY o.order_id, o.delivery_days, o.is_late, p.category_en, r.review_score
)
SELECT category                                        AS 品类,
       COUNT(*)                                        AS 订单数,
       ROUND(SUM(review_score <= 2) * 100.0 / COUNT(*), 2) AS 差评率,
       ROUND(AVG(review_score), 2)                     AS 平均分,
       ROUND(AVG(is_late) * 100, 2)                    AS 该品类延迟率,
       ROUND(AVG(amt), 2)                              AS 平均客单价
FROM order_fact
GROUP BY category
HAVING COUNT(*) >= 200
ORDER BY 差评率 DESC
LIMIT 10;


-- ============================================================
-- Q10  支付方式与分期行为
-- ------------------------------------------------------------
-- 业务问题：客户偏好什么支付方式？分期是否推高了客单价？
-- 技术点：分组的均值对比；注意 payment_count > 1 的订单（一单多笔支付）
-- 实现要点：分期数与客单价正相关，但不能说"分期导致高客单"——
--         更可能是"高客单的人更倾向分期"（反向因果）
-- ============================================================
SELECT pm.main_payment_type                      AS 支付方式,
       COUNT(*)                                  AS 订单数,
       ROUND(SUM(pm.payment_total), 2)           AS 支付总额,
       ROUND(AVG(pm.payment_total), 2)           AS 平均支付金额,
       ROUND(AVG(pm.max_installments), 1)        AS 平均分期数,
       ROUND(SUM(pm.payment_count > 1) * 100.0 / COUNT(*), 2) AS 多笔支付占比
FROM dwd_payments pm
JOIN dwd_orders o ON pm.order_id = o.order_id
WHERE o.purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
  AND o.order_status NOT IN ('canceled', 'unavailable')
GROUP BY pm.main_payment_type
ORDER BY 订单数 DESC;

-- 10.2 分期数 vs 客单价
SELECT CASE
         WHEN max_installments = 1  THEN '1. 不分期'
         WHEN max_installments <= 3 THEN '2. 2-3期'
         WHEN max_installments <= 6 THEN '3. 4-6期'
         WHEN max_installments <= 12 THEN '4. 7-12期'
         ELSE '5. 12期以上'
       END                                   AS 分期区间,
       COUNT(*)                              AS 订单数,
       ROUND(AVG(payment_total), 2)          AS 平均金额,
       ROUND(SUM(payment_total), 2)          AS 总金额
FROM dwd_payments pm
JOIN dwd_orders o ON pm.order_id = o.order_id
WHERE o.purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
  AND o.order_status NOT IN ('canceled', 'unavailable')
GROUP BY 分期区间
ORDER BY 分期区间;


-- ============================================================
-- Q11  RFM 客户分层（综合应用）
-- ------------------------------------------------------------
-- 业务问题：客户怎么分层运营？谁该重点维护、谁在流失？
-- 技术点：NTILE(5) 五分位打分 + CASE WHEN 打标签
-- 实现要点①：为什么用 NTILE 而不是固定阈值？
--          NTILE 让分层在数据内相对可比，固定阈值跨业务不可迁移。
-- 实现要点②【这里最大的坑】：F（频次）绝对不能用 NTILE。
--          本数据 96.96% 的客户只买过 1 次（91,832 / 94,707），
--          大量并列值时 NTILE 会把同分的人随机劈到不同桶，
--          结果就是"高频客户"平均购买次数只有 1.05 次——完全失真。
--          对高度离散且严重偏斜的字段，必须用业务阈值分箱。
-- ============================================================
WITH rfm_raw AS (
    SELECT o.customer_unique_id,
           DATEDIFF('2018-09-01', MAX(o.purchase_ts)) AS recency,
           COUNT(DISTINCT o.order_id)                 AS frequency,
           SUM(i.item_total)                          AS monetary
    FROM dwd_orders o
    JOIN dwd_order_items i ON o.order_id = i.order_id
    WHERE o.purchase_date BETWEEN '2017-01-01' AND '2018-08-31'
      AND o.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY o.customer_unique_id
),
rfm_score AS (
    SELECT *,
           -- R / M 是连续值，NTILE 可用
           NTILE(5) OVER (ORDER BY recency DESC)   AS r_score,  -- 越近分越高
           NTILE(5) OVER (ORDER BY monetary ASC)   AS m_score,
           -- F 严重偏斜，用业务阈值分箱
           CASE
             WHEN frequency = 1 THEN 1
             WHEN frequency = 2 THEN 3
             WHEN frequency <= 4 THEN 4
             ELSE 5
           END AS f_score
    FROM rfm_raw
),
segmented AS (
    SELECT *,
           CASE
             WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN '重要价值客户'
             WHEN r_score >= 4 AND f_score >= 4                  THEN '高频活跃客户'
             WHEN r_score >= 4 AND f_score = 1                   THEN '新客'
             WHEN r_score <= 2 AND (f_score >= 3 OR m_score >= 4) THEN '重要流失预警'
             WHEN r_score <= 2                                   THEN '一般流失客户'
             ELSE                                                     '一般客户'
           END AS segment
    FROM rfm_score
)
SELECT segment                                     AS 客户分层,
       COUNT(*)                                    AS 客户数,
       ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS 人数占比,
       ROUND(AVG(recency), 0)                      AS 平均最近购买天数,
       ROUND(AVG(frequency), 2)                    AS 平均购买次数,
       ROUND(AVG(monetary), 2)                     AS 平均消费金额,
       ROUND(SUM(monetary), 2)                     AS 分层总消费,
       ROUND(SUM(monetary) * 100.0 / SUM(SUM(monetary)) OVER (), 2) AS 收入占比
FROM segmented
GROUP BY segment
ORDER BY 分层总消费 DESC;
