-- ============================================================================
-- 06_paid_retention.sql — retention платных эпизодов с отсчётом от первой платной оплаты (Каплан-Мейер по дням): по первому платному плану и по типу эпизода, с долей ушедших на длинном последнем плане.
-- ============================================================================

WITH ep AS (
    SELECT g.grp, s.paid_duration_days AS dur, s.event,
           (s.last_plan >= 180)::int   AS last_long
    FROM marts.survival_episodes s
    CROSS JOIN LATERAL (VALUES
        ('1) платные, все'),
        (CASE WHEN s.first_paid_plan BETWEEN 30 AND 31
              THEN '2) первый платный план месячный' END),
        (CASE WHEN s.first_paid_plan BETWEEN 30 AND 31 AND s.sample_reason <> 'repeat'
              THEN '3) месячный, первый эпизод клиента' END),
        (CASE WHEN s.first_paid_plan BETWEEN 30 AND 31 AND s.sample_reason = 'repeat'
              THEN '4) месячный, повторный эпизод' END)
    ) AS g(grp)
    WHERE s.is_paid
      AND g.grp IS NOT NULL
),
by_day AS (
    SELECT grp, dur, count(*) AS n_end, sum(event) AS d, sum(event * last_long) AS d_long
    FROM ep
    GROUP BY grp, dur
),
km AS (
    SELECT grp, dur,
           exp(sum(ln(greatest(1 - d::numeric / n_risk, 1e-12))) OVER w) AS s,
           sum(d::numeric / (n_risk * greatest(n_risk - d, 1)))      OVER w AS gw
    FROM (
        SELECT grp, dur, d,
               sum(n_end) OVER (PARTITION BY grp ORDER BY dur DESC ROWS UNBOUNDED PRECEDING) AS n_risk
        FROM by_day
    ) AS risk
    WINDOW w AS (PARTITION BY grp ORDER BY dur ROWS UNBOUNDED PRECEDING)
),
months AS (
    SELECT g.grp, k.month_no
    FROM (SELECT grp, max(dur) AS max_dur FROM by_day GROUP BY grp) AS g
    CROSS JOIN LATERAL generate_series(1, g.max_dur / 30 + 1) AS k(month_no)
),
curve AS (
    SELECT m.grp,
           m.month_no,
           cnt.n_risk,
           cnt.churned,
           cnt.churned_long,
           coalesce(s_end.s, 1)   AS s_end,
           coalesce(s_end.gw, 0)  AS gw_end,
           coalesce(s_start.s, 1) AS s_start
    FROM months m
    CROSS JOIN LATERAL (
        SELECT sum(b.n_end) FILTER (WHERE b.dur >= 30 * (m.month_no - 1))                                     AS n_risk,
               coalesce(sum(b.d)      FILTER (WHERE b.dur BETWEEN 30 * (m.month_no - 1) AND 30 * m.month_no - 1), 0) AS churned,
               coalesce(sum(b.d_long) FILTER (WHERE b.dur BETWEEN 30 * (m.month_no - 1) AND 30 * m.month_no - 1), 0) AS churned_long
        FROM by_day b
        WHERE b.grp = m.grp
    ) AS cnt
    LEFT JOIN LATERAL (
        SELECT k.s, k.gw FROM km k
        WHERE k.grp = m.grp AND k.dur <= 30 * m.month_no - 1
        ORDER BY k.dur DESC LIMIT 1
    ) AS s_end ON true
    LEFT JOIN LATERAL (
        SELECT k.s FROM km k
        WHERE k.grp = m.grp AND k.dur <= 30 * (m.month_no - 1) - 1
        ORDER BY k.dur DESC LIMIT 1
    ) AS s_start ON true
)
SELECT grp,
       month_no,
       n_risk,
       churned,
       round(100 * (1 - s_end / NULLIF(s_start, 0)), 2)                    AS churn_in_month_pct,
       round(100 * s_end, 2)                                               AS retained_pct,
       round(100 * greatest(s_end - 1.96 * s_end * sqrt(gw_end), 0), 2)    AS retained_ci_low,
       round(100 * least(s_end + 1.96 * s_end * sqrt(gw_end), 1), 2)       AS retained_ci_high,
       round(100.0 * churned_long / NULLIF(churned, 0), 1)                 AS pct_churned_last_plan_180plus
FROM curve
WHERE n_risk >= 1000
ORDER BY grp, month_no;
