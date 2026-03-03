# How Each Dashboard Fetches Its Data

This document explains, in plain language, exactly where each dashboard gets its numbers from,
what SQL logic runs, which filters work, and where things go wrong.

---

## How the system works (quick overview)

```
Browser (React UI)
  → sends HTTP GET with query params: ?date_range=last_3_months&broker=XYZ&product=Health&state=Maharashtra
  → Node/Express API server (server/index.js)
      → checks in-memory cache (NodeCache)
          → if cached: returns immediately (no DB hit)
          → if not cached: runs SQL against Analytics DB (PostgreSQL)
  → returns JSON to the browser
  → React components render charts/tables from the JSON
```

**Filters available globally:**
- `date_range` — `last_30_days`, `last_3_months`, `last_6_months`, `last_12_months`, `all_time`
- `broker` — broker/channel name (text)
- `product` — product type (text)
- `state` — state name (text)

**Important: not all filters work on all endpoints.** Detailed below.

---

## Dashboard 1 — Executive Summary

**Page file:** `pages/Executive.tsx`  
**Endpoints called:** `/api/executive/kpis`, `/api/executive/growth`, `/api/executive/concentration`

---

### `/api/executive/kpis` — the 6 top KPI cards

**What it shows:** Total policies, total premium, active agents, average ticket, total quotes, total proposals — plus % change vs the prior period.

**Where the data comes from:**

| Metric | Source table | Logic |
|---|---|---|
| Policies, premium, active agents, avg ticket | `sold_policies_data` | COUNT and SUM rows by `sold_date` in current month vs prior month |
| Quotes | `daily_quote_counts` | SUM of `quote_count` by `quote_date` in current month vs prior month |
| Proposals | `agent_wise_monthly_activity_summary` | SUM of all 9 `proposal_count_*` columns for current `activity_month` vs prior |

**How filters apply:**
- `product`, `state`, `broker` → applied to `sold_policies_data` only. Quotes and proposals are **not filtered** by product/state/broker.
- `date_range` → switches between "current month vs prior month" logic (default) and "current range vs equal prior range" logic.

> **⚠ Discrepancy — Mixed data sources for the same time period**
>
> Policies come from `sold_policies_data` filtered by exact date. Quotes come from `daily_quote_counts` filtered by exact date. Proposals come from `agent_wise_monthly_activity_summary` filtered by month string (e.g. `'2025-01'`).
>
> This means: if today is Feb 15, the "current month" proposal count includes all of February so far, but the system counts every row in `activity_month = '2025-02'` — which is fine. However, if `activity_month` values are stored inconsistently (e.g. `'Feb-25'` in some rows), the count will be 0 even though February data exists.
>
> **Root cause:** `activity_month` is a plain text column with no format enforcement.

> **⚠ Discrepancy — Broker filter only affects policies, not quotes/proposals**
>
> If you select broker "ABC", the policy count, premium, active agents, and avg ticket will be filtered to broker ABC. But the quote count and proposal count will still show **all brokers combined**. The conversion rate (policies / quotes) will therefore be incorrectly low for any broker that is strong in policy conversion.

---

### `/api/executive/growth` — monthly growth trend chart

**What it shows:** Month-by-month line chart of policies sold, premium, and active agents over the last 12 months.

**Where the data comes from:** `sold_policies_data` only. Groups by `TO_CHAR(sold_date, 'YYYY-MM')`.

**How filters apply:** All 4 filters work correctly here (`date_range`, `product`, `state`, `broker`).

> **⚠ Discrepancy — Broker filter uses `broker_name` column which does not exist**
>
> The WHERE clause adds `broker_name = $1` but `sold_policies_data` has no `broker_name` column. When any broker is selected, this query will fail or return empty results. This affects this chart and every other chart that reads from `sold_policies_data` with a broker filter.

---

### `/api/executive/concentration` — risk concentration cards

**What it shows:** Which broker holds the largest share of premium, and what % the top 10 agents represent.

