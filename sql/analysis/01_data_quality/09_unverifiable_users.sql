-- ============================================================================
-- 09_unverifiable_users.sql — почему пользователи train не попали в пересчёт метки.
-- ============================================================================

WITH missing AS (
    SELECT l.msno, l.is_churn
    FROM staging.labels l
    LEFT JOIN staging.label_recalc r ON r.msno = l.msno
    WHERE r.msno IS NULL
),
tx AS (
    SELECT t.msno, t.transaction_date, t.membership_expire_date AS expire_date, t.is_cancel,
           (CASE WHEN t.is_plan_imputed THEN '0' || '0'
                 ELSE t.plan_list_price::text || t.payment_plan_days::text
            END || t.payment_method_id::text) COLLATE "C" AS sig
    FROM staging.transactions t
    JOIN missing m ON m.msno = t.msno
),
jan_last AS (
    SELECT DISTINCT ON (msno) msno, expire_date, is_cancel
    FROM tx
    WHERE transaction_date BETWEEN DATE '2017-01-01' AND DATE '2017-01-31'
    ORDER BY msno, transaction_date DESC, sig ASC, is_cancel DESC,
             CASE WHEN is_cancel = 1 THEN expire_date END ASC,
             CASE WHEN is_cancel = 0 THEN expire_date END DESC
),
before_feb AS (
    -- последняя оплата до февраля (для тех, у кого января нет)
    SELECT DISTINCT ON (msno) msno, expire_date, payment_days
    FROM (SELECT t.msno, t.transaction_date, t.membership_expire_date AS expire_date,
                 t.payment_plan_days AS payment_days
          FROM staging.transactions t
          JOIN missing m ON m.msno = t.msno
          WHERE t.is_cancel = 0
            AND t.transaction_date < DATE '2017-01-01') AS p
    ORDER BY msno, transaction_date DESC, expire_date DESC
)
SELECT CASE
         WHEN j.msno IS NULL AND b.msno IS NULL                        THEN '1) нет транзакций до февраля'
         WHEN j.msno IS NULL AND b.expire_date BETWEEN DATE '2017-02-01' AND DATE '2017-02-28'
                                                                       THEN '2) нет января, окончание в феврале по ранней оплате'
         WHEN j.msno IS NULL                                           THEN '3) нет января, окончание не в феврале'
         WHEN j.expire_date <  DATE '2017-02-01' AND j.is_cancel = 1   THEN '4) январь: отмена, окончание до февраля'
         WHEN j.expire_date <  DATE '2017-02-01'                       THEN '5) январь: окончание до февраля'
         WHEN j.expire_date >  DATE '2017-02-28' AND j.is_cancel = 1   THEN '6) январь: отмена, окончание после февраля'
         WHEN j.expire_date >  DATE '2017-02-28'                       THEN '7) январь: окончание после февраля'
         ELSE                                                               '8) январь: окончание в феврале'
       END                                                             AS reason,
       count(*)                                                        AS users,
       sum(m.is_churn)                                                 AS churned,
       round(100.0 * avg(m.is_churn), 1)                               AS churn_pct,
       round(avg(b.payment_days) FILTER (WHERE j.msno IS NULL))        AS avg_plan_days_no_jan
FROM missing m
LEFT JOIN jan_last   j ON j.msno = m.msno
LEFT JOIN before_feb b ON b.msno = m.msno
GROUP BY 1
ORDER BY 1;
