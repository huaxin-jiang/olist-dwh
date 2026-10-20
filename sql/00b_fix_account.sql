-- ============================================================
-- 脚本 00b：专用账号登录失败——诊断与修复
-- ============================================================
-- 【用途】
--   Navicat 用非 root 账号测试连接失败时，先跑诊断（第一部分），
--   再按结果选择对应的修复方案（第二部分）。
--
-- 【执行方式】
--   必须用 root 账号执行。
-- ============================================================

-- ############################################################
-- 第一部分：诊断（先跑这一段，把结果看一遍）
-- ############################################################

-- 诊断 1：账号是否存在？认证插件是什么？
--   期望：能看到 olist_dev 这一行，plugin 为 mysql_native_password
--   若查询结果为空 → 账号根本没建成，说明 00_create_user.sql 没执行成功
SELECT
    user   AS 用户名,
    host   AS 允许来源,
    plugin AS 认证插件
FROM mysql.user
WHERE user = 'olist_dev';

-- 诊断 2：该账号被授予了什么权限？
--   期望：能看到 GRANT ALL PRIVILEGES ON `olist_db`.* TO ...
--   若报错 "There is no such grant defined" → 账号或授权缺失
SHOW GRANTS FOR 'olist_dev'@'localhost';

-- 诊断 3：mysql_native_password 插件是否可用？
--   期望：PLUGIN_STATUS 为 ACTIVE
--   若为 DISABLED → 必须改用 caching_sha2_password（见修复方案 C）
SELECT
    PLUGIN_NAME   AS 插件名,
    PLUGIN_STATUS AS 状态
FROM information_schema.PLUGINS
WHERE PLUGIN_NAME IN ('mysql_native_password', 'caching_sha2_password');

-- 诊断 4：是否开启了跳过域名解析？
--   若 Value = ON，则 127.0.0.1 不会被解析成 localhost，
--   必须额外创建 'olist_dev'@'127.0.0.1' 才能用 IP 连接
SHOW VARIABLES LIKE 'skip_name_resolve';

-- 诊断 5：当前有哪些账号（看是否有历史遗留的同名账号干扰）
SELECT user, host, plugin FROM mysql.user ORDER BY user, host;


-- ############################################################
-- 第二部分：修复（按诊断结果选一个方案执行）
-- ############################################################

-- ------------------------------------------------------------
-- 修复方案 A（最常见）：同时为 localhost 和 127.0.0.1 建账号
-- ------------------------------------------------------------
-- 原因：Navicat 填「localhost」时，有的版本实际走 127.0.0.1 的 TCP 连接，
--       MySQL 判定来源主机为 '127.0.0.1'，
--       此时只有 'olist_dev'@'localhost' 这条记录匹配不上 → 拒绝访问。
--       最省事的做法是两种来源都建一份。
--
-- ⚠️ 执行前把下面的 '<YOUR_PASSWORD>' 改成你自己的密码
-- ------------------------------------------------------------

-- 先清理可能存在的旧账号，避免冲突
DROP USER IF EXISTS 'olist_dev'@'localhost';
DROP USER IF EXISTS 'olist_dev'@'127.0.0.1';

-- 为 localhost 建账号
CREATE USER 'olist_dev'@'localhost'
    IDENTIFIED WITH mysql_native_password BY '<YOUR_PASSWORD>';

-- 为 127.0.0.1 建账号（同样的密码和权限）
CREATE USER 'olist_dev'@'127.0.0.1'
    IDENTIFIED WITH mysql_native_password BY '<YOUR_PASSWORD>';

-- 分别授权
GRANT ALL PRIVILEGES ON olist_db.* TO 'olist_dev'@'localhost';
GRANT ALL PRIVILEGES ON olist_db.* TO 'olist_dev'@'127.0.0.1';

-- 刷新权限
FLUSH PRIVILEGES;

-- 验证
SHOW GRANTS FOR 'olist_dev'@'localhost';
SHOW GRANTS FOR 'olist_dev'@'127.0.0.1';


-- ------------------------------------------------------------
-- 修复方案 B：确认账号存在但密码可能记错了
-- ------------------------------------------------------------
-- 如果诊断 1 能查到账号，但仍登录失败，
-- 大概率是密码不一致。直接改密码：
--
-- ⚠️ 把 '<YOUR_PASSWORD>' 改成你要用的密码
-- ------------------------------------------------------------
-- ALTER USER 'olist_dev'@'localhost'
--     IDENTIFIED WITH mysql_native_password BY '<YOUR_PASSWORD>';
-- ALTER USER 'olist_dev'@'127.0.0.1'
--     IDENTIFIED WITH mysql_native_password BY '<YOUR_PASSWORD>';
-- FLUSH PRIVILEGES;


-- ------------------------------------------------------------
-- 修复方案 C：mysql_native_password 插件被禁用时
-- ------------------------------------------------------------
-- 若诊断 3 显示 mysql_native_password 为 DISABLED，
-- 则不能再用它建账号，改用 MySQL 8 默认的 caching_sha2_password。
-- 同时需要在 Navicat 里确认版本支持（新版 Navicat 16+ 支持）。
--
-- 或在 my.ini 的 [mysqld] 段加一行后重启服务：
--     mysql_native_password=ON
-- ------------------------------------------------------------
-- CREATE USER 'olist_dev'@'localhost'
--     IDENTIFIED BY '<YOUR_PASSWORD>';          -- 不指定插件，走默认 caching_sha2
-- GRANT ALL PRIVILEGES ON olist_db.* TO 'olist_dev'@'localhost';
-- FLUSH PRIVILEGES;


-- ------------------------------------------------------------
-- 修复方案 D：刀切方案 —— 允许任意来源（仅本地开发可用）
-- ------------------------------------------------------------
-- 如果上面都不行，先用 '%' 打通，确认是来源主机的问题而不是别的。
-- ⚠️ 生产环境严禁这样建账号。
-- ------------------------------------------------------------
-- DROP USER IF EXISTS 'olist_dev'@'%';
-- CREATE USER 'olist_dev'@'%'
--     IDENTIFIED WITH mysql_native_password BY '<YOUR_PASSWORD>';
-- GRANT ALL PRIVILEGES ON olist_db.* TO 'olist_dev'@'%';
-- FLUSH PRIVILEGES;
