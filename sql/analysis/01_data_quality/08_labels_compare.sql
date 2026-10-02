-- ============================================================================
-- 08_labels_compare.sql — официальная метка против пересчитанной.
-- ============================================================================

SELECT CASE WHEN r.msno IS NULL THEN '3) только в train'
            WHEN l.msno IS NULL THEN '4) только в пересчёте'
            WHEN l.is_churn = r.is_churn_recalc THEN '1) совпало'
            ELSE '2) расходится'
       END                                          AS grp,
       l.is_churn,
       r.is_churn_recalc,
       count(*)                                     AS users
FROM staging.labels l
FULL JOIN staging.label_recalc r ON r.msno = l.msno
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;
