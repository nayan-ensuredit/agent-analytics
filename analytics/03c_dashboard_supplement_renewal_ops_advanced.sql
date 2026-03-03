-- ============================================================================
-- FILE 3C: DASHBOARD SUPPLEMENT - RENEWAL, OPERATIONS & ADVANCED ANALYTICS
-- ============================================================================
-- Supplements 03_actionable_dashboard_queries.sql with additional depth in:
--   Section 8 (Renewal & Retention) - deeper renewal cohort and forecasting
--   Section 9 (Alerts) - additional alert scenarios
--   Section 10 (Operations) - operational efficiency queries
--   NEW: Advanced Cross-Cutting Analytics (multi-dimensional insights)
--
-- PostgreSQL 14+ | All tables from existing schema
-- Every query includes INSIGHT, ACTION, and THRESHOLDS.
-- ============================================================================


-- ############################################################################
-- SECTION 8 SUPPLEMENT: RENEWAL & RETENTION (EXTENDED)
-- ############################################################################

-- ============================================================================
-- 8.4 RENEWAL CAPTURE RATE BY COHORT
-- ============================================================================
-- INSIGHT: For policies that expired in past months, what percentage were
--   actually renewed on this platform? The renewal capture rate is the
--   single most important metric for platform maturity.
--   Currently ~13% of business is renewal, which is low for a platform
--   with 294K historic policies.
-- ACTION: If capture rate is below 20%, the platform is failing at
--   retention. Invest in pre-expiry outreach automation. Each 1% increase
--   in capture rate = hundreds of zero-CAC policies.
-- THRESHOLDS:
--   Excellent: >40% capture rate
--   Good: 25-40%
--   Poor: 10-25%
--   Critical: <10% -- massive revenue leakage
-- ============================================================================

WITH expired_cohorts AS (
    -- Policies that expired in each month (the "renewal opportunity pool")
    SELECT
        DATE_TRUNC('month', policy_expiry_date) AS expiry_month,
        COUNT(*) AS policies_expired,
        ROUND(SUM(premium_amount), 0) AS premium_expired,
        COUNT(DISTINCT agent) AS unique_agents
    FROM sold_policies_data
    WHERE policy_expiry_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '12 months'
      AND policy_expiry_date < CURRENT_DATE
      AND vehicle_registration IS NOT NULL
    GROUP BY DATE_TRUNC('month', policy_expiry_date)
),
renewed_policies AS (
    -- Policies that were renewed (matched by vehicle_registration)
    SELECT
        DATE_TRUNC('month', orig.policy_expiry_date) AS expiry_month,
        COUNT(DISTINCT orig.vehicle_registration) AS vehicles_renewed,
        ROUND(SUM(renew.premium_amount), 0) AS renewal_premium_captured
    FROM sold_policies_data orig
    JOIN sold_policies_data renew
        ON renew.vehicle_registration = orig.vehicle_registration
        AND renew.policy_business_type IN ('Renewal', 'Roll Over')
        AND renew.sold_date BETWEEN orig.policy_expiry_date - INTERVAL '60 days'
            AND orig.policy_expiry_date + INTERVAL '90 days'
        AND renew.id != orig.id
    WHERE orig.policy_expiry_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '12 months'
      AND orig.policy_expiry_date < CURRENT_DATE
      AND orig.vehicle_registration IS NOT NULL
    GROUP BY DATE_TRUNC('month', orig.policy_expiry_date)
)
SELECT
    ec.expiry_month,
    ec.policies_expired AS renewal_opportunity_pool,
    ec.premium_expired AS premium_at_stake,
    COALESCE(rp.vehicles_renewed, 0) AS policies_captured,
    COALESCE(rp.renewal_premium_captured, 0) AS premium_captured,
    ROUND(COALESCE(rp.vehicles_renewed, 0)::NUMERIC / NULLIF(ec.policies_expired, 0) * 100, 1) AS capture_rate_pct,
    -- Revenue leakage
    ec.premium_expired - COALESCE(rp.renewal_premium_captured, 0) AS premium_leaked,
    ec.unique_agents,

    CASE
        WHEN COALESCE(rp.vehicles_renewed, 0)::NUMERIC / NULLIF(ec.policies_expired, 0) >= 0.40
             THEN 'EXCELLENT: >40% capture. Strong retention program.'
        WHEN COALESCE(rp.vehicles_renewed, 0)::NUMERIC / NULLIF(ec.policies_expired, 0) >= 0.25
             THEN 'GOOD: 25-40% capture. Continue optimizing.'
        WHEN COALESCE(rp.vehicles_renewed, 0)::NUMERIC / NULLIF(ec.policies_expired, 0) >= 0.10
             THEN 'POOR: 10-25% capture. Major retention improvement needed.'
        ELSE 'CRITICAL: <10% capture. Revenue hemorrhaging. Emergency intervention.'
    END AS capture_assessment

FROM expired_cohorts ec
LEFT JOIN renewed_policies rp ON rp.expiry_month = ec.expiry_month
ORDER BY ec.expiry_month;


-- ============================================================================
-- 8.5 RENEWAL FORECAST (Next 6 Months Pipeline)
-- ============================================================================
-- INSIGHT: Predicts future renewal volume and premium based on existing
--   policy expiry dates. Gives management a forward-looking view of the
--   renewal opportunity, enabling resource planning.
-- ACTION: Use this to staff renewal teams. Months with high expiry
--   volume need more outreach capacity. Start outreach 60 days before
--   the peak months.
-- ============================================================================

SELECT
    DATE_TRUNC('month', policy_expiry_date) AS expiry_month,
    COUNT(*) AS policies_expiring,
    ROUND(SUM(premium_amount), 0) AS total_premium_expiring,
    ROUND(AVG(premium_amount), 0) AS avg_premium,
    COUNT(DISTINCT agent) AS original_agents,
    COUNT(DISTINCT insurer) AS unique_insurers,
    -- Product breakdown
    COUNT(CASE WHEN product_type ILIKE '%car%' OR product_type ILIKE '%private%' THEN 1 END) AS motor_4w,
    COUNT(CASE WHEN product_type ILIKE '%two%' OR product_type ILIKE '%2w%' THEN 1 END) AS motor_2w,
    COUNT(CASE WHEN product_type ILIKE '%health%' THEN 1 END) AS health,
    -- Estimated capture (using historic rate as proxy, assumed 15% if unknown)
    ROUND(COUNT(*) * 0.15, 0) AS estimated_captures_at_15pct,
    ROUND(SUM(premium_amount) * 0.15, 0) AS estimated_premium_at_15pct,
    -- Optimistic scenario (30% capture)
    ROUND(COUNT(*) * 0.30, 0) AS optimistic_captures_at_30pct,
    ROUND(SUM(premium_amount) * 0.30, 0) AS optimistic_premium_at_30pct,
    -- Breakin risk: policies expiring more than 90 days from now may still lapse
    COUNT(CASE WHEN is_breakin_journey::TEXT = 'true' THEN 1 END) AS original_breakin_count,
    ROUND(COUNT(CASE WHEN is_breakin_journey::TEXT = 'true' THEN 1 END)::NUMERIC
          / NULLIF(COUNT(*), 0) * 100, 1) AS original_breakin_pct
FROM sold_policies_data
WHERE policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '6 months'
  AND vehicle_registration IS NOT NULL
GROUP BY DATE_TRUNC('month', policy_expiry_date)
ORDER BY expiry_month;


-- ============================================================================
-- 8.6 INSURER-WISE RENEWAL RETENTION
-- ============================================================================
-- INSIGHT: Do customers stay with the same insurer on renewal, or do they
--   switch? High insurer churn means customers are price-shopping and the
--   platform is enabling competitive renewals (good). Low insurer churn
--   may mean agents aren't quoting from multiple insurers (bad).
-- ACTION: If insurer retention is >80%, agents may not be showing
--   competitive quotes on renewal. Ensure the renewal flow shows quotes
--   from at least 3 insurers. If retention is <30%, the original insurer
--   pricing is not competitive.
-- ============================================================================

