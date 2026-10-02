-- ============================================================================
-- 05_late_payment_loss_summary.sql — во что обходится опоздание с оплатой месячного плана:
-- дни без подписки × цена дня (оплата / дней тарифа), по способу оплаты и сроку опоздания.
-- Продления — как в 01_late_payment_period_start.sql. Две оценки: «подтверждённая» (новый период
-- точно начат с даты оплаты) и «верхняя» (плюс случаи, где правила неразличимы).
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
    SELECT o.transaction_date,
           CASE WHEN o.is_auto_renew = 1 THEN 'автопродление' ELSE 'ручная оплата' END AS pay_kind,
           o.transaction_date - o.prev_expire AS delay,
           o.actual_amount_paid::numeric / o.payment_plan_days AS day_price,
           o.actual_amount_paid,
           abs((o.membership_expire_date - o.prev_expire) - o.payment_plan_days) <= 1        AS is_from_prev,
           abs((o.membership_expire_date - o.transaction_date) - o.payment_plan_days) <= 1   AS is_from_payment
    FROM ordered o
    WHERE o.is_cancel = 0 AND o.prev_is_cancel = 0
      AND o.actual_amount_paid > 0
      AND o.payment_plan_days BETWEEN 30 AND 31
),
classified AS (
    SELECT r.*,
           CASE WHEN r.delay <= 0 THEN '0 вовремя'
                WHEN r.delay <= 2 THEN '1 (1-2 дня)'
                WHEN r.delay <= 7 THEN '2 (3-7 дней)'
                WHEN r.delay <= 29 THEN '3 (8-29 дней)'
                ELSE '4 (30+ дней)' END AS bucket,
           (r.delay BETWEEN 1 AND 29 AND r.is_from_payment AND NOT r.is_from_prev) AS lost_confirmed,
           (r.delay BETWEEN 1 AND 29 AND r.is_from_payment)                        AS lost_upper
    FROM renewals r
)
SELECT coalesce(pay_kind, 'ВСЕГО')   AS pay_kind,
       coalesce(bucket, 'итого')     AS bucket,
       count(*)                      AS renewals,
       count(*) FILTER (WHERE lost_confirmed)                                   AS shifted_confirmed,
       count(*) FILTER (WHERE lost_upper)                                       AS shifted_upper,
       round(sum(delay)  FILTER (WHERE lost_confirmed))                         AS days_lost_confirmed,
       round(sum(delay)  FILTER (WHERE lost_upper))                             AS days_lost_upper,
       round(sum(delay * day_price) FILTER (WHERE lost_confirmed))              AS ntd_lost_confirmed,
       round(sum(delay * day_price) FILTER (WHERE lost_upper))                  AS ntd_lost_upper,
       round(sum(actual_amount_paid))                                           AS ntd_paid_renewals,
       count(DISTINCT date_trunc('month', transaction_date))                    AS months_in_group
FROM classified
GROUP BY GROUPING SETS ((pay_kind, bucket), (pay_kind), ())
ORDER BY pay_kind NULLS LAST, bucket NULLS LAST;
