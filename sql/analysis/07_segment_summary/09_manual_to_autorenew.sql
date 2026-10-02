-- ============================================================================
-- 09_manual_to_autorenew.sql — как часто ручные плательщики месячного плана сами переходят
-- на автопродление: что было со следующей оплатой (в пределах 60 дней) после ручной оплаты.
-- ============================================================================

WITH paid_days AS (
    -- один день оплаты человека = одна строка (в один день бывает несколько оплат)
    SELECT t.msno,
           t.transaction_date,
           bool_or(t.is_auto_renew = 1)                          AS any_auto,
           bool_or(t.payment_plan_days BETWEEN 30 AND 31)        AS any_monthly,
           bool_or(t.payment_method_id = 38)                     AS any_method_38
    FROM staging.transactions t
    WHERE t.is_cancel = 0
      AND t.actual_amount_paid > 0
    GROUP BY t.msno, t.transaction_date
),
with_next AS (
    SELECT p.*,
           lead(p.transaction_date) OVER w                       AS next_date,
           lead(p.any_auto)         OVER w                       AS next_auto
    FROM paid_days p
    WINDOW w AS (PARTITION BY p.msno ORDER BY p.transaction_date)
),
manual AS (
    -- ручная оплата месячного плана; до 31.01.2017, чтобы 60 дней после неё были видны
    SELECT w.msno,
           w.transaction_date,
           w.any_method_38,
           CASE WHEN w.next_date - w.transaction_date <= 60 AND w.next_auto     THEN 'auto'
                WHEN w.next_date - w.transaction_date <= 60 AND NOT w.next_auto THEN 'manual'
                ELSE 'none' END                                  AS next_kind
    FROM with_next w
    WHERE NOT w.any_auto
      AND w.any_monthly
      AND w.transaction_date BETWEEN DATE '2015-01-01' AND DATE '2017-01-31'
),
layered AS (
    SELECT l.stratum, m.next_kind
    FROM manual m
    LEFT JOIN staging.members mb ON mb.msno = m.msno
    CROSS JOIN LATERAL (VALUES
        ('0) все ручные оплаты месячного плана'),
        ('1) ' || CASE WHEN mb.msno IS NULL          THEN 'нет профиля'
                       WHEN mb.registered_via = 7    THEN 'канал 7'
                       ELSE                               'другой канал' END),
        ('2) год оплаты ' || extract(year FROM m.transaction_date)::int),
        ('3) ' || CASE WHEN m.any_method_38 THEN 'способ оплаты 38' ELSE 'другой способ оплаты' END)
    ) AS l(stratum)
)
SELECT stratum,
       count(*)                                                                     AS manual_payments,
       round(100.0 * count(*) FILTER (WHERE next_kind = 'auto')   / count(*), 2)    AS next_autorenew_pct,
       round(100.0 * count(*) FILTER (WHERE next_kind = 'manual') / count(*), 2)    AS next_manual_pct,
       round(100.0 * count(*) FILTER (WHERE next_kind = 'none')   / count(*), 2)    AS no_payment_60d_pct,
       round(100.0 * count(*) FILTER (WHERE next_kind = 'auto')
             / NULLIF(count(*) FILTER (WHERE next_kind <> 'none'), 0), 2)           AS autorenew_among_renewed_pct
FROM layered
GROUP BY stratum
ORDER BY stratum;