WITH renewal_pairs AS (
    SELECT
        orig.insurer AS original_insurer,
        renew.insurer AS renewal_insurer,
        orig.product_type,
        orig.premium_amount AS original_premium,
        renew.premium_amount AS renewal_premium,
        CASE WHEN orig.insurer = renew.insurer THEN 'RETAINED' ELSE 'SWITCHED' END AS retention_status
    FROM sold_policies_data orig
    JOIN sold_policies_data renew
        ON renew.vehicle_registration = orig.vehicle_registration
        AND renew.policy_business_type IN ('Renewal', 'Roll Over')
        AND renew.sold_date BETWEEN orig.policy_expiry_date - INTERVAL '60 days'
            AND orig.policy_expiry_date + INTERVAL '90 days'
        AND renew.id != orig.id
    WHERE orig.policy_expiry_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '12 months'
      AND orig.vehicle_registration IS NOT NULL
      AND orig.insurer IS NOT NULL
      AND renew.insurer IS NOT NULL
)
SELECT
    original_insurer,
    COUNT(*) AS total_renewals,
    COUNT(CASE WHEN retention_status = 'RETAINED' THEN 1 END) AS retained_with_same_insurer,
    COUNT(CASE WHEN retention_status = 'SWITCHED' THEN 1 END) AS switched_insurer,
    ROUND(COUNT(CASE WHEN retention_status = 'RETAINED' THEN 1 END)::NUMERIC
          / NULLIF(COUNT(*), 0) * 100, 1) AS insurer_retention_rate,
    -- Premium change on renewal
    ROUND(AVG(renewal_premium - original_premium), 0) AS avg_premium_change,
    ROUND(AVG((renewal_premium - original_premium) / NULLIF(original_premium, 0) * 100), 1) AS avg_premium_change_pct,
    -- Where do switchers go?
    MODE() WITHIN GROUP (ORDER BY CASE WHEN retention_status = 'SWITCHED' THEN renewal_insurer END)
        AS most_common_switch_target,

    CASE
        WHEN COUNT(CASE WHEN retention_status = 'RETAINED' THEN 1 END)::NUMERIC
             / NULLIF(COUNT(*), 0) > 0.80
             THEN 'VERY HIGH RETENTION: Are agents comparing quotes? Ensure competitive display.'
        WHEN COUNT(CASE WHEN retention_status = 'RETAINED' THEN 1 END)::NUMERIC
             / NULLIF(COUNT(*), 0) > 0.50
             THEN 'HEALTHY: Balanced retention with competitive switching.'
        WHEN COUNT(CASE WHEN retention_status = 'RETAINED' THEN 1 END)::NUMERIC
             / NULLIF(COUNT(*), 0) > 0.30
             THEN 'LOW RETENTION: Insurer pricing may not be competitive at renewal.'
        ELSE 'VERY LOW: Customers actively leaving this insurer. Review pricing.'
    END AS retention_assessment

FROM renewal_pairs
GROUP BY original_insurer
HAVING COUNT(*) >= 10
ORDER BY total_renewals DESC;


-- ============================================================================
-- 8.7 AGENT RENEWAL PERFORMANCE SCORECARD
-- ============================================================================
-- INSIGHT: Which agents are best at capturing renewals? Renewal performance
--   is a key indicator of agent quality - it requires customer relationship
--   management, proactive outreach, and platform skill.
-- ACTION: Reward top renewal agents. Train bottom performers using top
--   performers' playbook. Agents with >50 expiring policies and 0% capture
--   rate are leaving the most money on the table.
-- ============================================================================

WITH agent_expiries AS (
    SELECT
        agent,
        COUNT(*) AS total_expiring,
        ROUND(SUM(premium_amount), 0) AS premium_expiring
    FROM sold_policies_data
    WHERE policy_expiry_date BETWEEN CURRENT_DATE - INTERVAL '6 months' AND CURRENT_DATE
      AND agent IS NOT NULL AND agent != ''
      AND vehicle_registration IS NOT NULL
    GROUP BY agent
),
agent_captures AS (
    SELECT
        orig.agent,
        COUNT(DISTINCT orig.vehicle_registration) AS renewals_captured,
        ROUND(SUM(renew.premium_amount), 0) AS renewal_premium
    FROM sold_policies_data orig
    JOIN sold_policies_data renew
        ON renew.vehicle_registration = orig.vehicle_registration
        AND renew.policy_business_type IN ('Renewal', 'Roll Over')
        AND renew.sold_date BETWEEN orig.policy_expiry_date - INTERVAL '60 days'
            AND orig.policy_expiry_date + INTERVAL '90 days'
        AND renew.id != orig.id
    WHERE orig.policy_expiry_date BETWEEN CURRENT_DATE - INTERVAL '6 months' AND CURRENT_DATE
      AND orig.agent IS NOT NULL AND orig.agent != ''
      AND orig.vehicle_registration IS NOT NULL
    GROUP BY orig.agent
)
SELECT
    ae.agent,
    u.fullname AS agent_name,
    ae.total_expiring AS policies_expired,
    ae.premium_expiring,
    COALESCE(ac.renewals_captured, 0) AS renewals_captured,
    COALESCE(ac.renewal_premium, 0) AS renewal_premium_captured,
    ROUND(COALESCE(ac.renewals_captured, 0)::NUMERIC / NULLIF(ae.total_expiring, 0) * 100, 1) AS capture_rate_pct,
    ae.premium_expiring - COALESCE(ac.renewal_premium, 0) AS premium_leaked,

    CASE
        WHEN COALESCE(ac.renewals_captured, 0)::NUMERIC / NULLIF(ae.total_expiring, 0) >= 0.40
             THEN 'STAR RENEWER: Reward and study their process.'
        WHEN COALESCE(ac.renewals_captured, 0)::NUMERIC / NULLIF(ae.total_expiring, 0) >= 0.20
             THEN 'GOOD: Above average capture.'
        WHEN COALESCE(ac.renewals_captured, 0) > 0
             THEN 'BELOW AVERAGE: Needs renewal training.'
        ELSE 'ZERO CAPTURES: Premium leaked entirely. Urgent intervention.'
    END AS renewal_grade,

    CASE
        WHEN ae.total_expiring >= 50 AND COALESCE(ac.renewals_captured, 0) = 0
             THEN 'TOP PRIORITY: 50+ policies, zero captures. Highest revenue leakage.'
        WHEN ae.total_expiring >= 20 AND COALESCE(ac.renewals_captured, 0) = 0
             THEN 'HIGH PRIORITY: Significant leakage.'
        ELSE NULL
    END AS leakage_alert

FROM agent_expiries ae
LEFT JOIN agent_captures ac ON ac.agent = ae.agent
LEFT JOIN users u ON u.id::TEXT = ae.agent::TEXT
ORDER BY ae.premium_expiring DESC
LIMIT 200;


-- ============================================================================
-- 8.8 RENEWAL TIMING ANALYSIS (How Early Do Renewals Happen?)
-- ============================================================================
-- INSIGHT: When do renewals actually occur relative to expiry date? Do
--   customers renew early (before expiry) or late (after lapse = breakin)?
--   Earlier renewals = better customer experience and lower breakin rate.
-- ACTION: If most renewals happen AFTER expiry, the outreach is too late.
--   Move the reminder schedule earlier. Target: majority of renewals
--   should happen 15-30 days before expiry.
-- ============================================================================

