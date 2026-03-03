-- ============================================================================
-- FILE 2: COMPREHENSIVE BROKER SCORECARD QUERIES
-- ============================================================================
-- InsurTech Distribution Platform - Broker Performance Analytics
-- PostgreSQL 14+
--
-- PURPOSE: Provide complete visibility into broker partner performance.
-- With 43 broker partners and Spinny driving 55% of volume, broker analytics
-- is critical for risk management and growth strategy.
--
-- TABLES USED:
--   EXISTING: sold_policies_data, users, channel_wise_monthly_activity_summary,
--             channel_wise_monthly_sold_policies, daily_quote_counts,
--             agent_wise_monthly_activity_summary
--   NEW (from 01_new_tables_schema.sql): broker_scorecard_monthly (for write)
--
-- NOTE: All queries use existing tables unless explicitly marked [NEW TABLE].
-- ============================================================================


-- ============================================================================
-- QUERY 1: OVERALL BROKER PERFORMANCE RANKING
-- ============================================================================
-- INSIGHT: Ranks all 43 brokers by composite score incorporating volume,
--   conversion efficiency, agent activation, and premium quality.
--
-- ACTION: Use this ranking for quarterly business reviews. Brokers in bottom
--   quartile need intervention plans. Brokers with high quotes but low
--   conversion need sales process audits. Top brokers should be studied for
--   best practices to replicate.
--
-- THRESHOLDS:
--   - Platinum: top 5% by score (typically 2-3 brokers)
--   - Gold: top 20%
--   - Silver: top 50%
--   - Bronze: bottom 50% with activity
--   - Inactive: zero policies in last 3 months
--   - ALERT: Any single broker > 40% of total volume = critical concentration risk
-- ============================================================================

WITH broker_policies AS (
    SELECT
        sales_channel_user_id AS channel_id,
        source AS broker_name,
        COUNT(*) AS total_policies,
        SUM(premium_amount) AS total_premium,
        SUM(net_premium) AS total_net_premium,
        AVG(premium_amount) AS avg_premium,
        COUNT(DISTINCT agent) AS unique_agents_selling,
        COUNT(CASE WHEN sold_date >= CURRENT_DATE - INTERVAL '3 months' THEN 1 END) AS policies_last_3m,
        SUM(CASE WHEN sold_date >= CURRENT_DATE - INTERVAL '3 months' THEN premium_amount ELSE 0 END) AS premium_last_3m,
        COUNT(CASE WHEN sold_date >= CURRENT_DATE - INTERVAL '1 month' THEN 1 END) AS policies_last_1m,
        SUM(CASE WHEN sold_date >= CURRENT_DATE - INTERVAL '1 month' THEN premium_amount ELSE 0 END) AS premium_last_1m,
        COUNT(CASE WHEN product_type ILIKE '%car%' OR product_type ILIKE '%4w%' OR product_type ILIKE '%private%' THEN 1 END) AS policies_4w,
        COUNT(CASE WHEN product_type ILIKE '%two%' OR product_type ILIKE '%2w%' THEN 1 END) AS policies_2w,
        COUNT(CASE WHEN product_type ILIKE '%health%' THEN 1 END) AS policies_health,
        COUNT(CASE WHEN is_breakin_journey = TRUE OR is_breakin_journey::TEXT = 'true' THEN 1 END) AS breakin_policies,
        COUNT(CASE WHEN policy_business_type = 'New Policy' THEN 1 END) AS new_policies,
        COUNT(CASE WHEN policy_business_type = 'Renewal' THEN 1 END) AS renewal_policies,
        COUNT(CASE WHEN policy_business_type = 'Roll Over' THEN 1 END) AS rollover_policies,
        MIN(sold_date) AS first_sale_date,
        MAX(sold_date) AS last_sale_date
    FROM sold_policies_data
    WHERE sales_channel_user_id IS NOT NULL
    GROUP BY sales_channel_user_id, source
),
broker_agents AS (
    -- Total agents assigned to each broker
    SELECT
        saleschanneluserid AS channel_id,
        COUNT(*) AS total_agents,
        COUNT(CASE WHEN lastlogin >= CURRENT_DATE - INTERVAL '30 days' THEN 1 END) AS recently_active_agents
    FROM users
    WHERE saleschanneluserid IS NOT NULL
      AND deletedat IS NULL
    GROUP BY saleschanneluserid
),
broker_quotes AS (
    -- Aggregate quote data per broker via agent mapping
    SELECT
        u.saleschanneluserid AS channel_id,
        SUM(dq.quote_count) AS total_quotes,
        SUM(CASE WHEN dq.quote_date >= CURRENT_DATE - INTERVAL '3 months' THEN dq.quote_count ELSE 0 END) AS quotes_last_3m,
        COUNT(DISTINCT dq.agent_id) AS quoting_agents
    FROM daily_quote_counts dq
    JOIN users u ON u.id = dq.agent_id
    WHERE u.saleschanneluserid IS NOT NULL
    GROUP BY u.saleschanneluserid
),
platform_totals AS (
    SELECT
        COUNT(*) AS total_platform_policies,
        SUM(premium_amount) AS total_platform_premium
    FROM sold_policies_data
),
scored AS (
    SELECT
        bp.channel_id,
        COALESCE(bp.broker_name, 'Unknown') AS broker_name,
        bp.total_policies,
        bp.total_premium,
        bp.total_net_premium,
        bp.avg_premium,
        bp.policies_last_3m,
        bp.premium_last_3m,
        bp.policies_last_1m,
        bp.premium_last_1m,
        COALESCE(ba.total_agents, 0) AS total_agents,
        bp.unique_agents_selling,
        COALESCE(ba.recently_active_agents, 0) AS recently_active_agents,
        COALESCE(bq.total_quotes, 0) AS total_quotes,
        COALESCE(bq.quoting_agents, 0) AS quoting_agents,

        -- Conversion rate: policies / quotes (%)
        CASE WHEN COALESCE(bq.total_quotes, 0) > 0
             THEN ROUND(bp.total_policies::NUMERIC / bq.total_quotes * 100, 2)
             ELSE 0 END AS overall_conversion_rate,

        -- Agent activation rate: agents with sales / total agents (%)
        CASE WHEN COALESCE(ba.total_agents, 0) > 0
             THEN ROUND(bp.unique_agents_selling::NUMERIC / ba.total_agents * 100, 2)
             ELSE 0 END AS agent_activation_rate,

        -- Policies per active agent (efficiency)
        CASE WHEN bp.unique_agents_selling > 0
             THEN ROUND(bp.total_policies::NUMERIC / bp.unique_agents_selling, 1)
             ELSE 0 END AS policies_per_active_agent,

        -- Platform share
        ROUND(bp.total_policies::NUMERIC / pt.total_platform_policies * 100, 2) AS platform_policy_share_pct,
        ROUND(bp.total_premium / pt.total_platform_premium * 100, 2) AS platform_premium_share_pct,

        -- Product mix
        bp.policies_4w,
        bp.policies_2w,
        bp.policies_health,
        bp.breakin_policies,
        bp.new_policies,
        bp.renewal_policies,
        bp.rollover_policies,

        -- Product diversity: Herfindahl Index (lower = more diverse)
        -- Transform to 0-100 score where 100 = perfectly diverse
        CASE WHEN bp.total_policies > 0
             THEN ROUND(
                (1 - (
                    POWER(bp.policies_4w::NUMERIC / bp.total_policies, 2) +
                    POWER(bp.policies_2w::NUMERIC / bp.total_policies, 2) +
                    POWER(COALESCE(bp.policies_health, 0)::NUMERIC / GREATEST(bp.total_policies, 1), 2) +
                    POWER(GREATEST(bp.total_policies - bp.policies_4w - bp.policies_2w - COALESCE(bp.policies_health, 0), 0)::NUMERIC / GREATEST(bp.total_policies, 1), 2)
                )) * 100, 2)
             ELSE 0 END AS product_diversity_score,

        bp.first_sale_date,
        bp.last_sale_date

    FROM broker_policies bp
    CROSS JOIN platform_totals pt
    LEFT JOIN broker_agents ba ON ba.channel_id = bp.channel_id
    LEFT JOIN broker_quotes bq ON bq.channel_id = bp.channel_id
)
SELECT
    *,
    -- Tier classification
    CASE
        WHEN policies_last_3m = 0 THEN 'Inactive'
        WHEN PERCENT_RANK() OVER (ORDER BY total_premium) >= 0.95 THEN 'Platinum'
        WHEN PERCENT_RANK() OVER (ORDER BY total_premium) >= 0.80 THEN 'Gold'
        WHEN PERCENT_RANK() OVER (ORDER BY total_premium) >= 0.50 THEN 'Silver'
        ELSE 'Bronze'
    END AS broker_tier,

    -- Concentration risk flag
    CASE
        WHEN platform_policy_share_pct >= 40 THEN 'CRITICAL - Single broker dependency'
        WHEN platform_policy_share_pct >= 25 THEN 'HIGH - Significant concentration'
        WHEN platform_policy_share_pct >= 15 THEN 'MEDIUM - Monitor closely'
        ELSE 'LOW'
    END AS concentration_risk,

    -- Overall ranking
    DENSE_RANK() OVER (ORDER BY total_premium DESC) AS premium_rank,
    DENSE_RANK() OVER (ORDER BY total_policies DESC) AS volume_rank,
    DENSE_RANK() OVER (ORDER BY overall_conversion_rate DESC) AS conversion_rank,
    DENSE_RANK() OVER (ORDER BY agent_activation_rate DESC) AS activation_rank