**Where the data comes from:**
- Broker concentration → `channel_wise_monthly_sold_policies` (sums `total_premium` per `broker_name`)
- Agent concentration → `sold_policies_data` (sums `premium_amount` per `agent`, picks top 10)
- Top 5 agents detail → `sold_policies_data` + `users` (joins on `agent` = `users.id` for name)

**How filters apply:** `date_range` and `broker` apply to the channel table. `product`, `state`, `broker` apply to `sold_policies_data`.

> **⚠ Discrepancy — Same broker filter issue**
>
> The `broker_name` column doesn't exist in `sold_policies_data`. Same bug.

> **⚠ Discrepancy — date_range defaults to 6 months here**
>
> The Executive KPIs default is "current month vs prior month", but concentration defaults to "last 6 months". If the user has no date filter selected, these two sections are comparing different time windows on the same page.

---

## Dashboard 2 — Agent Analytics

**Page file:** `pages/Agents.tsx`  
**Endpoints called:** `/api/agents/segmentation`, `/api/agents/activation`, `/api/agents/performance-distribution`

---

### `/api/agents/segmentation` — pie chart of agent segments

**What it shows:** How many agents fall into Star / Rising / Occasional / Dormant / Dead.

**The classification logic:**

| Segment | Rule |
|---|---|
| Star | Made ≥ 10 sales in the current month |
| Rising | Made ≥ 5 sales in the past 3 months |
| Occasional | Made ≥ 1 sale OR made ≥ 5 quotes in 3 months |
| Dormant | Made at least 1 quote but 0 sales in 3 months |
| Dead | 0 quotes and 0 sales |

**Where the data comes from:**
- Sales counts → `sold_policies_data` (counts by `sold_date` in last 3 months)
- Quote counts → `daily_quote_counts` (sums by `quote_date` in last 3 months)
- All agents baseline → `users` table in analytics DB (all non-deleted agents with a role)

**How filters apply:** `product`, `state`, `broker` apply to `sold_policies_data` only. Quotes are **not filtered**.

> **⚠ Discrepancy — Broker filter doesn't exist on `sold_policies_data`**
>
> Same missing `broker_name` column bug. Selecting a broker gives wrong results.

> **⚠ Discrepancy — "Dormant" segment is misleading**
>
> An agent is classified as "Dormant" if they have quotes > 0 but sales = 0. But there is no login data in this classification. An agent who logged in daily and did thorough research but didn't sell anything would be "Dormant" — which is different from someone who genuinely went dark. A "Dormant" label is too harsh here.

> **⚠ Discrepancy — `users` table has all users, not just agents**
>
> The "all agents" CTE is: `SELECT id FROM users WHERE roleid IS NOT NULL AND deletedat IS NULL`. This pulls any user who has a role, including admins, ops staff, etc. The "Dead" segment will be inflated by non-agent users.

---

### `/api/agents/activation` — cohort activation chart

**What it shows:** For each month an agent joined, what % of those agents ever made a sale.

**Where the data comes from:** `users` (join month) LEFT JOIN `sold_policies_data` (ever sold).

**How filters apply:** `date_range` controls how far back the cohorts go. `product`, `state`, `broker` filter `sold_policies_data`.

> **⚠ Discrepancy — "Ever sold" doesn't respect date range**
>
> Even if you select `last_3_months`, the query shows cohorts from the last 18 months (default), but "ever sold" means any sale in the entire history of `sold_policies_data`. An agent who joined 18 months ago and sold once 14 months ago would show as "activated" regardless of the selected date filter.
>
> This is actually correct semantically ("has this cohort ever activated") but may confuse users who expect date filter to limit the sales window too.

> **⚠ Discrepancy — analytics `users.createdat` vs transaction DB `users.createdAt`**
>
> The analytics DB `users` table uses lowercase `createdat`. The query uses `u.createdat` which matches the analytics schema. This is fine today but could break if someone tried to run the same query against the transaction DB by mistake.

---

### `/api/agents/performance-distribution` — bar chart of policy count buckets

**What it shows:** How many agents sold 0 / 1-2 / 3-5 / 6-10 / 10+ policies in the last 3 months.

**Where the data comes from:** `sold_policies_data` for policy counts, `users` for all agents baseline.

