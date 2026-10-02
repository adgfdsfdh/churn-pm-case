-- ============================================================================
-- 09_ltv_returning_clients.sql — LTV платного эпизода новых клиентов: первый эпизод против повторного (возврат после ухода); повторные эпизоды давних клиентов и без профиля — отдельно. Кривая обрезается там, где под риском меньше 1 000 эпизодов.
-- ============================================================================

WITH params AS (
    SELECT 629  AS max_obs_day,       -- последний день 21-го месяца: дальше кривая не интерпретируется
           1000 AS min_risk,          -- кривую дальше не используем, если под риском меньше
           239  AS plateau_from_day   -- последний день 8-го месяца; плато — от 9-го месяца до месяца перед концом кривой
),
ep AS (
    SELECT g.grp,
           s.paid_duration_days                                        AS dur,
           s.event,
           s.paid_total,
           s.plan_days_total
    FROM marts.survival_episodes s
    JOIN staging.subscription_episodes e
      ON e.msno = s.msno AND e.episode_no = s.episode_no
    CROSS JOIN LATERAL (VALUES
        ('0) платные, все'),
        (CASE WHEN s.sample_reason = 'new_client' THEN '1) новые клиенты: первый эпизод' END),
        (CASE WHEN s.sample_reason = 'repeat'
                   AND e.registration_date BETWEEN DATE '2015-01-01' AND e.first_tx_date
              THEN '2) новые клиенты: повторный эпизод' END),
        (CASE WHEN s.sample_reason = 'repeat'
                   AND NOT coalesce(e.registration_date BETWEEN DATE '2015-01-01' AND e.first_tx_date, false)
              THEN '3) давние клиенты и без профиля: повторный эпизод' END)
    ) AS g(grp)
    WHERE s.is_paid
      AND g.grp IS NOT NULL
),
totals AS (
    SELECT grp,
           count(*)                                                    AS episodes,
           sum(event)                                                  AS churned,
           sum(paid_total) * 30.0 / NULLIF(sum(plan_days_total), 0)    AS arpu30,
           avg(paid_total)                                             AS paid_avg,
           max(dur)                                                    AS max_dur
    FROM ep
    GROUP BY grp
),
by_day AS (
    SELECT grp, dur, count(*) AS n_end, sum(event) AS d
    FROM ep
    GROUP BY grp, dur
),
day_grid AS (
    SELECT t.grp, g.day, coalesce(b.n_end, 0) AS n_end, coalesce(b.d, 0) AS d
    FROM totals t
    CROSS JOIN params p
    CROSS JOIN LATERAL generate_series(0, greatest(t.max_dur, p.max_obs_day)) AS g(day)
    LEFT JOIN by_day b ON b.grp = t.grp AND b.dur = g.day
),
km AS (
    SELECT grp, day, n_risk,
           exp(sum(ln(greatest(1 - coalesce(d::numeric / NULLIF(n_risk, 0), 0), 1e-12)))
               OVER (PARTITION BY grp ORDER BY day ROWS UNBOUNDED PRECEDING))  AS s
    FROM (
        SELECT grp, day, d,
               sum(n_end) OVER (PARTITION BY grp ORDER BY day DESC ROWS UNBOUNDED PRECEDING) AS n_risk
        FROM day_grid
    ) AS risk
),
obs AS (
    -- конец кривой: последний полный месяц, пока под риском не меньше min_risk, но не дальше 21-го месяца
    SELECT k.grp,
           (least(p.max_obs_day, max(k.day) FILTER (WHERE k.n_risk >= p.min_risk)) + 1) / 30 * 30 - 1 AS last_obs_day
    FROM km k
    CROSS JOIN params p
    GROUP BY k.grp, p.max_obs_day
),
anchor AS (
    SELECT k.grp,
           o.last_obs_day,
           max(k.s)      FILTER (WHERE k.day = 359)                   AS s12,
           max(k.s)      FILTER (WHERE k.day = o.last_obs_day)        AS s_last,
           max(k.n_risk) FILTER (WHERE k.day = o.last_obs_day)        AS n_risk_last,
           (o.last_obs_day - 30 - p.plateau_from_day) / 30            AS plateau_months,
           CASE WHEN o.last_obs_day - 30 > p.plateau_from_day
                THEN 1 - power(max(k.s) FILTER (WHERE k.day = o.last_obs_day - 30)
                               / max(k.s) FILTER (WHERE k.day = p.plateau_from_day),
                               30.0 / (o.last_obs_day - 30 - p.plateau_from_day))
           END                                                        AS h_plateau
    FROM km k
    JOIN obs o ON o.grp = k.grp
    CROSS JOIN params p
    GROUP BY k.grp, o.last_obs_day, p.plateau_from_day
),
tails AS (
    SELECT a.grp, v.tail, v.h
    FROM anchor a
    CROSS JOIN LATERAL (VALUES ('plateau', a.h_plateau),
                               ('1%',      0.01::numeric),
                               ('3%',      0.03::numeric)) AS v(tail, h)
),
curve AS (
    SELECT tl.grp, tl.tail, g.day,
           CASE WHEN g.day <= a.last_obs_day THEN k.s
                ELSE a.s_last * power(1 - tl.h, (g.day - a.last_obs_day) / 30.0)
           END                                                        AS s
    FROM tails tl
    JOIN anchor a ON a.grp = tl.grp
    CROSS JOIN generate_series(0, 60 * 30 - 1) AS g(day)
    LEFT JOIN km k ON k.grp = tl.grp AND k.day = g.day
),
life AS (
    SELECT c.grp, c.tail, h.months,
           sum(c.s) FILTER (WHERE c.day < 30 * h.months) / 30         AS life_months
    FROM curve c
    CROSS JOIN (VALUES (12), (24), (36), (60)) AS h(months)
    GROUP BY c.grp, c.tail, h.months
),
res AS (
    SELECT t.grp, t.episodes, t.churned, t.arpu30, t.paid_avg,
           a.last_obs_day, a.s12, a.n_risk_last, a.plateau_months, a.h_plateau,
           max(l.life_months) FILTER (WHERE l.tail = 'plateau' AND l.months = 12) AS life12,
           max(l.life_months) FILTER (WHERE l.tail = 'plateau' AND l.months = 24) AS life24,
           max(l.life_months) FILTER (WHERE l.tail = 'plateau' AND l.months = 36) AS life36,
           max(l.life_months) FILTER (WHERE l.tail = '1%'      AND l.months = 36) AS life36_h1,
           max(l.life_months) FILTER (WHERE l.tail = '3%'      AND l.months = 36) AS life36_h3
    FROM totals t
    JOIN anchor a ON a.grp = t.grp
    JOIN life l   ON l.grp = t.grp
    GROUP BY t.grp, t.episodes, t.churned, t.arpu30, t.paid_avg,
             a.last_obs_day, a.s12, a.n_risk_last, a.plateau_months, a.h_plateau
),
long_rows AS (
    SELECT r.grp, v.metric, v.value
    FROM res r
    CROSS JOIN LATERAL (VALUES
        ('01 эпизодов',                                          round(r.episodes::numeric)),
        ('02 из них ушли',                                       round(r.churned::numeric)),
        ('03 ARPU за 30 дней, NTD',                              round(r.arpu30, 1)),
        ('04 реально заплачено за эпизод, среднее, NTD',         round(r.paid_avg)),
        ('05 retention к 12 мес., %',                            round(100 * r.s12, 1)),
        ('06 конец кривой, месяц',                               round((r.last_obs_day + 1) / 30.0)),
        ('07 под риском на конце кривой',                        round(r.n_risk_last::numeric)),
        ('08 месяцев плато (с 9-го)',                            round(r.plateau_months::numeric)),
        ('09 отток в мес. на плато, %',                          round(100 * r.h_plateau, 2)),
        ('10 срок жизни в пределах 12 мес., мес.',               round(r.life12, 2)),
        ('11 срок жизни в пределах 24 мес., мес.',               round(r.life24, 2)),
        ('12 срок жизни в пределах 36 мес., мес.',               round(r.life36, 2)),
        ('13 LTV за 12 мес., NTD',                               round(r.life12 * r.arpu30)),
        ('14 LTV за 24 мес., NTD',                               round(r.life24 * r.arpu30)),
        ('15 LTV за 36 мес., NTD',                               round(r.life36 * r.arpu30)),
        ('16   за 36 мес., если хвост 1% в мес., NTD',           round(r.life36_h1 * r.arpu30)),
        ('17   за 36 мес., если хвост 3% в мес., NTD',           round(r.life36_h3 * r.arpu30))
    ) AS v(metric, value)
)
SELECT metric,
       max(value) FILTER (WHERE grp = '0) платные, все')                   AS "платные, все",
       max(value) FILTER (WHERE grp = '1) новые клиенты: первый эпизод')                  AS "новые: первый",
       max(value) FILTER (WHERE grp = '2) новые клиенты: повторный эпизод')               AS "новые: повторный",
       max(value) FILTER (WHERE grp = '3) давние клиенты и без профиля: повторный эпизод') AS "давние: повторный"
FROM long_rows
GROUP BY metric
ORDER BY metric;