WITH renewal_timing AS (
    SELECT
        renew.id,
        orig.policy_expiry_date,
        renew.sold_date AS renewal_date,
        (renew.sold_date - orig.policy_expiry_date) AS days_vs_expiry,
        orig.premium_amount AS original_premium,
        renew.premium_amount AS renewal_premium,
        renew.product_type,
        renew.insurer
    FROM sold_policies_data orig
    JOIN sold_policies_data renew
        ON renew.vehicle_registration = orig.vehicle_registration
        AND renew.policy_business_type IN ('Renewal', 'Roll Over')
        AND renew.sold_date BETWEEN orig.policy_expiry_date - INTERVAL '60 days'
            AND orig.policy_expiry_date + INTERVAL '90 days'
        AND renew.id != orig.id
    WHERE orig.policy_expiry_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '12 months'
      AND orig.vehicle_registration IS NOT NULL
)
SELECT
    CASE
        WHEN days_vs_expiry < -30 THEN 'A: Very Early (>30 days before expiry)'
        WHEN days_vs_expiry < -15 THEN 'B: Early (15-30 days before)'
        WHEN days_vs_expiry < 0 THEN 'C: Just Before (0-15 days before)'
        WHEN days_vs_expiry = 0 THEN 'D: On Expiry Day'
        WHEN days_vs_expiry <= 15 THEN 'E: Shortly After (1-15 days lapsed)'
        WHEN days_vs_expiry <= 30 THEN 'F: Late (15-30 days lapsed = breakin risk)'
        WHEN days_vs_expiry <= 60 THEN 'G: Very Late (30-60 days lapsed = definite breakin)'
        ELSE 'H: Extremely Late (60-90 days lapsed)'
    END AS timing_bucket,
    COUNT(*) AS renewal_count,
    ROUND(COUNT(*)::NUMERIC / SUM(COUNT(*)) OVER () * 100, 1) AS pct_of_all_renewals,
    ROUND(AVG(renewal_premium), 0) AS avg_renewal_premium,
    ROUND(AVG(renewal_premium - original_premium), 0) AS avg_premium_change,
    ROUND(AVG((renewal_premium - original_premium) / NULLIF(original_premium, 0) * 100), 1) AS avg_premium_change_pct,

    CASE
        WHEN days_vs_expiry < 0 THEN 'PRE-EXPIRY: Ideal. No lapse, no breakin.'
        WHEN days_vs_expiry <= 15 THEN 'SLIGHT LAPSE: Acceptable but could improve.'
        ELSE 'POST-LAPSE: Breakin journey likely needed. Worse customer experience.'
    END AS quality_assessment

FROM renewal_timing
GROUP BY
    CASE
        WHEN days_vs_expiry < -30 THEN 'A: Very Early (>30 days before expiry)'
        WHEN days_vs_expiry < -15 THEN 'B: Early (15-30 days before)'
        WHEN days_vs_expiry < 0 THEN 'C: Just Before (0-15 days before)'
        WHEN days_vs_expiry = 0 THEN 'D: On Expiry Day'
        WHEN days_vs_expiry <= 15 THEN 'E: Shortly After (1-15 days lapsed)'
        WHEN days_vs_expiry <= 30 THEN 'F: Late (15-30 days lapsed = breakin risk)'
        WHEN days_vs_expiry <= 60 THEN 'G: Very Late (30-60 days lapsed = definite breakin)'
        ELSE 'H: Extremely Late (60-90 days lapsed)'
    END
ORDER BY timing_bucket;


-- ############################################################################
-- SECTION 9 SUPPLEMENT: ADDITIONAL ACTIONABLE ALERTS
-- ############################################################################

-- ============================================================================
-- 9.8 INSURER API/PRICING ANOMALY DETECTION
-- ============================================================================
-- INSIGHT: If an insurer's share suddenly drops, it could be a pricing
--   change or API outage. This query compares this week's insurer share
--   to the 4-week average to detect anomalies.
-- ACTION: If an insurer's share drops >40% from its 4-week average,
--   immediately check: 1) API health 2) Recent pricing changes 3) Product
--   availability. This is often the earliest signal of a technical issue.
-- THRESHOLDS:
--   Normal variance: +/- 20% from 4-week average
--   Anomaly: >30% deviation
--   Critical: >50% deviation
-- ============================================================================

WITH weekly_insurer AS (
    SELECT
        insurer,
        DATE_TRUNC('week', sold_date) AS sold_week,
        COUNT(*) AS weekly_policies,
        ROUND(SUM(premium_amount), 0) AS weekly_premium
    FROM sold_policies_data
    WHERE sold_date >= CURRENT_DATE - INTERVAL '5 weeks'
      AND insurer IS NOT NULL
    GROUP BY insurer, DATE_TRUNC('week', sold_date)
),
insurer_avg AS (
    SELECT
        insurer,
        ROUND(AVG(weekly_policies), 0) AS avg_weekly_policies,
        ROUND(AVG(weekly_premium), 0) AS avg_weekly_premium
    FROM weekly_insurer
    WHERE sold_week < DATE_TRUNC('week', CURRENT_DATE)  -- exclude current week
    GROUP BY insurer
),
current_week AS (
    SELECT
        insurer,
        weekly_policies,
        weekly_premium
    FROM weekly_insurer
    WHERE sold_week = DATE_TRUNC('week', CURRENT_DATE)
)
SELECT
    ia.insurer,
    COALESCE(cw.weekly_policies, 0) AS this_week_policies,
    ia.avg_weekly_policies AS four_week_avg_policies,
    COALESCE(cw.weekly_premium, 0) AS this_week_premium,
    ia.avg_weekly_premium AS four_week_avg_premium,

    -- Deviation percentage
    CASE WHEN ia.avg_weekly_policies > 0
         THEN ROUND((COALESCE(cw.weekly_policies, 0) - ia.avg_weekly_policies)::NUMERIC
                     / ia.avg_weekly_policies * 100, 1)
         ELSE NULL END AS volume_deviation_pct,

    CASE
        WHEN COALESCE(cw.weekly_policies, 0) = 0 AND ia.avg_weekly_policies > 10
             THEN 'CRITICAL: Zero policies this week. Possible API outage or product removal.'
        WHEN ia.avg_weekly_policies > 0
             AND COALESCE(cw.weekly_policies, 0)::NUMERIC / ia.avg_weekly_policies < 0.50
             THEN 'ANOMALY: Volume dropped >50% from average. Investigate immediately.'
        WHEN ia.avg_weekly_policies > 0
             AND COALESCE(cw.weekly_policies, 0)::NUMERIC / ia.avg_weekly_policies < 0.70
             THEN 'WARNING: Volume dropped >30%. Monitor and investigate.'
        WHEN ia.avg_weekly_policies > 0
             AND COALESCE(cw.weekly_policies, 0)::NUMERIC / ia.avg_weekly_policies > 1.50
             THEN 'SURGE: Volume up >50%. Check for pricing advantage or competitor outage.'
        ELSE 'NORMAL'
    END AS anomaly_status,

    'Check: 1) API uptime/errors 2) Pricing changes 3) Product availability 4) Competitor moves' AS investigation_steps

FROM insurer_avg ia
LEFT JOIN current_week cw ON cw.insurer = ia.insurer
WHERE ia.avg_weekly_policies >= 5  -- only meaningful insurers
ORDER BY
    CASE WHEN COALESCE(cw.weekly_policies, 0) = 0 AND ia.avg_weekly_policies > 10 THEN 0
         WHEN ia.avg_weekly_policies > 0
              AND COALESCE(cw.weekly_policies, 0)::NUMERIC / ia.avg_weekly_policies < 0.50 THEN 1
         ELSE 2 END,
    ia.avg_weekly_policies DESC;


-- ============================================================================
-- 9.9 BROKER AGENTS GOING DORMANT (Broker-Level Churn Risk)
-- ============================================================================
-- INSIGHT: For each broker, how many of their agents are going dormant?
--   If a broker's agent base is shrinking, the broker relationship is
--   at risk. This is an early warning for broker churn.
-- ACTION: Brokers with >30% agent dormancy need a relationship review
--   meeting. Share this data with broker account managers for action.
-- ============================================================================

WITH broker_agent_status AS (
    SELECT
        u.saleschanneluserid AS broker_id,
        COUNT(*) AS total_agents,
        COUNT(CASE WHEN u.lastlogin >= CURRENT_DATE - INTERVAL '30 days' THEN 1 END) AS active_30d,
        COUNT(CASE WHEN u.lastlogin >= CURRENT_DATE - INTERVAL '60 days'
                        AND u.lastlogin < CURRENT_DATE - INTERVAL '30 days' THEN 1 END) AS active_30_60d,
        COUNT(CASE WHEN u.lastlogin < CURRENT_DATE - INTERVAL '60 days' OR u.lastlogin IS NULL THEN 1 END) AS dormant_60d_plus
    FROM users u
    WHERE u.deletedat IS NULL
      AND u.saleschanneluserid IS NOT NULL
    GROUP BY u.saleschanneluserid
    HAVING COUNT(*) >= 5  -- meaningful broker size
),
broker_sales AS (
    SELECT
        sales_channel_user_id,
        source,
        COUNT(*) AS recent_policies,
        ROUND(SUM(premium_amount), 0) AS recent_premium
    FROM sold_policies_data
    WHERE sold_date >= CURRENT_DATE - INTERVAL '90 days'
    GROUP BY sales_channel_user_id, source
)
SELECT
    bas.broker_id,
    bs.source AS broker_name,
    bas.total_agents,
    bas.active_30d,
    bas.active_30_60d,
    bas.dormant_60d_plus,
    ROUND(bas.dormant_60d_plus::NUMERIC / NULLIF(bas.total_agents, 0) * 100, 1) AS dormancy_rate,
    COALESCE(bs.recent_policies, 0) AS policies_last_90d,
    COALESCE(bs.recent_premium, 0) AS premium_last_90d,

    CASE
        WHEN bas.dormant_60d_plus::NUMERIC / NULLIF(bas.total_agents, 0) > 0.60
             THEN 'CRITICAL: >60% agents dormant. Broker relationship at serious risk.'
        WHEN bas.dormant_60d_plus::NUMERIC / NULLIF(bas.total_agents, 0) > 0.40
             THEN 'HIGH RISK: >40% agents dormant. Schedule broker review meeting.'
        WHEN bas.dormant_60d_plus::NUMERIC / NULLIF(bas.total_agents, 0) > 0.25
             THEN 'MODERATE: >25% dormant. Monitor and re-engage.'
        ELSE 'HEALTHY: Most agents active.'
    END AS churn_risk_level,

    'Action: 1) Share dormant agent list with broker 2) Co-create reactivation plan 3) Review platform issues' AS recommended_action