FROM scored
ORDER BY total_premium DESC;


-- ============================================================================
-- QUERY 2: MONTH-OVER-MONTH BROKER TREND ANALYSIS
-- ============================================================================
-- INSIGHT: Shows each broker's monthly trajectory over the past 12 months.
--   Identifies brokers that are growing vs declining vs stagnating.
--
-- ACTION:
--   - Declining brokers (3+ consecutive months of decline): Schedule urgent
--     partner meeting to diagnose issues
--   - Stagnating brokers: Review product offerings, provide new campaigns
--   - Growing brokers: Double down with more agent allocation and marketing
--
-- THRESHOLD: A broker declining >20% MoM for 2+ months = immediate escalation
-- ============================================================================

WITH monthly_data AS (
    SELECT
        sales_channel_id,
        broker_name,
        sold_month,
        policy_count,
        total_premium,
        LAG(policy_count) OVER (PARTITION BY sales_channel_id ORDER BY sold_month) AS prev_month_policies,
        LAG(total_premium) OVER (PARTITION BY sales_channel_id ORDER BY sold_month) AS prev_month_premium,

        -- 3-month moving average for smoothing
        AVG(policy_count) OVER (
            PARTITION BY sales_channel_id
            ORDER BY sold_month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ) AS policies_3m_avg,

        AVG(total_premium) OVER (
            PARTITION BY sales_channel_id
            ORDER BY sold_month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ) AS premium_3m_avg

    FROM channel_wise_monthly_sold_policies
    WHERE sold_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '12 months'
)
SELECT
    sales_channel_id,
    broker_name,
    sold_month,
    policy_count,
    total_premium,
    prev_month_policies,
    prev_month_premium,

    -- Month-over-month change
    CASE WHEN prev_month_policies > 0
         THEN ROUND((policy_count - prev_month_policies)::NUMERIC / prev_month_policies * 100, 1)
         ELSE NULL END AS policy_mom_change_pct,
    CASE WHEN prev_month_premium > 0
         THEN ROUND((total_premium - prev_month_premium)::NUMERIC / prev_month_premium * 100, 1)
         ELSE NULL END AS premium_mom_change_pct,

    ROUND(policies_3m_avg, 1) AS policies_3m_avg,
    ROUND(premium_3m_avg, 0) AS premium_3m_avg,

    -- Trend direction indicator
    CASE
        WHEN policy_count > COALESCE(prev_month_policies, 0) * 1.1 THEN 'GROWING'
        WHEN policy_count < COALESCE(prev_month_policies, 0) * 0.9 THEN 'DECLINING'
        ELSE 'STABLE'
    END AS trend_direction

FROM monthly_data
ORDER BY broker_name, sold_month;


-- ============================================================================
-- QUERY 3: PRODUCT MIX PER BROKER (with diversification scoring)
-- ============================================================================
-- INSIGHT: Shows how dependent each broker is on a single product type.
--   Most brokers are expected to be 90%+ Private Car. Identifies which
--   brokers have potential for diversification.
--
-- ACTION:
--   - Brokers with 99-100% single-product: Launch targeted diversification
--     campaign (e.g., offer health cross-sell incentives)
--   - Brokers with some 2W volume: Expand 2W push
--   - Any broker with health sales: Study their model and replicate
--
-- THRESHOLD: Product diversity score < 10 = "dangerously concentrated"
-- ============================================================================

WITH broker_product_data AS (
    SELECT
        cwms.sales_channel_id,
        cwms.broker_name,
        cwms.product_type,
        SUM(cwms.policy_count) AS total_policies,
        SUM(cwms.total_premium) AS total_premium
    FROM channel_wise_monthly_sold_policies cwms
    WHERE cwms.sold_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    GROUP BY cwms.sales_channel_id, cwms.broker_name, cwms.product_type
),
broker_totals AS (
    SELECT
        sales_channel_id,
        broker_name,
        SUM(total_policies) AS broker_total_policies,
        SUM(total_premium) AS broker_total_premium
    FROM broker_product_data
    GROUP BY sales_channel_id, broker_name
)
SELECT
    bt.sales_channel_id,
    bt.broker_name,
    bt.broker_total_policies,
    bt.broker_total_premium,
    bpd.product_type,
    bpd.total_policies AS product_policies,
    bpd.total_premium AS product_premium,
    ROUND(bpd.total_policies::NUMERIC / NULLIF(bt.broker_total_policies, 0) * 100, 1) AS product_policy_pct,
    ROUND(bpd.total_premium / NULLIF(bt.broker_total_premium, 0) * 100, 1) AS product_premium_pct,

    -- Product concentration flag
    CASE
        WHEN bpd.total_policies::NUMERIC / NULLIF(bt.broker_total_policies, 0) > 0.95 THEN 'MONO-PRODUCT (>95%)'
        WHEN bpd.total_policies::NUMERIC / NULLIF(bt.broker_total_policies, 0) > 0.80 THEN 'HEAVILY CONCENTRATED (>80%)'
        WHEN bpd.total_policies::NUMERIC / NULLIF(bt.broker_total_policies, 0) > 0.50 THEN 'PRIMARY PRODUCT (>50%)'
        ELSE 'DIVERSIFIED (<50%)'
    END AS product_concentration

