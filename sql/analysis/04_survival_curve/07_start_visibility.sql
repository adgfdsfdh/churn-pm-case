-- ============================================================================
-- 07_start_visibility.sql — первые эпизоды подписки по тому, видно ли их начало: размер, доля ушедших и retention по группам (таблица по 30-дневным интервалам).
-- ============================================================================

WITH ep AS (
    SELECT CASE
             WHEN e.registration_date IS NULL                  THEN '5) нет профиля'
             WHEN e.registration_date > e.first_tx_date        THEN '6) регистрация позже первой оплаты'
             WHEN e.registration_date >= DATE '2015-01-01'     THEN '1) регистрация с 2015, до первой оплаты (сейчас в кривой)'
             WHEN e.start_date < DATE '2015-02-01'             THEN '2) регистрация до 2015, первая оплата в янв 2015'
             WHEN e.start_date < DATE '2016-01-01'             THEN '3) регистрация до 2015, первая оплата фев–дек 2015'
             ELSE                                                   '4) регистрация до 2015, первая оплата с 2016'
           END                                                  AS grp,
           (e.start_date < DATE '2015-02-01')::int              AS start_jan2015,
           div(greatest(CASE WHEN e.status = 'censored'
                             THEN least(e.end_date, DATE '2017-03-02')
                             ELSE e.end_date
                        END - e.start_date, 0), 30)             AS t,
           (e.status = 'churned')::int                          AS event
    FROM staging.subscription_episodes e
    WHERE e.episode_no = 1
      AND e.n_payments > 0
),
by_month AS (
    SELECT grp, t, count(*) AS n_end, sum(event) AS d
    FROM ep
    GROUP BY grp, t
),
full_months AS (
    SELECT g.grp, m.t, coalesce(b.n_end, 0) AS n_end, coalesce(b.d, 0) AS d
    FROM (SELECT grp, max(t) AS max_t FROM ep GROUP BY grp) AS g
    CROSS JOIN LATERAL generate_series(0, g.max_t) AS m(t)
    LEFT JOIN by_month b ON b.grp = g.grp AND b.t = m.t
),
risk AS (
    SELECT grp, t, d,
           sum(n_end) OVER (PARTITION BY grp ORDER BY t DESC ROWS UNBOUNDED PRECEDING) AS n_risk
    FROM full_months
),
surv AS (
    SELECT grp, t, n_risk,
           exp(sum(ln(greatest(1 - d::numeric / n_risk, 1e-12)))
               OVER (PARTITION BY grp ORDER BY t ROWS UNBOUNDED PRECEDING))           AS s
    FROM risk
),
curve AS (
    SELECT grp,
           max(s)      FILTER (WHERE t = 0)   AS s1,
           max(s)      FILTER (WHERE t = 5)   AS s6,
           max(s)      FILTER (WHERE t = 11)  AS s12,
           max(s)      FILTER (WHERE t = 23)  AS s24,
           max(n_risk) FILTER (WHERE t = 11)  AS risk12,
           max(n_risk) FILTER (WHERE t = 23)  AS risk24
    FROM surv
    GROUP BY grp
),
sizes AS (
    SELECT grp,
           count(*)           AS episodes,
           sum(event)         AS churned,
           sum(start_jan2015) AS start_jan2015
    FROM ep
    GROUP BY grp
)
SELECT z.grp,
       z.episodes,
       round(100.0 * z.episodes / sum(z.episodes) OVER (), 1)       AS pct_of_first,
       z.churned,
       round(100.0 * z.churned / NULLIF(z.episodes, 0), 1)           AS pct_churned,
       round(100.0 * z.start_jan2015 / NULLIF(z.episodes, 0), 1)     AS pct_start_jan2015,
       round(100 * c.s1, 1)                                          AS s_1m_pct,
       round(100 * c.s6, 1)                                          AS s_6m_pct,
       round(100 * c.s12, 1)                                         AS s_12m_pct,
       c.risk12                                                      AS at_risk_12m,
       round(100 * c.s24, 1)                                         AS s_24m_pct,
       c.risk24                                                      AS at_risk_24m
FROM sizes z
JOIN curve c USING (grp)
ORDER BY z.grp;
