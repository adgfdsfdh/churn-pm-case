-- ============================================================================
-- 13_late_cancels.sql — отмены через 30+ дней после окончания подписки: сколько их и как они меняют эпизоды.
-- ============================================================================

WITH ordered AS (
    SELECT msno,
           transaction_date,
           membership_expire_date                 AS expire_date,
           is_cancel,
           row_number() OVER w                    AS rn,
           lag(membership_expire_date) OVER w     AS prev_end,
           lead(transaction_date) OVER w          AS next_tx_date,
           lead(is_cancel) OVER w                 AS next_is_cancel
    FROM staging.transactions
    WINDOW w AS (PARTITION BY msno
                 ORDER BY transaction_date, is_cancel, membership_expire_date,
                          payment_plan_days, actual_amount_paid)
),
marked AS (
    SELECT msno, transaction_date, expire_date, is_cancel, rn, prev_end,
           next_tx_date, next_is_cancel,
           transaction_date - prev_end AS gap,
           CASE WHEN rn = 1                                              THEN 1
                WHEN is_cancel = 0 AND transaction_date - prev_end >= 30 THEN 1
                ELSE 0
           END AS new_ep
    FROM ordered
),
numbered AS (
    SELECT msno, transaction_date, expire_date, is_cancel, rn, prev_end,
           next_tx_date, next_is_cancel, gap,
           sum(new_ep) OVER (PARTITION BY msno ORDER BY rn ROWS UNBOUNDED PRECEDING) AS episode_no,
           lead(new_ep) OVER (PARTITION BY msno ORDER BY rn)                       AS next_new_ep
    FROM marked
),
flags AS (
    SELECT msno, episode_no, is_cancel, rn, gap, expire_date, prev_end,
           (is_cancel = 1 AND rn > 1 AND gap >= 30)                     AS is_late,
           coalesce(next_new_ep, 1) = 1                                 AS is_last_in_ep,
           -- следующая строка — оплата, которая без этой отмены открыла бы новый эпизод
           (next_is_cancel = 0 AND next_new_ep = 0
            AND next_tx_date - prev_end >= 30)                          AS hides_split
    FROM numbered
),
agg AS (
    SELECT
        count(*) FILTER (WHERE is_cancel = 1)                                   AS c_all,
        count(*) FILTER (WHERE is_cancel = 1 AND rn = 1)                        AS c_first_row,
        count(*) FILTER (WHERE is_cancel = 1 AND rn > 1 AND gap < 0)            AS c_before_end,
        count(*) FILTER (WHERE is_cancel = 1 AND rn > 1 AND gap BETWEEN 0 AND 1)  AS c_gap_0_1,
        count(*) FILTER (WHERE is_cancel = 1 AND rn > 1 AND gap BETWEEN 2 AND 29) AS c_gap_2_29,
        count(*) FILTER (WHERE is_late)                                         AS late_n,
        count(DISTINCT msno) FILTER (WHERE is_late)                             AS late_people,
        count(*) FILTER (WHERE is_late AND expire_date > prev_end)              AS late_extends,
        count(*) FILTER (WHERE is_late AND expire_date <= prev_end)             AS late_not_extends,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY expire_date - prev_end)
            FILTER (WHERE is_late AND expire_date > prev_end)                   AS late_ext_median_days,
        count(*) FILTER (WHERE is_late AND is_last_in_ep)                       AS late_last_in_ep,
        count(*) FILTER (WHERE is_late AND is_last_in_ep
                          AND (expire_date + 29 <= DATE '2017-03-31')
                           <> (prev_end    + 29 <= DATE '2017-03-31'))          AS late_last_status_flip,
        count(*) FILTER (WHERE is_late AND hides_split)                         AS late_hides_split
    FROM flags
)
SELECT v.ord, v.metric, v.value
FROM agg
CROSS JOIN LATERAL (VALUES
    (1,  'отмен всего',                                               c_all::numeric),
    (2,  '  первая строка человека (эпизод начинается с отмены)',     c_first_row),
    (3,  '  до окончания подписки (перерыв < 0)',                     c_before_end),
    (4,  '  в день окончания или на следующий (0–1)',                 c_gap_0_1),
    (5,  '  через 2–29 дней после окончания',                         c_gap_2_29),
    (6,  '  через 30+ дней после окончания («поздние»)',              late_n),
    (7,  'поздние: людей',                                            late_people),
    (8,  'поздние: сдвигают окончание вперёд',                        late_extends),
    (9,  'поздние: не сдвигают вперёд',                               late_not_extends),
    (10, 'поздние: медиана сдвига вперёд, дней',                      late_ext_median_days::numeric),
    (11, 'поздние: последняя строка эпизода (задают end_date)',       late_last_in_ep),
    (12, '  из них статус эпизода поменялся бы без этой отмены',      late_last_status_flip),
    (13, 'поздние: склеивают два эпизода (скрытый уход)',             late_hides_split)
) AS v(ord, metric, value)
ORDER BY v.ord;
