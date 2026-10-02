-- ============================================================================
-- 04_recruitment_unique_people.sql — сколько уникальных людей войдёт в эксперимент за окно набора
-- 4 / 5 / 6 / 8 недель (человек входит один раз, по первому подходящему окончанию).
-- ============================================================================

WITH tx_days AS (
    -- один день транзакций человека = одна строка (отмены не берём)
    SELECT t.msno,
           t.transaction_date,
           max(t.membership_expire_date)                               AS expire_date,
           sum(t.actual_amount_paid) > 0                               AS is_paid,
           bool_and(t.is_auto_renew = 0)                               AS is_manual,
           bool_and(t.payment_plan_days BETWEEN 30 AND 31)             AS is_monthly,
           bool_or(t.payment_method_id = 38)                           AS is_method_38
    FROM staging.transactions t
    WHERE t.is_cancel = 0
    GROUP BY t.msno, t.transaction_date
),
marked AS (
    SELECT d.*,
           CASE WHEN lag(d.expire_date) OVER w IS NULL
                  OR d.transaction_date - lag(d.expire_date) OVER w >= 30 THEN 1 ELSE 0 END AS new_ep,
           lead(d.transaction_date) OVER w                             AS next_date
    FROM tx_days d
    WINDOW w AS (PARTITION BY d.msno ORDER BY d.transaction_date)
),
ranked AS (
    -- номер платной оплаты внутри эпизода (перерыв 30+ дней — новый эпизод)
    SELECT m.*,
           count(*) FILTER (WHERE m.is_paid) OVER (PARTITION BY m.msno, m.ep_no
                                                   ORDER BY m.transaction_date
                                                   ROWS UNBOUNDED PRECEDING) AS paid_rank
    FROM (SELECT mk.*,
                 sum(mk.new_ep) OVER (PARTITION BY mk.msno ORDER BY mk.transaction_date
                                      ROWS UNBOUNDED PRECEDING)        AS ep_no
          FROM marked mk) m
),
qualifying AS (
    -- все окончания, перед которыми ушло бы напоминание (как в 03_reminder_baseline.sql, но без ограничения «одно в месяц»)
    SELECT r.msno,
           r.expire_date                                               AS expire0,
           CASE WHEN r.paid_rank = 1 THEN 'B' ELSE 'C' END             AS segment
    FROM ranked r
    WHERE r.is_paid AND r.is_manual AND r.is_monthly
      AND (r.next_date IS NULL OR r.next_date > r.expire_date - 3)
),
windows AS (
    SELECT s.start_date, w.weeks, s.start_date + 7 * w.weeks          AS end_date
    FROM (VALUES (DATE '2016-03-07'), (DATE '2016-06-06'), (DATE '2016-09-05')) AS s(start_date)
    CROSS JOIN (VALUES (4), (5), (6), (8)) AS w(weeks)
),
first_entry AS (
    -- первое подходящее окончание человека в окне набора
    SELECT DISTINCT ON (w.start_date, w.weeks, q.msno)
           w.start_date, w.weeks, q.msno, q.segment
    FROM windows w
    JOIN qualifying q
      ON q.expire0 >= w.start_date
     AND q.expire0 <  w.end_date
    ORDER BY w.start_date, w.weeks, q.msno, q.expire0
)
SELECT start_date,
       weeks,
       count(*)                                                        AS people,
       count(*) FILTER (WHERE segment = 'B')                           AS people_b,
       count(*) FILTER (WHERE segment = 'C')                           AS people_c,
       round(100.0 * count(*) FILTER (WHERE segment = 'B') / count(*), 1) AS b_share_pct
FROM first_entry
GROUP BY start_date, weeks
ORDER BY start_date, weeks;
