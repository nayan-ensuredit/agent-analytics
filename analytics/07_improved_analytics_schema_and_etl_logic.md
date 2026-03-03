# Improved Analytics Schema + Nightly ETL Logic (Transaction DB → Analytics DB)

This document proposes an analytics-friendly, accurate, and storage-efficient schema for the Analytics DB, plus the nightly ETL logic to populate it from the Transaction DB.

It is designed to fix the core problem in the current project:
- Current analytics tables are mostly **aggregates** (daily/monthly) + a denormalized `sold_policies_data`.
- Aggregates **lose funnel granularity** and prevent accurate **SLA + root-cause** analytics.
- Filters/joins are fragile because identifiers are inconsistently typed (INT vs TEXT), and because broker/product naming is not normalized.

Assumptions / constraints:
- **Nightly batch sync** (not real-time).
- Postgres analytics warehouse (same engine you use in this repo).
- We want **idempotent loads**, good query performance, minimal PII exposure.

---

## 0) Design principles (non-negotiables)

### A) Preserve event-level truth, derive aggregates
Store event/entity grain facts (quotes, proposals, policies, status transitions, API calls). Compute daily/monthly summaries from them.

### B) Stable keys and consistent types
In analytics, every primary key and foreign key should be:
- consistent type (`BIGINT` for numeric ids, `UUID` for uuids)
- not “sometimes text, sometimes integer”

### C) Minimize PII in analytics
Analytics should not store raw phone/email unless absolutely required.
Use:
- `phone_hash` (SHA-256 / salted hash)  
- optional masked last-4 for debugging

### D) Incremental loads by watermarks
Nightly ETL should use one of:
- `updatedAt` / `updated_at` timestamps (preferred)
- `id` monotonic sequences (fallback)

### E) Late arriving updates
Treat Transaction DB as mutable: proposals/policies can be updated later.
Use upserts with “last_updated_at” to keep analytics accurate.

---

## 1) Recommended star/hybrid model (overview)

