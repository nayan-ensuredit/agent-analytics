# Analytics DB — Schema Review & Change Recommendations

**Scope**: Agent activity · Broker activity · Funnel visibility · Time-based trends  
**Constraint**: Minimal, backward-compatible, implementable in 1 day via `ALTER TABLE` + nightly ETL update  
**Not in scope**: Insurer error analytics, Transaction DB changes, major redesigns

---

## Part 1 — Critical Bugs (Wrong Results Today)

These are places where the dashboards are currently **producing incorrect or empty results** due to a schema/code mismatch.

---

### BUG-1 · `sold_policies_data` is missing `broker_name` column

**What the code does**
Every endpoint that reads `sold_policies_data` applies a broker filter like this:
```sql
WHERE broker_name = $1
```

**What the table actually has**
The analytics schema does **not** have a `broker_name` column. It has `source` (text) and `sales_channel_user_id` (integer).

**Impact**
When a user selects any broker in the filter bar, every single dashboard that uses `sold_policies_data` will either:
- Return a Postgres column-not-found error, OR
- Return empty results silently

Affected dashboards (all of them use `sold_policies_data`):
- Executive Summary (KPIs, growth trend, concentration)
- Agent Analytics (segmentation, activation, distribution)
- Products (mix, business-type)
- Geographic (states, state×product)
- Insurers (share, trend)
- Renewals (upcoming, at-risk)
- Alerts (declining agents, inactive agents, expiring count)
- Operations (today, week-comparison, leaderboard)
- Advanced (revenue-at-risk, weekly-pulse)

**Fix**
```sql
ALTER TABLE sold_policies_data
  ADD COLUMN IF NOT EXISTS broker_name TEXT;
```

**ETL population**
```sql
-- In the nightly ETL, populate from the channel/broker mapping:
UPDATE sold_policies_data spd
SET broker_name = u.broker_display_name  -- or source from users join
FROM users u
WHERE u.id = spd.sales_channel_user_id
  AND spd.broker_name IS NULL;
```

If no broker master table exists, the simplest option is to copy `source` into `broker_name` during ETL since `source` already holds the broker/channel label in the current data. The `FilterBar` loads broker options from `channel_wise_monthly_sold_policies.broker_name`, so the values must match exactly.

```sql
-- Simpler interim approach: mirror source into broker_name
UPDATE sold_policies_data
SET broker_name = source
WHERE broker_name IS NULL;
```

Then make the nightly ETL maintain this field going forward.

---

### BUG-2 · `channel_wise_monthly_sold_policies.sales_channel_id` is `VARCHAR` not `INTEGER`

**What the code does**
The broker performance endpoint joins this table to `channel_wise_monthly_activity_summary` on `sales_channel_id`:
```sql
LEFT JOIN broker_quotes bq
  ON bq.sales_channel_id::text = bp.sales_channel_id::text
```

The `::text` cast is a workaround because one column is `BIGINT` and the other is `VARCHAR`.

**Impact**
- Index on `sales_channel_id` is not used during the join (cast bypass)
- The query is slower than it needs to be
- The type mismatch is a silent bug risk — string `'10'` vs integer `10` comparisons differ

**Fix**
```sql
ALTER TABLE channel_wise_monthly_sold_policies
  ALTER COLUMN sales_channel_id TYPE INTEGER
  USING sales_channel_id::INTEGER;
```

After this, the server code's `::text` casts become unnecessary (harmless but can be cleaned up).

---

### BUG-3 · `alerts/summary` returns wrong alert badge count (always 0)

**What the code does**
`Layout.tsx` reads:
```ts
const alertCount = alertData?.total_alerts ?? 0;
```

**What the API actually returns**
```json
{
  "declining_agents_count": 12,
  "stuck_quoters_count": 8,
  "inactive_agents_count": 45,
  "expiring_renewals_count": 130
}
```

The field `total_alerts` is never returned. This is a **code fix**, not a schema fix, but it stems from the schema having separate count columns. The sidebar alert badge is always `0`.

**Fix** — two options:

Option A (schema, preferred): Add `total_alerts` as a computed column in the SQL:
```sql
-- In /api/alerts/summary server query, add to SELECT:
(d.cnt + stuck_count + i.cnt + e.cnt) AS total_alerts
```

