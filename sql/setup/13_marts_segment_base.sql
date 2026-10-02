-- ============================================================================
-- 13_marts_segment_base.sql — пользователи train для сегментации: метки и признаки
-- на 31.01.2017 (последняя оплата, январская отмена, эпизод, профиль).
-- ============================================================================

DROP TABLE IF EXISTS marts.segment_base;

CREATE TABLE marts.segment_base AS
WITH last_pay AS (
    -- последняя оплата до февраля: не отмена, длина плана известна (как в 02_arpu_discount.sql)
    SELECT DISTINCT ON (t.msno)
           t.msno, t.transaction_date, t.membership_expire_date, t.payment_plan_days,
           t.plan_list_price, t.actual_amount_paid, t.payment_method_id,
           t.is_auto_renew, t.is_plan_imputed
    FROM staging.transactions t
    JOIN staging.labels l ON l.msno = t.msno
    WHERE t.is_cancel = 0
      AND t.payment_plan_days > 0
      AND t.transaction_date <= DATE '2017-01-31'
    ORDER BY t.msno, t.transaction_date DESC, t.membership_expire_date DESC,
             t.actual_amount_paid DESC, t.payment_plan_days DESC,
             t.plan_list_price DESC, t.payment_method_id DESC, t.is_auto_renew DESC,
             t.is_plan_imputed ASC                                    -- полный порядок: выбор однозначен
),
tx_flags AS (
    -- история до февраля
    SELECT t.msno,
           bool_or(t.is_cancel = 1
                   AND t.transaction_date >= DATE '2017-01-01')              AS has_jan_cancel,
           count(*) FILTER (WHERE t.is_cancel = 0 AND t.actual_amount_paid > 0) AS n_paid_before_feb
    FROM staging.transactions t
    JOIN staging.labels l ON l.msno = t.msno
    WHERE t.transaction_date <= DATE '2017-01-31'
    GROUP BY t.msno
),
episode AS (
    -- эпизод, идущий на 31.01.2017: последний из начавшихся до февраля.
    -- Берутся только поля, известные на 31.01 (status и end_date эпизода — нет: они из будущих оплат)
    SELECT DISTINCT ON (e.msno)
           e.msno, e.episode_no, e.start_date, e.registration_date, e.first_tx_date
    FROM staging.subscription_episodes e
    JOIN staging.labels l ON l.msno = e.msno
    WHERE e.start_date <= DATE '2017-01-31'
    ORDER BY e.msno, e.episode_no DESC
),
episode_paid AS (
    -- первая платная оплата этого эпизода до февраля
    SELECT ep.msno, min(t.transaction_date) AS first_paid_date
    FROM episode ep
    JOIN staging.transactions t ON t.msno = ep.msno
    WHERE t.transaction_date BETWEEN ep.start_date AND DATE '2017-01-31'
      AND t.is_cancel = 0
      AND t.actual_amount_paid > 0
    GROUP BY ep.msno
),
joined AS (
    SELECT l.msno,
           l.is_churn::int                                            AS is_churn,
           r.is_churn_recalc,
           (r.msno IS NOT NULL)                                       AS is_verifiable,
           lp.transaction_date                                        AS lp_date,
           lp.membership_expire_date                                  AS lp_expire_date,
           lp.payment_plan_days                                       AS lp_plan_days,
           lp.plan_list_price                                         AS lp_list_price,
           lp.actual_amount_paid                                      AS lp_amount_paid,
           lp.payment_method_id                                       AS lp_payment_method_id,
           lp.is_auto_renew                                           AS lp_is_auto_renew,
           lp.is_plan_imputed                                         AS lp_is_plan_imputed,
           (lp.actual_amount_paid = 0)                                AS lp_is_free,
           coalesce(lp.actual_amount_paid * 30.0 / lp.payment_plan_days, 0) AS arpu30,
           coalesce(f.has_jan_cancel, false)                          AS has_jan_cancel,
           coalesce(f.n_paid_before_feb, 0)                           AS n_paid_before_feb,
           ep.episode_no,
           ep.start_date                                              AS episode_start,
           -- видимое начало — как в 12_marts_survival_episodes.sql; без профиля первый эпизод не виден
           CASE WHEN ep.msno IS NOT NULL
                THEN coalesce(ep.episode_no > 1
                              OR ep.registration_date BETWEEN DATE '2015-01-01' AND ep.first_tx_date
                              OR (ep.registration_date < DATE '2015-01-01'
                                  AND ep.start_date >= DATE '2016-03-15'), false)
           END                                                        AS is_visible_start,
           pd.first_paid_date,
           m.msno IS NOT NULL                                         AS has_profile,
           m.city,
           m.registered_via,
           m.age,
           m.gender,
           m.registration_date
    FROM staging.labels l
    LEFT JOIN staging.label_recalc r ON r.msno  = l.msno
    LEFT JOIN last_pay            lp ON lp.msno = l.msno
    LEFT JOIN tx_flags             f ON f.msno  = l.msno
    LEFT JOIN episode             ep ON ep.msno = l.msno
    LEFT JOIN episode_paid        pd ON pd.msno = l.msno
    LEFT JOIN staging.members      m ON m.msno  = l.msno
)
SELECT j.*,
       CASE WHEN j.lp_plan_days IS NULL THEN '6) нет подписки до февраля'
            WHEN j.lp_plan_days < 30    THEN '1) короче месяца'
            WHEN j.lp_plan_days <= 31   THEN '2) месяц (30-31 дн.)'
            WHEN j.lp_plan_days < 180   THEN '3) 32-179 дн.'
            WHEN j.lp_plan_days < 365   THEN '4) 180-364 дн.'
            ELSE                             '5) год и больше'
       END                                                            AS plan_group,
       -- месяц жизни с первой платной оплаты эпизода на 31.01 (у месячного плана 1 = первое продление)
       CASE WHEN j.first_paid_date IS NOT NULL
            THEN div(DATE '2017-01-31' - j.first_paid_date, 30)::int + 1
       END                                                            AS paid_month_at_cut,
       CASE WHEN j.episode_no IS NULL           THEN '7) нет подписки до февраля'
            WHEN j.first_paid_date IS NULL      THEN '6) без оплаты в эпизоде'
            WHEN NOT j.is_visible_start         THEN '5) начало не видно'
            WHEN DATE '2017-01-31' - j.first_paid_date < 30  THEN '1) 1-й мес. (первое продление)'
            WHEN DATE '2017-01-31' - j.first_paid_date < 180 THEN '2) 2-6 мес.'
            WHEN DATE '2017-01-31' - j.first_paid_date < 360 THEN '3) 7-12 мес.'
            ELSE                                                  '4) 13+ мес.'
       END                                                            AS tenure_group
