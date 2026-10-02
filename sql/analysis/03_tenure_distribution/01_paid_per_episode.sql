-- ============================================================================
-- 01_paid_per_episode.sql — сколько заплачено за эпизод подписки.
-- ============================================================================

WITH clean AS (
    SELECT status,
           paid_total,
           greatest(end_date - start_date, 0) AS days   -- отмена могла сдвинуть окончание раньше начала
    FROM staging.subscription_episodes
    WHERE n_payments > 0
      AND (episode_no > 1
           OR registration_date BETWEEN DATE '2015-01-01' AND first_tx_date)
)
SELECT CASE WHEN GROUPING(status) = 1   THEN '3) все'
            WHEN status = 'churned'     THEN '1) жизнь закончилась (churned)'
            ELSE                             '2) ещё платят (censored)'
       END                                                               AS grp,
       count(*)                                                          AS episodes,
       round(avg(paid_total))                                            AS paid_avg,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY paid_total))::numeric) AS paid_median,
       round(avg(days) / 30.0, 1)                                        AS months_avg
FROM clean
GROUP BY ROLLUP (status)
ORDER BY grp;
