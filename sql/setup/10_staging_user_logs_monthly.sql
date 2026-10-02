-- ============================================================================
-- 10_staging_user_logs_monthly.sql — логи по пользователю и месяцу, три правила очистки.
-- ============================================================================

SET work_mem = '1GB';   -- только для этой сессии

DROP TABLE IF EXISTS staging.user_logs_monthly;

CREATE TABLE staging.user_logs_monthly AS
SELECT msno,
       to_date((date / 100)::text, 'YYYYMM')                 AS month,
       count(*)                                              AS active_days,
       sum(num_25)                                           AS num_25,
       sum(num_50)                                           AS num_50,
       sum(num_75)                                           AS num_75,
       sum(num_985)                                          AS num_985,
       sum(num_100)                                          AS num_100,
       sum(num_25 + num_50 + num_75 + num_985 + num_100)     AS plays,
       sum(num_unq)                                          AS num_unq_daily_sum,
       sum(total_secs)                                       AS total_secs,
       count(*) FILTER (WHERE total_secs > 86400)            AS over_day_days
FROM (
    SELECT msno, date, num_25, num_50, num_75, num_985, num_100, num_unq, total_secs
    FROM raw.user_logs
    UNION ALL
    SELECT msno, date, num_25, num_50, num_75, num_985, num_100, num_unq, total_secs
    FROM raw.user_logs_v2
) AS logs
WHERE total_secs >= 0                                         -- правило 1
  AND total_secs <= 604800                                    -- правило 3
  AND NOT (total_secs > 86400                                 -- правило 2
           AND total_secs / NULLIF(num_25 + num_50 + num_75 + num_985 + num_100, 0) > 3600)
GROUP BY msno, date / 100;

CREATE INDEX user_logs_monthly_msno_idx ON staging.user_logs_monthly (msno);
ANALYZE staging.user_logs_monthly;
RESET work_mem;