FROM joined j;

ALTER TABLE marts.segment_base ADD PRIMARY KEY (msno);
ANALYZE marts.segment_base;

-- контроль: те же числа, что в 02_baseline_metrics
DO $$
DECLARE
    n_users   bigint;
    n_churned bigint;
    mrr_lost  numeric;
BEGIN
    SELECT count(*), sum(is_churn), round(sum(arpu30) FILTER (WHERE is_churn = 1))
    INTO n_users, n_churned, mrr_lost
    FROM marts.segment_base;
    IF n_users <> 992931 OR n_churned <> 63471 OR mrr_lost <> 8383575 THEN
        RAISE EXCEPTION 'marts.segment_base: пользователей %, ушли %, потери в месяц % (ожидалось 992931, 63471, 8383575)',
                        n_users, n_churned, mrr_lost;
    END IF;
END $$;

-- результат: срок жизни эпизода на 31.01 — размер, отток, потери
WITH groups AS (
    SELECT GROUPING(tenure_group)                                        AS is_total,
           coalesce(tenure_group, 'все')                                 AS tenure_group,
           count(*)                                                      AS users,
           sum(is_churn)                                                 AS churned,
           sum(arpu30) FILTER (WHERE is_churn = 1)                       AS mrr_lost,
           count(*) FILTER (WHERE plan_group = '2) месяц (30-31 дн.)')   AS monthly_plan,
           count(*) FILTER (WHERE lp_is_free)                            AS free_last,
           count(*) FILTER (WHERE is_verifiable)                         AS verifiable
    FROM marts.segment_base
    GROUP BY GROUPING SETS ((tenure_group), ())
)
SELECT tenure_group,
       users,
       churned,
       round(100.0 * churned / users, 2)                                 AS churn_pct,
       round(coalesce(mrr_lost, 0))                                      AS mrr_lost,
       round(100.0 * coalesce(mrr_lost, 0)
             / NULLIF(max(mrr_lost) FILTER (WHERE is_total = 1) OVER (), 0), 1) AS mrr_lost_share_pct,
       round(100.0 * monthly_plan / users, 1)                            AS monthly_plan_pct,
       round(100.0 * free_last / users, 1)                               AS free_last_pct,
       round(100.0 * verifiable / users, 1)                              AS verifiable_pct
FROM groups
ORDER BY is_total, tenure_group;