### Core dimensions (small, stable)
- `dim_agent` (from transaction `users`)
- `dim_sales_channel` (broker/channel mapping)
- `dim_product` (from transaction `product`)
- `dim_insurer` (from transaction `company`)
- `dim_geo_state` (normalized states

### Core facts (entity grain)
- `fact_quote` (1 row per quote)
- `fact_quote_plan` (1 row per quote-plan returned/selected)
- `fact_proposal` (1 row per proposal)
- `fact_policy` (1 row per issued policy)

### Operational/event facts (append-only)
- `fact_status_event` (status transitions across quote/proposal/policy)
- `fact_insurer_api_call` (API latency/error/outage detection)
- `fact_payment_event` (payment attempts, failures, retries; extracted from proposals)
- `fact_inspection` (breakin inspections; from `inspections`)
- Optional: `fact_lead` (from `leads` tables)

### Derived aggregates (replace current “hand-maintained” rollups)
These power fast dashboards but are **recomputed from facts** nightly:
- `agg_agent_daily_activity` (replaces/extends `daily_quote_counts` + `agent_daily_logins`)
- `agg_agent_monthly_funnel` (replaces `agent_wise_monthly_activity_summary`)
- `agg_channel_monthly_funnel` (replaces `channel_wise_monthly_activity_summary`)
- `agg_category_monthly_sold` (replaces `category_wise_monthly_sold_policies`)
- `agg_channel_monthly_sold` (replaces `channel_wise_monthly_sold_policies`)
- `agg_platform_daily_snapshot` (like `platform_daily_snapshot`)

---

## 2) Improved schemas (table-by-table) + ETL logic

Each section includes:
- **Schema**: columns + types + constraints
- **Source**: transaction table(s)
- **Load strategy**: how to populate nightly
- **Why fields exist**: what they unlock / prevent

---

## 2.1 Dimensions

### Table: `dim_agent`
**Purpose**: single, clean agent dimension for joins and segmentation.

**Schema (recommended)**
- `agent_id` BIGINT PRIMARY KEY  *(transaction users.id)*
- `agent_uuid` UUID NULL
- `full_name` TEXT NULL
- `alias` TEXT NULL
- `status` TEXT NULL
- `role_id` BIGINT NULL
- `insurance_role_id` BIGINT NULL
- `reports_to_user_id` BIGINT NULL
- `sales_channel_id` BIGINT NULL
- `sub_sales_channel_id` BIGINT NULL
- `custom_branch_id` BIGINT NULL
- `created_at` TIMESTAMPTZ NOT NULL
- `updated_at` TIMESTAMPTZ NOT NULL
- `deleted_at` TIMESTAMPTZ NULL
- `last_login_at` TIMESTAMPTZ NULL
- `phone_hash` TEXT NULL  *(hash of normalized phone; do not store raw)*
- `email_hash` TEXT NULL
- `consent_status` BOOLEAN NULL
- `consent_timestamp` TIMESTAMPTZ NULL
- `additional_fields` JSONB NULL  *(optional, keep only if used)*

**Indexes**
- `idx_dim_agent_sales_channel (sales_channel_id)`
- `idx_dim_agent_last_login (last_login_at)`
- `idx_dim_agent_created_month (date_trunc('month', created_at))`

**Source**
- Transaction: `users`

**Load strategy**
- Incremental by `users.updatedAt` (or `updatedat/updatedAt` variant).
- Upsert: `ON CONFLICT (agent_id) DO UPDATE ... WHERE excluded.updated_at >= dim_agent.updated_at`.

**Why each field helps**
- `sales_channel_id`, `sub_sales_channel_id`: broker/channel slicing for every dashboard.
- `last_login_at`: “gone dark” and engagement segmentation.
- `phone_hash/email_hash`: safe dedupe keys for renewal matching and customer-level analysis without leaking PII.

---

### Table: `dim_sales_channel`
**Purpose**: stable broker/channel dimension so we stop depending on free-text `source`/`broker_name`.

**Schema**
- `sales_channel_id` BIGINT PRIMARY KEY
- `broker_name` TEXT NULL
- `channel_type` TEXT NOT NULL DEFAULT 'UNKNOWN' CHECK (channel_type IN ('ICE','FRANCHISE','BROKER','UNKNOWN'))
- `created_at` TIMESTAMPTZ NULL
- `updated_at` TIMESTAMPTZ NULL

**Source**
- If a master table exists in transaction DB: use it.
- If not: derive from `users.salesChannelUserId` and observed broker labels (e.g. `sold_policies_data.source`) into a curated mapping table.

**Load strategy**
- Nightly rebuild or incremental merge. If derived, treat as slowly changing (manual overrides allowed).

**Why**
- Fixes “broker_name” mismatch issues and makes broker filters accurate and durable.

---

### Table: `dim_product`
**Schema**
- `product_id` BIGINT PRIMARY KEY  *(transaction product.id)*
- `internal_name` TEXT NULL
- `display_name` TEXT NULL
- `category` TEXT NULL
- `created_at` TIMESTAMPTZ NULL
- `updated_at` TIMESTAMPTZ NULL

**Source**: transaction `product`

**Why**
- Product normalization (4W/2W/Health etc.) for consistent reporting.

---

### Table: `dim_insurer`
**Schema**
- `insurer_id` BIGINT PRIMARY KEY *(transaction company.id)*
- `internal_name` TEXT NULL
- `display_name` TEXT NOT NULL
- `created_at` TIMESTAMPTZ NULL
- `updated_at` TIMESTAMPTZ NULL

**Source**: transaction `company`

**Why**
- Prevents insurer-name spelling drift and enables insurer reliability analytics.

---

### Table: `dim_geo_state`
**Schema**
- `state_code` TEXT PRIMARY KEY  *(normalized; e.g. MH, KA; or canonical full name)*
- `state_name` TEXT NOT NULL
- `country` TEXT NOT NULL DEFAULT 'IN'

**Source**
- Reference list + normalization rules.

**Why**
- Prevents fragmentation due to casing/typos in `policy_holder_state`.

---

## 2.2 Core funnel facts (entity grain)

### Table: `fact_quote`
**Purpose**: 1 row per quote. Foundation for cohort funnel analytics.

**Schema**
- `quote_id` UUID PRIMARY KEY  *(transaction quotes.uuid)*
- `quote_pk` BIGINT NULL  *(transaction quotes.id if exists)*
- `agent_id` BIGINT NULL  *(sourcedByUserId / createdBy mapping)*
- `sales_channel_id` BIGINT NULL  *(from agent dimension at quote time)*
- `product_id` BIGINT NULL
- `quote_status` TEXT NULL
- `created_at` TIMESTAMPTZ NOT NULL
- `updated_at` TIMESTAMPTZ NOT NULL
- `source_system` TEXT NOT NULL DEFAULT 'transaction_db'
- `filter_data` JSONB NULL  *(optional: keep for debugging/feature derivation)*
- `field_data` JSONB NULL
- `geo_state_code` TEXT NULL  *(derived from field_data if available, else null)*
- `is_breakin_journey` BOOLEAN NULL

**Indexes**
- `idx_fact_quote_created_at (created_at)`
- `idx_fact_quote_agent_created (agent_id, created_at desc)`
- `idx_fact_quote_status (quote_status)`
- `idx_fact_quote_product (product_id, created_at)`

**Source**
- Transaction: `quotes`

**Load strategy**
- Incremental by `quotes.updatedAt`.
- Upsert by `quote_id`.

**Why these fields**
- `created_at`: quote cohorts (week/month), leading indicators.
- `quote_status`: stuck/abandoned quote detection.
- `geo_state_code`: geo demand vs conversion.
- JSON fields are optional; keep only if needed for derived attributes to avoid bloat.

---

### Table: `fact_quote_plan`
**Purpose**: 1 row per insurer plan returned for a quote (and whether selected).

**Schema**
- `quote_plan_id` UUID PRIMARY KEY *(transaction quotePlans.uuid if exists; else synthesize stable uuid)*
- `quote_id` UUID NOT NULL REFERENCES `fact_quote`(quote_id)
- `insurer_id` BIGINT NOT NULL REFERENCES `dim_insurer`(insurer_id)
- `plan_id` BIGINT NULL  *(transaction plan.id)*
- `plan_status` TEXT NULL
- `premium_gross` NUMERIC(12,2) NULL
- `premium_net` NUMERIC(12,2) NULL
- `paying_amount` NUMERIC(12,2) NULL
- `rank_by_price` INTEGER NULL  *(derived within quote)*
- `is_selected` BOOLEAN NOT NULL DEFAULT FALSE
- `created_at` TIMESTAMPTZ NOT NULL
- `updated_at` TIMESTAMPTZ NOT NULL
- `plan_data` JSONB NULL  *(optional, consider storing only extracts)*

**Indexes**
- `idx_fqp_quote (quote_id)`
- `idx_fqp_insurer_created (insurer_id, created_at)`
- `idx_fqp_selected (is_selected) WHERE is_selected = true`

**Source**
- Transaction: `quotePlans` joined to `quotes`

**Load strategy**
- Incremental by `quotePlans.updatedAt`.
- Derive `rank_by_price` nightly per quote using window function.
- Derive `is_selected` if transaction captures a selected flag; else infer via linkage to `proposals.quotePlanId`.

**Why**
- Enables insurer competitiveness, plan coverage gaps, and quote-stage funnel.

---

### Table: `fact_proposal`
**Purpose**: 1 row per proposal attempt. Captures payment & issuance outcomes.

**Schema**
- `proposal_id` BIGINT PRIMARY KEY *(transaction proposals.id)*
- `proposal_uuid` UUID NULL
- `quote_plan_id` UUID NULL REFERENCES `fact_quote_plan`(quote_plan_id)
- `quote_id` UUID NULL REFERENCES `fact_quote`(quote_id)  *(populate via quote_plan join)*
- `agent_id` BIGINT NULL
- `sales_channel_id` BIGINT NULL
- `proposal_status` TEXT NULL
- `created_at` TIMESTAMPTZ NOT NULL
- `updated_at` TIMESTAMPTZ NOT NULL
- `sold_at` TIMESTAMPTZ NULL
- `policy_number` TEXT NULL
- `transaction_id` TEXT NULL
- `paying_amount` NUMERIC(12,2) NULL
- `payment_status` TEXT NULL  *(derived)*
- `payment_provider` TEXT NULL  *(derived)*
- `payment_error_code` TEXT NULL
- `payment_error_message` TEXT NULL
- `payment_attempts_count` INTEGER NOT NULL DEFAULT 0  *(derived from payment events)*
- `field_data` JSONB NULL  *(optional)*
- `payment_data` JSONB NULL  *(optional; prefer extracts into `fact_payment_event`)*

**Indexes**
- `idx_fp_created_at (created_at)`
- `idx_fp_status (proposal_status)`
- `idx_fp_agent_created (agent_id, created_at desc)`
- `idx_fp_quote (quote_id)`

**Source**
- Transaction: `proposals`, plus joins to `quotePlans`/`quotes` to bring quote_id and insurer/product.

**Load strategy**
- Incremental by `proposals.updatedAt`.
- Parse payment fields from `paymentData` / `paymentGatewayTransactionDetails` into typed columns.

**Why**
- Separates “proposal created” vs “payment failed” vs “issued” cleanly.
- Without this, current dashboards can’t diagnose drop-offs beyond monthly aggregates.

---

### Table: `fact_policy`
**Purpose**: 1 row per issued policy (canonical policy fact; replaces/cleans `sold_policies_data`).

**Schema**
- `policy_id` BIGINT PRIMARY KEY *(transaction externalPolicy.id if exists; else use proposals.id for issued records + surrogate)*
- `policy_number` TEXT NOT NULL
- `proposal_id` BIGINT NULL REFERENCES `fact_proposal`(proposal_id)
- `quote_id` UUID NULL REFERENCES `fact_quote`(quote_id)
- `agent_id` BIGINT NULL REFERENCES `dim_agent`(agent_id)
- `sales_channel_id` BIGINT NULL REFERENCES `dim_sales_channel`(sales_channel_id)
- `product_id` BIGINT NULL REFERENCES `dim_product`(product_id)
- `insurer_id` BIGINT NULL REFERENCES `dim_insurer`(insurer_id)
- `issued_at` TIMESTAMPTZ NOT NULL
- `policy_start_date` DATE NULL
- `policy_end_date` DATE NULL
- `business_type` TEXT NULL  *(New / Renewal / Roll Over)*
- `is_breakin_journey` BOOLEAN NULL
- `vehicle_registration_hash` TEXT NULL
- `vehicle_registration_masked` TEXT NULL
- `customer_phone_hash` TEXT NULL
- `geo_state_code` TEXT NULL REFERENCES `dim_geo_state`(state_code)
- `gross_premium` NUMERIC(12,2) NULL
- `net_premium` NUMERIC(12,2) NULL
- `created_at` TIMESTAMPTZ NOT NULL
- `updated_at` TIMESTAMPTZ NOT NULL

**Indexes**
- `idx_policy_issued_at (issued_at)`
- `idx_policy_expiry (policy_end_date)`
- `idx_policy_agent_issued (agent_id, issued_at desc)`
- `idx_policy_channel_issued (sales_channel_id, issued_at desc)`
- `idx_policy_insurer_issued (insurer_id, issued_at desc)`

**Source**
- Transaction: `externalPolicy` + `proposals` (policy_number + soldAt) and/or current analytics export `sold_policies_data` as interim.

**Load strategy**
- Incremental by `externalPolicy.updatedAt` and `proposals.updatedAt` (issued proposals).
- Upsert by `policy_number` (unique) or stable policy id.

**Why**
- Clean policy fact enables accurate revenue, renewals, and insurer/broker performance without PII.

---

## 2.3 Event/ops facts (append-only)

### Table: `fact_status_event`
**Purpose**: immutable history of status transitions (enables SLA, stuck-state alerts).

**Schema**
- `event_id` BIGINT PRIMARY KEY
- `entity_type` TEXT NOT NULL CHECK (entity_type IN ('quote','quote_plan','proposal','policy','inspection','ticket','lead'))
- `entity_id` TEXT NOT NULL
- `old_status` TEXT NULL
- `new_status` TEXT NULL
- `event_name` TEXT NULL
- `operation_status` TEXT NULL
- `occurred_at` TIMESTAMPTZ NOT NULL
- `actor_user_id` BIGINT NULL
- `agent_id` BIGINT NULL
- `sales_channel_id` BIGINT NULL
- `additional_info` JSONB NULL

**Source**
- Transaction: `activity_log` (best), plus ticket history tables.

**Load strategy**
- Append-only incremental by `activity_log.id` or `created_on`.
- Never update rows; only insert.

**Why**
- Without this table you cannot measure “time in status” or detect “stuck” entities before escalation.

---

### Table: `fact_insurer_api_call`
**Purpose**: insurer/platform reliability & latency; leading indicators for escalations.

**Schema**
- `call_id` BIGINT PRIMARY KEY
- `occurred_at` TIMESTAMPTZ NOT NULL
- `insurer_id` BIGINT NULL REFERENCES `dim_insurer`(insurer_id)
- `product_id` BIGINT NULL REFERENCES `dim_product`(product_id)
- `api_name` TEXT NOT NULL
- `request_type` TEXT NULL
- `http_status` INTEGER NULL
- `success` BOOLEAN NOT NULL
- `latency_ms` INTEGER NULL
- `error_code` TEXT NULL
- `error_message` TEXT NULL
- `context_id` TEXT NULL  *(correlation key from `network_calls_log.contextId`)*
- `quote_id` UUID NULL
- `proposal_id` BIGINT NULL
- `env` TEXT NULL

**Source**
- Transaction: `insurerApiCallLogs` + `network_calls_log` + `apiLogger`

**Load strategy**
- Incremental by `createdAt`.
- Normalize `api_name` from URL + requestType.
- Deduplicate by `(context_id, api_name, occurred_at)` if upstream logs can duplicate.

**Why**
- Enables anomaly detection: insurer share drops, latency spikes, error storms.

---

### Table: `fact_payment_event`
**Purpose**: payment attempts/failures/retries at proposal level.

**Schema**
- `payment_event_id` BIGSERIAL PRIMARY KEY
- `proposal_id` BIGINT NOT NULL REFERENCES `fact_proposal`(proposal_id)
- `occurred_at` TIMESTAMPTZ NOT NULL
- `payment_provider` TEXT NULL
- `payment_status` TEXT NOT NULL  *(initiated/success/failure/timeout/refund)*
- `amount` NUMERIC(12,2) NULL
- `error_code` TEXT NULL
- `error_message` TEXT NULL
- `transaction_reference` TEXT NULL
- `raw_payment_json` JSONB NULL

**Source**
- Transaction: parse from `proposals.paymentGatewayTransactionDetails` / `paymentData`
- If there is a payment table/log: use that instead (prefer first-class payment logs).

**Load strategy**
- Re-extract from proposals nightly (since nested JSON can change).
- Use deterministic hash of (proposal_id + occurred_at + status + ref) to avoid duplicates.

**Why**
- Without payment events you cannot separate “proposal drop” from “payment failure”.

---

### Table: `fact_inspection`
**Purpose**: breakin inspection SLA and backlog.

**Schema**
- `inspection_id` BIGINT PRIMARY KEY
- `proposal_id` BIGINT NOT NULL
- `status` TEXT NOT NULL
- `created_at` TIMESTAMPTZ NOT NULL
- `updated_at` TIMESTAMPTZ NOT NULL
- `expiry_at` TIMESTAMPTZ NULL
- `insurer_id` BIGINT NULL
- `insurer_specific_data` JSONB NULL

**Source**
- Transaction: `inspections`

**Load strategy**
- Incremental by `updatedAt`.

**Why**
- Enables inspection aging buckets + SLA breach alerts.

---

## 2.4 Derived aggregates (computed from facts nightly)

These are “analytics-friendly” tables that serve dashboards fast. They should be **rebuildable** from the facts so they stay accurate.

### Table: `agg_agent_daily_activity` (replaces `daily_quote_counts` + `agent_daily_logins`)
**Schema**
- `activity_date` DATE NOT NULL
- `agent_id` BIGINT NOT NULL
- `sales_channel_id` BIGINT NULL
- `login_count` INTEGER NOT NULL DEFAULT 0
- `quote_count` INTEGER NOT NULL DEFAULT 0
- `proposal_count` INTEGER NOT NULL DEFAULT 0
- `policy_count` INTEGER NOT NULL DEFAULT 0
- `premium` NUMERIC(14,2) NOT NULL DEFAULT 0
- PRIMARY KEY (`activity_date`, `agent_id`)

**Source**
- `agent_daily_logins` (if still populated) OR derive from transaction authentication logs.
- `fact_quote` (quotes/day)
- `fact_proposal` (proposals/day)
- `fact_policy` (policies/day + premium)

**Why**
- One daily table enables consistent “today vs avg” and alerting without mixing incompatible grains.

---

### Table: `agg_agent_monthly_funnel` (replaces `agent_wise_monthly_activity_summary`)
**Schema**
- `activity_month` DATE NOT NULL  *(first day of month)*
- `agent_id` BIGINT NOT NULL
- `sales_channel_id` BIGINT NULL
- `product_id` BIGINT NULL
- `quotes` INTEGER NOT NULL DEFAULT 0
- `proposals` INTEGER NOT NULL DEFAULT 0
- `policies` INTEGER NOT NULL DEFAULT 0
- `premium` NUMERIC(14,2) NOT NULL DEFAULT 0
- PRIMARY KEY (`activity_month`, `agent_id`, `product_id`)

**Source**
- `fact_quote`, `fact_proposal`, `fact_policy` aggregated to month.

**Why**
- Keeps funnel aggregates but ties them back to entity facts for drill-down.

---

### Table: `agg_channel_monthly_funnel` (replaces `channel_wise_monthly_activity_summary`)
Similar to agent monthly funnel but grouped by `sales_channel_id`.

---

### Table: `agg_category_monthly_sold` / `agg_channel_monthly_sold`
These replace `category_wise_monthly_sold_policies` and `channel_wise_monthly_sold_policies`, derived from `fact_policy`.

---

## 3) ETL execution plan (nightly job)

### 3.1 Recommended staging pattern
For each source table:
1) Extract incrementals into `stg_*` tables (raw-ish, minimal transforms)
2) Merge into `dim_*` and `fact_*`
3) Recompute aggregates (`agg_*`)

