-- ============================================================================
-- run_all.sql — сборка базы с нуля. Запускать из папки с данными:
-- psql -U postgres -d churn_case -f ..\sql\run_all.sql
-- ============================================================================

\set ON_ERROR_STOP on

\ir setup/00_schemas.sql
\ir setup/01_create_raw.sql
\ir setup/02_load_raw.sql
\ir setup/03_verify_raw.sql
\ir setup/04_raw_indexes.sql
\ir setup/05_staging_members.sql
\ir setup/06_staging_transactions.sql
\ir setup/07_staging_labels.sql
\ir setup/08_staging_label_recalc.sql
\ir setup/09_staging_transactions_cleanup.sql
\ir setup/10_staging_user_logs_monthly.sql
\ir setup/11_staging_subscription_episodes.sql
\ir setup/12_marts_survival_episodes.sql
\ir setup/13_marts_segment_base.sql
\ir setup/90_marts_dashboard.sql
\ir setup/99_verify_staging.sql