**How filters apply:** `date_range`, `product`, `state`, `broker` filter `sold_policies_data`.

> **⚠ Discrepancy — Broker filter missing column**
>
> Same bug — `broker_name` doesn't exist.

---

## Dashboard 3 — Funnel

**Page file:** `pages/Funnel.tsx`  
**Endpoints called:** `/api/funnel/conversion`, `/api/funnel/by-product`, `/api/funnel/stuck-quoters`

---

### `/api/funnel/conversion` — monthly quote → proposal → policy trend

**What it shows:** Per month: how many quotes, proposals, policies were created and what the conversion rates were.

**Where the data comes from:** `agent_wise_monthly_activity_summary` only. Sums all 9 `quote_count_*`, `proposal_count_*`, and `policy_count_*` columns per `activity_month`.

**How filters apply:** Only `date_range` is applied. **No broker, product, or state filter is applied at all.**

> **⚠ Discrepancy — All global filters except date_range are silently ignored**
>
> If a user selects "Health" in the product filter, the funnel chart does not change. This is because the query reads the pre-aggregated monthly summary table, and filtering by product would require either a separate table or separate columns.
>
> The user sees the same funnel regardless of what broker or product they've selected — which is inconsistent with every other dashboard.

> **⚠ Discrepancy — Proposals and policies are from different tables than quotes**
>
> Quotes come from `daily_quote_counts` in the KPIs endpoint but from `agent_wise_monthly_activity_summary` in the funnel endpoint. These two tables are populated independently by the ETL. If there is any lag or difference in their update schedules, the quote counts shown on the Executive page and the Funnel page may not match for the same time period.

---

### `/api/funnel/by-product` — bar chart of funnel by product type

**What it shows:** For each product type, how many quotes/proposals/policies were created.

**Where the data comes from:** `agent_wise_monthly_activity_summary`. The server maps column suffixes to product names manually:
- `quote_count_2w` → "Two Wheeler"
- `quote_count_4w` → "Four Wheeler"
- `quote_count_health` → "Health"
- `quote_count_gcv` → "GCV"
- `quote_count_pcv` → "PCV"
- `quote_count_term` → "Term Life"
- `quote_count_personal_accident` → "Personal Accident"
- `quote_count_savings` → "Savings"
- `quote_count_miscd` → "Misc / D"

**How filters apply:** `date_range` works. `product` works (filters to one product_type row after the UNION). **Broker and state are ignored.**

> **⚠ Discrepancy — Product names here may not match the filter dropdown values**
>
> The filter bar populates product options from actual `sold_policies_data.product_type` values (e.g. `Private Car`, `Two Wheeler`, etc.). The funnel endpoint uses hardcoded labels like `'Two Wheeler'` and `'Four Wheeler'`. If a product filter value is `'4W'` or `'Private Car'`, it won't match `'Four Wheeler'`, and the filtered chart will show no data.

---

### `/api/funnel/stuck-quoters` — table of agents quoting but not selling

**What it shows:** Agents who had quotes but zero policies in the last 2 months. Sorted by total quotes.

**Where the data comes from:** `agent_wise_monthly_activity_summary` for quote/policy counts, `users` for agent name and phone.

**How filters apply:** Only `date_range`. No broker/product/state filter.

> **⚠ Discrepancy — Phone number is exposed in the API response**
>
> `u.phone` is returned directly to the browser. This is PII from the analytics `users` table.

---

## Dashboard 4 — Products

**Page file:** `pages/Products.tsx`  
**Endpoints called:** `/api/products/mix`, `/api/products/trend`, `/api/products/business-type`

---

### `/api/products/mix` — product share pie chart

**What it shows:** Which products account for what share of policies and premium.

**Where the data comes from:** `sold_policies_data`. Groups by `product_type`, sums premium and count.

**How filters apply:** All 4 filters work (date, product, state, broker).

> **⚠ Discrepancy — Broker filter uses `broker_name` which doesn't exist**
>
> Same bug as described above.

---

### `/api/products/trend` — product monthly trend line chart

**What it shows:** How each product's policy count and premium has moved month by month.

