# Analytics DB Schema Gap Analysis & Recommendations (Nightly Sync)

Context recap:
- **Transaction DB** is source of truth (high-granularity, operational + event-ish logs).
- **Analytics DB** is nightly-export target and dashboard DB (needs analytics-friendly facts/dims).
- Current analytics visibility is **lagging** and largely **aggregate-only**, so issues are detected **after escalation**.

This document covers:
1) Full schema understanding (transaction vs analytics)  
2) Gap analysis (funnel, SLA/time delay, ops pain points, business insights)  
3) Concrete schema changes (tables/columns/types/sources/why/dashboards)  
4) Dashboard & metric expansion  
5) Trend & cohort improvements  
6) Escalation-prevention signals (what data must exist)  
7) Prioritized roadmap (P0/P1/P2)

---

## 1) Full Schema Understanding

### Transaction DB: core business entities & lifecycle

**Identity / org structure**
- `users`: user/agent records, broker/channel assignment (`salesChannelUserId`, `subSalesChannelUserId`), last activity (`lastLogin`), status, role.
- `role`, `insuranceRole`, access-control tables: not primary for business analytics except segmentation.

**Acquisition / lead**
- `lead`, `leads`, `leads_20`: inbound lead lifecycle, assignment, pickedBy, status/workflowStage, tags, notes.

**Quote → proposal → policy**
- `quotes`: the quote “container” with `status`, `createdAt`, `updatedAt`, `productId`, `filterData`, `fieldData` (JSON).
- `quotePlans`: quote plan options (per quote) with `planData`, `amountDetail`, `payingAmount`, `status`, timestamps.
- `proposals`: created from `quotePlanId`, with `status`, `fieldData`, `paymentData`, `soldAt`, `policyNumber`, `transactionId`, `paymentGatewayTransactionDetails`.
- `externalPolicy`: policy records (vehicle/proposer/nominee details), `policyStartDate`, `policyEndDate`, `policyNumber`, timestamps.

**Operational workflow / exceptions**
- `inspections`: breakin inspection workflow (`status`, `expiryDate`, `insurerSpecificData`, `proposalId`).
- `policyTickets`, `policyTicketHistory`: operational tickets with status transitions + remarks/attachments.

**Time-sensitive logs / telemetry**
- `insurerApiCallLogs`, `apiLogger`, `network_calls_log`: request/response payloads + latency fields (some), status, env, contextId/correlation.
- `activity_log`: user operations with `data_prev_state`, `data_new_state`, `event_name`, `operation_status`, completion time, `created_on`.

**What the state machine really looks like**
- **Quote** (`quotes.status`) → one or many **Quote Plans** (`quotePlans.status`) → **Proposal** (`proposals.status`) → **Policy Issued** (`proposals.policyNumber` / `externalPolicy.policyNumber`)  
Plus side-flows: payment failures, breakin inspection, KYC/CKYC, ticketing.

**Key time fields**
- Almost everything has `createdAt`/`updatedAt` (or variants) and several “event timestamps” embedded in JSONs (`paymentGatewayTransactionDetails`, `ckycDetails`, etc.).
- `activity_log.created_on` is the closest thing to **append-only event history** (critical for analytics).

---

### Analytics DB: what exists today (and what it implies)

Current analytics schema you provided is dominated by:

**(A) Engagement aggregates**
- `agent_daily_logins`: per agent per day counts + `last_login`
- `daily_quote_counts`: per agent per day quote counts

**(B) Monthly funnel aggregates (already flattened)**
- `agent_wise_monthly_activity_summary`: per agent per month totals by product_type for **quotes/proposals/policies** and premiums
- `channel_wise_monthly_activity_summary`: same per broker/channel

**(C) Sold policy facts (semi-detailed, but disconnected)**
- `sold_policies_data`: policy-holder PII + product, insurer, premium, sold_date, expiry/start dates, agent/channel identifiers, proposal_id sometimes

**(D) Monthly sold policy aggregates**
- `category_wise_monthly_sold_policies`
- `channel_wise_monthly_sold_policies`

**What this enables today**
- Platform sales volume/premium trends, product mix, broker concentration, basic agent activation (login/quote/sale at coarse level), renewal pipeline via expiry dates, breakin share (if populated).

**What it cannot enable today**
- Quote-level and proposal-level **conversion diagnostics** (why and where drop-offs happen).
- SLA tracking (inspection time, payment latency, policy issuance latency).
- Insurer API reliability, latency, and error-driven conversion impact.
- Cohort funnels based on **entity creation time** (quote cohort, proposal cohort), not calendar months.
- Event-based escalations (“stuck in status for X hours/days”) because intermediate statuses aren’t preserved.

---

### Transaction vs analytics: missing entities, relationships, and granularity loss

