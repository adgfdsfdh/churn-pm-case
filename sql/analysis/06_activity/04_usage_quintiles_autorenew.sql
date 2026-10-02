-- ============================================================================
-- 04_usage_quintiles_autorenew.sql — отток по квинтилям прослушивания в январе 2017 отдельно внутри
-- автопродления «да» и «нет» (месячные платные); неслушающие — по наличию профиля. Уилсон, Бонферрони на 16 строк.
-- ============================================================================

WITH base AS (
    SELECT sb.msno,
           sb.is_churn,
           sb.is_churn_recalc,
           sb.arpu30,
           sb.plan_group,
           sb.lp_is_free,
           sb.episode_start,
           sb.lp_is_auto_renew,
           sb.has_profile,
           lg.total_secs,
           lg.active_days
    FROM marts.segment_base sb
    LEFT JOIN staging.user_logs_monthly lg
           ON lg.msno = sb.msno
          AND lg.month = DATE '2017-01-01'
),
grouped AS (
    SELECT b.*,
           CASE WHEN b.plan_group = '6) нет подписки до февраля'   THEN 'нет подписки до февраля'
                WHEN b.lp_is_free                                  THEN 'бесплатная последняя подписка'
                WHEN b.plan_group <> '2) месяц (30-31 дн.)'        THEN 'план не месячный'
                WHEN b.episode_start >= DATE '2017-01-01'          THEN 'месячные платные: эпизод начался в январе'
                WHEN b.total_secs IS NULL AND NOT b.has_profile    THEN 'месячные платные без логов в январе: нет профиля'
                WHEN b.total_secs IS NULL                          THEN 'месячные платные без логов в январе: профиль есть'
           END                                                     AS other_group,
           b.total_secs / 31.0                                      AS secs_per_day   -- подписан весь январь
    FROM base b
),
ranked AS (
    SELECT g.*,
           CASE WHEN g.other_group IS NULL
                THEN CASE g.lp_is_auto_renew WHEN 1 THEN 'автопродление да: Q' ELSE 'автопродление нет: Q' END
                     || ntile(5) OVER (PARTITION BY (g.other_group IS NULL), g.lp_is_auto_renew
                                       ORDER BY g.secs_per_day, g.msno)
                ELSE g.other_group
           END                                                     AS usage_group
    FROM grouped g
),
agg AS (
    SELECT usage_group,
           count(*)                                                AS users,
           count(*)::numeric                                       AS n,
           sum(is_churn)                                           AS churned,
           sum(is_churn)::numeric / count(*)                       AS p,
           sum(arpu30) FILTER (WHERE is_churn = 1)                 AS mrr_lost,
           count(is_churn_recalc)                                  AS users_verifiable,
           sum(is_churn_recalc)                                    AS churned_recalc,
           min(secs_per_day) / 3600                                AS hours_per_day_min,
           max(secs_per_day) / 3600                                AS hours_per_day_max,
           avg(active_days / 31.0)                                 AS active_share
    FROM ranked
    GROUP BY usage_group
),
z AS (SELECT 2.955::numeric AS z)                                  -- 95% с поправкой Бонферрони: 0,05 / 16 строк
SELECT a.usage_group,
       a.users,
       a.churned,
       round(100 * a.p, 2)                                         AS churn_pct,
       round(100 * ((a.p + z.z^2 / (2 * a.n)) / (1 + z.z^2 / a.n)
             - z.z * sqrt(a.p * (1 - a.p) / a.n + z.z^2 / (4 * a.n^2)) / (1 + z.z^2 / a.n)), 2) AS ci_low_pct,
       round(100 * ((a.p + z.z^2 / (2 * a.n)) / (1 + z.z^2 / a.n)
             + z.z * sqrt(a.p * (1 - a.p) / a.n + z.z^2 / (4 * a.n^2)) / (1 + z.z^2 / a.n)), 2) AS ci_high_pct,
       round(coalesce(a.mrr_lost, 0))                              AS mrr_lost,
       round(100 * coalesce(a.mrr_lost, 0) / sum(coalesce(a.mrr_lost, 0)) OVER (), 1) AS mrr_lost_share_pct,
       round(100.0 * a.churned_recalc / NULLIF(a.users_verifiable, 0), 2) AS churn_recalc_pct,
       round(a.hours_per_day_min::numeric, 2)                      AS hours_per_day_from,
       round(a.hours_per_day_max::numeric, 2)                      AS hours_per_day_to,
       round(100 * a.active_share, 1)                              AS active_days_pct
FROM agg a
CROSS JOIN z
ORDER BY CASE WHEN a.usage_group LIKE 'автопродление%' THEN 0 ELSE 1 END, a.usage_group;
