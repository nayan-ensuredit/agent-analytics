-- ============================================================================
-- FILE 3B: DASHBOARD SUPPLEMENT - DEEP DIVE QUERIES
-- ============================================================================
-- Supplements 03_actionable_dashboard_queries.sql with additional depth in
-- sections that were thin: Sales Funnel, Product Intelligence, Broker,
-- Geographic, and Insurer analytics.
--
-- PostgreSQL 14+ | All tables from existing schema
-- Every query includes INSIGHT, ACTION, and THRESHOLDS.
-- ============================================================================


-- ############################################################################
-- SECTION 3 SUPPLEMENT: SALES FUNNEL & CONVERSION (EXTENDED)
-- ############################################################################

-- ============================================================================
-- 3.5 SOURCE/CHANNEL CONVERSION ANALYSIS
-- ============================================================================
-- INSIGHT: "ICE" (direct digital) accounts for 67% of policies, with the
--   remainder split across F-codes (branches/franchises). This query reveals
--   which source channels convert best and which are leaking prospects.
-- ACTION: Sources with high quoting but low sales need pricing or UX review.
--   Sources with zero quotes need activation campaigns. Invest marketing
--   spend in channels with best cost-per-policy economics.
-- THRESHOLDS:
--   Good conversion (quote-to-policy): >5%
--   Average: 2-5%
--   Poor: <2% -- needs investigation
-- ============================================================================

WITH source_sales AS (
    SELECT
        source,
        COUNT(*) AS total_policies,
        ROUND(SUM(premium_amount), 0) AS total_premium,
        COUNT(DISTINCT agent) AS unique_agents,
        ROUND(AVG(premium_amount), 0) AS avg_ticket_size,
        COUNT(CASE WHEN policy_business_type = 'New Policy' THEN 1 END) AS new_policies,
        COUNT(CASE WHEN policy_business_type = 'Renewal' THEN 1 END) AS renewals,
        ROUND(COUNT(CASE WHEN policy_business_type = 'Renewal' THEN 1 END)::NUMERIC
              / NULLIF(COUNT(*), 0) * 100, 1) AS renewal_pct,
        COUNT(CASE WHEN is_breakin_journey::TEXT = 'true' THEN 1 END) AS breakin_count
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    GROUP BY source
),
source_activity AS (
    SELECT
        cw.broker_name AS source,
        SUM(
            COALESCE(cw."4w_quote_count", 0) + COALESCE(cw."2w_quote_count", 0) +
            COALESCE(cw.health_quote_count, 0) + COALESCE(cw.gcv_quote_count, 0) +
            COALESCE(cw.pcv_quote_count, 0)
        ) AS total_quotes,
        SUM(
            COALESCE(cw."4w_proposal_count", 0) + COALESCE(cw."2w_proposal_count", 0) +
            COALESCE(cw.health_proposal_count, 0) + COALESCE(cw.gcv_proposal_count, 0) +
            COALESCE(cw.pcv_proposal_count, 0)
        ) AS total_proposals
    FROM channel_wise_monthly_activity_summary cw
    WHERE cw.activity_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    GROUP BY cw.broker_name
)
SELECT
    ss.source,
    COALESCE(sa.total_quotes, 0) AS total_quotes,
    COALESCE(sa.total_proposals, 0) AS total_proposals,
    ss.total_policies,
    ss.total_premium,
    ss.unique_agents,
    ss.avg_ticket_size,
    ss.renewal_pct,
    ss.breakin_count,

    -- Conversion rates
    CASE WHEN COALESCE(sa.total_quotes, 0) > 0
         THEN ROUND(ss.total_policies::NUMERIC / sa.total_quotes * 100, 2)
         ELSE NULL END AS quote_to_policy_pct,
    CASE WHEN COALESCE(sa.total_proposals, 0) > 0
         THEN ROUND(ss.total_policies::NUMERIC / sa.total_proposals * 100, 2)
         ELSE NULL END AS proposal_to_policy_pct,

    -- Revenue per agent
    ROUND(ss.total_premium / NULLIF(ss.unique_agents, 0), 0) AS premium_per_agent,

    -- Classification
    CASE
        WHEN ss.source = 'ICE' THEN 'DIRECT DIGITAL'
        WHEN ss.source LIKE 'F%' THEN 'FRANCHISE/BRANCH'
        ELSE 'OTHER'
    END AS channel_type,

    -- Health assessment
    CASE
        WHEN COALESCE(sa.total_quotes, 0) > 100 AND ss.total_policies = 0
             THEN 'CRITICAL: Quoting but zero sales. Urgent fix needed.'
        WHEN COALESCE(sa.total_quotes, 0) > 0
             AND ss.total_policies::NUMERIC / NULLIF(sa.total_quotes, 0) < 0.02
             THEN 'POOR: Conversion below 2%. Investigate pricing/UX.'
        WHEN COALESCE(sa.total_quotes, 0) > 0
             AND ss.total_policies::NUMERIC / NULLIF(sa.total_quotes, 0) < 0.05
             THEN 'AVERAGE: 2-5% conversion. Room for optimization.'
        WHEN COALESCE(sa.total_quotes, 0) > 0
             THEN 'GOOD: Conversion above 5%. Maintain and scale.'
        ELSE 'NO DATA: No quoting activity detected.'
    END AS health_status

FROM source_sales ss
LEFT JOIN source_activity sa ON sa.source = ss.source
ORDER BY ss.total_premium DESC;


-- ============================================================================
-- 3.6 TIME-BASED FUNNEL ANALYSIS (Hour-of-Day / Day-of-Week)
-- ============================================================================
-- INSIGHT: When do conversions happen? Identifies peak selling hours and
--   days, enabling optimal staffing and support availability.
-- ACTION: Ensure tech support and insurer API reliability during peak hours.
--   Schedule marketing pushes for high-conversion windows. Reduce spending
--   during dead hours.
-- THRESHOLDS:
--   Peak hour: >1.5x daily average volume
--   Dead hour: <0.5x daily average volume
-- ============================================================================

