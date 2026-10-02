-- ============================================================================
-- 90_marts_dashboard.sql — витрина для графиков кейса и дашборда: агрегаты семи графиков в одной длинной таблице.
-- Колонки: chart — график; series — серия; x_order — порядок точки по оси X (месяц жизни, квинтиль,
-- месяц когорты YYYYMM, неделя до решения со знаком минус, корзина опоздания или номер сегмента);
-- x_label — подпись точки; metric — показатель; value — значение; n — размер группы, на которой посчитано значение.
-- Кривые Каплана-Мейера: n — под риском на начало месяца; точка выгружается до 21-го месяца, пока под риском
-- на конец месяца не меньше 1 000. Группы меньше 100 в витрину не попадают (ограничение таблицы).
-- Интервалы — 95%, без поправки на множественные сравнения.
-- ============================================================================

BEGIN;

DROP TABLE IF EXISTS marts.retention_dashboard;

CREATE TABLE marts.retention_dashboard (
    chart    text    NOT NULL,
    series   text    NOT NULL,
    x_order  int     NOT NULL,
    x_label  text    NOT NULL,
    metric   text    NOT NULL,
    value    numeric,
    n        bigint  NOT NULL CHECK (n >= 100),
    PRIMARY KEY (chart, series, x_order, metric)
);

-- 1. Retention платных эпизодов с первым месячным планом (Каплан-Мейер по дням от первой платной оплаты)
--    и две наивные оценки на той же популяции
INSERT INTO marts.retention_dashboard
WITH ep AS (
    SELECT s.paid_duration_days AS dur, s.event
    FROM marts.survival_episodes s
    WHERE s.is_paid
      AND s.first_paid_plan BETWEEN 30 AND 31
),
by_day AS (
    SELECT dur, count(*) AS n_end, sum(event) AS d
    FROM ep
    GROUP BY dur
),
km AS (
    SELECT dur,
           exp(sum(ln(greatest(1 - d::numeric / n_risk, 1e-12)))
               OVER (ORDER BY dur ROWS UNBOUNDED PRECEDING))           AS s
    FROM (
        SELECT dur, d,
               sum(n_end) OVER (ORDER BY dur DESC ROWS UNBOUNDED PRECEDING) AS n_risk
        FROM by_day
    ) AS risk
),
totals AS (
    SELECT sum(n_end) AS n_all, sum(d) AS d_all
    FROM by_day
),
curve AS (
    SELECT k.month_no,
           t.n_all,
           t.d_all,
           cnt.n_risk_start,
           cnt.n_risk_end,
           coalesce(s_end.s, 1)                                         AS s_end,
           coalesce(s_start.s, 1)                                       AS s_start,
           cnt.reached::numeric         / t.n_all                       AS naive_censored_as_churned,
           cnt.churned_reached::numeric / NULLIF(t.d_all, 0)            AS naive_censored_dropped
    FROM totals t
    CROSS JOIN generate_series(1, 21) AS k(month_no)
    CROSS JOIN LATERAL (
        SELECT coalesce(sum(b.n_end) FILTER (WHERE b.dur >= 30 * (k.month_no - 1)), 0) AS n_risk_start,
               coalesce(sum(b.n_end) FILTER (WHERE b.dur >= 30 * k.month_no - 1), 0)   AS n_risk_end,
               coalesce(sum(b.n_end) FILTER (WHERE b.dur >= 30 * k.month_no), 0)       AS reached,
               coalesce(sum(b.d)     FILTER (WHERE b.dur >= 30 * k.month_no), 0)       AS churned_reached
        FROM by_day b
    ) AS cnt
    LEFT JOIN LATERAL (
        SELECT km.s FROM km WHERE km.dur <= 30 * k.month_no - 1 ORDER BY km.dur DESC LIMIT 1
    ) AS s_end ON true
    LEFT JOIN LATERAL (
        SELECT km.s FROM km WHERE km.dur <= 30 * (k.month_no - 1) - 1 ORDER BY km.dur DESC LIMIT 1
    ) AS s_start ON true
)
SELECT '1 retention: первый платный план месячный',
       v.series, c.month_no, 'мес. ' || c.month_no, v.metric, v.value, v.n
