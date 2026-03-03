# Project Data Flow & Dashboard Coverage (What Powers What, and What’s Missing)

This repo contains:
- A **React dashboard UI** (`client/`)
- A **Node/Express API** (`server/`, exposed as a Vercel serverless function via `api/index.js`)
- A set of **SQL files** under `analytics/` describing an **analytics schema** and dashboard queries

What it **does not** contain:
- The **nightly ETL/export job** that copies data from the Transaction DB into the Analytics DB.  
  The project assumes “Analytics DB tables exist and are refreshed nightly”, but that exporter is outside this repo.

---

## 1) High-level architecture (runtime)

### Data lineage (conceptual)

**Transaction DB (source of truth)**  
→ (nightly export job, external to this repo)  
→ **Analytics DB (Postgres)**  
→ **Express API** (`server/index.js` + `server/db.js`)  
→ **React dashboard** (`client/`)

### Deployment wiring (Vercel)
- `vercel.json` rewrites:
  - `/api/(.*)` → `/api` (serverless function)
  - all other routes → `client` SPA (`index.html`)
- `api/index.js` is the Vercel entrypoint that exports the Express app from `server/index.js`.

---

## 2) How the dashboard works (client side)

### Filters → API query params
- Global filter state lives in `client/src/contexts/FilterContext.tsx`.
- Filter UI is `client/src/components/FilterBar.tsx`.
  - It fetches:
    - **States** from `GET /api/geographic/states?date_range=all_time`
    - **Brokers** from `GET /api/brokers/performance?date_range=all_time`
  - It sets filters: `date_range`, `broker`, `product`, `state`.

### All pages fetch data the same way
- Pages use `useFilteredApi()` (`client/src/api.ts`) which:
  - reads current filters from `FilterContext`
  - constructs URL like: `/api/…?date_range=…&broker=…&product=…&state=…`
  - calls `fetch()` and returns `{data, loading, error}` to the page

Key implication:
- The UI does **not** talk to the Transaction DB.
- The UI does **not** run SQL directly.
- The UI only uses the API endpoints defined in `server/index.js`.

---

## 3) How the API works (server side)

### DB access
- `server/db.js` creates a Postgres connection pool (host/db/user/password via env vars, with a local `~/.pgpass` fallback).
- Every endpoint calls `query(sql, params)` which runs against the **Analytics DB**.

### Filter handling
- The API parses query params (`date_range`, `broker`, `product`, `state`).
- It translates `date_range` to either:
  - an **interval** (for date columns like `sold_date`, `quote_date`, `login_date`)
  - or a **YYYY-MM cutoff** (for monthly strings like `sold_month`, `activity_month`)

### Caching
- Each endpoint is wrapped in `cachedHandler(...)` with a TTL.
- Cache keys include the filters, so results are cached **per filter combination**.

Key implication:
- Even though the UI auto-refreshes, the API may serve **cached** data for up to the endpoint’s TTL.

---

## 4) Which dashboards pull which Analytics DB tables

Below is the **source-of-truth mapping** from the codebase (UI endpoints) to the underlying analytics tables.

### Executive Summary (`/`)
Endpoints:
- `GET /api/executive/kpis`
- `GET /api/executive/growth`
- `GET /api/executive/concentration`

Analytics tables used:
- `sold_policies_data` (MTD policies/premium/agents, growth trend)
- `daily_quote_counts` (quotes for conversion calculation)
- `agent_wise_monthly_activity_summary` (proposal counts used in KPIs; month-based)
- `channel_wise_monthly_sold_policies` (broker concentration)
- `users` (top agent names in concentration endpoint)

What’s missing (limits the dashboard):
- **True quote→proposal→payment→issued funnel**: KPIs approximate funnel using mixed grains:
  - policies from `sold_policies_data` (date-grain)
  - quotes from `daily_quote_counts` (date-grain)
  - proposals from `agent_wise_monthly_activity_summary` (month-grain, aggregated)
- **No stage timestamps**: cannot compute time-to-issue or identify where delays happen.
- **No insurer/API context**: cannot explain conversion drops (pricing vs API outage vs payment).

---