FROM broker_totals bt
JOIN broker_product_data bpd ON bpd.sales_channel_id = bt.sales_channel_id AND bpd.broker_name = bt.broker_name
ORDER BY bt.broker_total_premium DESC, bpd.total_premium DESC;


-- ============================================================================
-- QUERY 4: AGENT EFFICIENCY PER BROKER
-- ============================================================================
-- INSIGHT: Measures how productive agents are within each broker's channel.
--   A broker with 5,000 agents but only 50 active is very different from
--   a broker with 100 agents and 50 active.
--
-- ACTION:
--   - Low activation rate (< 5%): Broker's agent onboarding is broken.
--     Schedule joint training programs.
--   - High agents, low efficiency: Agent quality issue. Tighten onboarding
--     criteria or invest in training.
--   - High efficiency, few agents: Growth opportunity. Help broker recruit
--     more agents.
--
-- THRESHOLDS:
--   - Agent activation rate: Good > 10%, Acceptable > 5%, Poor < 5%
--   - Policies per active agent per month: Good > 20, Acceptable > 10, Poor < 5
-- ============================================================================

WITH broker_agent_counts AS (
    SELECT
        u.saleschanneluserid AS channel_id,
        COUNT(*) AS total_agents,
        COUNT(CASE WHEN u.lastlogin >= CURRENT_DATE - INTERVAL '30 days' THEN 1 END) AS logged_in_30d,
        COUNT(CASE WHEN u.lastlogin >= CURRENT_DATE - INTERVAL '7 days' THEN 1 END) AS logged_in_7d
    FROM users u
    WHERE u.saleschanneluserid IS NOT NULL AND u.deletedat IS NULL
    GROUP BY u.saleschanneluserid
),
broker_sales_last_month AS (
    SELECT
        sales_channel_user_id AS channel_id,
        source AS broker_name,
        COUNT(*) AS policies_last_month,
        SUM(premium_amount) AS premium_last_month,
        COUNT(DISTINCT agent) AS selling_agents_last_month,
        AVG(premium_amount) AS avg_ticket_size
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month'
      AND sold_date < DATE_TRUNC('month', CURRENT_DATE)
    GROUP BY sales_channel_user_id, source
),
broker_quotes_last_month AS (
    SELECT
        u.saleschanneluserid AS channel_id,
        SUM(dq.quote_count) AS quotes_last_month,
        COUNT(DISTINCT dq.agent_id) AS quoting_agents_last_month
    FROM daily_quote_counts dq
    JOIN users u ON u.id = dq.agent_id
    WHERE dq.quote_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month'
      AND dq.quote_date < DATE_TRUNC('month', CURRENT_DATE)
    GROUP BY u.saleschanneluserid
)
SELECT
    bsl.channel_id,
    bsl.broker_name,
    COALESCE(bac.total_agents, 0) AS total_agents,
    COALESCE(bac.logged_in_30d, 0) AS agents_logged_in_30d,
    bsl.selling_agents_last_month,
    COALESCE(bql.quoting_agents_last_month, 0) AS quoting_agents_last_month,
    bsl.policies_last_month,
    bsl.premium_last_month,
    ROUND(bsl.avg_ticket_size, 0) AS avg_ticket_size,
    COALESCE(bql.quotes_last_month, 0) AS quotes_last_month,

    -- Activation rate: % of total agents who sold at least 1 policy last month
    CASE WHEN COALESCE(bac.total_agents, 0) > 0
         THEN ROUND(bsl.selling_agents_last_month::NUMERIC / bac.total_agents * 100, 2)
         ELSE 0 END AS agent_activation_rate_pct,

    -- Efficiency: policies per selling agent
    CASE WHEN bsl.selling_agents_last_month > 0
         THEN ROUND(bsl.policies_last_month::NUMERIC / bsl.selling_agents_last_month, 1)
         ELSE 0 END AS policies_per_selling_agent,

    -- Premium per selling agent
    CASE WHEN bsl.selling_agents_last_month > 0
         THEN ROUND(bsl.premium_last_month / bsl.selling_agents_last_month, 0)
         ELSE 0 END AS premium_per_selling_agent,

    -- Conversion rate
    CASE WHEN COALESCE(bql.quotes_last_month, 0) > 0
         THEN ROUND(bsl.policies_last_month::NUMERIC / bql.quotes_last_month * 100, 2)
         ELSE 0 END AS conversion_rate_pct,

    -- Quoting but not selling gap
    GREATEST(COALESCE(bql.quoting_agents_last_month, 0) - bsl.selling_agents_last_month, 0) AS agents_quoting_not_selling,

    -- Health indicators
    CASE
        WHEN COALESCE(bac.total_agents, 0) = 0 THEN 'NO AGENTS'
        WHEN bsl.selling_agents_last_month::NUMERIC / NULLIF(bac.total_agents, 0) > 0.10 THEN 'HEALTHY (>10%)'
        WHEN bsl.selling_agents_last_month::NUMERIC / NULLIF(bac.total_agents, 0) > 0.05 THEN 'ACCEPTABLE (5-10%)'
        WHEN bsl.selling_agents_last_month::NUMERIC / NULLIF(bac.total_agents, 0) > 0.01 THEN 'POOR (1-5%)'
        ELSE 'CRITICAL (<1%)'
    END AS activation_health,

    CASE
        WHEN bsl.selling_agents_last_month > 0 AND
             bsl.policies_last_month::NUMERIC / bsl.selling_agents_last_month >= 20 THEN 'HIGH EFFICIENCY'
        WHEN bsl.selling_agents_last_month > 0 AND
             bsl.policies_last_month::NUMERIC / bsl.selling_agents_last_month >= 10 THEN 'MODERATE EFFICIENCY'
        WHEN bsl.selling_agents_last_month > 0 AND
             bsl.policies_last_month::NUMERIC / bsl.selling_agents_last_month >= 5 THEN 'LOW EFFICIENCY'
        ELSE 'VERY LOW EFFICIENCY'
    END AS efficiency_rating

FROM broker_sales_last_month bsl
LEFT JOIN broker_agent_counts bac ON bac.channel_id = bsl.channel_id
LEFT JOIN broker_quotes_last_month bql ON bql.channel_id = bsl.channel_id
ORDER BY bsl.premium_last_month DESC;


-- ============================================================================
-- QUERY 5: QUOTE -> PROPOSAL -> POLICY FUNNEL PER BROKER
-- ============================================================================
-- INSIGHT: Shows where in the sales funnel each broker loses the most
--   volume. Uses agent_wise_monthly_activity_summary which has per-product
--   quote_count, proposal_count, and policy_count.
--
-- ACTION:
--   - Low Quote-to-Proposal rate: UX friction or price shock at quote stage.
--     Review insurer pricing for this broker's typical customer profile.
--   - Low Proposal-to-Policy rate: Payment or documentation bottleneck.
--     Investigate payment gateway issues or streamline document collection.
--   - Consistently low across all stages: Fundamental product-market fit
--     issue for this broker's agent/customer base.
--
-- THRESHOLDS:
--   - Quote-to-Proposal: Good > 30%, Concerning < 15%
--   - Proposal-to-Policy: Good > 50%, Concerning < 25%
--   - Overall Quote-to-Policy: Good > 15%, Concerning < 5%
-- ============================================================================

