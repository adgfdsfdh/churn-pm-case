-- ============================================================================
-- 05_near_duplicates.sql — почти-дубли: один платёж в нескольких строках.
-- ============================================================================

WITH groups AS (
    SELECT msno, transaction_date, actual_amount_paid, payment_plan_days, is_cancel,
           count(*)                                AS n,
           count(DISTINCT membership_expire_date)  AS n_expire,
           count(DISTINCT is_auto_renew)           AS n_auto_renew,
           count(DISTINCT payment_method_id)       AS n_method
    FROM staging.transactions
    GROUP BY msno, transaction_date, actual_amount_paid, payment_plan_days, is_cancel
    HAVING count(*) > 1
)
SELECT count(*)                                   AS duplicate_groups,
       sum(n)                                     AS rows_in_groups,
       sum(n - 1)                                 AS extra_rows,
       sum((n - 1) * actual_amount_paid)          AS extra_paid_ntd,
       count(*) FILTER (WHERE is_cancel = 0)      AS payment_groups,
       count(*) FILTER (WHERE n_expire > 1)       AS differ_by_expire,
       count(*) FILTER (WHERE n_auto_renew > 1)   AS differ_by_auto_renew,
       count(*) FILTER (WHERE n_method > 1)       AS differ_by_method
FROM groups;
