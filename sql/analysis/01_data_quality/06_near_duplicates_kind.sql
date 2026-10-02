-- ============================================================================
-- 06_near_duplicates_kind.sql — почти-дубли: докупка нескольких месяцев в один день или повторная запись.
-- ============================================================================

WITH groups AS (
    SELECT msno, transaction_date, actual_amount_paid, payment_plan_days, is_cancel,
           count(*)                                                AS n,
           max(membership_expire_date) - min(membership_expire_date) AS expire_spread
    FROM staging.transactions
    GROUP BY msno, transaction_date, actual_amount_paid, payment_plan_days, is_cancel
    HAVING count(*) > 1
)
SELECT CASE WHEN is_cancel = 1                                   THEN '0) отмены'
            WHEN payment_plan_days > 0
             AND abs(expire_spread - payment_plan_days * (n - 1)) <= 2
                                                                 THEN '1) окончание сдвинуто на длину плана: докупили'
            WHEN expire_spread <= 3                              THEN '2) окончание почти то же: запись повторена'
            ELSE                                                      '3) другое'
       END                                            AS kind,
       count(*)                                       AS groups,
       sum(n - 1)                                     AS extra_rows,
       sum((n - 1) * actual_amount_paid)              AS extra_paid_ntd,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY expire_spread) AS median_spread_days
FROM groups
GROUP BY 1
ORDER BY 1;
