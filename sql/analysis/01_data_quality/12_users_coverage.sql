-- ============================================================================
-- 12_users_coverage.sql — сколько пользователей из транзакций нет в train и train_v2.
-- ============================================================================

SELECT count(*)                                                    AS users_in_transactions,
       count(*) FILTER (WHERE t1.msno IS NOT NULL)                 AS in_train,
       count(*) FILTER (WHERE t2.msno IS NOT NULL)                 AS in_train_v2,
       count(*) FILTER (WHERE t1.msno IS NULL AND t2.msno IS NULL) AS in_neither
FROM (SELECT DISTINCT msno FROM staging.subscription_episodes) AS users
LEFT JOIN raw.train    t1 ON t1.msno = users.msno
LEFT JOIN raw.train_v2 t2 ON t2.msno = users.msno;
