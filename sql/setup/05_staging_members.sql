-- ============================================================================
-- 05_staging_members.sql — профили: дата регистрации, возраст 13–75 или NULL.
-- ============================================================================

DROP TABLE IF EXISTS staging.members;

CREATE TABLE staging.members AS
SELECT msno,
       city,
       CASE WHEN bd BETWEEN 13 AND 75 THEN bd END             AS age,
       gender,                                                -- NULL, если не указан
       registered_via,
       to_date(registration_init_time::text, 'YYYYMMDD')      AS registration_date
FROM raw.members;

ALTER TABLE staging.members ADD PRIMARY KEY (msno);
ANALYZE staging.members;
