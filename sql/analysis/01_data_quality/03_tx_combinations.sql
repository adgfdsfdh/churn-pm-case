-- ============================================================================
-- 03_tx_combinations.sql — транзакции: сочетания «план / прайс / оплата» и доля отмен.
-- ============================================================================

WITH tx AS (
    SELECT payment_plan_days, plan_list_price, actual_amount_paid, is_cancel FROM raw.transactions
    UNION ALL
    SELECT payment_plan_days, plan_list_price, actual_amount_paid, is_cancel FROM raw.transactions_v2
)
SELECT payment_plan_days  = 0 AS plan_zero,
       plan_list_price    = 0 AS price_zero,
       actual_amount_paid = 0 AS paid_zero,
       count(*)                                          AS rows,
       round(100.0 * avg(is_cancel), 1)                  AS cancel_pct
FROM tx
GROUP BY 1, 2, 3
ORDER BY rows DESC;