### Agent Analytics (`/agents`)
Endpoints:
- `GET /api/agents/segmentation`
- `GET /api/agents/activation`
- `GET /api/agents/performance-distribution`

Analytics tables used:
- `users` (agent base + join month + active agents)
- `sold_policies_data` (sales/premium per agent)
- `daily_quote_counts` (quotes per agent for segmentation)

What’s missing:
- **Agent journey milestones** (profile completion, certification, first proposal, etc.) are not present; only inferred from logins/quotes/sales.
- **Quality metrics** (cancellation/endorsement/claims/complaints) not present → “health” is mostly activity/sales.

---

### Sales Funnel (`/funnel`)
Endpoints:
- `GET /api/funnel/conversion`
- `GET /api/funnel/by-product`
- `GET /api/funnel/stuck-quoters`

Analytics tables used:
- `agent_wise_monthly_activity_summary` (quotes/proposals/policies by month and product category)
- `users` (agent name/phone for stuck-quoters table)

What’s missing (biggest gap in the whole system):
- **Quote-level facts**: there is no `quotes`/`quotePlans`/`proposals` entity table in analytics, so you cannot:
  - compute cohort funnels (quote cohort → conversion over time)
  - do insurer-level conversion at quote stage
  - find drop-off reasons and retries
  - measure time between stages (proposal start/completion/payment/issuance)
- The funnel shown today is **a monthly aggregate**, not a true event funnel.

Related: `analytics/01_new_tables_schema.sql` proposes `quote_details` + `quote_drop_reasons`, but those tables are not referenced by the API/UI yet.

---

### Products (`/products`)
Endpoints:
- `GET /api/products/mix`
- `GET /api/products/trend`
- `GET /api/products/business-type`

Analytics tables used:
- `sold_policies_data` (mix + business type)
- `category_wise_monthly_sold_policies` (trend)

What’s missing:
- **Product funnel** (quotes/plans/proposals) at product level. Today product dashboards are “policy-issued only”.
- **Insurer competitiveness** per product at quote stage (needs quote plan facts).

---

### Brokers (`/brokers`)
Endpoints:
- `GET /api/brokers/performance`
- `GET /api/brokers/dormant`
- `GET /api/brokers/trend`

Analytics tables used:
- `channel_wise_monthly_sold_policies` (policy/premium by broker-month)
- `channel_wise_monthly_activity_summary` (quote totals by broker-month)

What’s missing:
- **Broker funnel root cause**: “quotes but no policies” is detectable, but you can’t tell if the leak is:
  - pricing (bad insurer quotes)
  - proposal UX
  - payment failures
  - inspection backlog
  - insurer API outages
- **Broker agent portfolio health** beyond totals (needs agent-level and event-level join).

---

### Geographic (`/geographic`)
Endpoints:
- `GET /api/geographic/states`
- `GET /api/geographic/state-product`

Analytics tables used:
- `sold_policies_data` (state performance; state×product)

What’s missing:
- **Geography at quote stage** (demand vs conversion) because quotes aren’t stored with geo attributes.

---

### Insurers (`/insurers`)
Endpoints:
- `GET /api/insurers/share`
- `GET /api/insurers/trend`

Analytics tables used:
- `sold_policies_data` (share + trend)

What’s missing:
- **Insurer reliability / SLA** (latency, error rate, outages) and its link to conversion.
- **Insurer quote competitiveness** (plans returned, lowest premium ranking, etc.).

---

### Renewals (`/renewals`)
Endpoints:
- `GET /api/renewals/upcoming`
- `GET /api/renewals/at-risk`

Analytics tables used:
- `sold_policies_data` (policy_expiry_date pipeline + at-risk)

Important limitation:
- The “at-risk” logic matches renewals using `(vehicle_make_model, policy_holder_phone)` and checks whether a “renewal/rollover” policy exists recently. This is a **heuristic** and can produce false positives/negatives.

What’s missing:
- **Explicit renewal journey** (outreach events, renewal quote created, renewal sold) → cannot run a proper renewal funnel.
- **Stable identifiers** for matching: `vehicle_registration` exists in the table but is not used in the API’s renewal matching logic.

---

