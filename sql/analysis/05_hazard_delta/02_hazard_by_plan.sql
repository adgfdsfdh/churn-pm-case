-- ============================================================================
-- 02_hazard_by_plan.sql — отток по месяцам жизни эпизода в разрезе длины первого плана (таблица по 30-дневным интервалам, месяцы с 0): откуда всплески оттока.
-- ============================================================================

WITH ordered AS (
    SELECT msno,
           transaction_date,
           is_cancel,
           payment_plan_days,
           row_number() OVER w                AS rn,
           lag(membership_expire_date) OVER w AS prev_end
    FROM staging.transactions
    WINDOW w AS (PARTITION BY msno
                 ORDER BY transaction_date, is_cancel, membership_expire_date,
                          payment_plan_days, actual_amount_paid,
                          is_auto_renew, payment_method_id)
),
numbered AS (
    SELECT msno, rn, is_cancel, payment_plan_days,
           sum(CASE WHEN rn = 1                                              THEN 1
                    WHEN is_cancel = 0 AND transaction_date - prev_end >= 30 THEN 1
                    ELSE 0 END)
               OVER (PARTITION BY msno ORDER BY rn ROWS UNBOUNDED PRECEDING) AS episode_no
    FROM ordered
),
ranked AS (
    SELECT msno, episode_no, payment_plan_days,
           row_number() OVER (PARTITION BY msno, episode_no ORDER BY rn)      AS rn_first_pay,
           row_number() OVER (PARTITION BY msno, episode_no ORDER BY rn DESC) AS rn_last_pay
    FROM numbered
    WHERE is_cancel = 0
),
ep_plan AS (
    SELECT msno,
           episode_no::int                                           AS episode_no,
           max(payment_plan_days) FILTER (WHERE rn_first_pay = 1)    AS first_plan,
           max(payment_plan_days) FILTER (WHERE rn_last_pay = 1)     AS last_plan
    FROM ranked
    WHERE rn_first_pay = 1 OR rn_last_pay = 1
    GROUP BY msno, episode_no
),
ep AS (
    SELECT CASE WHEN p.first_plan BETWEEN 1  AND 29  THEN 'trial'
                WHEN p.first_plan BETWEEN 30 AND 31  THEN 'month'
                WHEN p.first_plan BETWEEN 32 AND 179 THEN 'p32_179'
                WHEN p.first_plan BETWEEN 180 AND 364 THEN 'p180_364'
                WHEN p.first_plan >= 365             THEN 'p365'
           END                                                            AS grp,
           (p.last_plan >= 180)::int                                      AS last_long,
           div(greatest(CASE WHEN e.status = 'censored'
                             THEN least(e.end_date, DATE '2017-03-02')
                             ELSE e.end_date
                        END - e.start_date, 0), 30)                       AS t,
           (e.status = 'churned')::int                                    AS event
    FROM staging.subscription_episodes e
    JOIN ep_plan p
      ON p.msno = e.msno AND p.episode_no = e.episode_no
    WHERE e.n_payments > 0
      AND (e.episode_no > 1
           OR e.registration_date BETWEEN DATE '2015-01-01' AND e.first_tx_date
           OR (e.registration_date < DATE '2015-01-01' AND e.start_date >= DATE '2016-03-15'))
),
by_month AS (
    SELECT g.grp, ep.t,
           count(*)                            AS n_end,
           sum(ep.event)                       AS d,
           sum(ep.event * ep.last_long)        AS d_last_long
    FROM ep
    CROSS JOIN LATERAL (VALUES ('all'), (ep.grp)) AS g(grp)
    WHERE g.grp IS NOT NULL
    GROUP BY g.grp, ep.t
),
full_months AS (
    SELECT g.grp, m.t,
           coalesce(b.n_end, 0)       AS n_end,
           coalesce(b.d, 0)           AS d,
           coalesce(b.d_last_long, 0) AS d_last_long
    FROM (SELECT grp, max(t) AS max_t FROM by_month GROUP BY grp) AS g
    CROSS JOIN LATERAL generate_series(0, g.max_t) AS m(t)
    LEFT JOIN by_month b ON b.grp = g.grp AND b.t = m.t
),
risk AS (
    SELECT grp, t, d, d_last_long,
           sum(n_end) OVER (PARTITION BY grp ORDER BY t DESC ROWS UNBOUNDED PRECEDING) AS n_risk
    FROM full_months
),
wide AS (
    SELECT t,
           max(n_risk)                           FILTER (WHERE grp = 'all')      AS n_risk_all,
           max(d)                                FILTER (WHERE grp = 'all')      AS churned_all,
           max(d::numeric / NULLIF(n_risk, 0))   FILTER (WHERE grp = 'all')      AS hz_all,
           max(d::numeric / NULLIF(n_risk, 0))   FILTER (WHERE grp = 'trial')    AS hz_trial,
           max(d::numeric / NULLIF(n_risk, 0))   FILTER (WHERE grp = 'month')    AS hz_month,
           max(d::numeric / NULLIF(n_risk, 0))   FILTER (WHERE grp = 'p32_179')  AS hz_32_179,
           max(d::numeric / NULLIF(n_risk, 0))   FILTER (WHERE grp = 'p180_364') AS hz_180_364,
           max(n_risk)                           FILTER (WHERE grp = 'p180_364') AS n_risk_180_364,
           max(d::numeric / NULLIF(n_risk, 0))   FILTER (WHERE grp = 'p365')     AS hz_365,
           max(n_risk)                           FILTER (WHERE grp = 'p365')     AS n_risk_365,
           max(d_last_long::numeric / NULLIF(d, 0)) FILTER (WHERE grp = 'all')   AS share_last_long
    FROM risk
    GROUP BY t
)
SELECT t,
       n_risk_all,
       churned_all,
       round(100 * hz_all, 2)          AS hazard_all_pct,
       round(100 * hz_trial, 2)        AS hazard_trial_pct,
       round(100 * hz_month, 2)        AS hazard_month_pct,
       round(100 * hz_32_179, 2)       AS hazard_32_179_pct,
       round(100 * hz_180_364, 2)      AS hazard_180_364_pct,
       n_risk_180_364,
       round(100 * hz_365, 2)          AS hazard_365_pct,
       n_risk_365,
       round(100 * share_last_long, 1) AS pct_churned_last_plan_180plus
FROM wide
WHERE n_risk_all >= 1000
ORDER BY t;
