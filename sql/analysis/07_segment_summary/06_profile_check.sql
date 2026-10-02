-- ============================================================================
-- 06_profile_check.sql — кто такие «город 1» и месячные платные без прослушиваний в январе:
-- доли канала 7, незаполненного профиля, автопродления, способа оплаты 41 и тарифа 99 NTD.
-- ============================================================================

WITH base AS (
    SELECT sb.*,
           (lg.msno IS NOT NULL)                                          AS has_jan_logs
    FROM marts.segment_base sb
    LEFT JOIN staging.user_logs_monthly lg
           ON lg.msno = sb.msno
          AND lg.month = DATE '2017-01-01'
),
grouped AS (
    -- группы описательные и могут пересекаться
    SELECT g.grp, b.*
    FROM base b
    CROSS JOIN LATERAL (VALUES
        ('1) все train'),
        (CASE WHEN b.city = 1                  THEN '2) город 1' END),
        (CASE WHEN b.city <> 1                 THEN '3) остальные города' END),
        (CASE WHEN NOT b.has_profile           THEN '4) нет профиля' END),
        (CASE WHEN b.plan_group = '2) месяц (30-31 дн.)' AND NOT b.lp_is_free
               AND b.episode_start < DATE '2017-01-01' AND NOT b.has_jan_logs
                                               THEN '5) месячные платные: нет логов в январе' END),
        (CASE WHEN b.plan_group = '2) месяц (30-31 дн.)' AND NOT b.lp_is_free
               AND b.episode_start < DATE '2017-01-01' AND b.has_jan_logs
                                               THEN '6) месячные платные: есть логи в январе' END)
    ) AS g(grp)
    WHERE g.grp IS NOT NULL
)
SELECT grp,
       count(*)                                                                    AS users,
       round(100.0 * sum(is_churn) / count(*), 2)                                  AS churn_pct,
       round(avg(arpu30), 1)                                                       AS arpu30,
       round(100.0 * count(*) FILTER (WHERE registered_via = 7) / count(*), 1)     AS channel_7_pct,
       round(100.0 * count(*) FILTER (WHERE city = 1) / count(*), 1)               AS city_1_pct,
       round(100.0 * count(*) FILTER (WHERE has_profile AND age IS NULL)
             / NULLIF(count(*) FILTER (WHERE has_profile), 0), 1)                  AS age_empty_pct_of_profiles,
       round(100.0 * count(*) FILTER (WHERE has_profile AND gender IS NULL)
             / NULLIF(count(*) FILTER (WHERE has_profile), 0), 1)                  AS gender_empty_pct_of_profiles,
       round(100.0 * count(*) FILTER (WHERE lp_is_auto_renew = 1) / count(*), 1)   AS autorenew_pct,
       round(100.0 * count(*) FILTER (WHERE lp_payment_method_id = 41) / count(*), 1) AS method_41_pct,
       round(100.0 * count(*) FILTER (WHERE plan_group = '2) месяц (30-31 дн.)'
                                        AND lp_amount_paid = 99) / count(*), 1)    AS price_99_pct,
       round(100.0 * count(*) FILTER (WHERE NOT has_jan_logs) / count(*), 1)       AS no_jan_logs_pct
FROM grouped
GROUP BY grp
ORDER BY grp;
