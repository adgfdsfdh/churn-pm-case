-- ============================================================================
-- 03_lost_revenue.sql — потерянная выручка группы подписок, истекших в феврале 2017.
-- ============================================================================

WITH last_tx AS (
    SELECT DISTINCT ON (t.msno)
           t.msno, t.payment_plan_days, t.actual_amount_paid
    FROM staging.transactions t
    JOIN staging.labels l ON l.msno = t.msno
    WHERE t.is_cancel = 0
      AND t.payment_plan_days > 0
      AND t.transaction_date <= DATE '2017-01-31'
    ORDER BY t.msno, t.transaction_date DESC, t.membership_expire_date DESC,
             t.actual_amount_paid DESC, t.payment_plan_days DESC
),
per_user AS (
    SELECT l.is_churn::int                                               AS is_churn,
           r.is_churn_recalc,
           coalesce(x.actual_amount_paid * 30.0 / x.payment_plan_days, 0) AS arpu30
    FROM staging.labels l
    LEFT JOIN last_tx x              ON x.msno = l.msno
    LEFT JOIN staging.label_recalc r ON r.msno = l.msno
),
variants AS (
    SELECT v.variant,
           count(*)                            AS users,
           sum(v.churn)                        AS churned,
           sum(arpu30)                         AS mrr_cohort,
           sum(arpu30) FILTER (WHERE v.churn = 1) AS mrr_lost
    FROM per_user
    CROSS JOIN LATERAL (VALUES
        ('1) is_churn, весь train',               true,                        is_churn),
        ('2) is_churn, проверяемая часть',        is_churn_recalc IS NOT NULL, is_churn),
        ('3) is_churn_recalc, проверяемая часть', is_churn_recalc IS NOT NULL, is_churn_recalc),
        ('4) комбинированная, весь train',        true,                        coalesce(is_churn_recalc, is_churn))
    ) AS v(variant, in_sample, churn)
    WHERE v.in_sample
    GROUP BY v.variant
)
SELECT variant,
       users,
       churned,
       round(mrr_cohort)                                          AS mrr_cohort,
       round(mrr_lost)                                            AS mrr_lost,
       round(100 * mrr_lost / NULLIF(mrr_cohort, 0), 2)           AS mrr_lost_pct,
       round(mrr_cohort / NULLIF(users, 0), 1)                    AS arpu30,
       round(users::numeric / NULLIF(churned, 0), 1)              AS renewals_until_churn,   -- 1 / доля оттока
       round(mrr_cohort / NULLIF(churned, 0))                     AS ltv_const_churn,
       round(mrr_lost * (1 - power(1 - churned::numeric / users, 12))
                      / (churned::numeric / users))               AS lost_12m_if_stayed
FROM variants
ORDER BY variant;
