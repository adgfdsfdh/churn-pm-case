-- ============================================================================
-- 02_autorenew_retention.sql — retention платных эпизодов с первым месячным планом по автопродлению
-- при первой платной оплате (Каплан-Мейер по дням, отсчёт от первой платной оплаты).
-- ============================================================================

WITH first_paid AS (
    -- автопродление в первой платной оплате эпизода; несколько оплат в этот день — «да», если хоть в одной включено
    SELECT s.msno, s.episode_no,
           bool_or(t.is_auto_renew = 1)                             AS autorenew_at_start
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
ep AS (
    SELECT CASE WHEN f.autorenew_at_start THEN '1) автопродление при первой оплате: да'
                ELSE                           '2) автопродление при первой оплате: нет' END AS grp,
           s.paid_duration_days                                     AS dur,
           s.event
    FROM marts.survival_episodes s
    JOIN first_paid f ON f.msno = s.msno AND f.episode_no = s.episode_no
),
by_day AS (
    SELECT grp, dur, count(*) AS n_end, sum(event) AS d
    FROM ep
    GROUP BY grp, dur
),
km AS (
    SELECT grp, dur,
           exp(sum(ln(greatest(1 - d::numeric / n_risk, 1e-12))) OVER w) AS s
    FROM (
        SELECT grp, dur, d,
               sum(n_end) OVER (PARTITION BY grp ORDER BY dur DESC ROWS UNBOUNDED PRECEDING) AS n_risk
        FROM by_day
    ) AS risk
    WINDOW w AS (PARTITION BY grp ORDER BY dur ROWS UNBOUNDED PRECEDING)
),
months AS (
    SELECT g.grp, k.month_no
    FROM (SELECT DISTINCT grp FROM by_day) AS g
    CROSS JOIN generate_series(1, 12) AS k(month_no)
),
curve AS (
    SELECT m.grp,
           m.month_no,
           cnt.n_risk,
           cnt.churned,
           coalesce(s_end.s, 1)   AS s_end,
           coalesce(s_start.s, 1) AS s_start
    FROM months m
    CROSS JOIN LATERAL (
        SELECT sum(b.n_end) FILTER (WHERE b.dur >= 30 * (m.month_no - 1))                                     AS n_risk,
               coalesce(sum(b.d) FILTER (WHERE b.dur BETWEEN 30 * (m.month_no - 1) AND 30 * m.month_no - 1), 0) AS churned
        FROM by_day b
        WHERE b.grp = m.grp
    ) AS cnt
    LEFT JOIN LATERAL (
        SELECT k.s FROM km k
        WHERE k.grp = m.grp AND k.dur <= 30 * m.month_no - 1
        ORDER BY k.dur DESC LIMIT 1
    ) AS s_end ON true
    LEFT JOIN LATERAL (
        SELECT k.s FROM km k
        WHERE k.grp = m.grp AND k.dur <= 30 * (m.month_no - 1) - 1
        ORDER BY k.dur DESC LIMIT 1
    ) AS s_start ON true
)
SELECT grp,
       month_no,
       n_risk,
       churned,
       round(100 * (1 - s_end / NULLIF(s_start, 0)), 2)             AS churn_in_month_pct,
       round(100 * s_end, 2)                                        AS retained_pct
FROM curve
WHERE n_risk >= 1000
ORDER BY grp, month_no;