**Where the data comes from:** `category_wise_monthly_sold_policies`. This is a separate pre-aggregated table that stores `(product_type, sold_month, policy_count, total_premium)`.

**How filters apply:** `date_range` and `product` work. **Broker and state are ignored completely** — this table has no broker or state column.

> **⚠ Discrepancy — Broker and state filters are silently ignored**
>
> If a user picks broker "ABC" and looks at the Product Trend chart, they are seeing platform-wide numbers, not broker ABC's numbers. There is no way to tell from the UI that the filter was ignored.

---

### `/api/products/business-type` — new vs renewal stacked chart

**What it shows:** Month-by-month split of policies into business types (New, Renewal, Roll Over, etc.) per product.

**Where the data comes from:** `sold_policies_data`. Groups by month and `policy_business_type`.

**How filters apply:** All 4 filters work.

> **⚠ Discrepancy — Broker filter missing column**
>
> Same `broker_name` column bug.

---

## Dashboard 5 — Brokers

**Page file:** `pages/Brokers.tsx`  
**Endpoints called:** `/api/brokers/performance`, `/api/brokers/dormant`, `/api/brokers/trend`

---

### `/api/brokers/performance` — broker scorecard table

**What it shows:** Each broker's total policies, premium, quotes, active months, conversion rate, and tier.

**Where the data comes from:**
- Policies and premium → `channel_wise_monthly_sold_policies` (grouped by `broker_name`)
- Quotes → `channel_wise_monthly_activity_summary` (sums all 9 `quote_count_*` columns)
- These two are joined on `sales_channel_id`

**How filters apply:** `date_range` and `broker` work on both tables.

> **⚠ Discrepancy — Join uses a type cast hack (`::text`)**
>
> `channel_wise_monthly_sold_policies.sales_channel_id` is stored as VARCHAR. `channel_wise_monthly_activity_summary.sales_channel_id` is stored as BIGINT. The join is:
> ```sql
> ON bq.sales_channel_id::text = bp.sales_channel_id::text
> ```
> Casting both to text to make them match. This works but disables index usage on both sides, making this query slower than it needs to be. It also means if any `sales_channel_id` has leading zeros or spaces in the VARCHAR version, the join will miss rows.

> **⚠ Discrepancy — No proposal count in the broker scorecard**
>
> The scorecard shows quotes and policies but not proposals. Conversion rate is calculated as policies/quotes, skipping the proposal step. You cannot tell from this table whether a broker's drop-off is happening at quote→proposal or proposal→policy.

---

### `/api/brokers/dormant` — brokers who quote but don't sell

**What it shows:** Brokers with quotes > 0 but policies = 0 in the last 3 months.

**Where the data comes from:** `channel_wise_monthly_activity_summary` only.

**How filters apply:** `date_range` and `broker` work.

---

### `/api/brokers/trend` — broker monthly trend chart

**What it shows:** Top 10 brokers' policy count and premium over the last 6 months.

**Where the data comes from:** `channel_wise_monthly_sold_policies`. If a specific broker is selected, shows just that broker.

**How filters apply:** `date_range` and `broker` work.

> **⚠ Discrepancy — Trend shows policies only, not quotes**
>
> The broker trend only shows how many policies were sold. There is no quote or proposal line. You cannot see whether a broker's trend change was driven by a drop in quoting activity or a drop in conversion.

---

## Dashboard 6 — Geographic

**Page file:** `pages/Geographic.tsx`  
**Endpoints called:** `/api/geographic/states`, `/api/geographic/state-product`

---

### `/api/geographic/states` — state-level table and map

**What it shows:** Top 20 states by premium with policy count, agent count, avg ticket.

**Where the data comes from:** `sold_policies_data`. Groups by `policy_holder_state`.

**How filters apply:** All 4 filters work.

> **⚠ Discrepancy — Broker filter missing column**
>
> Same `broker_name` bug.

> **Note — This endpoint is also used by FilterBar to populate the state dropdown**
>
> The FilterBar calls this same endpoint (without filters) to get the list of available states. This means the state dropdown only shows states that have at least one sold policy. States with no sales history won't appear as a filter option.

