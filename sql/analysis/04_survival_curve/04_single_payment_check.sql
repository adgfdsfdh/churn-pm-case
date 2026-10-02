-- ============================================================================
-- 04_single_payment_check.sql — длительность эпизодов из одной оплаты.
-- ============================================================================

SELECT CASE WHEN plan_days_total BETWEEN 30 AND 31 THEN 'одна оплата, месячный план'
            WHEN plan_days_total < 30               THEN 'одна оплата, план короче месяца'
            ELSE                                         'одна оплата, план длиннее месяца'
       END                                                          AS episode_kind,
       end_date - start_date                                        AS days,
       div(greatest(end_date - start_date, 0), 30)                  AS t,
       count(*)                                                     AS episodes
FROM staging.subscription_episodes
WHERE n_payments = 1
  AND status = 'churned'
  AND end_date - start_date BETWEEN -5 AND 70
GROUP BY 1, 2, 3
HAVING count(*) >= 100
ORDER BY 1, 2;
