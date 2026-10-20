-- ============================================================
-- 第 6 步：索引失效 8 大场景（在 MySQL 8.0.43 真实数据上逐条验证）
-- ------------------------------------------------------------
-- 看 EXPLAIN 的三个列：
--   type  = ALL      → 全表扫描
--   type  = index    → 全索引扫描（等价于全表扫描，只是扫索引不扫数据页）
--   type  = range/ref/const → 真正用上了索引做定位
--   rows             → 优化器预计要处理的行数
--
-- 为什么用 EXPLAIN 而不是耗时：
--   毫秒级耗时会受 buffer pool、系统负载影响，实测波动可达 ±30%。
--   type 和 rows 是优化器的确定性输出，换台机器结论也一样。
--   汇报时说"扫描行数从 98,267 降到 14,030"比"快了 7 倍"更站得住。
--
-- 【重要】本脚本在验证中发现：网上流传的 8 条规则里，
--   有 2 条在 MySQL 8 上已经不成立（场景 5、场景 6）。
--   这不是背错，而是版本演进——MySQL 8.0.13 引入了 Skip Scan。
-- ============================================================

USE olist_db;


-- ============================================================
-- 场景 1：索引列被函数包裹 —— 确实失效
-- ------------------------------------------------------------
-- 索引 B+ 树里存的是 purchase_ts 原始值，不是 DATE_FORMAT 后的值。
-- 套了函数，优化器无法按索引定位，只能逐行计算再比较。
-- 注意：如果用 COUNT(*) 且索引覆盖，会显示 type=index（全索引扫描），
--       看起来"用了索引"，但其实扫了全部 98,267 行。
--       取真实列才会露出 type=ALL 的原形。
-- ============================================================
SELECT '=== 场景1 失效：函数包裹（取真实列）===' AS 说明;
EXPLAIN SELECT order_id, order_status, purchase_ts FROM dwd_orders
WHERE DATE_FORMAT(purchase_ts, '%Y-%m') = '2017-11';

SELECT '=== 场景1 正确：改写成范围查询 ===' AS 说明;
EXPLAIN SELECT order_id, order_status, purchase_ts FROM dwd_orders
WHERE purchase_ts >= '2017-11-01' AND purchase_ts < '2017-12-01';


-- ============================================================
-- 场景 2：隐式类型转换 —— 确实失效
-- ------------------------------------------------------------
-- zip_code_prefix 是 VARCHAR(5)。传数字 1037 时，MySQL 会把【列】
-- 转成数字再比较（等价于 CAST(col AS DOUBLE)），索引立刻失效。
-- 传字符串 '01037' 则 type=const，只定位 1 行。
--
-- ⚠️ 补充一个容易讲错的点：本例中两种写法的查询结果恰好相同
--    （因为 '01037' 转成数字正好等于 1037）。但一旦库里存在
--    '0103X'、'1037 ' 这类值，隐式转换会把它们也匹配进来，
--    那时就是"又慢又错"。所以不能拿"结果对"来证明写法没问题。
-- ============================================================
SELECT '=== 场景2 失效：字符串列传数字 ===' AS 说明;
EXPLAIN SELECT * FROM dim_geolocation WHERE zip_code_prefix = 1037;

SELECT '=== 场景2 正确：传字符串 ===' AS 说明;
EXPLAIN SELECT * FROM dim_geolocation WHERE zip_code_prefix = '01037';

SELECT '=== 场景2 两种写法结果对比（本例恰好一致）===' AS 说明;
SELECT
    (SELECT COUNT(*) FROM dim_geolocation WHERE zip_code_prefix = 1037)   AS 传数字,
    (SELECT COUNT(*) FROM dim_geolocation WHERE zip_code_prefix = '01037') AS 传字符串;


-- ============================================================
-- 场景 3：前导模糊 LIKE —— 确实失效
-- ------------------------------------------------------------
-- B+ 树按前缀有序。'%table%' 无法确定起点，只能全表逐行匹配。
-- 'bed%' 能确定起点在 'bed' 附近，走 range。
-- ============================================================
SELECT '=== 场景3 失效：前后都模糊 ===' AS 说明;
EXPLAIN SELECT COUNT(*) FROM dim_product WHERE category_en LIKE '%table%';

SELECT '=== 场景3 正确：只用后缀通配 ===' AS 说明;
EXPLAIN SELECT COUNT(*) FROM dim_product WHERE category_en LIKE 'bed%';


-- ============================================================
-- 场景 4：OR 连接了未建索引的列 —— 确实失效
-- ------------------------------------------------------------
-- OR 要求两侧都能用索引。city 列没索引，整体退化为全表扫描。
-- 改写方案：UNION ALL 拆成两条各自走索引的查询，或给 city 建索引。
-- ============================================================
SELECT '=== 场景4 失效：OR 跨列 ===' AS 说明;
EXPLAIN SELECT COUNT(*) FROM dim_customer
WHERE state = 'SP' OR city = 'rio de janeiro';

SELECT '=== 场景4 正确：单列条件 ===' AS 说明;
EXPLAIN SELECT COUNT(*) FROM dim_customer WHERE state = 'SP';

