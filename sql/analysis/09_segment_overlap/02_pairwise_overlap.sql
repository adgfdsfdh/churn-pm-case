-- ============================================================================
-- 02_pairwise_overlap.sql — попарное пересечение признаков-кандидатов в топ-3 (train, на 31.01.2017):
-- какая доля людей и потерь сегмента A одновременно входит в сегмент B.
-- ============================================================================

WITH flags AS (
    SELECT sb.msno,
           sb.is_churn,
           sb.arpu30,
           (sb.lp_is_auto_renew = 0)                                          AS f1,
           (sb.tenure_group = '1) 1-й мес. (первое продление)')               AS f2,
           (sb.plan_group IN ('3) 32-179 дн.', '4) 180-364 дн.', '5) год и больше')) AS f3,
           sb.has_jan_cancel                                                  AS f4,
           (sb.lp_payment_method_id = 38)                                     AS f5,
           (sb.plan_group = '2) месяц (30-31 дн.)' AND sb.lp_amount_paid >= 149) AS f6,
           (sb.age BETWEEN 13 AND 24)                                         AS f7
    FROM marts.segment_base sb
),
long_form AS (
    -- одна строка на человека и признак, который у него есть
    SELECT f.msno, f.is_churn, f.arpu30, s.segment
    FROM flags f
    CROSS JOIN LATERAL (VALUES
        ('1 автопродление выкл.', f.f1),
        ('2 первое продление',    f.f2),
        ('3 длинный план',        f.f3),
        ('4 отмена в январе',     f.f4),
        ('5 способ 38',           f.f5),
        ('6 месячный 149+ NTD',   f.f6),
        ('7 возраст 13-24',       f.f7)
    ) AS s(segment, has_flag)
    WHERE s.has_flag
),
seg_totals AS (
    SELECT segment,
           count(*)                                                           AS users,
           coalesce(sum(arpu30) FILTER (WHERE is_churn = 1), 0)               AS mrr_lost
    FROM long_form
    GROUP BY segment
),
pairs AS (
    SELECT a.segment                                                          AS segment_a,
           b.segment                                                          AS segment_b,
           count(*)                                                           AS users_both,
           coalesce(sum(a.arpu30) FILTER (WHERE a.is_churn = 1), 0)           AS mrr_lost_both
    FROM long_form a
    JOIN long_form b ON b.msno = a.msno AND b.segment <> a.segment
    GROUP BY a.segment, b.segment
)
SELECT ta.segment                                                             AS segment_a,
       tb.segment                                                             AS segment_b,
       ta.users                                                               AS users_a,
       round(ta.mrr_lost)                                                     AS mrr_lost_a,
       coalesce(p.users_both, 0)                                              AS users_both,
       round(100.0 * coalesce(p.users_both, 0) / ta.users, 1)                 AS users_a_in_b_pct,
       round(coalesce(p.mrr_lost_both, 0))                                    AS mrr_lost_both,
       round(100 * coalesce(p.mrr_lost_both, 0) / NULLIF(ta.mrr_lost, 0), 1)  AS mrr_lost_a_in_b_pct
FROM seg_totals ta
CROSS JOIN seg_totals tb
LEFT JOIN pairs p ON p.segment_a = ta.segment AND p.segment_b = tb.segment
WHERE ta.segment <> tb.segment
ORDER BY ta.segment, tb.segment;
