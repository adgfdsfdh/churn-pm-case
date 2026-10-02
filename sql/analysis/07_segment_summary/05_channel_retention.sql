-- ============================================================================
-- 05_channel_retention.sql — retention первых платных эпизодов новых клиентов по каналу регистрации
-- (Каплан-Мейер по дням от первой платной оплаты): проверка канала вне выборки train;
-- месяц без эпизодов под риском — пусто.
-- ============================================================================

WITH ep AS (
    SELECT coalesce(m.registered_via::text, 'нет профиля')              AS channel,
           s.paid_duration_days                                         AS dur,
           s.event
    FROM marts.survival_episodes s
    JOIN staging.members m ON m.msno = s.msno
    WHERE s.is_paid
      AND s.sample_reason = 'new_client'
),
by_day AS (
    SELECT channel, dur, count(*) AS n_end, sum(event) AS d
    FROM ep
    GROUP BY channel, dur
),
km AS (
    SELECT channel, dur,
           exp(sum(ln(greatest(1 - d::numeric / n_risk, 1e-12))) OVER w) AS s
    FROM (
        SELECT channel, dur, d,
               sum(n_end) OVER (PARTITION BY channel ORDER BY dur DESC ROWS UNBOUNDED PRECEDING) AS n_risk
        FROM by_day
    ) AS risk
    WINDOW w AS (PARTITION BY channel ORDER BY dur ROWS UNBOUNDED PRECEDING)
),
totals AS (
    SELECT channel, sum(n_end) AS episodes
    FROM by_day
    GROUP BY channel
),
points AS (
    SELECT t.channel, t.episodes, p.month_no,
           (SELECT sum(b.n_end) FROM by_day b
             WHERE b.channel = t.channel AND b.dur >= 30 * p.month_no - 1)     AS n_risk_at_end,
           (SELECT k.s FROM km k
             WHERE k.channel = t.channel AND k.dur <= 30 * p.month_no - 1
             ORDER BY k.dur DESC LIMIT 1)                                     AS s
    FROM totals t
    CROSS JOIN (VALUES (2), (3), (6), (12)) AS p(month_no)
)
SELECT channel,
       episodes,
       max(round(100 * s, 1)) FILTER (WHERE month_no = 2 AND n_risk_at_end > 0)                      AS retained_m2_pct,
       max(round(100 * s, 1)) FILTER (WHERE month_no = 3 AND n_risk_at_end > 0)                      AS retained_m3_pct,
       max(round(100 * s, 1)) FILTER (WHERE month_no = 6 AND n_risk_at_end > 0)                      AS retained_m6_pct,
       max(round(100 * s, 1)) FILTER (WHERE month_no = 12 AND n_risk_at_end > 0)                     AS retained_m12_pct,
       max(n_risk_at_end) FILTER (WHERE month_no = 12)                         AS n_risk_m12,
       CASE WHEN episodes < 1000 THEN 'меньше 1 000 эпизодов — вывод шаткий' END AS small_flag
FROM points
GROUP BY channel, episodes
ORDER BY episodes DESC, channel;