FROM curve c
CROSS JOIN LATERAL (VALUES
    ('Каплан-Мейер',                               'retention, %',      round(100 * c.s_end, 2),                                  c.n_risk_start),
    ('Каплан-Мейер',                               'отток в месяце, %', round(100 * (1 - c.s_end / NULLIF(c.s_start, 0)), 2),     c.n_risk_start),
    ('наивная: незавершённые считаются ушедшими', 'retention, %',      round(100 * c.naive_censored_as_churned, 2),              c.n_all),
    ('наивная: незавершённые выброшены',          'retention, %',      round(100 * c.naive_censored_dropped, 2),                 c.d_all)
) AS v(series, metric, value, n)
WHERE c.n_risk_end >= 1000;

-- 2. Потери в месяц по трём сегментам train (признаки на 31.01.2017);
--    пользователи без оплаты до февраля ни к одному сегменту не относятся и в график не входят
INSERT INTO marts.retention_dashboard
WITH users AS (
    SELECT CASE WHEN sb.lp_is_auto_renew = 0
                 AND sb.tenure_group = '1) 1-й мес. (первое продление)'
                 AND sb.plan_group NOT IN ('3) 32-179 дн.', '4) 180-364 дн.', '5) год и больше')
                    THEN 1
                WHEN sb.lp_is_auto_renew = 0
                    THEN 2
                WHEN sb.lp_is_auto_renew = 1
                    THEN 3
           END                                                          AS segment_no,
           sb.is_churn,
           sb.arpu30
    FROM marts.segment_base sb
),
agg AS (
    SELECT segment_no,
           CASE segment_no
                WHEN 1 THEN 'ручная оплата, первое продление'
                WHEN 2 THEN 'ручная оплата: эпизод от 2 месяцев, длинные планы, начало не видно'
                WHEN 3 THEN 'автопродление включено'
           END                                                          AS segment,
           count(*)                                                     AS users,
           sum(is_churn)                                                AS churned,
           coalesce(sum(arpu30) FILTER (WHERE is_churn = 1), 0)         AS mrr_lost
    FROM users
    WHERE segment_no IS NOT NULL
    GROUP BY segment_no
),
total AS (
    SELECT sum(mrr_lost) AS mrr_lost_all FROM agg
)
SELECT '2 потери по сегментам',
       a.segment, a.segment_no, a.segment, v.metric, v.value, a.users
FROM agg a
CROSS JOIN total t
CROSS JOIN LATERAL (VALUES
    ('людей',                  a.users::numeric),
    ('ушли',                   a.churned::numeric),
    ('отток, %',               round(100.0 * a.churned / a.users, 2)),
    ('потери в месяц, NTD',    round(a.mrr_lost)),
    ('доля потерь, %',         round(100 * a.mrr_lost / t.mrr_lost_all, 1))
) AS v(metric, value);

