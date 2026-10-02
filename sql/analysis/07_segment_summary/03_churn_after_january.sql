-- ============================================================================
-- 03_churn_after_january.sql — что было после 31.01.2017 у ушедших из train в каждом из пяти
-- непересекающихся блоков потерь: отмена, поздняя оплата или ни одной транзакции.
-- ============================================================================

WITH after_jan AS (
    SELECT t.msno,
           bool_or(t.is_cancel = 1)                                      AS has_cancel,
           bool_or(t.is_cancel = 0)                                      AS has_payment
    FROM staging.transactions t
    JOIN marts.segment_base sb ON sb.msno = t.msno AND sb.is_churn = 1
    WHERE t.transaction_date > DATE '2017-01-31'
    GROUP BY t.msno
),
churned AS (
    SELECT CASE WHEN sb.lp_is_auto_renew = 0 AND sb.plan_group IN ('3) 32-179 дн.', '4) 180-364 дн.', '5) год и больше')
                    THEN 'A) ручная оплата, длинный план'
                WHEN sb.lp_is_auto_renew = 0 AND sb.tenure_group = '1) 1-й мес. (первое продление)'
                    THEN 'B) ручная оплата, первое продление'
                WHEN sb.lp_is_auto_renew = 0
                    THEN 'C) ручная оплата, остальные'
                WHEN sb.has_jan_cancel
                    THEN 'D) автопродление, отмена в январе'
                WHEN sb.lp_is_auto_renew = 1
                    THEN 'E) автопродление, без отмены'
                ELSE     'F) нет оплаты до февраля'
           END                                                           AS block,
           CASE WHEN a.has_cancel  THEN '1) была отмена после 31.01'
                WHEN a.has_payment THEN '2) была оплата после 31.01, но метка «ушёл»'
                ELSE                    '3) после 31.01 транзакций нет'
           END                                                           AS after_january,
           sb.arpu30,
           sb.is_verifiable
    FROM marts.segment_base sb
    LEFT JOIN after_jan a ON a.msno = sb.msno
    WHERE sb.is_churn = 1
),
agg AS (
    SELECT block,
           coalesce(after_january, 'ИТОГО по блоку')                     AS after_january,
           GROUPING(after_january)                                       AS is_total,
           count(*)                                                      AS churned,
           sum(arpu30)                                                   AS mrr_lost,
           count(*) FILTER (WHERE is_verifiable)                         AS verifiable
    FROM churned
    GROUP BY GROUPING SETS ((block, after_january), (block))
)
SELECT block,
       after_january,
       churned,
       round(100.0 * churned / max(churned) FILTER (WHERE is_total = 1) OVER (PARTITION BY block), 1) AS churned_share_pct,
       round(mrr_lost)                                                   AS mrr_lost,
       round(100 * mrr_lost / NULLIF(max(mrr_lost) FILTER (WHERE is_total = 1) OVER (PARTITION BY block), 0), 1) AS mrr_share_pct,
       round(100.0 * verifiable / churned, 1)                            AS verifiable_pct
FROM agg
ORDER BY block, is_total DESC, after_january;
