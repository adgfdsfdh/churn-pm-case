-- ============================================================================
-- 10_ltv_constant_churn.sql — LTV платного эпизода при допущении постоянного оттока («ARPU ÷ отток»): для сравнения с LTV по кривой Каплана-Мейера (08_ltv.sql).
-- ============================================================================

WITH ep AS (
    SELECT g.grp,
           s.paid_duration_days AS dur,
           s.event,
           s.paid_total,
           s.plan_days_total
    FROM marts.survival_episodes s
    CROSS JOIN LATERAL (VALUES
        ('1) платные, все'),
        (CASE WHEN s.first_paid_plan BETWEEN 30 AND 31 THEN '2) первый платный план месячный' END)
    ) AS g(grp)
    WHERE s.is_paid
      AND g.grp IS NOT NULL
),
totals AS (
    SELECT grp,
           sum(event)                                                AS churned,
           sum(dur) / 30.0                                           AS months_observed,
           sum(paid_total) * 30.0 / NULLIF(sum(plan_days_total), 0)  AS arpu30
    FROM ep
    GROUP BY grp
),
calc AS (
    SELECT grp, churned, months_observed, arpu30,
           churned / NULLIF(months_observed, 0)                      AS churn_month,
           months_observed / NULLIF(churned, 0)                      AS life_months
    FROM totals
)
SELECT grp                                                           AS "группа",
       round(100 * churn_month, 2)                                   AS "постоянный отток в мес., %",
       round(life_months, 2)                                         AS "срок жизни без ограничения, мес.",
       round(life_months * (1 - exp(-36 / life_months)), 2)          AS "срок жизни в пределах 36 мес.",
       round(life_months * (1 - exp(-60 / life_months)), 2)          AS "срок жизни в пределах 60 мес.",
       round(arpu30 * life_months)                                   AS "LTV «ARPU ÷ отток», NTD",
       round(arpu30 * life_months * (1 - exp(-36 / life_months)))    AS "то же за 36 мес., NTD",
       round(arpu30 * life_months * (1 - exp(-60 / life_months)))    AS "то же за 60 мес., NTD"
FROM calc
ORDER BY grp;