WITH broker_funnel AS (
    SELECT
        aw.sales_channel_id,
        MAX(aw.activity_month) AS latest_month,

        -- Aggregate across all product types for 4W (primary product)
        SUM(COALESCE(aw."4w_quote_count", 0)) AS total_4w_quotes,
        SUM(COALESCE(aw."4w_proposal_count", 0)) AS total_4w_proposals,
        SUM(COALESCE(aw."4w_policy_count", 0)) AS total_4w_policies,

        -- 2W funnel
        SUM(COALESCE(aw."2w_quote_count", 0)) AS total_2w_quotes,
        SUM(COALESCE(aw."2w_proposal_count", 0)) AS total_2w_proposals,
        SUM(COALESCE(aw."2w_policy_count", 0)) AS total_2w_policies,

        -- Health funnel
        SUM(COALESCE(aw.health_quote_count, 0)) AS total_health_quotes,
        SUM(COALESCE(aw.health_proposal_count, 0)) AS total_health_proposals,
        SUM(COALESCE(aw.health_policy_count, 0)) AS total_health_policies,

        -- All products combined
        SUM(
            COALESCE(aw."4w_quote_count", 0) + COALESCE(aw."2w_quote_count", 0) +
            COALESCE(aw.health_quote_count, 0) + COALESCE(aw.gcv_quote_count, 0) +
            COALESCE(aw.pcv_quote_count, 0) + COALESCE(aw.term_quote_count, 0) +
            COALESCE(aw.personal_accident_quote_count, 0) +
            COALESCE(aw.savings_quote_count, 0) + COALESCE(aw.miscd_quote_count, 0)
        ) AS total_all_quotes,

        SUM(
            COALESCE(aw."4w_proposal_count", 0) + COALESCE(aw."2w_proposal_count", 0) +
            COALESCE(aw.health_proposal_count, 0) + COALESCE(aw.gcv_proposal_count, 0) +
            COALESCE(aw.pcv_proposal_count, 0) + COALESCE(aw.term_proposal_count, 0) +
            COALESCE(aw.personal_accident_proposal_count, 0) +
            COALESCE(aw.savings_proposal_count, 0) + COALESCE(aw.miscd_proposal_count, 0)
        ) AS total_all_proposals,

        SUM(
            COALESCE(aw."4w_policy_count", 0) + COALESCE(aw."2w_policy_count", 0) +
            COALESCE(aw.health_policy_count, 0) + COALESCE(aw.gcv_policy_count, 0) +
            COALESCE(aw.pcv_policy_count, 0) + COALESCE(aw.term_policy_count, 0) +
            COALESCE(aw.personal_accident_policy_count, 0) +
            COALESCE(aw.savings_policy_count, 0) + COALESCE(aw.miscd_policy_count, 0)
        ) AS total_all_policies

    FROM agent_wise_monthly_activity_summary aw
    WHERE aw.activity_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    GROUP BY aw.sales_channel_id
),
broker_names AS (
    SELECT DISTINCT ON (sales_channel_id)
        sales_channel_id, broker_name
    FROM channel_wise_monthly_sold_policies
    ORDER BY sales_channel_id, sold_month DESC
)
SELECT
    bf.sales_channel_id,
    COALESCE(bn.broker_name, 'Unknown') AS broker_name,

    -- Overall funnel
    bf.total_all_quotes,
    bf.total_all_proposals,
    bf.total_all_policies,

    -- Conversion rates
    CASE WHEN bf.total_all_quotes > 0
         THEN ROUND(bf.total_all_proposals::NUMERIC / bf.total_all_quotes * 100, 1)
         ELSE 0 END AS quote_to_proposal_rate,

    CASE WHEN bf.total_all_proposals > 0
         THEN ROUND(bf.total_all_policies::NUMERIC / bf.total_all_proposals * 100, 1)
         ELSE 0 END AS proposal_to_policy_rate,

    CASE WHEN bf.total_all_quotes > 0
         THEN ROUND(bf.total_all_policies::NUMERIC / bf.total_all_quotes * 100, 1)
         ELSE 0 END AS overall_conversion_rate,

    -- Drop-off volumes (where volume is lost)
    bf.total_all_quotes - bf.total_all_proposals AS drop_at_proposal_stage,
    bf.total_all_proposals - bf.total_all_policies AS drop_at_policy_stage,

    -- 4W-specific funnel (since it is 96% of business)
    bf.total_4w_quotes,
    bf.total_4w_proposals,
    bf.total_4w_policies,
    CASE WHEN bf.total_4w_quotes > 0
         THEN ROUND(bf.total_4w_policies::NUMERIC / bf.total_4w_quotes * 100, 1)
         ELSE 0 END AS "4w_conversion_rate",

    -- Health funnel (tracking the dead product)
    bf.total_health_quotes,
    bf.total_health_proposals,
    bf.total_health_policies,

    -- Funnel health assessment
    CASE
        WHEN bf.total_all_quotes = 0 THEN 'NO ACTIVITY'
        WHEN bf.total_all_policies::NUMERIC / NULLIF(bf.total_all_quotes, 0) > 0.15 THEN 'HEALTHY FUNNEL'
        WHEN bf.total_all_policies::NUMERIC / NULLIF(bf.total_all_quotes, 0) > 0.05 THEN 'MODERATE FUNNEL'
        WHEN bf.total_all_policies::NUMERIC / NULLIF(bf.total_all_quotes, 0) > 0.01 THEN 'LEAKY FUNNEL'
        ELSE 'BROKEN FUNNEL'
    END AS funnel_health,

    -- Where is the biggest leak?
    CASE
        WHEN bf.total_all_quotes = 0 THEN 'No quotes generated'
        WHEN bf.total_all_proposals = 0 THEN 'ZERO proposals from quotes - quote-to-proposal completely broken'
        WHEN (bf.total_all_quotes - bf.total_all_proposals)::NUMERIC / NULLIF(bf.total_all_quotes, 0) >
             (bf.total_all_proposals - bf.total_all_policies)::NUMERIC / NULLIF(bf.total_all_proposals, 0)
             THEN 'Biggest leak: Quote-to-Proposal stage'
        ELSE 'Biggest leak: Proposal-to-Policy stage'
    END AS primary_bottleneck

FROM broker_funnel bf
LEFT JOIN broker_names bn ON bn.sales_channel_id = bf.sales_channel_id
ORDER BY bf.total_all_quotes DESC;


-- ============================================================================
-- QUERY 6: BROKER RISK ASSESSMENT
-- ============================================================================
-- INSIGHT: Comprehensive risk score per broker combining concentration risk,
--   trend direction, agent health, and conversion trajectory.
--
-- ACTION:
--   - CRITICAL RISK brokers: Immediate executive-level intervention
--   - HIGH RISK: Monthly monitoring with action plan
--   - MEDIUM RISK: Quarterly review
--   - LOW RISK: Continue current approach
--
-- KEY RISK: Spinny at 55% volume means if Spinny leaves or underperforms,
--   the platform loses more than half its business overnight.
-- ============================================================================

