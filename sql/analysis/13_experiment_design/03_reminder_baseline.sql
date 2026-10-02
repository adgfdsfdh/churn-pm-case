-- ============================================================================
-- 03_reminder_baseline.sql — базовый уровень для эксперимента «напоминание об оплате»: поток,
-- среднее и SD оплаченных дней за 90 дней после окончания у ручных плательщиков месячного плана
-- (окончания 2016 года), по слоям стажа, способа оплаты, прослушивания и месяца.
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
eligible AS (
    -- кому ушло бы напоминание: ручная платная оплата месячного плана, окончание в 2016,
    -- за 3 дня до окончания ещё не продлил; один человек — не больше одного окончания в месяц
    SELECT DISTINCT ON (r.msno, date_trunc('month', r.expire_date))
           r.msno,
           r.transaction_date                                          AS index_date,
           r.expire_date                                               AS expire0,
           CASE WHEN r.paid_rank = 1 THEN 'B) первое продление' ELSE 'C) стаж 2+ мес.' END AS segment,
           CASE WHEN r.is_method_38 THEN 'способ 38' ELSE 'другие способы' END           AS method_group
    FROM ranked r
    WHERE r.is_paid AND r.is_manual AND r.is_monthly
      AND r.expire_date BETWEEN DATE '2016-01-01' AND DATE '2016-12-31'
      AND (r.next_date IS NULL OR r.next_date > r.expire_date - 3)
    ORDER BY r.msno, date_trunc('month', r.expire_date), r.expire_date
),
periods AS (
    -- оплаченные периоды последующих оплат (сделанных до конца окна), обрезанные окном [окончание; окончание + 90);
    -- поля окончания несём дальше, чтобы не соединять промежуточные таблицы между собой
    SELECT e.msno, e.expire0, e.segment, e.method_group,
           -- без оплат в окне t пустая: greatest/least пропускают NULL, поэтому явная проверка
           CASE WHEN t.msno IS NOT NULL
                THEN greatest(t.membership_expire_date - t.payment_plan_days, e.expire0) END AS p_start,
           CASE WHEN t.msno IS NOT NULL
                THEN least(t.membership_expire_date, e.expire0 + 90) END                 AS p_end,
           t.transaction_date
    FROM eligible e
    LEFT JOIN staging.transactions t
           ON t.msno = e.msno
          AND t.is_cancel = 0
          AND t.actual_amount_paid > 0
          AND t.transaction_date >  e.index_date
          AND t.transaction_date <  e.expire0 + 90
),
merged AS (
    -- объединение периодов без двойного счёта: у каждого — только часть после конца предыдущих
    SELECT p.*,
           max(p.p_end) OVER (PARTITION BY p.msno, p.expire0
                              ORDER BY p.p_start, p.p_end
                              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS covered_until
    FROM periods p
),
outcome AS (
    -- одна строка на окончание; у кого оплат в окне нет — 0 дней
    SELECT m.msno, m.expire0, m.segment, m.method_group,
           coalesce(sum(greatest(0, m.p_end - greatest(m.p_start, coalesce(m.covered_until, m.p_start)))), 0) AS paid_days_90,
           coalesce(bool_or(m.transaction_date < m.expire0 + 30), false)  AS renewed_30
    FROM merged m
    GROUP BY m.msno, m.expire0, m.segment, m.method_group
),
with_logs AS (
    -- прослушивание за календарный месяц до месяца окончания (агрегаты только помесячные)
    SELECT o.*, lg.total_secs
    FROM outcome o
    LEFT JOIN staging.user_logs_monthly lg
           ON lg.msno  = o.msno
          AND lg.month = (date_trunc('month', o.expire0) - interval '1 month')::date
),
median AS (
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY total_secs)   AS median_secs
    FROM with_logs
    WHERE total_secs IS NOT NULL
),
base AS (
    SELECT w.segment,
           w.method_group,
           CASE WHEN w.total_secs IS NULL          THEN 'нет логов'
                WHEN w.total_secs < md.median_secs THEN 'ниже медианы'
                ELSE                                    'медиана и выше'
           END                                                         AS listen_group,
           to_char(w.expire0, 'YYYY-MM')                               AS expire_month,
           w.paid_days_90,
           w.renewed_30
    FROM with_logs w
    CROSS JOIN median md
),
agg AS (
    SELECT CASE WHEN GROUPING(expire_month) = 0              THEN '4) по месяцам окончания'
                WHEN GROUPING(listen_group) = 0              THEN '3) по прослушиванию'
                WHEN GROUPING(method_group) = 0              THEN '2) сегмент × способ оплаты'
                ELSE                                              '1) сегменты и итог'
           END                                                         AS section,
           coalesce(segment, 'B + C')                                  AS segment,
           coalesce(method_group, 'все способы')                       AS method_group,
           coalesce(listen_group, 'все')                               AS listen_group,
           coalesce(expire_month, '2016')                              AS expire_month,
           count(*)                                                    AS n,
           avg(paid_days_90)                                           AS mean_days,
           stddev_samp(paid_days_90)                                   AS sd_days,
           avg(renewed_30::int)                                        AS p_renewed,
           avg(paid_days_90) FILTER (WHERE renewed_30)                 AS mean_days_renewed,
           avg(paid_days_90) FILTER (WHERE NOT renewed_30)             AS mean_days_not_renewed
    FROM base
    GROUP BY GROUPING SETS ((segment), (), (segment, method_group), (listen_group),
                            (segment, listen_group), (segment, expire_month))
)
SELECT a.section,
       a.segment,
       a.method_group,
       a.listen_group,
       a.expire_month,
       a.n,
       round(a.n / CASE WHEN a.expire_month = '2016' THEN 12.0 ELSE 1 END) AS n_per_month,
       round(a.mean_days, 2)                                           AS mean_paid_days_90,
       round(a.sd_days, 2)                                             AS sd_paid_days_90,
       round(100 * a.p_renewed, 2)                                     AS renewed_30d_pct,
       round(a.mean_days_renewed, 2)                                   AS mean_days_if_renewed,
       round(a.mean_days_not_renewed, 2)                               AS mean_days_if_not_renewed,
       -- сколько дней даёт +1 п.п. продливших за 30 дней (если эффект только в этом)
       round((a.mean_days_renewed - a.mean_days_not_renewed) / 100, 3) AS days_per_1pp,
       -- на группу при значимости 5% (двусторонней) и мощности 80%, MDE = 1 оплаченный день
       ceil(2 * (1.959964 + 0.841621)^2 * a.sd_days^2 / 1.0)          AS n_per_group_mde_1day,
       round((SELECT median_secs FROM median)::numeric / 3600, 2)      AS median_hours_month
FROM agg a
ORDER BY a.section, a.segment, a.method_group, a.listen_group, a.expire_month;
