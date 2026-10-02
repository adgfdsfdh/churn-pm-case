-- ============================================================================
-- 02_ltv.sql — первая оценка срока жизни и LTV эпизода (все эпизоды, месячный шаг, предварительная кривая); заменена 08_ltv.sql и 09_ltv_returning_clients.sql.
-- ============================================================================

WITH ep AS (
    SELECT e.msno,
           e.episode_no,
           div(greatest(CASE WHEN e.status = 'censored'
                             THEN least(e.end_date, DATE '2017-03-02')
                             ELSE e.end_date
                        END - e.start_date, 0), 30)                      AS t,
           (e.status = 'churned')::int                                   AS event,
           e.paid_total,
           e.plan_days_total,
           e.registration_date BETWEEN DATE '2015-01-01' AND e.first_tx_date AS client_start_visible
    FROM staging.subscription_episodes e
    WHERE e.n_payments > 0
      AND (e.episode_no > 1
           OR e.registration_date BETWEEN DATE '2015-01-01' AND e.first_tx_date)
),
clean AS (
    SELECT g.grp, ep.t, ep.event, ep.paid_total, ep.plan_days_total
    FROM ep
    CROSS JOIN LATERAL (VALUES
        ('1) все',                               true),
        ('2) первые',                            ep.episode_no = 1),
        ('3) повторные',                         ep.episode_no > 1),
        ('4) повторные, начало клиента видно',   ep.episode_no > 1 AND coalesce(ep.client_start_visible, false))
    ) AS g(grp, keep)
    WHERE g.keep
),
by_month AS (
    SELECT grp, t, count(*) AS n_end, sum(event) AS d
    FROM clean
    GROUP BY grp, t
),
full_months AS (
    SELECT g.grp, m.t, coalesce(b.n_end, 0) AS n_end, coalesce(b.d, 0) AS d
    FROM (SELECT grp, max(t) AS max_t FROM clean GROUP BY grp) AS g
    CROSS JOIN LATERAL generate_series(0, g.max_t) AS m(t)
    LEFT JOIN by_month b ON b.grp = g.grp AND b.t = m.t
),
risk AS (
    SELECT grp, t, d,
           sum(n_end) OVER (PARTITION BY grp ORDER BY t DESC ROWS UNBOUNDED PRECEDING) AS n_risk
    FROM full_months
),
surv AS (
    SELECT grp, t, d, n_risk,
           exp(sum(ln(greatest(1 - d::numeric / n_risk, 1e-12))) OVER w)  AS s,
           sum(d::numeric / (n_risk * greatest(n_risk - d, 1)))   OVER w  AS greenwood
    FROM risk
    WHERE n_risk >= 1000
    WINDOW w AS (PARTITION BY grp ORDER BY t ROWS UNBOUNDED PRECEDING)
),
curve AS (
    SELECT grp,
           max(t)                                   AS last_t,
           sum(s)                                   AS life_obs,
           max(s)         FILTER (WHERE t = 11)     AS s12,
           max(greenwood) FILTER (WHERE t = 11)     AS gw12,
           max(s)         FILTER (WHERE t = 23)     AS s24,
           max(greenwood) FILTER (WHERE t = 23)     AS gw24,
           min(t)         FILTER (WHERE s <= 0.5)   AS median_t
    FROM surv
    GROUP BY grp
),
curve_end AS (
    SELECT s.grp,
           max(s.s) FILTER (WHERE s.t = c.last_t)                        AS s_last,
           sum(s.d) FILTER (WHERE s.t > c.last_t - 6)::numeric
             / sum(s.n_risk) FILTER (WHERE s.t > c.last_t - 6)          AS h_tail
    FROM surv s
    JOIN curve c ON c.grp = s.grp
    GROUP BY s.grp
),
horizons AS (
    -- ожидаемые оплаченные месяцы в пределах горизонта H при оттоке хвоста h
    SELECT c.grp, v.name,
           (SELECT sum(s2.s) FROM surv s2 WHERE s2.grp = c.grp AND s2.t < v.horizon)
           + CASE WHEN v.horizon - 1 <= c.last_t THEN 0
                  WHEN v.h > 0 THEN ce.s_last * (1 - v.h)
                                    * (1 - power(1 - v.h, v.horizon - 1 - c.last_t)) / v.h
                  ELSE ce.s_last * (v.horizon - 1 - c.last_t)
             END                                                        AS life
    FROM curve c
    JOIN curve_end ce ON ce.grp = c.grp
    CROSS JOIN LATERAL (VALUES ('36',      36, ce.h_tail),
                               ('60',      60, ce.h_tail),
                               ('60_h1',   60, 0.01),
                               ('60_h25',  60, 0.025)) AS v(name, horizon, h)
),
totals AS (
    SELECT grp,
           count(*)                                        AS episodes,
           sum(event)                                      AS churned,
           sum(t)::numeric / NULLIF(sum(event), 0)         AS life_a,
           sum(paid_total) * 30.0 / sum(plan_days_total)   AS arpu30
    FROM clean
    GROUP BY grp
),
returns AS (
    SELECT g.grp,
           count(next_ep.msno)::numeric / count(*)         AS p_return
    FROM staging.subscription_episodes e
    LEFT JOIN staging.subscription_episodes next_ep
           ON next_ep.msno = e.msno
          AND next_ep.episode_no = e.episode_no + 1
          AND next_ep.start_date <= e.end_date + 365
    CROSS JOIN LATERAL (VALUES
        ('2) первые',                            e.episode_no = 1),
        ('3) повторные',                         e.episode_no > 1),
        ('4) повторные, начало клиента видно',   e.episode_no > 1
                                                 AND coalesce(e.registration_date BETWEEN DATE '2015-01-01'
                                                                                     AND e.first_tx_date, false))
    ) AS g(grp, keep)
    WHERE g.keep
      AND e.status = 'churned'
      AND e.end_date <= DATE '2016-03-31'
      AND e.n_payments > 0
      AND (e.episode_no > 1
           OR e.registration_date BETWEEN DATE '2015-01-01' AND e.first_tx_date)
    GROUP BY g.grp
),
res AS (
    SELECT t.grp, t.episodes, t.churned, t.arpu30, t.life_a,
           c.last_t, c.life_obs, c.s12, c.gw12, c.s24, c.gw24, c.median_t,
           ce.s_last, ce.h_tail, r.p_return,
           max(h.life) FILTER (WHERE h.name = '36')        AS life_36,
           max(h.life) FILTER (WHERE h.name = '60')        AS life_60,
           max(h.life) FILTER (WHERE h.name = '60_h1')     AS life_60_h1,
           max(h.life) FILTER (WHERE h.name = '60_h25')    AS life_60_h25,
           c.life_obs + ce.s_last * (1 - ce.h_tail) / NULLIF(ce.h_tail, 0) AS life_full,
           CASE WHEN c.last_t >= 59 THEN (SELECT s FROM surv s3 WHERE s3.grp = t.grp AND s3.t = 59)
                ELSE ce.s_last * power(1 - ce.h_tail, 59 - c.last_t)
           END                                             AS s59
    FROM totals t
    JOIN curve c      ON c.grp  = t.grp
    JOIN curve_end ce ON ce.grp = t.grp
    JOIN horizons h   ON h.grp  = t.grp
    LEFT JOIN returns r ON r.grp = t.grp
    GROUP BY t.grp, t.episodes, t.churned, t.arpu30, t.life_a,
             c.last_t, c.life_obs, c.s12, c.gw12, c.s24, c.gw24, c.median_t,
             ce.s_last, ce.h_tail, r.p_return
),
client AS (
    SELECT f.life_60 * f.arpu30                                           AS ltv_first,
           (1 - f.s59) * f.p_return                                       AS p_first,
           (1 - v.s59) * v.p_return                                       AS p_repeat,
           v.life_60 * v.arpu30                                           AS ltv_repeat
    FROM res f
    CROSS JOIN res v
    WHERE f.grp = '2) первые'
      AND v.grp = '4) повторные, начало клиента видно'
),
long_rows AS (
    SELECT r.grp, v.metric, v.value
    FROM res r
    LEFT JOIN client cl ON true
    CROSS JOIN LATERAL (VALUES
        ('01 эпизодов',                                   round(r.episodes::numeric)),
        ('02 из них ушли',                                round(r.churned::numeric)),
        ('03 ARPU за 30 дней, NTD',                       round(r.arpu30, 1)),
        ('04 длина надёжной части кривой, мес.',          round((r.last_t + 1)::numeric)),
        ('05 дожили до 12 мес., %',                       round(100 * r.s12, 1)),
        ('06   ± 95% (Гринвуд), п.п.',                    round(100 * 1.96 * r.s12 * sqrt(r.gw12), 2)),
        ('07 дожили до 24 мес., %',                       round(100 * r.s24, 1)),
        ('08   ± 95% (Гринвуд), п.п.',                    round(100 * 1.96 * r.s24 * sqrt(r.gw24), 2)),
        ('09 медиана срока, мес.',                        r.median_t::numeric),
        ('10 отток в мес., 1-й год, %',                   round(100 * (1 - power(r.s12, 1.0 / 12)), 2)),
        ('11 отток в мес., 2-й год, %',                   round(100 * (1 - power(r.s24 / r.s12, 1.0 / 12)), 2)),
        ('12 отток в мес., последние 6 мес. кривой, %',   round(100 * r.h_tail, 2)),
        ('13 А полный: срок, мес.',                       round(r.life_a, 1)),
        ('14 А в пределах кривой: срок, мес.',            round(r.life_a * (1 - power(1 - 1 / r.life_a, r.last_t + 1)), 1)),
        ('15 Б в пределах кривой: срок, мес.',            round(r.life_obs, 1)),
        ('16 LTV А полный, NTD',                          round(r.life_a * r.arpu30)),
        ('17 LTV А в пределах кривой, NTD',               round(r.life_a * (1 - power(1 - 1 / r.life_a, r.last_t + 1)) * r.arpu30)),
        ('18 LTV Б в пределах кривой, NTD',               round(r.life_obs * r.arpu30)),
        ('19 LTV Б за 36 мес., NTD',                      round(r.life_36 * r.arpu30)),
        ('20 LTV Б за 60 мес., NTD',                      round(r.life_60 * r.arpu30)),
        ('21   за 60 мес., если хвост 1%/мес., NTD',      round(r.life_60_h1 * r.arpu30)),
        ('22   за 60 мес., если хвост 2,5%/мес., NTD',    round(r.life_60_h25 * r.arpu30)),
        ('23 LTV Б без ограничения срока, NTD',           round(r.life_full * r.arpu30)),
        ('24 доживут до 60 мес. (с продлением), %',       round(100 * r.s59, 1)),
        ('25 вернулись в течение года после ухода, %',    round(100 * r.p_return, 1)),
        ('26 LTV клиента: первый эпизод + возвраты, NTD', CASE WHEN r.grp = '2) первые' THEN
             round(cl.ltv_first + cl.p_first * cl.ltv_repeat / (1 - cl.p_repeat)) END),
        ('27   из них за счёт возвратов, %',              CASE WHEN r.grp = '2) первые' THEN
             round(100 * (cl.p_first * cl.ltv_repeat / (1 - cl.p_repeat))
                   / (cl.ltv_first + cl.p_first * cl.ltv_repeat / (1 - cl.p_repeat)), 1) END)
    ) AS v(metric, value)
)
SELECT metric,
       max(value) FILTER (WHERE grp = '1) все')                             AS "все эпизоды",
       max(value) FILTER (WHERE grp = '2) первые')                          AS "первые",
       max(value) FILTER (WHERE grp = '3) повторные')                       AS "повторные",
       max(value) FILTER (WHERE grp = '4) повторные, начало клиента видно') AS "повторные у новых"
FROM long_rows
GROUP BY metric
ORDER BY metric;
