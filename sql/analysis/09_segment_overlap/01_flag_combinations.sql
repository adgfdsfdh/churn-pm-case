-- ============================================================================
-- 01_flag_combinations.sql — потери train, разложенные по непересекающимся сочетаниям
-- признаков-кандидатов в топ-3 (на 31.01.2017), с накопительной долей (Парето).
-- ============================================================================

WITH flags AS (
    SELECT sb.msno,
           sb.is_churn,
           sb.arpu30,
           (sb.lp_is_auto_renew = 0)                                          AS f_autorenew_off,
           (sb.tenure_group = '1) 1-й мес. (первое продление)')               AS f_first_renewal,
           (sb.plan_group IN ('3) 32-179 дн.', '4) 180-364 дн.', '5) год и больше')) AS f_long_plan,
           sb.has_jan_cancel                                                  AS f_jan_cancel,
           (sb.lp_payment_method_id = 38)                                     AS f_method_38,
           (sb.plan_group = '2) месяц (30-31 дн.)' AND sb.lp_amount_paid >= 149) AS f_monthly_149plus,
           (sb.age BETWEEN 13 AND 24)                                         AS f_age_13_24
    FROM marts.segment_base sb
),
combos AS (
    SELECT concat_ws(' + ',
               CASE WHEN f_autorenew_off   THEN 'автопродление выкл.' END,
               CASE WHEN f_first_renewal   THEN 'первое продление' END,
               CASE WHEN f_long_plan       THEN 'длинный план' END,
               CASE WHEN f_jan_cancel      THEN 'отмена в январе' END,
               CASE WHEN f_method_38       THEN 'способ 38' END,
               CASE WHEN f_monthly_149plus THEN 'месячный 149+ NTD' END,
               CASE WHEN f_age_13_24       THEN 'возраст 13-24' END)          AS combo,
           count(*)                                                           AS users,
           sum(is_churn)                                                      AS churned,
           coalesce(sum(arpu30) FILTER (WHERE is_churn = 1), 0)               AS mrr_lost
    FROM flags
    GROUP BY 1
)
SELECT CASE WHEN combo = '' THEN '(ни одного признака)' ELSE combo END     AS combo,
       users,
       churned,
       round(100.0 * churned / users, 2)                                      AS churn_pct,
       round(mrr_lost)                                                        AS mrr_lost,
       round(100 * mrr_lost / sum(mrr_lost) OVER (), 1)                       AS mrr_lost_share_pct,
       round(100 * sum(mrr_lost) OVER (ORDER BY mrr_lost DESC, combo COLLATE "C"
                                       ROWS UNBOUNDED PRECEDING)
                 / sum(mrr_lost) OVER (), 1)                                  AS cum_share_pct,
       CASE WHEN users < 30  THEN 'меньше 30 — вывода нет'
            WHEN users < 100 THEN 'меньше 100 — вывод шаткий'
       END                                                                    AS small_flag
FROM combos
ORDER BY mrr_lost DESC, combo COLLATE "C";
