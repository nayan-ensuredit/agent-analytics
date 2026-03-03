-- ============================================================================
-- FILE 3: ACTIONABLE DASHBOARD QUERIES - COMPLETE SYSTEM
-- ============================================================================
-- InsurTech Distribution Platform - Management Dashboard Analytics
-- PostgreSQL 14+
--
-- 10 SECTIONS covering every dimension of platform performance.
-- Every query includes: What insight it provides, What ACTION to take,
-- and What THRESHOLDS to watch.
--
-- TABLES USED: All existing tables. Queries requiring new tables from
-- 01_new_tables_schema.sql are clearly marked [NEW TABLE REQUIRED].
-- ============================================================================


-- ############################################################################
-- SECTION 1: EXECUTIVE SUMMARY (CEO/CTO View)
-- ############################################################################

-- ============================================================================
-- 1.1 BUSINESS HEALTH KPIs - Current Month vs Previous Month
-- ============================================================================
-- INSIGHT: Single-glance view of platform health with month-over-month deltas.
-- ACTION: If any KPI declines >10% MoM, escalate immediately. Green/Yellow/Red
--   status enables quick triage in leadership meetings.
-- THRESHOLDS:
--   GREEN: MoM growth > 0%
--   YELLOW: MoM decline 0-10%
--   RED: MoM decline > 10%
-- ============================================================================

WITH current_month AS (
    SELECT
        COUNT(*) AS policies,
        COALESCE(SUM(premium_amount), 0) AS premium,
        COALESCE(SUM(net_premium), 0) AS net_premium,
        COUNT(DISTINCT agent) AS selling_agents,
        COUNT(DISTINCT sales_channel_user_id) AS active_brokers,
        AVG(premium_amount) AS avg_ticket_size,
        COUNT(CASE WHEN policy_business_type = 'Renewal' THEN 1 END) AS renewals,
        COUNT(CASE WHEN is_breakin_journey::TEXT = 'true' THEN 1 END) AS breakin_count
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE)
),
prev_month AS (
    SELECT
        COUNT(*) AS policies,
        COALESCE(SUM(premium_amount), 0) AS premium,
        COUNT(DISTINCT agent) AS selling_agents,
        COUNT(DISTINCT sales_channel_user_id) AS active_brokers,
        AVG(premium_amount) AS avg_ticket_size
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month'
      AND sold_date < DATE_TRUNC('month', CURRENT_DATE)
),
current_quotes AS (
    SELECT SUM(quote_count) AS quotes, COUNT(DISTINCT agent_id) AS quoting_agents
    FROM daily_quote_counts
    WHERE quote_date >= DATE_TRUNC('month', CURRENT_DATE)
),
prev_quotes AS (
    SELECT SUM(quote_count) AS quotes
    FROM daily_quote_counts
    WHERE quote_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month'
      AND quote_date < DATE_TRUNC('month', CURRENT_DATE)
),
total_agents AS (
    SELECT COUNT(*) AS total FROM users WHERE deletedat IS NULL
)
SELECT
    -- Current month metrics
    cm.policies AS mtd_policies,
    ROUND(cm.premium, 0) AS mtd_premium,
    ROUND(cm.net_premium, 0) AS mtd_net_premium,
    cm.selling_agents AS mtd_selling_agents,
    cm.active_brokers AS mtd_active_brokers,
    ROUND(cm.avg_ticket_size, 0) AS mtd_avg_ticket,
    cm.renewals AS mtd_renewals,
    cm.breakin_count AS mtd_breakin,
    COALESCE(cq.quotes, 0) AS mtd_quotes,
    COALESCE(cq.quoting_agents, 0) AS mtd_quoting_agents,
    ta.total AS total_agents_in_system,

    -- Conversion rate
    CASE WHEN COALESCE(cq.quotes, 0) > 0
         THEN ROUND(cm.policies::NUMERIC / cq.quotes * 100, 2)
         ELSE 0 END AS mtd_conversion_rate,

    -- Agent activation rate
    ROUND(cm.selling_agents::NUMERIC / NULLIF(ta.total, 0) * 100, 3) AS agent_activation_rate,

    -- MoM changes
    pm.policies AS prev_month_policies,
    ROUND(pm.premium, 0) AS prev_month_premium,
    CASE WHEN pm.policies > 0
         THEN ROUND((cm.policies - pm.policies)::NUMERIC / pm.policies * 100, 1)
         ELSE NULL END AS policies_mom_pct,
    CASE WHEN pm.premium > 0
         THEN ROUND((cm.premium - pm.premium) / pm.premium * 100, 1)
         ELSE NULL END AS premium_mom_pct,
    CASE WHEN pm.selling_agents > 0
         THEN ROUND((cm.selling_agents - pm.selling_agents)::NUMERIC / pm.selling_agents * 100, 1)
         ELSE NULL END AS agents_mom_pct,

    -- Status indicators
    CASE
        WHEN cm.policies > pm.policies THEN 'GREEN: Growing'
        WHEN cm.policies >= pm.policies * 0.9 THEN 'YELLOW: Flat/slight decline'
        ELSE 'RED: Declining >10%'
    END AS volume_status,
    CASE
        WHEN cm.premium > pm.premium THEN 'GREEN'
        WHEN cm.premium >= pm.premium * 0.9 THEN 'YELLOW'
        ELSE 'RED'
    END AS premium_status

FROM current_month cm
CROSS JOIN prev_month pm
CROSS JOIN current_quotes cq
CROSS JOIN prev_quotes pq
CROSS JOIN total_agents ta;


-- ============================================================================
-- 1.2 REVENUE CONCENTRATION RISK
-- ============================================================================
-- INSIGHT: How dependent is the platform on its top broker and top agents?
--   Spinny = 55% of volume is a severe concentration risk.
-- ACTION: If top broker > 40%, launch aggressive diversification plan.
--   If top 10 agents > 50% of volume, invest in mid-tier agent development.
-- THRESHOLDS:
--   Top broker share: CRITICAL > 40%, HIGH > 30%, MEDIUM > 20%
--   Top 10 agents share: CRITICAL > 60%, HIGH > 40%
-- ============================================================================

WITH total_premium AS (
    SELECT SUM(premium_amount) AS total, COUNT(*) AS total_policies
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
),
top_broker AS (
    SELECT source AS broker_name,
           SUM(premium_amount) AS broker_premium,
           COUNT(*) AS broker_policies
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    GROUP BY source
    ORDER BY broker_premium DESC
    LIMIT 1
),
top_5_brokers AS (
    SELECT SUM(premium_amount) AS top5_premium, SUM(cnt) AS top5_policies
    FROM (
        SELECT source, SUM(premium_amount) AS premium_amount, COUNT(*) AS cnt
        FROM sold_policies_data
        WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
        GROUP BY source
        ORDER BY SUM(premium_amount) DESC
        LIMIT 5
    ) t
),
top_10_agents AS (
    SELECT SUM(premium_amount) AS top10_premium, SUM(cnt) AS top10_policies
    FROM (
        SELECT agent, SUM(premium_amount) AS premium_amount, COUNT(*) AS cnt
        FROM sold_policies_data
        WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
        GROUP BY agent
        ORDER BY SUM(premium_amount) DESC
        LIMIT 10
    ) t
),
top_50_agents AS (
    SELECT SUM(premium_amount) AS top50_premium, SUM(cnt) AS top50_policies
    FROM (
        SELECT agent, SUM(premium_amount) AS premium_amount, COUNT(*) AS cnt
        FROM sold_policies_data
        WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
        GROUP BY agent
        ORDER BY SUM(premium_amount) DESC
        LIMIT 50
    ) t
)
SELECT
    tb.broker_name AS top_broker,
    ROUND(tb.broker_premium / NULLIF(tp.total, 0) * 100, 1) AS top_broker_premium_share,
    ROUND(tb.broker_policies::NUMERIC / NULLIF(tp.total_policies, 0) * 100, 1) AS top_broker_policy_share,
    ROUND(t5.top5_premium / NULLIF(tp.total, 0) * 100, 1) AS top_5_brokers_premium_share,
    ROUND(t10.top10_premium / NULLIF(tp.total, 0) * 100, 1) AS top_10_agents_premium_share,
    ROUND(t10.top10_policies::NUMERIC / NULLIF(tp.total_policies, 0) * 100, 1) AS top_10_agents_policy_share,
    ROUND(t50.top50_premium / NULLIF(tp.total, 0) * 100, 1) AS top_50_agents_premium_share,

    CASE
        WHEN tb.broker_premium / NULLIF(tp.total, 0) >= 0.40
             THEN 'CRITICAL: Top broker controls >40% of revenue. Business continuity risk.'
        WHEN tb.broker_premium / NULLIF(tp.total, 0) >= 0.30
             THEN 'HIGH: Top broker >30%. Actively diversify broker portfolio.'
        WHEN tb.broker_premium / NULLIF(tp.total, 0) >= 0.20
             THEN 'MEDIUM: Top broker >20%. Monitor and grow other brokers.'
        ELSE 'LOW: Healthy diversification.'
    END AS broker_concentration_risk,

    CASE
        WHEN t10.top10_premium / NULLIF(tp.total, 0) >= 0.60
             THEN 'CRITICAL: Top 10 agents = >60% revenue. Key-person dependency.'
        WHEN t10.top10_premium / NULLIF(tp.total, 0) >= 0.40
             THEN 'HIGH: Top 10 agents = >40%. Build mid-tier agent pipeline.'
        ELSE 'ACCEPTABLE: Agent revenue reasonably distributed.'
    END AS agent_concentration_risk

FROM total_premium tp
CROSS JOIN top_broker tb
CROSS JOIN top_5_brokers t5
CROSS JOIN top_10_agents t10
CROSS JOIN top_50_agents t50;


-- ============================================================================
-- 1.3 GROWTH TRAJECTORY (12-Month Trend)
-- ============================================================================
-- INSIGHT: Is the platform growing, flat, or declining? Monthly trend line
--   with 3-month moving average smooths out noise.
-- ACTION: If 3-month average is declining for 2+ consecutive months, this
--   is a systemic issue needing strategic intervention (not tactical fixes).
-- THRESHOLDS:
--   Healthy growth: >5% MoM average over 3 months
--   Stagnation: -2% to +2% MoM
--   Decline: < -2% MoM sustained
-- ============================================================================