WITH broker_current AS (
    SELECT
        sales_channel_id,
        broker_name,
        SUM(policy_count) AS current_6m_policies,
        SUM(total_premium) AS current_6m_premium
    FROM channel_wise_monthly_sold_policies
    WHERE sold_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    GROUP BY sales_channel_id, broker_name
),
broker_prior AS (
    SELECT
        sales_channel_id,
        SUM(policy_count) AS prior_6m_policies,
        SUM(total_premium) AS prior_6m_premium
    FROM channel_wise_monthly_sold_policies
    WHERE sold_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '12 months'
      AND sold_month < DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    GROUP BY sales_channel_id
),
platform_totals AS (
    SELECT SUM(policy_count) AS total_policies, SUM(total_premium) AS total_premium
    FROM channel_wise_monthly_sold_policies
    WHERE sold_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
),
recent_trend AS (
    -- Compare last 2 months to 2 months before that
    SELECT
        sales_channel_id,
        SUM(CASE WHEN sold_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '2 months'
                 THEN policy_count ELSE 0 END) AS recent_2m_policies,
        SUM(CASE WHEN sold_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '4 months'
                  AND sold_month < DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '2 months'
                 THEN policy_count ELSE 0 END) AS prior_2m_policies
    FROM channel_wise_monthly_sold_policies
    GROUP BY sales_channel_id
)
SELECT
    bc.sales_channel_id,
    bc.broker_name,
    bc.current_6m_policies,
    bc.current_6m_premium,

    -- Concentration risk
    ROUND(bc.current_6m_policies::NUMERIC / NULLIF(pt.total_policies, 0) * 100, 2) AS platform_share_pct,

    CASE
        WHEN bc.current_6m_policies::NUMERIC / NULLIF(pt.total_policies, 0) >= 0.40 THEN 'CRITICAL'
        WHEN bc.current_6m_policies::NUMERIC / NULLIF(pt.total_policies, 0) >= 0.25 THEN 'HIGH'
        WHEN bc.current_6m_policies::NUMERIC / NULLIF(pt.total_policies, 0) >= 0.15 THEN 'MEDIUM'
        ELSE 'LOW'
    END AS concentration_risk_level,

    -- Growth/decline trend (6m vs prior 6m)
    COALESCE(bp.prior_6m_policies, 0) AS prior_6m_policies,
    CASE WHEN COALESCE(bp.prior_6m_policies, 0) > 0
         THEN ROUND((bc.current_6m_policies - bp.prior_6m_policies)::NUMERIC / bp.prior_6m_policies * 100, 1)
         ELSE NULL END AS yoy_growth_pct,

    -- Recent momentum (last 2m vs prior 2m)
    rt.recent_2m_policies,
    rt.prior_2m_policies,
    CASE WHEN rt.prior_2m_policies > 0
         THEN ROUND((rt.recent_2m_policies - rt.prior_2m_policies)::NUMERIC / rt.prior_2m_policies * 100, 1)
         ELSE NULL END AS recent_momentum_pct,

    -- Trend direction
    CASE
        WHEN rt.prior_2m_policies = 0 AND rt.recent_2m_policies > 0 THEN 'NEW/REACTIVATING'
        WHEN rt.recent_2m_policies = 0 AND rt.prior_2m_policies > 0 THEN 'STOPPED'
        WHEN rt.recent_2m_policies::NUMERIC / NULLIF(rt.prior_2m_policies, 0) >= 1.20 THEN 'ACCELERATING'
        WHEN rt.recent_2m_policies::NUMERIC / NULLIF(rt.prior_2m_policies, 0) >= 1.05 THEN 'GROWING'
        WHEN rt.recent_2m_policies::NUMERIC / NULLIF(rt.prior_2m_policies, 0) >= 0.95 THEN 'STABLE'
        WHEN rt.recent_2m_policies::NUMERIC / NULLIF(rt.prior_2m_policies, 0) >= 0.80 THEN 'DECLINING'
        ELSE 'CRITICAL_DECLINE'
    END AS trend_direction,

    -- Composite risk score (0-100, higher = riskier)
    ROUND(
        -- Concentration component (0-40 points): high share = high risk
        LEAST(bc.current_6m_policies::NUMERIC / NULLIF(pt.total_policies, 0) * 100, 40) +
        -- Decline component (0-30 points): declining = high risk
        CASE
            WHEN rt.prior_2m_policies > 0 AND
                 rt.recent_2m_policies::NUMERIC / rt.prior_2m_policies < 0.80 THEN 30
            WHEN rt.prior_2m_policies > 0 AND
                 rt.recent_2m_policies::NUMERIC / rt.prior_2m_policies < 0.95 THEN 15
            ELSE 0
        END +
        -- Dependency component (0-30 points): if we depend heavily AND they're declining
        CASE
            WHEN bc.current_6m_policies::NUMERIC / NULLIF(pt.total_policies, 0) >= 0.30
                 AND rt.recent_2m_policies < rt.prior_2m_policies THEN 30
            WHEN bc.current_6m_policies::NUMERIC / NULLIF(pt.total_policies, 0) >= 0.20
                 AND rt.recent_2m_policies < rt.prior_2m_policies THEN 20
            ELSE 0
        END
    , 1) AS composite_risk_score,

    -- Risk classification
    CASE
        WHEN bc.current_6m_policies::NUMERIC / NULLIF(pt.total_policies, 0) >= 0.30
             AND rt.recent_2m_policies < rt.prior_2m_policies
             THEN 'CRITICAL: High-dependency broker declining'
        WHEN bc.current_6m_policies::NUMERIC / NULLIF(pt.total_policies, 0) >= 0.40
             THEN 'CRITICAL: Extreme concentration regardless of trend'
        WHEN rt.recent_2m_policies = 0 AND rt.prior_2m_policies > 10
             THEN 'HIGH: Previously active broker has stopped'
        WHEN rt.recent_2m_policies::NUMERIC / NULLIF(rt.prior_2m_policies, 0) < 0.50
             THEN 'HIGH: Broker volume dropped by >50%'
        WHEN bc.current_6m_policies::NUMERIC / NULLIF(pt.total_policies, 0) >= 0.20
             THEN 'MEDIUM: Significant platform dependency'
        ELSE 'LOW: Manageable risk'
    END AS risk_assessment

FROM broker_current bc
CROSS JOIN platform_totals pt
LEFT JOIN broker_prior bp ON bp.sales_channel_id = bc.sales_channel_id
LEFT JOIN recent_trend rt ON rt.sales_channel_id = bc.sales_channel_id
ORDER BY
    ROUND(
        LEAST(bc.current_6m_policies::NUMERIC / NULLIF(pt.total_policies, 0) * 100, 40) +
        CASE WHEN rt.prior_2m_policies > 0 AND rt.recent_2m_policies::NUMERIC / rt.prior_2m_policies < 0.80 THEN 30
             WHEN rt.prior_2m_policies > 0 AND rt.recent_2m_policies::NUMERIC / rt.prior_2m_policies < 0.95 THEN 15
             ELSE 0 END +
        CASE WHEN bc.current_6m_policies::NUMERIC / NULLIF(pt.total_policies, 0) >= 0.30
                  AND rt.recent_2m_policies < rt.prior_2m_policies THEN 30
             WHEN bc.current_6m_policies::NUMERIC / NULLIF(pt.total_policies, 0) >= 0.20
                  AND rt.recent_2m_policies < rt.prior_2m_policies THEN 20
             ELSE 0 END
    , 1) DESC;


