-- ============================================================================
-- 06_staging_transactions.sql — транзакции: объединение с _v2 без дублей, даты,
-- восстановление незаписанного тарифа по сумме оплаты.
-- ============================================================================

DROP TABLE IF EXISTS staging.transactions CASCADE;

CREATE TABLE staging.transactions AS
WITH combined AS (
    SELECT msno, payment_method_id, payment_plan_days, plan_list_price,
           actual_amount_paid, is_auto_renew, transaction_date,
           membership_expire_date, is_cancel
    FROM raw.transactions
    UNION
    SELECT msno, payment_method_id, payment_plan_days, plan_list_price,
           actual_amount_paid, is_auto_renew, transaction_date,
           membership_expire_date, is_cancel
    FROM raw.transactions_v2
),
tariff_counts AS (
    -- обычные строки: план, прайс и оплата указаны
    SELECT actual_amount_paid, payment_plan_days, plan_list_price, count(*) AS n
    FROM combined
    WHERE payment_plan_days > 0
      AND plan_list_price > 0
      AND actual_amount_paid > 0
    GROUP BY actual_amount_paid, payment_plan_days, plan_list_price
),
tariff_lookup AS (
    -- самый частый тариф для каждой суммы, его доля и число строк с этой суммой
    SELECT DISTINCT ON (actual_amount_paid)
           actual_amount_paid,
           payment_plan_days,
           plan_list_price,
           n::numeric / sum(n) OVER (PARTITION BY actual_amount_paid) AS share,
           sum(n) OVER (PARTITION BY actual_amount_paid)              AS amount_rows
    FROM tariff_counts
    ORDER BY actual_amount_paid, n DESC, payment_plan_days, plan_list_price
)
SELECT c.msno,
       c.payment_method_id,
       coalesce(l.payment_plan_days, c.payment_plan_days)            AS payment_plan_days,
       coalesce(l.plan_list_price,   c.plan_list_price)              AS plan_list_price,
       c.actual_amount_paid,
       c.is_auto_renew,
       to_date(c.transaction_date::text,       'YYYYMMDD')           AS transaction_date,
       to_date(c.membership_expire_date::text, 'YYYYMMDD')           AS membership_expire_date,
       c.is_cancel,
       (l.actual_amount_paid IS NOT NULL)                            AS is_plan_imputed
FROM combined c
LEFT JOIN tariff_lookup l
       ON l.actual_amount_paid = c.actual_amount_paid
      AND c.payment_plan_days  = 0
      AND c.plan_list_price    = 0
      AND c.actual_amount_paid > 0
      AND l.share       >= 0.90
      AND l.amount_rows >= 100;

CREATE INDEX transactions_msno_idx ON staging.transactions (msno);
ANALYZE staging.transactions;