-- 3. Отток по квинтилям прослушивания в январе 2017 (месячные платные): квинтили общие для всех,
--    отток — по всем и отдельно внутри автопродления «да» и «нет», с интервалом Уилсона
INSERT INTO marts.retention_dashboard
WITH base AS (
    SELECT sb.msno, sb.is_churn, sb.lp_is_auto_renew,
           lg.total_secs / 31.0                                          AS secs_per_day
    FROM marts.segment_base sb
    LEFT JOIN staging.user_logs_monthly lg
           ON lg.msno = sb.msno
          AND lg.month = DATE '2017-01-01'
    WHERE sb.plan_group = '2) месяц (30-31 дн.)'
      AND NOT sb.lp_is_free
      AND (sb.episode_start < DATE '2017-01-01' OR sb.episode_start IS NULL)
      AND lg.total_secs IS NOT NULL
),
ranked AS (
    SELECT b.*, ntile(5) OVER (ORDER BY b.secs_per_day, b.msno)         AS q
    FROM base b
),
agg AS (
    SELECT q,
           CASE GROUPING(lp_is_auto_renew)
                WHEN 1 THEN 'все'
                ELSE CASE lp_is_auto_renew WHEN 1 THEN 'автопродление да' ELSE 'автопродление нет' END
           END                                                          AS series,
           count(*)::numeric                                            AS n,
           sum(is_churn)::numeric / count(*)                            AS p,
           min(secs_per_day) / 3600                                     AS hours_from,
           max(secs_per_day) / 3600                                     AS hours_to
    FROM ranked
    GROUP BY GROUPING SETS ((q, lp_is_auto_renew), (q))
),
wilson AS (
    SELECT a.*,
           ((a.p + 1.96^2 / (2 * a.n))
            - 1.96 * sqrt(a.p * (1 - a.p) / a.n + 1.96^2 / (4 * a.n^2))) / (1 + 1.96^2 / a.n) AS ci_low,
           ((a.p + 1.96^2 / (2 * a.n))
            + 1.96 * sqrt(a.p * (1 - a.p) / a.n + 1.96^2 / (4 * a.n^2))) / (1 + 1.96^2 / a.n) AS ci_high
    FROM agg a
)
SELECT '3 отток по квинтилям прослушивания',
       w.series, w.q, 'Q' || w.q, v.metric, v.value, w.n::bigint
FROM wilson w
CROSS JOIN LATERAL (VALUES
    ('людей',                        w.n,                               true),
    ('отток, %',                     round(100 * w.p, 2),               true),
    ('отток, % — 95% от',            round(100 * w.ci_low, 2),          true),
    ('отток, % — 95% до',            round(100 * w.ci_high, 2),         true),
    ('часов в день, от',             round(w.hours_from::numeric, 2),   w.series = 'все'),
    ('часов в день, до',             round(w.hours_to::numeric, 2),     w.series = 'все')
) AS v(metric, value, keep)
WHERE v.keep
  AND w.n >= 100;

-- 4. Отток на первом продлении по когортам новых клиентов с месячным первым платным планом:
--    все и по автопродлению при первой оплате, с интервалом Гринвуда; плюс доля автопродления в когорте
INSERT INTO marts.retention_dashboard
WITH first_paid AS (
    SELECT s.msno, s.episode_no,
           bool_or(t.is_auto_renew = 1)                                    AS autorenew_at_start
    FROM marts.survival_episodes s
    JOIN staging.transactions t
      ON t.msno = s.msno
     AND t.transaction_date = s.first_paid_date
     AND t.is_cancel = 0
     AND t.actual_amount_paid > 0
    WHERE s.is_paid
      AND s.sample_reason = 'new_client'
      AND s.first_paid_plan BETWEEN 30 AND 31
    GROUP BY s.msno, s.episode_no
),
ep_base AS (
    SELECT date_trunc('month', s.first_paid_date)::date                    AS cohort,
           f.autorenew_at_start,
           s.paid_duration_days                                            AS dur,
           s.event
    FROM marts.survival_episodes s
    JOIN first_paid f ON f.msno = s.msno AND f.episode_no = s.episode_no
),
ep AS (
    SELECT l.stratum, e.cohort, e.dur, e.event
    FROM ep_base e
    CROSS JOIN LATERAL (VALUES
        ('все'),
        (CASE WHEN e.autorenew_at_start THEN 'автопродление да' ELSE 'автопродление нет' END)
    ) AS l(stratum)
),
by_day AS (
    SELECT stratum, cohort, dur, count(*) AS n_end, sum(event) AS d
    FROM ep
    GROUP BY stratum, cohort, dur
),
risk AS (
    SELECT stratum, cohort, dur, d,
           sum(n_end) OVER (PARTITION BY stratum, cohort ORDER BY dur DESC ROWS UNBOUNDED PRECEDING) AS n_risk
    FROM by_day
),
month2 AS (
    -- второй месяц жизни — дни 30…59: условное дожитие S(59)/S(29) и его дисперсия по Гринвуду
    SELECT stratum, cohort,
           exp(sum(ln(greatest(1 - d::numeric / n_risk, 1e-12))))           AS s_cond,
           sum(d::numeric / (n_risk * greatest(n_risk - d, 1)))             AS gw
    FROM risk
    WHERE dur BETWEEN 30 AND 59
    GROUP BY stratum, cohort
),
at_risk AS (
    SELECT stratum, cohort, sum(n_end) FILTER (WHERE dur >= 30) AS n_risk_m2
    FROM by_day
    GROUP BY stratum, cohort
),
churn AS (
    SELECT a.stratum, a.cohort, a.n_risk_m2,
           coalesce(m.s_cond, 1)                                           AS s_cond,
           coalesce(m.gw, 0)                                               AS gw
    FROM at_risk a
    LEFT JOIN month2 m ON m.stratum = a.stratum AND m.cohort = a.cohort
    WHERE a.n_risk_m2 >= 100
),
mix AS (
    SELECT e.cohort,
           count(*)                                                        AS episodes,
           100.0 * count(*) FILTER (WHERE e.autorenew_at_start) / count(*) AS autorenew_pct
    FROM ep_base e
    WHERE e.cohort IN (SELECT cohort FROM churn WHERE stratum = 'все')
    GROUP BY e.cohort
)
SELECT '4 отток на первом продлении по когортам',
       c.stratum,
       (extract(year FROM c.cohort) * 100 + extract(month FROM c.cohort))::int,
       to_char(c.cohort, 'YYYY-MM'),
       v.metric, v.value, c.n_risk_m2