-- ============================================================================
-- QUERY 7: DORMANT BROKER IDENTIFICATION
-- ============================================================================
-- INSIGHT: Identifies brokers that have been onboarded but produce zero
--   or negligible volume. There are 15+ brokers with quoting activity
--   but zero conversions. This separates truly dead brokers from those
--   with untapped potential (quoting = interested but stuck).
--
-- ACTION:
--   - "Quoting but Not Converting" brokers: Priority intervention. They have
--     interested agents. Diagnose conversion blockers (pricing? product?
--     payment UX?). This is the easiest win.
--   - "Completely Dormant" brokers: Assess if relationship is worth
--     maintaining. Consider sunsetting or reactivation campaign.
--   - "Recently Dormant" (active before, stopped now): Urgent call to
--     understand what changed. Competitive loss? Internal issue?
-- ============================================================================

WITH broker_recent_activity AS (
    SELECT
        cwms.sales_channel_id,
        cwms.broker_name,
        SUM(CASE WHEN cwms.sold_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '3 months'
                 THEN cwms.policy_count ELSE 0 END) AS policies_last_3m,
        SUM(CASE WHEN cwms.sold_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
                 THEN cwms.policy_count ELSE 0 END) AS policies_last_6m,
        SUM(cwms.policy_count) AS total_policies_ever,
        MAX(cwms.sold_month) AS last_sale_month
    FROM channel_wise_monthly_sold_policies cwms
    GROUP BY cwms.sales_channel_id, cwms.broker_name
),
broker_quote_activity AS (
    SELECT
        cw.sales_channel_id,
        SUM(
            COALESCE(cw."4w_quote_count", 0) + COALESCE(cw."2w_quote_count", 0) +
            COALESCE(cw.health_quote_count, 0) + COALESCE(cw.gcv_quote_count, 0) +
            COALESCE(cw.pcv_quote_count, 0) + COALESCE(cw.term_quote_count, 0) +
            COALESCE(cw.personal_accident_quote_count, 0) +
            COALESCE(cw.savings_quote_count, 0) + COALESCE(cw.miscd_quote_count, 0)
        ) AS total_quotes,
        SUM(CASE WHEN cw.activity_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '3 months'
            THEN COALESCE(cw."4w_quote_count", 0) + COALESCE(cw."2w_quote_count", 0) +
                 COALESCE(cw.health_quote_count, 0) + COALESCE(cw.gcv_quote_count, 0) +
                 COALESCE(cw.pcv_quote_count, 0)
            ELSE 0 END) AS quotes_last_3m
    FROM channel_wise_monthly_activity_summary cw
    GROUP BY cw.sales_channel_id
),
all_brokers AS (
    SELECT DISTINCT saleschanneluserid AS channel_id
    FROM users
    WHERE saleschanneluserid IS NOT NULL AND deletedat IS NULL
)
SELECT
    ab.channel_id,
    COALESCE(bra.broker_name, 'Unknown Broker') AS broker_name,
    COALESCE(bra.total_policies_ever, 0) AS total_policies_ever,
    COALESCE(bra.policies_last_6m, 0) AS policies_last_6m,
    COALESCE(bra.policies_last_3m, 0) AS policies_last_3m,
    bra.last_sale_month,
    COALESCE(bqa.total_quotes, 0) AS total_quotes_ever,
    COALESCE(bqa.quotes_last_3m, 0) AS quotes_last_3m,

    -- Days since last sale
    CASE WHEN bra.last_sale_month IS NOT NULL
         THEN (CURRENT_DATE - bra.last_sale_month::DATE)
         ELSE NULL END AS days_since_last_sale,

    -- Classification
    CASE
        WHEN COALESCE(bra.policies_last_3m, 0) > 0 THEN 'ACTIVE'
        WHEN COALESCE(bra.policies_last_6m, 0) > 0 THEN 'RECENTLY_DORMANT (no sales in 3 months)'
        WHEN COALESCE(bqa.quotes_last_3m, 0) > 0 AND COALESCE(bra.policies_last_3m, 0) = 0
             THEN 'QUOTING_NOT_CONVERTING (priority intervention!)'
        WHEN COALESCE(bra.total_policies_ever, 0) > 0 THEN 'LONG_DORMANT (had sales before, now stopped)'
        WHEN COALESCE(bqa.total_quotes, 0) > 0 THEN 'NEVER_CONVERTED (quoted before, never sold)'
        ELSE 'COMPLETELY_INACTIVE (no quotes, no sales ever)'
    END AS dormancy_status,

    -- Recommended action
    CASE
        WHEN COALESCE(bra.policies_last_3m, 0) > 0 THEN 'Continue monitoring'
        WHEN COALESCE(bqa.quotes_last_3m, 0) > 0 AND COALESCE(bra.policies_last_3m, 0) = 0
             THEN 'URGENT: Agents are trying but failing. Diagnose conversion blockers.'
        WHEN COALESCE(bra.policies_last_6m, 0) > 0
             THEN 'Call broker to understand why sales stopped. Possible competitive loss.'
        WHEN COALESCE(bra.total_policies_ever, 0) > 0
             THEN 'Reactivation campaign or consider sunsetting partnership.'
        WHEN COALESCE(bqa.total_quotes, 0) > 0
             THEN 'Was interested but never converted. Review onboarding support.'
        ELSE 'Assess if partnership is viable. Consider formal offboarding.'
    END AS recommended_action

FROM all_brokers ab
LEFT JOIN broker_recent_activity bra ON bra.sales_channel_id = ab.channel_id
LEFT JOIN broker_quote_activity bqa ON bqa.sales_channel_id = ab.channel_id
ORDER BY
    CASE
        WHEN COALESCE(bqa.quotes_last_3m, 0) > 0 AND COALESCE(bra.policies_last_3m, 0) = 0 THEN 1
        WHEN COALESCE(bra.policies_last_6m, 0) > 0 AND COALESCE(bra.policies_last_3m, 0) = 0 THEN 2
        WHEN COALESCE(bra.total_policies_ever, 0) > 0 AND COALESCE(bra.policies_last_6m, 0) = 0 THEN 3
        WHEN COALESCE(bra.policies_last_3m, 0) > 0 THEN 5
        ELSE 4
    END,
    COALESCE(bqa.quotes_last_3m, 0) DESC;


-- ============================================================================
-- QUERY 8: BROKER COMPARISON AGAINST PLATFORM AVERAGES
-- ============================================================================
-- INSIGHT: For each broker, compare their key metrics against platform
--   averages. Shows whether a broker is above or below par for each metric.
--
-- ACTION: Use this as the basis for broker quarterly business reviews.
--   Highlight below-average metrics as improvement areas with specific
--   action plans tied to each metric.
-- ============================================================================