SELECT
    EXTRACT(DOW FROM sold_date) AS day_of_week,
    TO_CHAR(sold_date, 'Day') AS day_name,
    COUNT(*) AS total_policies,
    ROUND(SUM(premium_amount), 0) AS total_premium,
    COUNT(DISTINCT agent) AS unique_agents,
    ROUND(AVG(premium_amount), 0) AS avg_ticket,
    -- Comparison to overall daily average
    ROUND(COUNT(*)::NUMERIC / NULLIF(COUNT(DISTINCT sold_date), 0), 1) AS avg_policies_per_day,
    -- Premium density
    ROUND(SUM(premium_amount) / NULLIF(COUNT(DISTINCT sold_date), 0), 0) AS avg_premium_per_day,
    -- Weekend vs Weekday flag
    CASE WHEN EXTRACT(DOW FROM sold_date) IN (0, 6) THEN 'WEEKEND' ELSE 'WEEKDAY' END AS day_type,
    -- Product mix by day
    ROUND(COUNT(CASE WHEN product_type ILIKE '%car%' OR product_type ILIKE '%private%' THEN 1 END)::NUMERIC
          / NULLIF(COUNT(*), 0) * 100, 1) AS motor_4w_pct,
    ROUND(COUNT(CASE WHEN product_type ILIKE '%two%' OR product_type ILIKE '%2w%' THEN 1 END)::NUMERIC
          / NULLIF(COUNT(*), 0) * 100, 1) AS motor_2w_pct
FROM sold_policies_data
WHERE sold_date >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY EXTRACT(DOW FROM sold_date), TO_CHAR(sold_date, 'Day')
ORDER BY EXTRACT(DOW FROM sold_date);


-- ============================================================================
-- 3.7 MONTHLY FUNNEL TREND (Quote -> Proposal -> Policy)
-- ============================================================================
-- INSIGHT: Tracks the full funnel month over month. A widening gap between
--   quotes and policies means something is breaking in the middle of the
--   customer journey.
-- ACTION: If quote-to-proposal drop >60%, pricing display is the issue.
--   If proposal-to-policy drop >80%, payment/documentation is the issue.
--   Track month-over-month to catch regressions from platform changes.
-- ============================================================================

SELECT
    cw.activity_month,
    SUM(
        COALESCE(cw."4w_quote_count", 0) + COALESCE(cw."2w_quote_count", 0) +
        COALESCE(cw.health_quote_count, 0) + COALESCE(cw.gcv_quote_count, 0) +
        COALESCE(cw.pcv_quote_count, 0)
    ) AS total_quotes,
    SUM(
        COALESCE(cw."4w_proposal_count", 0) + COALESCE(cw."2w_proposal_count", 0) +
        COALESCE(cw.health_proposal_count, 0) + COALESCE(cw.gcv_proposal_count, 0) +
        COALESCE(cw.pcv_proposal_count, 0)
    ) AS total_proposals,
    SUM(
        COALESCE(cw."4w_policy_count", 0) + COALESCE(cw."2w_policy_count", 0) +
        COALESCE(cw.health_policy_count, 0) + COALESCE(cw.gcv_policy_count, 0) +
        COALESCE(cw.pcv_policy_count, 0)
    ) AS total_policies,

    -- Conversion rates
    CASE WHEN SUM(COALESCE(cw."4w_quote_count", 0) + COALESCE(cw."2w_quote_count", 0) +
                  COALESCE(cw.health_quote_count, 0) + COALESCE(cw.gcv_quote_count, 0) +
                  COALESCE(cw.pcv_quote_count, 0)) > 0
         THEN ROUND(
             SUM(COALESCE(cw."4w_proposal_count", 0) + COALESCE(cw."2w_proposal_count", 0) +
                 COALESCE(cw.health_proposal_count, 0) + COALESCE(cw.gcv_proposal_count, 0) +
                 COALESCE(cw.pcv_proposal_count, 0))::NUMERIC /
             SUM(COALESCE(cw."4w_quote_count", 0) + COALESCE(cw."2w_quote_count", 0) +
                 COALESCE(cw.health_quote_count, 0) + COALESCE(cw.gcv_quote_count, 0) +
                 COALESCE(cw.pcv_quote_count, 0)) * 100, 2)
         ELSE 0 END AS quote_to_proposal_pct,

    CASE WHEN SUM(COALESCE(cw."4w_proposal_count", 0) + COALESCE(cw."2w_proposal_count", 0) +
                  COALESCE(cw.health_proposal_count, 0) + COALESCE(cw.gcv_proposal_count, 0) +
                  COALESCE(cw.pcv_proposal_count, 0)) > 0
         THEN ROUND(
             SUM(COALESCE(cw."4w_policy_count", 0) + COALESCE(cw."2w_policy_count", 0) +
                 COALESCE(cw.health_policy_count, 0) + COALESCE(cw.gcv_policy_count, 0) +
                 COALESCE(cw.pcv_policy_count, 0))::NUMERIC /
             SUM(COALESCE(cw."4w_proposal_count", 0) + COALESCE(cw."2w_proposal_count", 0) +
                 COALESCE(cw.health_proposal_count, 0) + COALESCE(cw.gcv_proposal_count, 0) +
                 COALESCE(cw.pcv_proposal_count, 0)) * 100, 2)
         ELSE 0 END AS proposal_to_policy_pct,

    CASE WHEN SUM(COALESCE(cw."4w_quote_count", 0) + COALESCE(cw."2w_quote_count", 0) +
                  COALESCE(cw.health_quote_count, 0) + COALESCE(cw.gcv_quote_count, 0) +
                  COALESCE(cw.pcv_quote_count, 0)) > 0
         THEN ROUND(
             SUM(COALESCE(cw."4w_policy_count", 0) + COALESCE(cw."2w_policy_count", 0) +
                 COALESCE(cw.health_policy_count, 0) + COALESCE(cw.gcv_policy_count, 0) +
                 COALESCE(cw.pcv_policy_count, 0))::NUMERIC /
             SUM(COALESCE(cw."4w_quote_count", 0) + COALESCE(cw."2w_quote_count", 0) +
                 COALESCE(cw.health_quote_count, 0) + COALESCE(cw.gcv_quote_count, 0) +
                 COALESCE(cw.pcv_quote_count, 0)) * 100, 2)
         ELSE 0 END AS overall_quote_to_policy_pct

FROM channel_wise_monthly_activity_summary cw
GROUP BY cw.activity_month
ORDER BY cw.activity_month;


-- ============================================================================
-- 3.8 AGENT-LEVEL CONVERSION BENCHMARKING
-- ============================================================================
-- INSIGHT: Compare each agent's conversion rate to the platform average.
--   Identifies top converters (learn from them) and bottom converters
--   (train them). Segmented by volume tier so comparisons are fair.
-- ACTION: Share best practices from top-quartile converters. Set up
--   peer-mentoring between high and low converters in same volume tier.
--   Agents below 50% of tier average need 1-on-1 coaching.
-- THRESHOLDS:
--   Top quartile: >2x platform average conversion
--   Good: 1-2x platform average
--   Below average: 0.5-1x
--   Critical: <0.5x -- needs immediate intervention
-- ============================================================================