---

### `/api/geographic/state-product` — heatmap of state × product

**What it shows:** For each state and product combination, how many policies and what premium.

**Where the data comes from:** `sold_policies_data`. Shows top 10 states (by premium) with their product breakdown, or one specific state if selected.

**How filters apply:** All 4 filters work.

> **⚠ Discrepancy — Broker filter missing column**
>
> Same `broker_name` bug.

---

## Dashboard 7 — Insurers

**Page file:** `pages/Insurers.tsx`  
**Endpoints called:** `/api/insurers/share`, `/api/insurers/trend`

---

### `/api/insurers/share` — insurer market share

**What it shows:** Each insurer's policy count, premium, and % share of total.

**Where the data comes from:** `sold_policies_data`. Groups by `insurer`.

**How filters apply:** All 4 work.

> **⚠ Discrepancy — Broker filter missing column**
>
> Same `broker_name` bug.

---

### `/api/insurers/trend` — top 8 insurers monthly trend

**What it shows:** Month-by-month policy count and premium for the top 8 insurers.

**Where the data comes from:** `sold_policies_data`. First finds top 8 insurers by premium in the date range, then plots their monthly trend.

**How filters apply:** All 4 work.

> **⚠ Discrepancy — Broker filter missing column**
>
> Same `broker_name` bug.

> **⚠ Discrepancy — "Top 8" is determined within the filtered period**
>
> If you filter by product = "Health", the top 8 insurers are recalculated for Health only. This is correct behavior but worth knowing — the set of insurers on the chart will change when you change filters.

---

## Dashboard 8 — Renewals

**Page file:** `pages/Renewals.tsx`  
**Endpoints called:** `/api/renewals/upcoming`, `/api/renewals/at-risk`

---

### `/api/renewals/upcoming` — policies expiring in next 90 days

**What it shows:** Count and premium at stake for policies expiring in 0-30, 31-60, 61-90 days.

**Where the data comes from:** `sold_policies_data`. Filters by `policy_expiry_date` between today and today + 90 days.

**How filters apply:** `product`, `state`, `broker` work. `date_range` is ignored (the window is always "next 90 days").

> **⚠ Discrepancy — Broker filter missing column**
>
> Same `broker_name` bug.

> **⚠ Discrepancy — These are original policies, not renewals**
>
> This endpoint identifies policies that are about to expire. It does not know whether the renewal has already been initiated or whether the agent has been contacted. The "premium at stake" is the premium from when the policy was originally sold, not the expected renewal premium.

---

### `/api/renewals/at-risk` — expired policies not yet renewed

**What it shows:** Policies that expired in the last 90 days and do NOT appear to have been renewed.

**Where the data comes from:** `sold_policies_data` joined to itself.

**The renewal matching logic:**
1. Find all policies that expired in the last 90 days (the "expired" set)
2. Find all policies sold in the last 90 days where `policy_business_type` is `'Renewal'` or `'Roll Over'` (the "renewed" set)
3. Match expired to renewed using `vehicle_make_model` AND `policy_holder_phone`
4. Expired policies that have no matching renewed record = "at risk"

**How filters apply:** `product`, `state`, `broker` work (with `broker_name` bug).

> **⚠ Discrepancy — Renewal matching is a heuristic, not exact**
>
> The match uses `vehicle_make_model` + `policy_holder_phone` as a proxy for "same customer, same vehicle". This will:
> - Miss renewals where the phone number changed
> - Miss renewals where the vehicle name is stored slightly differently (e.g. `'Maruti Swift'` vs `'Swift'`)
> - False-match if two different customers happen to have the same phone number and vehicle model (rare but possible)
>
> There is no `proposal_id` or `policy_number` linkage between original and renewal policy records, so this heuristic is the best the current schema allows.

---

## Dashboard 9 — Alerts

**Page file:** `pages/Alerts.tsx`  
**Endpoints called:** `/api/alerts/summary`, `/api/alerts/declining-agents`, `/api/alerts/stuck-quoters`, `/api/alerts/inactive-agents`

---

### `/api/alerts/summary` — the 4 count badges

