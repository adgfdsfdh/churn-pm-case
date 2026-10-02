-- ============================================================================
-- 06_late_payment_loss_by_month.sql — то же, что 05_late_payment_loss_summary.sql,
-- по месяцам оплаты и способу оплаты.
-- ============================================================================

WITH ordered AS (
    SELECT t.msno, t.transaction_date, t.membership_expire_date, t.payment_plan_days,
           t.actual_amount_paid, t.is_auto_renew, t.is_cancel,
           lag(t.membership_expire_date) OVER w AS prev_expire,
           lag(t.is_cancel)              OVER w AS prev_is_cancel
    FROM staging.transactions t
    WINDOW w AS (PARTITION BY t.msno
                 ORDER BY t.transaction_date, t.is_cancel, t.membership_expire_date,
                          t.payment_plan_days, t.actual_amount_paid, t.is_auto_renew, t.payment_method_id)
),
renewals AS (
    SELECT date_trunc('month', o.transaction_date)::date AS pay_month,
           CASE WHEN o.is_auto_renew = 1 THEN 'автопродление' ELSE 'ручная оплата' END AS pay_kind,
           o.transaction_date - o.prev_expire AS delay,
           o.actual_amount_paid::numeric / o.payment_plan_days AS day_price,
           o.actual_amount_paid,
           abs((o.membership_expire_date - o.prev_expire) - o.payment_plan_days) <= 1      AS is_from_prev,
           abs((o.membership_expire_date - o.transaction_date) - o.payment_plan_days) <= 1 AS is_from_payment
    FROM ordered o
    WHERE o.is_cancel = 0 AND o.prev_is_cancel = 0
      AND o.actual_amount_paid > 0
      AND o.payment_plan_days BETWEEN 30 AND 31
)
SELECT pay_month, pay_kind,
       count(*)                                                                                     AS renewals,
       round(sum(delay * day_price) FILTER (WHERE delay BETWEEN 1 AND 29
                                             AND is_from_payment AND NOT is_from_prev))             AS ntd_lost_confirmed,
       round(sum(delay * day_price) FILTER (WHERE delay BETWEEN 1 AND 29 AND is_from_payment))      AS ntd_lost_upper,
       round(sum(actual_amount_paid))                                                               AS ntd_paid_renewals
FROM renewals
GROUP BY pay_month, pay_kind
ORDER BY pay_month, pay_kind;
