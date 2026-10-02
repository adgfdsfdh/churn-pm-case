-- ============================================================================
-- 01_churn_wilson.sql — доля ушедших с интервалом Уилсона — четыре варианта метки.
-- ============================================================================

WITH per_user AS (
    SELECT l.is_churn, r.is_churn_recalc
    FROM staging.labels l
    LEFT JOIN staging.label_recalc r ON r.msno = l.msno
),
samples AS (
    SELECT v.variant, v.churn
    FROM per_user
    CROSS JOIN LATERAL (VALUES
        ('1) is_churn, весь train',               true,                        is_churn::int),
        ('2) is_churn, проверяемая часть',        is_churn_recalc IS NOT NULL, is_churn::int),
        ('3) is_churn_recalc, проверяемая часть', is_churn_recalc IS NOT NULL, is_churn_recalc),
        ('4) комбинированная, весь train',        true,                        coalesce(is_churn_recalc, is_churn::int))
    ) AS v(variant, in_sample, churn)
    WHERE v.in_sample
),
calc AS (
    SELECT variant,
           count(*)                           AS n,
           sum(churn)                         AS churned,
           sum(churn)::numeric / count(*)     AS p,
           count(*)::numeric                  AS nn,
           1.96::numeric                      AS z
    FROM samples
    GROUP BY variant
)
SELECT variant,
       n,
       churned,
       round(100 * p, 3) AS churn_pct,
       round(100 * (p + z*z/(2*nn) - z * sqrt(p*(1-p)/nn + z*z/(4*nn*nn))) / (1 + z*z/nn), 3) AS wilson_low_pct,
       round(100 * (p + z*z/(2*nn) + z * sqrt(p*(1-p)/nn + z*z/(4*nn*nn))) / (1 + z*z/nn), 3) AS wilson_high_pct
FROM calc
ORDER BY variant;
