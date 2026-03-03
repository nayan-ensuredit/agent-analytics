-- ============================================================================
-- FILE 1: NEW ANALYTICS TABLES SCHEMA
-- ============================================================================
-- InsurTech Distribution Platform - Analytics Infrastructure
-- PostgreSQL 14+
--
-- PURPOSE: These tables fill critical data gaps that prevent the platform from
-- having actionable analytics. The existing tables provide aggregate counts
-- but lack the granularity needed for funnel analysis, engagement scoring,
-- and proactive agent management.
--
-- DEPLOYMENT ORDER: Tables are numbered to indicate dependency order.
-- Run this file top-to-bottom in a single transaction.
--
-- AUTHOR: Analytics Engineering Team
-- DATE: 2026-02-13
-- ============================================================================

BEGIN;

-- ============================================================================
-- TABLE 1: agent_onboarding_milestones
-- ============================================================================
-- PURPOSE: Track every agent through a defined onboarding funnel:
--   signup -> profile_complete -> certification_done -> first_quote ->
--   first_proposal -> first_sale
--
-- WHY THIS MATTERS: Currently 0% of 927 agents who joined in 2024 have made
-- a single sale. We cannot diagnose WHERE they drop off without milestone
-- tracking. This table enables cohort analysis and identifies the exact
-- bottleneck in the onboarding funnel.
--
-- HOW TO POPULATE: Backfill from existing data where possible (signup from
-- users.createdat, first_quote from daily_quote_counts, first_sale from
-- sold_policies_data). Going forward, application events write here in
-- real-time.
-- ============================================================================

CREATE TABLE IF NOT EXISTS agent_onboarding_milestones (
    id                      BIGSERIAL PRIMARY KEY,
    agent_id                BIGINT NOT NULL,

    -- Milestone timestamps: NULL means milestone not yet reached
    signup_at               TIMESTAMPTZ NOT NULL,
    profile_completed_at    TIMESTAMPTZ,
    certification_started_at TIMESTAMPTZ,
    certification_completed_at TIMESTAMPTZ,
    first_login_at          TIMESTAMPTZ,
    first_quote_at          TIMESTAMPTZ,
    first_proposal_at       TIMESTAMPTZ,
    first_sale_at           TIMESTAMPTZ,

    -- Derived fields (computed by trigger or application logic)
    -- Days from signup to first sale - the key metric to optimize
    days_to_first_sale      INTEGER GENERATED ALWAYS AS (
        CASE WHEN first_sale_at IS NOT NULL AND signup_at IS NOT NULL
             THEN EXTRACT(DAY FROM (first_sale_at - signup_at))::INTEGER
             ELSE NULL
        END
    ) STORED,

    -- Days from signup to first quote
    days_to_first_quote     INTEGER GENERATED ALWAYS AS (
        CASE WHEN first_quote_at IS NOT NULL AND signup_at IS NOT NULL
             THEN EXTRACT(DAY FROM (first_quote_at - signup_at))::INTEGER
             ELSE NULL
        END
    ) STORED,

    -- Current funnel stage for quick filtering
    current_stage           VARCHAR(30) NOT NULL DEFAULT 'signed_up'
        CHECK (current_stage IN (
            'signed_up', 'profile_complete', 'certification_started',
            'certified', 'first_login', 'first_quote',
            'first_proposal', 'first_sale', 'active_seller'
        )),

    -- Which broker/channel onboarded this agent
    onboarding_channel_id   BIGINT,

    -- Metadata
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_onboarding_agent FOREIGN KEY (agent_id) REFERENCES users(id),
    CONSTRAINT uq_onboarding_agent UNIQUE (agent_id)
);

-- Fast lookups by current funnel stage (for dashboards showing funnel counts)
CREATE INDEX idx_onboarding_current_stage ON agent_onboarding_milestones(current_stage);
-- Cohort analysis: group agents by signup month
CREATE INDEX idx_onboarding_signup_month ON agent_onboarding_milestones(DATE_TRUNC('month', signup_at));
-- Find agents stuck at a stage for too long
CREATE INDEX idx_onboarding_stuck ON agent_onboarding_milestones(current_stage, updated_at);
-- Channel-level onboarding analysis
CREATE INDEX idx_onboarding_channel ON agent_onboarding_milestones(onboarding_channel_id);

COMMENT ON TABLE agent_onboarding_milestones IS
    'Tracks each agent through the onboarding funnel from signup to first sale. '
    'Critical for diagnosing the 0% activation rate of 2024 cohort agents.';


-- ============================================================================
-- TABLE 2: agent_engagement_score
-- ============================================================================
-- PURPOSE: Daily computed composite engagement score per agent (0-100).
-- Combines login frequency, quote activity, conversion success, and
-- product diversity into a single actionable metric.
--
-- WHY THIS MATTERS: With 76,917 agents, managers cannot manually review each.
-- The engagement score enables automated segmentation (Star/Rising/Dormant/Dead)
-- and triggers alerts when a productive agent starts disengaging.
--
-- HOW TO POPULATE: Nightly batch job computes scores from the previous day's
-- activity data across agent_daily_logins, daily_quote_counts, and
-- sold_policies_data. See companion ETL script.
-- ============================================================================

