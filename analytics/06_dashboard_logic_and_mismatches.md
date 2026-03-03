# Dashboard Logic & Potential Mismatches (Page-by-page)

Goal: For each dashboard page in `client/src/pages/`, document:
- which `/api/...` endpoints it calls
- the core SQL/tables powering those endpoints (from `server/index.js`)
- any likely mismatches / correctness risks

Legend:
- **Grain**: the “row level” of the data (policy row, daily agent, monthly broker, etc.)
- **Risk**: likely mismatch, silent correctness issue, or a code contract bug

---

## 1) Executive Summary (`/`)

### Data endpoints (client)
- `/api/executive/kpis`
- `/api/executive/growth`
- `/api/executive/concentration`

### Logic (server)
- **`/api/executive/kpis`**
  - **Policies/premium/agents/avg ticket**: from `sold_policies_data`
  - **Quotes**: from `daily_quote_counts`
  - **Proposals**: from `agent_wise_monthly_activity_summary` (sum of proposal_count_* columns)
  - Computes conversion as `policies / quotes`
  - Supports `date_range` either as:
    - “range vs previous equal range” (if date_range set), or
    - “current month vs previous month”
  - **Grain**: mixed (policy rows + daily quotes + monthly proposals)
- **`/api/executive/growth`**
  - Monthly time series: `TO_CHAR(sold_date,'YYYY-MM')` grouped from `sold_policies_data`
  - **Grain**: month
- **`/api/executive/concentration`**
  - Top broker share: from `channel_wise_monthly_sold_policies` (month-based)
  - Top agents share: from `sold_policies_data` (policy rows) + optional join to `users` for names
  - **Grain**: broker-month + policy rows

### Risks / mismatches to watch
- **Mixed grains in KPIs**: policies and quotes are date-grain, proposals are month-grain aggregates → conversion and proposal counts can be directionally useful but not “true funnel”.
- **Broker filter on `sold_policies_data` uses `broker_name`** (exact equality). In your provided analytics schema, the closest column is `source` (and `sales_channel_user_id`). If `broker_name` is not a real column/view, broker filtering will be wrong or error.
- **Product filter is `product_type = $1`** (exact match). If `sold_policies_data.product_type` values don’t exactly equal UI options (see FilterBar), filters will silently return 0.

---

## 2) Agent Analytics (`/agents`)

### Data endpoints (client)
- `/api/agents/segmentation`
- `/api/agents/activation`
- `/api/agents/performance-distribution`

### Logic (server)
- **`/api/agents/segmentation`**
  - Builds “segment” per agent using:
    - sales counts and premium from `sold_policies_data`
    - quote counts from `daily_quote_counts`
    - agent universe from `users` (roleid != null, deletedat is null)
  - Segments: Star/Rising/Occasional/Dormant/Dead based on sales_m0, sales_range, quotes_range.
  - **Grain**: segment aggregate row
- **`/api/agents/activation`**
  - Cohort by `users.createdat` join month, “ever_sold” by left joining to `sold_policies_data`
  - **Grain**: join_month
- **`/api/agents/performance-distribution`**
  - Buckets all agents by policy count in a date window (0, 1–2, 3–5, 6–10, 10+)
  - **Grain**: bucket

### Risks / mismatches to watch
- **Agent id type mismatch risk**: some parts of the code join `users.id` to `sold_policies_data.agent` as-is. If `agent` is stored as text in analytics exports, joins may fail unless casted consistently.
- **Segment definitions are heuristic**: “Dormant” is inferred from quotes/sales, not from real status transitions or onboarding milestones.

---

## 3) Sales Funnel (`/funnel`)

### Data endpoints (client)
- `/api/funnel/conversion`
- `/api/funnel/by-product`
- `/api/funnel/stuck-quoters`

### Logic (server)
- **`/api/funnel/conversion`**
  - Monthly totals from `agent_wise_monthly_activity_summary`
  - Sums all quote_count_* / proposal_count_* / policy_count_* columns
  - Computes:
    - quote_to_proposal_rate
    - proposal_to_policy_rate
    - overall_conversion_rate
  - **Grain**: month
