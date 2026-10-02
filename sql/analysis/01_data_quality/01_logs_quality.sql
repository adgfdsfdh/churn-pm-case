-- ============================================================================
-- 01_logs_quality.sql — логи: нули по корзинам, мусор в total_secs, сезонность по месяцам и дням недели.
-- ============================================================================

WITH logs AS (
    SELECT date, num_25, num_50, num_75, num_985, num_100, total_secs,
           num_25 + num_50 + num_75 + num_985 + num_100 AS plays
    FROM raw.user_logs
    UNION ALL
    SELECT date, num_25, num_50, num_75, num_985, num_100, total_secs,
           num_25 + num_50 + num_75 + num_985 + num_100
    FROM raw.user_logs_v2
),
flagged AS (
    SELECT to_date((date / 100)::text, 'YYYYMM')                        AS month,
           extract(isodow FROM to_date(date::text, 'YYYYMMDD'))::int     AS iso_dow,  -- 1 = пн
           num_25, num_50, num_75, num_985, num_100, total_secs,
           total_secs < 0                                                AS rule1_negative,
           coalesce(total_secs > 86400
                    AND total_secs / NULLIF(plays, 0) > 3600, false)     AS rule2_hour_per_play,
           total_secs > 604800
             AND NOT coalesce(total_secs / NULLIF(plays, 0) > 3600, false) AS rule3_over_week
    FROM logs
)
SELECT CASE WHEN GROUPING(month) = 0   THEN 'month ' || to_char(month, 'YYYY-MM')
            WHEN GROUPING(iso_dow) = 0 THEN 'dow '   || iso_dow
            ELSE 'total'
       END                                                               AS slice,
       count(*)                                                          AS rows,
       round(100.0 * count(*) FILTER (WHERE num_25  = 0) / count(*), 2)  AS zero_25_pct,
       round(100.0 * count(*) FILTER (WHERE num_50  = 0) / count(*), 2)  AS zero_50_pct,
       round(100.0 * count(*) FILTER (WHERE num_75  = 0) / count(*), 2)  AS zero_75_pct,
       round(100.0 * count(*) FILTER (WHERE num_985 = 0) / count(*), 2)  AS zero_985_pct,
       round(100.0 * count(*) FILTER (WHERE num_100 = 0) / count(*), 2)  AS zero_100_pct,
       count(*) FILTER (WHERE rule1_negative)                            AS negative_secs,
       count(*) FILTER (WHERE total_secs > 86400)                        AS over_day,
       count(*) FILTER (WHERE rule2_hour_per_play)                       AS rule2_rows,
       count(*) FILTER (WHERE rule3_over_week)                           AS rule3_rows,
       round((avg(total_secs) FILTER (WHERE NOT rule1_negative
                                        AND NOT rule2_hour_per_play
                                        AND NOT rule3_over_week))::numeric, 0) AS avg_clean_secs
FROM flagged
GROUP BY GROUPING SETS ((month), (iso_dow), ())
ORDER BY GROUPING(month), GROUPING(iso_dow), month, iso_dow;
