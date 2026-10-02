-- ============================================================================
-- 01_km_table.sql — таблица дожития по группам эпизодов.
-- ============================================================================

WITH ep AS (
    SELECT e.msno,
           e.episode_no,
           div(greatest(CASE WHEN e.status = 'censored'
                             THEN least(e.end_date, DATE '2017-03-02')
                             ELSE e.end_date
                        END - e.start_date, 0), 30)                      AS t,
           (e.status = 'churned')::int                                   AS event,
           e.registration_date BETWEEN DATE '2015-01-01' AND e.first_tx_date AS client_start_visible
    FROM staging.subscription_episodes e
    WHERE e.n_payments > 0
      AND (e.episode_no > 1
           OR e.registration_date BETWEEN DATE '2015-01-01' AND e.first_tx_date)
),
clean AS (
    SELECT g.grp, ep.t, ep.event
    FROM ep
    CROSS JOIN LATERAL (VALUES
        ('1) все',                               true),
        ('2) первые',                            ep.episode_no = 1),
        ('3) повторные',                         ep.episode_no > 1),
        ('4) повторные, начало клиента видно',   ep.episode_no > 1 AND coalesce(ep.client_start_visible, false))
    ) AS g(grp, keep)
    WHERE g.keep
),
by_month AS (
    SELECT grp, t, count(*) AS n_end, sum(event) AS d
    FROM clean
    GROUP BY grp, t
),
full_months AS (
    SELECT g.grp, m.t, coalesce(b.n_end, 0) AS n_end, coalesce(b.d, 0) AS d
    FROM (SELECT grp, max(t) AS max_t FROM clean GROUP BY grp) AS g
    CROSS JOIN LATERAL generate_series(0, g.max_t) AS m(t)
    LEFT JOIN by_month b ON b.grp = g.grp AND b.t = m.t
),
risk AS (
    SELECT grp, t, d,
           sum(n_end) OVER (PARTITION BY grp ORDER BY t DESC ROWS UNBOUNDED PRECEDING) AS n_risk
    FROM full_months
)
SELECT grp,
       t,
       n_risk,
       d                                                                          AS churned,
       round(d::numeric / n_risk, 5)                                              AS hazard,
       round(exp(sum(ln(greatest(1 - d::numeric / n_risk, 1e-12))) OVER w), 5)    AS s,
       round(exp(sum(ln(greatest(1 - d::numeric / n_risk, 1e-12))) OVER w)
             * sqrt(sum(d::numeric / (n_risk * greatest(n_risk - d, 1))) OVER w), 5) AS s_se
FROM risk
WHERE n_risk >= 1000                         -- дальше кривая ненадёжна
WINDOW w AS (PARTITION BY grp ORDER BY t ROWS UNBOUNDED PRECEDING)
ORDER BY grp, t;
