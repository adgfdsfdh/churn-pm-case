-- ============================================================================
-- 10_payment_gaps.sql — через сколько дней после окончания подписки приходит следующая оплата.
-- ============================================================================

WITH ordered AS (
    SELECT msno,
           transaction_date,
           membership_expire_date                           AS expire_date,
           is_cancel,
           row_number() OVER w                              AS rn,
           lag(membership_expire_date) OVER w               AS prev_end_last,
           sum(is_cancel) OVER (w ROWS UNBOUNDED PRECEDING) AS cancel_grp  -- растёт на каждой отмене
    FROM staging.transactions
    WINDOW w AS (PARTITION BY msno
                 ORDER BY transaction_date, is_cancel, membership_expire_date,
                          payment_plan_days, actual_amount_paid)
),
prev AS (
    SELECT transaction_date,
           is_cancel,
           prev_end_last,
           max(expire_date) OVER (PARTITION BY msno, cancel_grp ORDER BY rn
                                  ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_end_max
    FROM ordered
),
gaps AS (
    SELECT v.variant, v.gap
    FROM prev
    CROSS JOIN LATERAL (VALUES ('A', transaction_date - prev_end_last),
                               ('B', transaction_date - prev_end_max)) AS v(variant, gap)
    WHERE is_cancel = 0                 -- только оплаты
      AND prev_end_last IS NOT NULL     -- и не первая транзакция человека
)
SELECT CASE WHEN gap < 0   THEN '1) раньше окончания'
            WHEN gap = 0   THEN '2) в день окончания'
            WHEN gap = 1   THEN '3) на следующий день'
            WHEN gap <= 7  THEN '4) через 2-7 дней'
            WHEN gap <= 29 THEN '5) через 8-29 дней'
            ELSE                '6) через 30+ дней'
       END                                      AS bucket,
       count(*) FILTER (WHERE variant = 'A')    AS payments_a_last,
       count(*) FILTER (WHERE variant = 'B')    AS payments_b_max
FROM gaps
GROUP BY 1
ORDER BY 1;