WITH platform_averages AS (
    SELECT
        AVG(policy_count) AS avg_monthly_policies,
        AVG(total_premium) AS avg_monthly_premium,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY policy_count) AS median_monthly_policies,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total_premium) AS median_monthly_premium,
        AVG(total_premium / NULLIF(policy_count, 0)) AS avg_ticket_size
    FROM channel_wise_monthly_sold_policies
    WHERE sold_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
      AND policy_count > 0
),
broker_monthly_avg AS (
    SELECT
        sales_channel_id,
        broker_name,
        AVG(policy_count) AS broker_avg_monthly_policies,
        AVG(total_premium) AS broker_avg_monthly_premium,
        AVG(total_premium / NULLIF(policy_count, 0)) AS broker_avg_ticket_size,
        COUNT(*) AS active_months
    FROM channel_wise_monthly_sold_policies
    WHERE sold_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
      AND policy_count > 0
    GROUP BY sales_channel_id, broker_name
)
SELECT
    bma.sales_channel_id,
    bma.broker_name,
    bma.active_months,

    -- Policies comparison
    ROUND(bma.broker_avg_monthly_policies, 1) AS broker_avg_monthly_policies,
    ROUND(pa.avg_monthly_policies, 1) AS platform_avg_monthly_policies,
    ROUND(pa.median_monthly_policies, 1) AS platform_median_monthly_policies,
    ROUND((bma.broker_avg_monthly_policies - pa.avg_monthly_policies) / NULLIF(pa.avg_monthly_policies, 0) * 100, 1)
        AS policy_pct_vs_platform_avg,

    -- Premium comparison
    ROUND(bma.broker_avg_monthly_premium, 0) AS broker_avg_monthly_premium,
    ROUND(pa.avg_monthly_premium, 0) AS platform_avg_monthly_premium,
    ROUND((bma.broker_avg_monthly_premium - pa.avg_monthly_premium) / NULLIF(pa.avg_monthly_premium, 0) * 100, 1)
        AS premium_pct_vs_platform_avg,

    -- Ticket size comparison
    ROUND(bma.broker_avg_ticket_size, 0) AS broker_avg_ticket_size,
    ROUND(pa.avg_ticket_size, 0) AS platform_avg_ticket_size,
    ROUND((bma.broker_avg_ticket_size - pa.avg_ticket_size) / NULLIF(pa.avg_ticket_size, 0) * 100, 1)
        AS ticket_pct_vs_platform_avg,

    -- Overall position
    CASE
        WHEN bma.broker_avg_monthly_policies > pa.avg_monthly_policies
             AND bma.broker_avg_ticket_size > pa.avg_ticket_size
             THEN 'ABOVE AVERAGE: Volume AND quality above platform average'
        WHEN bma.broker_avg_monthly_policies > pa.avg_monthly_policies
             THEN 'HIGH VOLUME, LOW TICKET: Selling more but at lower premiums'
        WHEN bma.broker_avg_ticket_size > pa.avg_ticket_size
             THEN 'LOW VOLUME, HIGH TICKET: Few sales but premium quality'
        ELSE 'BELOW AVERAGE: Both volume and ticket below platform average'
    END AS broker_position

FROM broker_monthly_avg bma
CROSS JOIN platform_averages pa
ORDER BY bma.broker_avg_monthly_premium DESC;


-- ============================================================================
-- QUERY 9: BROKER-WISE AGENT HEALTH DISTRIBUTION
-- ============================================================================
-- INSIGHT: Shows how agents within each broker are distributed across
--   engagement segments (Star/Rising/Occasional/Dormant/Dead).
--   A broker might have 1,000 agents but if 990 are dead, that is a
--   problem with the broker's agent management, not our platform.
--
-- ACTION:
--   - Brokers with >90% dead agents: Agent quality issue at onboarding.
--     Work with broker to improve agent selection/onboarding.
--   - Brokers with many "occasional" agents: Activation opportunity.
--     These agents sell sometimes - with nudges they could sell more.
--   - Brokers with many "rising" agents: Growing health. Support with
--     training and tools.
--
-- NOTE: This query uses agent engagement segments derived from activity.
--   If agent_engagement_score table is populated (from 01_new_tables_schema),
--   use that instead for more accurate segments.
-- ============================================================================

