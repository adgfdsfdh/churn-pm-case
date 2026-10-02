-- ============================================================================
-- 01_cohort_retention.sql — retention платных эпизодов по когортам: месяц первой платной оплаты
-- эпизода × месяц жизни (Каплан-Мейер по дням с цензурированием; пусто, если месяц не наблюдается).
-- ============================================================================

WITH ep AS (
    SELECT date_trunc('month', s.first_paid_date)::date                    AS cohort,
           s.sample_reason,
           (s.first_paid_plan BETWEEN 30 AND 31)                           AS monthly_first_plan,
           s.paid_duration_days                                            AS dur,
           s.event
    FROM marts.survival_episodes s
    WHERE s.is_paid
),
by_day AS (
    SELECT cohort, dur, count(*) AS n_end, sum(event) AS d
    FROM ep
    GROUP BY cohort, dur
),
km AS (
    SELECT cohort, dur,
           exp(sum(ln(greatest(1 - d::numeric / n_risk, 1e-12))) OVER w)  AS s
    FROM (
        SELECT cohort, dur, d,
               sum(n_end) OVER (PARTITION BY cohort ORDER BY dur DESC ROWS UNBOUNDED PRECEDING) AS n_risk
        FROM by_day
    ) AS risk
    WINDOW w AS (PARTITION BY cohort ORDER BY dur ROWS UNBOUNDED PRECEDING)
),
totals AS (
    SELECT cohort,
           count(*)                                                        AS episodes,
           round(100.0 * count(*) FILTER (WHERE sample_reason = 'new_client') / count(*), 1)            AS new_client_pct,
           round(100.0 * count(*) FILTER (WHERE sample_reason = 'repeat') / count(*), 1)                AS repeat_pct,
           round(100.0 * count(*) FILTER (WHERE sample_reason = 'old_client_late_start') / count(*), 1) AS old_client_pct,
           round(100.0 * count(*) FILTER (WHERE monthly_first_plan) / count(*), 1)                     AS monthly_first_plan_pct
    FROM ep
    GROUP BY cohort
),
points AS (
    -- retention к месяцу k = S(30k − 1); месяц наблюдается, если к его концу кто-то ещё под риском
    SELECT t.cohort, p.month_no,
           coalesce((SELECT sum(b.n_end) FROM by_day b
                      WHERE b.cohort = t.cohort AND b.dur >= 30 * p.month_no - 1), 0)   AS n_risk_at_end,
           coalesce((SELECT k.s FROM km k
                      WHERE k.cohort = t.cohort AND k.dur <= 30 * p.month_no - 1
                      ORDER BY k.dur DESC LIMIT 1), 1)                                  AS s
    FROM totals t
    CROSS JOIN generate_series(1, 24) AS p(month_no)
),
wide AS (
    SELECT cohort,
           max(s) FILTER (WHERE month_no = 1  AND n_risk_at_end > 0)       AS s1,
           max(s) FILTER (WHERE month_no = 2  AND n_risk_at_end > 0)       AS s2,
           max(s) FILTER (WHERE month_no = 3  AND n_risk_at_end > 0)       AS s3,
           max(s) FILTER (WHERE month_no = 6  AND n_risk_at_end > 0)       AS s6,
           max(s) FILTER (WHERE month_no = 12 AND n_risk_at_end > 0)       AS s12,
           max(s) FILTER (WHERE month_no = 18 AND n_risk_at_end > 0)       AS s18,
           max(s) FILTER (WHERE month_no = 24 AND n_risk_at_end > 0)       AS s24,
           max(n_risk_at_end) FILTER (WHERE month_no = 12)                 AS n_risk_m12,
           max(month_no) FILTER (WHERE n_risk_at_end > 0)                  AS months_observed
    FROM points
    GROUP BY cohort
)
SELECT to_char(t.cohort, 'YYYY-MM')                                        AS cohort_month,
       t.episodes,
       t.new_client_pct,
       t.repeat_pct,
       t.old_client_pct,
       t.monthly_first_plan_pct,
       w.months_observed,
       round(100 * w.s1, 1)                                                AS retained_m1_pct,
       round(100 * w.s2, 1)                                                AS retained_m2_pct,
       round(100 * (1 - w.s2 / NULLIF(w.s1, 0)), 1)                        AS churn_first_renewal_pct,
       round(100 * w.s3, 1)                                                AS retained_m3_pct,
       round(100 * w.s6, 1)                                                AS retained_m6_pct,
       round(100 * w.s12, 1)                                               AS retained_m12_pct,
       round(100 * w.s18, 1)                                               AS retained_m18_pct,
       round(100 * w.s24, 1)                                               AS retained_m24_pct,
       w.n_risk_m12,
       CASE WHEN t.episodes < 1000 THEN 'меньше 1 000 эпизодов — вывод шаткий' END AS small_flag
FROM totals t
JOIN wide w ON w.cohort = t.cohort
ORDER BY t.cohort;
