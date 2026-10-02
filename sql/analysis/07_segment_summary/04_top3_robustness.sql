-- ============================================================================
-- 04_top3_robustness.sql — топ-3 сегмента: потери по официальной метке и по пересчитанной
-- (на проверяемой части train), плюс «упущенная выручка» ушедших бесплатных по цене 149 NTD.
-- ============================================================================

WITH cancel_after AS (
    SELECT t.msno
    FROM staging.transactions t
    JOIN marts.segment_base sb ON sb.msno = t.msno
    WHERE t.transaction_date > DATE '2017-01-31'
      AND t.is_cancel = 1
    GROUP BY t.msno
),
users AS (
    SELECT CASE WHEN sb.lp_is_auto_renew = 0
                 AND sb.tenure_group = '1) 1-й мес. (первое продление)'
                 AND sb.plan_group NOT IN ('3) 32-179 дн.', '4) 180-364 дн.', '5) год и больше')
                    THEN '1) ручная оплата, первое продление'
                WHEN sb.lp_is_auto_renew = 0
                    THEN '2) ручная оплата, остальные и длинные планы'
                WHEN sb.has_jan_cancel OR ca.msno IS NOT NULL
                    THEN '3) отменили автопродление (январь или после 31.01)'
                ELSE     '4) остальные'
           END                                                          AS segment,
           sb.is_churn,
           sb.is_churn_recalc,
           sb.is_verifiable,
           sb.arpu30,
           sb.lp_is_free
    FROM marts.segment_base sb
    LEFT JOIN cancel_after ca ON ca.msno = sb.msno
),
agg AS (
    SELECT coalesce(segment, 'ИТОГО')                                   AS segment,
           GROUPING(segment)                                            AS is_total,
           count(*)                                                     AS users,
           sum(is_churn)                                                AS churned,
           sum(arpu30) FILTER (WHERE is_churn = 1)                      AS mrr_lost,
           count(*) FILTER (WHERE is_verifiable)                        AS users_v,
           sum(is_churn) FILTER (WHERE is_verifiable)                   AS churned_v,
           sum(is_churn_recalc)                                         AS churned_recalc,
           sum(arpu30) FILTER (WHERE is_verifiable AND is_churn = 1)    AS mrr_lost_v,
           sum(arpu30) FILTER (WHERE is_churn_recalc = 1)               AS mrr_lost_recalc,
           count(*) FILTER (WHERE lp_is_free AND is_churn = 1)          AS churned_free
    FROM users
    GROUP BY GROUPING SETS ((segment), ())
)
SELECT segment,
       users,
       churned,
       round(100.0 * churned / users, 2)                                AS churn_pct,
       round(coalesce(mrr_lost, 0))                                     AS mrr_lost,
       round(100 * coalesce(mrr_lost, 0) / max(mrr_lost) FILTER (WHERE is_total = 1) OVER (), 1) AS mrr_lost_share_pct,
       round(100.0 * users_v / users, 1)                                AS verifiable_pct,
       round(100.0 * churned_v / NULLIF(users_v, 0), 2)                 AS churn_official_v_pct,
       round(100.0 * churned_recalc / NULLIF(users_v, 0), 2)            AS churn_recalc_v_pct,
       round(coalesce(mrr_lost_v, 0))                                   AS mrr_lost_official_v,
       round(coalesce(mrr_lost_recalc, 0))                              AS mrr_lost_recalc_v,
       round(100 * coalesce(mrr_lost_recalc, 0)
             / max(mrr_lost_recalc) FILTER (WHERE is_total = 1) OVER (), 1) AS mrr_lost_recalc_share_pct,
       churned_free,
       churned_free * 149                                               AS missed_revenue_free_149
FROM agg
ORDER BY is_total, segment;
