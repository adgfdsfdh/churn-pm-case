-- ============================================================================
-- 12_marts_survival_episodes.sql — эпизоды подписки для retention curve:
-- выборка «видимое начало», срок с censoring, отсчёт от первой платной оплаты,
-- первый и последний план.
-- ============================================================================

DROP TABLE IF EXISTS marts.survival_episodes;

CREATE TABLE marts.survival_episodes AS
WITH ordered AS (
    SELECT msno,
           transaction_date,
           is_cancel,
           payment_plan_days,
           actual_amount_paid,
           row_number() OVER w                AS rn,
           lag(membership_expire_date) OVER w AS prev_end
    FROM staging.transactions
    WINDOW w AS (PARTITION BY msno
                 ORDER BY transaction_date, is_cancel, membership_expire_date,
                          payment_plan_days, actual_amount_paid,
                          is_auto_renew, payment_method_id)
),
numbered AS (
    SELECT msno, rn, transaction_date, is_cancel, payment_plan_days, actual_amount_paid,
           sum(CASE WHEN rn = 1                                              THEN 1
                    WHEN is_cancel = 0 AND transaction_date - prev_end >= 30 THEN 1
                    ELSE 0 END)
               OVER (PARTITION BY msno ORDER BY rn ROWS UNBOUNDED PRECEDING) AS episode_no
    FROM ordered
),
ep_plan AS (
    SELECT msno,
           episode_no::int                                                        AS episode_no,
           (array_agg(payment_plan_days  ORDER BY rn))[1]                         AS first_plan,
           (array_agg(actual_amount_paid ORDER BY rn))[1] = 0                     AS starts_free,
           (array_agg(payment_plan_days  ORDER BY rn DESC))[1]                    AS last_plan,
           min(transaction_date)  FILTER (WHERE actual_amount_paid > 0)           AS first_paid_date,
           (array_agg(payment_plan_days ORDER BY rn)
                FILTER (WHERE actual_amount_paid > 0))[1]                         AS first_paid_plan
    FROM numbered
    WHERE is_cancel = 0
    GROUP BY msno, episode_no
),
sample AS (
    SELECT e.*,
           CASE WHEN e.episode_no > 1
                    THEN 'repeat'
                WHEN e.registration_date BETWEEN DATE '2015-01-01' AND e.first_tx_date
                    THEN 'new_client'
                WHEN e.registration_date < DATE '2015-01-01' AND e.start_date >= DATE '2016-03-15'
                    THEN 'old_client_late_start'
           END AS sample_reason,
           CASE WHEN e.status = 'churned' THEN e.end_date
                ELSE least(e.end_date, DATE '2017-03-02')
           END AS obs_end
    FROM staging.subscription_episodes e
    WHERE e.n_payments > 0
)
SELECT s.msno,
       s.episode_no,
       s.sample_reason,
       s.start_date,
       s.end_date,
       s.obs_end,
       s.status,
       (s.status = 'churned')::int                                   AS event,
       (s.obs_end < s.start_date)                                    AS is_negative_duration,
       greatest(s.obs_end - s.start_date, 0)                         AS duration_days,
       div(greatest(s.obs_end - s.start_date, 0), 30)::int           AS t_month,
       p.starts_free,
       (p.first_paid_date IS NOT NULL)                               AS is_paid,
       p.first_paid_date,
       CASE WHEN p.first_paid_date IS NOT NULL
            THEN greatest(s.obs_end - p.first_paid_date, 0) END      AS paid_duration_days,
       p.first_plan,
       p.first_paid_plan,
       p.last_plan,
       s.n_payments,
       s.paid_total,
       s.plan_days_total,
       nx.start_date                                                 AS next_start_date
FROM sample s
JOIN ep_plan p
  ON p.msno = s.msno AND p.episode_no = s.episode_no
LEFT JOIN staging.subscription_episodes nx
  ON nx.msno = s.msno AND nx.episode_no = s.episode_no + 1
WHERE s.sample_reason IS NOT NULL;

ALTER TABLE marts.survival_episodes ADD PRIMARY KEY (msno, episode_no);
ANALYZE marts.survival_episodes;

-- контроль: нумерация эпизодов совпала со staging, ни один эпизод не потерян при JOIN
DO $$
DECLARE
    n_expected bigint;
    n_actual   bigint;
BEGIN
    SELECT count(*) INTO n_expected
    FROM staging.subscription_episodes e
    WHERE e.n_payments > 0
      AND (e.episode_no > 1
           OR e.registration_date BETWEEN DATE '2015-01-01' AND e.first_tx_date
           OR (e.registration_date < DATE '2015-01-01' AND e.start_date >= DATE '2016-03-15'));
    SELECT count(*) INTO n_actual FROM marts.survival_episodes;
    IF n_expected <> n_actual THEN
        RAISE EXCEPTION 'marts.survival_episodes: ожидалось % эпизодов, получено %', n_expected, n_actual;
    END IF;
END $$;

-- контроль: состав выборки
SELECT v.ord, v.metric, v.value
FROM (
    SELECT count(*)                                                        AS n_all,
           count(*) FILTER (WHERE sample_reason = 'new_client')            AS n_new,
           count(*) FILTER (WHERE sample_reason = 'repeat')                AS n_repeat,
           count(*) FILTER (WHERE sample_reason = 'old_client_late_start') AS n_old,
           sum(event)                                                      AS n_churned,
           count(*) FILTER (WHERE is_paid)                                 AS n_paid,
           count(*) FILTER (WHERE starts_free)                             AS n_starts_free,
           count(*) FILTER (WHERE starts_free AND is_paid)                 AS n_free_then_paid,
           count(*) FILTER (WHERE is_negative_duration)                    AS n_negative
    FROM marts.survival_episodes
) AS c
CROSS JOIN LATERAL (VALUES
    (1, 'эпизодов всего',                           n_all),
    (2, '  новые клиенты',                          n_new),
    (3, '  повторные',                              n_repeat),
    (4, '  давние клиенты, начало с 15.03.2016',    n_old),
    (5, 'ушли',                                     n_churned),
    (6, 'платных (есть оплата > 0)',                n_paid),
    (7, 'начались с бесплатной оплаты',             n_starts_free),
    (8, '  из них потом заплатили',                 n_free_then_paid),
    (9, 'срок отрицательный (отмена раньше начала)', n_negative)
) AS v(ord, metric, value)
ORDER BY v.ord;
