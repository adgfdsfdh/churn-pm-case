-- ============================================================================
-- 09_staging_transactions_cleanup.sql — удаление транзакций с датой окончания раньше 2015.
-- ============================================================================

-- Сначала посмотреть, что уйдёт:
SELECT count(*)                                              AS rows_to_delete,
       count(DISTINCT msno)                                  AS users,
       sum(actual_amount_paid)                               AS paid_ntd,
       count(*) FILTER (WHERE membership_expire_date = DATE '1970-01-01') AS epoch_zero
FROM staging.transactions
WHERE membership_expire_date < DATE '2015-01-01';

DELETE FROM staging.transactions
WHERE membership_expire_date < DATE '2015-01-01';

ANALYZE staging.transactions;
