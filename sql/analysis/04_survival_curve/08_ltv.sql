-- ============================================================================
-- 08_ltv.sql — LTV платного эпизода: среднее время жизни в пределах горизонта (RMST) по кривой Каплана-Мейера по дням от первой платной оплаты × ARPU за 30 дней; горизонты 12 / 24 / 36 / 60 мес., после 21-го месяца — экстраполяция хвоста с чувствительностью 1% и 3% в месяц.
-- ============================================================================

WITH params AS (
    SELECT 629 AS last_obs_day,       -- последний день 21-го месяца: дальше кривая не интерпретируется
           239 AS plateau_from_day,   -- последний день 8-го месяца
           599 AS plateau_to_day      -- последний день 20-го месяца: плато = месяцы 9–20
),
ep AS (
    SELECT g.grp,
           s.paid_duration_days                                        AS dur,
           s.event,
           s.paid_total,
           s.plan_days_total,
           CASE WHEN s.starts_free THEN s.first_paid_date - s.start_date
                ELSE 0 END                                             AS days_before_paid
    FROM marts.survival_episodes s
    CROSS JOIN LATERAL (VALUES
        ('1) платные, все'),
        (CASE WHEN s.first_paid_plan BETWEEN 30 AND 31 THEN '2) первый платный план месячный' END),
        (CASE WHEN s.sample_reason <> 'repeat'          THEN '3) первый эпизод клиента' END),
        (CASE WHEN s.sample_reason = 'repeat'           THEN '4) повторный эпизод' END)
    ) AS g(grp)
    WHERE s.is_paid
      AND g.grp IS NOT NULL
),
totals AS (
    SELECT grp,
           count(*)                                                              AS episodes,
           sum(event)                                                            AS churned,
           sum(paid_total) * 30.0 / NULLIF(sum(plan_days_total), 0)              AS arpu30,
           sum(paid_total) * 30.0 / NULLIF(sum(plan_days_total - days_before_paid), 0) AS arpu30_high,
           avg(paid_total)                                                       AS paid_avg,
           max(dur)                                                              AS max_dur
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
    CROSS JOIN LATERAL generate_series(0, greatest(t.max_dur, p.last_obs_day)) AS g(day)
    LEFT JOIN by_day b ON b.grp = t.grp AND b.dur = g.day
),
km AS (
    SELECT grp, day, n_risk,
           exp(sum(ln(greatest(1 - coalesce(d::numeric / NULLIF(n_risk, 0), 0), 1e-12)))
               OVER (PARTITION BY grp ORDER BY day ROWS UNBOUNDED PRECEDING))    AS s
    FROM (
        SELECT grp, day, d,
               sum(n_end) OVER (PARTITION BY grp ORDER BY day DESC ROWS UNBOUNDED PRECEDING) AS n_risk
        FROM day_grid
    ) AS risk
),
anchor AS (
    SELECT k.grp,
           max(k.s)      FILTER (WHERE k.day = 359)                AS s12,
           max(k.s)      FILTER (WHERE k.day = 719)                AS s24,
           max(k.s)      FILTER (WHERE k.day = p.last_obs_day)     AS s_last,
           max(k.n_risk) FILTER (WHERE k.day = p.last_obs_day)     AS n_risk_last,
           1 - power(max(k.s) FILTER (WHERE k.day = p.plateau_to_day)
                     / max(k.s) FILTER (WHERE k.day = p.plateau_from_day), 1.0 / 12) AS h_plateau
    FROM km k
    CROSS JOIN params p
    GROUP BY k.grp
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
           CASE WHEN g.day <= p.last_obs_day THEN k.s
                ELSE a.s_last * power(1 - tl.h, (g.day - p.last_obs_day) / 30.0)
           END                                                    AS s
    FROM tails tl
    JOIN anchor a ON a.grp = tl.grp
    CROSS JOIN params p
    CROSS JOIN generate_series(0, 60 * 30 - 1) AS g(day)
    LEFT JOIN km k ON k.grp = tl.grp AND k.day = g.day
),
life AS (
    SELECT c.grp, c.tail, h.months,
           sum(c.s) FILTER (WHERE c.day < 30 * h.months) / 30     AS life_months
    FROM curve c
    CROSS JOIN (VALUES (12), (24), (36), (60)) AS h(months)
    GROUP BY c.grp, c.tail, h.months
),
res AS (
    SELECT t.grp, t.episodes, t.churned, t.arpu30, t.arpu30_high, t.paid_avg,
           a.s12, a.s24, a.n_risk_last, a.h_plateau,
           max(l.life_months) FILTER (WHERE l.tail = 'plateau' AND l.months = 12) AS life12,
           max(l.life_months) FILTER (WHERE l.tail = 'plateau' AND l.months = 24) AS life24,
           max(l.life_months) FILTER (WHERE l.tail = 'plateau' AND l.months = 36) AS life36,
           max(l.life_months) FILTER (WHERE l.tail = 'plateau' AND l.months = 60) AS life60,
           max(l.life_months) FILTER (WHERE l.tail = '1%'      AND l.months = 36) AS life36_h1,
           max(l.life_months) FILTER (WHERE l.tail = '3%'      AND l.months = 36) AS life36_h3,
           max(l.life_months) FILTER (WHERE l.tail = '1%'      AND l.months = 60) AS life60_h1,
           max(l.life_months) FILTER (WHERE l.tail = '3%'      AND l.months = 60) AS life60_h3
    FROM totals t
    JOIN anchor a ON a.grp = t.grp
    JOIN life l   ON l.grp = t.grp
    GROUP BY t.grp, t.episodes, t.churned, t.arpu30, t.arpu30_high, t.paid_avg,
             a.s12, a.s24, a.n_risk_last, a.h_plateau
),
long_rows AS (
    SELECT r.grp, v.metric, v.value
    FROM res r
    CROSS JOIN LATERAL (VALUES
        ('01 эпизодов',                                          round(r.episodes::numeric)),
        ('02 из них ушли',                                       round(r.churned::numeric)),
        ('03 ARPU за 30 дней, NTD',                              round(r.arpu30, 1)),
        ('04 ARPU за 30 дней без дней до первой оплаты, NTD',    round(r.arpu30_high, 1)),
        ('05 реально заплачено за эпизод, среднее, NTD',         round(r.paid_avg)),
        ('06 retention к 12 мес., %',                            round(100 * r.s12, 1)),
        ('07 retention к 24 мес., %',                            round(100 * r.s24, 1)),
        ('08 под риском на конце 21-го мес.',                    round(r.n_risk_last::numeric)),
        ('09 отток в мес. на плато (мес. 9–20), %',              round(100 * r.h_plateau, 2)),
        ('10 срок жизни в пределах 12 мес., мес.',               round(r.life12, 2)),
        ('11 срок жизни в пределах 24 мес., мес.',               round(r.life24, 2)),
        ('12 срок жизни в пределах 36 мес., мес.',               round(r.life36, 2)),
        ('13 срок жизни в пределах 60 мес., мес.',               round(r.life60, 2)),
        ('14 LTV за 12 мес., NTD',                               round(r.life12 * r.arpu30)),
        ('15 LTV за 24 мес., NTD',                               round(r.life24 * r.arpu30)),
        ('16 LTV за 36 мес., NTD',                               round(r.life36 * r.arpu30)),
        ('17 LTV за 60 мес., NTD',                               round(r.life60 * r.arpu30)),
        ('18   за 36 мес., если хвост 1% в мес., NTD',           round(r.life36_h1 * r.arpu30)),
        ('19   за 36 мес., если хвост 3% в мес., NTD',           round(r.life36_h3 * r.arpu30)),
        ('20   за 60 мес., если хвост 1% в мес., NTD',           round(r.life60_h1 * r.arpu30)),
        ('21   за 60 мес., если хвост 3% в мес., NTD',           round(r.life60_h3 * r.arpu30))
    ) AS v(metric, value)
)
SELECT metric,
       max(value) FILTER (WHERE grp = '1) платные, все')                  AS "платные, все",
       max(value) FILTER (WHERE grp = '2) первый платный план месячный')  AS "первый план месячный",
       max(value) FILTER (WHERE grp = '3) первый эпизод клиента')         AS "первый эпизод",
       max(value) FILTER (WHERE grp = '4) повторный эпизод')              AS "повторный эпизод"
FROM long_rows
GROUP BY metric
ORDER BY metric;