Option B (client code): Sum the four counts in `Layout.tsx`:
```ts
const alertCount = alertData
  ? (toNum(alertData.declining_agents_count)
   + toNum(alertData.stuck_quoters_count)
   + toNum(alertData.inactive_agents_count)
   + toNum(alertData.expiring_renewals_count))
  : 0;
```

Option B is a 3-line client-side fix and the faster path.

---

## Part 2 — Missing Fields (Analytics Gaps)

These are fields that do not exist in the current analytics schema but are needed for accurate, efficient dashboards.

---

### GAP-1 · `daily_quote_counts` is missing `sales_channel_id`

**Current state**
`daily_quote_counts` has only `agent_id`, `quote_date`, `quote_count`.

**What breaks**
Every alert/query that needs broker-level daily quote activity (declining agents by broker, stuck quoters by broker, operations today by broker) must join:
```sql
daily_quote_counts → users (to get saleschanneluserid)
```

This join scans the full `users` table every time.

**Fix**
```sql
ALTER TABLE daily_quote_counts
  ADD COLUMN IF NOT EXISTS sales_channel_id INTEGER;
```

**ETL population**
```sql
UPDATE daily_quote_counts dqc
SET sales_channel_id = u.saleschanneluserid
FROM users u
WHERE u.id = dqc.agent_id
  AND dqc.sales_channel_id IS NULL;
```

**Dashboards improved**
- Alerts: declining agents, stuck quoters (can now filter by broker without a join)
- Operations: today, week-comparison (broker filter on quote data now direct)
- Executive KPIs: quote counts with broker filter now correct

---

### GAP-2 · `agent_wise_monthly_activity_summary` is missing `login_count`

**Current state**
Login data lives in `agent_daily_logins` (separate table, daily grain). There is no monthly login rollup.

**What breaks**
The agent segmentation logic classifies agents as "Dormant" based on quotes alone (`quotes_3m > 0`). An agent who logged in regularly but didn't generate quotes is invisible to this classification.

Agent health and engagement scoring (proposed in `01_new_tables_schema.sql`) also depends on login frequency as a signal.

**Fix**
```sql
ALTER TABLE agent_wise_monthly_activity_summary
  ADD COLUMN IF NOT EXISTS login_count INTEGER NOT NULL DEFAULT 0;
```

**ETL population** — computed from `agent_daily_logins`:
```sql
UPDATE agent_wise_monthly_activity_summary a
SET login_count = (
  SELECT COALESCE(SUM(adl.login_count), 0)
  FROM agent_daily_logins adl
  WHERE adl.agent_id = a.agent_id
    AND TO_CHAR(adl.login_date, 'YYYY-MM') = a.activity_month
)
WHERE a.login_count = 0;
```

