-- ============================================================
-- Olist 电商订单数据分析平台
-- 脚本 01：建库
-- ============================================================
-- 说明：
--   utf8mb4 是完整的 UTF-8 实现（最多 4 字节），支持 emoji 和生僻字
--   MySQL 里的 "utf8" 是残缺的（最多 3 字节），不要用
--   utf8mb4_general_ci 中的 ci = case insensitive（大小写不敏感）
-- ============================================================

-- 如果已存在则先删除（谨慎！会清空所有数据）
DROP DATABASE IF EXISTS olist_db;

-- 创建数据库
CREATE DATABASE olist_db
    DEFAULT CHARACTER SET utf8mb4
    DEFAULT COLLATE utf8mb4_general_ci;

-- 切换到该库
USE olist_db;

-- 验证
SELECT
    SCHEMA_NAME       AS 数据库名,
    DEFAULT_CHARACTER_SET_NAME AS 字符集,
    DEFAULT_COLLATION_NAME     AS 排序规则
FROM information_schema.SCHEMATA
WHERE SCHEMA_NAME = 'olist_db';