**What it shows:** Count of: declining agents, stuck quoters, inactive agents, expiring renewals.

**Where the data comes from:**
- Declining agents → `daily_quote_counts` (compares current vs prior period quote counts per agent)
- Stuck quoters → `agent_wise_monthly_activity_summary` (agents with quotes but no policies in last 2 months)
- Inactive agents → `agent_daily_logins` (agents who were logging in 30-60 days ago but have gone quiet)
- Expiring renewals → `sold_policies_data` (policies expiring within 30 days)

> **⚠ Discrepancy — Alert badge in the sidebar always shows 0**
>
> The sidebar in `Layout.tsx` reads `alertData.total_alerts`. This endpoint **never returns a `total_alerts` field**. It returns four separate counts: `declining_agents_count`, `stuck_quoters_count`, `inactive_agents_count`, `expiring_renewals_count`. The badge will always display 0.

---

### `/api/alerts/declining-agents` — table of agents whose quoting dropped >40%

**What it shows:** Agents whose quote count dropped by more than 40% compared to the prior period, along with their lifetime premium and policy count.

**Where the data comes from:**
- Quote volumes → `daily_quote_counts` for both current and prior periods
- Lifetime context → `sold_policies_data` (total premium and policies ever sold by that agent)
- Agent name/phone → `users`

**Decline threshold:** An agent appears if `(prev_quotes - cur_quotes) / prev_quotes > 0.40`.

**How filters apply:** `date_range` adjusts the comparison window. `product`, `state`, `broker` filter the lifetime context (which broker and product the agent has sold in their lifetime) but do **not** filter the quote counts.

> **⚠ Discrepancy — The "declining" detection is based only on quotes**
>
> An agent who shifted from quoting 2-wheelers to quoting health (and happens to not have 2-wheeler data in this period) would show as declining if the old product filter is applied. But quote volumes are never filtered by product.

> **⚠ Discrepancy — Only agents who were present in both periods are shown**
>
> The INNER JOIN between current and prior period means:
> - New agents (only in current period) are not shown
> - Agents who stopped entirely (only in prior period) are also not shown — because their `cur_quotes` would be 0 and they'd need to be in the current period CTE to appear at all
>
> Agents who went completely silent will not appear in this alert list.

---

### `/api/alerts/stuck-quoters` — agents quoting but not converting

**What it shows:** Agents with quotes > 0 and policies = 0 in the last 2 months. Includes a "stuck at" diagnosis: whether they're stuck at the quote→proposal stage or proposal→policy stage.

**Where the data comes from:** `agent_wise_monthly_activity_summary` for counts, `users` for name and phone.

**How filters apply:** Only `date_range`. No broker/product/state filter.

> **⚠ Discrepancy — The "stuck at proposal stage" diagnosis can be misleading**
>
> The code says: `WHEN r.total_proposals > 0 THEN 'Stuck at proposal stage'`. This means if an agent has any proposals but no policies, they're labeled "Stuck at proposal stage". But the actual sticking point could be payment failure, KYC failure, or inspection delay — the current data doesn't tell us which. The label is an oversimplification.

---

### `/api/alerts/inactive-agents` — agents who were active but stopped logging in

**What it shows:** Agents who logged in regularly 30–60 days ago (≥5 logins) but haven't logged in recently.

**Where the data comes from:**
- Login history → `agent_daily_logins` (two scans: one for "was active", one for "last login")
- Lifetime context → `sold_policies_data`
- Agent details → `users`

**Inactivity windows (default):**
- "Previously active" = logged in between 60 days ago and 30 days ago
- "Now inactive" = last login was more than 7 days ago

**How filters apply:** `date_range` adjusts the windows. `product`, `state`, `broker` filter only the lifetime context (same broker_name bug applies).

> **⚠ Discrepancy — Login data and sales data are measured independently**
>
> An agent could be "inactive" by login (not logged into the platform) but their broker might be submitting business through another channel. The login data only captures direct platform activity.

> **⚠ Discrepancy — The 5-login threshold is hardcoded**
>
> `HAVING SUM(login_count) >= 5` is the definition of "was previously active". This means an agent who logged in exactly 4 times in the active window will not appear in this list, even if that's a significant drop from their normal behavior.

