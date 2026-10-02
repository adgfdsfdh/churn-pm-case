-- ============================================================================
-- 99_verify_staging.sql — контрольные числа staging, в колонке ok должно быть true.
-- ============================================================================

WITH label_cmp AS (
    SELECT count(*)                                                        AS both_labels,
           count(*) FILTER (WHERE l.is_churn = 0 AND r.is_churn_recalc = 0) AS stay_stay,
           count(*) FILTER (WHERE l.is_churn = 1 AND r.is_churn_recalc = 1) AS churn_churn,
           count(*) FILTER (WHERE l.is_churn = 1 AND r.is_churn_recalc = 0) AS churn_stay,
           count(*) FILTER (WHERE l.is_churn = 0 AND r.is_churn_recalc = 1) AS stay_churn
    FROM staging.labels l
    JOIN staging.label_recalc r ON r.msno = l.msno
),
checks (check_name, expected, actual) AS (
    SELECT 'members: rows',                  6769473::bigint, (SELECT count(*) FROM staging.members)
    UNION ALL SELECT 'members: age filled',  2217424, (SELECT count(age) FROM staging.members)
    UNION ALL SELECT 'transactions: rows',  22965699, (SELECT count(*) FROM staging.transactions)
    UNION ALL SELECT 'transactions: expire < 2015', 0,
              (SELECT count(*) FROM staging.transactions WHERE membership_expire_date < DATE '2015-01-01')
    UNION ALL SELECT 'labels: rows',          992931, (SELECT count(*) FROM staging.labels)
    UNION ALL SELECT 'label_recalc: rows',    856144, (SELECT count(*) FROM staging.label_recalc)
    UNION ALL SELECT 'labels vs recalc: both', 856085, (SELECT both_labels FROM label_cmp)
    UNION ALL SELECT 'labels vs recalc: stay/stay',   817233, (SELECT stay_stay   FROM label_cmp)
    UNION ALL SELECT 'labels vs recalc: churn/churn',  28327, (SELECT churn_churn FROM label_cmp)
    UNION ALL SELECT 'labels vs recalc: churn/stay',   10357, (SELECT churn_stay  FROM label_cmp)
    UNION ALL SELECT 'labels vs recalc: stay/churn',     168, (SELECT stay_churn  FROM label_cmp)
    UNION ALL SELECT 'user_logs_monthly: rows',  27862690, (SELECT count(*) FROM staging.user_logs_monthly)
    UNION ALL SELECT 'user_logs_monthly: users',  5339366, (SELECT count(DISTINCT msno) FROM staging.user_logs_monthly)
    UNION ALL SELECT 'user_logs_monthly: active days', 410432545,
              (SELECT sum(active_days) FROM staging.user_logs_monthly)
    UNION ALL SELECT 'episodes: rows',        3126004, (SELECT count(*) FROM staging.subscription_episodes)
    UNION ALL SELECT 'episodes: users',       2425727, (SELECT count(DISTINCT msno) FROM staging.subscription_episodes)
)
SELECT check_name, expected, actual, actual = expected AS ok
FROM checks;
