-- ============================================================================
-- 02_cohort_retention_new_clients.sql — то же, что 01_cohort_retention.sql, но только первые эпизоды новых клиентов
-- (регистрация с 2015 г.): все и с месячным первым платным планом — без повторных эпизодов и давних клиентов.
-- ============================================================================

WITH ep_base AS (
    SELECT date_trunc('month', s.first_paid_date)::date                    AS cohort,
           (s.first_paid_plan BETWEEN 30 AND 31)                           AS monthly_first_plan,
           s.paid_duration_days                                            AS dur,
           s.event
    FROM marts.survival_episodes s
    WHERE s.is_paid
      AND s.sample_reason = 'new_client'
),
ep AS (
    -- каждый эпизод — в слой «все»; с месячным первым платным планом — ещё и во второй слой
    SELECT l.stratum, e.cohort, e.monthly_first_plan, e.dur, e.event
    FROM ep_base e
    CROSS JOIN LATERAL (VALUES
        ('1) новые клиенты: все'),
        (CASE WHEN e.monthly_first_plan THEN '2) новые клиенты: первый план месячный' END)
    ) AS l(stratum)
    WHERE l.stratum IS NOT NULL
),
by_day AS (
    SELECT stratum, cohort, dur, count(*) AS n_end, sum(event) AS d
    FROM ep
    GROUP BY stratum, cohort, dur
),
km AS (
    SELECT stratum, cohort, dur,
           exp(sum(ln(greatest(1 - d::numeric / n_risk, 1e-12))) OVER w)  AS s
    FROM (
        SELECT stratum, cohort, dur, d,
               sum(n_end) OVER (PARTITION BY stratum, cohort ORDER BY dur DESC ROWS UNBOUNDED PRECEDING) AS n_risk
        FROM by_day
    ) AS risk
    WINDOW w AS (PARTITION BY stratum, cohort ORDER BY dur ROWS UNBOUNDED PRECEDING)
),
totals AS (
    SELECT stratum, cohort,
           count(*)                                                        AS episodes,
           round(100.0 * count(*) FILTER (WHERE monthly_first_plan) / count(*), 1)                     AS monthly_first_plan_pct
    FROM ep
    GROUP BY stratum, cohort
),
points AS (
    -- retention к месяцу k = S(30k − 1); месяц наблюдается, если к его концу кто-то ещё под риском
    SELECT t.stratum, t.cohort, p.month_no,
           coalesce((SELECT sum(b.n_end) FROM by_day b
                      WHERE b.stratum = t.stratum AND b.cohort = t.cohort
                        AND b.dur >= 30 * p.month_no - 1), 0)                           AS n_risk_at_end,
           coalesce((SELECT k.s FROM km k
                      WHERE k.stratum = t.stratum AND k.cohort = t.cohort
                        AND k.dur <= 30 * p.month_no - 1
                      ORDER BY k.dur DESC LIMIT 1), 1)                                  AS s
    FROM totals t
    CROSS JOIN generate_series(1, 24) AS p(month_no)
),
wide AS (
    SELECT stratum, cohort,
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
    GROUP BY stratum, cohort
)
SELECT t.stratum,
       to_char(t.cohort, 'YYYY-MM')                                        AS cohort_month,
       t.episodes,
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
JOIN wide w ON w.stratum = t.stratum AND w.cohort = t.cohort
ORDER BY t.stratum, t.cohort;