SELECT
    sold_month,
    policy_count,
    total_premium,
    -- MoM change
    LAG(policy_count) OVER (ORDER BY sold_month) AS prev_month_policies,
    CASE WHEN LAG(policy_count) OVER (ORDER BY sold_month) > 0
         THEN ROUND((policy_count - LAG(policy_count) OVER (ORDER BY sold_month))::NUMERIC
              / LAG(policy_count) OVER (ORDER BY sold_month) * 100, 1)
         ELSE NULL END AS policy_mom_pct,
    -- 3-month moving average
    ROUND(AVG(policy_count) OVER (ORDER BY sold_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0)
        AS policies_3m_avg,
    ROUND(AVG(total_premium) OVER (ORDER BY sold_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0)
        AS premium_3m_avg,
    -- Cumulative YTD
    SUM(policy_count) OVER (
        PARTITION BY DATE_TRUNC('year', sold_month)
        ORDER BY sold_month
    ) AS ytd_policies,
    SUM(total_premium) OVER (
        PARTITION BY DATE_TRUNC('year', sold_month)
        ORDER BY sold_month
    ) AS ytd_premium
FROM category_wise_monthly_sold_policies
WHERE product_type IS NOT NULL
GROUP BY sold_month,
         policy_count, total_premium
ORDER BY sold_month;


-- ============================================================================
-- 1.4 PRODUCT DIVERSIFICATION SCORE
-- ============================================================================
-- INSIGHT: Platform is 96% Private Car. This measures how concentrated the
--   product mix is and tracks it over time.
-- ACTION: Score < 20 = dangerously concentrated. Every 1% shift toward
--   health/2W significantly improves platform resilience.
-- THRESHOLD: Diversity score (inverse Herfindahl): 0=monopoly, 100=equal split
-- ============================================================================

WITH product_share AS (
    SELECT
        sold_month,
        product_type,
        SUM(policy_count) AS policies,
        SUM(total_premium) AS premium
    FROM category_wise_monthly_sold_policies
    GROUP BY sold_month, product_type
),
month_totals AS (
    SELECT sold_month, SUM(policies) AS total_policies, SUM(premium) AS total_premium
    FROM product_share
    GROUP BY sold_month
),
hhi AS (
    SELECT
        ps.sold_month,
        mt.total_policies,
        mt.total_premium,
        -- Herfindahl-Hirschman Index (sum of squared shares)
        SUM(POWER(ps.policies::NUMERIC / NULLIF(mt.total_policies, 0), 2)) AS hhi_policies,
        -- Diversity score = (1 - HHI) * 100
        ROUND((1 - SUM(POWER(ps.policies::NUMERIC / NULLIF(mt.total_policies, 0), 2))) * 100, 1) AS diversity_score
    FROM product_share ps
    JOIN month_totals mt ON mt.sold_month = ps.sold_month
    GROUP BY ps.sold_month, mt.total_policies, mt.total_premium
)
SELECT
    sold_month,
    total_policies,
    total_premium,
    ROUND(hhi_policies, 4) AS hhi_index,
    diversity_score,
    CASE
        WHEN diversity_score < 10 THEN 'CRITICAL: Near-monopoly product concentration'
        WHEN diversity_score < 20 THEN 'POOR: Very limited diversification'
        WHEN diversity_score < 40 THEN 'MODERATE: Some diversification'
        ELSE 'GOOD: Healthy product mix'
    END AS diversification_status
FROM hhi
ORDER BY sold_month;


-- ############################################################################
-- SECTION 2: AGENT LIFECYCLE ANALYTICS
-- ############################################################################

-- ============================================================================
-- 2.1 AGENT ACTIVATION FUNNEL (Current State)
-- ============================================================================
-- INSIGHT: Of 76,917 agents, how many reached each milestone?
--   Shows the biggest drop-off point in the agent journey.
-- ACTION: Focus resources on the stage with the biggest absolute drop-off.
--   If 50K agents never logged in, fix onboarding. If 10K logged in but
--   never quoted, fix the quoting UX.
-- THRESHOLDS:
--   Healthy activation: >5% of registered agents have sold
--   Current reality: ~0.8% monthly active rate = broken funnel
-- ============================================================================

WITH agent_funnel AS (
    SELECT
        COUNT(*) AS total_registered,
        COUNT(CASE WHEN lastlogin IS NOT NULL THEN 1 END) AS ever_logged_in,
        COUNT(CASE WHEN lastlogin >= CURRENT_DATE - INTERVAL '90 days' THEN 1 END) AS logged_in_90d,
        COUNT(CASE WHEN lastlogin >= CURRENT_DATE - INTERVAL '30 days' THEN 1 END) AS logged_in_30d
    FROM users
    WHERE deletedat IS NULL
),
quoting_agents AS (
    SELECT COUNT(DISTINCT agent_id) AS agents_ever_quoted,
           COUNT(DISTINCT CASE WHEN quote_date >= CURRENT_DATE - INTERVAL '90 days' THEN agent_id END) AS agents_quoted_90d,
           COUNT(DISTINCT CASE WHEN quote_date >= CURRENT_DATE - INTERVAL '30 days' THEN agent_id END) AS agents_quoted_30d
    FROM daily_quote_counts
    WHERE quote_count > 0
),
selling_agents AS (
    SELECT COUNT(DISTINCT agent) AS agents_ever_sold,
           COUNT(DISTINCT CASE WHEN sold_date >= CURRENT_DATE - INTERVAL '90 days' THEN agent END) AS agents_sold_90d,
           COUNT(DISTINCT CASE WHEN sold_date >= CURRENT_DATE - INTERVAL '30 days' THEN agent END) AS agents_sold_30d
    FROM sold_policies_data
    WHERE agent IS NOT NULL AND agent != ''
)
SELECT
    af.total_registered,
    af.ever_logged_in,
    af.logged_in_90d,
    af.logged_in_30d,
    qa.agents_ever_quoted,
    qa.agents_quoted_90d,
    qa.agents_quoted_30d,
    sa.agents_ever_sold,
    sa.agents_sold_90d,
    sa.agents_sold_30d,

    -- Funnel conversion rates
    ROUND(af.ever_logged_in::NUMERIC / NULLIF(af.total_registered, 0) * 100, 1) AS pct_ever_logged_in,
    ROUND(qa.agents_ever_quoted::NUMERIC / NULLIF(af.ever_logged_in, 0) * 100, 1) AS pct_login_to_quote,
    ROUND(sa.agents_ever_sold::NUMERIC / NULLIF(qa.agents_ever_quoted, 0) * 100, 1) AS pct_quote_to_sale,
    ROUND(sa.agents_ever_sold::NUMERIC / NULLIF(af.total_registered, 0) * 100, 1) AS pct_overall_activation,

    -- Drop-off at each stage (absolute numbers)
    af.total_registered - af.ever_logged_in AS never_logged_in,
    af.ever_logged_in - qa.agents_ever_quoted AS logged_in_never_quoted,
    qa.agents_ever_quoted - sa.agents_ever_sold AS quoted_never_sold,

    -- Biggest drop-off identification
    CASE
        WHEN (af.total_registered - af.ever_logged_in) >= (af.ever_logged_in - qa.agents_ever_quoted)
             AND (af.total_registered - af.ever_logged_in) >= (qa.agents_ever_quoted - sa.agents_ever_sold)
             THEN 'BIGGEST DROP: Registration to First Login (' || (af.total_registered - af.ever_logged_in) || ' agents never logged in)'
        WHEN (af.ever_logged_in - qa.agents_ever_quoted) >= (qa.agents_ever_quoted - sa.agents_ever_sold)
             THEN 'BIGGEST DROP: Login to First Quote (' || (af.ever_logged_in - qa.agents_ever_quoted) || ' logged in but never quoted)'
        ELSE 'BIGGEST DROP: Quote to First Sale (' || (qa.agents_ever_quoted - sa.agents_ever_sold) || ' quoted but never sold)'
    END AS primary_bottleneck

FROM agent_funnel af
CROSS JOIN quoting_agents qa
CROSS JOIN selling_agents sa;


-- ============================================================================
-- 2.2 COHORT ANALYSIS - Agents by Join Month
-- ============================================================================
-- INSIGHT: For each join-month cohort, what percentage activated within
--   1 month, 3 months, and 6 months? Reveals whether onboarding is
--   improving or deteriorating over time.
-- ACTION: If recent cohorts activate worse than older ones, the onboarding
--   process has degraded. If 2024 cohort has 0% activation, something is
--   fundamentally broken for new agents.
-- THRESHOLDS:
--   Good: >10% activation within 3 months
--   Acceptable: >5% within 3 months
--   Poor: <5% within 3 months
--   Broken: 0% (current state for 2024 cohort)
-- ============================================================================

WITH agent_cohorts AS (
    SELECT
        u.id AS agent_id,
        DATE_TRUNC('month', u.createdat) AS cohort_month,
        u.createdat AS join_date
    FROM users u
    WHERE u.deletedat IS NULL
      AND u.createdat >= '2022-01-01'
),
agent_first_sale AS (
    SELECT
        agent::TEXT AS agent_id_text,
        MIN(sold_date) AS first_sale_date
    FROM sold_policies_data
    WHERE agent IS NOT NULL AND agent != ''
    GROUP BY agent::TEXT
),
agent_first_quote AS (
    SELECT
        agent_id,
        MIN(quote_date) AS first_quote_date
    FROM daily_quote_counts
    WHERE quote_count > 0
    GROUP BY agent_id
)
SELECT
    ac.cohort_month,
    COUNT(*) AS cohort_size,

    -- Quote activation
    COUNT(CASE WHEN afq.first_quote_date IS NOT NULL THEN 1 END) AS ever_quoted,
    COUNT(CASE WHEN afq.first_quote_date <= ac.join_date + INTERVAL '30 days' THEN 1 END) AS quoted_within_30d,
    COUNT(CASE WHEN afq.first_quote_date <= ac.join_date + INTERVAL '90 days' THEN 1 END) AS quoted_within_90d,

    -- Sale activation
    COUNT(CASE WHEN afs.first_sale_date IS NOT NULL THEN 1 END) AS ever_sold,
    COUNT(CASE WHEN afs.first_sale_date <= ac.join_date + INTERVAL '30 days' THEN 1 END) AS sold_within_30d,
    COUNT(CASE WHEN afs.first_sale_date <= ac.join_date + INTERVAL '90 days' THEN 1 END) AS sold_within_90d,
    COUNT(CASE WHEN afs.first_sale_date <= ac.join_date + INTERVAL '180 days' THEN 1 END) AS sold_within_180d,

    -- Rates
    ROUND(COUNT(CASE WHEN afs.first_sale_date IS NOT NULL THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1) AS ever_activated_pct,
    ROUND(COUNT(CASE WHEN afs.first_sale_date <= ac.join_date + INTERVAL '30 days' THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1) AS activated_30d_pct,
    ROUND(COUNT(CASE WHEN afs.first_sale_date <= ac.join_date + INTERVAL '90 days' THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1) AS activated_90d_pct,

    -- Cohort health
    CASE
        WHEN COUNT(CASE WHEN afs.first_sale_date <= ac.join_date + INTERVAL '90 days' THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) > 0.10
             THEN 'GOOD: >10% activated within 90 days'
        WHEN COUNT(CASE WHEN afs.first_sale_date <= ac.join_date + INTERVAL '90 days' THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) > 0.05
             THEN 'ACCEPTABLE: 5-10% activated within 90 days'
        WHEN COUNT(CASE WHEN afs.first_sale_date IS NOT NULL THEN 1 END) > 0
             THEN 'POOR: <5% activation rate'
        ELSE 'BROKEN: 0% activation - investigate immediately'
    END AS cohort_health

FROM agent_cohorts ac
LEFT JOIN agent_first_sale afs ON afs.agent_id_text = ac.agent_id::TEXT
LEFT JOIN agent_first_quote afq ON afq.agent_id = ac.agent_id
GROUP BY ac.cohort_month
ORDER BY ac.cohort_month;


-- ============================================================================
-- 2.3 AGENT CHURN PREDICTION
-- ============================================================================
-- INSIGHT: Identifies agents who were previously active but are showing
--   declining activity - potential churners. Early detection enables
--   proactive intervention.
-- ACTION: Create a "save team" that reaches out to declining agents within
--   7 days of detection. Offer incentives, training, or problem resolution.
-- THRESHOLDS:
--   At Risk: Active last month but quotes dropped >50%
--   Churning: Was active 2 months ago, zero activity last month
--   Churned: Was active 3+ months ago, zero activity since
-- ============================================================================

WITH agent_monthly_activity AS (
    SELECT
        agent_id,
        DATE_TRUNC('month', quote_date) AS activity_month,
        SUM(quote_count) AS monthly_quotes
    FROM daily_quote_counts
    GROUP BY agent_id, DATE_TRUNC('month', quote_date)
),
agent_recent_months AS (
    SELECT
        agent_id,
        SUM(CASE WHEN activity_month = DATE_TRUNC('month', CURRENT_DATE) THEN monthly_quotes ELSE 0 END) AS current_month_quotes,
        SUM(CASE WHEN activity_month = DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month' THEN monthly_quotes ELSE 0 END) AS prev_month_quotes,
        SUM(CASE WHEN activity_month = DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '2 months' THEN monthly_quotes ELSE 0 END) AS two_months_ago_quotes,
        SUM(CASE WHEN activity_month = DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '3 months' THEN monthly_quotes ELSE 0 END) AS three_months_ago_quotes,
        MAX(activity_month) AS last_active_month
    FROM agent_monthly_activity
    GROUP BY agent_id
),
agent_sales AS (
    SELECT
        agent::TEXT AS agent_id_text,
        COUNT(*) AS total_sales,
        SUM(premium_amount) AS total_premium,
        MAX(sold_date) AS last_sale_date
    FROM sold_policies_data
    WHERE agent IS NOT NULL AND agent != ''
    GROUP BY agent::TEXT
)
SELECT
    arm.agent_id,
    u.fullname AS agent_name,
    u.saleschanneluserid AS broker_id,
    arm.current_month_quotes,
    arm.prev_month_quotes,
    arm.two_months_ago_quotes,
    arm.three_months_ago_quotes,
    arm.last_active_month,
    COALESCE(asales.total_sales, 0) AS lifetime_sales,
    COALESCE(asales.total_premium, 0) AS lifetime_premium,
    asales.last_sale_date,

    -- Churn classification
    CASE
        WHEN arm.prev_month_quotes > 10 AND arm.current_month_quotes = 0
             THEN 'CHURNING: Was active last month, zero activity now'
        WHEN arm.prev_month_quotes > 0 AND arm.current_month_quotes < arm.prev_month_quotes * 0.5
             THEN 'AT RISK: Activity dropped >50%'
        WHEN arm.two_months_ago_quotes > 10 AND arm.prev_month_quotes = 0 AND arm.current_month_quotes = 0
             THEN 'CHURNED: No activity for 2 months'
        WHEN arm.three_months_ago_quotes > 10 AND arm.two_months_ago_quotes = 0
             AND arm.prev_month_quotes = 0 AND arm.current_month_quotes = 0
             THEN 'LOST: No activity for 3+ months'
        ELSE NULL
    END AS churn_status,

    -- Revenue at risk
    CASE
        WHEN COALESCE(asales.total_sales, 0) > 0
             THEN ROUND(asales.total_premium / asales.total_sales, 0) -- avg premium per sale
             ELSE 0
    END AS avg_premium_per_sale,

    -- Priority score (higher = more important to save)
    COALESCE(asales.total_sales, 0) * 10 +
    arm.prev_month_quotes AS save_priority_score

FROM agent_recent_months arm
JOIN users u ON u.id = arm.agent_id
LEFT JOIN agent_sales asales ON asales.agent_id_text = arm.agent_id::TEXT
WHERE
    -- Only show agents showing decline patterns
    (arm.prev_month_quotes > 10 AND arm.current_month_quotes < arm.prev_month_quotes * 0.5)
    OR (arm.two_months_ago_quotes > 10 AND arm.prev_month_quotes = 0 AND arm.current_month_quotes = 0)
    OR (arm.prev_month_quotes > 10 AND arm.current_month_quotes = 0)
ORDER BY
    COALESCE(asales.total_sales, 0) DESC, arm.prev_month_quotes DESC;


-- ============================================================================
-- 2.4 AGENT SEGMENTATION (Star / Rising / Occasional / Dormant / Dead)
-- ============================================================================
-- INSIGHT: Segments all 76,917 agents into actionable categories with
--   specific recommended actions per segment.
-- ACTION:
--   Stars (top performers): Retain at all costs. Offer exclusive benefits.
--   Rising: Accelerate with training and higher-value leads.
--   Occasional: Nudge campaigns to increase frequency.
--   Dormant: Reactivation campaigns. Find out why they stopped.
--   Dead: Clean up or automated reactivation drip.
-- THRESHOLDS: Based on last 90 days of activity
-- ============================================================================

WITH agent_metrics AS (
    SELECT
        u.id AS agent_id,
        u.fullname,
        u.saleschanneluserid,
        u.createdat,
        u.lastlogin,
        COALESCE(sp.policy_count_90d, 0) AS policies_90d,
        COALESCE(sp.premium_90d, 0) AS premium_90d,
        COALESCE(sp.policy_count_30d, 0) AS policies_30d,
        COALESCE(dq.quotes_90d, 0) AS quotes_90d,
        COALESCE(dq.quotes_30d, 0) AS quotes_30d,
        COALESCE(sp.product_types, 0) AS unique_products
    FROM users u
    LEFT JOIN (
        SELECT
            agent::TEXT AS agent_text,
            COUNT(CASE WHEN sold_date >= CURRENT_DATE - INTERVAL '90 days' THEN 1 END) AS policy_count_90d,
            SUM(CASE WHEN sold_date >= CURRENT_DATE - INTERVAL '90 days' THEN premium_amount ELSE 0 END) AS premium_90d,
            COUNT(CASE WHEN sold_date >= CURRENT_DATE - INTERVAL '30 days' THEN 1 END) AS policy_count_30d,
            COUNT(DISTINCT CASE WHEN sold_date >= CURRENT_DATE - INTERVAL '90 days' THEN product_type END) AS product_types
        FROM sold_policies_data
        WHERE agent IS NOT NULL AND agent != ''
        GROUP BY agent::TEXT
    ) sp ON sp.agent_text = u.id::TEXT
    LEFT JOIN (
        SELECT
            agent_id,
            SUM(CASE WHEN quote_date >= CURRENT_DATE - INTERVAL '90 days' THEN quote_count ELSE 0 END) AS quotes_90d,
            SUM(CASE WHEN quote_date >= CURRENT_DATE - INTERVAL '30 days' THEN quote_count ELSE 0 END) AS quotes_30d
        FROM daily_quote_counts
        GROUP BY agent_id
    ) dq ON dq.agent_id = u.id
    WHERE u.deletedat IS NULL
)
SELECT
    CASE
        WHEN policies_30d >= 10 AND premium_90d > 0 THEN 'STAR'
        WHEN policies_90d >= 5 THEN 'RISING'
        WHEN policies_90d >= 1 OR quotes_90d >= 5 THEN 'OCCASIONAL'
        WHEN quotes_90d >= 1 OR (lastlogin >= CURRENT_DATE - INTERVAL '90 days') THEN 'DORMANT'
        ELSE 'DEAD'
    END AS segment,
    COUNT(*) AS agent_count,
    ROUND(COUNT(*)::NUMERIC / SUM(COUNT(*)) OVER () * 100, 1) AS pct_of_total,
    SUM(policies_90d) AS total_policies_90d,
    ROUND(SUM(premium_90d), 0) AS total_premium_90d,
    ROUND(AVG(policies_90d), 1) AS avg_policies_per_agent,
    SUM(quotes_90d) AS total_quotes_90d,

    -- Action for each segment
    CASE
        WHEN policies_30d >= 10 AND premium_90d > 0
             THEN 'RETAIN: White-glove support. Priority access to new products. Referral bonuses.'
        WHEN policies_90d >= 5
             THEN 'ACCELERATE: Assign dedicated success manager. Cross-sell training. Increase targets.'
        WHEN policies_90d >= 1 OR quotes_90d >= 5
             THEN 'ACTIVATE: Weekly nudges. Conversion assistance. Simplified quoting workflow.'
        WHEN quotes_90d >= 1 OR (lastlogin >= CURRENT_DATE - INTERVAL '90 days')
             THEN 'RE-ENGAGE: Reactivation campaign. Survey to understand barriers. Training webinars.'
        ELSE 'ASSESS: Automated drip campaigns. Bulk cleanup of truly inactive accounts after 6 months.'
    END AS recommended_action

FROM agent_metrics
GROUP BY
    CASE
        WHEN policies_30d >= 10 AND premium_90d > 0 THEN 'STAR'
        WHEN policies_90d >= 5 THEN 'RISING'
        WHEN policies_90d >= 1 OR quotes_90d >= 5 THEN 'OCCASIONAL'
        WHEN quotes_90d >= 1 OR (lastlogin >= CURRENT_DATE - INTERVAL '90 days') THEN 'DORMANT'
        ELSE 'DEAD'
    END
ORDER BY
    CASE
        WHEN policies_30d >= 10 AND premium_90d > 0 THEN 1
        WHEN policies_90d >= 5 THEN 2
        WHEN policies_90d >= 1 OR quotes_90d >= 5 THEN 3
        WHEN quotes_90d >= 1 OR (lastlogin >= CURRENT_DATE - INTERVAL '90 days') THEN 4
        ELSE 5
    END;


-- ============================================================================
-- 2.5 TIME-TO-FIRST-SALE ANALYSIS
-- ============================================================================
-- INSIGHT: How long does it take a new agent to make their first sale?
--   Understanding this timeline helps set expectations and identify
--   where the onboarding process needs acceleration.
-- ACTION: If median time-to-first-sale is > 30 days, the onboarding process
--   needs redesign. Set a target of 14 days and track progress.
-- ============================================================================

WITH agent_timeline AS (
    SELECT
        u.id AS agent_id,
        u.createdat AS join_date,
        MIN(sp.sold_date) AS first_sale_date,
        EXTRACT(DAY FROM MIN(sp.sold_date) - u.createdat) AS days_to_first_sale
    FROM users u
    JOIN sold_policies_data sp ON sp.agent::TEXT = u.id::TEXT
    WHERE u.deletedat IS NULL
      AND sp.sold_date IS NOT NULL
    GROUP BY u.id, u.createdat
)
SELECT
    COUNT(*) AS agents_with_sales,
    ROUND(AVG(days_to_first_sale), 0) AS avg_days_to_first_sale,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days_to_first_sale) AS median_days_to_first_sale,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY days_to_first_sale) AS p25_days,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY days_to_first_sale) AS p75_days,
    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY days_to_first_sale) AS p90_days,
    MIN(days_to_first_sale) AS fastest_activation,
    MAX(days_to_first_sale) AS slowest_activation,

    -- Distribution buckets
    COUNT(CASE WHEN days_to_first_sale <= 1 THEN 1 END) AS same_day,
    COUNT(CASE WHEN days_to_first_sale BETWEEN 2 AND 7 THEN 1 END) AS within_1_week,
    COUNT(CASE WHEN days_to_first_sale BETWEEN 8 AND 14 THEN 1 END) AS within_2_weeks,
    COUNT(CASE WHEN days_to_first_sale BETWEEN 15 AND 30 THEN 1 END) AS within_1_month,
    COUNT(CASE WHEN days_to_first_sale BETWEEN 31 AND 90 THEN 1 END) AS within_3_months,
    COUNT(CASE WHEN days_to_first_sale > 90 THEN 1 END) AS over_3_months
FROM agent_timeline;


-- ============================================================================
-- 2.6 AT-RISK AGENT IDENTIFICATION (Declining Activity)
-- ============================================================================
-- INSIGHT: Lists specific agents whose activity is declining week-over-week.
--   These are agents worth saving because they were productive.
-- ACTION: Assign each at-risk agent to a success manager within 48 hours.
--   Call to understand what changed. Offer support/incentives.
-- THRESHOLD: Any agent with >5 lifetime sales showing >50% activity decline
-- ============================================================================

WITH weekly_activity AS (
    SELECT
        agent_id,
        DATE_TRUNC('week', quote_date) AS activity_week,
        SUM(quote_count) AS weekly_quotes
    FROM daily_quote_counts
    WHERE quote_date >= CURRENT_DATE - INTERVAL '8 weeks'
    GROUP BY agent_id, DATE_TRUNC('week', quote_date)
),
agent_trend AS (
    SELECT
        agent_id,
        -- Last 2 weeks vs prior 2 weeks
        SUM(CASE WHEN activity_week >= DATE_TRUNC('week', CURRENT_DATE) - INTERVAL '2 weeks'
                 THEN weekly_quotes ELSE 0 END) AS recent_2w_quotes,
        SUM(CASE WHEN activity_week >= DATE_TRUNC('week', CURRENT_DATE) - INTERVAL '4 weeks'
                  AND activity_week < DATE_TRUNC('week', CURRENT_DATE) - INTERVAL '2 weeks'
                 THEN weekly_quotes ELSE 0 END) AS prior_2w_quotes
    FROM weekly_activity
    GROUP BY agent_id
),
agent_value AS (
    SELECT agent::TEXT AS agent_text,
           COUNT(*) AS lifetime_sales,
           SUM(premium_amount) AS lifetime_premium
    FROM sold_policies_data
    WHERE agent IS NOT NULL AND agent != ''
    GROUP BY agent::TEXT
)
SELECT
    at2.agent_id,
    u.fullname,
    u.phone,
    u.saleschanneluserid AS broker_id,
    at2.recent_2w_quotes,
    at2.prior_2w_quotes,
    ROUND((at2.recent_2w_quotes - at2.prior_2w_quotes)::NUMERIC /
          NULLIF(at2.prior_2w_quotes, 0) * 100, 0) AS activity_change_pct,
    COALESCE(av.lifetime_sales, 0) AS lifetime_sales,
    ROUND(COALESCE(av.lifetime_premium, 0), 0) AS lifetime_premium,
    'INTERVENTION NEEDED: Previously active agent showing declining activity' AS action_required
FROM agent_trend at2
JOIN users u ON u.id = at2.agent_id
LEFT JOIN agent_value av ON av.agent_text = at2.agent_id::TEXT
WHERE at2.prior_2w_quotes >= 10                           -- was meaningfully active
  AND at2.recent_2w_quotes < at2.prior_2w_quotes * 0.5    -- dropped >50%
  AND COALESCE(av.lifetime_sales, 0) >= 3                  -- has proven sales ability
ORDER BY COALESCE(av.lifetime_premium, 0) DESC
LIMIT 100;


-- ############################################################################
-- SECTION 3: SALES FUNNEL & CONVERSION
-- ############################################################################

-- ============================================================================
-- 3.1 QUOTE-TO-POLICY CONVERSION RATES BY PRODUCT
-- ============================================================================
-- INSIGHT: Which products convert best from quote to sale? The 4W conversion
--   rate sets the benchmark. If health quotes exist but never convert,
--   the issue may be pricing or product design, not demand.
-- ACTION: Products with conversion < half the 4W rate need product team
--   investigation. Check insurer pricing, UX flow, and eligibility criteria.
-- ============================================================================

WITH product_funnel AS (
    SELECT
        '4W' AS product,
        SUM("4w_quote_count") AS quotes,
        SUM("4w_proposal_count") AS proposals,
        SUM("4w_policy_count") AS policies,
        SUM("4w_policy_premium") AS premium
    FROM agent_wise_monthly_activity_summary
    WHERE activity_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    UNION ALL
    SELECT
        '2W',
        SUM("2w_quote_count"),
        SUM("2w_proposal_count"),
        SUM("2w_policy_count"),
        SUM("2w_policy_premium")
    FROM agent_wise_monthly_activity_summary
    WHERE activity_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    UNION ALL
    SELECT
        'Health',
        SUM(health_quote_count),
        SUM(health_proposal_count),
        SUM(health_policy_count),
        SUM(health_policy_premium)
    FROM agent_wise_monthly_activity_summary
    WHERE activity_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    UNION ALL
    SELECT
        'GCV',
        SUM(gcv_quote_count), SUM(gcv_proposal_count),
        SUM(gcv_policy_count), SUM(gcv_policy_premium)
    FROM agent_wise_monthly_activity_summary
    WHERE activity_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    UNION ALL
    SELECT
        'PCV',
        SUM(pcv_quote_count), SUM(pcv_proposal_count),
        SUM(pcv_policy_count), SUM(pcv_policy_premium)
    FROM agent_wise_monthly_activity_summary
    WHERE activity_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
)
SELECT
    product,
    COALESCE(quotes, 0) AS total_quotes,
    COALESCE(proposals, 0) AS total_proposals,
    COALESCE(policies, 0) AS total_policies,
    ROUND(COALESCE(premium, 0), 0) AS total_premium,

    CASE WHEN COALESCE(quotes, 0) > 0
         THEN ROUND(proposals::NUMERIC / quotes * 100, 1) ELSE 0 END AS quote_to_proposal_pct,
    CASE WHEN COALESCE(proposals, 0) > 0
         THEN ROUND(policies::NUMERIC / proposals * 100, 1) ELSE 0 END AS proposal_to_policy_pct,
    CASE WHEN COALESCE(quotes, 0) > 0
         THEN ROUND(policies::NUMERIC / quotes * 100, 1) ELSE 0 END AS overall_conversion_pct,

    -- Quotes needed per sale
    CASE WHEN COALESCE(policies, 0) > 0
         THEN ROUND(quotes::NUMERIC / policies, 1) ELSE NULL END AS quotes_per_sale,

    -- Drop-off volumes
    COALESCE(quotes, 0) - COALESCE(proposals, 0) AS lost_at_proposal,
    COALESCE(proposals, 0) - COALESCE(policies, 0) AS lost_at_policy

FROM product_funnel
WHERE COALESCE(quotes, 0) > 0
ORDER BY COALESCE(quotes, 0) DESC;


-- ============================================================================
-- 3.2 AGENTS QUOTING BUT NOT SELLING (The 2,291 Opportunity)
-- ============================================================================
-- INSIGHT: These agents are TRYING to sell but failing. They represent
--   the lowest-hanging fruit for conversion improvement. If even 10%
--   start converting, that is 229 new active agents.
-- ACTION: Segment these agents by quote volume. High-volume quoters need
--   conversion coaching. Low-volume quoters may need product training.
--   Build a targeted intervention program for this cohort.
-- THRESHOLD: Agent with 10+ quotes but 0 sales in 90 days = intervention target
-- ============================================================================

WITH quoting_agents AS (
    SELECT
        dq.agent_id,
        SUM(dq.quote_count) AS total_quotes_90d,
        COUNT(DISTINCT dq.quote_date) AS active_days_90d,
        MAX(dq.quote_date) AS last_quote_date
    FROM daily_quote_counts dq
    WHERE dq.quote_date >= CURRENT_DATE - INTERVAL '90 days'
      AND dq.quote_count > 0
    GROUP BY dq.agent_id
),
selling_agents AS (
    SELECT DISTINCT agent::TEXT AS agent_text
    FROM sold_policies_data
    WHERE sold_date >= CURRENT_DATE - INTERVAL '90 days'
      AND agent IS NOT NULL AND agent != ''
)
SELECT
    qa.agent_id,
    u.fullname AS agent_name,
    u.phone,
    u.saleschanneluserid AS broker_id,
    u.createdat AS joined_at,
    qa.total_quotes_90d,
    qa.active_days_90d,
    qa.last_quote_date,
    ROUND(qa.total_quotes_90d::NUMERIC / NULLIF(qa.active_days_90d, 0), 1) AS avg_quotes_per_active_day,

    -- Urgency classification
    CASE
        WHEN qa.total_quotes_90d >= 50 THEN 'HIGH PRIORITY: Heavy quoter, needs conversion coaching NOW'
        WHEN qa.total_quotes_90d >= 20 THEN 'MEDIUM PRIORITY: Regular quoter, needs conversion support'
        WHEN qa.total_quotes_90d >= 10 THEN 'STANDARD: Occasional quoter, needs engagement + training'
        ELSE 'LOW: Minimal quoting activity'
    END AS intervention_priority,

    -- Days since they joined (are these new agents struggling?)
    EXTRACT(DAY FROM CURRENT_DATE - u.createdat)::INTEGER AS days_since_joining

FROM quoting_agents qa
JOIN users u ON u.id = qa.agent_id
LEFT JOIN selling_agents sa ON sa.agent_text = qa.agent_id::TEXT
WHERE sa.agent_text IS NULL   -- Has NOT sold
  AND qa.total_quotes_90d >= 5
ORDER BY qa.total_quotes_90d DESC;


-- ============================================================================
-- 3.3 BREAKIN JOURNEY ANALYSIS
-- ============================================================================
-- INSIGHT: 31% of policies are breakin journey. Is this healthy? Compare
--   breakin vs non-breakin: premium, conversion, processing time.
-- ACTION: If breakin policies have significantly higher premiums, this is
--   a revenue opportunity. If they have lower conversion, fix the breakin
--   inspection flow. Track insurer-wise breakin acceptance rates.
-- ============================================================================

WITH breakin_analysis AS (
    SELECT
        CASE WHEN is_breakin_journey::TEXT = 'true' THEN 'Breakin' ELSE 'Non-Breakin' END AS journey_type,
        COUNT(*) AS policy_count,
        SUM(premium_amount) AS total_premium,
        AVG(premium_amount) AS avg_premium,
        SUM(net_premium) AS total_net_premium,
        AVG(net_premium) AS avg_net_premium,
        COUNT(DISTINCT agent) AS unique_agents,
        COUNT(DISTINCT insurer) AS unique_insurers,
        COUNT(CASE WHEN policy_business_type = 'New Policy' THEN 1 END) AS new_policies,
        COUNT(CASE WHEN policy_business_type = 'Renewal' THEN 1 END) AS renewals,
        COUNT(CASE WHEN policy_business_type = 'Roll Over' THEN 1 END) AS rollovers
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    GROUP BY CASE WHEN is_breakin_journey::TEXT = 'true' THEN 'Breakin' ELSE 'Non-Breakin' END
)
SELECT
    journey_type,
    policy_count,
    ROUND(policy_count::NUMERIC / SUM(policy_count) OVER () * 100, 1) AS pct_of_total,
    ROUND(total_premium, 0) AS total_premium,
    ROUND(avg_premium, 0) AS avg_premium,
    ROUND(avg_net_premium, 0) AS avg_net_premium,
    unique_agents,
    unique_insurers,
    new_policies,
    renewals,
    rollovers,
    -- Premium per agent comparison
    ROUND(total_premium / NULLIF(unique_agents, 0), 0) AS premium_per_agent
FROM breakin_analysis
ORDER BY policy_count DESC;


-- ============================================================================
-- 3.4 BREAKIN JOURNEY BY INSURER
-- ============================================================================
-- INSIGHT: Which insurers accept breakin most? This determines routing strategy.
-- ACTION: Route breakin leads to insurers with highest acceptance/conversion.
-- ============================================================================

SELECT
    insurer,
    COUNT(*) AS total_policies,
    COUNT(CASE WHEN is_breakin_journey::TEXT = 'true' THEN 1 END) AS breakin_policies,
    ROUND(COUNT(CASE WHEN is_breakin_journey::TEXT = 'true' THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1) AS breakin_pct,
    ROUND(AVG(CASE WHEN is_breakin_journey::TEXT = 'true' THEN premium_amount END), 0) AS avg_breakin_premium,
    ROUND(AVG(CASE WHEN is_breakin_journey::TEXT != 'true' THEN premium_amount END), 0) AS avg_non_breakin_premium
FROM sold_policies_data
WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
  AND insurer IS NOT NULL
GROUP BY insurer
HAVING COUNT(*) >= 10
ORDER BY COUNT(CASE WHEN is_breakin_journey::TEXT = 'true' THEN 1 END) DESC;


-- ############################################################################
-- SECTION 4: PRODUCT INTELLIGENCE
-- ############################################################################

-- ============================================================================
-- 4.1 PRODUCT MIX WITH REVENUE CONTRIBUTION
-- ============================================================================
-- INSIGHT: Detailed product breakdown showing volume, premium, and trend.
-- ACTION: Any product with >0 quotes but 0 sales needs immediate
--   investigation. Products with declining trends need product team review.
-- ============================================================================

SELECT
    product_type,
    SUM(policy_count) AS total_policies,
    ROUND(SUM(total_premium), 0) AS total_premium,
    ROUND(SUM(policy_count)::NUMERIC / SUM(SUM(policy_count)) OVER () * 100, 2) AS policy_share_pct,
    ROUND(SUM(total_premium) / SUM(SUM(total_premium)) OVER () * 100, 2) AS premium_share_pct,
    ROUND(SUM(total_premium) / NULLIF(SUM(policy_count), 0), 0) AS avg_ticket_size,
    -- Recent 3 month trend
    SUM(CASE WHEN sold_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '3 months'
             THEN policy_count ELSE 0 END) AS policies_last_3m,
    SUM(CASE WHEN sold_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
              AND sold_month < DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '3 months'
             THEN policy_count ELSE 0 END) AS policies_prior_3m
FROM category_wise_monthly_sold_policies
GROUP BY product_type
ORDER BY SUM(total_premium) DESC;


-- ============================================================================
-- 4.2 PRODUCT-WISE INSURER PERFORMANCE
-- ============================================================================
-- INSIGHT: Which insurer converts best for each product type? Determines
--   optimal insurer routing to maximize conversion.
-- ACTION: Default quote display should prioritize insurers with highest
--   conversion for that product. Deprioritize insurers with low conversion.
-- ============================================================================

SELECT
    product_type,
    insurer,
    COUNT(*) AS policies_sold,
    ROUND(SUM(premium_amount), 0) AS total_premium,
    ROUND(AVG(premium_amount), 0) AS avg_premium,
    ROUND(AVG(net_premium), 0) AS avg_net_premium,
    COUNT(DISTINCT agent) AS unique_agents,
    -- Share within product
    ROUND(COUNT(*)::NUMERIC / SUM(COUNT(*)) OVER (PARTITION BY product_type) * 100, 1) AS pct_within_product,
    RANK() OVER (PARTITION BY product_type ORDER BY COUNT(*) DESC) AS rank_within_product
FROM sold_policies_data
WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
  AND insurer IS NOT NULL
GROUP BY product_type, insurer
ORDER BY product_type, COUNT(*) DESC;


-- ============================================================================
-- 4.3 CROSS-SELL OPPORTUNITY IDENTIFICATION
-- ============================================================================
-- INSIGHT: Agents who sell only motor but whose customers also need health.
--   The top 20 agents all sell only 1 product type - massive cross-sell gap.
-- ACTION: For every motor sale, trigger a health cross-sell prompt.
--   Train top motor agents on health product. Set cross-sell targets.
-- ============================================================================

WITH agent_product_mix AS (
    SELECT
        agent,
        COUNT(*) AS total_policies,
        SUM(premium_amount) AS total_premium,
        COUNT(DISTINCT product_type) AS unique_products,
        COUNT(CASE WHEN product_type ILIKE '%car%' OR product_type ILIKE '%4w%' OR product_type ILIKE '%private%' THEN 1 END) AS motor_4w,
        COUNT(CASE WHEN product_type ILIKE '%two%' OR product_type ILIKE '%2w%' THEN 1 END) AS motor_2w,
        COUNT(CASE WHEN product_type ILIKE '%health%' THEN 1 END) AS health,
        COUNT(CASE WHEN product_type NOT ILIKE '%car%' AND product_type NOT ILIKE '%4w%'
                         AND product_type NOT ILIKE '%private%' AND product_type NOT ILIKE '%two%'
                         AND product_type NOT ILIKE '%2w%' AND product_type NOT ILIKE '%health%' THEN 1 END) AS other
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
      AND agent IS NOT NULL AND agent != ''
    GROUP BY agent
    HAVING COUNT(*) >= 5   -- at least 5 sales to be meaningful
)
SELECT
    agent,
    total_policies,
    ROUND(total_premium, 0) AS total_premium,
    unique_products,
    motor_4w,
    motor_2w,
    health,
    other,

    CASE
        WHEN unique_products = 1 AND motor_4w > 0
             THEN 'MONO-MOTOR: Cross-sell 2W + Health'
        WHEN unique_products = 1 AND motor_2w > 0
             THEN 'MONO-2W: Cross-sell 4W + Health'
        WHEN health = 0 AND (motor_4w + motor_2w) > 0
             THEN 'NO HEALTH: Train on health product'
        WHEN motor_2w = 0 AND motor_4w > 0
             THEN 'NO 2W: Easy cross-sell to 2W'
        ELSE 'DIVERSIFIED'
    END AS cross_sell_opportunity,

    -- Estimated opportunity: each motor customer is a potential health buyer
    -- Assume 5% conversion on cross-sell with avg health premium of 10,000
    ROUND((motor_4w + motor_2w) * 0.05 * 10000, 0) AS estimated_health_opportunity

FROM agent_product_mix
WHERE unique_products <= 2
ORDER BY total_policies DESC
LIMIT 200;


-- ============================================================================
-- 4.4 NEW vs RENEWAL vs ROLLOVER MIX AND TRENDS
-- ============================================================================
-- INSIGHT: Business type mix shows platform maturity. As the platform ages,
--   the renewal proportion should grow (lower acquisition cost, higher margin).
-- ACTION: If renewal % is declining, renewal capture is failing. If rollover
--   is high, customers are not getting competitive renewal quotes early enough.
-- THRESHOLD: Healthy mature platform: >30% renewals
-- ============================================================================

SELECT
    DATE_TRUNC('month', sold_date) AS sold_month,
    COUNT(*) AS total_policies,
    COUNT(CASE WHEN policy_business_type = 'New Policy' THEN 1 END) AS new_policies,
    COUNT(CASE WHEN policy_business_type = 'Renewal' THEN 1 END) AS renewals,
    COUNT(CASE WHEN policy_business_type = 'Roll Over' THEN 1 END) AS rollovers,
    -- Percentages
    ROUND(COUNT(CASE WHEN policy_business_type = 'New Policy' THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1) AS new_pct,
    ROUND(COUNT(CASE WHEN policy_business_type = 'Renewal' THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1) AS renewal_pct,
    ROUND(COUNT(CASE WHEN policy_business_type = 'Roll Over' THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1) AS rollover_pct,
    -- Premium by type
    ROUND(SUM(CASE WHEN policy_business_type = 'Renewal' THEN premium_amount ELSE 0 END), 0) AS renewal_premium,
    ROUND(AVG(CASE WHEN policy_business_type = 'Renewal' THEN premium_amount END), 0) AS avg_renewal_ticket,
    ROUND(AVG(CASE WHEN policy_business_type = 'New Policy' THEN premium_amount END), 0) AS avg_new_ticket
FROM sold_policies_data
WHERE sold_date >= '2023-01-01'
GROUP BY DATE_TRUNC('month', sold_date)
ORDER BY sold_month;


-- ############################################################################
-- SECTION 5: BROKER/CHANNEL DEEP DIVE
-- ############################################################################
-- NOTE: Detailed broker queries are in 02_broker_scorecard.sql.
-- This section contains summary views for the main dashboard.

-- ============================================================================
-- 5.1 BROKER TIER CLASSIFICATION
-- ============================================================================
-- INSIGHT: Quick view of broker distribution across tiers.
-- ACTION: Focus account management resources on Gold/Silver brokers
--   (highest growth potential). Platinum brokers need retention.
-- ============================================================================

WITH broker_volume AS (
    SELECT
        source AS broker_name,
        sales_channel_user_id,
        COUNT(*) AS total_policies,
        SUM(premium_amount) AS total_premium,
        COUNT(CASE WHEN sold_date >= CURRENT_DATE - INTERVAL '3 months' THEN 1 END) AS policies_3m
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '12 months'
    GROUP BY source, sales_channel_user_id
)
SELECT
    CASE
        WHEN policies_3m = 0 THEN 'INACTIVE'
        WHEN PERCENT_RANK() OVER (ORDER BY total_premium) >= 0.95 THEN 'PLATINUM'
        WHEN PERCENT_RANK() OVER (ORDER BY total_premium) >= 0.80 THEN 'GOLD'
        WHEN PERCENT_RANK() OVER (ORDER BY total_premium) >= 0.50 THEN 'SILVER'
        ELSE 'BRONZE'
    END AS tier,
    COUNT(*) AS broker_count,
    SUM(total_policies) AS total_policies,
    ROUND(SUM(total_premium), 0) AS total_premium,
    ROUND(AVG(total_policies), 0) AS avg_policies_per_broker,
    ROUND(SUM(total_premium) / NULLIF(SUM(SUM(total_premium)) OVER (), 0) * 100, 1) AS premium_share_pct
FROM broker_volume
GROUP BY
    CASE
        WHEN policies_3m = 0 THEN 'INACTIVE'
        WHEN PERCENT_RANK() OVER (ORDER BY total_premium) >= 0.95 THEN 'PLATINUM'
        WHEN PERCENT_RANK() OVER (ORDER BY total_premium) >= 0.80 THEN 'GOLD'
        WHEN PERCENT_RANK() OVER (ORDER BY total_premium) >= 0.50 THEN 'SILVER'
        ELSE 'BRONZE'
    END
ORDER BY
    CASE
        WHEN policies_3m = 0 THEN 'INACTIVE'
        WHEN PERCENT_RANK() OVER (ORDER BY total_premium) >= 0.95 THEN 'PLATINUM'
        WHEN PERCENT_RANK() OVER (ORDER BY total_premium) >= 0.80 THEN 'GOLD'
        WHEN PERCENT_RANK() OVER (ORDER BY total_premium) >= 0.50 THEN 'SILVER'
        ELSE 'BRONZE'
    END;


-- ============================================================================
-- 5.2 ZERO-CONVERSION BROKER ANALYSIS
-- ============================================================================
-- INSIGHT: 15+ brokers generate quotes but have zero policy conversions.
--   These are warm leads going cold.
-- ACTION: For each zero-conversion broker, investigate:
--   1. Are their agents trained? 2. Is pricing competitive?
--   3. Is the product mix right? 4. Are there technical issues?
-- ============================================================================

WITH broker_quotes AS (
    SELECT
        cw.sales_channel_id,
        cw.broker_name,
        SUM(
            COALESCE(cw."4w_quote_count", 0) + COALESCE(cw."2w_quote_count", 0) +
            COALESCE(cw.health_quote_count, 0) + COALESCE(cw.gcv_quote_count, 0) +
            COALESCE(cw.pcv_quote_count, 0)
        ) AS total_quotes,
        SUM(
            COALESCE(cw."4w_policy_count", 0) + COALESCE(cw."2w_policy_count", 0) +
            COALESCE(cw.health_policy_count, 0) + COALESCE(cw.gcv_policy_count, 0) +
            COALESCE(cw.pcv_policy_count, 0)
        ) AS total_policies
    FROM channel_wise_monthly_activity_summary cw
    WHERE cw.activity_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    GROUP BY cw.sales_channel_id, cw.broker_name
)
SELECT
    sales_channel_id,
    broker_name,
    total_quotes,
    total_policies,
    CASE
        WHEN total_quotes >= 100 AND total_policies = 0
             THEN 'CRITICAL: High quote volume, zero conversion. Immediate investigation needed.'
        WHEN total_quotes >= 20 AND total_policies = 0
             THEN 'HIGH PRIORITY: Meaningful quoting activity but no conversion.'
        WHEN total_quotes > 0 AND total_policies = 0
             THEN 'INVESTIGATE: Some quoting activity but no conversions.'
        ELSE 'No activity'
    END AS status,
    'Check: 1) Agent training 2) Insurer pricing 3) Product-market fit 4) Technical issues' AS investigation_checklist
FROM broker_quotes
WHERE total_policies = 0 AND total_quotes > 0
ORDER BY total_quotes DESC;


-- ############################################################################
-- SECTION 6: GEOGRAPHIC INTELLIGENCE
-- ############################################################################

-- ============================================================================
-- 6.1 STATE-WISE PERFORMANCE
-- ============================================================================
-- INSIGHT: Top 5 states (MH, KA, TS, TN, UP) drive most volume. Identifies
--   under-penetrated states with growth potential.
-- ACTION: For top states, invest in agent density. For under-penetrated
--   states with agent presence, diagnose conversion barriers.
-- ============================================================================

SELECT
    COALESCE(policy_holder_state, 'Unknown') AS state,
    COUNT(*) AS total_policies,
    ROUND(SUM(premium_amount), 0) AS total_premium,
    ROUND(AVG(premium_amount), 0) AS avg_premium,
    COUNT(DISTINCT agent) AS unique_agents,
    COUNT(DISTINCT insurer) AS unique_insurers,
    COUNT(DISTINCT product_type) AS unique_products,
    -- Market share
    ROUND(COUNT(*)::NUMERIC / SUM(COUNT(*)) OVER () * 100, 1) AS policy_share_pct,
    ROUND(SUM(premium_amount) / SUM(SUM(premium_amount)) OVER () * 100, 1) AS premium_share_pct,
    -- Efficiency
    ROUND(COUNT(*)::NUMERIC / NULLIF(COUNT(DISTINCT agent), 0), 1) AS policies_per_agent,
    -- Product mix
    COUNT(CASE WHEN product_type ILIKE '%car%' OR product_type ILIKE '%4w%' OR product_type ILIKE '%private%' THEN 1 END) AS motor_4w,
    COUNT(CASE WHEN product_type ILIKE '%health%' THEN 1 END) AS health,
    -- Business type
    COUNT(CASE WHEN policy_business_type = 'Renewal' THEN 1 END) AS renewals,
    ROUND(COUNT(CASE WHEN policy_business_type = 'Renewal' THEN 1 END)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1) AS renewal_pct
FROM sold_policies_data
WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
GROUP BY COALESCE(policy_holder_state, 'Unknown')
ORDER BY SUM(premium_amount) DESC;


-- ============================================================================
-- 6.2 UNDER-PENETRATED STATES
-- ============================================================================
-- INSIGHT: States where we have agents but low sales indicate either
--   market potential or agent quality issues.
-- ACTION: High agent count + low sales = training/support issue.
--   Low agent count + low sales = recruitment opportunity.
-- ============================================================================

WITH state_agents AS (
    -- Parse state from agent data (from additionalfieldsdata or broker assignment)
    SELECT
        COALESCE(sp.policy_holder_state, 'Unknown') AS state,
        COUNT(DISTINCT sp.agent) AS selling_agents,
        COUNT(*) AS policies
    FROM sold_policies_data sp
    WHERE sp.sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    GROUP BY COALESCE(sp.policy_holder_state, 'Unknown')
),
state_quotes AS (
    SELECT
        COALESCE(sp.policy_holder_state, 'Unknown') AS state,
        SUM(dq.quote_count) AS total_quotes
    FROM daily_quote_counts dq
    JOIN users u ON u.id = dq.agent_id
    LEFT JOIN LATERAL (
        SELECT DISTINCT policy_holder_state
        FROM sold_policies_data sp2
        WHERE sp2.agent = u.id::TEXT
        LIMIT 1
    ) sp ON TRUE
    WHERE dq.quote_date >= CURRENT_DATE - INTERVAL '90 days'
    GROUP BY COALESCE(sp.policy_holder_state, 'Unknown')
)
SELECT
    sa.state,
    sa.selling_agents,
    sa.policies,
    COALESCE(sq.total_quotes, 0) AS total_quotes,
    CASE WHEN COALESCE(sq.total_quotes, 0) > 0
         THEN ROUND(sa.policies::NUMERIC / sq.total_quotes * 100, 1) ELSE 0 END AS conversion_rate,
    ROUND(sa.policies::NUMERIC / NULLIF(sa.selling_agents, 0), 1) AS policies_per_agent,

    CASE
        WHEN sa.selling_agents >= 10 AND sa.policies::NUMERIC / NULLIF(sa.selling_agents, 0) < 5
             THEN 'UNDER-PERFORMING: Has agents but low productivity. Needs training.'
        WHEN sa.selling_agents < 5 AND COALESCE(sq.total_quotes, 0) > sa.policies * 3
             THEN 'HIGH POTENTIAL: Few agents but strong quoting. Recruit more agents.'
        WHEN sa.policies < 50
             THEN 'EARLY STAGE: Small market presence. Assess market potential.'
        ELSE 'ESTABLISHED: Monitor and optimize.'
    END AS state_assessment

FROM state_agents sa
LEFT JOIN state_quotes sq ON sq.state = sa.state
ORDER BY sa.policies ASC;


-- ############################################################################
-- SECTION 7: INSURER ANALYTICS
-- ############################################################################

-- ============================================================================
-- 7.1 INSURER MARKET SHARE ON PLATFORM
-- ============================================================================
-- INSIGHT: Which insurers dominate on this platform? Is there insurer
--   concentration risk similar to broker concentration risk?
-- ACTION: Ensure no single insurer >40% of volume. Negotiate better terms
--   with top insurers. Grow volume with under-represented insurers that
--   offer competitive pricing.
-- ============================================================================

SELECT
    insurer,
    COUNT(*) AS total_policies,
    ROUND(SUM(premium_amount), 0) AS total_premium,
    ROUND(AVG(premium_amount), 0) AS avg_premium,
    ROUND(COUNT(*)::NUMERIC / SUM(COUNT(*)) OVER () * 100, 1) AS policy_share_pct,
    ROUND(SUM(premium_amount) / SUM(SUM(premium_amount)) OVER () * 100, 1) AS premium_share_pct,
    COUNT(DISTINCT agent) AS unique_agents,
    COUNT(DISTINCT product_type) AS product_types,
    -- Trend: last 3m vs prior 3m
    COUNT(CASE WHEN sold_date >= CURRENT_DATE - INTERVAL '3 months' THEN 1 END) AS policies_last_3m,
    COUNT(CASE WHEN sold_date >= CURRENT_DATE - INTERVAL '6 months'
                AND sold_date < CURRENT_DATE - INTERVAL '3 months' THEN 1 END) AS policies_prior_3m,

    CASE
        WHEN COUNT(*)::NUMERIC / SUM(COUNT(*)) OVER () >= 0.30 THEN 'HIGH CONCENTRATION'
        WHEN COUNT(*)::NUMERIC / SUM(COUNT(*)) OVER () >= 0.15 THEN 'SIGNIFICANT SHARE'
        ELSE 'DIVERSIFIED'
    END AS concentration_flag

FROM sold_policies_data
WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
  AND insurer IS NOT NULL
GROUP BY insurer
ORDER BY SUM(premium_amount) DESC;


-- ============================================================================
-- 7.2 INSURER-WISE AVERAGE PREMIUM COMPARISON
-- ============================================================================
-- INSIGHT: Compare premium levels across insurers for same product type.
--   Helps understand pricing competitiveness and guides insurer routing.
-- ACTION: Route price-sensitive customers to lower-premium insurers.
--   Route high-IDV customers to insurers with better high-value pricing.
-- ============================================================================

SELECT
    insurer,
    product_type,
    COUNT(*) AS policies,
    ROUND(AVG(premium_amount), 0) AS avg_premium,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY premium_amount), 0) AS median_premium,
    ROUND(MIN(premium_amount), 0) AS min_premium,
    ROUND(MAX(premium_amount), 0) AS max_premium,
    ROUND(AVG(idv), 0) AS avg_idv,
    -- Compare to product average
    ROUND(AVG(premium_amount) - AVG(AVG(premium_amount)) OVER (PARTITION BY product_type), 0) AS premium_vs_product_avg
FROM sold_policies_data
WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
  AND insurer IS NOT NULL
  AND premium_amount > 0
GROUP BY insurer, product_type
HAVING COUNT(*) >= 5
ORDER BY product_type, AVG(premium_amount);


-- ############################################################################
-- SECTION 8: RENEWAL & RETENTION
-- ############################################################################

-- ============================================================================
-- 8.1 UPCOMING RENEWAL OPPORTUNITIES
-- ============================================================================
-- INSIGHT: Policies expiring in next 30/60/90 days represent the renewal
--   pipeline. Each expiring policy is a potential sale that requires
--   zero acquisition cost.
-- ACTION: Assign renewal leads to original selling agent 60 days before
--   expiry. Send customer reminder at 45 days. Escalate uncontacted
--   renewals at 15 days.
-- THRESHOLD: Aim for >40% renewal capture rate.
-- ============================================================================

SELECT
    CASE
        WHEN policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days' THEN 'Next 30 days'
        WHEN policy_expiry_date BETWEEN CURRENT_DATE + INTERVAL '30 days' AND CURRENT_DATE + INTERVAL '60 days' THEN '30-60 days'
        WHEN policy_expiry_date BETWEEN CURRENT_DATE + INTERVAL '60 days' AND CURRENT_DATE + INTERVAL '90 days' THEN '60-90 days'
    END AS expiry_window,
    COUNT(*) AS policies_expiring,
    ROUND(SUM(premium_amount), 0) AS premium_at_stake,
    ROUND(AVG(premium_amount), 0) AS avg_premium,
    COUNT(DISTINCT agent) AS unique_original_agents,
    COUNT(DISTINCT product_type) AS product_types,
    -- Product breakdown
    COUNT(CASE WHEN product_type ILIKE '%car%' OR product_type ILIKE '%4w%' OR product_type ILIKE '%private%' THEN 1 END) AS motor_4w_renewals,
    COUNT(CASE WHEN product_type ILIKE '%two%' OR product_type ILIKE '%2w%' THEN 1 END) AS motor_2w_renewals,
    COUNT(CASE WHEN product_type ILIKE '%health%' THEN 1 END) AS health_renewals
FROM sold_policies_data
WHERE policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days'
GROUP BY
    CASE
        WHEN policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days' THEN 'Next 30 days'
        WHEN policy_expiry_date BETWEEN CURRENT_DATE + INTERVAL '30 days' AND CURRENT_DATE + INTERVAL '60 days' THEN '30-60 days'
        WHEN policy_expiry_date BETWEEN CURRENT_DATE + INTERVAL '60 days' AND CURRENT_DATE + INTERVAL '90 days' THEN '60-90 days'
    END
ORDER BY
    CASE
        WHEN policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days' THEN 1
        WHEN policy_expiry_date BETWEEN CURRENT_DATE + INTERVAL '30 days' AND CURRENT_DATE + INTERVAL '60 days' THEN 2
        ELSE 3
    END;


-- ============================================================================
-- 8.2 AGENT-WISE RENEWAL PIPELINE
-- ============================================================================
-- INSIGHT: Each agent's upcoming renewal opportunities. Agents with large
--   renewal pipelines should be prioritized for retention.
-- ACTION: Share this pipeline with agents weekly. Set renewal targets.
--   Agents not pursuing renewals are leaving money on the table.
-- ============================================================================

SELECT
    sp.agent,
    u.fullname AS agent_name,
    COUNT(CASE WHEN sp.policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days' THEN 1 END) AS renewals_30d,
    COUNT(CASE WHEN sp.policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '60 days' THEN 1 END) AS renewals_60d,
    COUNT(CASE WHEN sp.policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days' THEN 1 END) AS renewals_90d,
    ROUND(SUM(CASE WHEN sp.policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days'
                   THEN sp.premium_amount ELSE 0 END), 0) AS renewal_premium_90d,
    -- How many of their total policies are up for renewal?
    COUNT(CASE WHEN sp.policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days' THEN 1 END)::NUMERIC AS renewal_count,
    COUNT(*) AS total_historic_policies,
    'Share renewal list with agent. Set target: capture 40%+ of renewals.' AS action
FROM sold_policies_data sp
LEFT JOIN users u ON u.id::TEXT = sp.agent::TEXT
WHERE sp.agent IS NOT NULL AND sp.agent != ''
GROUP BY sp.agent, u.fullname
HAVING COUNT(CASE WHEN sp.policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days' THEN 1 END) > 0
ORDER BY COUNT(CASE WHEN sp.policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days' THEN 1 END) DESC
LIMIT 100;


-- ============================================================================
-- 8.3 PREMIUM AT RISK OF CHURN (Overdue Renewals)
-- ============================================================================
-- INSIGHT: Policies that have already expired without renewal. This is
--   revenue that has been LOST unless we act quickly (within 90 days).
-- ACTION: For recently expired policies (< 30 days), aggressive outreach.
--   For 30-90 days expired, offer breakin journey facilitation.
--   Beyond 90 days, likely lost.
-- ============================================================================

SELECT
    CASE
        WHEN policy_expiry_date BETWEEN CURRENT_DATE - INTERVAL '30 days' AND CURRENT_DATE THEN 'Expired < 30 days (RECOVERABLE)'
        WHEN policy_expiry_date BETWEEN CURRENT_DATE - INTERVAL '60 days' AND CURRENT_DATE - INTERVAL '30 days' THEN 'Expired 30-60 days (URGENT)'
        WHEN policy_expiry_date BETWEEN CURRENT_DATE - INTERVAL '90 days' AND CURRENT_DATE - INTERVAL '60 days' THEN 'Expired 60-90 days (AT RISK)'
    END AS expiry_status,
    COUNT(*) AS policies,
    ROUND(SUM(premium_amount), 0) AS premium_at_risk,
    ROUND(AVG(premium_amount), 0) AS avg_premium,
    COUNT(DISTINCT agent) AS original_agents,
    'Immediate outreach campaign. Offer breakin inspection facilitation for expired policies.' AS action
FROM sold_policies_data
WHERE policy_expiry_date BETWEEN CURRENT_DATE - INTERVAL '90 days' AND CURRENT_DATE
  -- Exclude if they already renewed (check by vehicle/customer)
  AND vehicle_registration NOT IN (
      SELECT vehicle_registration
      FROM sold_policies_data
      WHERE sold_date >= CURRENT_DATE - INTERVAL '90 days'
        AND policy_business_type IN ('Renewal', 'Roll Over')
        AND vehicle_registration IS NOT NULL
  )
GROUP BY
    CASE
        WHEN policy_expiry_date BETWEEN CURRENT_DATE - INTERVAL '30 days' AND CURRENT_DATE THEN 'Expired < 30 days (RECOVERABLE)'
        WHEN policy_expiry_date BETWEEN CURRENT_DATE - INTERVAL '60 days' AND CURRENT_DATE - INTERVAL '30 days' THEN 'Expired 30-60 days (URGENT)'
        WHEN policy_expiry_date BETWEEN CURRENT_DATE - INTERVAL '90 days' AND CURRENT_DATE - INTERVAL '60 days' THEN 'Expired 60-90 days (AT RISK)'
    END
ORDER BY
    CASE
        WHEN policy_expiry_date BETWEEN CURRENT_DATE - INTERVAL '30 days' AND CURRENT_DATE THEN 1
        WHEN policy_expiry_date BETWEEN CURRENT_DATE - INTERVAL '60 days' AND CURRENT_DATE - INTERVAL '30 days' THEN 2
        ELSE 3
    END;


-- ############################################################################
-- SECTION 9: ACTIONABLE ALERTS (THE MOST IMPORTANT SECTION)
-- ############################################################################
-- These queries should be run daily and results sent as alerts/notifications
-- to relevant stakeholders.

-- ============================================================================
-- 9.1 AGENTS DECLINING IN ACTIVITY (This Month vs Last)
-- ============================================================================
-- INSIGHT: Agents whose activity THIS month is significantly below last
--   month. Early warning system for agent disengagement.
-- ACTION: Auto-trigger a "check-in" nudge via WhatsApp/SMS. If a high-value
--   agent, assign success manager for personal outreach within 48 hours.
-- THRESHOLD: Flag if activity drops >40% with at least 10 quotes last month
-- ============================================================================

WITH this_month AS (
    SELECT agent_id, SUM(quote_count) AS quotes
    FROM daily_quote_counts
    WHERE quote_date >= DATE_TRUNC('month', CURRENT_DATE)
    GROUP BY agent_id
),
last_month AS (
    SELECT agent_id, SUM(quote_count) AS quotes
    FROM daily_quote_counts
    WHERE quote_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month'
      AND quote_date < DATE_TRUNC('month', CURRENT_DATE)
    GROUP BY agent_id
),
agent_value AS (
    SELECT agent::TEXT AS agent_text, COUNT(*) AS sales, SUM(premium_amount) AS premium
    FROM sold_policies_data WHERE agent IS NOT NULL AND agent != '' GROUP BY agent::TEXT
)
SELECT
    lm.agent_id,
    u.fullname,
    u.phone,
    lm.quotes AS last_month_quotes,
    COALESCE(tm.quotes, 0) AS this_month_quotes,
    ROUND((COALESCE(tm.quotes, 0) - lm.quotes)::NUMERIC / lm.quotes * 100, 0) AS change_pct,
    COALESCE(av.sales, 0) AS lifetime_sales,
    ROUND(COALESCE(av.premium, 0), 0) AS lifetime_premium,
    CASE
        WHEN COALESCE(av.sales, 0) >= 50 THEN 'HIGH VALUE AGENT - Personal outreach within 24 hours'
        WHEN COALESCE(av.sales, 0) >= 10 THEN 'VALUABLE AGENT - Send incentive offer within 48 hours'
        ELSE 'STANDARD - Automated nudge campaign'
    END AS intervention_level
FROM last_month lm
LEFT JOIN this_month tm ON tm.agent_id = lm.agent_id
JOIN users u ON u.id = lm.agent_id
LEFT JOIN agent_value av ON av.agent_text = lm.agent_id::TEXT
WHERE lm.quotes >= 10
  AND COALESCE(tm.quotes, 0) < lm.quotes * 0.6  -- dropped >40%
ORDER BY COALESCE(av.premium, 0) DESC
LIMIT 50;


-- ============================================================================
-- 9.2 AGENTS WITH HIGH QUOTE VOLUME BUT ZERO SALES (Intervention Needed)
-- ============================================================================
-- INSIGHT: Current month agents generating many quotes but zero conversions.
--   These agents are working hard but failing at the conversion step.
-- ACTION: Assign conversion coaching. Review their quote history to identify
--   if it is pricing, product, or process issue. This is the #1 quick win.
-- THRESHOLD: 10+ quotes this month with 0 sales = intervention target
-- ============================================================================

WITH current_month_quotes AS (
    SELECT agent_id, SUM(quote_count) AS monthly_quotes, COUNT(DISTINCT quote_date) AS active_days
    FROM daily_quote_counts
    WHERE quote_date >= DATE_TRUNC('month', CURRENT_DATE)
    GROUP BY agent_id
    HAVING SUM(quote_count) >= 10
),
current_month_sales AS (
    SELECT DISTINCT agent::TEXT AS agent_text
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE)
      AND agent IS NOT NULL AND agent != ''
)
SELECT
    cmq.agent_id,
    u.fullname AS agent_name,
    u.phone,
    u.saleschanneluserid AS broker_id,
    cmq.monthly_quotes,
    cmq.active_days,
    ROUND(cmq.monthly_quotes::NUMERIC / NULLIF(cmq.active_days, 0), 1) AS quotes_per_day,
    EXTRACT(DAY FROM CURRENT_DATE - u.createdat)::INTEGER AS days_on_platform,
    'IMMEDIATE: Agent is actively trying but failing. Call to diagnose conversion blockers.' AS action_required
FROM current_month_quotes cmq
JOIN users u ON u.id = cmq.agent_id
LEFT JOIN current_month_sales cms ON cms.agent_text = cmq.agent_id::TEXT
WHERE cms.agent_text IS NULL
ORDER BY cmq.monthly_quotes DESC
LIMIT 50;


-- ============================================================================
-- 9.3 BROKERS WITH DECLINING CONVERSION RATES
-- ============================================================================
-- INSIGHT: Brokers whose quote-to-sale conversion is dropping.
-- ACTION: Schedule a call with broker management. Review if pricing,
--   product, or technical issues are causing the decline.
-- THRESHOLD: Conversion drop >30% from prior month
-- ============================================================================

WITH broker_monthly_conversion AS (
    SELECT
        cw.sales_channel_id,
        cw.broker_name,
        cw.activity_month,
        SUM(
            COALESCE(cw."4w_quote_count", 0) + COALESCE(cw."2w_quote_count", 0) +
            COALESCE(cw.health_quote_count, 0)
        ) AS monthly_quotes,
        SUM(
            COALESCE(cw."4w_policy_count", 0) + COALESCE(cw."2w_policy_count", 0) +
            COALESCE(cw.health_policy_count, 0)
        ) AS monthly_policies,
        CASE WHEN SUM(COALESCE(cw."4w_quote_count", 0) + COALESCE(cw."2w_quote_count", 0) +
                     COALESCE(cw.health_quote_count, 0)) > 0
             THEN ROUND(SUM(COALESCE(cw."4w_policy_count", 0) + COALESCE(cw."2w_policy_count", 0) +
                            COALESCE(cw.health_policy_count, 0))::NUMERIC /
                        SUM(COALESCE(cw."4w_quote_count", 0) + COALESCE(cw."2w_quote_count", 0) +
                            COALESCE(cw.health_quote_count, 0)) * 100, 2)
             ELSE 0 END AS conversion_rate
    FROM channel_wise_monthly_activity_summary cw
    GROUP BY cw.sales_channel_id, cw.broker_name, cw.activity_month
)
SELECT
    sales_channel_id,
    broker_name,
    activity_month,
    monthly_quotes,
    monthly_policies,
    conversion_rate,
    LAG(conversion_rate) OVER (PARTITION BY sales_channel_id ORDER BY activity_month) AS prev_month_conversion,
    conversion_rate - LAG(conversion_rate) OVER (PARTITION BY sales_channel_id ORDER BY activity_month) AS conversion_change,
    CASE
        WHEN LAG(conversion_rate) OVER (PARTITION BY sales_channel_id ORDER BY activity_month) > 0
             AND conversion_rate < LAG(conversion_rate) OVER (PARTITION BY sales_channel_id ORDER BY activity_month) * 0.7
             THEN 'ALERT: Conversion dropped >30%. Investigate immediately.'
        WHEN LAG(conversion_rate) OVER (PARTITION BY sales_channel_id ORDER BY activity_month) > 0
             AND conversion_rate < LAG(conversion_rate) OVER (PARTITION BY sales_channel_id ORDER BY activity_month) * 0.85
             THEN 'WARNING: Conversion declining. Monitor closely.'
        ELSE 'OK'
    END AS alert_status
FROM broker_monthly_conversion
WHERE activity_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '3 months'
  AND monthly_quotes >= 10
ORDER BY activity_month DESC, monthly_quotes DESC;


-- ============================================================================
-- 9.4 AGENTS WHO HAVENT LOGGED IN (Previously Active)
-- ============================================================================
-- INSIGHT: Agents who were logging in regularly but have stopped.
--   Different from never-active agents - these are agents we are LOSING.
-- ACTION:
--   7 days inactive: Automated "We miss you" nudge
--   14 days inactive: Personal check-in call
--   30 days inactive: Escalate to broker manager
-- ============================================================================

WITH login_history AS (
    SELECT
        adl.agent_id,
        MAX(adl.login_date) AS last_login_date,
        COUNT(DISTINCT adl.login_date) AS total_login_days,
        COUNT(DISTINCT CASE WHEN adl.login_date >= CURRENT_DATE - INTERVAL '60 days'
                             AND adl.login_date < CURRENT_DATE - INTERVAL '30 days'
                            THEN adl.login_date END) AS logins_30_60d_ago
    FROM agent_daily_logins adl
    GROUP BY adl.agent_id
),
agent_value AS (
    SELECT agent::TEXT AS agent_text, COUNT(*) AS sales, SUM(premium_amount) AS premium
    FROM sold_policies_data WHERE agent IS NOT NULL AND agent != '' GROUP BY agent::TEXT
)
SELECT
    lh.agent_id,
    u.fullname,
    u.phone,
    u.saleschanneluserid AS broker_id,
    lh.last_login_date,
    (CURRENT_DATE - lh.last_login_date) AS days_since_login,
    lh.total_login_days AS historic_login_days,
    COALESCE(av.sales, 0) AS lifetime_sales,
    ROUND(COALESCE(av.premium, 0), 0) AS lifetime_premium,

    CASE
        WHEN (CURRENT_DATE - lh.last_login_date) BETWEEN 7 AND 13
             THEN '7-DAY ALERT: Send "We miss you" nudge with incentive'
        WHEN (CURRENT_DATE - lh.last_login_date) BETWEEN 14 AND 29
             THEN '14-DAY ALERT: Personal phone call from success team'
        WHEN (CURRENT_DATE - lh.last_login_date) >= 30
             THEN '30-DAY ALERT: Escalate to broker manager. At risk of permanent loss.'
    END AS intervention_action

FROM login_history lh
JOIN users u ON u.id = lh.agent_id
LEFT JOIN agent_value av ON av.agent_text = lh.agent_id::TEXT
WHERE
    lh.logins_30_60d_ago >= 5                              -- was active 30-60 days ago
    AND lh.last_login_date < CURRENT_DATE - INTERVAL '7 days' -- hasn't logged in for 7+ days
ORDER BY
    COALESCE(av.premium, 0) DESC,
    (CURRENT_DATE - lh.last_login_date) DESC
LIMIT 100;


-- ============================================================================
-- 9.5 HIGH-VALUE RENEWAL OPPORTUNITIES AT RISK
-- ============================================================================
-- INSIGHT: Policies with premium > platform average expiring soon where
--   no renewal activity has been detected.
-- ACTION: Priority list for the renewal team. Each entry needs personal
--   agent + customer outreach. These are the highest-value renewals.
-- ============================================================================

WITH avg_premium AS (
    SELECT AVG(premium_amount) AS platform_avg
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
),
recent_renewals AS (
    SELECT DISTINCT vehicle_registration
    FROM sold_policies_data
    WHERE sold_date >= CURRENT_DATE - INTERVAL '90 days'
      AND policy_business_type IN ('Renewal', 'Roll Over')
      AND vehicle_registration IS NOT NULL
)
SELECT
    sp.id AS policy_id,
    sp.policy_number,
    sp.policy_holder_full_name,
    sp.phone AS customer_phone,
    sp.policy_holder_state,
    sp.product_type,
    sp.insurer,
    sp.vehicle_registration,
    sp.premium_amount,
    sp.policy_expiry_date,
    (sp.policy_expiry_date - CURRENT_DATE) AS days_to_expiry,
    sp.agent AS original_agent_id,
    u.fullname AS agent_name,
    u.phone AS agent_phone,
    'HIGH VALUE RENEWAL: Premium above platform average. Assign to original agent for personal outreach.' AS action
FROM sold_policies_data sp
CROSS JOIN avg_premium ap
LEFT JOIN users u ON u.id::TEXT = sp.agent::TEXT
LEFT JOIN recent_renewals rr ON rr.vehicle_registration = sp.vehicle_registration
WHERE sp.policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '60 days'
  AND sp.premium_amount > ap.platform_avg * 1.5   -- 50% above average
  AND rr.vehicle_registration IS NULL              -- no renewal detected yet
ORDER BY sp.premium_amount DESC
LIMIT 100;


-- ============================================================================
-- 9.6 NEW AGENTS WHO HAVENT GENERATED FIRST QUOTE IN 7 DAYS
-- ============================================================================
-- INSIGHT: Agents who joined in the last 30 days but haven't generated
--   a single quote within 7 days of joining. The 2024 cohort has 0%
--   activation - this alert catches the problem early.
-- ACTION: Day 3: Automated welcome + tutorial nudge. Day 7: Personal call
--   from onboarding team. Day 14: Escalate to broker for joint intervention.
-- THRESHOLD: Any new agent without a quote by day 7 = at risk
-- ============================================================================

WITH new_agents AS (
    SELECT
        u.id AS agent_id,
        u.fullname,
        u.phone,
        u.createdat AS joined_at,
        u.saleschanneluserid AS broker_id,
        u.lastlogin,
        EXTRACT(DAY FROM CURRENT_DATE - u.createdat)::INTEGER AS days_since_joining
    FROM users u
    WHERE u.deletedat IS NULL
      AND u.createdat >= CURRENT_DATE - INTERVAL '30 days'
),
first_quotes AS (
    SELECT agent_id, MIN(quote_date) AS first_quote_date
    FROM daily_quote_counts
    WHERE quote_count > 0
    GROUP BY agent_id
)
SELECT
    na.agent_id,
    na.fullname,
    na.phone,
    na.broker_id,
    na.joined_at,
    na.days_since_joining,
    na.lastlogin,
    fq.first_quote_date,

    CASE
        WHEN na.lastlogin IS NULL THEN 'NEVER LOGGED IN: Onboarding completely failed.'
        WHEN fq.first_quote_date IS NULL AND na.days_since_joining >= 14
             THEN 'CRITICAL: 14+ days, no quote. Escalate to broker manager.'
        WHEN fq.first_quote_date IS NULL AND na.days_since_joining >= 7
             THEN 'WARNING: 7+ days, no quote. Personal call from onboarding team.'
        WHEN fq.first_quote_date IS NULL AND na.days_since_joining >= 3
             THEN 'NUDGE: 3+ days, no quote. Send tutorial + incentive.'
        ELSE 'ON TRACK: Has generated first quote.'
    END AS status,

    CASE
        WHEN na.lastlogin IS NULL THEN 1  -- highest priority
        WHEN fq.first_quote_date IS NULL AND na.days_since_joining >= 14 THEN 2
        WHEN fq.first_quote_date IS NULL AND na.days_since_joining >= 7 THEN 3
        WHEN fq.first_quote_date IS NULL AND na.days_since_joining >= 3 THEN 4
        ELSE 5
    END AS priority_rank

FROM new_agents na
LEFT JOIN first_quotes fq ON fq.agent_id = na.agent_id
WHERE fq.first_quote_date IS NULL  -- no quote yet
ORDER BY priority_rank, na.days_since_joining DESC;


-- ============================================================================
-- 9.7 PRODUCTS WITH DECLINING SALES
-- ============================================================================
-- INSIGHT: Month-over-month product sales trend to catch declining products
--   early. Health is already dead (34 policies) - are other products
--   following the same path?
-- ACTION: Any product declining for 2+ consecutive months needs product
--   team investigation. Check pricing, insurer changes, competitive landscape.
-- ============================================================================

WITH monthly_product AS (
    SELECT
        product_type,
        sold_month,
        policy_count,
        total_premium,
        LAG(policy_count) OVER (PARTITION BY product_type ORDER BY sold_month) AS prev_month_policies,
        LAG(total_premium) OVER (PARTITION BY product_type ORDER BY sold_month) AS prev_month_premium
    FROM category_wise_monthly_sold_policies
    WHERE sold_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
)
SELECT
    product_type,
    sold_month,
    policy_count,
    ROUND(total_premium, 0) AS total_premium,
    prev_month_policies,
    CASE WHEN prev_month_policies > 0
         THEN ROUND((policy_count - prev_month_policies)::NUMERIC / prev_month_policies * 100, 1)
         ELSE NULL END AS policy_mom_change_pct,

    CASE
        WHEN prev_month_policies > 0 AND policy_count < prev_month_policies * 0.8
             THEN 'DECLINING >20%: Investigate insurer pricing and competitive landscape'
        WHEN prev_month_policies > 0 AND policy_count < prev_month_policies
             THEN 'SLIGHT DECLINE: Monitor next month'
        WHEN policy_count > COALESCE(prev_month_policies, 0) * 1.1
             THEN 'GROWING: Positive trend'
        ELSE 'STABLE'
    END AS trend_status

FROM monthly_product
ORDER BY product_type, sold_month;


-- ############################################################################
-- SECTION 10: DAILY OPERATIONAL QUERIES
-- ############################################################################

-- ============================================================================
-- 10.1 TODAY'S SALES SNAPSHOT
-- ============================================================================
-- INSIGHT: Real-time view of today's performance.
-- ACTION: If today's run rate is significantly below daily average,
--   investigate system issues or market events.
-- ============================================================================

WITH today AS (
    SELECT
        COUNT(*) AS policies_today,
        COALESCE(SUM(premium_amount), 0) AS premium_today,
        COUNT(DISTINCT agent) AS agents_selling_today,
        COUNT(DISTINCT source) AS brokers_active_today,
        COUNT(DISTINCT insurer) AS insurers_used_today
    FROM sold_policies_data
    WHERE sold_date = CURRENT_DATE
),
daily_avg AS (
    SELECT
        AVG(daily_count) AS avg_daily_policies,
        AVG(daily_premium) AS avg_daily_premium
    FROM (
        SELECT sold_date, COUNT(*) AS daily_count, SUM(premium_amount) AS daily_premium
        FROM sold_policies_data
        WHERE sold_date >= CURRENT_DATE - INTERVAL '30 days' AND sold_date < CURRENT_DATE
        GROUP BY sold_date
    ) daily
),
today_quotes AS (
    SELECT SUM(quote_count) AS quotes_today, COUNT(DISTINCT agent_id) AS agents_quoting
    FROM daily_quote_counts
    WHERE quote_date = CURRENT_DATE
)
SELECT
    t.policies_today,
    ROUND(t.premium_today, 0) AS premium_today,
    t.agents_selling_today,
    t.brokers_active_today,
    t.insurers_used_today,
    COALESCE(tq.quotes_today, 0) AS quotes_today,
    COALESCE(tq.agents_quoting, 0) AS agents_quoting_today,
    ROUND(da.avg_daily_policies, 0) AS avg_daily_policies_30d,
    ROUND(da.avg_daily_premium, 0) AS avg_daily_premium_30d,
    -- Performance vs average
    CASE WHEN da.avg_daily_policies > 0
         THEN ROUND(t.policies_today / da.avg_daily_policies * 100, 0)
         ELSE 0 END AS pct_of_daily_avg,
    -- Today's conversion rate
    CASE WHEN COALESCE(tq.quotes_today, 0) > 0
         THEN ROUND(t.policies_today::NUMERIC / tq.quotes_today * 100, 1)
         ELSE 0 END AS today_conversion_rate
FROM today t
CROSS JOIN daily_avg da
CROSS JOIN today_quotes tq;


-- ============================================================================
-- 10.2 THIS WEEK vs LAST WEEK COMPARISON
-- ============================================================================
-- INSIGHT: Week-over-week performance comparison. More stable than daily
--   comparisons which can be noisy.
-- ACTION: Consistent week-over-week decline (3+ weeks) = systemic issue.
-- ============================================================================

WITH this_week AS (
    SELECT
        COUNT(*) AS policies,
        SUM(premium_amount) AS premium,
        COUNT(DISTINCT agent) AS agents,
        COUNT(DISTINCT sold_date) AS selling_days
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('week', CURRENT_DATE)
),
last_week AS (
    SELECT
        COUNT(*) AS policies,
        SUM(premium_amount) AS premium,
        COUNT(DISTINCT agent) AS agents,
        COUNT(DISTINCT sold_date) AS selling_days
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('week', CURRENT_DATE) - INTERVAL '7 days'
      AND sold_date < DATE_TRUNC('week', CURRENT_DATE)
)
SELECT
    tw.policies AS this_week_policies,
    ROUND(tw.premium, 0) AS this_week_premium,
    tw.agents AS this_week_agents,
    tw.selling_days AS this_week_days,
    lw.policies AS last_week_policies,
    ROUND(lw.premium, 0) AS last_week_premium,
    lw.agents AS last_week_agents,
    -- Changes
    CASE WHEN lw.policies > 0
         THEN ROUND((tw.policies - lw.policies)::NUMERIC / lw.policies * 100, 1)
         ELSE NULL END AS policy_wow_pct,
    CASE WHEN lw.premium > 0
         THEN ROUND((tw.premium - lw.premium) / lw.premium * 100, 1)
         ELSE NULL END AS premium_wow_pct,
    -- Normalized (per selling day) to account for partial weeks
    CASE WHEN tw.selling_days > 0
         THEN ROUND(tw.policies::NUMERIC / tw.selling_days, 1) ELSE 0 END AS this_week_daily_rate,
    CASE WHEN lw.selling_days > 0
         THEN ROUND(lw.policies::NUMERIC / lw.selling_days, 1) ELSE 0 END AS last_week_daily_rate
FROM this_week tw
CROSS JOIN last_week lw;


-- ============================================================================
-- 10.3 REAL-TIME FUNNEL FOR CURRENT MONTH
-- ============================================================================
-- INSIGHT: Current month's quote-to-sale funnel across all products.
--   Shows how the month is progressing and whether conversion is on track.
-- ACTION: If conversion rate is below the 3-month average, something changed.
--   Investigate insurer API issues, pricing changes, or competitive moves.
-- ============================================================================

WITH current_month_funnel AS (
    SELECT
        SUM(
            COALESCE("4w_quote_count", 0) + COALESCE("2w_quote_count", 0) +
            COALESCE(health_quote_count, 0) + COALESCE(gcv_quote_count, 0) +
            COALESCE(pcv_quote_count, 0)
        ) AS total_quotes,
        SUM(
            COALESCE("4w_proposal_count", 0) + COALESCE("2w_proposal_count", 0) +
            COALESCE(health_proposal_count, 0) + COALESCE(gcv_proposal_count, 0) +
            COALESCE(pcv_proposal_count, 0)
        ) AS total_proposals,
        SUM(
            COALESCE("4w_policy_count", 0) + COALESCE("2w_policy_count", 0) +
            COALESCE(health_policy_count, 0) + COALESCE(gcv_policy_count, 0) +
            COALESCE(pcv_policy_count, 0)
        ) AS total_policies,
        SUM(
            COALESCE("4w_policy_premium", 0) + COALESCE("2w_policy_premium", 0) +
            COALESCE(health_policy_premium, 0) + COALESCE(gcv_policy_premium, 0) +
            COALESCE(pcv_policy_premium, 0)
        ) AS total_premium,
        COUNT(DISTINCT agent_id) AS active_agents
    FROM agent_wise_monthly_activity_summary
    WHERE activity_month = DATE_TRUNC('month', CURRENT_DATE)
),
avg_3m_conversion AS (
    SELECT
        CASE WHEN SUM(
            COALESCE("4w_quote_count", 0) + COALESCE("2w_quote_count", 0) +
            COALESCE(health_quote_count, 0)
        ) > 0
        THEN ROUND(
            SUM(COALESCE("4w_policy_count", 0) + COALESCE("2w_policy_count", 0) +
                COALESCE(health_policy_count, 0))::NUMERIC /
            SUM(COALESCE("4w_quote_count", 0) + COALESCE("2w_quote_count", 0) +
                COALESCE(health_quote_count, 0)) * 100, 2)
        ELSE 0 END AS avg_conversion
    FROM agent_wise_monthly_activity_summary
    WHERE activity_month >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '3 months'
      AND activity_month < DATE_TRUNC('month', CURRENT_DATE)
)
SELECT
    cmf.total_quotes AS mtd_quotes,
    cmf.total_proposals AS mtd_proposals,
    cmf.total_policies AS mtd_policies,
    ROUND(cmf.total_premium, 0) AS mtd_premium,
    cmf.active_agents AS mtd_active_agents,
    -- Conversion rates
    CASE WHEN cmf.total_quotes > 0
         THEN ROUND(cmf.total_proposals::NUMERIC / cmf.total_quotes * 100, 1) ELSE 0 END AS mtd_quote_to_proposal,
    CASE WHEN cmf.total_proposals > 0
         THEN ROUND(cmf.total_policies::NUMERIC / cmf.total_proposals * 100, 1) ELSE 0 END AS mtd_proposal_to_policy,
    CASE WHEN cmf.total_quotes > 0
         THEN ROUND(cmf.total_policies::NUMERIC / cmf.total_quotes * 100, 1) ELSE 0 END AS mtd_overall_conversion,
    -- Benchmark
    a3m.avg_conversion AS benchmark_3m_avg_conversion,
    -- Status
    CASE
        WHEN cmf.total_quotes > 0 AND
             cmf.total_policies::NUMERIC / cmf.total_quotes * 100 >= a3m.avg_conversion
             THEN 'ON TRACK: Conversion at or above 3-month average'
        WHEN cmf.total_quotes > 0 AND
             cmf.total_policies::NUMERIC / cmf.total_quotes * 100 >= a3m.avg_conversion * 0.8
             THEN 'WATCH: Conversion slightly below average (-20%)'
        WHEN cmf.total_quotes > 0
             THEN 'ALERT: Conversion significantly below average. Investigate immediately.'
        ELSE 'INSUFFICIENT DATA'
    END AS conversion_status
FROM current_month_funnel cmf
CROSS JOIN avg_3m_conversion a3m;


-- ============================================================================
-- 10.4 DAILY SALES TREND (Last 30 Days)
-- ============================================================================
-- INSIGHT: Day-by-day sales for trend spotting and anomaly detection.
-- ACTION: Any day with zero sales = system issue investigation.
--   Days significantly above average = study what worked.
-- ============================================================================

WITH daily_sales AS (
    SELECT
        sold_date,
        EXTRACT(DOW FROM sold_date) AS day_of_week,
        TO_CHAR(sold_date, 'Day') AS day_name,
        COUNT(*) AS policies,
        SUM(premium_amount) AS premium,
        COUNT(DISTINCT agent) AS agents
    FROM sold_policies_data
    WHERE sold_date >= CURRENT_DATE - INTERVAL '30 days'
    GROUP BY sold_date
),
stats AS (
    SELECT AVG(policies) AS avg_policies, STDDEV(policies) AS stddev_policies
    FROM daily_sales
)
SELECT
    ds.sold_date,
    ds.day_name,
    ds.policies,
    ROUND(ds.premium, 0) AS premium,
    ds.agents,
    ROUND(s.avg_policies, 0) AS avg_daily,
    CASE
        WHEN ds.policies > s.avg_policies + 2 * s.stddev_policies THEN 'EXCEPTIONAL (>2 std dev)'
        WHEN ds.policies > s.avg_policies THEN 'ABOVE AVERAGE'
        WHEN ds.policies > s.avg_policies - s.stddev_policies THEN 'NORMAL'
        WHEN ds.policies > 0 THEN 'BELOW AVERAGE'
        ELSE 'ZERO SALES - INVESTIGATE'
    END AS day_classification
FROM daily_sales ds
CROSS JOIN stats s
ORDER BY ds.sold_date DESC;


-- ============================================================================
-- 10.5 AGENT ACTIVITY HEATMAP BY DAY OF WEEK
-- ============================================================================
-- INSIGHT: Which days see the most agent activity and sales? Helps optimize
--   team scheduling and campaign timing.
-- ACTION: Run promotional campaigns on high-activity days.
--   Investigate if low-activity days are due to system downtime or market patterns.
-- ============================================================================

SELECT
    EXTRACT(DOW FROM sold_date) AS day_of_week_num,
    TO_CHAR(sold_date, 'Day') AS day_name,
    COUNT(*) AS total_policies,
    ROUND(SUM(premium_amount), 0) AS total_premium,
    COUNT(DISTINCT sold_date) AS num_weeks_in_data,
    ROUND(COUNT(*)::NUMERIC / NULLIF(COUNT(DISTINCT sold_date), 0), 1) AS avg_policies_per_day,
    COUNT(DISTINCT agent) AS total_unique_agents,
    ROUND(AVG(premium_amount), 0) AS avg_premium
FROM sold_policies_data
WHERE sold_date >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY EXTRACT(DOW FROM sold_date), TO_CHAR(sold_date, 'Day')
ORDER BY EXTRACT(DOW FROM sold_date);


-- ############################################################################
-- END OF DASHBOARD QUERIES
-- ############################################################################
-- IMPLEMENTATION NOTES:
--
-- 1. SCHEDULING: Section 9 (Alerts) should run daily at 9 AM. Results should
--    be sent as Slack/email notifications to relevant managers.
--
-- 2. CACHING: Section 1 (Executive Summary) and Section 10 (Daily Ops) should
--    be cached in platform_daily_snapshot (from 01_new_tables_schema.sql).
--
-- 3. PERMISSIONS: Create read-only database roles for dashboard tools.
--    Never run these against the primary database - use a read replica.
--
-- 4. PERFORMANCE: For queries touching sold_policies_data (294K+ rows),
--    ensure indexes exist on: sold_date, agent, sales_channel_user_id,
--    product_type, policy_expiry_date, insurer.
--
-- 5. REFRESH FREQUENCY:
--    - Section 1 (Executive): Every 15 minutes during business hours
--    - Section 2 (Agent Lifecycle): Daily
--    - Section 3 (Funnel): Hourly during business hours
--    - Section 4 (Product): Daily
--    - Section 5 (Broker): Daily
--    - Section 6 (Geography): Weekly
--    - Section 7 (Insurer): Daily
--    - Section 8 (Renewal): Daily
--    - Section 9 (Alerts): Every 4 hours
--    - Section 10 (Operational): Every 15 minutes
--
-- 6. RECOMMENDED INDEXES (if not already present on existing tables):
--    CREATE INDEX IF NOT EXISTS idx_spd_sold_date ON sold_policies_data(sold_date);
--    CREATE INDEX IF NOT EXISTS idx_spd_agent ON sold_policies_data(agent);
--    CREATE INDEX IF NOT EXISTS idx_spd_channel ON sold_policies_data(sales_channel_user_id);
--    CREATE INDEX IF NOT EXISTS idx_spd_product ON sold_policies_data(product_type);
--    CREATE INDEX IF NOT EXISTS idx_spd_expiry ON sold_policies_data(policy_expiry_date);
--    CREATE INDEX IF NOT EXISTS idx_spd_insurer ON sold_policies_data(insurer);
--    CREATE INDEX IF NOT EXISTS idx_spd_breakin ON sold_policies_data(is_breakin_journey);
--    CREATE INDEX IF NOT EXISTS idx_spd_business_type ON sold_policies_data(policy_business_type);
--    CREATE INDEX IF NOT EXISTS idx_dqc_date ON daily_quote_counts(quote_date);
--    CREATE INDEX IF NOT EXISTS idx_dqc_agent ON daily_quote_counts(agent_id);
--    CREATE INDEX IF NOT EXISTS idx_adl_date ON agent_daily_logins(login_date);
--    CREATE INDEX IF NOT EXISTS idx_users_channel ON users(saleschanneluserid);
--    CREATE INDEX IF NOT EXISTS idx_users_lastlogin ON users(lastlogin);
-- ############################################################################
