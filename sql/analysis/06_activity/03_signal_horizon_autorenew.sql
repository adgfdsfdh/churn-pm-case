-- ============================================================================
-- 03_signal_horizon_autorenew.sql — горизонт сигнала для подписанных все 63 дня отдельно по автопродлению
-- (как в 01_signal_horizon.sql); плюс отношение медиан.
-- ============================================================================

WITH first_tx AS (
    -- первая транзакция после 31.01.2017 (продление или отмена) — одной группировкой
    SELECT t.msno, min(t.transaction_date) AS first_tx_after_jan
    FROM staging.transactions t
    JOIN staging.label_recalc r ON r.msno = t.msno
    WHERE t.transaction_date > DATE '2017-01-31'
    GROUP BY t.msno
),
users AS (
    SELECT sb.msno,
           sb.is_churn,
           sb.lp_is_auto_renew,
           sb.has_jan_cancel,
           sb.lp_is_free,
           sb.tenure_group,
           sb.episode_start,
           least(r.effective_expire, ft.first_tx_after_jan)             AS anchor
    FROM marts.segment_base sb
    JOIN staging.label_recalc r ON r.msno = sb.msno
    LEFT JOIN first_tx ft       ON ft.msno = sb.msno
),
in_scope AS (
    -- логи в выгрузке с 01.10.2016: 63 дня до точки решения видны, если она не раньше 03.12.2016
    SELECT msno, is_churn, lp_is_auto_renew, has_jan_cancel, lp_is_free, tenure_group,
           (episode_start <= anchor - 63)                            AS subscribed_63d,
           anchor,
           to_char(anchor - 63, 'YYYYMMDD')::int                     AS lo_int,
           to_char(anchor,      'YYYYMMDD')::int                     AS anchor_int
    FROM users
    WHERE anchor >= DATE '2016-12-03'
),
logs AS MATERIALIZED (
    -- дни прослушивания в 63 днях до точки решения; три правила очистки из staging
    SELECT u.msno,
           to_date(l.date::text, 'YYYYMMDD') - u.anchor              AS day_offset,
           l.total_secs
    FROM raw.user_logs l
    JOIN in_scope u ON u.msno = l.msno
    WHERE l.date >= 20161001
      AND l.date <  20170301
      AND l.date >= u.lo_int
      AND l.date <  u.anchor_int
      AND l.total_secs >= 0                                                  -- правило 1
      AND l.total_secs <= 604800                                             -- правило 3
      AND NOT (l.total_secs > 86400                                          -- правило 2
               AND l.total_secs / NULLIF(l.num_25 + l.num_50 + l.num_75
                                         + l.num_985 + l.num_100, 0) > 3600)
),
periods AS (
    SELECT p.period, p.day_from, p.day_to, p.day_to - p.day_from + 1 AS n_days, p.ord
    FROM (VALUES
        ('неделя -1',            -7,  -1, 1),
        ('неделя -2',           -14,  -8, 2),
        ('неделя -3',           -21, -15, 3),
        ('неделя -4',           -28, -22, 4),
        ('неделя -5',           -35, -29, 5),
        ('неделя -6',           -42, -36, 6),
        ('неделя -7',           -49, -43, 7),
        ('неделя -8',           -56, -50, 8),
        ('неделя -9',           -63, -57, 9),
        ('окно A: дни -14…-1',  -14,  -1, 10),
        ('окно B: дни -60…-31', -60, -31, 11)
    ) AS p(period, day_from, day_to, ord)
),
log_period AS (
    -- дни и секунды по пользователю и периоду
    SELECT g.msno, p.period,
           count(*)                                                  AS active_days,
           sum(g.total_secs)                                         AS secs
    FROM logs g
    JOIN periods p ON g.day_offset BETWEEN p.day_from AND p.day_to
    GROUP BY g.msno, p.period
),
with_logs AS (
    -- у кого есть хоть один день прослушивания за 63 дня
    SELECT DISTINCT msno FROM log_period
),
user_period AS (
    -- каждый пользователь с логами × каждый период, нули включены
    SELECT u.msno, u.is_churn, u.lp_is_auto_renew, u.has_jan_cancel, u.lp_is_free,
           u.tenure_group, u.subscribed_63d,
           p.period, p.ord, p.n_days,
           coalesce(lp.active_days, 0)                               AS active_days,
           coalesce(lp.secs, 0)                                      AS secs
    FROM in_scope u
    JOIN with_logs w ON w.msno = u.msno
    CROSS JOIN periods p
    LEFT JOIN log_period lp ON lp.msno = u.msno AND lp.period = p.period
),
sliced AS (
    SELECT s.slice, s.slice_value, up.is_churn, up.period, up.ord, up.n_days,
           up.active_days, up.secs
    FROM user_period up
    CROSS JOIN LATERAL (VALUES
        ('подписан все 63 дня × автопродление',
         CASE WHEN up.subscribed_63d IS NOT TRUE THEN NULL
              WHEN up.lp_is_auto_renew = 1 THEN 'автопродление: да'
              WHEN up.lp_is_auto_renew = 0 THEN 'автопродление: нет'
              ELSE 'нет оплаты до февраля' END)
    ) AS s(slice, slice_value)
    WHERE s.slice_value IS NOT NULL
),
counts AS (
    -- размер групп: все в проверяемой части, без логов за 63 дня, точка решения раньше 03.12.2016
    SELECT s.slice, s.slice_value, u.is_churn,
           count(*)                                                  AS users_verifiable,
           count(*) FILTER (WHERE u.anchor >= DATE '2016-12-03'
                              AND w.msno IS NULL)                    AS users_no_logs,
           count(*) FILTER (WHERE u.anchor <  DATE '2016-12-03'
                               OR u.anchor IS NULL)                  AS users_anchor_early
    FROM users u
    LEFT JOIN with_logs w ON w.msno = u.msno
    CROSS JOIN LATERAL (VALUES
        ('подписан все 63 дня × автопродление',
         CASE WHEN NOT (u.episode_start <= u.anchor - 63) OR u.episode_start IS NULL THEN NULL
              WHEN u.lp_is_auto_renew = 1 THEN 'автопродление: да'
              WHEN u.lp_is_auto_renew = 0 THEN 'автопродление: нет'
              ELSE 'нет оплаты до февраля' END)
    ) AS s(slice, slice_value)
    WHERE s.slice_value IS NOT NULL
    GROUP BY s.slice, s.slice_value, u.is_churn
),
agg AS (
    SELECT slice, slice_value, is_churn, period, ord,
           count(*)                                                        AS users_with_logs,
           round(100.0 * count(*) FILTER (WHERE active_days > 0) / count(*), 1) AS active_pct,
           round(avg(active_days) * 7.0 / min(n_days), 2)                  AS active_days_per_week,
           round((avg(secs) / 3600 * 7.0 / min(n_days))::numeric, 2)       AS hours_per_week,
           round((percentile_cont(0.5) WITHIN GROUP (ORDER BY secs)
                  / 3600 * 7.0 / min(n_days))::numeric, 2)                 AS median_hours_per_week
    FROM sliced
    GROUP BY slice, slice_value, is_churn, period, ord
)
SELECT a.slice,
       a.slice_value,
       CASE a.is_churn WHEN 1 THEN 'ушёл' ELSE 'остался' END               AS label,
       a.period,
       c.users_verifiable,
       c.users_no_logs,
       c.users_anchor_early,
       a.users_with_logs,
       a.active_pct,
       a.active_days_per_week,
       a.hours_per_week,
       a.median_hours_per_week,
       round(a.hours_per_week / NULLIF(max(a.hours_per_week) FILTER (WHERE a.is_churn = 0)
             OVER (PARTITION BY a.slice, a.slice_value, a.period), 0), 2)  AS hours_vs_stayed,
       round(a.median_hours_per_week / NULLIF(max(a.median_hours_per_week) FILTER (WHERE a.is_churn = 0)
             OVER (PARTITION BY a.slice, a.slice_value, a.period), 0), 2)  AS median_vs_stayed
FROM agg a
JOIN counts c
  ON c.slice = a.slice AND c.slice_value = a.slice_value AND c.is_churn = a.is_churn
ORDER BY a.slice, a.slice_value, a.ord, a.is_churn;
