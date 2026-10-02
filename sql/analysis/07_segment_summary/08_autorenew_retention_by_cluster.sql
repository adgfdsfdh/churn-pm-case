-- ============================================================================
-- 08_autorenew_retention_by_cluster.sql — retention платных эпизодов с первым месячным планом
-- по автопродлению при первой платной оплате, отдельно внутри и вне кластера
-- «канал 7 / способ оплаты 41» (Каплан-Мейер по дням от первой платной оплаты).
-- ============================================================================

WITH first_paid AS (
    -- первая платная оплата эпизода; несколько оплат в этот день — «да», если хоть в одной
    SELECT s.msno, s.episode_no,
           bool_or(t.is_auto_renew = 1)                              AS autorenew_at_start,
           bool_or(t.payment_method_id = 41)                         AS method_41_at_start
    FROM marts.survival_episodes s
    JOIN staging.transactions t
      ON t.msno = s.msno
     AND t.transaction_date = s.first_paid_date
     AND t.is_cancel = 0
     AND t.actual_amount_paid > 0
    WHERE s.is_paid
      AND s.first_paid_plan BETWEEN 30 AND 31
    GROUP BY s.msno, s.episode_no
),
ep_base AS (
    SELECT CASE WHEN f.autorenew_at_start THEN 'да' ELSE 'нет' END  AS autorenew,
           CASE WHEN m.msno IS NULL          THEN 'нет профиля'
                WHEN m.registered_via = 7    THEN 'канал 7'
                ELSE                              'другой канал' END AS channel_grp,
           CASE WHEN f.method_41_at_start THEN 'способ 41' ELSE 'другой способ' END AS method_grp,
           s.paid_duration_days                                      AS dur,
           s.event
    FROM marts.survival_episodes s
    JOIN first_paid f ON f.msno = s.msno AND f.episode_no = s.episode_no
    LEFT JOIN staging.members m ON m.msno = s.msno
),
ep AS (
    -- каждый эпизод попадает в три слоя: все / по каналу / канал × способ оплаты
    SELECT l.stratum, e.autorenew, e.dur, e.event
    FROM ep_base e
    CROSS JOIN LATERAL (VALUES
        ('0) все'),
        ('1) ' || e.channel_grp),
        ('2) ' || e.channel_grp || ' × ' || e.method_grp)
    ) AS l(stratum)
),
by_day AS (
    SELECT stratum, autorenew, dur, count(*) AS n_end, sum(event) AS d
    FROM ep
    GROUP BY stratum, autorenew, dur
),
km AS (
    SELECT stratum, autorenew, dur,
           exp(sum(ln(greatest(1 - d::numeric / n_risk, 1e-12))) OVER w) AS s
    FROM (
        SELECT stratum, autorenew, dur, d,
               sum(n_end) OVER (PARTITION BY stratum, autorenew
                                ORDER BY dur DESC ROWS UNBOUNDED PRECEDING) AS n_risk
        FROM by_day
    ) AS risk
    WINDOW w AS (PARTITION BY stratum, autorenew ORDER BY dur ROWS UNBOUNDED PRECEDING)
),
totals AS (
    SELECT stratum, autorenew, sum(n_end) AS episodes
    FROM by_day
    GROUP BY stratum, autorenew
),
points AS (
    -- retention к месяцу k = S(30k − 1); пусто, если к концу месяца под риском никого
    SELECT t.stratum, t.autorenew, t.episodes, p.month_no,
           coalesce((SELECT sum(b.n_end) FROM by_day b
                      WHERE b.stratum = t.stratum AND b.autorenew = t.autorenew
                        AND b.dur >= 30 * p.month_no - 1), 0)                  AS n_risk_at_end,
           coalesce((SELECT k.s FROM km k
                      WHERE k.stratum = t.stratum AND k.autorenew = t.autorenew
                        AND k.dur <= 30 * p.month_no - 1
                      ORDER BY k.dur DESC LIMIT 1), 1)                          AS s
    FROM totals t
    CROSS JOIN (VALUES (1), (2), (3), (6), (12)) AS p(month_no)
)
SELECT stratum,
       autorenew                                                                AS autorenew_at_start,
       episodes,
       round(100.0 * episodes / sum(episodes) OVER (PARTITION BY stratum), 1)   AS share_in_stratum_pct,
       max(round(100 * s, 1)) FILTER (WHERE month_no = 1  AND n_risk_at_end > 0) AS retained_m1_pct,
       max(round(100 * s, 1)) FILTER (WHERE month_no = 2  AND n_risk_at_end > 0) AS retained_m2_pct,
       max(round(100 * s, 1)) FILTER (WHERE month_no = 3  AND n_risk_at_end > 0) AS retained_m3_pct,
       max(round(100 * s, 1)) FILTER (WHERE month_no = 6  AND n_risk_at_end > 0) AS retained_m6_pct,
       max(round(100 * s, 1)) FILTER (WHERE month_no = 12 AND n_risk_at_end > 0) AS retained_m12_pct,
       max(n_risk_at_end) FILTER (WHERE month_no = 12)                          AS n_risk_m12,
       CASE WHEN episodes < 1000 THEN 'меньше 1 000 эпизодов — вывод шаткий' END AS small_flag
FROM points
GROUP BY stratum, autorenew, episodes
ORDER BY stratum, autorenew;
