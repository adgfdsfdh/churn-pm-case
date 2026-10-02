-- ============================================================================
-- 01_late_payment_period_start.sql — при оплате месячного плана после окончания прежнего периода:
-- от какой даты считается новый период — от прежней даты окончания или от даты оплаты.
-- ============================================================================

WITH ordered AS (
    SELECT t.msno,
           t.transaction_date,
           t.membership_expire_date,
           t.payment_plan_days,
           t.actual_amount_paid,
           t.is_auto_renew,
           t.payment_method_id,
           t.is_cancel,
           lag(t.membership_expire_date) OVER w                      AS prev_expire,
           lag(t.is_cancel)              OVER w                      AS prev_is_cancel
    FROM staging.transactions t
    WINDOW w AS (PARTITION BY t.msno
                 ORDER BY t.transaction_date, t.is_cancel, t.membership_expire_date,
                          t.payment_plan_days, t.actual_amount_paid)   -- порядок как в 11_staging_subscription_episodes.sql
),
renewals AS (
    -- оплата месячного плана сразу после другой оплаты (не отмены)
    SELECT o.*,
           o.transaction_date - o.prev_expire                          AS days_late,
           o.membership_expire_date - o.prev_expire                    AS from_prev_expire,
           o.membership_expire_date - o.transaction_date               AS from_payment
    FROM ordered o
    WHERE o.is_cancel = 0
      AND o.prev_is_cancel = 0
      AND o.actual_amount_paid > 0
      AND o.payment_plan_days BETWEEN 30 AND 31
),
classified AS (
    SELECT CASE WHEN days_late <= 0  THEN '0) вовремя или заранее'
                WHEN days_late <= 2  THEN '1) позже на 1-2 дня (правила не различить)'
                WHEN days_late <= 7  THEN '2) позже на 3-7 дней'
                WHEN days_late <= 29 THEN '3) позже на 8-29 дней'
                ELSE                      '4) позже на 30+ дней (новый эпизод)'
           END                                                         AS lateness,
           CASE WHEN is_auto_renew = 1 THEN 'автопродление' ELSE 'ручная' END AS pay_kind,
           abs(from_prev_expire - payment_plan_days) <= 1              AS is_from_prev,
           abs(from_payment     - payment_plan_days) <= 1              AS is_from_payment
    FROM renewals
)
SELECT lateness,
       pay_kind,
       count(*)                                                        AS renewals,
       round(100.0 * count(*) FILTER (WHERE is_from_prev AND NOT is_from_payment) / count(*), 2) AS from_prev_expire_pct,
       round(100.0 * count(*) FILTER (WHERE is_from_payment AND NOT is_from_prev) / count(*), 2) AS from_payment_pct,
       round(100.0 * count(*) FILTER (WHERE is_from_prev AND is_from_payment)     / count(*), 2) AS both_fit_pct,
       round(100.0 * count(*) FILTER (WHERE NOT is_from_prev AND NOT is_from_payment) / count(*), 2) AS neither_pct
FROM classified
GROUP BY lateness, pay_kind
ORDER BY lateness, pay_kind;