**Missing entities in analytics (high impact)**
- `quotes`, `quotePlans`, `proposals`, `externalPolicy` (or at least a slim mirror of them)
- `inspections`
- `policyTickets` + `policyTicketHistory`
- `activity_log` (or a derived “status transition events” table)
- `insurerApiCallLogs` / `network_calls_log` / `apiLogger` (for SLA + outage detection)
- `leads` (for top-of-funnel acquisition and conversion to quote)

**Missing relationships**
- `quote_id` ↔ `quotePlanId` ↔ `proposalId` ↔ `policyNumber/policyId`
- Agent ↔ broker/channel mapping as a clean dimension (today it’s embedded/duplicated with inconsistent types)
- Insurer/product/channel dimensions used consistently across facts

**Loss of granularity**
- Daily quote counts and monthly summaries destroy:
  - per-quote insurer comparisons
  - time-to-next-step distributions (median/P90/P95)
  - abandonment reasons, retries, and step-level failure modes

---

## 2) Analytics Schema Gap Analysis (categorized)

### Funnel analysis gaps
- No quote/proposal **entity tables** → cannot compute:
  - quote-to-plan selection rate
  - plan selection-to-proposal completion rate
  - proposal completion-to-payment success rate
  - payment success-to-policy issuance rate
  - abandonment stage + reason distribution
- Aggregates only allow a blurred funnel (monthly totals) and hide conversion mechanics.

### Time-delay & SLA tracking gaps
- No event timestamps for:
  - quote generated → proposal started/completed
  - proposal completed → payment initiated/succeeded
  - payment success → policy issued
  - breakin: inspection requested → scheduled → completed → approved
- No API latency/availability facts per insurer/product → cannot detect regressions before escalations.

### Operational pain-point gaps
- Ticketing lifecycle absent → no “open tickets aging”, “SLA breaches”, “reopen rates”, “root cause categories”.
- No operational workflow facts (inspection, KYC) → “stuck” states can’t be measured.

### Business & revenue insight gaps
- No commission/earnings facts → weak agent motivation analytics + unit economics.
- No lead-to-quote attribution → cannot measure channel CAC proxy, lead quality, or sales pipeline health.
- Renewal is inferred via expiry/vehicle matching heuristics; no explicit renewal workflow/outreach instrumentation.

---

## 3) Concrete Schema Change Recommendations (opinionated)

Design principles (nightly sync-friendly):
- Prefer **fact/dimension** (hybrid) with a small number of well-typed core facts.
- Preserve **event history** via append-only event tables (export logs).
- Avoid duplicating full JSON payloads unless needed; store **typed extracts** + a `raw_json` column only when critical.
- Protect PII: store hashed phone/email; keep raw PII in a restricted schema if absolutely necessary.

### P0: add “core funnel facts” (minimum viable event-grain)

#### Table: `fact_quotes`
- **Purpose**: one row per quote (cohort and funnel foundation).
- **Source**: `quotes` (transaction DB)
- **Columns**
  - `quote_id` UUID (PK) — source `quotes.uuid`
  - `quote_created_at` TIMESTAMPTZ — `quotes.createdAt`
  - `quote_updated_at` TIMESTAMPTZ — `quotes.updatedAt`
  - `quote_status` TEXT — `quotes.status`
  - `agent_id` BIGINT — `quotes.sourcedByUserId` (or mapped user)
  - `sales_channel_id` BIGINT — via agent→users mapping
  - `product_id` INT — `quotes.productId`
  - `source` TEXT — derived (ICE/F-code/etc.) if available
  - `geo_state` TEXT — derived from quote fieldData or user/customer if present
  - `is_breakin_journey` BOOLEAN — derived from quote fieldData (if present)
- **Unlocks**
  - Quote cohorts (by created month/week), quote volume health, early anomaly detection.

#### Table: `fact_quote_plans`
- **Purpose**: one row per plan shown/selected per quote.
- **Source**: `quotePlans`
- **Columns**
  - `quote_plan_id` TEXT/UUID (PK) — `quotePlans.uuid` (or `id` if numeric)
  - `quote_id` UUID (FK → `fact_quotes.quote_id`) — `quotePlans.quoteId`
  - `insurer_id` INT — from `quotePlans.companyId`
  - `plan_id` INT — `quotePlans.planId`
  - `premium_amount` NUMERIC(12,2) — from `amountDetail` / `payingAmount`
  - `plan_status` TEXT — `quotePlans.status`
  - `created_at` TIMESTAMPTZ — `quotePlans.createdAt`
  - `updated_at` TIMESTAMPTZ — `quotePlans.updatedAt`
- **Unlocks**
  - Price competitiveness (rank/percentile), insurer availability (plans returned vs missing), plan selection.