CREATE TABLE IF NOT EXISTS agent_engagement_score (
    id                      BIGSERIAL PRIMARY KEY,
    agent_id                BIGINT NOT NULL,
    score_date              DATE NOT NULL,

    -- Component scores (each 0-100, weighted to produce overall score)
    login_score             SMALLINT NOT NULL DEFAULT 0 CHECK (login_score BETWEEN 0 AND 100),
    quote_activity_score    SMALLINT NOT NULL DEFAULT 0 CHECK (quote_activity_score BETWEEN 0 AND 100),
    conversion_score        SMALLINT NOT NULL DEFAULT 0 CHECK (conversion_score BETWEEN 0 AND 100),
    product_diversity_score SMALLINT NOT NULL DEFAULT 0 CHECK (product_diversity_score BETWEEN 0 AND 100),
    recency_score           SMALLINT NOT NULL DEFAULT 0 CHECK (recency_score BETWEEN 0 AND 100),

    -- Weighted composite (computed by ETL; weights configurable)
    -- Default weights: login=15%, quotes=25%, conversion=30%, diversity=15%, recency=15%
    overall_score           NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (overall_score BETWEEN 0 AND 100),

    -- Derived segment based on overall_score
    -- Star: 80-100, Rising: 60-79, Occasional: 30-59, Dormant: 1-29, Dead: 0
    agent_segment           VARCHAR(20) NOT NULL DEFAULT 'dead'
        CHECK (agent_segment IN ('star', 'rising', 'occasional', 'dormant', 'dead')),

    -- Week-over-week and month-over-month score change (for trend detection)
    score_change_7d         NUMERIC(5,2),   -- vs 7 days ago
    score_change_30d        NUMERIC(5,2),   -- vs 30 days ago

    -- Flags for alert system
    is_declining            BOOLEAN NOT NULL DEFAULT FALSE,  -- score dropped >15 pts in 7 days
    is_at_risk              BOOLEAN NOT NULL DEFAULT FALSE,  -- was active, now declining

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_engagement_agent FOREIGN KEY (agent_id) REFERENCES users(id),
    CONSTRAINT uq_engagement_agent_date UNIQUE (agent_id, score_date)
);

-- Dashboard: show today's score distribution
CREATE INDEX idx_engagement_date_segment ON agent_engagement_score(score_date, agent_segment);
-- Alert system: find at-risk agents quickly
CREATE INDEX idx_engagement_at_risk ON agent_engagement_score(score_date, is_at_risk) WHERE is_at_risk = TRUE;
-- Find declining agents
CREATE INDEX idx_engagement_declining ON agent_engagement_score(score_date, is_declining) WHERE is_declining = TRUE;
-- Agent-level history lookups
CREATE INDEX idx_engagement_agent_date ON agent_engagement_score(agent_id, score_date DESC);
-- Segment-based queries
CREATE INDEX idx_engagement_segment ON agent_engagement_score(agent_segment, score_date);

COMMENT ON TABLE agent_engagement_score IS
    'Daily composite engagement score (0-100) per agent with segment classification. '
    'Enables automated identification of star performers, declining agents, and dead accounts.';


-- ============================================================================
-- TABLE 3: quote_details
-- ============================================================================
-- PURPOSE: Individual quote-level data. Currently the system only stores
-- daily_quote_counts (aggregate count per agent per day). This table stores
-- each quote event so we can analyze:
--   - Quote-to-policy conversion at the individual level
--   - Why specific quotes didn't convert (price, eligibility, drop-off point)
--   - Insurer-level quote acceptance rates
--   - Time-of-day patterns
--
-- WHY THIS MATTERS: 2,291 agents are quoting but not converting. Without
-- individual quote data, we cannot diagnose whether the issue is price,
-- product fit, UX friction, or something else.
--
-- HOW TO POPULATE: Application writes here on every quote generation event.
-- Backfill is not possible for historical quotes (only counts exist).
-- ============================================================================

CREATE TABLE IF NOT EXISTS quote_details (
    id                      BIGSERIAL PRIMARY KEY,
    quote_id                UUID NOT NULL DEFAULT gen_random_uuid(),

    -- Who generated the quote
    agent_id                BIGINT NOT NULL,
    sales_channel_id        BIGINT,

    -- What was quoted
    product_type            VARCHAR(50) NOT NULL,        -- '4w', '2w', 'health', etc.
    insurer                 VARCHAR(100),                -- insurer quoted

    -- Customer context
    customer_phone          VARCHAR(20),                 -- hashed/masked for privacy
    customer_state          VARCHAR(100),
    vehicle_type            VARCHAR(50),
    vehicle_make            VARCHAR(100),
    vehicle_model           VARCHAR(100),
    vehicle_year            INTEGER,

    -- Quote economics
    sum_insured             NUMERIC(14,2),
    idv                     NUMERIC(14,2),
    quoted_premium          NUMERIC(12,2),
    net_premium             NUMERIC(12,2),

    -- Is this a breakin journey?
    is_breakin_journey      BOOLEAN DEFAULT FALSE,

    -- Business type
    policy_business_type    VARCHAR(30),                 -- 'New Policy', 'Renewal', 'Roll Over'

    -- Funnel tracking
    quote_status            VARCHAR(30) NOT NULL DEFAULT 'generated'
        CHECK (quote_status IN (
            'generated', 'viewed', 'proposal_started', 'proposal_completed',
            'payment_initiated', 'payment_failed', 'policy_issued', 'expired', 'abandoned'
        )),

    -- Link to resulting policy (if converted)
    sold_policy_id          BIGINT,
    proposal_id             VARCHAR(100),

    -- Timestamps for funnel analysis
    quoted_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    proposal_started_at     TIMESTAMPTZ,
    proposal_completed_at   TIMESTAMPTZ,
    payment_initiated_at    TIMESTAMPTZ,
    policy_issued_at        TIMESTAMPTZ,
    expired_at              TIMESTAMPTZ,

    -- Drop-off tracking
    drop_off_stage          VARCHAR(30),                 -- stage where user abandoned
    drop_off_reason_id      INTEGER,                     -- FK to quote_drop_reasons

    -- Metadata
    source_platform         VARCHAR(30),                 -- 'web', 'mobile_app', 'api'
    session_id              UUID,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_quote_agent FOREIGN KEY (agent_id) REFERENCES users(id),
    CONSTRAINT uq_quote_id UNIQUE (quote_id)
);

-- Funnel analysis: conversion rates by product
CREATE INDEX idx_quote_product_status ON quote_details(product_type, quote_status);
-- Agent-level conversion analysis
CREATE INDEX idx_quote_agent_date ON quote_details(agent_id, quoted_at DESC);
-- Time-based analysis
CREATE INDEX idx_quote_quoted_at ON quote_details(quoted_at);
-- Insurer conversion comparison
CREATE INDEX idx_quote_insurer_status ON quote_details(insurer, quote_status);
-- Breakin journey analysis
CREATE INDEX idx_quote_breakin ON quote_details(is_breakin_journey, quote_status);
-- Channel/broker analysis
CREATE INDEX idx_quote_channel ON quote_details(sales_channel_id, quoted_at);
-- Abandoned quote recovery
CREATE INDEX idx_quote_abandoned ON quote_details(quote_status, quoted_at)
    WHERE quote_status IN ('generated', 'viewed', 'proposal_started');