FROM churn c
CROSS JOIN LATERAL (VALUES
    ('отток на первом продлении, %',        round(100 * (1 - c.s_cond), 1)),
    ('отток на первом продлении, % — 95% от', round(100 * greatest(1 - c.s_cond - 1.96 * c.s_cond * sqrt(c.gw), 0), 1)),
    ('отток на первом продлении, % — 95% до', round(100 * least(1 - c.s_cond + 1.96 * c.s_cond * sqrt(c.gw), 1), 1))
) AS v(metric, value)
UNION ALL
SELECT '4 отток на первом продлении по когортам',
       'доля автопродления в когорте',
       (extract(year FROM m.cohort) * 100 + extract(month FROM m.cohort))::int,
       to_char(m.cohort, 'YYYY-MM'),
       'доля автопродления, %',
       round(m.autorenew_pct, 1),
       m.episodes
FROM mix m;

-- 5. Прослушивание по неделям до точки решения (окончание подписки или первая транзакция после 31.01.2017):
--    ушедшие и оставшиеся, подписанные все 63 дня, отдельно по автопродлению; проверяемая часть train;
--    часы — по тем, у кого за 63 дня есть хотя бы один день прослушивания; доля без логов — отдельным показателем
INSERT INTO marts.retention_dashboard
WITH first_tx AS (
    SELECT t.msno, min(t.transaction_date) AS first_tx_after_jan
    FROM staging.transactions t
    JOIN staging.label_recalc r ON r.msno = t.msno
    WHERE t.transaction_date > DATE '2017-01-31'
    GROUP BY t.msno
),
in_scope AS (
    SELECT sb.msno,
           sb.is_churn,
           sb.lp_is_auto_renew,
           least(r.effective_expire, ft.first_tx_after_jan)               AS anchor
    FROM marts.segment_base sb
    JOIN staging.label_recalc r ON r.msno = sb.msno
    LEFT JOIN first_tx ft       ON ft.msno = sb.msno
    WHERE least(r.effective_expire, ft.first_tx_after_jan) >= DATE '2016-12-03'
      AND sb.episode_start <= least(r.effective_expire, ft.first_tx_after_jan) - 63
      AND sb.lp_is_auto_renew IS NOT NULL
),
scope_int AS (
    SELECT i.*,
           to_char(i.anchor - 63, 'YYYYMMDD')::int                         AS lo_int,
           to_char(i.anchor,      'YYYYMMDD')::int                         AS anchor_int
    FROM in_scope i
),
logs AS MATERIALIZED (
    SELECT u.msno,
           to_date(l.date::text, 'YYYYMMDD') - u.anchor                    AS day_offset,
           l.total_secs
    FROM raw.user_logs l
    JOIN scope_int u ON u.msno = l.msno
    WHERE l.date >= 20161001
      AND l.date <  20170301
      AND l.date >= u.lo_int
      AND l.date <  u.anchor_int
      AND l.total_secs >= 0
      AND l.total_secs <= 604800
      AND NOT (l.total_secs > 86400
               AND l.total_secs / NULLIF(l.num_25 + l.num_50 + l.num_75
                                         + l.num_985 + l.num_100, 0) > 3600)
),
weeks AS (
    SELECT w AS week_no, -7 * w AS day_from, -7 * w + 6 AS day_to
    FROM generate_series(1, 9) AS w
),
log_week AS (
    SELECT g.msno, wk.week_no, count(*) AS active_days, sum(g.total_secs) AS secs
    FROM logs g
    JOIN weeks wk ON g.day_offset BETWEEN wk.day_from AND wk.day_to
    GROUP BY g.msno, wk.week_no
),
with_logs AS (
    SELECT DISTINCT msno FROM log_week
),
user_week AS (
    SELECT u.msno, u.is_churn, u.lp_is_auto_renew, wk.week_no,
           coalesce(lw.active_days, 0)                                      AS active_days,
           coalesce(lw.secs, 0)                                             AS secs
    FROM scope_int u
    JOIN with_logs w ON w.msno = u.msno
    CROSS JOIN weeks wk
    LEFT JOIN log_week lw ON lw.msno = u.msno AND lw.week_no = wk.week_no
),
agg AS (
    SELECT lp_is_auto_renew, is_churn, week_no,
           count(*)                                                         AS users,
           100.0 * count(*) FILTER (WHERE active_days > 0) / count(*)       AS active_pct,
           avg(secs) / 3600                                                 AS hours_avg,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY secs) / 3600         AS hours_median
    FROM user_week
    GROUP BY lp_is_auto_renew, is_churn, week_no
),
no_logs AS (
    SELECT u.lp_is_auto_renew, u.is_churn,
           count(*)                                                         AS users_in_scope,
           100.0 * count(*) FILTER (WHERE w.msno IS NULL) / count(*)        AS no_logs_pct
    FROM scope_int u
    LEFT JOIN with_logs w ON w.msno = u.msno
    GROUP BY u.lp_is_auto_renew, u.is_churn
),
named AS (
    SELECT a.*,
           CASE a.lp_is_auto_renew WHEN 1 THEN 'автопродление да' ELSE 'автопродление нет' END AS pay
    FROM agg a
)
SELECT '5 прослушивание до точки решения',
       a.pay || ': ' || CASE a.is_churn WHEN 1 THEN 'ушли' ELSE 'остались' END,
       -a.week_no, 'неделя -' || a.week_no, v.metric, v.value, a.users