FROM broker_agent_status bas
LEFT JOIN broker_sales bs ON bs.sales_channel_user_id::TEXT = bas.broker_id::TEXT
ORDER BY bas.dormant_60d_plus::NUMERIC / NULLIF(bas.total_agents, 0) DESC;


-- ============================================================================
-- 9.10 DAILY VELOCITY CHECK (Is Today On Track?)
-- ============================================================================
-- INSIGHT: Compare today's policy count to the same day-of-week average
--   from the past 4 weeks. If today is significantly below, something
--   may be wrong (API issue, platform bug, insurer problem).
-- ACTION: If by noon the day is tracking 40%+ below average, check
--   platform health dashboard. If by 3pm still below, alert ops team.
-- ============================================================================

WITH same_dow_history AS (
    SELECT
        ROUND(AVG(daily_count), 1) AS avg_daily_policies,
        ROUND(AVG(daily_premium), 0) AS avg_daily_premium,
        COUNT(*) AS weeks_of_data
    FROM (
        SELECT
            sold_date,
            COUNT(*) AS daily_count,
            SUM(premium_amount) AS daily_premium
        FROM sold_policies_data
        WHERE sold_date >= CURRENT_DATE - INTERVAL '28 days'
          AND sold_date < CURRENT_DATE
          AND EXTRACT(DOW FROM sold_date) = EXTRACT(DOW FROM CURRENT_DATE)
        GROUP BY sold_date
    ) daily
),
today_so_far AS (
    SELECT
        COUNT(*) AS today_policies,
        ROUND(SUM(premium_amount), 0) AS today_premium,
        COUNT(DISTINCT agent) AS today_agents,
        COUNT(DISTINCT insurer) AS today_insurers
    FROM sold_policies_data
    WHERE sold_date = CURRENT_DATE
)
SELECT
    tsf.today_policies,
    tsf.today_premium,
    tsf.today_agents,
    tsf.today_insurers,
    sdh.avg_daily_policies AS same_dow_avg_policies,
    sdh.avg_daily_premium AS same_dow_avg_premium,
    sdh.weeks_of_data,
    CASE WHEN sdh.avg_daily_policies > 0
         THEN ROUND(tsf.today_policies / sdh.avg_daily_policies * 100, 0)
         ELSE NULL END AS pacing_pct,

    CASE
        WHEN sdh.avg_daily_policies > 0 AND tsf.today_policies >= sdh.avg_daily_policies
             THEN 'ON TRACK or AHEAD: Good day.'
        WHEN sdh.avg_daily_policies > 0 AND tsf.today_policies >= sdh.avg_daily_policies * 0.6
             THEN 'SLIGHTLY BEHIND: Monitor through the day.'
        WHEN sdh.avg_daily_policies > 0 AND tsf.today_policies >= sdh.avg_daily_policies * 0.3
             THEN 'SIGNIFICANTLY BEHIND: Check platform health and insurer APIs.'
        WHEN sdh.avg_daily_policies > 0
             THEN 'CRITICAL: Way below average. Possible outage or major issue.'
        ELSE 'INSUFFICIENT HISTORICAL DATA'
    END AS pacing_status

FROM today_so_far tsf
CROSS JOIN same_dow_history sdh;


-- ############################################################################
-- SECTION 10 SUPPLEMENT: DAILY OPERATIONS (EXTENDED)
-- ############################################################################

-- ============================================================================
-- 10.6 AGENT LOGIN ENGAGEMENT PATTERN
-- ============================================================================
-- INSIGHT: How frequently do agents log in, and does login frequency
--   correlate with sales? This quantifies the value of platform engagement.
-- ACTION: If high-login agents sell 3x more, then increasing login
--   frequency is a lever for revenue growth. Use this data to justify
--   investment in daily engagement features (gamification, daily tips, etc.)
-- ============================================================================

WITH login_frequency AS (
    SELECT
        adl.agent_id,
        COUNT(DISTINCT adl.login_date) AS login_days_90d,
        MIN(adl.login_date) AS first_login_90d,
        MAX(adl.login_date) AS last_login_90d
    FROM agent_daily_logins adl
    WHERE adl.login_date >= CURRENT_DATE - INTERVAL '90 days'
    GROUP BY adl.agent_id
),
agent_sales AS (
    SELECT
        agent::TEXT AS agent_text,
        COUNT(*) AS policies_90d,
        ROUND(SUM(premium_amount), 0) AS premium_90d
    FROM sold_policies_data
    WHERE sold_date >= CURRENT_DATE - INTERVAL '90 days'
      AND agent IS NOT NULL AND agent != ''
    GROUP BY agent::TEXT
)
SELECT
    CASE
        WHEN lf.login_days_90d >= 60 THEN 'A: Super Active (60+ days/90)'
        WHEN lf.login_days_90d >= 30 THEN 'B: Active (30-59 days/90)'
        WHEN lf.login_days_90d >= 10 THEN 'C: Moderate (10-29 days/90)'
        WHEN lf.login_days_90d >= 3 THEN 'D: Infrequent (3-9 days/90)'
        ELSE 'E: Barely Active (1-2 days/90)'
    END AS engagement_tier,
    COUNT(*) AS agents_in_tier,
    ROUND(AVG(lf.login_days_90d), 0) AS avg_login_days,
    -- Sales performance
    ROUND(AVG(COALESCE(asl.policies_90d, 0)), 1) AS avg_policies_per_agent,
    ROUND(AVG(COALESCE(asl.premium_90d, 0)), 0) AS avg_premium_per_agent,
    SUM(COALESCE(asl.policies_90d, 0)) AS total_policies_in_tier,
    SUM(COALESCE(asl.premium_90d, 0)) AS total_premium_in_tier,
    -- Conversion likelihood
    ROUND(COUNT(CASE WHEN COALESCE(asl.policies_90d, 0) > 0 THEN 1 END)::NUMERIC
          / NULLIF(COUNT(*), 0) * 100, 1) AS pct_with_sales,

    'More engaged agents sell more. Invest in daily engagement features.' AS strategic_insight

FROM login_frequency lf
LEFT JOIN agent_sales asl ON asl.agent_text = lf.agent_id::TEXT
GROUP BY
    CASE
        WHEN lf.login_days_90d >= 60 THEN 'A: Super Active (60+ days/90)'
        WHEN lf.login_days_90d >= 30 THEN 'B: Active (30-59 days/90)'
        WHEN lf.login_days_90d >= 10 THEN 'C: Moderate (10-29 days/90)'
        WHEN lf.login_days_90d >= 3 THEN 'D: Infrequent (3-9 days/90)'
        ELSE 'E: Barely Active (1-2 days/90)'
    END
ORDER BY engagement_tier;


-- ============================================================================
-- 10.7 PLATFORM UTILIZATION LEADERBOARD (Top 20 Agents This Month)
-- ============================================================================
-- INSIGHT: Who are the platform's best performers RIGHT NOW? Real-time
--   leaderboard creates healthy competition and identifies agents to learn from.
-- ACTION: Share this leaderboard weekly with all agents. Offer monthly
--   prizes for top 3. Interview top performers to understand their process.
-- ============================================================================