---

## Dashboard 10 — Operations

**Page file:** `pages/Operations.tsx`  
**Endpoints called:** `/api/operations/today`, `/api/operations/week-comparison`, `/api/operations/leaderboard`

---

### `/api/operations/today` — today's numbers vs 30-day average

**What it shows:** Today's policies, premium, agents, and quotes, compared against the 30-day daily average.

**Where the data comes from:**
- Today's policies/premium/agents → `sold_policies_data` where `sold_date = CURRENT_DATE`
- Today's quotes → `daily_quote_counts` where `quote_date = CURRENT_DATE`
- 30-day average for policies/premium/agents → `sold_policies_data` for last 30 days
- 30-day average for quotes → `daily_quote_counts` for last 30 days

**How filters apply:** `product`, `state`, `broker` apply to `sold_policies_data`. Quote counts are **not filtered** by product/state/broker.

> **⚠ Discrepancy — Broker filter on policies but not quotes**
>
> If you filter by broker "ABC", today's policy count shows broker ABC only, but today's quote count shows all brokers. The comparison between the two (conversion rate) becomes meaningless for a specific broker.

> **⚠ Discrepancy — Today's data depends on when the ETL runs**
>
> Because data comes from the analytics DB (which is updated nightly by an Airflow job), "today's" numbers will be 0 or very low until the ETL runs. If the ETL runs at midnight, "today's" data for 9 AM shows only policies sold between midnight and whenever the last sync ran — which may be 0. The dashboard would show "today: 0 policies, 30-day avg: 15/day" and look alarming even on a normal day.

---

### `/api/operations/week-comparison` — this week vs last week

**What it shows:** This week vs last week comparison for policies, premium, agents, and quotes, with % change.

**Where the data comes from:** Same tables as above but with `DATE_TRUNC('week', CURRENT_DATE)` as the cutoff.

**How filters apply:** Same as above — `product`, `state`, `broker` filter policies but not quotes.

> **⚠ Discrepancy — Same broker/quotes mismatch as in "today"**
>
> Week-over-week comparison has the same issue. The quote comparison is unfiltered by broker.

> **⚠ Discrepancy — "This week" is calendar week, not rolling 7 days**
>
> The query uses `DATE_TRUNC('week', CURRENT_DATE)` which resets on Monday. If today is Tuesday, "this week" has only 2 days of data and will always look worse than "last week" (7 days). The % drop will be artificial.

---

### `/api/operations/leaderboard` — top 20 agents by policies this month

**What it shows:** Ranked list of agents by policies sold this month (or the selected date range).

**Where the data comes from:** `sold_policies_data` joined to `users` for agent names.

**How filters apply:** All 4 filters apply.

> **⚠ Discrepancy — Broker filter missing column**
>
> Same `broker_name` bug.

> **⚠ Discrepancy — Phone numbers in the response**
>
> `u.phone` is returned to the browser. Same PII concern as stuck-quoters.

---

## Dashboard 11 — Advanced

**Page file:** `pages/Advanced.tsx`  
**Endpoints called:** `/api/advanced/revenue-at-risk`, `/api/advanced/weekly-pulse`

---

### `/api/advanced/revenue-at-risk` — revenue risk metrics

**What it shows:** Three concentration/risk metrics:
1. Broker concentration: what % of premium comes from the top broker
2. Agent dependency: what % of premium comes from the top 10 agents
3. Renewal leakage: how much premium was lost to policies that expired but weren't renewed

**Where the data comes from:**
- Broker concentration → `channel_wise_monthly_sold_policies`
- Agent dependency → `sold_policies_data` (top 10 agents by premium)
- Renewal leakage → `sold_policies_data` self-joined (same heuristic as at-risk renewals)

**How filters apply:** `product`, `state`, `broker` filter `sold_policies_data`. Date range filters both tables.

> **⚠ Discrepancy — Broker concentration is not filtered by product/state**
>
> The broker concentration CTE reads from `channel_wise_monthly_sold_policies` which has no product or state column. So even if the user selects "Health" and "Maharashtra", the broker concentration still shows platform-wide numbers.