FROM named a
CROSS JOIN LATERAL (VALUES
    ('часов в неделю, медиана',           round(a.hours_median::numeric, 2)),
    ('часов в неделю, среднее',           round(a.hours_avg::numeric, 2)),
    ('слушали хотя бы день, %',           round(a.active_pct, 1))
) AS v(metric, value)
WHERE a.users >= 100
UNION ALL
SELECT '5 прослушивание до точки решения',
       ch.pay || ': ушли ÷ остались',
       -ch.week_no, 'неделя -' || ch.week_no,
       'медиана часов ушедших, % от оставшихся',
       round((100 * ch.hours_median / NULLIF(st.hours_median, 0))::numeric, 1),
       least(ch.users, st.users)
FROM named ch
JOIN named st ON st.lp_is_auto_renew = ch.lp_is_auto_renew AND st.week_no = ch.week_no AND st.is_churn = 0
WHERE ch.is_churn = 1
  AND least(ch.users, st.users) >= 100
UNION ALL
SELECT '5 прослушивание до точки решения',
       CASE nl.lp_is_auto_renew WHEN 1 THEN 'автопродление да' ELSE 'автопродление нет' END
       || ': ' || CASE nl.is_churn WHEN 1 THEN 'ушли' ELSE 'остались' END,
       0, 'вся группа', 'без прослушивания за 63 дня, % группы (в часы не входят)',
       round(nl.no_logs_pct, 1), nl.users_in_scope