WITH agent_activity AS (
    SELECT
        u.id AS agent_id,
        u.saleschanneluserid AS channel_id,
        COUNT(DISTINCT sp.id) AS total_sales,
        COUNT(DISTINCT CASE WHEN sp.sold_date >= CURRENT_DATE - INTERVAL '3 months' THEN sp.id END) AS sales_3m,
        COUNT(DISTINCT CASE WHEN sp.sold_date >= CURRENT_DATE - INTERVAL '1 month' THEN sp.id END) AS sales_1m,
        COALESCE(SUM(dq.quote_count), 0) AS total_quotes_3m
    FROM users u
    LEFT JOIN sold_policies_data sp ON sp.agent::TEXT = u.id::TEXT
        AND sp.sold_date >= CURRENT_DATE - INTERVAL '3 months'
    LEFT JOIN daily_quote_counts dq ON dq.agent_id = u.id
        AND dq.quote_date >= CURRENT_DATE - INTERVAL '3 months'
    WHERE u.saleschanneluserid IS NOT NULL
      AND u.deletedat IS NULL
    GROUP BY u.id, u.saleschanneluserid
),
agent_segments AS (
    SELECT
        agent_id,
        channel_id,
        total_sales,
        sales_3m,
        sales_1m,
        total_quotes_3m,
        CASE
            WHEN sales_1m >= 10 THEN 'star'          -- 10+ sales last month
            WHEN sales_3m >= 5 THEN 'rising'          -- Active and growing
            WHEN sales_3m >= 1 OR total_quotes_3m >= 5 THEN 'occasional' -- Some activity
            WHEN total_quotes_3m >= 1 THEN 'dormant'  -- Quoting but not selling
            ELSE 'dead'                                -- No activity at all
        END AS segment
    FROM agent_activity
),
broker_names AS (
    SELECT DISTINCT ON (sales_channel_id)
        sales_channel_id, broker_name
    FROM channel_wise_monthly_sold_policies
    ORDER BY sales_channel_id, sold_month DESC
)
SELECT
    aseg.channel_id AS sales_channel_id,
    COALESCE(bn.broker_name, 'Unknown') AS broker_name,

    COUNT(*) AS total_agents,
    COUNT(CASE WHEN segment = 'star' THEN 1 END) AS star_agents,
    COUNT(CASE WHEN segment = 'rising' THEN 1 END) AS rising_agents,
    COUNT(CASE WHEN segment = 'occasional' THEN 1 END) AS occasional_agents,
    COUNT(CASE WHEN segment = 'dormant' THEN 1 END) AS dormant_agents,
    COUNT(CASE WHEN segment = 'dead' THEN 1 END) AS dead_agents,

    -- Percentages
    ROUND(COUNT(CASE WHEN segment = 'star' THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1) AS star_pct,
    ROUND(COUNT(CASE WHEN segment = 'rising' THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1) AS rising_pct,
    ROUND(COUNT(CASE WHEN segment = 'occasional' THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1) AS occasional_pct,
    ROUND(COUNT(CASE WHEN segment = 'dormant' THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1) AS dormant_pct,
    ROUND(COUNT(CASE WHEN segment = 'dead' THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1) AS dead_pct,

    -- Health score: weighted average (star=100, rising=75, occasional=50, dormant=25, dead=0)
    ROUND(
        (COUNT(CASE WHEN segment = 'star' THEN 1 END) * 100.0 +
         COUNT(CASE WHEN segment = 'rising' THEN 1 END) * 75.0 +
         COUNT(CASE WHEN segment = 'occasional' THEN 1 END) * 50.0 +
         COUNT(CASE WHEN segment = 'dormant' THEN 1 END) * 25.0) /
        NULLIF(COUNT(*), 0)
    , 1) AS agent_health_score,

    -- Actionable insight
    CASE
        WHEN COUNT(CASE WHEN segment = 'dead' THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) > 0.90
             THEN 'CRITICAL: >90% dead agents. Broker agent quality/onboarding needs overhaul.'
        WHEN COUNT(CASE WHEN segment = 'dormant' THEN 1 END) > 20
             THEN 'OPPORTUNITY: ' || COUNT(CASE WHEN segment = 'dormant' THEN 1 END) ||
                  ' dormant agents quoting but not selling. Targeted intervention needed.'
        WHEN COUNT(CASE WHEN segment = 'occasional' THEN 1 END) > 10
             THEN 'GROWTH: ' || COUNT(CASE WHEN segment = 'occasional' THEN 1 END) ||
                  ' occasional agents could become regular with nudges and training.'
        WHEN COUNT(CASE WHEN segment IN ('star', 'rising') THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) > 0.10
             THEN 'HEALTHY: Good proportion of active agents. Focus on retention.'
        ELSE 'STABLE: Monitor regularly.'
    END AS actionable_insight

FROM agent_segments aseg
LEFT JOIN broker_names bn ON bn.sales_channel_id = aseg.channel_id
GROUP BY aseg.channel_id, bn.broker_name
ORDER BY COUNT(*) DESC;


-- ============================================================================
-- QUERY 10: POPULATE broker_scorecard_monthly (ETL Query)
-- ============================================================================
-- PURPOSE: Runs monthly (or nightly) to populate the broker_scorecard_monthly
--   table from File 1. This is the ETL that powers fast dashboard queries.
--
-- NOTE: This query writes to the NEW broker_scorecard_monthly table.
--   Run after deploying 01_new_tables_schema.sql.
-- ============================================================================
-- [NEW TABLE REQUIRED: broker_scorecard_monthly from 01_new_tables_schema.sql]

/*
-- Uncomment after broker_scorecard_monthly table is created

INSERT INTO broker_scorecard_monthly (
    sales_channel_id, broker_name, scorecard_month,
    total_policies, total_premium, total_net_premium,
    total_agents, active_agents, quoting_agents, agent_activation_rate,
    total_quotes, overall_conversion_rate,
    policies_4w, policies_2w, policies_health, policies_other,
    premium_4w, premium_2w, premium_health, premium_other,
    new_policies, renewal_policies, rollover_policies, breakin_policies,
    avg_premium_per_policy, policies_per_active_agent, premium_per_active_agent,
    broker_tier, overall_score
)
WITH month_param AS (
    SELECT DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month') AS target_month
),
broker_sales AS (
    SELECT
        sp.sales_channel_user_id,
        sp.source AS broker_name,
        COUNT(*) AS total_policies,
        SUM(sp.premium_amount) AS total_premium,
        SUM(sp.net_premium) AS total_net_premium,
        COUNT(DISTINCT sp.agent) AS selling_agents,
        AVG(sp.premium_amount) AS avg_premium,
        COUNT(CASE WHEN sp.product_type ILIKE '%car%' OR sp.product_type ILIKE '%4w%' OR sp.product_type ILIKE '%private%' THEN 1 END) AS p4w,
        COUNT(CASE WHEN sp.product_type ILIKE '%two%' OR sp.product_type ILIKE '%2w%' THEN 1 END) AS p2w,
        COUNT(CASE WHEN sp.product_type ILIKE '%health%' THEN 1 END) AS phealth,
        SUM(CASE WHEN sp.product_type ILIKE '%car%' OR sp.product_type ILIKE '%4w%' OR sp.product_type ILIKE '%private%' THEN sp.premium_amount ELSE 0 END) AS prem4w,
        SUM(CASE WHEN sp.product_type ILIKE '%two%' OR sp.product_type ILIKE '%2w%' THEN sp.premium_amount ELSE 0 END) AS prem2w,
        SUM(CASE WHEN sp.product_type ILIKE '%health%' THEN sp.premium_amount ELSE 0 END) AS premhealth,
        COUNT(CASE WHEN sp.policy_business_type = 'New Policy' THEN 1 END) AS new_pol,
        COUNT(CASE WHEN sp.policy_business_type = 'Renewal' THEN 1 END) AS renewal_pol,
        COUNT(CASE WHEN sp.policy_business_type = 'Roll Over' THEN 1 END) AS rollover_pol,
        COUNT(CASE WHEN sp.is_breakin_journey = TRUE OR sp.is_breakin_journey::TEXT = 'true' THEN 1 END) AS breakin_pol
    FROM sold_policies_data sp, month_param mp
    WHERE DATE_TRUNC('month', sp.sold_date) = mp.target_month
    GROUP BY sp.sales_channel_user_id, sp.source
),
broker_agents AS (
    SELECT
        u.saleschanneluserid AS channel_id,
        COUNT(*) AS total_agents
    FROM users u
    WHERE u.saleschanneluserid IS NOT NULL AND u.deletedat IS NULL
    GROUP BY u.saleschanneluserid
),
broker_quotes AS (
    SELECT
        u.saleschanneluserid AS channel_id,
        SUM(dq.quote_count) AS total_quotes,
        COUNT(DISTINCT dq.agent_id) AS quoting_agents
    FROM daily_quote_counts dq
    JOIN users u ON u.id = dq.agent_id, month_param mp
    WHERE DATE_TRUNC('month', dq.quote_date) = mp.target_month
    GROUP BY u.saleschanneluserid
)
SELECT
    bs.sales_channel_user_id,
    bs.broker_name,
    mp.target_month,
    bs.total_policies,
    bs.total_premium,
    bs.total_net_premium,
    COALESCE(ba.total_agents, 0),
    bs.selling_agents,
    COALESCE(bq.quoting_agents, 0),
    CASE WHEN COALESCE(ba.total_agents, 0) > 0
         THEN ROUND(bs.selling_agents::NUMERIC / ba.total_agents * 100, 2)
         ELSE 0 END,
    COALESCE(bq.total_quotes, 0),
    CASE WHEN COALESCE(bq.total_quotes, 0) > 0
         THEN ROUND(bs.total_policies::NUMERIC / bq.total_quotes * 100, 2)
         ELSE 0 END,
    bs.p4w, bs.p2w, bs.phealth,
    bs.total_policies - bs.p4w - bs.p2w - bs.phealth,
    bs.prem4w, bs.prem2w, bs.premhealth,
    bs.total_premium - bs.prem4w - bs.prem2w - bs.premhealth,
    bs.new_pol, bs.renewal_pol, bs.rollover_pol, bs.breakin_pol,
    ROUND(bs.avg_premium, 2),
    CASE WHEN bs.selling_agents > 0 THEN ROUND(bs.total_policies::NUMERIC / bs.selling_agents, 2) ELSE 0 END,
    CASE WHEN bs.selling_agents > 0 THEN ROUND(bs.total_premium / bs.selling_agents, 2) ELSE 0 END,
    -- Tier (simplified - use NTILE in production)
    CASE
        WHEN bs.total_premium > 1000000 THEN 'platinum'
        WHEN bs.total_premium > 500000 THEN 'gold'
        WHEN bs.total_premium > 100000 THEN 'silver'
        WHEN bs.total_premium > 0 THEN 'bronze'
        ELSE 'inactive'
    END,
    -- Score (simplified - use weighted composite in production)
    LEAST(bs.total_premium / 10000, 100)
FROM broker_sales bs
CROSS JOIN month_param mp
LEFT JOIN broker_agents ba ON ba.channel_id = bs.sales_channel_user_id
LEFT JOIN broker_quotes bq ON bq.channel_id = bs.sales_channel_user_id
ON CONFLICT (sales_channel_id, scorecard_month) DO UPDATE SET
    total_policies = EXCLUDED.total_policies,
    total_premium = EXCLUDED.total_premium,
    total_net_premium = EXCLUDED.total_net_premium,
    updated_at = NOW();
*/
