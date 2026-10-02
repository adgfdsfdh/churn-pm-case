-- ============================================================================
-- 08_staging_label_recalc.sql — пересчёт метки по опубликованному коду разметки.
-- Запускать до 09.
-- ============================================================================

DROP TABLE IF EXISTS staging.label_recalc;

CREATE TABLE staging.label_recalc AS
WITH tx AS NOT MATERIALIZED (
    SELECT msno, transaction_date, membership_expire_date AS expire_date, is_cancel,
           (CASE WHEN is_plan_imputed THEN '0' || '0'
                 ELSE plan_list_price::text || payment_plan_days::text
            END || payment_method_id::text) COLLATE "C" AS sig
    FROM staging.transactions
),
hist AS (
    -- последняя январская транзакция: её дата окончания
    SELECT DISTINCT ON (msno) msno, expire_date AS last_expire
    FROM tx
    WHERE transaction_date BETWEEN DATE '2017-01-01' AND DATE '2017-01-31'
    ORDER BY msno, transaction_date DESC, sig ASC, is_cancel DESC,
             CASE WHEN is_cancel = 1 THEN expire_date END ASC,
             CASE WHEN is_cancel = 0 THEN expire_date END DESC
),
cand AS (
    SELECT msno, last_expire
    FROM hist
    WHERE last_expire BETWEEN DATE '2017-02-01' AND DATE '2017-02-28'
),
fut AS (
    -- транзакции кандидатов после 31.01.2017, по порядку
    SELECT t.msno, t.transaction_date, t.expire_date, t.is_cancel,
           row_number() OVER (PARTITION BY t.msno
               ORDER BY t.transaction_date ASC, t.sig DESC, t.is_cancel ASC,
                        CASE WHEN t.is_cancel = 0 THEN t.expire_date END ASC,
                        CASE WHEN t.is_cancel = 1 THEN t.expire_date END DESC) AS rn
    FROM tx t
    JOIN cand c ON c.msno = t.msno
    WHERE t.transaction_date > DATE '2017-01-31'
),
first_renewal AS (
    SELECT DISTINCT ON (msno) msno, rn, transaction_date AS renewal_date
    FROM fut
    WHERE is_cancel = 0
    ORDER BY msno, rn
),
cancels_before AS (
    -- отмены до первого продления: самая ранняя из их дат окончания
    SELECT f.msno, min(f.expire_date) AS min_cancel_expire
    FROM fut f
    LEFT JOIN first_renewal r ON r.msno = f.msno
    WHERE f.is_cancel = 1
      AND (r.rn IS NULL OR f.rn < r.rn)
    GROUP BY f.msno
)
SELECT c.msno,
       c.last_expire,
       least(c.last_expire, cb.min_cancel_expire)                  AS effective_expire,
       r.renewal_date,
       r.renewal_date - least(c.last_expire, cb.min_cancel_expire) AS gap_days,
       EXISTS (SELECT 1 FROM fut f WHERE f.msno = c.msno)          AS has_future_tx,
       CASE WHEN r.msno IS NULL THEN 1
            WHEN r.renewal_date - least(c.last_expire, cb.min_cancel_expire) >= 30 THEN 1
            ELSE 0
       END                                                         AS is_churn_recalc
FROM cand c
LEFT JOIN first_renewal  r  ON r.msno  = c.msno
LEFT JOIN cancels_before cb ON cb.msno = c.msno;

ALTER TABLE staging.label_recalc ADD PRIMARY KEY (msno);
ANALYZE staging.label_recalc;
