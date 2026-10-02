-- ============================================================================
-- 02_method_38_autorenew.sql — поддерживает ли способ оплаты 38 автосписание: доля оплат
-- с автопродлением и число отмен по способам оплаты и годам.
-- ============================================================================

WITH tx AS (
    SELECT CASE WHEN t.payment_method_id = 38 THEN '1) способ 38' ELSE '2) другие способы' END AS method_group,
           extract(year FROM t.transaction_date)::int                  AS tx_year,
           t.msno,
           t.is_auto_renew,
           t.is_cancel,
           t.actual_amount_paid
    FROM staging.transactions t
)
SELECT method_group,
       coalesce(tx_year::text, 'все годы')                             AS tx_year,
       count(*) FILTER (WHERE is_cancel = 0 AND actual_amount_paid > 0)                   AS paid_tx,
       count(*) FILTER (WHERE is_cancel = 0 AND actual_amount_paid > 0 AND is_auto_renew = 1) AS paid_tx_autorenew,
       round(100.0 * count(*) FILTER (WHERE is_cancel = 0 AND actual_amount_paid > 0 AND is_auto_renew = 1)
             / NULLIF(count(*) FILTER (WHERE is_cancel = 0 AND actual_amount_paid > 0), 0), 3) AS paid_autorenew_pct,
       count(*) FILTER (WHERE is_cancel = 1)                           AS cancels,
       count(DISTINCT msno) FILTER (WHERE is_cancel = 0 AND actual_amount_paid > 0 AND is_auto_renew = 1) AS users_with_autorenew_payment
FROM tx
GROUP BY GROUPING SETS ((method_group, tx_year), (method_group))
ORDER BY method_group, GROUPING(tx_year), tx_year;
