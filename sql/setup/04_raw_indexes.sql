-- ============================================================================
-- 04_raw_indexes.sql — индексы по msno и VACUUM ANALYZE.
-- ============================================================================

CREATE UNIQUE INDEX IF NOT EXISTS train_msno_uq    ON raw.train (msno);
CREATE UNIQUE INDEX IF NOT EXISTS train_v2_msno_uq ON raw.train_v2 (msno);
CREATE UNIQUE INDEX IF NOT EXISTS members_msno_uq  ON raw.members (msno);
CREATE INDEX IF NOT EXISTS transactions_msno_idx    ON raw.transactions (msno);
CREATE INDEX IF NOT EXISTS transactions_v2_msno_idx ON raw.transactions_v2 (msno);
CREATE INDEX IF NOT EXISTS user_logs_v2_msno_idx    ON raw.user_logs_v2 (msno);
CREATE INDEX IF NOT EXISTS user_logs_msno_idx       ON raw.user_logs (msno);

-- в pgAdmin запускать отдельной командой: VACUUM не работает внутри транзакции
VACUUM ANALYZE;