> **⚠ Discrepancy — Parameter index conflict in the SQL construction**
>
> The query builds two separate param arrays (`spf` for the main clauses, `spfE` and `spfR` for the renewal leakage CTE) and merges them into `params`. However, `spfE` and `spfR` both start their parameter index at `1`, meaning they would generate `$1` parameters that conflict with the `$1` from `spf`. The combined SQL has parameter index collisions that could cause wrong filter values to be applied in the renewal leakage calculation.

---

### `/api/advanced/weekly-pulse` — this week's health dashboard with traffic lights

**What it shows:** Week-over-week changes for policies, premium, agents, quotes, and conversion rate. Each metric gets a GREEN / YELLOW / RED flag.

**Flag thresholds:**
- GREEN = grew ≥ 5% vs last week
- YELLOW = between -5% and +5%
- RED = dropped more than 5%

**Where the data comes from:** `sold_policies_data` and `daily_quote_counts` — same logic as week-comparison endpoint.

**How filters apply:** `product`, `state`, `broker` filter `sold_policies_data`. Quotes unfiltered.

> **⚠ Discrepancy — Broker filter missing column on `sold_policies_data`**
>
> Same bug.

> **⚠ Discrepancy — Same "partial week" issue**
>
> Calendar week comparison means "this week" always looks incomplete on Monday through Friday. The traffic lights will show RED every Monday through Wednesday even in healthy weeks.

> **⚠ Discrepancy — Conversion rate = policies / quotes**
>
> The conversion rate here is `policies (sold_policies_data) / quotes (daily_quote_counts)`. These two numbers come from different tables with different update timing. On any given day mid-week, today's quotes may be counted but today's policies (from the nightly ETL) may not be in yet. This makes the conversion rate artificially low.

---

## Summary of All Discrepancies

| # | Issue | Dashboards affected | Severity |
|---|-------|---------------------|----------|
| 1 | `sold_policies_data` has no `broker_name` column — broker filter silently fails | All except Funnel and Brokers | **Critical** |
| 2 | Alert badge reads `total_alerts` which is never returned | Sidebar on all pages | **Critical** |
| 3 | `channel_wise_monthly_sold_policies.sales_channel_id` is VARCHAR — join uses `::text` cast, disabling indexes | Brokers — performance | **High** |
| 4 | `funnel/conversion` ignores broker, product, state filters | Funnel | **High** |
| 5 | Product trend (`category_wise_monthly_sold_policies`) has no broker or state column — filters silently ignored | Products — trend | **High** |
| 6 | Broker filter on policies does not apply to quotes in same endpoint | Operations — today, week-comparison, weekly-pulse | **High** |
| 7 | Renewal matching is heuristic (phone + vehicle_make_model), not exact | Renewals — at-risk, Advanced — revenue-at-risk | **Medium** |
| 8 | Agent segmentation includes all users (not just agents) in the "Dead" count | Agents — segmentation | **Medium** |
| 9 | "Declining agents" misses agents who went completely silent | Alerts — declining agents | **Medium** |
| 10 | "Today" and "this week" always show low/zero numbers before nightly ETL runs | Operations — today, week-comparison | **Medium** |
| 11 | Calendar week comparison makes Tuesday look worse than Monday artificially | Operations — week-comparison, Advanced — weekly-pulse | **Medium** |
| 12 | Executive KPIs: quotes and proposals come from different tables than policies (mixed grain) | Executive — KPIs | **Medium** |
| 13 | Broker concentration in revenue-at-risk is never filtered by product/state | Advanced — revenue-at-risk | **Low** |
| 14 | Parameter index conflict in `revenue-at-risk` SQL for renewal leakage | Advanced — revenue-at-risk | **Low** |
| 15 | Agent phone numbers exposed in API responses | Funnel — stuck-quoters, Operations — leaderboard, Alerts | **Low** |
| 16 | `activity_month` is plain text with no format enforcement — YYYY-MM mismatch causes 0 counts | Executive KPIs, Funnel | **Low** |
