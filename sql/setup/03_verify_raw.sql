-- ============================================================================
-- 03_verify_raw.sql — сверка raw: число строк, горизонт дат, пустые апрельские секции.
-- ============================================================================

-- 1. Число строк: diff должен быть нулевым везде.
SELECT tbl, expected, actual, actual - expected AS diff
FROM (
    SELECT 'train'             AS tbl,    992931 AS expected, count(*) AS actual FROM raw.train
    UNION ALL SELECT 'train_v2',          970960,  count(*) FROM raw.train_v2
    UNION ALL SELECT 'transactions',    21547746,  count(*) FROM raw.transactions
    UNION ALL SELECT 'transactions_v2',  1431009,  count(*) FROM raw.transactions_v2
    UNION ALL SELECT 'members',          6769473,  count(*) FROM raw.members
    UNION ALL SELECT 'user_logs',      392106543,  count(*) FROM raw.user_logs
    UNION ALL SELECT 'user_logs_v2',    18396362,  count(*) FROM raw.user_logs_v2
) AS counts
ORDER BY tbl;


-- 2. Горизонт данных: 20170228 в основных файлах, 20170331 в _v2.
SELECT 'transactions'      AS src, max(transaction_date) AS max_date FROM raw.transactions
UNION ALL SELECT 'transactions_v2', max(transaction_date) FROM raw.transactions_v2
UNION ALL SELECT 'user_logs',       max(date)            FROM raw.user_logs
UNION ALL SELECT 'user_logs_v2',    max(date)            FROM raw.user_logs_v2;


-- 3. Апрельские секции логов должны быть пустыми.
SELECT (SELECT count(*) FROM raw.user_logs_201704)    AS user_logs_april,
       (SELECT count(*) FROM raw.user_logs_v2_201704) AS user_logs_v2_april;