- **`/api/funnel/by-product`**
  - Hard-coded “product groups” computed from *specific columns* in `agent_wise_monthly_activity_summary`
  - Returns rows like “Two Wheeler / Four Wheeler / Health / ...”
  - **Grain**: product-group aggregate
- **`/api/funnel/stuck-quoters`**
  - Finds agents with quotes > 0 but policies = 0 in a month window from `agent_wise_monthly_activity_summary`
  - Joins `users` to show `fullname`, `phone`
  - **Grain**: agent

### Risks / mismatches to watch
- **This is not a true event funnel**: it uses pre-aggregated monthly tables. You can’t compute:
  - quote cohort funnels
  - stage-level SLAs
  - drop-off reasons
- **Product filter mismatch**: UI product filter values come from `FilterBar.tsx` and are sent as `product=...`, but `/api/funnel/by-product` only supports filtering on the *labels it returns* (e.g. “Four Wheeler”, not “Private Car”). Filtering may not behave as the user expects.

---

## 4) Products (`/products`)

### Data endpoints (client)
- `/api/products/mix`
- `/api/products/trend`
- `/api/products/business-type`

### Logic (server)
- **`/api/products/mix`**
  - Aggregates `sold_policies_data` by `product_type` in a date window
  - Computes policy_count, total_premium, avg_ticket, share of premium
  - **Grain**: product_type
- **`/api/products/trend`**
  - Reads `category_wise_monthly_sold_policies` (already aggregated)
  - **Grain**: month × product_type
- **`/api/products/business-type`**
  - Reads `sold_policies_data` and groups by month + `policy_business_type`
  - **Grain**: month × business type

### Risks / mismatches to watch
- **Product filter exact match** again (`product_type = $1`). If `sold_policies_data.product_type` values are not aligned with UI options, the filter will zero out.
- **Trend vs Mix mismatch**: mix uses `sold_policies_data`; trend uses `category_wise_monthly_sold_policies`. If those two tables are not built from the same transformation rules (or have different category mappings), the numbers won’t reconcile perfectly.

---

## 5) Brokers (`/brokers`)

### Data endpoints (client)
- `/api/brokers/performance`
- `/api/brokers/dormant`
- `/api/brokers/trend`

### Logic (server)
- **`/api/brokers/performance`**
  - Policies/premium from `channel_wise_monthly_sold_policies`
  - Quotes from `channel_wise_monthly_activity_summary`
  - Computes conversion_rate as `policies / quotes`
  - **Grain**: broker (aggregated across months in window)
- **`/api/brokers/dormant`**
  - From `channel_wise_monthly_activity_summary`: brokers with quotes > 0 and policies = 0
  - **Grain**: broker
- **`/api/brokers/trend`**
  - From `channel_wise_monthly_sold_policies`: month trend for a broker or top 10 brokers
  - **Grain**: month × broker

### Risks / mismatches to watch
- **Broker definition depends on `broker_name`** existing and being stable in the monthly tables. If broker naming changes month-to-month, trend will split.
- **No drill-down** to agent/quote/proposal causes: “zero conversion broker” is detectable but not diagnosable.

---

## 6) Geographic (`/geographic`)

### Data endpoints (client)
- `/api/geographic/states`
- `/api/geographic/state-product`

### Logic (server)
- Both endpoints use `sold_policies_data` and aggregate by:
  - state, or
  - state × product_type
  - with optional “top states” limiting logic
  - **Grain**: aggregate

### Risks / mismatches to watch
- **State field quality**: depends on `policy_holder_state` being populated and normalized; otherwise “Unknown”/case issues fragment results.

---

## 7) Insurers (`/insurers`)

### Data endpoints (client)
- `/api/insurers/share`
- `/api/insurers/trend`

### Logic (server)
- Both endpoints are from `sold_policies_data`:
  - share: group by insurer
  - trend: top 8 insurers by premium, then month trend
  - **Grain**: insurer / month×insurer

### Risks / mismatches to watch
- **No insurer performance at quote stage**: this is “issued policies only”, so it can’t detect insurer API outages early.

---

## 8) Renewals (`/renewals`)

### Data endpoints (client)
- `/api/renewals/upcoming`
- `/api/renewals/at-risk`