SELECT
    RANK() OVER (ORDER BY COUNT(*) DESC) AS rank,
    sp.agent,
    u.fullname AS agent_name,
    sp.source AS broker,
    COUNT(*) AS policies_this_month,
    ROUND(SUM(sp.premium_amount), 0) AS premium_this_month,
    ROUND(AVG(sp.premium_amount), 0) AS avg_ticket,
    COUNT(DISTINCT sp.product_type) AS products_sold,
    COUNT(DISTINCT sp.insurer) AS insurers_used,
    COUNT(CASE WHEN sp.policy_business_type = 'Renewal' THEN 1 END) AS renewals,
    COUNT(CASE WHEN sp.is_breakin_journey::TEXT = 'true' THEN 1 END) AS breakin_journeys,
    -- Days active this month
    COUNT(DISTINCT sp.sold_date) AS selling_days,
    ROUND(COUNT(*)::NUMERIC / NULLIF(COUNT(DISTINCT sp.sold_date), 0), 1) AS policies_per_selling_day

FROM sold_policies_data sp
LEFT JOIN users u ON u.id::TEXT = sp.agent::TEXT
WHERE sp.sold_date >= DATE_TRUNC('month', CURRENT_DATE)
  AND sp.agent IS NOT NULL AND sp.agent != ''
GROUP BY sp.agent, u.fullname, sp.source
ORDER BY COUNT(*) DESC
LIMIT 20;


-- ############################################################################
-- SECTION 11 (BONUS): ADVANCED CROSS-CUTTING ANALYTICS
-- ############################################################################
-- These queries combine multiple dimensions to uncover insights that
-- single-dimension queries cannot reveal.

-- ============================================================================
-- 11.1 AGENT 360-DEGREE SCORECARD
-- ============================================================================
-- INSIGHT: Comprehensive view of each agent across all dimensions:
--   volume, conversion, product mix, renewal, engagement, and growth.
--   This is the single most important query for agent management.
-- ACTION: Use this to segment agents for targeted programs. Each agent
--   gets a score on 5 dimensions. Agents weak in specific areas get
--   targeted interventions for that specific weakness.
-- ============================================================================

WITH agent_sales AS (
    SELECT
        agent,
        COUNT(*) AS total_policies,
        ROUND(SUM(premium_amount), 0) AS total_premium,
        COUNT(DISTINCT product_type) AS product_diversity,
        COUNT(CASE WHEN policy_business_type = 'Renewal' THEN 1 END) AS renewals,
        COUNT(CASE WHEN sold_date >= DATE_TRUNC('month', CURRENT_DATE) THEN 1 END) AS current_month_policies,
        COUNT(CASE WHEN sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month'
                        AND sold_date < DATE_TRUNC('month', CURRENT_DATE) THEN 1 END) AS prev_month_policies,
        MAX(sold_date) AS last_sale_date
    FROM sold_policies_data
    WHERE sold_date >= CURRENT_DATE - INTERVAL '6 months'
      AND agent IS NOT NULL AND agent != ''
    GROUP BY agent
),
agent_quotes AS (
    SELECT
        agent_id,
        SUM(quote_count) AS total_quotes_6m,
        SUM(CASE WHEN quote_date >= DATE_TRUNC('month', CURRENT_DATE) THEN quote_count ELSE 0 END) AS current_month_quotes,
        COUNT(DISTINCT quote_date) AS active_days
    FROM daily_quote_counts
    WHERE quote_date >= CURRENT_DATE - INTERVAL '6 months'
    GROUP BY agent_id
),
agent_logins AS (
    SELECT
        agent_id,
        COUNT(DISTINCT login_date) AS login_days_6m,
        MAX(login_date) AS last_login
    FROM agent_daily_logins
    WHERE login_date >= CURRENT_DATE - INTERVAL '6 months'
    GROUP BY agent_id
)
SELECT
    asu.agent,
    u.fullname AS agent_name,
    u.saleschanneluserid AS broker_id,
    u.createdat AS join_date,
    EXTRACT(DAY FROM CURRENT_DATE - u.createdat)::INTEGER AS tenure_days,

    -- Volume metrics
    asu.total_policies AS policies_6m,
    asu.total_premium AS premium_6m,
    asu.current_month_policies,
    asu.prev_month_policies,
    CASE WHEN asu.prev_month_policies > 0
         THEN ROUND((asu.current_month_policies - asu.prev_month_policies)::NUMERIC
                     / asu.prev_month_policies * 100, 1)
         ELSE NULL END AS mom_growth_pct,

    -- Conversion
    COALESCE(aq.total_quotes_6m, 0) AS quotes_6m,
    CASE WHEN COALESCE(aq.total_quotes_6m, 0) > 0
         THEN ROUND(asu.total_policies::NUMERIC / aq.total_quotes_6m * 100, 2)
         ELSE NULL END AS conversion_rate,

    -- Engagement
    COALESCE(al.login_days_6m, 0) AS login_days_6m,
    al.last_login,
    (CURRENT_DATE - COALESCE(al.last_login, u.createdat::DATE)) AS days_since_login,

    -- Product diversity
    asu.product_diversity,
    asu.renewals AS renewal_count,
    ROUND(asu.renewals::NUMERIC / NULLIF(asu.total_policies, 0) * 100, 1) AS renewal_pct,

    -- SCORING (each dimension 0-5)
    -- Volume score
    CASE
        WHEN asu.total_policies >= 100 THEN 5
        WHEN asu.total_policies >= 50 THEN 4
        WHEN asu.total_policies >= 20 THEN 3
        WHEN asu.total_policies >= 5 THEN 2
        WHEN asu.total_policies >= 1 THEN 1
        ELSE 0
    END AS volume_score,

    -- Conversion score
    CASE
        WHEN COALESCE(aq.total_quotes_6m, 0) = 0 THEN 0
        WHEN asu.total_policies::NUMERIC / NULLIF(aq.total_quotes_6m, 0) >= 0.10 THEN 5
        WHEN asu.total_policies::NUMERIC / NULLIF(aq.total_quotes_6m, 0) >= 0.05 THEN 4
        WHEN asu.total_policies::NUMERIC / NULLIF(aq.total_quotes_6m, 0) >= 0.03 THEN 3
        WHEN asu.total_policies::NUMERIC / NULLIF(aq.total_quotes_6m, 0) >= 0.01 THEN 2
        ELSE 1
    END AS conversion_score,

    -- Engagement score
    CASE
        WHEN COALESCE(al.login_days_6m, 0) >= 120 THEN 5
        WHEN COALESCE(al.login_days_6m, 0) >= 60 THEN 4
        WHEN COALESCE(al.login_days_6m, 0) >= 30 THEN 3
        WHEN COALESCE(al.login_days_6m, 0) >= 10 THEN 2
        WHEN COALESCE(al.login_days_6m, 0) >= 1 THEN 1
        ELSE 0
    END AS engagement_score,

    -- Growth score
    CASE
        WHEN asu.prev_month_policies = 0 AND asu.current_month_policies > 0 THEN 4
        WHEN asu.prev_month_policies > 0 AND asu.current_month_policies > asu.prev_month_policies * 1.2 THEN 5
        WHEN asu.prev_month_policies > 0 AND asu.current_month_policies >= asu.prev_month_policies THEN 3
        WHEN asu.prev_month_policies > 0 AND asu.current_month_policies >= asu.prev_month_policies * 0.5 THEN 2
        WHEN asu.prev_month_policies > 0 THEN 1
        ELSE 0
    END AS growth_score,

    -- Product diversity score
    CASE
        WHEN asu.product_diversity >= 4 THEN 5
        WHEN asu.product_diversity = 3 THEN 4
        WHEN asu.product_diversity = 2 THEN 3
        WHEN asu.product_diversity = 1 THEN 2
        ELSE 0
    END AS diversity_score,

    -- OVERALL COMPOSITE SCORE (out of 25)
    (CASE WHEN asu.total_policies >= 100 THEN 5 WHEN asu.total_policies >= 50 THEN 4
          WHEN asu.total_policies >= 20 THEN 3 WHEN asu.total_policies >= 5 THEN 2
          WHEN asu.total_policies >= 1 THEN 1 ELSE 0 END) +
    (CASE WHEN COALESCE(aq.total_quotes_6m, 0) = 0 THEN 0
          WHEN asu.total_policies::NUMERIC / NULLIF(aq.total_quotes_6m, 0) >= 0.10 THEN 5
          WHEN asu.total_policies::NUMERIC / NULLIF(aq.total_quotes_6m, 0) >= 0.05 THEN 4
          WHEN asu.total_policies::NUMERIC / NULLIF(aq.total_quotes_6m, 0) >= 0.03 THEN 3
          WHEN asu.total_policies::NUMERIC / NULLIF(aq.total_quotes_6m, 0) >= 0.01 THEN 2
          ELSE 1 END) +
    (CASE WHEN COALESCE(al.login_days_6m, 0) >= 120 THEN 5
          WHEN COALESCE(al.login_days_6m, 0) >= 60 THEN 4
          WHEN COALESCE(al.login_days_6m, 0) >= 30 THEN 3
          WHEN COALESCE(al.login_days_6m, 0) >= 10 THEN 2
          WHEN COALESCE(al.login_days_6m, 0) >= 1 THEN 1
          ELSE 0 END) +
    (CASE WHEN asu.prev_month_policies = 0 AND asu.current_month_policies > 0 THEN 4
          WHEN asu.prev_month_policies > 0 AND asu.current_month_policies > asu.prev_month_policies * 1.2 THEN 5
          WHEN asu.prev_month_policies > 0 AND asu.current_month_policies >= asu.prev_month_policies THEN 3
          WHEN asu.prev_month_policies > 0 AND asu.current_month_policies >= asu.prev_month_policies * 0.5 THEN 2
          WHEN asu.prev_month_policies > 0 THEN 1
          ELSE 0 END) +
    (CASE WHEN asu.product_diversity >= 4 THEN 5 WHEN asu.product_diversity = 3 THEN 4
          WHEN asu.product_diversity = 2 THEN 3 WHEN asu.product_diversity = 1 THEN 2
          ELSE 0 END)
    AS composite_score,

    -- Overall classification
    CASE
        WHEN (CASE WHEN asu.total_policies >= 100 THEN 5 WHEN asu.total_policies >= 50 THEN 4
                   WHEN asu.total_policies >= 20 THEN 3 WHEN asu.total_policies >= 5 THEN 2
                   WHEN asu.total_policies >= 1 THEN 1 ELSE 0 END +
              CASE WHEN COALESCE(aq.total_quotes_6m, 0) = 0 THEN 0
                   WHEN asu.total_policies::NUMERIC / NULLIF(aq.total_quotes_6m, 0) >= 0.10 THEN 5
                   WHEN asu.total_policies::NUMERIC / NULLIF(aq.total_quotes_6m, 0) >= 0.05 THEN 4
                   WHEN asu.total_policies::NUMERIC / NULLIF(aq.total_quotes_6m, 0) >= 0.03 THEN 3
                   WHEN asu.total_policies::NUMERIC / NULLIF(aq.total_quotes_6m, 0) >= 0.01 THEN 2
                   ELSE 1 END +
              CASE WHEN COALESCE(al.login_days_6m, 0) >= 120 THEN 5
                   WHEN COALESCE(al.login_days_6m, 0) >= 60 THEN 4
                   WHEN COALESCE(al.login_days_6m, 0) >= 30 THEN 3
                   WHEN COALESCE(al.login_days_6m, 0) >= 10 THEN 2
                   WHEN COALESCE(al.login_days_6m, 0) >= 1 THEN 1
                   ELSE 0 END) >= 12
             THEN 'STAR AGENT: Top tier. Protect and reward.'
        WHEN (CASE WHEN asu.total_policies >= 100 THEN 5 WHEN asu.total_policies >= 50 THEN 4
                   WHEN asu.total_policies >= 20 THEN 3 WHEN asu.total_policies >= 5 THEN 2
                   WHEN asu.total_policies >= 1 THEN 1 ELSE 0 END +
              CASE WHEN COALESCE(aq.total_quotes_6m, 0) = 0 THEN 0
                   WHEN asu.total_policies::NUMERIC / NULLIF(aq.total_quotes_6m, 0) >= 0.10 THEN 5
                   WHEN asu.total_policies::NUMERIC / NULLIF(aq.total_quotes_6m, 0) >= 0.05 THEN 4
                   WHEN asu.total_policies::NUMERIC / NULLIF(aq.total_quotes_6m, 0) >= 0.03 THEN 3
                   WHEN asu.total_policies::NUMERIC / NULLIF(aq.total_quotes_6m, 0) >= 0.01 THEN 2
                   ELSE 1 END +
              CASE WHEN COALESCE(al.login_days_6m, 0) >= 120 THEN 5
                   WHEN COALESCE(al.login_days_6m, 0) >= 60 THEN 4
                   WHEN COALESCE(al.login_days_6m, 0) >= 30 THEN 3
                   WHEN COALESCE(al.login_days_6m, 0) >= 10 THEN 2
                   WHEN COALESCE(al.login_days_6m, 0) >= 1 THEN 1
                   ELSE 0 END) >= 8
             THEN 'RISING: Good potential. Invest in coaching.'
        WHEN asu.current_month_policies > 0
             THEN 'ACTIVE: Currently selling but needs development.'
        WHEN COALESCE(aq.current_month_quotes, 0) > 0
             THEN 'ENGAGED: Quoting but not selling. Conversion help needed.'
        ELSE 'AT RISK: Low activity across all dimensions.'
    END AS agent_classification

