-- ============================================================================
-- 14_monthly_composition.sql — по месяцам: кто начинает эпизоды и кто уходит (бесплатные, короткие планы, автопродление, отмена, способ оплаты, возврат за 90 дней).
-- ============================================================================

WITH ordered AS (
    SELECT msno,
           transaction_date,
           is_cancel,
           is_auto_renew,
           payment_method_id,
           payment_plan_days,
           actual_amount_paid,
           row_number() OVER w                AS rn,
           lag(membership_expire_date) OVER w AS prev_end
    FROM staging.transactions
    WINDOW w AS (PARTITION BY msno
                 ORDER BY transaction_date, is_cancel, membership_expire_date,
                          payment_plan_days, actual_amount_paid,
                          is_auto_renew, payment_method_id)   -- два последних ключа только делают выбор однозначным
),
numbered AS (
    SELECT msno, rn, is_cancel, is_auto_renew, payment_method_id,
           payment_plan_days, actual_amount_paid,
           sum(CASE WHEN rn = 1                                              THEN 1
                    WHEN is_cancel = 0 AND transaction_date - prev_end >= 30 THEN 1
                    ELSE 0 END)
               OVER (PARTITION BY msno ORDER BY rn ROWS UNBOUNDED PRECEDING) AS episode_no
    FROM ordered
),
ranked AS (
    SELECT msno, episode_no, is_cancel, is_auto_renew, payment_method_id,
           payment_plan_days, actual_amount_paid,
           row_number() OVER (PARTITION BY msno, episode_no ORDER BY rn DESC)            AS rn_last_row,
           row_number() OVER (PARTITION BY msno, episode_no, is_cancel ORDER BY rn)      AS rn_first_of_kind,
           row_number() OVER (PARTITION BY msno, episode_no, is_cancel ORDER BY rn DESC) AS rn_last_of_kind
    FROM numbered
),
ep_tx AS (
    SELECT msno,
           episode_no::int                                                                   AS episode_no,
           bool_or(rn_last_row = 1 AND is_cancel = 1)                                        AS ends_with_cancel,
           max(actual_amount_paid) FILTER (WHERE is_cancel = 0 AND rn_first_of_kind = 1)     AS first_paid,
           max(payment_plan_days)  FILTER (WHERE is_cancel = 0 AND rn_first_of_kind = 1)     AS first_plan,
           max(is_auto_renew)      FILTER (WHERE is_cancel = 0 AND rn_first_of_kind = 1)     AS first_auto,
           max(actual_amount_paid) FILTER (WHERE is_cancel = 0 AND rn_last_of_kind = 1)      AS last_paid,
           max(payment_plan_days)  FILTER (WHERE is_cancel = 0 AND rn_last_of_kind = 1)      AS last_plan,
           max(is_auto_renew)      FILTER (WHERE is_cancel = 0 AND rn_last_of_kind = 1)      AS last_auto,
           max(payment_method_id)  FILTER (WHERE is_cancel = 0 AND rn_last_of_kind = 1)      AS last_method
    FROM ranked
    WHERE rn_last_row = 1 OR rn_first_of_kind = 1 OR rn_last_of_kind = 1
    GROUP BY msno, episode_no
),
ep AS (
    SELECT date_trunc('month', e.start_date)::date AS start_month,
           date_trunc('month', e.end_date)::date   AS end_month,
           e.episode_no,
           e.status,
           e.end_date,
           nx.start_date                           AS next_start,
           t.ends_with_cancel,
           t.first_paid, t.first_plan, t.first_auto,
           t.last_paid,  t.last_plan,  t.last_auto, t.last_method
    FROM staging.subscription_episodes e
    JOIN ep_tx t
      ON t.msno = e.msno AND t.episode_no = e.episode_no
    LEFT JOIN staging.subscription_episodes nx
      ON nx.msno = e.msno AND nx.episode_no = e.episode_no + 1
    WHERE e.n_payments > 0
),
starts AS (
    SELECT start_month                                                         AS month,
           count(*)                                                            AS started,
           round(100.0 * count(*) FILTER (WHERE episode_no = 1)  / count(*), 1) AS pct_first_ep,
           round(100.0 * count(*) FILTER (WHERE first_paid = 0)  / count(*), 1) AS pct_start_free,
           round(100.0 * count(*) FILTER (WHERE first_plan < 30) / count(*), 1) AS pct_start_plan_lt30,
           round(100.0 * count(*) FILTER (WHERE first_auto = 1)  / count(*), 1) AS pct_start_autorenew
    FROM ep
    GROUP BY start_month
),
ends AS (
    SELECT end_month                                                               AS month,
           count(*)                                                                AS churned,
           CASE WHEN end_month <= DATE '2016-12-01' THEN
               round(100.0 * count(*) FILTER (WHERE next_start - end_date <= 90) / count(*), 1)
           END                                                                     AS pct_returned_90d,
           round(100.0 * count(*) FILTER (WHERE ends_with_cancel) / count(*), 1)   AS pct_end_cancel,
           round(100.0 * count(*) FILTER (WHERE last_auto = 1)    / count(*), 1)   AS pct_end_autorenew,
           round(100.0 * count(*) FILTER (WHERE last_paid = 0)    / count(*), 1)   AS pct_end_free,
           round(100.0 * count(*) FILTER (WHERE last_plan < 30)   / count(*), 1)   AS pct_end_plan_lt30
    FROM ep
    WHERE status = 'churned'
    GROUP BY end_month
),
end_methods AS (
    SELECT end_month AS month,
           last_method,
           count(*)  AS n,
           row_number() OVER (PARTITION BY end_month ORDER BY count(*) DESC, last_method) AS pos,
           sum(count(*)) OVER (PARTITION BY end_month)                                     AS total
    FROM ep
    WHERE status = 'churned'
    GROUP BY end_month, last_method
),
months AS (
    SELECT generate_series(DATE '2015-01-01', DATE '2017-03-01', INTERVAL '1 month')::date AS month
)
SELECT to_char(m.month, 'YYYY-MM')                                    AS month,
       CASE WHEN m.month IN (DATE '2015-04-01', DATE '2015-06-01',
                             DATE '2016-03-01', DATE '2016-11-01')
            THEN '<<' ELSE '' END                                     AS anomaly,
       s.started,
       s.pct_first_ep,
       s.pct_start_free,
       s.pct_start_plan_lt30,
       s.pct_start_autorenew,
       n.churned,
       n.pct_returned_90d,
       n.pct_end_cancel,
       n.pct_end_autorenew,
       n.pct_end_free,
       n.pct_end_plan_lt30,
       em.last_method                                                  AS top_end_method,
       round(100.0 * em.n / NULLIF(em.total, 0), 1)                    AS pct_top_end_method
FROM months m
LEFT JOIN starts      s  ON s.month  = m.month
LEFT JOIN ends        n  ON n.month  = m.month
LEFT JOIN end_methods em ON em.month = m.month AND em.pos = 1
ORDER BY m.month;