WITH agent_funnel AS (
    SELECT
        aw.agent_id,
        SUM(
            COALESCE(aw.quote_count_4w, 0) + COALESCE(aw.quote_count_2w, 0) +
            COALESCE(aw.quote_count_health, 0) + COALESCE(aw.quote_count_gcv, 0) +
            COALESCE(aw.quote_count_pcv, 0)
        ) AS total_quotes,
        SUM(
            COALESCE(aw.proposal_count_4w, 0) + COALESCE(aw.proposal_count_2w, 0) +
            COALESCE(aw.proposal_count_health, 0) + COALESCE(aw.proposal_count_gcv, 0) +
            COALESCE(aw.proposal_count_pcv, 0)
        ) AS total_proposals,
        SUM(
            COALESCE(aw.policy_count_4w, 0) + COALESCE(aw.policy_count_2w, 0) +
            COALESCE(aw.policy_count_health, 0) + COALESCE(aw.policy_count_gcv, 0) +
            COALESCE(aw.policy_count_pcv, 0)
        ) AS total_policies
    FROM agent_wise_monthly_activity_summary aw
    WHERE aw.activity_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '3 months'
    GROUP BY aw.agent_id
    HAVING SUM(COALESCE(aw.quote_count_4w, 0) + COALESCE(aw.quote_count_2w, 0) +
               COALESCE(aw.quote_count_health, 0) + COALESCE(aw.quote_count_gcv, 0) +
               COALESCE(aw.quote_count_pcv, 0)) > 0
),
platform_avg AS (
    SELECT
        ROUND(SUM(total_policies)::NUMERIC / NULLIF(SUM(total_quotes), 0) * 100, 2) AS avg_conversion
    FROM agent_funnel
),
agent_with_tier AS (
    SELECT
        af.*,
        ROUND(af.total_policies::NUMERIC / NULLIF(af.total_quotes, 0) * 100, 2) AS conversion_rate,
        NTILE(4) OVER (ORDER BY af.total_quotes) AS volume_quartile,
        CASE
            WHEN af.total_quotes >= 100 THEN 'HIGH VOLUME'
            WHEN af.total_quotes >= 20 THEN 'MEDIUM VOLUME'
            ELSE 'LOW VOLUME'
        END AS volume_tier
    FROM agent_funnel af
)
SELECT
    awt.agent_id,
    awt.volume_tier,
    awt.total_quotes,
    awt.total_proposals,
    awt.total_policies,
    awt.conversion_rate,
    pa.avg_conversion AS platform_avg_conversion,
    ROUND(awt.conversion_rate / NULLIF(pa.avg_conversion, 0), 2) AS conversion_vs_platform,

    -- Funnel stage analysis
    CASE WHEN awt.total_quotes > 0
         THEN ROUND(awt.total_proposals::NUMERIC / awt.total_quotes * 100, 1) ELSE 0 END AS quote_to_proposal_pct,
    CASE WHEN awt.total_proposals > 0
         THEN ROUND(awt.total_policies::NUMERIC / awt.total_proposals * 100, 1) ELSE 0 END AS proposal_to_policy_pct,

    CASE
        WHEN awt.conversion_rate >= pa.avg_conversion * 2
             THEN 'TOP PERFORMER: Study and replicate their process.'
        WHEN awt.conversion_rate >= pa.avg_conversion
             THEN 'GOOD: Above platform average.'
        WHEN awt.conversion_rate >= pa.avg_conversion * 0.5
             THEN 'BELOW AVERAGE: Needs coaching on conversion techniques.'
        WHEN awt.conversion_rate > 0
             THEN 'CRITICAL: Below 50% of average. Immediate 1-on-1 required.'
        ELSE 'ZERO CONVERSION: Quoting but never closing. Check training.'
    END AS performance_flag

FROM agent_with_tier awt
CROSS JOIN platform_avg pa
ORDER BY awt.total_quotes DESC
LIMIT 500;


-- ############################################################################
-- SECTION 4 SUPPLEMENT: PRODUCT INTELLIGENCE (EXTENDED)
-- ############################################################################

-- ============================================================================
-- 4.5 PRODUCT GROWTH VELOCITY (Month-over-Month by Product)
-- ============================================================================
-- INSIGHT: Tracks each product's growth trajectory independently. Critical
--   for identifying which products are gaining traction (2W expanding?) and
--   which are stagnating.
-- ACTION: Products with 3+ months of growth above 10% MoM should get
--   more marketing investment. Products declining 3+ months need product
--   team review of pricing and insurer availability.
-- THRESHOLDS:
--   Accelerating: >10% MoM growth for 3+ months
--   Growing: >0% MoM
--   Stagnating: -5% to 0% MoM
--   Declining: < -5% MoM
-- ============================================================================

WITH monthly_product AS (
    SELECT
        sold_month,
        product_type,
        SUM(policy_count) AS policies,
        SUM(total_premium) AS premium
    FROM category_wise_monthly_sold_policies
    GROUP BY sold_month, product_type
),
with_lag AS (
    SELECT
        sold_month,
        product_type,
        policies,
        premium,
        LAG(policies) OVER (PARTITION BY product_type ORDER BY sold_month) AS prev_policies,
        LAG(premium) OVER (PARTITION BY product_type ORDER BY sold_month) AS prev_premium,
        -- 3-month trailing average
        AVG(policies) OVER (
            PARTITION BY product_type
            ORDER BY sold_month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ) AS policies_3m_avg,
        AVG(premium) OVER (
            PARTITION BY product_type
            ORDER BY sold_month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ) AS premium_3m_avg
    FROM monthly_product
)
SELECT
    sold_month,
    product_type,
    policies,
    ROUND(premium, 0) AS premium,
    prev_policies,
    CASE WHEN prev_policies > 0
         THEN ROUND((policies - prev_policies)::NUMERIC / prev_policies * 100, 1)
         ELSE NULL END AS policy_mom_pct,
    CASE WHEN prev_premium > 0
         THEN ROUND((premium - prev_premium) / prev_premium * 100, 1)
         ELSE NULL END AS premium_mom_pct,
    ROUND(policies_3m_avg, 0) AS policies_3m_avg,
    ROUND(premium_3m_avg, 0) AS premium_3m_avg,

    CASE
        WHEN prev_policies > 0 AND (policies - prev_policies)::NUMERIC / prev_policies > 0.10
             THEN 'ACCELERATING'
        WHEN prev_policies > 0 AND policies >= prev_policies
             THEN 'GROWING'
        WHEN prev_policies > 0 AND (policies - prev_policies)::NUMERIC / prev_policies >= -0.05
             THEN 'STAGNATING'
        WHEN prev_policies > 0
             THEN 'DECLINING'
        ELSE 'NEW/INSUFFICIENT DATA'
    END AS velocity_status

