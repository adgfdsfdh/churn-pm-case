-- ============================================================================
-- 11_monthly_flow.sql — по месяцам: начатые эпизоды, уходы, уходы без возврата.
-- ============================================================================

WITH months AS (
    SELECT generate_series(DATE '2015-01-01', DATE '2017-03-01', INTERVAL '1 month')::date AS month
),
starts AS (
    SELECT date_trunc('month', start_date)::date   AS month,
           count(*)                                AS episodes_started,
           count(*) FILTER (WHERE episode_no = 1)  AS first_visible_episodes
    FROM staging.subscription_episodes
    GROUP BY 1
),
churns AS (
    SELECT date_trunc('month', e.end_date)::date   AS month,
           count(*)                                AS churned_episodes,
           count(*) FILTER (WHERE NOT EXISTS (
               SELECT 1 FROM staging.subscription_episodes next_ep
               WHERE next_ep.msno = e.msno
                 AND next_ep.episode_no = e.episode_no + 1)) AS churned_never_returned
    FROM staging.subscription_episodes e
    WHERE e.status = 'churned'
    GROUP BY 1
)
SELECT m.month,
       coalesce(s.first_visible_episodes, 0) AS first_visible_episodes,
       coalesce(s.episodes_started, 0)       AS episodes_started,
       coalesce(c.churned_episodes, 0)       AS churned_episodes,
       coalesce(c.churned_never_returned, 0) AS churned_never_returned
FROM months m
LEFT JOIN starts s ON s.month = m.month
LEFT JOIN churns c ON c.month = m.month
ORDER BY m.month;