FROM agent_sales asu
LEFT JOIN agent_quotes aq ON aq.agent_id::TEXT = asu.agent::TEXT
LEFT JOIN agent_logins al ON al.agent_id::TEXT = asu.agent::TEXT
LEFT JOIN users u ON u.id::TEXT = asu.agent::TEXT
ORDER BY asu.total_premium DESC
LIMIT 1000;


-- ============================================================================
-- 11.2 PLATFORM COHORT RETENTION (Monthly Cohort Survival)
-- ============================================================================
-- INSIGHT: For agents who joined in each month, what percentage are still
--   active N months later? This is the definitive measure of platform
--   stickiness and reveals whether recent cohorts retain better or worse.
-- ACTION: If retention is declining across cohorts, something fundamental
--   is broken in the agent experience. Compare high-retention cohorts to
--   low-retention cohorts to find what changed.
-- ============================================================================

WITH agent_cohort AS (
    SELECT
        u.id AS agent_id,
        DATE_TRUNC('month', u.createdat) AS cohort_month
    FROM users u
    WHERE u.deletedat IS NULL
      AND u.createdat >= '2023-01-01'
),
monthly_activity AS (
    SELECT
        agent_id,
        DATE_TRUNC('month', quote_date) AS activity_month
    FROM daily_quote_counts
    WHERE quote_count > 0
    GROUP BY agent_id, DATE_TRUNC('month', quote_date)
)
SELECT
    ac.cohort_month,
    COUNT(DISTINCT ac.agent_id) AS cohort_size,
    -- Retention at month 1, 3, 6, 9, 12
    ROUND(COUNT(DISTINCT CASE WHEN ma.activity_month = ac.cohort_month THEN ac.agent_id END)::NUMERIC
          / NULLIF(COUNT(DISTINCT ac.agent_id), 0) * 100, 1) AS month_0_active_pct,
    ROUND(COUNT(DISTINCT CASE WHEN ma.activity_month = ac.cohort_month + INTERVAL '1 month' THEN ac.agent_id END)::NUMERIC
          / NULLIF(COUNT(DISTINCT ac.agent_id), 0) * 100, 1) AS month_1_active_pct,
    ROUND(COUNT(DISTINCT CASE WHEN ma.activity_month = ac.cohort_month + INTERVAL '3 months' THEN ac.agent_id END)::NUMERIC
          / NULLIF(COUNT(DISTINCT ac.agent_id), 0) * 100, 1) AS month_3_active_pct,
    ROUND(COUNT(DISTINCT CASE WHEN ma.activity_month = ac.cohort_month + INTERVAL '6 months' THEN ac.agent_id END)::NUMERIC
          / NULLIF(COUNT(DISTINCT ac.agent_id), 0) * 100, 1) AS month_6_active_pct,
    ROUND(COUNT(DISTINCT CASE WHEN ma.activity_month = ac.cohort_month + INTERVAL '9 months' THEN ac.agent_id END)::NUMERIC
          / NULLIF(COUNT(DISTINCT ac.agent_id), 0) * 100, 1) AS month_9_active_pct,
    ROUND(COUNT(DISTINCT CASE WHEN ma.activity_month = ac.cohort_month + INTERVAL '12 months' THEN ac.agent_id END)::NUMERIC
          / NULLIF(COUNT(DISTINCT ac.agent_id), 0) * 100, 1) AS month_12_active_pct,

    CASE
        WHEN COUNT(DISTINCT CASE WHEN ma.activity_month = ac.cohort_month + INTERVAL '3 months' THEN ac.agent_id END)::NUMERIC
             / NULLIF(COUNT(DISTINCT ac.agent_id), 0) < 0.10
             THEN 'CRITICAL CHURN: <10% retained at month 3. Onboarding is failing.'
        WHEN COUNT(DISTINCT CASE WHEN ma.activity_month = ac.cohort_month + INTERVAL '3 months' THEN ac.agent_id END)::NUMERIC
             / NULLIF(COUNT(DISTINCT ac.agent_id), 0) < 0.25
             THEN 'HIGH CHURN: <25% retained at month 3. Improve first 90 days.'
        WHEN COUNT(DISTINCT CASE WHEN ma.activity_month = ac.cohort_month + INTERVAL '3 months' THEN ac.agent_id END)::NUMERIC
             / NULLIF(COUNT(DISTINCT ac.agent_id), 0) < 0.50
             THEN 'MODERATE: 25-50% retained. Good but room to improve.'
        ELSE 'STRONG: >50% retained at month 3. Healthy onboarding.'
    END AS cohort_health