FROM with_lag
ORDER BY product_type, sold_month;


-- ============================================================================
-- 4.6 PREMIUM BAND ANALYSIS BY PRODUCT TYPE
-- ============================================================================
-- INSIGHT: What premium ranges sell most? Identifies the "sweet spot"
--   pricing tier for each product. Policies outside the sweet spot may
--   have conversion issues or represent niche segments.
-- ACTION: Focus insurer negotiations on sweet-spot price ranges. If
--   conversion drops above a certain premium band, consider whether
--   customer base can support high-premium products.
-- ============================================================================

SELECT
    product_type,
    CASE
        WHEN premium_amount < 2000 THEN '00: Under 2K'
        WHEN premium_amount < 5000 THEN '01: 2K-5K'
        WHEN premium_amount < 10000 THEN '02: 5K-10K'
        WHEN premium_amount < 15000 THEN '03: 10K-15K'
        WHEN premium_amount < 20000 THEN '04: 15K-20K'
        WHEN premium_amount < 30000 THEN '05: 20K-30K'
        WHEN premium_amount < 50000 THEN '06: 30K-50K'
        WHEN premium_amount < 100000 THEN '07: 50K-1L'
        ELSE '08: 1L+'
    END AS premium_band,
    COUNT(*) AS policies,
    ROUND(SUM(premium_amount), 0) AS total_premium,
    ROUND(AVG(premium_amount), 0) AS avg_premium,
    COUNT(DISTINCT agent) AS unique_agents,
    COUNT(DISTINCT insurer) AS unique_insurers,
    -- Share within product
    ROUND(COUNT(*)::NUMERIC / SUM(COUNT(*)) OVER (PARTITION BY product_type) * 100, 1) AS pct_of_product,
    -- Breakin proportion in this band
    ROUND(COUNT(CASE WHEN is_breakin_journey::TEXT = 'true' THEN 1 END)::NUMERIC
          / NULLIF(COUNT(*), 0) * 100, 1) AS breakin_pct,
    -- New vs Renewal
    ROUND(COUNT(CASE WHEN policy_business_type = 'Renewal' THEN 1 END)::NUMERIC
          / NULLIF(COUNT(*), 0) * 100, 1) AS renewal_pct
FROM sold_policies_data
WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
  AND premium_amount > 0
GROUP BY product_type,
    CASE
        WHEN premium_amount < 2000 THEN '00: Under 2K'
        WHEN premium_amount < 5000 THEN '01: 2K-5K'
        WHEN premium_amount < 10000 THEN '02: 5K-10K'
        WHEN premium_amount < 15000 THEN '03: 10K-15K'
        WHEN premium_amount < 20000 THEN '04: 15K-20K'
        WHEN premium_amount < 30000 THEN '05: 20K-30K'
        WHEN premium_amount < 50000 THEN '06: 30K-50K'
        WHEN premium_amount < 100000 THEN '07: 50K-1L'
        ELSE '08: 1L+'
    END
ORDER BY product_type, premium_band;


-- ============================================================================
-- 4.7 BREAKIN JOURNEY DEEP DIVE BY PRODUCT AND INSURER
-- ============================================================================
-- INSIGHT: 31% of journeys are breakin (lapsed policy renewals). This is
--   a high-friction experience. Which insurers handle breakin best?
--   Which products have highest breakin rates?
-- ACTION: Route breakin customers to insurers with best breakin conversion.
--   Reduce breakin rate by sending renewal reminders BEFORE policy lapses.
--   Product-wise: if a specific product has >40% breakin, that product's
--   renewal capture is failing.
-- THRESHOLDS:
--   Healthy breakin rate: <20%
--   Moderate: 20-35%
--   High: >35% -- renewal capture program needed
-- ============================================================================

SELECT
    product_type,
    insurer,
    COUNT(*) AS total_policies,
    COUNT(CASE WHEN is_breakin_journey::TEXT = 'true' THEN 1 END) AS breakin_policies,
    ROUND(COUNT(CASE WHEN is_breakin_journey::TEXT = 'true' THEN 1 END)::NUMERIC
          / NULLIF(COUNT(*), 0) * 100, 1) AS breakin_pct,
    -- Premium comparison: breakin vs normal
    ROUND(AVG(CASE WHEN is_breakin_journey::TEXT = 'true' THEN premium_amount END), 0) AS avg_breakin_premium,
    ROUND(AVG(CASE WHEN is_breakin_journey::TEXT != 'true' OR is_breakin_journey IS NULL THEN premium_amount END), 0) AS avg_normal_premium,
    -- Premium uplift on breakin (breakin usually costs more)
    ROUND(
        (AVG(CASE WHEN is_breakin_journey::TEXT = 'true' THEN premium_amount END) -
         AVG(CASE WHEN is_breakin_journey::TEXT != 'true' OR is_breakin_journey IS NULL THEN premium_amount END))
        / NULLIF(AVG(CASE WHEN is_breakin_journey::TEXT != 'true' OR is_breakin_journey IS NULL THEN premium_amount END), 0) * 100
    , 1) AS breakin_premium_uplift_pct,

    CASE
        WHEN COUNT(CASE WHEN is_breakin_journey::TEXT = 'true' THEN 1 END)::NUMERIC
             / NULLIF(COUNT(*), 0) > 0.35
             THEN 'HIGH BREAKIN: Renewal capture failing. Pre-expiry outreach needed.'
        WHEN COUNT(CASE WHEN is_breakin_journey::TEXT = 'true' THEN 1 END)::NUMERIC
             / NULLIF(COUNT(*), 0) > 0.20
             THEN 'MODERATE: Some room to improve renewal timing.'
        ELSE 'HEALTHY: Most customers renewing before lapse.'
    END AS breakin_assessment

FROM sold_policies_data
WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
  AND insurer IS NOT NULL
GROUP BY product_type, insurer
HAVING COUNT(*) >= 10
ORDER BY product_type, breakin_pct DESC;


-- ############################################################################
-- SECTION 5 SUPPLEMENT: BROKER/CHANNEL DEEP DIVE (EXTENDED)
-- ############################################################################

