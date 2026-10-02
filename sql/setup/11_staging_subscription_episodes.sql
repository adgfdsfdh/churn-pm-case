-- ============================================================================
-- 11_staging_subscription_episodes.sql — эпизоды подписки: перерыв 30+ дней — уход,
-- возвращение — новый эпизод.
-- ============================================================================

DROP TABLE IF EXISTS staging.subscription_episodes;

CREATE TABLE staging.subscription_episodes AS
WITH ordered AS (
    SELECT msno,
           transaction_date,
           membership_expire_date AS expire_date,
           is_cancel,
           payment_plan_days,
           actual_amount_paid,
           row_number() OVER w                AS rn,
           lag(membership_expire_date) OVER w AS prev_end
    FROM staging.transactions
    WINDOW w AS (PARTITION BY msno
                 ORDER BY transaction_date, is_cancel, membership_expire_date,
                          payment_plan_days, actual_amount_paid)
),
marked AS (
    SELECT msno, transaction_date, expire_date, is_cancel,
           payment_plan_days, actual_amount_paid, rn,
           transaction_date - prev_end AS gap,
           CASE WHEN rn = 1                                              THEN 1
                WHEN is_cancel = 0 AND transaction_date - prev_end >= 30 THEN 1
                ELSE 0
           END AS new_ep
    FROM ordered
),
numbered AS (
    SELECT msno, transaction_date, expire_date, is_cancel,
           payment_plan_days, actual_amount_paid, rn, gap,
           sum(new_ep) OVER (PARTITION BY msno ORDER BY rn
                             ROWS UNBOUNDED PRECEDING) AS episode_no
    FROM marked
),
plan_changes AS (
    SELECT msno,
           episode_no,
           count(*) FILTER (WHERE payment_plan_days >= 1.5 * prev_plan) AS n_plan_longer,
           count(*) FILTER (WHERE payment_plan_days * 1.5 <= prev_plan) AS n_plan_shorter
    FROM (
        SELECT msno,
               episode_no,
               payment_plan_days,
               lag(payment_plan_days) OVER (PARTITION BY msno, episode_no ORDER BY rn) AS prev_plan
        FROM numbered
        WHERE is_cancel = 0
          AND payment_plan_days > 0
          AND actual_amount_paid > 0          -- пробный бесплатный период не считается планом
    ) AS paid_payments
    GROUP BY msno, episode_no
),
episodes AS (
    SELECT msno,
           episode_no,
           min(transaction_date)                                  AS start_date,
           (array_agg(expire_date ORDER BY rn DESC))[1]           AS end_date,
           count(*) FILTER (WHERE is_cancel = 0)                  AS n_payments,
           count(*) FILTER (WHERE is_cancel = 1)                  AS n_cancels,
           count(*) FILTER (WHERE is_cancel = 0 AND gap BETWEEN 2 AND 29)              AS n_pauses,
           coalesce(sum(gap) FILTER (WHERE is_cancel = 0 AND gap BETWEEN 2 AND 29), 0) AS pause_days,
           coalesce(max(gap) FILTER (WHERE is_cancel = 0 AND gap BETWEEN 2 AND 29), 0) AS max_pause_days,
           coalesce(sum(actual_amount_paid) FILTER (WHERE is_cancel = 0), 0)           AS paid_total,
           coalesce(sum(payment_plan_days)  FILTER (WHERE is_cancel = 0), 0)           AS plan_days_total
    FROM numbered
    GROUP BY msno, episode_no
)
SELECT e.msno,
       e.episode_no::int                                   AS episode_no,
       e.start_date,
       e.end_date,
       CASE WHEN e.end_date + 29 <= DATE '2017-03-31'
            THEN 'churned' ELSE 'censored' END             AS status,
       e.n_payments,
       e.n_cancels,
       e.n_pauses,
       e.pause_days,
       e.max_pause_days,
       coalesce(pc.n_plan_longer, 0)                       AS n_plan_longer,
       coalesce(pc.n_plan_shorter, 0)                      AS n_plan_shorter,
       e.paid_total,
       e.plan_days_total,
       m.registration_date,
       min(e.start_date) OVER (PARTITION BY e.msno)        AS first_tx_date
FROM episodes e
LEFT JOIN plan_changes pc
       ON pc.msno = e.msno AND pc.episode_no = e.episode_no
LEFT JOIN staging.members m
       ON m.msno = e.msno;

ALTER TABLE staging.subscription_episodes ADD PRIMARY KEY (msno, episode_no);
ANALYZE staging.subscription_episodes;
