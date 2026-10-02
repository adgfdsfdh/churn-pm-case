-- ============================================================================
-- 02_members_quality.sql — профили: мусор в возрасте, пустой пол, пользователи train без профиля.
-- ============================================================================

SELECT (SELECT count(*) FILTER (WHERE bd = 0)                  FROM raw.members) AS bd_zero,
       (SELECT count(*) FILTER (WHERE bd BETWEEN 5 AND 100)    FROM raw.members) AS bd_5_100,
       (SELECT count(*) FILTER (WHERE bd > 100)                FROM raw.members) AS bd_over_100,
       (SELECT count(*) FILTER (WHERE bd < 0)                  FROM raw.members) AS bd_negative,
       (SELECT count(*) FILTER (WHERE bd BETWEEN 1 AND 4)      FROM raw.members) AS bd_1_4,
       (SELECT count(*) FILTER (WHERE bd BETWEEN 13 AND 75)    FROM raw.members) AS age_13_75,
       (SELECT count(*) FILTER (WHERE gender IS NULL)          FROM raw.members) AS gender_empty,
       count(*) FILTER (WHERE m.msno IS NULL)                                    AS train_no_profile,
       round(100.0 * avg(l.is_churn) FILTER (WHERE m.msno IS NULL), 2)           AS churn_no_profile_pct,
       round(100.0 * avg(l.is_churn) FILTER (WHERE m.msno IS NOT NULL), 2)       AS churn_with_profile_pct
FROM staging.labels l
LEFT JOIN raw.members m ON m.msno = l.msno;
