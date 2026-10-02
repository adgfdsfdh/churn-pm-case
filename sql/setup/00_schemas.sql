-- ============================================================================
-- 00_schemas.sql — схемы raw, staging, marts.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS raw;       -- сырые данные ровно как в CSV
CREATE SCHEMA IF NOT EXISTS staging;   -- типизация, очистка, производные таблицы
CREATE SCHEMA IF NOT EXISTS marts;     -- витрины