**Dashboards improved**
- Agent Analytics: segmentation (Dormant agents correctly identified even if they logged in but didn't quote)
- Alerts: inactive agents (can use monthly login summary instead of scanning `agent_daily_logins`)

---

### GAP-3 · `agent_wise_monthly_activity_summary` is missing `last_activity_date`

**Current state**
To find when an agent was last active in a given month, you must scan `agent_daily_logins` or `sold_policies_data`. The alerts for "gone dark" agents do a backward scan across multiple months.

**Fix**
```sql
ALTER TABLE agent_wise_monthly_activity_summary
  ADD COLUMN IF NOT EXISTS last_activity_date DATE;
```

`last_activity_date` = the latest date in that month on which the agent had any login, quote, or policy.

**ETL population**
```sql
UPDATE agent_wise_monthly_activity_summary a
SET last_activity_date = (
  SELECT MAX(d)
  FROM (
    SELECT MAX(adl.login_date) AS d
    FROM agent_daily_logins adl
    WHERE adl.agent_id = a.agent_id
      AND TO_CHAR(adl.login_date, 'YYYY-MM') = a.activity_month
    UNION ALL
    SELECT MAX(dqc.quote_date)
    FROM daily_quote_counts dqc
    WHERE dqc.agent_id = a.agent_id
      AND TO_CHAR(dqc.quote_date, 'YYYY-MM') = a.activity_month
  ) sub
);
```

**Dashboards improved**
- Alerts: inactive agents — detect "was active N months ago, now gone dark" in a single table scan
- Agent Analytics: cohort activation trends (last active date per cohort month)

---

### GAP-4 · `channel_wise_monthly_activity_summary` is missing pre-computed totals

**Current state**
The broker performance and funnel endpoints must sum 9 product columns at query time:
```sql
SUM(quote_count_2w + quote_count_4w + quote_count_health + quote_count_gcv
    + quote_count_pcv + quote_count_term + quote_count_personal_accident
    + quote_count_savings + quote_count_miscd) AS total_quotes
```

This pattern is repeated 3× per query (quotes/proposals/policies) and appears across multiple endpoints.

**Fix**
```sql
ALTER TABLE channel_wise_monthly_activity_summary
  ADD COLUMN IF NOT EXISTS total_quotes     INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_proposals  INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_policies   INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_premium    NUMERIC NOT NULL DEFAULT 0;
```

**ETL population** — these are simple row-level sums:
```sql
UPDATE channel_wise_monthly_activity_summary SET
  total_quotes    = COALESCE(quote_count_2w,0)    + COALESCE(quote_count_4w,0)
                  + COALESCE(quote_count_health,0) + COALESCE(quote_count_gcv,0)
                  + COALESCE(quote_count_pcv,0)    + COALESCE(quote_count_term,0)
                  + COALESCE(quote_count_personal_accident,0)
                  + COALESCE(quote_count_savings,0)+ COALESCE(quote_count_miscd,0),
  total_proposals = COALESCE(proposal_count_2w,0)  + COALESCE(proposal_count_4w,0)
                  + COALESCE(proposal_count_health,0) + COALESCE(proposal_count_gcv,0)
                  + COALESCE(proposal_count_pcv,0) + COALESCE(proposal_count_term,0)
                  + COALESCE(proposal_count_personal_accident,0)
                  + COALESCE(proposal_count_savings,0) + COALESCE(proposal_count_miscd,0),
  total_policies  = COALESCE(policy_count_2w,0)    + COALESCE(policy_count_4w,0)
                  + COALESCE(policy_count_health,0) + COALESCE(policy_count_gcv,0)
                  + COALESCE(policy_count_pcv,0)    + COALESCE(policy_count_term,0)
                  + COALESCE(policy_count_personal_accident,0)
                  + COALESCE(policy_count_savings,0)+ COALESCE(policy_count_miscd,0),
  total_premium   = COALESCE(policy_premium_2w,0)  + COALESCE(policy_premium_4w,0)
                  + COALESCE(policy_premium_health,0)+ COALESCE(policy_premium_gcv,0)
                  + COALESCE(policy_premium_pcv,0)  + COALESCE(policy_premium_term,0)
                  + COALESCE(policy_premium_personal_accident,0)
                  + COALESCE(policy_premium_savings,0)+ COALESCE(policy_premium_miscd,0);
```

**Dashboards improved**
- Brokers: performance scorecard (conversion rate now uses pre-computed columns)
- Brokers: dormant detection (simpler `total_policies = 0 AND total_quotes > 0` check)
- Funnel: monthly conversion trend (can use channel table directly for totals)
- Operations: week-comparison broker filter (pre-computed totals = faster)

---

### GAP-5 · `agent_wise_monthly_activity_summary` is missing pre-computed totals (same as GAP-4 but for agents)

**Fix**
```sql
ALTER TABLE agent_wise_monthly_activity_summary
  ADD COLUMN IF NOT EXISTS total_quotes     INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_proposals  INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_policies   INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_premium    NUMERIC NOT NULL DEFAULT 0;
```

Same ETL pattern as GAP-4 but applied to `agent_wise_monthly_activity_summary`.

**Dashboards improved**
- Funnel: conversion endpoint (reads from this table — can now use `total_*` instead of 9-column sums)
- Funnel: stuck quoters (simpler `total_policies = 0 AND total_quotes > 0`)
- Alerts: stuck quoters (same)
- Agent Analytics: segmentation (total_quotes and total_policies directly available)

---

### GAP-6 · `channel_wise_monthly_activity_summary` is missing `sub_sales_channel_id`

**Current state**
The table tracks `sales_channel_id` (broker level) but there is no sub-channel column. The transaction DB `users` table has both `salesChannelUserId` and `subSalesChannelUserId`, and `sold_policies_data` has `sub_sales_channel_id`.

**Fix**
```sql
ALTER TABLE channel_wise_monthly_activity_summary
  ADD COLUMN IF NOT EXISTS sub_sales_channel_id INTEGER;
```

**ETL**
Populate when building the monthly aggregation by grouping on `sub_sales_channel_id` from the source data.

**Dashboards improved**
- Brokers: enables sub-broker level drill-down
- Alerts: broker-level alerts can be narrowed to specific sub-channels

---

### GAP-7 · `sold_policies_data` is missing `net_premium` total at funnel/broker level

Actually, `sold_policies_data` already has `net_premium`. However neither `agent_wise_monthly_activity_summary` nor `channel_wise_monthly_activity_summary` has `net_premium` totals — only `policy_premium_*` (gross).

**Fix**
```sql
ALTER TABLE agent_wise_monthly_activity_summary
  ADD COLUMN IF NOT EXISTS total_net_premium NUMERIC NOT NULL DEFAULT 0;

ALTER TABLE channel_wise_monthly_activity_summary
  ADD COLUMN IF NOT EXISTS total_net_premium NUMERIC NOT NULL DEFAULT 0;
```

**ETL population** — derived from `sold_policies_data` summed by agent/channel and month.

**Dashboards improved**
- Executive KPIs: `net_premium` is shown as a KPI card but currently reads from `sold_policies_data` only. Having it in summary tables enables correct broker-filtered net premium.

---

## Part 3 — Type / Naming Inconsistencies (Fragility Risks)

These don't break dashboards today but are time bombs.

---

### RISK-1 · `activity_month` and `sold_month` are `VARCHAR` not `DATE`

**Both monthly summary tables use string fields for month:**
- `agent_wise_monthly_activity_summary.activity_month` — `character varying`
- `channel_wise_monthly_activity_summary.sold_month` — `character varying`
- `category_wise_monthly_sold_policies.sold_month` — `text`
- `channel_wise_monthly_sold_policies.sold_month` — `text`

**Risk**
String comparison `'2024-09' >= '2024-06'` works **only** if the format is strictly `YYYY-MM` everywhere. If any row gets `'Sep-24'` or `'2024-9'` it silently returns wrong data. Also no date arithmetic (e.g. `NOW() - INTERVAL '3 months'` doesn't work on strings).

The server uses `TO_CHAR(CURRENT_DATE - INTERVAL ..., 'YYYY-MM')` for comparisons, which works today but is fragile.

**Recommended fix** (can be done in ETL without breaking existing queries immediately):
```sql
-- Add a proper date column alongside the varchar one
ALTER TABLE agent_wise_monthly_activity_summary
  ADD COLUMN IF NOT EXISTS activity_month_date DATE;

-- ETL: populate as first-of-month
UPDATE agent_wise_monthly_activity_summary
SET activity_month_date = TO_DATE(activity_month || '-01', 'YYYY-MM-DD')
WHERE activity_month_date IS NULL;
```

Do the same for all four tables. Then gradually migrate server queries to use `activity_month_date` for date comparisons.

---

### RISK-2 · Inconsistent month column naming across tables

| Table | Month column |
|---|---|
| `agent_wise_monthly_activity_summary` | `activity_month` |
| `channel_wise_monthly_activity_summary` | `sold_month` |
| `category_wise_monthly_sold_policies` | `sold_month` |
| `channel_wise_monthly_sold_policies` | `sold_month` |

The agent table uses a different name (`activity_month`) than the three channel/category tables (`sold_month`). This causes server-side code to use different filter builders for each table. Not a data bug, but adds maintenance overhead and confusion.

**Recommendation**: When adding the new `activity_month_date` column (RISK-1 above), use `month_date` as the standard name across all four tables for the new column, creating a consistent convention going forward.

---

### RISK-3 · `users` table in analytics DB has raw PII and credentials

**What exists**
```
users.phone       VARCHAR   -- raw phone number
users.email       VARCHAR   -- raw email
users.password    VARCHAR   -- stored password (even if hashed, shouldn't be here)
users.salt        VARCHAR   -- crypto salt
```

**Risk**
Analytics DB is queried by the dashboard API. These fields are readable via the API surface. The server code joins `users` in alert and leaderboard endpoints and returns `phone` directly to the browser.

**Recommendation**
This does not need to be fixed in 1 day but should be flagged. The `phone` column is needed for the alert tables (agents to call), so it can't simply be dropped. A minimal safe approach: create a **view** `users_analytics` that exposes only the safe columns, and migrate server queries to use the view.

---

## Part 4 — Summary Table (Priority Order)

| # | Change | Type | Tables affected | Priority | Effort |
|---|--------|------|-----------------|----------|--------|
| BUG-1 | Add `broker_name` to `sold_policies_data` | ADD COLUMN + ETL | `sold_policies_data` | **P0 — Critical** | 1h |
| BUG-2 | Fix `sales_channel_id` type in `channel_wise_monthly_sold_policies` | ALTER TYPE | `channel_wise_monthly_sold_policies` | **P0 — Critical** | 30m |
| BUG-3 | Fix alert badge count in `Layout.tsx` | Code fix (client) | `Layout.tsx` | **P0 — Critical** | 15m |
| GAP-1 | Add `sales_channel_id` to `daily_quote_counts` | ADD COLUMN + ETL | `daily_quote_counts` | **P1 — High** | 1h |
| GAP-4 | Add `total_*` rollup cols to `channel_wise_monthly_activity_summary` | ADD COLUMN + ETL | `channel_wise_monthly_activity_summary` | **P1 — High** | 1h |
| GAP-5 | Add `total_*` rollup cols to `agent_wise_monthly_activity_summary` | ADD COLUMN + ETL | `agent_wise_monthly_activity_summary` | **P1 — High** | 1h |
| GAP-2 | Add `login_count` to `agent_wise_monthly_activity_summary` | ADD COLUMN + ETL | `agent_wise_monthly_activity_summary` | **P1 — High** | 1h |
| GAP-3 | Add `last_activity_date` to `agent_wise_monthly_activity_summary` | ADD COLUMN + ETL | `agent_wise_monthly_activity_summary` | **P2 — Medium** | 2h |
| GAP-6 | Add `sub_sales_channel_id` to `channel_wise_monthly_activity_summary` | ADD COLUMN + ETL | `channel_wise_monthly_activity_summary` | **P2 — Medium** | 1h |
| GAP-7 | Add `total_net_premium` to both monthly summary tables | ADD COLUMN + ETL | Both summary tables | **P2 — Medium** | 1h |
| RISK-1 | Add `_date` DATE columns for month fields | ADD COLUMN + ETL | All 4 monthly tables | **P3 — Low** | 2h |
| RISK-2 | Standardize month column naming | Documentation / new column convention | All 4 monthly tables | **P3 — Low** | With RISK-1 |
| RISK-3 | PII in analytics `users` table | Create safe view | `users` | **P3 — Low** | 1h |

---

## Part 5 — Quick Reference: What Each Dashboard Needs Fixed

| Dashboard | Broken by | Fixed by |
|-----------|-----------|----------|
| All dashboards with broker filter | BUG-1 (missing `broker_name`) | Add `broker_name` to `sold_policies_data` |
| Brokers — performance scorecard | BUG-2 (type mismatch join) | Fix `sales_channel_id` type |
| All pages — alert badge | BUG-3 (`total_alerts` missing) | Sum counts in `Layout.tsx` |
| Alerts — declining / stuck (broker filter) | GAP-1 (no channel on daily quotes) | Add `sales_channel_id` to `daily_quote_counts` |
| Funnel — conversion, by-product, stuck quoters | GAP-4/5 (verbose 9-col sums) | Add pre-computed `total_*` columns |
| Agent Analytics — segmentation (Dormant category) | GAP-2 (no monthly login count) | Add `login_count` to agent monthly summary |
| Alerts — inactive agents | GAP-2/3 | Add `login_count` + `last_activity_date` |
| Brokers — sub-channel drill-down (future) | GAP-6 | Add `sub_sales_channel_id` |