FROM no_logs nl
WHERE nl.users_in_scope >= 100;

-- 6. Продления месячного плана по опозданию оплаты: сколько их, доля от способа оплаты,
--    от какой даты считается новый период (от даты оплаты, подходят оба правила, ни одно) и среднее опоздание в днях
INSERT INTO marts.retention_dashboard
WITH ordered AS (
    SELECT t.msno,
           t.transaction_date,
           t.membership_expire_date,
           t.payment_plan_days,
           t.actual_amount_paid,
           t.is_auto_renew,
           t.is_cancel,
           lag(t.membership_expire_date) OVER w                            AS prev_expire,
           lag(t.is_cancel)              OVER w                            AS prev_is_cancel
    FROM staging.transactions t
    WINDOW w AS (PARTITION BY t.msno
                 ORDER BY t.transaction_date, t.is_cancel, t.membership_expire_date,
                          t.payment_plan_days, t.actual_amount_paid,
                          t.is_auto_renew, t.payment_method_id)
),
classified AS (
    SELECT CASE WHEN o.transaction_date - o.prev_expire <= 0  THEN 0
                WHEN o.transaction_date - o.prev_expire <= 2  THEN 1
                WHEN o.transaction_date - o.prev_expire <= 7  THEN 2
                WHEN o.transaction_date - o.prev_expire <= 29 THEN 3
                ELSE                                               4
           END                                                             AS lateness,
           CASE WHEN o.is_auto_renew = 1 THEN 'автопродление' ELSE 'ручная оплата' END AS pay_kind,
           greatest(o.transaction_date - o.prev_expire, 0)                 AS days_late,
           abs((o.membership_expire_date - o.prev_expire) - o.payment_plan_days) <= 1       AS is_from_prev,
           abs((o.membership_expire_date - o.transaction_date) - o.payment_plan_days) <= 1  AS is_from_payment
    FROM ordered o
    WHERE o.is_cancel = 0
      AND o.prev_is_cancel = 0
      AND o.actual_amount_paid > 0
      AND o.payment_plan_days BETWEEN 30 AND 31
),
agg AS (
    SELECT pay_kind, lateness,
           count(*)                                                        AS renewals,
           100.0 * count(*) FILTER (WHERE is_from_payment AND NOT is_from_prev) / count(*) AS from_payment_pct,
           100.0 * count(*) FILTER (WHERE is_from_payment AND is_from_prev) / count(*)     AS both_fit_pct,
           100.0 * count(*) FILTER (WHERE NOT is_from_payment AND NOT is_from_prev) / count(*) AS neither_pct,
           avg(days_late)                                                  AS days_late_avg
    FROM classified
    GROUP BY pay_kind, lateness
),
shares AS (
    SELECT agg.*,
           100.0 * renewals / sum(renewals) OVER (PARTITION BY pay_kind)   AS kind_share_pct
    FROM agg
)
SELECT '6 опоздание с оплатой месячного плана',
       a.pay_kind,
       a.lateness,
       CASE a.lateness WHEN 0 THEN 'вовремя или заранее'
                       WHEN 1 THEN 'позже на 1-2 дня (правила не различить)'
                       WHEN 2 THEN 'позже на 3-7 дней'
                       WHEN 3 THEN 'позже на 8-29 дней'
                       ELSE        'позже на 30+ дней (уход и возврат, новый эпизод)' END,
       v.metric, v.value, a.renewals