### Logic (server)
- **Upcoming**: buckets `sold_policies_data.policy_expiry_date` into 0–30/31–60/61–90 days.
- **At-risk**:
  - Finds expired policies in last 90 days (`sold_policies_data e`)
  - Excludes “renewed” ones by matching `(vehicle_make_model, policy_holder_phone)` against recent renewal/rollover records
  - **Grain**: expiry_window aggregate

### Risks / mismatches to watch
- **Renewal matching heuristic**: matching renewals by `(vehicle_make_model, phone)` can be wrong.
  - False positives: same phone + similar vehicle text
  - False negatives: phone formatting changes, vehicle string changes
- You likely want to use `vehicle_registration` when available, or a stable policy/customer key.

---

## 9) Alerts (`/alerts`)

### Data endpoints (client)
- `/api/alerts/summary`
- `/api/alerts/declining-agents`
- `/api/alerts/stuck-quoters`
- `/api/alerts/inactive-agents`

### Logic (server)
- **Summary**:
  - Declining agents: compares quote volume (current vs previous period) using `daily_quote_counts`
  - Stuck quoters: from `agent_wise_monthly_activity_summary` (quotes > 0, policies = 0)
  - Inactive: from `agent_daily_logins` (previously active but no recent logins)
  - Expiring renewals: count from `sold_policies_data` (next 30 days)
- **Declining agents**: detailed list (quotes drop) + lifetime premium context from `sold_policies_data`.
- **Stuck quoters**: detailed list from `agent_wise_monthly_activity_summary` + user info.
- **Inactive agents**: previously active loginers who went dark + lifetime premium context.

### Risks / mismatches to watch
- **UI contract bug (real mismatch)**:
  - `client/src/components/Layout.tsx` expects `total_alerts` in `/api/alerts/summary`
  - API returns `declining_agents_count`, `stuck_quoters_count`, `inactive_agents_count`, `expiring_renewals_count`
  - Result: sidebar alert badge is likely always 0.
- **Cause attribution missing**: alerts identify symptoms but cannot identify operational root causes (no payment failures, no insurer API logs, no ticket/inspection/KYC events).

---

## 10) Operations (`/operations`)

### Data endpoints (client)
- `/api/operations/today`
- `/api/operations/week-comparison`
- `/api/operations/leaderboard`

### Logic (server)
- Today:
  - `sold_policies_data` for today vs 30-day average
  - `daily_quote_counts` for today quote volume
- Week comparison:
  - `sold_policies_data` and `daily_quote_counts` this week vs last week
- Leaderboard:
  - top agents by count/premium from `sold_policies_data` (joins `users` for names)

### Risks / mismatches to watch
- This is **sales operations**, not **workflow operations**: there is no inspection/payment/KYC/ticket telemetry feeding this page.

---

## 11) Advanced (`/advanced`)

### Data endpoints (client)
- `/api/advanced/revenue-at-risk`
- `/api/advanced/weekly-pulse`

### Logic (server)
- Revenue at risk:
  - total premium base: `sold_policies_data`
  - top broker premium: `channel_wise_monthly_sold_policies`
  - top 10 agents premium: `sold_policies_data`
  - renewal leakage: expired policies not matched to recent renewals using `(phone, vehicle_make_model)` heuristic
- Weekly pulse:
  - this week vs last week for policies/premium/agents + quotes and conversion

### Risks / mismatches to watch
- Same renewal matching heuristic risk as Renewals page.
- Broker premium uses monthly aggregated table; agent premium uses policy table → reconciliation depends on ETL consistency.

---

## Cross-cutting “likely mismatches” (high priority to validate)

1) **`sold_policies_data.broker_name` column**
   - The API filters on `broker_name` in `sold_policies_data`.
   - Your earlier schema snippet showed `source` (not `broker_name`).
   - If there is no view/alias column, broker filtering is incorrect or failing.

2) **Product filter values**
   - UI sends product values like: `Private Car`, `Two Wheeler`, `Health`
   - API uses `product_type = $1` (exact match) in `sold_policies_data`
   - If product_type values are different (e.g., `4W`, `Private Car Package`, etc.) filters won’t work.

3) **Alerts sidebar count**
   - Layout expects `total_alerts`, API does not return it → alert badge likely wrong.