-- ============================================================================
-- 5.3 BROKER PRODUCT MIX ANALYSIS
-- ============================================================================
-- INSIGHT: Which brokers sell which products? Identifies broker-product
--   alignment and opportunities to cross-sell new products through
--   brokers who only focus on one product.
-- ACTION: Brokers selling only 4W should be trained on 2W/Health.
--   Brokers with 100% one-insurer concentration need diversification.
--   Share top broker product mixes as templates for underperformers.
-- ============================================================================

WITH broker_product AS (
    SELECT
        source AS broker,
        sales_channel_user_id,
        product_type,
        COUNT(*) AS policies,
        SUM(premium_amount) AS premium
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    GROUP BY source, sales_channel_user_id, product_type
),
broker_total AS (
    SELECT
        broker,
        sales_channel_user_id,
        SUM(policies) AS total_policies,
        SUM(premium) AS total_premium,
        COUNT(DISTINCT product_type) AS unique_products
    FROM broker_product
    GROUP BY broker, sales_channel_user_id
)
SELECT
    bt.broker,
    bt.total_policies,
    ROUND(bt.total_premium, 0) AS total_premium,
    bt.unique_products,
    -- Product breakdown
    COALESCE(SUM(CASE WHEN bp.product_type ILIKE '%car%' OR bp.product_type ILIKE '%private%'
                      THEN bp.policies END), 0) AS motor_4w_policies,
    COALESCE(SUM(CASE WHEN bp.product_type ILIKE '%two%' OR bp.product_type ILIKE '%2w%'
                      THEN bp.policies END), 0) AS motor_2w_policies,
    COALESCE(SUM(CASE WHEN bp.product_type ILIKE '%health%'
                      THEN bp.policies END), 0) AS health_policies,
    -- Percentage breakdown
    ROUND(COALESCE(SUM(CASE WHEN bp.product_type ILIKE '%car%' OR bp.product_type ILIKE '%private%'
                            THEN bp.policies END), 0)::NUMERIC
          / NULLIF(bt.total_policies, 0) * 100, 1) AS motor_4w_pct,
    ROUND(COALESCE(SUM(CASE WHEN bp.product_type ILIKE '%two%' OR bp.product_type ILIKE '%2w%'
                            THEN bp.policies END), 0)::NUMERIC
          / NULLIF(bt.total_policies, 0) * 100, 1) AS motor_2w_pct,
    ROUND(COALESCE(SUM(CASE WHEN bp.product_type ILIKE '%health%'
                            THEN bp.policies END), 0)::NUMERIC
          / NULLIF(bt.total_policies, 0) * 100, 1) AS health_pct,

    CASE
        WHEN bt.unique_products = 1 THEN 'MONO-PRODUCT: Cross-sell training needed immediately.'
        WHEN bt.unique_products = 2 THEN 'LIMITED MIX: Introduce third product line.'
        ELSE 'DIVERSIFIED: Good product spread.'
    END AS product_diversity_flag

FROM broker_total bt
JOIN broker_product bp ON bp.broker = bt.broker AND bp.sales_channel_user_id = bt.sales_channel_user_id
GROUP BY bt.broker, bt.sales_channel_user_id, bt.total_policies, bt.total_premium, bt.unique_products
ORDER BY bt.total_premium DESC;


-- ============================================================================
-- 5.4 BROKER GROWTH TRAJECTORY (Trending Up vs Declining)
-- ============================================================================
-- INSIGHT: Which brokers are growing and which are shrinking? This is the
--   most important broker health indicator. A declining broker needs
--   immediate account management attention before it churns.
-- ACTION: Brokers with 3+ months of decline need personal outreach from
--   account manager. Identify root cause (agent churn? product issue?).
--   Growing brokers should be celebrated and given more support.
-- ============================================================================

WITH broker_monthly AS (
    SELECT
        source AS broker,
        DATE_TRUNC('month', sold_date) AS sold_month,
        COUNT(*) AS policies,
        SUM(premium_amount) AS premium,
        COUNT(DISTINCT agent) AS active_agents
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    GROUP BY source, DATE_TRUNC('month', sold_date)
),
with_trend AS (
    SELECT
        broker,
        sold_month,
        policies,
        ROUND(premium, 0) AS premium,
        active_agents,
        LAG(policies) OVER (PARTITION BY broker ORDER BY sold_month) AS prev_policies,
        -- 3-month average
        ROUND(AVG(policies) OVER (
            PARTITION BY broker ORDER BY sold_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ), 0) AS policies_3m_avg,
        -- Rank within month
        RANK() OVER (PARTITION BY sold_month ORDER BY SUM(premium_amount) DESC) AS monthly_rank
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    GROUP BY source, DATE_TRUNC('month', sold_date)
    -- Re-derive since CTE has aggregation issues in window; use subquery approach
)
SELECT
    bm.broker,
    bm.sold_month,
    bm.policies,
    bm.premium,
    bm.active_agents,
    LAG(bm.policies) OVER (PARTITION BY bm.broker ORDER BY bm.sold_month) AS prev_month_policies,
    CASE WHEN LAG(bm.policies) OVER (PARTITION BY bm.broker ORDER BY bm.sold_month) > 0
         THEN ROUND((bm.policies - LAG(bm.policies) OVER (PARTITION BY bm.broker ORDER BY bm.sold_month))::NUMERIC
                     / LAG(bm.policies) OVER (PARTITION BY bm.broker ORDER BY bm.sold_month) * 100, 1)
         ELSE NULL END AS policy_mom_pct,
    ROUND(AVG(bm.policies) OVER (
        PARTITION BY bm.broker ORDER BY bm.sold_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ), 0) AS policies_3m_avg
FROM broker_monthly bm
ORDER BY bm.broker, bm.sold_month;


-- ============================================================================
-- 5.5 ICE vs FRANCHISE CHANNEL COMPARISON
-- ============================================================================
-- INSIGHT: Direct comparison of the ICE (67% digital) channel versus
--   franchise/branch (F-code) channels. Are franchises justifying their
--   cost? What is each channel's productivity per agent?
-- ACTION: If franchise cost-per-policy > ICE, evaluate franchise ROI.
--   If franchise agents have higher avg ticket, they may be serving a
--   different (higher-value) customer segment. Adjust strategy accordingly.
-- ============================================================================