### 3.2 Watermarks (examples)
Store ETL progress in `etl_watermarks`:
- `source_name` TEXT PRIMARY KEY
- `last_updated_at` TIMESTAMPTZ
- `last_id` BIGINT

Example watermark usage:
- `quotes`: `WHERE updatedAt > watermark.last_updated_at - interval '2 days'` (2-day overlap for safety)
- `activity_log`: `WHERE id > watermark.last_id`

### 3.3 Idempotency
- Facts/dims: UPSERT by natural keys (`quote_id`, `proposal_id`, `policy_number`)
- Events: append-only, dedupe by unique constraint if needed

---

## 4) Mapping from current analytics tables to improved model

Current tables:
- `sold_policies_data` → should become `fact_policy` + (optional) `dim_vehicle` + hashed customer identifiers
- `daily_quote_counts` → derive from `fact_quote` into `agg_agent_daily_activity`
- `agent_daily_logins` → keep only if sourced reliably; otherwise derive from auth logs into `agg_agent_daily_activity`
- `agent_wise_monthly_activity_summary` → derive from facts into `agg_agent_monthly_funnel`
- `channel_wise_monthly_activity_summary` → derive from facts into `agg_channel_monthly_funnel`
- monthly sold policy tables → derive from `fact_policy`

---

## 5) Why this is “accurate and optimal”

Accuracy improvements:
- Eliminates mixed-grain KPI math (policy rows vs monthly proposal totals).
- Preserves immutable status transitions and API telemetry to explain *why* funnel leaks.
- Uses stable ids + normalized dimensions so filters always match.

Storage/performance improvements:
- Keeps heavy JSON payloads optional (store typed extracts + raw JSON only where needed).
- Aggregates become rebuildable (no silent drift).
- Indexing aligns with dashboard query patterns (date + agent/channel/product/insurer slices).

---

## 6) What this unlocks (concretely)

With `fact_quote` + `fact_quote_plan` + `fact_proposal` + `fact_policy` + `fact_status_event`:
- True cohort funnel: quote cohort → proposal → payment → issued policy
- Stage SLAs: median/P90 time between statuses; stuck-state alerting
- Insurer performance: price competitiveness + API reliability + conversion contribution
- Payment failure diagnosis: provider/error_code trends and retry success
- Inspection/ticket operations: backlog aging, SLA breaches, root causes