### Alerts (`/alerts`)
Endpoints:
- `GET /api/alerts/summary`
- `GET /api/alerts/declining-agents`
- `GET /api/alerts/stuck-quoters`
- `GET /api/alerts/inactive-agents`

Analytics tables used:
- `daily_quote_counts` (decline detection)
- `agent_wise_monthly_activity_summary` (stuck quoters)
- `agent_daily_logins` (inactive agents)
- `sold_policies_data` (lifetime premium context; expiring renewals count)
- `users` (names/phones)

What’s missing:
- Alerts can identify “symptoms” (decline, stuck, inactive), but not “causes”:
  - no stage-level timestamps
  - no payment failure detail
  - no insurer API error context
  - no ticket/inspection backlog

Note (code contract mismatch):
- `client/src/components/Layout.tsx` expects `total_alerts` from `/api/alerts/summary`, but the API returns separate counts (`declining_agents_count`, `stuck_quoters_count`, etc.). This is an app wiring issue, not an analytics DB gap.

---

### Operations (`/operations`)
Endpoints:
- `GET /api/operations/today`
- `GET /api/operations/week-comparison`
- `GET /api/operations/leaderboard`

Analytics tables used:
- `sold_policies_data` (policies/premium + leaderboard)
- `daily_quote_counts` (quotes today/weekly)
- `users` (agent names in leaderboard)

What’s missing:
- “Operations” is effectively **sales ops**, not **process ops**. There is no operational workflow telemetry (inspection/payment/KYC/tickets) backing this page.

---

### Advanced (`/advanced`)
Endpoints:
- `GET /api/advanced/revenue-at-risk`
- `GET /api/advanced/weekly-pulse`

Analytics tables used:
- `sold_policies_data`
- `channel_wise_monthly_sold_policies`
- `daily_quote_counts`

What’s missing:
- This is a good “risk summary”, but it still cannot attribute *why* risk is rising (needs event/telemetry facts).

---

## 5) Where we “don’t have the data” for the dashboards we built

The current dashboards are **built and working** only because they rely on:
- issued-policy data (`sold_policies_data`)
- daily quote counts (`daily_quote_counts`)
- daily logins (`agent_daily_logins`)
- monthly aggregates (`agent_wise_monthly_activity_summary`, `channel_wise_monthly_*`)

But the dashboards **cannot become truly actionable** (root-cause + proactive prevention) without these missing datasets in the analytics DB:

### Missing dataset A — Quote/plan/proposal entity facts
Needed to turn “monthly funnel” into a real funnel:
- A `quotes`-grain table (1 row per quote)
- A `quote_plans`-grain table (1 row per insurer plan per quote)
- A `proposals`-grain table (1 row per proposal, with payment and issuance fields)

Without this, we cannot:
- compute cohort funnels (quote cohort, not calendar month)
- do insurer competitiveness at quote stage
- isolate payment failures vs proposal drop-offs vs issuance delays

### Missing dataset B — Status transition events (append-only)
Needed for:
- stuck-state alerts (“proposal pending > 6 hours”)
- SLA percentiles (median/P90/P95 time between states)

### Missing dataset C — Insurer API call logs unified for analytics
Needed for:
- early outage/latency anomaly detection
- tying conversion drops to insurer/platform issues

### Missing dataset D — Operational workflow facts
Needed for escalation prevention:
- inspections (breakin)
- policy tickets + ticket history
- KYC/CKYC milestones (if part of your flow)

See: `analytics/04_schema_gap_analysis_and_plan.md` for the concrete tables recommended to fill these gaps.

---

## 6) Practical “how it works today” summary

1) Analytics DB is assumed to be refreshed nightly from the Transaction DB (export code is not in this repo).  
2) The dashboard UI calls `/api/...` endpoints with filters.  
3) Vercel routes `/api/...` to the Express serverless function.  
4) Express runs SQL against the Analytics DB and returns aggregated results.  
5) The UI renders charts/tables from those aggregates.

The system is strong at:
- policy-issued trends, concentration risk, high-level broker/agent performance

The system is weak at (today):
- diagnosing **where and why** the funnel is leaking
- proactive detection of operational issues **before escalation**