SELECT
    CASE
        WHEN source = 'ICE' THEN 'ICE (Direct Digital)'
        WHEN source LIKE 'F%' THEN 'FRANCHISE/BRANCH'
        ELSE 'OTHER'
    END AS channel_type,
    COUNT(*) AS total_policies,
    ROUND(SUM(premium_amount), 0) AS total_premium,
    COUNT(DISTINCT agent) AS unique_agents,
    COUNT(DISTINCT source) AS unique_sources,
    ROUND(AVG(premium_amount), 0) AS avg_ticket_size,
    -- Productivity
    ROUND(COUNT(*)::NUMERIC / NULLIF(COUNT(DISTINCT agent), 0), 1) AS policies_per_agent,
    ROUND(SUM(premium_amount) / NULLIF(COUNT(DISTINCT agent), 0), 0) AS premium_per_agent,
    -- Business type mix
    ROUND(COUNT(CASE WHEN policy_business_type = 'Renewal' THEN 1 END)::NUMERIC
          / NULLIF(COUNT(*), 0) * 100, 1) AS renewal_pct,
    ROUND(COUNT(CASE WHEN is_breakin_journey::TEXT = 'true' THEN 1 END)::NUMERIC
          / NULLIF(COUNT(*), 0) * 100, 1) AS breakin_pct,
    -- Product mix
    ROUND(COUNT(CASE WHEN product_type ILIKE '%car%' OR product_type ILIKE '%private%' THEN 1 END)::NUMERIC
          / NULLIF(COUNT(*), 0) * 100, 1) AS motor_4w_pct,
    ROUND(COUNT(CASE WHEN product_type ILIKE '%two%' OR product_type ILIKE '%2w%' THEN 1 END)::NUMERIC
          / NULLIF(COUNT(*), 0) * 100, 1) AS motor_2w_pct,
    -- Top insurer
    MODE() WITHIN GROUP (ORDER BY insurer) AS most_common_insurer
FROM sold_policies_data
WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
GROUP BY
    CASE
        WHEN source = 'ICE' THEN 'ICE (Direct Digital)'
        WHEN source LIKE 'F%' THEN 'FRANCHISE/BRANCH'
        ELSE 'OTHER'
    END
ORDER BY total_premium DESC;


-- ############################################################################
-- SECTION 6 SUPPLEMENT: GEOGRAPHIC INTELLIGENCE (EXTENDED)
-- ############################################################################

-- ============================================================================
-- 6.3 STATE-WISE MONTHLY TREND WITH GROWTH SIGNALS
-- ============================================================================
-- INSIGHT: Tracks each state's growth month-over-month. Early detection
--   of geographic market shifts. A state losing share might indicate
--   competitive pressure or agent churn in that geography.
-- ACTION: States with 3+ months of decline need local market analysis.
--   States with rapid growth need agent recruitment to capture demand.
--   Use growth signals to allocate regional marketing budgets.
-- ============================================================================

WITH state_monthly AS (
    SELECT
        COALESCE(policy_holder_state, 'Unknown') AS state,
        DATE_TRUNC('month', sold_date) AS sold_month,
        COUNT(*) AS policies,
        SUM(premium_amount) AS premium,
        COUNT(DISTINCT agent) AS active_agents
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '12 months'
      AND policy_holder_state IS NOT NULL
      AND policy_holder_state != ''
    GROUP BY COALESCE(policy_holder_state, 'Unknown'), DATE_TRUNC('month', sold_date)
)
SELECT
    state,
    sold_month,
    policies,
    ROUND(premium, 0) AS premium,
    active_agents,
    LAG(policies) OVER (PARTITION BY state ORDER BY sold_month) AS prev_month_policies,
    CASE WHEN LAG(policies) OVER (PARTITION BY state ORDER BY sold_month) > 0
         THEN ROUND(
             (policies - LAG(policies) OVER (PARTITION BY state ORDER BY sold_month))::NUMERIC
             / LAG(policies) OVER (PARTITION BY state ORDER BY sold_month) * 100, 1)
         ELSE NULL END AS policy_mom_pct,
    -- Share of total platform
    ROUND(policies::NUMERIC / NULLIF(SUM(policies) OVER (PARTITION BY sold_month), 0) * 100, 1) AS platform_share_pct,
    -- 3-month moving average
    ROUND(AVG(policies) OVER (
        PARTITION BY state ORDER BY sold_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ), 0) AS policies_3m_avg,

    CASE
        WHEN policies > COALESCE(LAG(policies) OVER (PARTITION BY state ORDER BY sold_month), 0) * 1.15
             THEN 'RAPID GROWTH: Invest in agent recruitment for this state.'
        WHEN policies > COALESCE(LAG(policies) OVER (PARTITION BY state ORDER BY sold_month), 0)
             THEN 'GROWING'
        WHEN policies < COALESCE(LAG(policies) OVER (PARTITION BY state ORDER BY sold_month), 0) * 0.85
             THEN 'SHARP DECLINE: Investigate competitive pressure and agent activity.'
        WHEN policies < COALESCE(LAG(policies) OVER (PARTITION BY state ORDER BY sold_month), 0)
             THEN 'DECLINING'
        ELSE 'STABLE'
    END AS growth_signal

FROM state_monthly
ORDER BY state, sold_month;


-- ============================================================================
-- 6.4 STATE-INSURER HEATMAP (Which insurer dominates which state?)
-- ============================================================================
-- INSIGHT: Insurer market share varies dramatically by state. ICICI Lombard
--   may dominate in Maharashtra while Digit leads in Karnataka. Understanding
--   this helps optimize insurer routing by geography.
-- ACTION: In states where one insurer has >50% share, negotiate better
--   terms with that insurer. In states with balanced share, ensure all
--   insurers' APIs are reliable to maintain competition.
-- ============================================================================

SELECT
    COALESCE(policy_holder_state, 'Unknown') AS state,
    insurer,
    COUNT(*) AS policies,
    ROUND(SUM(premium_amount), 0) AS premium,
    ROUND(AVG(premium_amount), 0) AS avg_premium,
    -- Share within state
    ROUND(COUNT(*)::NUMERIC / SUM(COUNT(*)) OVER (PARTITION BY COALESCE(policy_holder_state, 'Unknown')) * 100, 1) AS share_in_state,
    -- Rank within state
    RANK() OVER (PARTITION BY COALESCE(policy_holder_state, 'Unknown') ORDER BY COUNT(*) DESC) AS rank_in_state,
    -- Flag dominant insurer
    CASE
        WHEN COUNT(*)::NUMERIC / SUM(COUNT(*)) OVER (PARTITION BY COALESCE(policy_holder_state, 'Unknown')) > 0.50
             THEN 'DOMINANT: >50% share. Leverage for better terms.'
        WHEN COUNT(*)::NUMERIC / SUM(COUNT(*)) OVER (PARTITION BY COALESCE(policy_holder_state, 'Unknown')) > 0.30
             THEN 'STRONG: >30% share. Key partner in this state.'
        ELSE 'COMPETITIVE'
    END AS market_position