SELECT '=== 场景4 改写：UNION ALL 拆分 ===' AS 说明;
EXPLAIN SELECT COUNT(*) FROM dim_customer WHERE state = 'SP'
UNION ALL
SELECT COUNT(*) FROM dim_customer WHERE city = 'rio de janeiro';


-- ============================================================
-- 场景 5：【辟谣】!= 和 NOT IN 在 MySQL 8 上不一定失效
-- ------------------------------------------------------------
-- 网上普遍说"不等于会导致索引失效"。实测 MySQL 8 会把
-- `<> x` 等价改写成 `< x OR > x` 两个 range，索引照用。
--
-- 真正的规律是【代价决定】：如果被排除的值极少（比如排除
-- canceled 只占 0.6%），剩下 99.4% 都要返回，优化器就会放弃索引
-- 改走全表扫描——因为它判断"扫索引 + 回表"比"顺序扫全表"更贵。
-- ============================================================
SELECT '=== 场景5 不等于：仍然走 range（辟谣）===' AS 说明;
EXPLAIN SELECT COUNT(*) FROM dwd_orders WHERE order_status <> 'delivered';

SELECT '=== 场景5 NOT IN 两个值：仍然走 range ===' AS 说明;
EXPLAIN SELECT COUNT(*) FROM dwd_orders WHERE order_status NOT IN ('delivered', 'shipped');

SELECT '=== 场景5 排除少量值：仍用索引但扫了半张表 ===' AS 说明;
EXPLAIN SELECT COUNT(*) FROM dwd_orders WHERE order_status != 'canceled';


-- ============================================================
-- 场景 6：【辟谣】跳过最左列，MySQL 8 可能用 Skip Scan 兜住
-- ------------------------------------------------------------
-- 索引 idx_year_month(purchase_year, purchase_month)。
-- 只查 purchase_month=11 时，理论上用不上索引。
-- 但 MySQL 8.0.13+ 的 Skip Scan 会"枚举前导列的每个不同值再跳查"，
-- 只要前导列基数足够小就能生效。本例 purchase_year 只有 3 个值。
--
-- 反例见下一条：前导列基数 98,666 时，Skip Scan 直接放弃，
-- 退化为全索引扫描 111,435 行。
-- ============================================================
SELECT '=== 场景6 正确：带最左列（ref 精确定位）===' AS 说明;
EXPLAIN SELECT COUNT(*) FROM dwd_orders
WHERE purchase_year = 2017 AND purchase_month = 11;

SELECT '=== 场景6 跳过最左列：Skip Scan 兜住了（前导列只有 3 个值）===' AS 说明;
EXPLAIN SELECT COUNT(*) FROM dwd_orders WHERE purchase_month = 11;

SELECT '=== 场景6 反例：前导列基数 98,666 时 Skip Scan 失效 ===' AS 说明;
EXPLAIN SELECT COUNT(*) FROM dwd_order_items WHERE order_item_id = 1;


-- ============================================================
-- 场景 7：索引列参与运算 —— 确实失效
-- ------------------------------------------------------------
-- 和场景 1 同源：列只要不是"裸"的，索引就用不上。
-- 把运算移到常量侧即可（order_count + 1 > 2 等价于 order_count > 1）。
-- ============================================================
SELECT '=== 场景7 失效：列参与运算 ===' AS 说明;
EXPLAIN SELECT COUNT(*) FROM dim_customer WHERE order_count + 1 > 2;

SELECT '=== 场景7 正确：运算移到常量侧 ===' AS 说明;
EXPLAIN SELECT COUNT(*) FROM dim_customer WHERE order_count > 1;


-- ============================================================
-- 场景 8：索引选择性太低 —— 用了等于没用
-- ------------------------------------------------------------
-- is_delivered 只有 0/1 两个值，1 占 97%。优化器"用了"索引，
-- 但要扫 49,133 行——等于扫半张表，随机 IO 比顺序全表扫更贵。
--
-- 这就是"给每个 WHERE 列都建索引"为什么是错的：
-- 选择性 = 不同值数 / 总行数，低于 10% 基本没有优化价值。
-- ============================================================
SELECT '=== 场景8：低选择性索引 ===' AS 说明;
EXPLAIN SELECT COUNT(*) FROM dwd_orders WHERE is_delivered = 1;

SELECT '=== 各列选择性对比（越低越不适合建索引）===' AS 说明;
SELECT 'order_status' AS 列名,
       COUNT(DISTINCT order_status) AS 不同值,
       COUNT(*)                     AS 总行数,
       ROUND(COUNT(DISTINCT order_status) / COUNT(*) * 100, 3) AS 选择性百分比
FROM dwd_orders
UNION ALL
SELECT 'is_delivered', COUNT(DISTINCT is_delivered), COUNT(*),
       ROUND(COUNT(DISTINCT is_delivered) / COUNT(*) * 100, 3) FROM dwd_orders
UNION ALL
SELECT 'customer_unique_id', COUNT(DISTINCT customer_unique_id), COUNT(*),
       ROUND(COUNT(DISTINCT customer_unique_id) / COUNT(*) * 100, 3) FROM dwd_orders
UNION ALL
SELECT 'order_id', COUNT(DISTINCT order_id), COUNT(*),
       ROUND(COUNT(DISTINCT order_id) / COUNT(*) * 100, 3) FROM dwd_orders;