FROM shares a
CROSS JOIN LATERAL (VALUES
    ('продлений',                                      a.renewals::numeric),
    ('доля от продлений способа оплаты, %',            round(a.kind_share_pct, 2)),
    ('новый период от даты оплаты, %',                 round(a.from_payment_pct, 2)),
    ('подходят оба правила, %',                        round(a.both_fit_pct, 2)),
    ('не подходит ни одно правило, %',                 round(a.neither_pct, 2)),
    ('опоздание, дней в среднем',                      round(a.days_late_avg, 1))
) AS v(metric, value)
WHERE a.renewals >= 100;

-- 7. Retention новых клиентов: первый эпизод против повторного (Каплан-Мейер по дням от первой платной оплаты),
--    до 21-го месяца, пока под риском на конец месяца не меньше 1 000
INSERT INTO marts.retention_dashboard
WITH ep AS (
    SELECT g.grp, s.paid_duration_days AS dur, s.event
    FROM marts.survival_episodes s
    JOIN staging.subscription_episodes e
      ON e.msno = s.msno AND e.episode_no = s.episode_no
    CROSS JOIN LATERAL (VALUES
        (CASE WHEN s.sample_reason = 'new_client' THEN 'первый эпизод' END),
        (CASE WHEN s.sample_reason = 'repeat'
                   AND e.registration_date BETWEEN DATE '2015-01-01' AND e.first_tx_date
              THEN 'повторный эпизод (вернулись после ухода)' END)
    ) AS g(grp)
    WHERE s.is_paid
      AND g.grp IS NOT NULL
),
by_day AS (
    SELECT grp, dur, count(*) AS n_end, sum(event) AS d
    FROM ep
    GROUP BY grp, dur
),
km AS (
    SELECT grp, dur,
           exp(sum(ln(greatest(1 - d::numeric / n_risk, 1e-12))) OVER w)  AS s
    FROM (
        SELECT grp, dur, d,
               sum(n_end) OVER (PARTITION BY grp ORDER BY dur DESC ROWS UNBOUNDED PRECEDING) AS n_risk
        FROM by_day
    ) AS risk
    WINDOW w AS (PARTITION BY grp ORDER BY dur ROWS UNBOUNDED PRECEDING)
),
curve AS (
    SELECT g.grp, k.month_no,
           (SELECT coalesce(sum(b.n_end), 0) FROM by_day b
             WHERE b.grp = g.grp AND b.dur >= 30 * (k.month_no - 1))            AS n_risk_start,
           (SELECT coalesce(sum(b.n_end), 0) FROM by_day b
             WHERE b.grp = g.grp AND b.dur >= 30 * k.month_no - 1)              AS n_risk_end,
           coalesce((SELECT km.s FROM km
                      WHERE km.grp = g.grp AND km.dur <= 30 * k.month_no - 1
                      ORDER BY km.dur DESC LIMIT 1), 1)                          AS s
    FROM (SELECT DISTINCT grp FROM by_day) AS g
    CROSS JOIN generate_series(1, 21) AS k(month_no)
)
SELECT '7 retention новых клиентов: первый и повторный эпизод',
       c.grp, c.month_no, 'мес. ' || c.month_no, 'retention, %', round(100 * c.s, 2), c.n_risk_start
FROM curve c
WHERE c.n_risk_end >= 1000;

-- контроль: потери по сегментам сходятся с 02_baseline_metrics, в каждом графике есть строки,
-- квинтили серии «все» покрывают всех месячных платных с логами
DO $$
DECLARE
    lost      numeric;
    n_charts  int;
BEGIN
    SELECT sum(value) INTO lost
    FROM marts.retention_dashboard
    WHERE chart = '2 потери по сегментам' AND metric = 'потери в месяц, NTD';
    SELECT count(DISTINCT chart) INTO n_charts FROM marts.retention_dashboard;
    IF abs(lost - 8383575) > 3 OR n_charts <> 7 THEN
        RAISE EXCEPTION 'marts.retention_dashboard: потери %, графиков % (ожидалось 8383575 ± 3 и 7)', lost, n_charts;
    END IF;
END $$;

COMMIT;

ANALYZE marts.retention_dashboard;
