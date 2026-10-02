-- ============================================================================
-- 01_create_raw.sql — таблицы слоя raw и помесячные секции логов.
-- ============================================================================

-- Метки оттока: train — основная, train_v2 — для проверки устойчивости.

CREATE TABLE raw.train (
    msno      text,
    is_churn  smallint
);

CREATE TABLE raw.train_v2 (
    msno      text,
    is_churn  smallint
);

-- Транзакции; даты — integer YYYYMMDD, _v2 объединяется с основной в staging.

CREATE TABLE raw.transactions (
    msno                   text,
    payment_method_id      smallint,
    payment_plan_days      smallint,
    plan_list_price        integer,
    actual_amount_paid     integer,
    is_auto_renew          smallint,
    transaction_date       integer,
    membership_expire_date integer,
    is_cancel              smallint
);

CREATE TABLE raw.transactions_v2 (LIKE raw.transactions);

-- Профили: одна строка на msno.

CREATE TABLE raw.members (
    msno                   text,
    city                   smallint,
    bd                     integer,
    gender                 text,
    registered_via         smallint,
    registration_init_time integer
);

-- Логи прослушивания: сутки пользователя; секционированы по месяцам (date = YYYYMMDD).

CREATE TABLE raw.user_logs (
    msno       text,
    date       integer,
    num_25     integer,
    num_50     integer,
    num_75     integer,
    num_985    integer,
    num_100    integer,
    num_unq    integer,
    total_secs double precision
) PARTITION BY RANGE (date);

CREATE TABLE raw.user_logs_v2 (
    msno       text,
    date       integer,
    num_25     integer,
    num_50     integer,
    num_75     integer,
    num_985    integer,
    num_100    integer,
    num_unq    integer,
    total_secs double precision
) PARTITION BY RANGE (date);

-- Помесячные секции 2015-01 … 2017-04 для обеих таблиц логов.

DO $$
DECLARE
    t   text;
    d   date;
BEGIN
    FOREACH t IN ARRAY ARRAY['user_logs', 'user_logs_v2'] LOOP
        d := date '2015-01-01';
        WHILE d < date '2017-05-01' LOOP
            EXECUTE format(
                'CREATE TABLE raw.%I PARTITION OF raw.%I
                 FOR VALUES FROM (%s) TO (%s)',
                t || '_' || to_char(d, 'YYYYMM'),
                t,
                to_char(d, 'YYYYMMDD'),
                to_char(d + interval '1 month', 'YYYYMMDD')
            );
            d := d + interval '1 month';
        END LOOP;
    END LOOP;
END $$;
