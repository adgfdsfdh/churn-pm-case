-- ============================================================================
-- 03_cohorts.sql — отток по годам жизни в когортах по кварталу начала.
-- ============================================================================

WITH ep AS (
    SELECT to_char(start_date, 'YYYY') || '-Q' || to_char(start_date, 'Q')  AS cohort,
           div(greatest(CASE WHEN status = 'censored'
                             THEN least(end_date, DATE '2017-03-02')
                             ELSE end_date
                        END - start_date, 0), 30)                          AS t,
           (status = 'churned')::int                                       AS event
    FROM staging.subscription_episodes
    WHERE n_payments > 0
      AND (episode_no > 1
           OR registration_date BETWEEN DATE '2015-01-01' AND first_tx_date)
      AND start_date < DATE '2016-04-01'
),
by_month AS (
    SELECT cohort, t, count(*) AS n_end, sum(event) AS d
    FROM ep
    GROUP BY cohort, t
),
full_months AS (
    SELECT g.cohort, m.t, coalesce(b.n_end, 0) AS n_end, coalesce(b.d, 0) AS d
    FROM (SELECT cohort, max(t) AS max_t FROM ep GROUP BY cohort) AS g
    CROSS JOIN LATERAL generate_series(0, g.max_t) AS m(t)
    LEFT JOIN by_month b ON b.cohort = g.cohort AND b.t = m.t
),
risk AS (
    SELECT cohort, t, d,
           sum(n_end) OVER (PARTITION BY cohort ORDER BY t DESC ROWS UNBOUNDED PRECEDING) AS n_risk
    FROM full_months
),
surv AS (
    SELECT cohort, t, n_risk,
           exp(sum(ln(greatest(1 - d::numeric / n_risk, 1e-12)))
               OVER (PARTITION BY cohort ORDER BY t ROWS UNBOUNDED PRECEDING)) AS s
    FROM risk
    WHERE n_risk >= 1000
),
years AS (
    SELECT s.cohort, y.year_no,
           least(12 * y.year_no - 1, max(s.t) OVER (PARTITION BY s.cohort)) AS t_end,
           12 * (y.year_no - 1) - 1                                          AS t_start   -- S(−1) = 1
    FROM (SELECT DISTINCT cohort, t FROM surv) AS s
    CROSS JOIN (VALUES (1), (2), (3)) AS y(year_no)
),
rates AS (
    SELECT DISTINCT y.cohort, y.year_no, y.t_end - y.t_start AS months,
           1 - power((SELECT s FROM surv WHERE cohort = y.cohort AND t = y.t_end)
                     / coalesce((SELECT s FROM surv WHERE cohort = y.cohort AND t = y.t_start), 1),
                     1.0 / (y.t_end - y.t_start))                            AS monthly_churn
    FROM years y
    WHERE y.t_end > y.t_start
)
SELECT r1.cohort,
       (SELECT n_risk FROM surv WHERE cohort = r1.cohort AND t = 0)   AS episodes,
       round(100 * r1.monthly_churn, 2)                               AS churn_month_y1_pct,
       (SELECT n_risk FROM surv WHERE cohort = r1.cohort AND t = 12)  AS at_risk_m12,
       round(100 * r2.monthly_churn, 2)                               AS churn_month_y2_pct,
       r2.months                                                      AS months_y2,
       (SELECT n_risk FROM surv WHERE cohort = r1.cohort AND t = 24)  AS at_risk_m24,
       round(100 * r3.monthly_churn, 2)                               AS churn_month_y3_pct,
       r3.months                                                      AS months_y3
FROM rates r1
LEFT JOIN rates r2 ON r2.cohort = r1.cohort AND r2.year_no = 2
LEFT JOIN rates r3 ON r3.cohort = r1.cohort AND r3.year_no = 3
WHERE r1.year_no = 1
ORDER BY r1.cohort;
