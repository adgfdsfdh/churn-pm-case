-- ============================================================================
-- 04_expire_dates.sql — транзакции: невозможные и далёкие даты окончания подписки.
-- ============================================================================

WITH tx AS (
    SELECT transaction_date, membership_expire_date, is_cancel FROM raw.transactions
    UNION ALL
    SELECT transaction_date, membership_expire_date, is_cancel FROM raw.transactions_v2
)
SELECT count(*) FILTER (WHERE membership_expire_date = 19700101)            AS expire_1970_01_01,
       count(*) FILTER (WHERE membership_expire_date < 20150101)            AS expire_before_2015,
       count(*) FILTER (WHERE membership_expire_date > 20171231)            AS expire_after_2017,
       count(*) FILTER (WHERE membership_expire_date < transaction_date)    AS expire_before_payment,
       count(*) FILTER (WHERE membership_expire_date < transaction_date
                          AND is_cancel = 1)                                AS of_them_cancels
FROM tx;
