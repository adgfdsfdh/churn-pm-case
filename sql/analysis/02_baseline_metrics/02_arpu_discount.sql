-- ============================================================================
-- 02_arpu_discount.sql — aRPU за 30 дней и скидка — по метке и по длине плана.
-- ============================================================================

WITH last_tx AS (
    SELECT DISTINCT ON (t.msno)
           t.msno, t.payment_plan_days, t.plan_list_price, t.actual_amount_paid
    FROM staging.transactions t
    JOIN staging.labels l ON l.msno = t.msno
    WHERE t.is_cancel = 0
      AND t.payment_plan_days > 0
      AND t.transaction_date <= DATE '2017-01-31'
    ORDER BY t.msno, t.transaction_date DESC, t.membership_expire_date DESC,
             t.actual_amount_paid DESC, t.payment_plan_days DESC
),
per_user AS (
    SELECT CASE WHEN l.is_churn = 1 THEN 'ушёл' ELSE 'остался' END  AS label_group,
           CASE WHEN x.msno IS NULL             THEN '6) нет подписки до февраля'
                WHEN x.payment_plan_days < 30   THEN '1) короче месяца'
                WHEN x.payment_plan_days <= 31  THEN '2) месяц (30-31 дн.)'
                WHEN x.payment_plan_days < 180  THEN '3) 32-179 дн.'
                WHEN x.payment_plan_days < 365  THEN '4) 180-364 дн.'
                ELSE                                 '5) год и больше'
           END                                                       AS plan_group,
           l.is_churn,
           x.actual_amount_paid,
           x.actual_amount_paid * 30.0 / x.payment_plan_days                       AS arpu30,
           (x.plan_list_price - x.actual_amount_paid) * 30.0 / x.payment_plan_days AS discount30
    FROM staging.labels l
    LEFT JOIN last_tx x ON x.msno = l.msno
)
SELECT CASE WHEN GROUPING(label_group) = 0 THEN 'метка: '  || label_group
            WHEN GROUPING(plan_group)  = 0 THEN 'план: '   || plan_group
            ELSE 'все'
       END                                                                     AS slice,
       count(*)                                                                AS users,
       count(arpu30)                                                           AS users_with_tx,
       count(*) FILTER (WHERE actual_amount_paid > 0)                          AS paying_users,
       count(*) FILTER (WHERE is_churn = 1)                                    AS churned,
       round(100.0 * count(*) FILTER (WHERE is_churn = 1) / count(*), 2)       AS churn_pct,
       round(100.0 * count(*) FILTER (WHERE actual_amount_paid = 0)
             / NULLIF(count(arpu30), 0), 1)                                    AS free_pct,
       round(avg(arpu30), 1)                                                   AS arpu30,
       round(avg(arpu30) FILTER (WHERE actual_amount_paid > 0), 1)             AS arppu30,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY arpu30)
              FILTER (WHERE actual_amount_paid > 0))::numeric, 1)              AS arppu30_median,
       round(avg(discount30) FILTER (WHERE actual_amount_paid > 0), 1)         AS discount30,
       round(100.0 * count(*) FILTER (WHERE actual_amount_paid > 0 AND discount30 > 0)
             / NULLIF(count(*) FILTER (WHERE actual_amount_paid > 0), 0), 1)   AS pct_discounted
FROM per_user
GROUP BY GROUPING SETS ((label_group), (plan_group), ())
ORDER BY GROUPING(label_group) DESC, GROUPING(plan_group) DESC, 1;
