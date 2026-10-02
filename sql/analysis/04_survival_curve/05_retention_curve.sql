-- ============================================================================
-- 05_retention_curve.sql — retention curve эпизодов подписки (Каплан-Мейер по дням): все и бесплатные — от начала эпизода, платные — от первой платной оплаты; доля оставшихся к концу месяца, интервал Гринвуда, отток в месяц и два варианта naive estimate.
-- ============================================================================

WITH ep AS (
    SELECT g.grp, g.dur, s.event
    FROM marts.survival_episodes s
    CROSS JOIN LATERAL (VALUES
        ('1) все, от начала эпизода',                s.duration_days),
        (CASE WHEN NOT s.is_paid THEN '3) бесплатные, от начала эпизода' END, s.duration_days),
        (CASE WHEN s.is_paid THEN '2) платные, от первой платной оплаты' END, s.paid_duration_days)
    ) AS g(grp, dur)
    WHERE g.grp IS NOT NULL
),
by_day AS (
    SELECT grp, dur, count(*) AS n_end, sum(event) AS d
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
totals AS (
    SELECT grp, sum(n_end) AS n_all, sum(d) AS d_all, max(dur) AS max_dur
    FROM by_day
    GROUP BY grp
),
months AS (
    SELECT t.grp, t.n_all, t.d_all, k.month_no
    FROM totals t
    CROSS JOIN LATERAL generate_series(1, t.max_dur / 30 + 1) AS k(month_no)
),
curve AS (
    SELECT m.grp,
           m.month_no,
           cnt.n_risk,
           cnt.churned,
           coalesce(s_end.s, 1)    AS s_end,
           coalesce(s_end.gw, 0)   AS gw_end,
           coalesce(s_start.s, 1)  AS s_start,
           cnt.reached::numeric          / m.n_all              AS naive_censored_as_churned,
           cnt.churned_reached::numeric  / NULLIF(m.d_all, 0)   AS naive_censored_dropped
    FROM months m
    CROSS JOIN LATERAL (
        SELECT sum(b.n_end) FILTER (WHERE b.dur >= 30 * (m.month_no - 1))                          AS n_risk,
               coalesce(sum(b.d) FILTER (WHERE b.dur BETWEEN 30 * (m.month_no - 1) AND 30 * m.month_no - 1), 0) AS churned,
               coalesce(sum(b.n_end) FILTER (WHERE b.dur >= 30 * m.month_no), 0)                    AS reached,
               coalesce(sum(b.d)     FILTER (WHERE b.dur >= 30 * m.month_no), 0)                    AS churned_reached
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
       round(100 * naive_censored_as_churned, 2)                           AS naive_censored_as_churned_pct,
       round(100 * naive_censored_dropped, 2)                              AS naive_censored_dropped_pct
FROM curve
WHERE n_risk >= 1000
ORDER BY grp, month_no;