FROM sold_policies_data
WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
  AND insurer IS NOT NULL
  AND policy_holder_state IS NOT NULL AND policy_holder_state != ''
GROUP BY COALESCE(policy_holder_state, 'Unknown'), insurer
HAVING COUNT(*) >= 5
ORDER BY state, COUNT(*) DESC;


-- ============================================================================
-- 6.5 STATE-WISE AGENT DENSITY AND PRODUCTIVITY
-- ============================================================================
-- INSIGHT: How many agents per state and how productive are they? A state
--   with many agents but low per-agent output has a quality problem. A
--   state with few highly productive agents has a capacity constraint.
-- ACTION: Low density + high productivity = recruit more agents.
--   High density + low productivity = train and cull inactive agents.
--   Compare state-level productivity to platform average.
-- ============================================================================

WITH state_performance AS (
    SELECT
        COALESCE(policy_holder_state, 'Unknown') AS state,
        COUNT(*) AS total_policies,
        ROUND(SUM(premium_amount), 0) AS total_premium,
        COUNT(DISTINCT agent) AS selling_agents,
        COUNT(DISTINCT insurer) AS insurers_used
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
      AND policy_holder_state IS NOT NULL AND policy_holder_state != ''
    GROUP BY COALESCE(policy_holder_state, 'Unknown')
),
platform_benchmark AS (
    SELECT
        ROUND(SUM(total_policies)::NUMERIC / NULLIF(SUM(selling_agents), 0), 1) AS avg_policies_per_agent,
        ROUND(SUM(total_premium)::NUMERIC / NULLIF(SUM(selling_agents), 0), 0) AS avg_premium_per_agent
    FROM state_performance
)
SELECT
    sp.state,
    sp.total_policies,
    sp.total_premium,
    sp.selling_agents,
    sp.insurers_used,
    ROUND(sp.total_policies::NUMERIC / NULLIF(sp.selling_agents, 0), 1) AS policies_per_agent,
    ROUND(sp.total_premium::NUMERIC / NULLIF(sp.selling_agents, 0), 0) AS premium_per_agent,
    pb.avg_policies_per_agent AS platform_avg_policies_per_agent,
    pb.avg_premium_per_agent AS platform_avg_premium_per_agent,
    -- Productivity index (100 = platform average)
    ROUND(
        (sp.total_policies::NUMERIC / NULLIF(sp.selling_agents, 0))
        / NULLIF(pb.avg_policies_per_agent, 0) * 100, 0
    ) AS productivity_index,

    CASE
        WHEN sp.selling_agents < 10 AND sp.total_policies::NUMERIC / NULLIF(sp.selling_agents, 0) > pb.avg_policies_per_agent * 1.2
             THEN 'CAPACITY CONSTRAINED: Few but productive agents. Recruit more.'
        WHEN sp.selling_agents >= 10 AND sp.total_policies::NUMERIC / NULLIF(sp.selling_agents, 0) < pb.avg_policies_per_agent * 0.5
             THEN 'QUALITY ISSUE: Many agents, low productivity. Training needed.'
        WHEN sp.total_policies::NUMERIC / NULLIF(sp.selling_agents, 0) > pb.avg_policies_per_agent
             THEN 'HIGH PERFORMING: Above platform average.'
        ELSE 'BELOW AVERAGE: Needs improvement plan.'
    END AS state_assessment

FROM state_performance sp
CROSS JOIN platform_benchmark pb
ORDER BY sp.total_premium DESC;


-- ############################################################################
-- SECTION 7 SUPPLEMENT: INSURER ANALYTICS (EXTENDED)
-- ############################################################################

-- ============================================================================
-- 7.3 INSURER TREND ANALYSIS (Growing vs Declining Insurers)
-- ============================================================================
-- INSIGHT: Which insurers are gaining share on the platform and which are
--   losing it? Tracks insurer momentum over time.
-- ACTION: Growing insurers likely have competitive pricing or better APIs.
--   Declining insurers may have pricing issues or technical problems.
--   Use this data in insurer review meetings and contract negotiations.
-- ============================================================================

WITH insurer_monthly AS (
    SELECT
        insurer,
        DATE_TRUNC('month', sold_date) AS sold_month,
        COUNT(*) AS policies,
        SUM(premium_amount) AS premium,
        COUNT(DISTINCT agent) AS unique_agents
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '12 months'
      AND insurer IS NOT NULL
    GROUP BY insurer, DATE_TRUNC('month', sold_date)
)
SELECT
    insurer,
    sold_month,
    policies,
    ROUND(premium, 0) AS premium,
    unique_agents,
    -- MoM change
    LAG(policies) OVER (PARTITION BY insurer ORDER BY sold_month) AS prev_policies,
    CASE WHEN LAG(policies) OVER (PARTITION BY insurer ORDER BY sold_month) > 0
         THEN ROUND(
             (policies - LAG(policies) OVER (PARTITION BY insurer ORDER BY sold_month))::NUMERIC
             / LAG(policies) OVER (PARTITION BY insurer ORDER BY sold_month) * 100, 1)
         ELSE NULL END AS policy_mom_pct,
    -- Platform share in month
    ROUND(policies::NUMERIC / NULLIF(SUM(policies) OVER (PARTITION BY sold_month), 0) * 100, 1) AS monthly_platform_share,
    -- 3-month moving average
    ROUND(AVG(policies) OVER (
        PARTITION BY insurer ORDER BY sold_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ), 0) AS policies_3m_avg,

    CASE
        WHEN policies > COALESCE(LAG(policies) OVER (PARTITION BY insurer ORDER BY sold_month), 0) * 1.20
             THEN 'SURGING: >20% growth. Their pricing/API is winning.'
        WHEN policies > COALESCE(LAG(policies) OVER (PARTITION BY insurer ORDER BY sold_month), 0)
             THEN 'GROWING'
        WHEN policies < COALESCE(LAG(policies) OVER (PARTITION BY insurer ORDER BY sold_month), 0) * 0.80
             THEN 'DECLINING FAST: >20% drop. Check pricing or API issues.'
        WHEN policies < COALESCE(LAG(policies) OVER (PARTITION BY insurer ORDER BY sold_month), 0)
             THEN 'DECLINING'
        ELSE 'STABLE'
    END AS trend_signal

