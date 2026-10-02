-- ============================================================================
-- 02_tenure_groups.sql — распределение эпизодов по сроку.
-- ============================================================================

WITH clean AS (
    SELECT status,
           div(greatest(CASE WHEN status = 'censored'
                             THEN least(end_date, DATE '2017-03-02')
                             ELSE end_date
                        END - start_date, 0), 30) AS months
    FROM staging.subscription_episodes
    WHERE n_payments > 0
      AND (episode_no > 1
           OR registration_date BETWEEN DATE '2015-01-01' AND first_tx_date)
)
SELECT CASE WHEN months = 0   THEN '1) меньше месяца'
            WHEN months = 1   THEN '2) 1 мес.'
            WHEN months <= 3  THEN '3) 2-3 мес.'
            WHEN months <= 6  THEN '4) 4-6 мес.'
            WHEN months <= 12 THEN '5) 7-12 мес.'
            WHEN months <= 24 THEN '6) 13-24 мес.'
            ELSE                   '7) больше 24 мес.'
       END                                                             AS tenure_group,
       count(*)                                                        AS episodes,
       count(*) FILTER (WHERE status = 'churned')                      AS churned,
       count(*) FILTER (WHERE status = 'censored')                     AS censored,
       round(100.0 * count(*) FILTER (WHERE status = 'churned') / count(*), 1) AS churned_pct_descriptive
FROM clean
GROUP BY 1
ORDER BY 1;
