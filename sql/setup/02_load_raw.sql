-- ============================================================================
-- 02_load_raw.sql — загрузка семи CSV в raw. Запускать через psql из папки с данными.
-- ============================================================================

\timing on
SET synchronous_commit = off;

\echo '--- train.csv'
\copy raw.train FROM 'train.csv' WITH (FORMAT csv, HEADER true)

\echo '--- train_v2.csv'
\copy raw.train_v2 FROM 'train_v2.csv' WITH (FORMAT csv, HEADER true)

\echo '--- members_v3.csv'
\copy raw.members FROM 'members_v3.csv' WITH (FORMAT csv, HEADER true)

\echo '--- transactions.csv'
\copy raw.transactions FROM 'transactions.csv' WITH (FORMAT csv, HEADER true)

\echo '--- transactions_v2.csv'
\copy raw.transactions_v2 FROM 'transactions_v2.csv' WITH (FORMAT csv, HEADER true)

\echo '--- user_logs_v2.csv'
\copy raw.user_logs_v2 FROM 'user_logs_v2.csv' WITH (FORMAT csv, HEADER true)

\echo '--- user_logs.csv'
\copy raw.user_logs FROM 'user_logs.csv' WITH (FORMAT csv, HEADER true)

\echo '=== Load finished. Next: 03_verify_raw.sql'