FROM agent_cohort ac
LEFT JOIN monthly_activity ma ON ma.agent_id = ac.agent_id
GROUP BY ac.cohort_month
HAVING COUNT(DISTINCT ac.agent_id) >= 10  -- meaningful cohort size
ORDER BY ac.cohort_month;


-- ============================================================================
-- 11.3 REVENUE AT RISK DASHBOARD
-- ============================================================================
-- INSIGHT: Aggregates all revenue risk signals into a single view:
--   broker concentration, agent churn risk, renewal leakage, insurer
--   dependency, and geographic concentration.
-- ACTION: Present this in the weekly leadership meeting. Each risk
--   category has a specific mitigation action. Total revenue at risk
--   should be tracked as a KPI and reduced quarter over quarter.
-- ============================================================================

WITH broker_concentration_risk AS (
    SELECT
        ROUND(MAX(broker_share) * SUM(premium_amount), 0) AS revenue_at_risk_broker
    FROM (
        SELECT
            source,
            SUM(premium_amount) / SUM(SUM(premium_amount)) OVER () AS broker_share,
            SUM(premium_amount) AS premium_amount
        FROM sold_policies_data
        WHERE sold_date >= CURRENT_DATE - INTERVAL '6 months'
        GROUP BY source
    ) broker_shares
),
top_agent_risk AS (
    -- Revenue from top 10 agents (at risk if they leave)
    SELECT SUM(premium_amount) AS revenue_at_risk_top_agents
    FROM (
        SELECT agent, SUM(premium_amount) AS premium_amount
        FROM sold_policies_data
        WHERE sold_date >= CURRENT_DATE - INTERVAL '6 months'
          AND agent IS NOT NULL AND agent != ''
        GROUP BY agent
        ORDER BY SUM(premium_amount) DESC
        LIMIT 10
    ) top_agents
),
renewal_leakage AS (
    -- Premium from policies that expired without renewal in last 6 months
    SELECT
        ROUND(SUM(sp.premium_amount), 0) AS premium_leaked_renewals
    FROM sold_policies_data sp
    WHERE sp.policy_expiry_date BETWEEN CURRENT_DATE - INTERVAL '6 months' AND CURRENT_DATE
      AND sp.vehicle_registration IS NOT NULL
      AND sp.vehicle_registration NOT IN (
          SELECT vehicle_registration
          FROM sold_policies_data
          WHERE policy_business_type IN ('Renewal', 'Roll Over')
            AND sold_date >= CURRENT_DATE - INTERVAL '6 months'
            AND vehicle_registration IS NOT NULL
      )
),
declining_agents_premium AS (
    -- Premium from agents whose activity is declining
    SELECT ROUND(SUM(premium_6m), 0) AS premium_from_declining_agents
    FROM (
        SELECT
            agent,
            SUM(premium_amount) AS premium_6m,
            SUM(CASE WHEN sold_date >= DATE_TRUNC('month', CURRENT_DATE) THEN premium_amount ELSE 0 END) AS this_month,
            SUM(CASE WHEN sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month'
                          AND sold_date < DATE_TRUNC('month', CURRENT_DATE) THEN premium_amount ELSE 0 END) AS last_month
        FROM sold_policies_data
        WHERE sold_date >= CURRENT_DATE - INTERVAL '6 months'
          AND agent IS NOT NULL AND agent != ''
        GROUP BY agent
        HAVING SUM(CASE WHEN sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month'
                             AND sold_date < DATE_TRUNC('month', CURRENT_DATE) THEN 1 ELSE 0 END) >= 5
           AND SUM(CASE WHEN sold_date >= DATE_TRUNC('month', CURRENT_DATE) THEN 1 ELSE 0 END) <
               SUM(CASE WHEN sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month'
                             AND sold_date < DATE_TRUNC('month', CURRENT_DATE) THEN 1 ELSE 0 END) * 0.5
    ) declining
),
total_6m_premium AS (
    SELECT ROUND(SUM(premium_amount), 0) AS total
    FROM sold_policies_data
    WHERE sold_date >= CURRENT_DATE - INTERVAL '6 months'
)
SELECT
    t6.total AS total_premium_6m,
    bcr.revenue_at_risk_broker AS risk_broker_concentration,
    tar.revenue_at_risk_top_agents AS risk_top_agent_dependency,
    rl.premium_leaked_renewals AS risk_renewal_leakage,
    dap.premium_from_declining_agents AS risk_declining_agents,

    -- Total unique risk (not additive - overlapping)
    GREATEST(bcr.revenue_at_risk_broker,
             tar.revenue_at_risk_top_agents,
             COALESCE(rl.premium_leaked_renewals, 0),
             COALESCE(dap.premium_from_declining_agents, 0)) AS largest_single_risk,

    -- Risk as percentage of total
    ROUND(bcr.revenue_at_risk_broker::NUMERIC / NULLIF(t6.total, 0) * 100, 1) AS broker_risk_pct,
    ROUND(tar.revenue_at_risk_top_agents::NUMERIC / NULLIF(t6.total, 0) * 100, 1) AS agent_risk_pct,
    ROUND(COALESCE(rl.premium_leaked_renewals, 0)::NUMERIC / NULLIF(t6.total, 0) * 100, 1) AS renewal_leak_pct,

    -- Actions
    'BROKER: Diversify beyond top broker. TARGET: No broker > 30% share.' AS broker_action,
    'AGENTS: Develop mid-tier agent pipeline. TARGET: Top 10 < 30% of revenue.' AS agent_action,
    'RENEWAL: Launch automated pre-expiry outreach. TARGET: >30% capture rate.' AS renewal_action,
    'DECLINING: Intervene with declining agents within 48 hours.' AS declining_action

FROM total_6m_premium t6
CROSS JOIN broker_concentration_risk bcr
CROSS JOIN top_agent_risk tar
CROSS JOIN renewal_leakage rl
CROSS JOIN declining_agents_premium dap;


-- ============================================================================
-- 11.4 WEEKLY EXECUTIVE PULSE (Single-Row Summary for Slack/Email)
-- ============================================================================
-- INSIGHT: One-line weekly summary suitable for automated Slack messages
--   or email digests. Contains the most critical numbers only.
-- ACTION: Send this every Monday morning to leadership. Any metric
--   flagged RED should have a corresponding investigation assigned to
--   a specific person by end of day Monday.
-- ============================================================================