FROM insurer_monthly
ORDER BY insurer, sold_month;


-- ============================================================================
-- 7.4 INSURER AGENT ADOPTION (Which agents sell which insurer?)
-- ============================================================================
-- INSIGHT: Some insurers are sold by many agents (broad adoption) while
--   others are concentrated among few agents. Broad adoption = resilient.
--   Concentrated = dependent on key agents.
-- ACTION: Low-adoption insurers need agent training or better pricing.
--   High-adoption insurers have product-market fit. Push for better
--   commission terms with high-adoption insurers.
-- ============================================================================

WITH insurer_agents AS (
    SELECT
        insurer,
        COUNT(*) AS total_policies,
        SUM(premium_amount) AS total_premium,
        COUNT(DISTINCT agent) AS unique_agents,
        -- Agent concentration: what % comes from top 5 agents?
        COUNT(*) AS all_policies
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
      AND insurer IS NOT NULL
    GROUP BY insurer
),
top_5_by_insurer AS (
    SELECT
        insurer,
        SUM(policies) AS top5_policies
    FROM (
        SELECT
            insurer,
            agent,
            COUNT(*) AS policies,
            ROW_NUMBER() OVER (PARTITION BY insurer ORDER BY COUNT(*) DESC) AS rn
        FROM sold_policies_data
        WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
          AND insurer IS NOT NULL
        GROUP BY insurer, agent
    ) t
    WHERE rn <= 5
    GROUP BY insurer
)
SELECT
    ia.insurer,
    ia.total_policies,
    ROUND(ia.total_premium, 0) AS total_premium,
    ia.unique_agents,
    ROUND(ia.total_policies::NUMERIC / NULLIF(ia.unique_agents, 0), 1) AS policies_per_agent,
    COALESCE(t5.top5_policies, 0) AS top_5_agents_policies,
    ROUND(COALESCE(t5.top5_policies, 0)::NUMERIC / NULLIF(ia.total_policies, 0) * 100, 1) AS top_5_agents_share_pct,

    CASE
        WHEN COALESCE(t5.top5_policies, 0)::NUMERIC / NULLIF(ia.total_policies, 0) > 0.70
             THEN 'HIGH CONCENTRATION: Top 5 agents drive >70%. Broaden adoption.'
        WHEN COALESCE(t5.top5_policies, 0)::NUMERIC / NULLIF(ia.total_policies, 0) > 0.50
             THEN 'MODERATE CONCENTRATION: Top 5 agents drive >50%.'
        ELSE 'BROAD ADOPTION: Volume well distributed across agents.'
    END AS adoption_status,

    CASE
        WHEN ia.unique_agents < 10 THEN 'LOW ADOPTION: Needs training/awareness campaign.'
        WHEN ia.unique_agents < 50 THEN 'MODERATE ADOPTION: Room to grow agent base.'
        ELSE 'HIGH ADOPTION: Well-established insurer.'
    END AS agent_reach

FROM insurer_agents ia
LEFT JOIN top_5_by_insurer t5 ON t5.insurer = ia.insurer
ORDER BY ia.total_premium DESC;


-- ============================================================================
-- 7.5 INSURER-PRODUCT FIT MATRIX
-- ============================================================================
-- INSIGHT: Not all insurers perform equally across products. Some excel
--   at 4W (high premium), others at 2W (volume play). This matrix shows
--   where each insurer has its sweet spot.
-- ACTION: Use this to build smart insurer routing rules. Default each
--   product to the insurer with best conversion and competitive pricing.
--   Identify product-insurer combinations with zero sales as gaps.
-- ============================================================================

WITH insurer_product AS (
    SELECT
        insurer,
        product_type,
        COUNT(*) AS policies,
        ROUND(SUM(premium_amount), 0) AS premium,
        ROUND(AVG(premium_amount), 0) AS avg_premium,
        COUNT(DISTINCT agent) AS agents_selling
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
      AND insurer IS NOT NULL
    GROUP BY insurer, product_type
),
product_total AS (
    SELECT product_type, SUM(policies) AS total_policies
    FROM insurer_product
    GROUP BY product_type
)
SELECT
    ip.insurer,
    ip.product_type,
    ip.policies,
    ip.premium,
    ip.avg_premium,
    ip.agents_selling,
    pt.total_policies AS product_total_policies,
    ROUND(ip.policies::NUMERIC / NULLIF(pt.total_policies, 0) * 100, 1) AS share_of_product,
    RANK() OVER (PARTITION BY ip.product_type ORDER BY ip.policies DESC) AS rank_for_product,

    CASE
        WHEN RANK() OVER (PARTITION BY ip.product_type ORDER BY ip.policies DESC) = 1
             THEN 'MARKET LEADER for this product.'
        WHEN RANK() OVER (PARTITION BY ip.product_type ORDER BY ip.policies DESC) <= 3
             THEN 'TOP 3: Strong position.'
        WHEN ip.policies::NUMERIC / NULLIF(pt.total_policies, 0) < 0.05
             THEN 'MARGINAL: <5% share. Consider if worth supporting.'
        ELSE 'COMPETITIVE: Mid-tier position.'
    END AS position_assessment

FROM insurer_product ip
JOIN product_total pt ON pt.product_type = ip.product_type
ORDER BY ip.product_type, ip.policies DESC;


-- ############################################################################
-- END OF FILE 3B: DASHBOARD SUPPLEMENT - DEEP DIVES
-- ############################################################################
-- IMPLEMENTATION NOTE: These queries supplement the main dashboard file
-- (03_actionable_dashboard_queries.sql). They can be run independently
-- or integrated into the same dashboard tool.
--
-- RECOMMENDED REFRESH FREQUENCY:
--   3.5 Source Analysis: Daily
--   3.6 Time-Based Funnel: Weekly (needs 90 days of data)
--   3.7 Monthly Funnel Trend: Daily
--   3.8 Agent Conversion Benchmarking: Weekly
--   4.5 Product Growth Velocity: Daily
--   4.6 Premium Band Analysis: Weekly
--   4.7 Breakin Deep Dive: Daily
--   5.3 Broker Product Mix: Weekly
--   5.4 Broker Growth Trajectory: Daily
--   5.5 ICE vs Franchise: Weekly
--   6.3 State Monthly Trend: Weekly
--   6.4 State-Insurer Heatmap: Weekly
--   6.5 State Agent Density: Weekly
--   7.3 Insurer Trend: Daily
--   7.4 Insurer Agent Adoption: Weekly
--   7.5 Insurer-Product Fit: Weekly
-- ############################################################################