#### Table: `fact_proposals`
- **Purpose**: one row per proposal instance (captures payment/policy issuance fields).
- **Source**: `proposals`
- **Columns**
  - `proposal_id` BIGINT (PK) — `proposals.id`
  - `quote_plan_id` TEXT/UUID — `proposals.quotePlanId`
  - `proposal_status` TEXT — `proposals.status`
  - `created_at` TIMESTAMPTZ — `proposals.createdAt`
  - `updated_at` TIMESTAMPTZ — `proposals.updatedAt`
  - `sold_at` TIMESTAMPTZ — `proposals.soldAt`
  - `policy_number` TEXT — `proposals.policyNumber`
  - `transaction_id` TEXT — `proposals.transactionId`
  - `paying_amount` NUMERIC(12,2) — `proposals.payingAmount`
  - `payment_status` TEXT — derived from `paymentGatewayTransactionDetails`/`paymentData`
  - `payment_provider` TEXT — derived
  - `payment_error_code` TEXT — derived
- **Unlocks**
  - Proposal abandonment, payment failure monitoring, issuance delays.

#### Table: `fact_policies`
- **Purpose**: unified issued-policy fact (cleaner than current `sold_policies_data`).
- **Source**: prefer `externalPolicy` + `proposals` issued fields; can also backfill from `sold_policies_data`.
- **Columns**
  - `policy_id` BIGINT or UUID (PK)
  - `policy_number` TEXT
  - `proposal_id` BIGINT (FK)
  - `policy_issued_at` TIMESTAMPTZ (or DATE) — from `proposals.soldAt` / `externalPolicy.createdAt`
  - `policy_start_date` DATE
  - `policy_end_date` DATE
  - `product_id` INT
  - `insurer_id` INT
  - `agent_id` BIGINT
  - `sales_channel_id` BIGINT
  - `gross_premium` NUMERIC(12,2)
  - `net_premium` NUMERIC(12,2)
  - `business_type` TEXT (New/Renewal/RollOver)
  - `is_breakin_journey` BOOLEAN
  - `geo_state` TEXT
- **Unlocks**
  - Clean revenue analytics, cohorting by issued time, renewal base.

---

### P0: add “status transition events” (to enable stuck-state and SLA)

#### Table: `fact_entity_status_events`
- **Purpose**: append-only event history (status transitions) for quote/plan/proposal/policy/tickets.
- **Source**: `activity_log` (best), plus targeted extracts from core tables when missing.
- **Columns**
  - `event_id` BIGINT (PK) — from `activity_log.id`
  - `entity_type` TEXT — derived (`quote`, `quote_plan`, `proposal`, `policy`, `ticket`, `inspection`)
  - `entity_id` TEXT — id/uuid
  - `event_name` TEXT — `activity_log.event_name`
  - `old_status` TEXT — parsed from `data_prev_state`
  - `new_status` TEXT — parsed from `data_new_state`
  - `operation_status` TEXT — success/fail
  - `occurred_at` TIMESTAMPTZ — `activity_log.created_on`
  - `user_id` BIGINT — actor if available
  - `sales_channel_id` BIGINT — derived via user mapping
  - `additional_info` JSONB — passthrough for debugging
- **Unlocks**
  - “stuck in status for X hours” alerts
  - SLA percentile dashboards by stage and by insurer/channel/product

---

### P0: add “insurer + platform operations facts” (early outage detection)

#### Table: `fact_insurer_api_calls`
- **Purpose**: insurer reliability, latency, error monitoring; link to funnel degradation.
- **Source**: `insurerApiCallLogs` + `network_calls_log` + `apiLogger` (unify via correlation keys if possible).
- **Columns**
  - `call_id` BIGINT (PK)
  - `occurred_at` TIMESTAMPTZ
  - `insurer_id` INT
  - `product_id` INT
  - `api_name` TEXT (requestType / reqUrl normalized)
  - `http_status` INT
  - `success` BOOLEAN
  - `latency_ms` INT
  - `error_code` TEXT
  - `error_message` TEXT (trimmed)
  - `context_id` TEXT (from `network_calls_log.contextId`)
  - `quote_id` UUID nullable (if linkable)
  - `proposal_id` BIGINT nullable (if linkable)
- **Unlocks**
  - Insurer anomaly dashboard, API regression → conversion impact, proactive escalations.

---

### P1: operational workflow facts

#### Table: `fact_inspections`
- **Source**: `inspections`
- **Columns**: `inspection_id`, `proposal_id`, `status`, `created_at`, `updated_at`, `expiry_date`, `insurer_id`, `sla_bucket`, `insurer_specific_status` (extract)
- **Unlocks**: breakin SLA, pending backlog, insurer-specific friction.

#### Table: `fact_policy_tickets` and `fact_policy_ticket_events`
- **Source**: `policyTickets`, `policyTicketHistory`
- **Unlocks**: escalation prevention, ops SLA, root cause categories, reopen rates.

---

### P1: dimensions (clean joins, no mixed types)

