-- ============================================================================
-- 07_staging_labels.sql — официальная метка оттока из train.
-- ============================================================================

DROP TABLE IF EXISTS staging.labels;

CREATE TABLE staging.labels AS
SELECT msno, is_churn
FROM raw.train;

ALTER TABLE staging.labels ADD PRIMARY KEY (msno);
ANALYZE staging.labels;
