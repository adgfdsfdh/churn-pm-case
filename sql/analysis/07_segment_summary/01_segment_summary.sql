-- ============================================================================
-- 01_segment_summary.sql — отток и потери по всем разрезам train (признаки на 31.01.2017),
-- подытог по каждому разрезу; интервал Уилсона с поправкой Бонферрони на число ячеек разреза.
-- ============================================================================

WITH users AS (
    SELECT sb.*,
           lg.over_day_days
    FROM marts.segment_base sb
    LEFT JOIN staging.user_logs_monthly lg
           ON lg.msno = sb.msno
          AND lg.month = DATE '2017-01-01'
),
cells AS (
    -- одна строка на пользователя и разрез
    SELECT d.dim, d.value, u.is_churn, u.is_churn_recalc, u.is_verifiable, u.arpu30
    FROM users u
    CROSS JOIN LATERAL (VALUES
        ('01 срок жизни эпизода',   u.tenure_group),
        ('02 автопродление',        CASE u.lp_is_auto_renew WHEN 1 THEN 'да' WHEN 0 THEN 'нет'
                                         ELSE 'нет оплаты до февраля' END),
        ('03 способ оплаты',        coalesce(u.lp_payment_method_id::text, 'нет оплаты до февраля')),
        ('04 длина плана',          u.plan_group),
        ('05 цена месячного плана', CASE WHEN u.plan_group <> '2) месяц (30-31 дн.)' THEN 'план не месячный'
                                         WHEN u.lp_amount_paid IN (0, 99, 100, 119, 129, 149, 150)
                                              THEN lpad(u.lp_amount_paid::text, 3, '0') || ' NTD'
                                         ELSE 'другая сумма' END),
        ('06 последняя подписка',   CASE WHEN u.lp_is_free THEN 'бесплатная'
                                         WHEN u.lp_is_free = false THEN 'платная'
                                         ELSE 'нет оплаты до февраля' END),
        ('07 отмена в январе',      CASE WHEN u.has_jan_cancel THEN 'да' ELSE 'нет' END),
        ('08 канал регистрации',    coalesce(u.registered_via::text, 'нет профиля')),
        ('09 город',                coalesce(u.city::text, 'нет профиля')),
        ('10 возраст',              CASE WHEN NOT u.has_profile THEN 'нет профиля'
                                         WHEN u.age IS NULL     THEN 'не указан'
                                         WHEN u.age < 18        THEN '13-17'
                                         WHEN u.age < 25        THEN '18-24'
                                         WHEN u.age < 35        THEN '25-34'
                                         WHEN u.age < 45        THEN '35-44'
                                         ELSE                        '45-75' END),
        ('11 сверхактивные дни в январе', CASE WHEN u.over_day_days IS NULL THEN 'нет логов в январе'
                                               WHEN u.over_day_days > 0     THEN 'есть день больше суток'
                                               ELSE 'нет' END),
        ('12 проверяется правилом', CASE WHEN u.is_verifiable THEN 'да' ELSE 'нет' END)
    ) AS d(dim, value)
),
agg AS (
    SELECT dim,
           coalesce(value, 'ИТОГО по разрезу')                        AS value,
           GROUPING(value)                                            AS is_subtotal,
           count(*)::numeric                                          AS n,
           sum(is_churn)                                              AS churned,
           sum(arpu30) FILTER (WHERE is_churn = 1)                    AS mrr_lost,
           avg(arpu30)                                                AS arpu30,
           count(*) FILTER (WHERE is_verifiable)                      AS n_verifiable,
           sum(is_churn_recalc)                                       AS churned_recalc
    FROM cells
    GROUP BY GROUPING SETS ((dim, value), (dim))
),
stats AS (
    SELECT a.*,
           a.churned / a.n                                            AS p,
           -- z для 95% с поправкой Бонферрони: 0,05 / число ячеек разреза (аппроксимация, точность ±0,001)
           count(*) FILTER (WHERE a.is_subtotal = 0) OVER (PARTITION BY a.dim) AS m
    FROM agg a
),
zed AS (
    SELECT s.*,
           sqrt(-2 * ln(0.025 / CASE WHEN s.is_subtotal = 1 THEN 1 ELSE s.m END)) AS t   -- итог разреза — без поправки
    FROM stats s
),
z_calc AS (
    SELECT zed.*,
           (t - (2.515517 + 0.802853 * t + 0.010328 * t^2)
                / (1 + 1.432788 * t + 0.189269 * t^2 + 0.001308 * t^3))::numeric AS z
    FROM zed
)
SELECT dim,
       value,
       n::bigint                                                      AS users,
       round(100 * n / max(n) FILTER (WHERE is_subtotal = 1) OVER (PARTITION BY dim), 2) AS users_pct,
       churned,
       round(100 * p, 2)                                              AS churn_pct,
       round(100 * ((p + z^2 / (2 * n)) / (1 + z^2 / n)
             - z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / (1 + z^2 / n)), 2) AS ci_low_pct,
       round(100 * ((p + z^2 / (2 * n)) / (1 + z^2 / n)
             + z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / (1 + z^2 / n)), 2) AS ci_high_pct,
       round(100 * (p - max(p) FILTER (WHERE is_subtotal = 1) OVER (PARTITION BY dim)), 2) AS diff_pp,
       round(coalesce(mrr_lost, 0))                                   AS mrr_lost,
       round(100 * coalesce(mrr_lost, 0)
             / max(mrr_lost) FILTER (WHERE is_subtotal = 1) OVER (PARTITION BY dim), 1) AS mrr_lost_share_pct,
       round(arpu30, 1)                                               AS arpu30,
       round(100.0 * churned_recalc / NULLIF(n_verifiable, 0), 2)     AS churn_recalc_pct,
       round(100.0 * n_verifiable / n, 1)                             AS verifiable_pct,
       CASE WHEN n < 30  THEN 'меньше 30 — вывода нет'
            WHEN n < 100 THEN 'меньше 100 — вывод шаткий'
       END                                                            AS small_flag,
       CASE WHEN is_subtotal = 1 THEN NULL
            WHEN abs(p - max(p) FILTER (WHERE is_subtotal = 1) OVER (PARTITION BY dim)) >= 0.01
             AND coalesce(mrr_lost, 0) >= 0.01 * max(mrr_lost) FILTER (WHERE is_subtotal = 1) OVER (PARTITION BY dim)
            THEN 'да' ELSE 'нет'
       END                                                            AS passes_threshold,
       round(z, 3)                                                    AS z_bonferroni
FROM z_calc
ORDER BY dim, is_subtotal DESC, mrr_lost DESC NULLS LAST, value;