WITH this_week AS (
    SELECT
        COUNT(*) AS policies,
        ROUND(SUM(premium_amount), 0) AS premium,
        COUNT(DISTINCT agent) AS agents,
        COUNT(DISTINCT insurer) AS insurers,
        ROUND(AVG(premium_amount), 0) AS avg_ticket
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('week', CURRENT_DATE)
),
last_week AS (
    SELECT
        COUNT(*) AS policies,
        ROUND(SUM(premium_amount), 0) AS premium,
        COUNT(DISTINCT agent) AS agents
    FROM sold_policies_data
    WHERE sold_date >= DATE_TRUNC('week', CURRENT_DATE) - INTERVAL '7 days'
      AND sold_date < DATE_TRUNC('week', CURRENT_DATE)
),
this_week_quotes AS (
    SELECT SUM(quote_count) AS quotes
    FROM daily_quote_counts
    WHERE quote_date >= DATE_TRUNC('week', CURRENT_DATE)
),
renewals_expiring AS (
    SELECT COUNT(*) AS cnt
    FROM sold_policies_data
    WHERE policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '7 days'
),
new_agents AS (
    SELECT COUNT(*) AS cnt
    FROM users
    WHERE createdat >= DATE_TRUNC('week', CURRENT_DATE) AND deletedat IS NULL
)
SELECT
    -- This week
    tw.policies AS week_policies,
    tw.premium AS week_premium,
    tw.agents AS week_active_agents,
    tw.avg_ticket AS week_avg_ticket,
    COALESCE(twq.quotes, 0) AS week_quotes,

    -- WoW comparison
    lw.policies AS last_week_policies,
    lw.premium AS last_week_premium,
    CASE WHEN lw.policies > 0
         THEN ROUND((tw.policies - lw.policies)::NUMERIC / lw.policies * 100, 0)
         ELSE NULL END AS policies_wow_pct,
    CASE WHEN lw.premium > 0
         THEN ROUND((tw.premium - lw.premium)::NUMERIC / lw.premium * 100, 0)
         ELSE NULL END AS premium_wow_pct,

    -- Conversion
    CASE WHEN COALESCE(twq.quotes, 0) > 0
         THEN ROUND(tw.policies::NUMERIC / twq.quotes * 100, 2)
         ELSE 0 END AS conversion_rate,

    -- Upcoming
    re.cnt AS renewals_expiring_this_week,
    na.cnt AS new_agents_this_week,

    -- Status flags
    CASE WHEN lw.policies > 0 AND tw.policies < lw.policies * 0.8 THEN 'RED'
         WHEN lw.policies > 0 AND tw.policies < lw.policies THEN 'YELLOW'
         ELSE 'GREEN' END AS volume_flag,
    CASE WHEN lw.premium > 0 AND tw.premium < lw.premium * 0.8 THEN 'RED'
         WHEN lw.premium > 0 AND tw.premium < lw.premium THEN 'YELLOW'
         ELSE 'GREEN' END AS premium_flag

FROM this_week tw
CROSS JOIN last_week lw
CROSS JOIN this_week_quotes twq
CROSS JOIN renewals_expiring re
CROSS JOIN new_agents na;


-- ============================================================================
-- 11.5 PRODUCT-CHANNEL-STATE CUBE (Multi-Dimensional Drill-Down)
-- ============================================================================
-- INSIGHT: Three-dimensional analysis combining product, channel type,
--   and state. Reveals hidden patterns like "2W sells well through
--   franchises in Karnataka but poorly through ICE in Maharashtra."
-- ACTION: Use this to build location-specific and channel-specific
--   product strategies. Different states may need different product
--   focus through different channels.
-- ============================================================================

SELECT
    product_type,
    CASE
        WHEN source = 'ICE' THEN 'ICE'
        WHEN source LIKE 'F%' THEN 'FRANCHISE'
        ELSE 'OTHER'
    END AS channel_type,
    COALESCE(policy_holder_state, 'Unknown') AS state,
    COUNT(*) AS policies,
    ROUND(SUM(premium_amount), 0) AS premium,
    ROUND(AVG(premium_amount), 0) AS avg_ticket,
    COUNT(DISTINCT agent) AS unique_agents,
    COUNT(DISTINCT insurer) AS unique_insurers,
    ROUND(COUNT(CASE WHEN is_breakin_journey::TEXT = 'true' THEN 1 END)::NUMERIC
          / NULLIF(COUNT(*), 0) * 100, 1) AS breakin_pct,
    ROUND(COUNT(CASE WHEN policy_business_type = 'Renewal' THEN 1 END)::NUMERIC
          / NULLIF(COUNT(*), 0) * 100, 1) AS renewal_pct,
    -- Rank within product-channel combination
    RANK() OVER (PARTITION BY product_type,
                 CASE WHEN source = 'ICE' THEN 'ICE' WHEN source LIKE 'F%' THEN 'FRANCHISE' ELSE 'OTHER' END
                 ORDER BY COUNT(*) DESC) AS state_rank_in_product_channel
FROM sold_policies_data
WHERE sold_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
  AND policy_holder_state IS NOT NULL AND policy_holder_state != ''
GROUP BY
    product_type,
    CASE WHEN source = 'ICE' THEN 'ICE' WHEN source LIKE 'F%' THEN 'FRANCHISE' ELSE 'OTHER' END,
    COALESCE(policy_holder_state, 'Unknown')
HAVING COUNT(*) >= 5  -- filter noise
ORDER BY product_type, channel_type, COUNT(*) DESC;


-- ############################################################################
-- END OF FILE 3C: DASHBOARD SUPPLEMENT - RENEWAL, OPS & ADVANCED
-- ############################################################################
-- IMPLEMENTATION NOTES:
--
-- 1. SECTION 8 SUPPLEMENTS (8.4-8.8): These are critical for building a
--    renewal program. 8.4 (Capture Rate) should be the #1 KPI for the
--    retention team. 8.5 (Forecast) enables proactive resource planning.
--    8.8 (Timing) tells you when to start outreach.
--
-- 2. SECTION 9 SUPPLEMENTS (9.8-9.10): These are operational alerts.
--    9.8 (Insurer Anomaly) should run every 4 hours.
--    9.10 (Daily Velocity) should run at noon and 3pm.
--
-- 3. SECTION 11 (Advanced Analytics):
--    11.1 (Agent 360) is the master agent view - run weekly.
--    11.2 (Cohort Retention) is a monthly strategic metric.
--    11.3 (Revenue at Risk) is a quarterly board-level metric.
--    11.4 (Weekly Pulse) is automated every Monday at 8 AM.
--    11.5 (Product-Channel-State Cube) is for ad-hoc strategic analysis.
--
-- 4. PERFORMANCE NOTES:
--    - Queries 8.4, 8.6, 8.7, 8.8 use vehicle_registration JOINs which
--      can be slow on 294K rows. Ensure index on vehicle_registration:
--      CREATE INDEX IF NOT EXISTS idx_spd_vehicle_reg ON sold_policies_data(vehicle_registration);
--    - Query 11.1 (Agent 360) joins 3 tables and should be materialized
--      as a daily view or cached in a summary table.
--    - Query 11.5 (Cube) can return many rows. In dashboards, filter by
--      product or state before display.
--
-- 5. COMPLETE FILE INVENTORY:
--    03_actionable_dashboard_queries.sql  - Main dashboard (Sections 1-10)
--    03b_dashboard_supplement_deep_dives.sql - Sections 3-7 deep dives
--    03c_dashboard_supplement_renewal_ops_advanced.sql - Sections 8-11
--
-- TOTAL QUERY COUNT ACROSS ALL THREE FILES:
--    Section 1  (Executive):    4 queries (03)
--    Section 2  (Agent):        6 queries (03)
--    Section 3  (Funnel):       4 + 4 = 8 queries (03 + 03b)
--    Section 4  (Product):      4 + 3 = 7 queries (03 + 03b)
--    Section 5  (Broker):       2 + 3 = 5 queries (03 + 03b)
--    Section 6  (Geographic):   2 + 3 = 5 queries (03 + 03b)
--    Section 7  (Insurer):      2 + 3 = 5 queries (03 + 03b)
--    Section 8  (Renewal):      3 + 5 = 8 queries (03 + 03c)
--    Section 9  (Alerts):       7 + 3 = 10 queries (03 + 03c)
--    Section 10 (Operations):   5 + 2 = 7 queries (03 + 03c)
--    Section 11 (Advanced):     5 queries (03c)
--    ----------------------------------------
--    GRAND TOTAL:               70 queries
-- ############################################################################
