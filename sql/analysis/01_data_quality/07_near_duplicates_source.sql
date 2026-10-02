-- ============================================================================
-- 07_near_duplicates_source.sql — почти-дубли: из какого файла каждый экземпляр платежа.
-- ============================================================================

WITH dup_keys AS (
    SELECT msno, transaction_date, actual_amount_paid, is_cancel
    FROM staging.transactions
    GROUP BY msno, transaction_date, actual_amount_paid, payment_plan_days, is_cancel
    HAVING count(*) > 1
),
raw_rows AS (
    SELECT 'main' AS src, t.msno, to_date(t.transaction_date::text, 'YYYYMMDD') AS transaction_date,
           t.actual_amount_paid, t.is_cancel,
           to_date(t.membership_expire_date::text, 'YYYYMMDD') AS expire_date
    FROM raw.transactions t
    JOIN (SELECT DISTINCT msno FROM dup_keys) k ON k.msno = t.msno
    UNION ALL
    SELECT 'v2', t.msno, to_date(t.transaction_date::text, 'YYYYMMDD'),
           t.actual_amount_paid, t.is_cancel,
           to_date(t.membership_expire_date::text, 'YYYYMMDD')
    FROM raw.transactions_v2 t
    JOIN (SELECT DISTINCT msno FROM dup_keys) k ON k.msno = t.msno
),
per_group AS (
    SELECT d.msno, d.transaction_date,
           count(*) FILTER (WHERE r.src = 'main')                AS rows_main,
           count(*) FILTER (WHERE r.src = 'v2')                  AS rows_v2,
           max(r.expire_date) FILTER (WHERE r.src = 'main')      AS max_expire_main,
           max(r.expire_date) FILTER (WHERE r.src = 'v2')        AS max_expire_v2
    FROM (SELECT DISTINCT msno, transaction_date, actual_amount_paid, is_cancel FROM dup_keys) d
    JOIN raw_rows r
      ON r.msno = d.msno AND r.transaction_date = d.transaction_date
     AND r.actual_amount_paid = d.actual_amount_paid AND r.is_cancel = d.is_cancel
    GROUP BY d.msno, d.transaction_date, d.actual_amount_paid, d.is_cancel
)
SELECT CASE WHEN rows_main > 0 AND rows_v2 > 0 THEN '1) в обоих файлах'
            WHEN rows_v2 = 0                   THEN '2) только в основном файле'
            ELSE                                    '3) только в _v2'
       END                                                              AS source,
       count(*)                                                         AS groups,
       count(*) FILTER (WHERE max_expire_v2 > max_expire_main)          AS v2_expire_later,
       count(*) FILTER (WHERE max_expire_v2 < max_expire_main)          AS v2_expire_earlier,
       min(transaction_date)                                            AS first_date,
       max(transaction_date)                                            AS last_date
FROM per_group
GROUP BY 1
ORDER BY 1;