-- Link back to policy
CREATE INDEX idx_quote_sold_policy ON quote_details(sold_policy_id) WHERE sold_policy_id IS NOT NULL;

COMMENT ON TABLE quote_details IS
    'Individual quote-level data enabling funnel analysis, drop-off diagnosis, '
    'and insurer-level conversion tracking. Critical for understanding the 2,291 '
    'agents who quote but never sell.';


-- ============================================================================
-- TABLE 4: quote_drop_reasons
-- ============================================================================
-- PURPOSE: Lookup table categorizing why quotes fail to convert. Used in
-- conjunction with quote_details.drop_off_reason_id.
--
-- WHY THIS MATTERS: Knowing WHERE quotes drop off is insufficient. We need
-- to know WHY. Is it price? Is it eligibility? Is it UX friction?
-- ============================================================================

CREATE TABLE IF NOT EXISTS quote_drop_reasons (
    id                      SERIAL PRIMARY KEY,
    reason_code             VARCHAR(50) NOT NULL UNIQUE,
    reason_category         VARCHAR(50) NOT NULL,       -- 'price', 'eligibility', 'ux', 'technical', 'customer', 'other'
    reason_description      TEXT NOT NULL,
    is_actionable           BOOLEAN NOT NULL DEFAULT TRUE,  -- can we do something about this?
    suggested_action        TEXT,                        -- what to do when this reason is frequent
    display_order           INTEGER NOT NULL DEFAULT 0,
    is_active               BOOLEAN NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed with common drop-off reasons
INSERT INTO quote_drop_reasons (reason_code, reason_category, reason_description, is_actionable, suggested_action) VALUES
    ('price_too_high', 'price', 'Customer found premium too expensive', TRUE, 'Review insurer pricing; offer discount coupons; suggest lower IDV'),
    ('price_comparison', 'price', 'Customer comparing with other platforms', TRUE, 'Enable price-match guarantee; show value-adds'),
    ('eligibility_rejected', 'eligibility', 'Customer/vehicle did not meet insurer criteria', FALSE, 'Route to insurers with broader eligibility'),
    ('breakin_inspection_pending', 'eligibility', 'Breakin inspection not completed', TRUE, 'Send inspection reminder nudge; offer doorstep inspection'),
    ('document_missing', 'ux', 'Required documents not available with customer', TRUE, 'Allow document upload later; send reminder'),
    ('form_too_long', 'ux', 'Customer abandoned long form', TRUE, 'Simplify form; pre-fill from RC data'),
    ('technical_error', 'technical', 'Quote API or payment gateway error', TRUE, 'Alert engineering team; retry mechanism'),
    ('payment_failed', 'technical', 'Payment transaction failed', TRUE, 'Offer alternative payment methods; retry'),
    ('customer_not_ready', 'customer', 'Customer just browsing / not ready to buy', TRUE, 'Follow up in 3 days; send renewal reminder closer to expiry'),
    ('customer_unreachable', 'customer', 'Agent could not reach customer after quote', TRUE, 'Automated follow-up SMS/WhatsApp'),
    ('wrong_product', 'customer', 'Customer needed different product type', TRUE, 'Improve product recommendation engine'),
    ('competitor_purchased', 'customer', 'Customer bought from another platform', FALSE, 'Analyze pricing gap; improve retention offers'),
    ('ncb_dispute', 'eligibility', 'No Claim Bonus verification issue', TRUE, 'Automate NCB verification; provide manual override path'),
    ('session_timeout', 'technical', 'User session expired during quote process', TRUE, 'Extend session duration; save draft quotes'),
    ('unknown', 'other', 'Reason not captured', TRUE, 'Improve exit survey; mandatory reason capture on abandonment');

COMMENT ON TABLE quote_drop_reasons IS
    'Lookup table for quote drop-off reasons. Each reason has a category, '
    'actionability flag, and suggested remediation action.';


-- ============================================================================
-- TABLE 5: cross_sell_opportunities
-- ============================================================================
-- PURPOSE: Track cross-sell prompts shown to agents and whether they acted.
-- Currently top 20 agents sell only 1 product type. This table enables
-- measuring cross-sell campaign effectiveness.
--
-- WHY THIS MATTERS: Health product has only 34 sales in 6 months. The agent
-- base is motor-focused but every motor customer also needs health insurance.
-- Tracking cross-sell prompts → actions → conversions quantifies the
-- opportunity and measures campaign ROI.
-- ============================================================================

CREATE TABLE IF NOT EXISTS cross_sell_opportunities (
    id                      BIGSERIAL PRIMARY KEY,

    -- The trigger event
    trigger_policy_id       BIGINT,                      -- policy that triggered the cross-sell
    trigger_product_type    VARCHAR(50) NOT NULL,         -- product just sold/quoted

    -- The opportunity
    recommended_product     VARCHAR(50) NOT NULL,         -- product we're recommending
    opportunity_reason      VARCHAR(100),                 -- 'motor_to_health', 'car_to_2w', etc.

    -- Who
    agent_id                BIGINT NOT NULL,
    customer_phone          VARCHAR(20),                  -- hashed
    sales_channel_id        BIGINT,

    -- Tracking the funnel: shown → clicked → quoted → sold
    prompt_shown_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    prompt_clicked_at       TIMESTAMPTZ,
    quote_generated_at      TIMESTAMPTZ,
    policy_sold_at          TIMESTAMPTZ,

    -- Outcome
    outcome                 VARCHAR(30) NOT NULL DEFAULT 'shown'
        CHECK (outcome IN ('shown', 'clicked', 'quoted', 'sold', 'dismissed', 'expired')),

    -- Resulting policy if converted
    resulting_policy_id     BIGINT,
    resulting_premium       NUMERIC(12,2),

    -- Campaign tracking
    campaign_id             VARCHAR(50),                 -- which cross-sell campaign
    prompt_variant          VARCHAR(50),                 -- A/B test variant

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_crosssell_agent FOREIGN KEY (agent_id) REFERENCES users(id)
);

-- Campaign effectiveness analysis
CREATE INDEX idx_crosssell_campaign ON cross_sell_opportunities(campaign_id, outcome);
-- Agent cross-sell behavior
CREATE INDEX idx_crosssell_agent ON cross_sell_opportunities(agent_id, prompt_shown_at);
-- Product pair analysis
CREATE INDEX idx_crosssell_products ON cross_sell_opportunities(trigger_product_type, recommended_product, outcome);
-- Conversion funnel
CREATE INDEX idx_crosssell_outcome ON cross_sell_opportunities(outcome, prompt_shown_at);
-- Time-based analysis
CREATE INDEX idx_crosssell_shown_at ON cross_sell_opportunities(prompt_shown_at);

COMMENT ON TABLE cross_sell_opportunities IS
    'Tracks cross-sell prompts shown to agents and their outcomes. Critical for '
    'reviving the health product (34 sales in 6 months) by leveraging the motor base.';


-- ============================================================================
-- TABLE 6: agent_product_certification
-- ============================================================================
-- PURPOSE: Track which products each agent is certified/trained to sell.
-- Currently agents default to motor because that is what they know.
-- This table enables:
--   - Identifying agents eligible but not selling specific products
--   - Measuring training → activation for new products
--   - Targeting training campaigns to the right audience
--
-- WHY THIS MATTERS: Health product is dead with only 34 sales. Are agents
-- even certified to sell health? If so, why aren't they? If not, who should
-- we certify first?
-- ============================================================================

CREATE TABLE IF NOT EXISTS agent_product_certification (
    id                      BIGSERIAL PRIMARY KEY,
    agent_id                BIGINT NOT NULL,
    product_type            VARCHAR(50) NOT NULL,        -- '4w', '2w', 'health', 'term', etc.

    -- Certification journey
    training_started_at     TIMESTAMPTZ,
    training_completed_at   TIMESTAMPTZ,
    exam_passed_at          TIMESTAMPTZ,
    certified_at            TIMESTAMPTZ,
    certification_expiry    DATE,

    -- Status
    certification_status    VARCHAR(30) NOT NULL DEFAULT 'not_started'
        CHECK (certification_status IN (
            'not_started', 'training_in_progress', 'training_complete',
            'exam_failed', 'certified', 'expired', 'revoked'
        )),

    -- Post-certification activation
    first_quote_after_cert  TIMESTAMPTZ,
    first_sale_after_cert   TIMESTAMPTZ,
    total_sales_count       INTEGER NOT NULL DEFAULT 0,
    total_premium_sold      NUMERIC(14,2) NOT NULL DEFAULT 0,

    -- Metadata
    certifying_body         VARCHAR(100),                -- IRDAI, internal, etc.
    certificate_number      VARCHAR(100),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_cert_agent FOREIGN KEY (agent_id) REFERENCES users(id),
    CONSTRAINT uq_cert_agent_product UNIQUE (agent_id, product_type)
);

-- Find certified but inactive agents for a product
CREATE INDEX idx_cert_product_status ON agent_product_certification(product_type, certification_status);
-- Agent certification portfolio
CREATE INDEX idx_cert_agent ON agent_product_certification(agent_id);
-- Expiring certifications
CREATE INDEX idx_cert_expiry ON agent_product_certification(certification_expiry)
    WHERE certification_status = 'certified';

COMMENT ON TABLE agent_product_certification IS
    'Tracks agent training and certification per product type. Enables targeting '
    'health product training to motor-only agents and measuring training ROI.';


-- ============================================================================
-- TABLE 7: customer_renewal_tracker
-- ============================================================================
-- PURPOSE: Track every policy from issuance through expiry and renewal.
-- Currently 294,136 policies exist with policy_expiry_date. This table
-- transforms that passive data into an active renewal pipeline.
--
-- WHY THIS MATTERS: Insurance renewal is the highest-margin, lowest-effort
-- sale. With 294K+ policies, the renewal pipeline is potentially the biggest
-- revenue opportunity. Without active tracking, renewals are lost to
-- competitors.
-- ============================================================================

CREATE TABLE IF NOT EXISTS customer_renewal_tracker (
    id                      BIGSERIAL PRIMARY KEY,

    -- Original policy reference
    original_policy_id      BIGINT NOT NULL,             -- FK to sold_policies_data
    policy_number           VARCHAR(100),
    customer_phone          VARCHAR(20),
    customer_name           VARCHAR(200),
    customer_state          VARCHAR(100),

    -- Product info
    product_type            VARCHAR(50) NOT NULL,
    insurer                 VARCHAR(100),
    vehicle_registration    VARCHAR(50),

    -- Policy dates
    policy_start_date       DATE NOT NULL,
    policy_expiry_date      DATE NOT NULL,

    -- Premium info
    original_premium        NUMERIC(12,2),
    expected_renewal_premium NUMERIC(12,2),              -- estimated from trends

    -- Assignment
    original_agent_id       BIGINT,                      -- agent who sold original policy
    assigned_agent_id       BIGINT,                      -- agent assigned for renewal (may differ)
    sales_channel_id        BIGINT,

    -- Renewal funnel tracking
    renewal_status          VARCHAR(30) NOT NULL DEFAULT 'upcoming'
        CHECK (renewal_status IN (
            'upcoming',             -- expiry > 30 days away
            'due_soon',             -- expiry within 30 days
            'overdue',              -- past expiry, not renewed
            'contacted',            -- agent reached out to customer
            'quote_generated',      -- renewal quote created
            'renewed_same_insurer', -- renewed with same insurer
            'renewed_diff_insurer', -- renewed but switched insurer
            'renewed_other_platform', -- lost to competitor
            'lapsed',              -- customer did not renew (confirmed)
            'vehicle_sold',        -- customer sold the vehicle
            'unknown'              -- no info after expiry
        )),

    -- Outreach tracking
    first_reminder_sent_at  TIMESTAMPTZ,
    second_reminder_sent_at TIMESTAMPTZ,
    agent_contacted_at      TIMESTAMPTZ,
    customer_response       VARCHAR(100),

    -- Renewal outcome
    renewed_policy_id       BIGINT,                      -- FK to new policy in sold_policies_data
    renewed_premium         NUMERIC(12,2),
    renewed_at              TIMESTAMPTZ,
    premium_change_pct      NUMERIC(6,2),                -- % change from original premium

    -- Risk scoring
    churn_risk_score        NUMERIC(5,2),                -- 0-100, higher = more likely to churn

    -- Metadata
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_renewal_original_policy FOREIGN KEY (original_policy_id) REFERENCES sold_policies_data(id),
    CONSTRAINT fk_renewal_original_agent FOREIGN KEY (original_agent_id) REFERENCES users(id),
    CONSTRAINT fk_renewal_assigned_agent FOREIGN KEY (assigned_agent_id) REFERENCES users(id)
);

-- Upcoming renewals pipeline (most critical query)
CREATE INDEX idx_renewal_expiry_status ON customer_renewal_tracker(policy_expiry_date, renewal_status);
-- Agent renewal pipeline
CREATE INDEX idx_renewal_assigned_agent ON customer_renewal_tracker(assigned_agent_id, policy_expiry_date);
-- Product-level renewal analysis
CREATE INDEX idx_renewal_product ON customer_renewal_tracker(product_type, renewal_status);
-- High-value renewals at risk
CREATE INDEX idx_renewal_churn_risk ON customer_renewal_tracker(churn_risk_score DESC)
    WHERE renewal_status IN ('upcoming', 'due_soon', 'overdue');
-- Status-based lookups
CREATE INDEX idx_renewal_status ON customer_renewal_tracker(renewal_status);
-- Channel renewal tracking
CREATE INDEX idx_renewal_channel ON customer_renewal_tracker(sales_channel_id, policy_expiry_date);

COMMENT ON TABLE customer_renewal_tracker IS
    'Active renewal pipeline tracking for all policies. Transforms passive expiry dates '
    'into an actionable sales pipeline with outreach tracking and churn risk scoring.';


-- ============================================================================
-- TABLE 8: agent_earnings
-- ============================================================================
-- PURPOSE: Commission tracking per agent per transaction. Agents need to see
-- their earnings to stay motivated. Management needs to understand unit
-- economics per agent tier.
--
-- WHY THIS MATTERS: Agent motivation is directly tied to earnings visibility.
-- If agents cannot see what they earn, they have no incentive to stay active.
-- This is likely a contributor to the 0.8% monthly active rate.
-- ============================================================================

CREATE TABLE IF NOT EXISTS agent_earnings (
    id                      BIGSERIAL PRIMARY KEY,
    agent_id                BIGINT NOT NULL,

    -- Policy reference
    policy_id               BIGINT,                      -- FK to sold_policies_data
    policy_number           VARCHAR(100),
    product_type            VARCHAR(50) NOT NULL,
    insurer                 VARCHAR(100),

    -- Earning details
    policy_premium          NUMERIC(12,2) NOT NULL,
    net_premium             NUMERIC(12,2),
    commission_rate_pct     NUMERIC(6,4),                -- e.g., 2.5000 for 2.5%
    gross_commission        NUMERIC(12,2) NOT NULL,
    platform_fee            NUMERIC(12,2) NOT NULL DEFAULT 0,
    tds_deducted            NUMERIC(12,2) NOT NULL DEFAULT 0,
    net_earnings            NUMERIC(12,2) NOT NULL,

    -- Payment tracking
    earning_status          VARCHAR(30) NOT NULL DEFAULT 'accrued'
        CHECK (earning_status IN ('accrued', 'approved', 'processing', 'paid', 'disputed', 'reversed')),
    accrued_date            DATE NOT NULL,
    payment_date            DATE,
    payment_reference       VARCHAR(100),

    -- Context
    sales_channel_id        BIGINT,
    is_renewal              BOOLEAN DEFAULT FALSE,
    is_cross_sell           BOOLEAN DEFAULT FALSE,

    -- Bonus/incentive markers
    bonus_applicable        BOOLEAN DEFAULT FALSE,
    bonus_amount            NUMERIC(12,2) DEFAULT 0,
    bonus_reason            VARCHAR(100),

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_earnings_agent FOREIGN KEY (agent_id) REFERENCES users(id)
);

-- Agent earnings dashboard
CREATE INDEX idx_earnings_agent_date ON agent_earnings(agent_id, accrued_date DESC);
-- Payment processing
CREATE INDEX idx_earnings_status ON agent_earnings(earning_status, accrued_date);
-- Product-level commission analysis
CREATE INDEX idx_earnings_product ON agent_earnings(product_type, accrued_date);
-- Monthly earnings aggregation
CREATE INDEX idx_earnings_month ON agent_earnings(DATE_TRUNC('month', accrued_date), agent_id);
-- Channel-level economics
CREATE INDEX idx_earnings_channel ON agent_earnings(sales_channel_id, accrued_date);

COMMENT ON TABLE agent_earnings IS
    'Commission and earnings tracking per agent per transaction. Critical for agent '
    'motivation (earnings visibility) and platform unit economics analysis.';


-- ============================================================================
-- TABLE 9: broker_scorecard_monthly
-- ============================================================================
-- PURPOSE: Materialized monthly scorecard per broker. Pre-computed for fast
-- dashboard rendering. Combines data from multiple source tables.
--
-- WHY THIS MATTERS: 43 broker partners need monthly performance reviews.
-- Currently management is "flying blind." This table provides a single
-- source of truth for broker performance with all key metrics pre-computed.
-- Spinny at 55% volume concentration is a critical risk that needs monitoring.
-- ============================================================================

CREATE TABLE IF NOT EXISTS broker_scorecard_monthly (
    id                      BIGSERIAL PRIMARY KEY,
    sales_channel_id        BIGINT NOT NULL,
    broker_name             VARCHAR(200),
    scorecard_month         DATE NOT NULL,               -- first day of month

    -- Volume metrics
    total_policies          INTEGER NOT NULL DEFAULT 0,
    total_premium           NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_net_premium       NUMERIC(14,2) NOT NULL DEFAULT 0,

    -- Agent metrics
    total_agents            INTEGER NOT NULL DEFAULT 0,   -- agents assigned to this broker
    active_agents           INTEGER NOT NULL DEFAULT 0,   -- agents with >= 1 sale this month
    quoting_agents          INTEGER NOT NULL DEFAULT 0,   -- agents with >= 1 quote this month
    agent_activation_rate   NUMERIC(6,2) DEFAULT 0,       -- active/total * 100

    -- Funnel metrics
    total_quotes            INTEGER NOT NULL DEFAULT 0,
    total_proposals         INTEGER NOT NULL DEFAULT 0,
    total_conversions       INTEGER NOT NULL DEFAULT 0,
    quote_to_proposal_rate  NUMERIC(6,2) DEFAULT 0,       -- proposals/quotes * 100
    proposal_to_policy_rate NUMERIC(6,2) DEFAULT 0,       -- policies/proposals * 100
    overall_conversion_rate NUMERIC(6,2) DEFAULT 0,        -- policies/quotes * 100

    -- Product mix
    policies_4w             INTEGER NOT NULL DEFAULT 0,
    policies_2w             INTEGER NOT NULL DEFAULT 0,
    policies_health         INTEGER NOT NULL DEFAULT 0,
    policies_other          INTEGER NOT NULL DEFAULT 0,
    premium_4w              NUMERIC(14,2) NOT NULL DEFAULT 0,
    premium_2w              NUMERIC(14,2) NOT NULL DEFAULT 0,
    premium_health          NUMERIC(14,2) NOT NULL DEFAULT 0,
    premium_other           NUMERIC(14,2) NOT NULL DEFAULT 0,
    product_diversity_score NUMERIC(5,2) DEFAULT 0,        -- Herfindahl-based, 0-100

    -- Business type mix
    new_policies            INTEGER NOT NULL DEFAULT 0,
    renewal_policies        INTEGER NOT NULL DEFAULT 0,
    rollover_policies       INTEGER NOT NULL DEFAULT 0,
    breakin_policies        INTEGER NOT NULL DEFAULT 0,

    -- Efficiency metrics
    avg_premium_per_policy  NUMERIC(12,2) DEFAULT 0,
    policies_per_active_agent NUMERIC(8,2) DEFAULT 0,
    premium_per_active_agent NUMERIC(14,2) DEFAULT 0,

    -- Month-over-month trends
    policy_count_mom_pct    NUMERIC(8,2),                 -- month-over-month % change
    premium_mom_pct         NUMERIC(8,2),
    conversion_rate_change  NUMERIC(6,2),

    -- Platform share
    platform_policy_share_pct NUMERIC(6,2) DEFAULT 0,     -- this broker's % of total platform
    platform_premium_share_pct NUMERIC(6,2) DEFAULT 0,

    -- Risk indicators
    concentration_risk      VARCHAR(20) DEFAULT 'low'
        CHECK (concentration_risk IN ('critical', 'high', 'medium', 'low')),
    trend_direction         VARCHAR(20) DEFAULT 'stable'
        CHECK (trend_direction IN ('accelerating', 'growing', 'stable', 'declining', 'critical_decline')),

    -- Tier classification
    broker_tier             VARCHAR(20) NOT NULL DEFAULT 'inactive'
        CHECK (broker_tier IN ('platinum', 'gold', 'silver', 'bronze', 'inactive')),

    -- Overall score (0-100)
    overall_score           NUMERIC(5,2) NOT NULL DEFAULT 0,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_scorecard_channel_month UNIQUE (sales_channel_id, scorecard_month)
);

-- Monthly dashboard
CREATE INDEX idx_scorecard_month ON broker_scorecard_monthly(scorecard_month, broker_tier);
-- Broker trend analysis
CREATE INDEX idx_scorecard_broker ON broker_scorecard_monthly(sales_channel_id, scorecard_month);
-- Risk monitoring
CREATE INDEX idx_scorecard_risk ON broker_scorecard_monthly(scorecard_month, concentration_risk);
-- Tier-based views
CREATE INDEX idx_scorecard_tier ON broker_scorecard_monthly(broker_tier, scorecard_month);

COMMENT ON TABLE broker_scorecard_monthly IS
    'Pre-computed monthly broker scorecard with all key metrics. Enables fast dashboard '
    'rendering and broker performance reviews. Monitors Spinny concentration risk.';


-- ============================================================================
-- TABLE 10: agent_health_score
-- ============================================================================
-- PURPOSE: Comprehensive weekly health metric per agent that goes beyond
-- the daily engagement score. Incorporates longer-term trends, compliance,
-- customer satisfaction, and business quality metrics.
--
-- WHY THIS MATTERS: Different from engagement_score which is daily and
-- activity-focused. Health score is weekly and holistic - it answers
-- "Is this agent a healthy, sustainable contributor to the platform?"
-- ============================================================================

CREATE TABLE IF NOT EXISTS agent_health_score (
    id                      BIGSERIAL PRIMARY KEY,
    agent_id                BIGINT NOT NULL,
    score_week              DATE NOT NULL,               -- Monday of the week

    -- Dimension scores (each 0-100)
    activity_score          SMALLINT NOT NULL DEFAULT 0,  -- login + quote frequency
    productivity_score      SMALLINT NOT NULL DEFAULT 0,  -- policies sold / quotes generated
    quality_score           SMALLINT NOT NULL DEFAULT 0,  -- cancellation rate, complaint rate
    growth_score            SMALLINT NOT NULL DEFAULT 0,  -- week-over-week improvement
    diversity_score         SMALLINT NOT NULL DEFAULT 0,  -- product mix, insurer mix
    compliance_score        SMALLINT NOT NULL DEFAULT 0,  -- certification current, KYC complete
    retention_score         SMALLINT NOT NULL DEFAULT 0,  -- customer renewal rate

    -- Composite score
    overall_health          NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (overall_health BETWEEN 0 AND 100),

    -- Trend
    health_trend            VARCHAR(20) NOT NULL DEFAULT 'stable'
        CHECK (health_trend IN ('improving', 'stable', 'declining', 'critical')),
    health_change_4w        NUMERIC(5,2),                -- vs 4 weeks ago

    -- Key metrics snapshot
    policies_sold_week      INTEGER NOT NULL DEFAULT 0,
    premium_sold_week       NUMERIC(14,2) NOT NULL DEFAULT 0,
    quotes_generated_week   INTEGER NOT NULL DEFAULT 0,
    conversion_rate_week    NUMERIC(6,2) DEFAULT 0,
    login_days_week         SMALLINT NOT NULL DEFAULT 0,
    unique_products_sold    SMALLINT NOT NULL DEFAULT 0,

    -- Flags
    needs_intervention      BOOLEAN NOT NULL DEFAULT FALSE,
    intervention_reason     TEXT,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_health_agent FOREIGN KEY (agent_id) REFERENCES users(id),
    CONSTRAINT uq_health_agent_week UNIQUE (agent_id, score_week)
);

-- Weekly dashboard
CREATE INDEX idx_health_week ON agent_health_score(score_week, overall_health DESC);
-- Intervention queue
CREATE INDEX idx_health_intervention ON agent_health_score(score_week, needs_intervention)
    WHERE needs_intervention = TRUE;
-- Agent history
CREATE INDEX idx_health_agent ON agent_health_score(agent_id, score_week DESC);
-- Trend analysis
CREATE INDEX idx_health_trend ON agent_health_score(score_week, health_trend);

COMMENT ON TABLE agent_health_score IS
    'Weekly holistic health score per agent incorporating activity, productivity, quality, '
    'growth, diversity, compliance, and retention dimensions. Used for proactive intervention.';


-- ============================================================================
-- TABLE 11: alerts_and_nudges
-- ============================================================================
-- PURPOSE: Track every automated alert/nudge sent to agents, managers, or
-- brokers. Enables measuring nudge effectiveness and preventing alert fatigue.
--
-- WHY THIS MATTERS: The platform needs to proactively reach out to:
--   - New agents who haven't quoted in 7 days
--   - Active agents whose activity is declining
--   - Agents with renewals coming up
--   - Agents quoting but not converting
-- Without tracking which nudges were sent and their outcomes, we cannot
-- optimize the intervention system.
-- ============================================================================

CREATE TABLE IF NOT EXISTS alerts_and_nudges (
    id                      BIGSERIAL PRIMARY KEY,

    -- Target of the nudge
    target_type             VARCHAR(30) NOT NULL          -- 'agent', 'broker', 'manager', 'customer'
        CHECK (target_type IN ('agent', 'broker', 'manager', 'customer')),
    target_id               BIGINT NOT NULL,              -- user ID or broker ID

    -- Nudge details
    nudge_type              VARCHAR(50) NOT NULL,         -- categorized nudge type
    nudge_category          VARCHAR(50) NOT NULL          -- high-level category
        CHECK (nudge_category IN (
            'onboarding', 'activation', 'engagement', 'conversion',
            'cross_sell', 'renewal', 'compliance', 'achievement',
            'risk_alert', 'operational'
        )),

    -- Content
    nudge_title             VARCHAR(200) NOT NULL,
    nudge_message           TEXT NOT NULL,

    -- Delivery
    delivery_channel        VARCHAR(30) NOT NULL          -- 'push', 'sms', 'whatsapp', 'email', 'in_app'
        CHECK (delivery_channel IN ('push', 'sms', 'whatsapp', 'email', 'in_app')),

    -- Status tracking
    nudge_status            VARCHAR(30) NOT NULL DEFAULT 'sent'
        CHECK (nudge_status IN ('queued', 'sent', 'delivered', 'read', 'acted_on', 'failed', 'suppressed')),

    -- Timestamps
    scheduled_at            TIMESTAMPTZ,
    sent_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    delivered_at            TIMESTAMPTZ,
    read_at                 TIMESTAMPTZ,
    acted_on_at             TIMESTAMPTZ,

    -- Outcome tracking
    desired_action          VARCHAR(100),                 -- what we want them to do
    action_taken            VARCHAR(100),                 -- what they actually did
    action_within_hours     NUMERIC(8,2),                 -- hours from delivery to action

    -- Context
    trigger_event           VARCHAR(100),                 -- what triggered this nudge
    trigger_data            JSONB,                        -- relevant context data

    -- A/B testing
    experiment_id           VARCHAR(50),
    variant                 VARCHAR(50),

    -- Anti-fatigue
    nudge_sequence_number   INTEGER NOT NULL DEFAULT 1,   -- nth nudge of this type to this user
    suppress_until          TIMESTAMPTZ,                  -- don't send more until this time

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_nudge_target CHECK (target_id > 0)
);

-- Nudge effectiveness analysis
CREATE INDEX idx_nudge_type_status ON alerts_and_nudges(nudge_type, nudge_status);
-- Target's nudge history (prevent fatigue)
CREATE INDEX idx_nudge_target ON alerts_and_nudges(target_type, target_id, sent_at DESC);
-- Category-level analysis
CREATE INDEX idx_nudge_category ON alerts_and_nudges(nudge_category, sent_at);
-- A/B test analysis
CREATE INDEX idx_nudge_experiment ON alerts_and_nudges(experiment_id, variant)
    WHERE experiment_id IS NOT NULL;
-- Delivery monitoring
CREATE INDEX idx_nudge_status ON alerts_and_nudges(nudge_status, sent_at);
-- Anti-fatigue: check recent nudges before sending
CREATE INDEX idx_nudge_fatigue ON alerts_and_nudges(target_type, target_id, nudge_type, sent_at DESC);

COMMENT ON TABLE alerts_and_nudges IS
    'Tracks all automated nudges/alerts sent to agents, brokers, and managers. '
    'Enables nudge effectiveness measurement and prevents alert fatigue.';


-- ============================================================================
-- TABLE 12: platform_daily_snapshot
-- ============================================================================
-- PURPOSE: Daily platform-level aggregate metrics for fast trend dashboards.
-- One row per day with all key KPIs. Eliminates expensive daily aggregation
-- queries across large tables.
--
-- WHY THIS MATTERS: The executive dashboard needs to load in < 2 seconds.
-- Querying 294K+ policies and 226K+ quote records daily is too slow.
-- This table pre-computes the numbers.
-- ============================================================================

CREATE TABLE IF NOT EXISTS platform_daily_snapshot (
    snapshot_date           DATE PRIMARY KEY,

    -- Volume metrics
    policies_sold           INTEGER NOT NULL DEFAULT 0,
    total_premium           NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_net_premium       NUMERIC(14,2) NOT NULL DEFAULT 0,

    -- Agent metrics
    total_agents            INTEGER NOT NULL DEFAULT 0,
    active_agents           INTEGER NOT NULL DEFAULT 0,   -- logged in today
    selling_agents          INTEGER NOT NULL DEFAULT 0,   -- sold >= 1 policy today
    quoting_agents          INTEGER NOT NULL DEFAULT 0,   -- generated >= 1 quote today
    new_agents_joined       INTEGER NOT NULL DEFAULT 0,

    -- Funnel metrics
    total_quotes            INTEGER NOT NULL DEFAULT 0,
    total_proposals         INTEGER NOT NULL DEFAULT 0,   -- if available
    daily_conversion_rate   NUMERIC(6,2) DEFAULT 0,

    -- Product breakdown
    policies_4w             INTEGER NOT NULL DEFAULT 0,
    policies_2w             INTEGER NOT NULL DEFAULT 0,
    policies_health         INTEGER NOT NULL DEFAULT 0,
    policies_other          INTEGER NOT NULL DEFAULT 0,
    premium_4w              NUMERIC(14,2) NOT NULL DEFAULT 0,
    premium_2w              NUMERIC(14,2) NOT NULL DEFAULT 0,
    premium_health          NUMERIC(14,2) NOT NULL DEFAULT 0,
    premium_other           NUMERIC(14,2) NOT NULL DEFAULT 0,

    -- Broker metrics
    active_brokers          INTEGER NOT NULL DEFAULT 0,
    top_broker_share_pct    NUMERIC(6,2) DEFAULT 0,       -- concentration check

    -- Business type
    new_policies            INTEGER NOT NULL DEFAULT 0,
    renewal_policies        INTEGER NOT NULL DEFAULT 0,
    rollover_policies       INTEGER NOT NULL DEFAULT 0,
    breakin_policies        INTEGER NOT NULL DEFAULT 0,

    -- Averages
    avg_premium             NUMERIC(12,2) DEFAULT 0,
    avg_quotes_per_agent    NUMERIC(8,2) DEFAULT 0,
    avg_policies_per_agent  NUMERIC(8,2) DEFAULT 0,

    -- Running totals (for quick YTD/MTD)
    mtd_policies            INTEGER NOT NULL DEFAULT 0,
    mtd_premium             NUMERIC(14,2) NOT NULL DEFAULT 0,
    ytd_policies            INTEGER NOT NULL DEFAULT 0,
    ytd_premium             NUMERIC(14,2) NOT NULL DEFAULT 0,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Month-level aggregation
CREATE INDEX idx_snapshot_month ON platform_daily_snapshot(DATE_TRUNC('month', snapshot_date));

COMMENT ON TABLE platform_daily_snapshot IS
    'Pre-computed daily platform KPIs for fast executive dashboard rendering. '
    'Eliminates expensive real-time aggregation across large tables.';


-- ============================================================================
-- BACKFILL SCRIPTS (run after table creation)
-- ============================================================================

-- Backfill agent_onboarding_milestones from existing data
-- NOTE: This captures signup and first_sale. Other milestones require app-level data.
INSERT INTO agent_onboarding_milestones (agent_id, signup_at, first_quote_at, first_sale_at, current_stage, onboarding_channel_id)
SELECT
    u.id AS agent_id,
    u.createdat AS signup_at,
    fq.first_quote_at,
    fs.first_sale_at,
    CASE
        WHEN fs.first_sale_at IS NOT NULL THEN 'first_sale'
        WHEN fq.first_quote_at IS NOT NULL THEN 'first_quote'
        ELSE 'signed_up'
    END AS current_stage,
    u.saleschanneluserid AS onboarding_channel_id
FROM users u
LEFT JOIN (
    SELECT agent_id, MIN(quote_date)::TIMESTAMPTZ AS first_quote_at
    FROM daily_quote_counts
    WHERE quote_count > 0
    GROUP BY agent_id
) fq ON fq.agent_id = u.id
LEFT JOIN (
    SELECT agent::BIGINT AS agent_id, MIN(sold_date) AS first_sale_at
    FROM sold_policies_data
    WHERE agent IS NOT NULL AND agent != ''
    GROUP BY agent::BIGINT
) fs ON fs.agent_id = u.id
WHERE u.deletedat IS NULL
ON CONFLICT (agent_id) DO NOTHING;


-- Backfill customer_renewal_tracker from sold_policies_data
-- Populates renewal pipeline for all policies with a valid expiry date
INSERT INTO customer_renewal_tracker (
    original_policy_id, policy_number, customer_phone, customer_name,
    customer_state, product_type, insurer, vehicle_registration,
    policy_start_date, policy_expiry_date, original_premium,
    original_agent_id, assigned_agent_id, sales_channel_id,
    renewal_status
)
SELECT
    sp.id,
    sp.policy_number,
    sp.phone,
    sp.policy_holder_full_name,
    sp.policy_holder_state,
    sp.product_type,
    sp.insurer,
    sp.vehicle_registration,
    sp.policy_start_date,
    sp.policy_expiry_date,
    sp.premium_amount,
    CASE WHEN sp.agent ~ '^\d+$' THEN sp.agent::BIGINT ELSE NULL END,
    CASE WHEN sp.agent ~ '^\d+$' THEN sp.agent::BIGINT ELSE NULL END,
    sp.sales_channel_user_id,
    CASE
        WHEN sp.policy_expiry_date < CURRENT_DATE - INTERVAL '90 days' THEN 'lapsed'
        WHEN sp.policy_expiry_date < CURRENT_DATE THEN 'overdue'
        WHEN sp.policy_expiry_date <= CURRENT_DATE + INTERVAL '30 days' THEN 'due_soon'
        ELSE 'upcoming'
    END
FROM sold_policies_data sp
WHERE sp.policy_expiry_date IS NOT NULL
ON CONFLICT DO NOTHING;


COMMIT;

-- ============================================================================
-- POST-DEPLOYMENT: Verify table creation
-- ============================================================================
-- Run this to confirm all tables were created successfully:
/*
SELECT table_name,
       (SELECT COUNT(*) FROM information_schema.columns c WHERE c.table_name = t.table_name) AS column_count
FROM information_schema.tables t
WHERE table_schema = 'public'
  AND table_name IN (
    'agent_onboarding_milestones', 'agent_engagement_score', 'quote_details',
    'quote_drop_reasons', 'cross_sell_opportunities', 'agent_product_certification',
    'customer_renewal_tracker', 'agent_earnings', 'broker_scorecard_monthly',
    'agent_health_score', 'alerts_and_nudges', 'platform_daily_snapshot'
  )
ORDER BY table_name;
*/
