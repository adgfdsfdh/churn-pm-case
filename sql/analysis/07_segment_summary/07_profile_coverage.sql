-- ============================================================================
-- 07_profile_coverage.sql — граница выгрузки или поведение: есть ли у людей без профиля и у месячных
-- платных без логов в январе прослушивания в какие-либо другие месяцы 2015–2017.
-- ============================================================================

WITH logs_by_user AS (
    SELECT lg.msno,
           min(lg.month)                                                     AS first_month,
           max(lg.month)                                                     AS last_month,
           bool_or(lg.month BETWEEN DATE '2015-01-01' AND DATE '2015-12-01') AS logs_2015,
           bool_or(lg.month BETWEEN DATE '2016-01-01' AND DATE '2016-12-01') AS logs_2016,
           bool_or(lg.month = DATE '2016-12-01')                             AS logs_dec_2016,
           bool_or(lg.month = DATE '2017-01-01')                             AS logs_jan_2017,
           bool_or(lg.month >= DATE '2017-02-01')                            AS logs_feb_mar_2017
    FROM staging.user_logs_monthly lg
    JOIN marts.segment_base sb ON sb.msno = lg.msno
    GROUP BY lg.msno
),
base AS (
    SELECT sb.msno, sb.is_churn, sb.has_profile, sb.lp_is_auto_renew, sb.registered_via,
           (sb.plan_group = '2) месяц (30-31 дн.)' AND NOT sb.lp_is_free
            AND sb.episode_start < DATE '2017-01-01')                         AS monthly_paid_full_jan,
           l.msno IS NOT NULL                                                AS logs_ever,
           coalesce(l.logs_2015, false)                                      AS logs_2015,
           coalesce(l.logs_2016, false)                                      AS logs_2016,
           coalesce(l.logs_dec_2016, false)                                  AS logs_dec_2016,
           coalesce(l.logs_jan_2017, false)                                  AS logs_jan_2017,
           coalesce(l.logs_feb_mar_2017, false)                              AS logs_feb_mar_2017,
           l.last_month
    FROM marts.segment_base sb
    LEFT JOIN logs_by_user l ON l.msno = sb.msno
),
grouped AS (
    SELECT g.grp, b.*
    FROM base b
    CROSS JOIN LATERAL (VALUES
        (CASE WHEN NOT b.has_profile THEN '1) нет профиля: все' END),
        (CASE WHEN b.monthly_paid_full_jan AND NOT b.logs_jan_2017 AND NOT b.has_profile
              THEN '2) месячные платные без логов в январе: нет профиля' END),
        (CASE WHEN b.monthly_paid_full_jan AND NOT b.logs_jan_2017 AND b.has_profile
              THEN '3) месячные платные без логов в январе: профиль есть' END),
        (CASE WHEN b.monthly_paid_full_jan AND b.logs_jan_2017
              THEN '4) месячные платные с логами в январе (сравнение)' END)
    ) AS g(grp)
    WHERE g.grp IS NOT NULL
)
SELECT grp,
       count(*)                                                                  AS users,
       round(100.0 * sum(is_churn) / count(*), 2)                                AS churn_pct,
       round(100.0 * count(*) FILTER (WHERE logs_ever)         / count(*), 1)    AS logs_ever_pct,
       round(100.0 * count(*) FILTER (WHERE logs_2015)         / count(*), 1)    AS logs_2015_pct,
       round(100.0 * count(*) FILTER (WHERE logs_2016)         / count(*), 1)    AS logs_2016_pct,
       round(100.0 * count(*) FILTER (WHERE logs_dec_2016)     / count(*), 1)    AS logs_dec_2016_pct,
       round(100.0 * count(*) FILTER (WHERE logs_feb_mar_2017) / count(*), 1)    AS logs_feb_mar_2017_pct,
       to_char(percentile_disc(0.5) WITHIN GROUP (ORDER BY last_month), 'YYYY-MM') AS last_log_month_median,
       round(100.0 * count(*) FILTER (WHERE lp_is_auto_renew = 1) / count(*), 1) AS autorenew_pct,
       round(100.0 * count(*) FILTER (WHERE registered_via = 7)   / count(*), 1) AS channel_7_pct
FROM grouped
GROUP BY grp
ORDER BY grp;