#### Table: `dim_agent`
- **Source**: `users`
- **Keep**: `agent_id`, `created_at`, `status`, `role_id`, `sales_channel_id`, `sub_sales_channel_id`, `branch_id`
- **Drop/Mask**: `password`, `salt`, raw `email`, raw `phone` (store hashes)

#### Table: `dim_sales_channel`
- **Source**: transaction tables (sales channel masters if present) or derived from `users.salesChannelUserId`
- **Columns**: `sales_channel_id`, `broker_name`, `channel_type` (ICE/FRANCHISE/OTHER)

#### Table: `dim_product`, `dim_insurer`, `dim_geo_state`
- **Source**: `product`, `company`, and normalized state list.

---

### P2: product growth & monetization expansion

#### Table: `fact_commissions` (agent earnings)
- **Source**: if commission exists in transaction DB; otherwise derived rules table + policy facts.
- **Unlocks**: agent motivation, retention, unit economics by channel.

#### Table: `fact_nudges` (alerts/outreach tracking)
- **Source**: notifications/CRM system or app events.
- **Unlocks**: intervention ROI, alert fatigue control.

---

## 4) Dashboard & Metric Expansion (leading indicators first)

### Quote → Policy funnel (cohort-based)
- Cohort = `quote_created_at` week/month (not calendar month of issuance).
- Metrics:
  - quote→plan rate, plan→proposal rate, proposal→payment success, payment→issued
  - median/P90 time between steps
  - abandonment stage + reason (when available)

### Delay reasons (API, KYC, inspection, payment)
- API latency/error heatmaps by insurer/product
- Inspection backlog + SLA breach rate
- Payment failure rate by provider/error_code + retry success rate

### Drop-offs & retries
- Quote-plan coverage gaps (insurers returning 0 plans)
- Proposal retries, payment retries, insurer API retry storms

### Partner / insurer performance comparison
- Insurer reliability score = weighted (availability + latency + conversion contribution)
- Broker health = active agents + conversion + concentration risk

---

## 5) Trend & Cohort Improvements

### Cohort dimensions (recommended)
- **Agent cohorts**: join month, onboarding channel, region, broker
- **Quote cohorts**: quote_created week, product, insurer mix, channel, state
- **Proposal cohorts**: proposal_created week, payment provider, breakin vs normal
- **Renewal cohorts**: expiry month, outreach timing bucket

### Snapshot vs event-based tables
- Event-based (must-have): `fact_entity_status_events`, `fact_insurer_api_calls`
- Snapshot (derived nightly): `platform_daily_snapshot`, `broker_scorecard_monthly`, `agent_engagement_score`

---

## 6) Escalation Prevention Signals (and required data)

Explicit answer: **What data should exist so issues are detected before escalation?**

You need, at minimum:
- **Status transition timestamps** (event log) for quote/plan/proposal/policy/tickets/inspections
- **API call latency + error** facts by insurer/product
- **Payment status + errors** extracted from proposal/payment logs

Early-warning signals you can compute nightly:
- **Stuck states**: count of entities stuck in a status > X hours (P95-based thresholds)
- **Insurer anomaly**: insurer volume share drop >40% vs 4-week average + latency spike
- **Payment failure spike**: gateway failure rate > baseline + error code concentration
- **Inspection backlog**: pending inspections aging > SLA
- **Ticket backlog**: open tickets aging + reopen rate spike
- **Funnel leak shift**: quote→proposal rate drop vs trailing 4 weeks; proposal→policy drop

---

## 7) Prioritized roadmap (P0 / P1 / P2)

### P0 (do this first — unlocks most dashboards + early warnings)
- Export/mirror to analytics DB nightly:
  - `quotes`, `quotePlans`, `proposals`, `externalPolicy` (slim columns)
  - `activity_log`
  - `insurerApiCallLogs` + `network_calls_log` + `apiLogger`
- Create:
  - `fact_quotes`, `fact_quote_plans`, `fact_proposals`, `fact_policies`
  - `fact_entity_status_events`
  - `fact_insurer_api_calls`

**Quick wins (low effort, high impact)**
- Export `activity_log` + API logs first: immediate outage + latency alerts even before full funnel modeling.
- Add consistent typing + keys (`agent_id` BIGINT everywhere; `sales_channel_id` BIGINT everywhere).
- Mask PII in analytics exports (hash phone/email).

### P1 (operational excellence + retention)
- Add `fact_inspections`, `fact_policy_tickets`, ticket event history
- Build renewal facts explicitly (beyond heuristics) if transaction DB supports it
- Materialize daily snapshots for executive + alert workloads

### P2 (growth + monetization + experimentation)
- Nudges/intervention tracking + effectiveness
- Commission/earnings facts
- UI instrumentation for quote viewed / abandonment reasons (true product analytics)

