import express from 'express';
import cors from 'cors';
import NodeCache from 'node-cache';
import { query, testConnection } from './db.js';

const app = express();
const PORT = 3001;
const cache = new NodeCache({ checkperiod: 120 });

app.use(cors({
  origin: process.env.VERCEL
    ? true   // allow all origins in production (same-domain via rewrites)
    : 'http://localhost:5173'
}));
app.use(express.json());

// ---------------------------------------------------------------------------
// Filter Helpers
// ---------------------------------------------------------------------------

/** Parse filter query parameters from request */
function parseFilters(req) {
  const { date_range, broker, product, state } = req.query;
  return {
    dateRange: date_range || null,
    broker: broker || null,
    product: product || null,
    state: state || null,
  };
}

/** Build a date interval SQL literal based on date_range param (enum-validated, safe to inline) */
function getDateInterval(dateRange) {
  switch (dateRange) {
    case 'last_30_days':   return "INTERVAL '30 days'";
    case 'last_3_months':  return "INTERVAL '3 months'";
    case 'last_6_months':  return "INTERVAL '6 months'";
    case 'last_12_months': return "INTERVAL '12 months'";
    case 'all_time':       return null;
    default:               return null;
  }
}

/** Return a SQL expression for a YYYY-MM cutoff from a date_range value */
function getMonthCutoff(dateRange) {
  const interval = getDateInterval(dateRange);
  if (!interval) return null;
  return `TO_CHAR(CURRENT_DATE - ${interval}, 'YYYY-MM')`;
}

/**
 * Build extra WHERE clause fragments + params for sold_policies_data.
 * @param {object} filters - parsed filters
 * @param {string} prefix  - table alias prefix including dot, e.g. 's.' or '' for no alias
 * @param {number} startIdx - starting $N parameter index
 * @returns {{ clauses: string[], params: any[], nextIdx: number }}
 */
function buildSoldPolicyFilters(filters, prefix = '', startIdx = 1) {
  const clauses = [];
  const params = [];
  let idx = startIdx;

  if (filters.dateRange && filters.dateRange !== 'all_time') {
    const interval = getDateInterval(filters.dateRange);
    if (interval) {
      clauses.push(`${prefix}sold_date >= (CURRENT_DATE - ${interval})`);
    }
  }
  if (filters.product) {
    clauses.push(`${prefix}product_type = $${idx}`);
    params.push(filters.product);
    idx++;
  }
  if (filters.state) {
    clauses.push(`UPPER(${prefix}policy_holder_state) = UPPER($${idx})`);
    params.push(filters.state);
    idx++;
  }
  if (filters.broker) {
    // sold_policies_data has no broker_name; resolve via sales_channel_user_id → users.fullname
    clauses.push(`${prefix}sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${idx})`);
    params.push(filters.broker);
    idx++;
  }

  return { clauses, params, nextIdx: idx };
}

/**
 * Build extra WHERE clause fragments + params for channel_wise tables.
 * Supports date_range (month cutoff) and broker.
 */
function buildChannelFilters(filters, prefix = '', startIdx = 1, monthCol = 'sold_month') {
  const clauses = [];
  const params = [];
  let idx = startIdx;

  if (filters.dateRange && filters.dateRange !== 'all_time') {
    const cutoff = getMonthCutoff(filters.dateRange);
    if (cutoff) {
      clauses.push(`${prefix}${monthCol} >= ${cutoff}`);
    }
  }
  if (filters.broker) {
    clauses.push(`${prefix}broker_name = $${idx}`);
    params.push(filters.broker);
    idx++;
  }

  return { clauses, params, nextIdx: idx };
}

/**
 * Build extra WHERE clause fragments for agent_wise / activity_month tables.
 * Only date_range applies (month cutoff).
 */
function buildActivityMonthFilter(filters, prefix = '', monthCol = 'activity_month') {
  const clauses = [];
  if (filters.dateRange && filters.dateRange !== 'all_time') {
    const cutoff = getMonthCutoff(filters.dateRange);
    if (cutoff) {
      clauses.push(`${prefix}${monthCol} >= ${cutoff}`);
    }
  }
  return clauses;
}

/**
 * Build extra WHERE clause fragments for daily_quote_counts.
 * Only date_range applies.
 */
function buildQuoteDateFilter(filters, prefix = '') {
  const clauses = [];
  if (filters.dateRange && filters.dateRange !== 'all_time') {
    const interval = getDateInterval(filters.dateRange);
    if (interval) {
      clauses.push(`${prefix}quote_date >= (CURRENT_DATE - ${interval})`);
    }
  }
  return clauses;
}

/** Helper: join clauses with AND, returns '1=1' if empty */
function andJoin(clauses) {
  return clauses.length > 0 ? clauses.join(' AND ') : '1=1';
}

/** Helper: prepend AND to extra clauses for appending to existing WHERE */
function andAppend(clauses) {
  return clauses.length > 0 ? ' AND ' + clauses.join(' AND ') : '';
}

// ---------------------------------------------------------------------------
// channel_wise_monthly_activity_summary — reusable column sum expressions
// These replace channel_wise_monthly_sold_policies throughout the codebase.
// ---------------------------------------------------------------------------

const CH_POLICY_COUNT = `(
  COALESCE(policy_count_2w,0) + COALESCE(policy_count_4w,0) + COALESCE(policy_count_health,0) +
  COALESCE(policy_count_gcv,0) + COALESCE(policy_count_pcv,0) + COALESCE(policy_count_term,0) +
  COALESCE(policy_count_personal_accident,0) + COALESCE(policy_count_savings,0) + COALESCE(policy_count_miscd,0)
)`;

const CH_POLICY_PREMIUM = `(
  COALESCE(policy_premium_2w,0) + COALESCE(policy_premium_4w,0) + COALESCE(policy_premium_health,0) +
  COALESCE(policy_premium_gcv,0) + COALESCE(policy_premium_pcv,0) + COALESCE(policy_premium_term,0) +
  COALESCE(policy_premium_personal_accident,0) + COALESCE(policy_premium_savings,0) + COALESCE(policy_premium_miscd,0)
)`;

const CH_QUOTE_COUNT = `(
  COALESCE(quote_count_2w,0) + COALESCE(quote_count_4w,0) + COALESCE(quote_count_health,0) +
  COALESCE(quote_count_gcv,0) + COALESCE(quote_count_pcv,0) + COALESCE(quote_count_term,0) +
  COALESCE(quote_count_personal_accident,0) + COALESCE(quote_count_savings,0) + COALESCE(quote_count_miscd,0)
)`;

// ---------------------------------------------------------------------------
// Cached handler (filter-aware)
// ---------------------------------------------------------------------------

function cachedHandler(baseCacheKey, ttlSeconds, queryFn) {
  return async (req, res) => {
    try {
      const filters = parseFilters(req);
      const filterSuffix = JSON.stringify(filters);
      const cacheKey = `${baseCacheKey}:${filterSuffix}`;

      const cached = cache.get(cacheKey);
      if (cached) {
        return res.json({
          success: true,
          data: cached.data,
          meta: { rowCount: cached.rowCount, cachedAt: cached.cachedAt, executionTimeMs: 0 },
        });
      }

      const start = Date.now();
      const data = await queryFn(filters);
      const executionTimeMs = Date.now() - start;
      const rowCount = Array.isArray(data) ? data.length : 1;
      const cachedAt = new Date().toISOString();

      cache.set(cacheKey, { data, rowCount, cachedAt }, ttlSeconds);

      return res.json({ success: true, data, meta: { rowCount, cachedAt, executionTimeMs } });
    } catch (err) {
      console.error(`Error in ${baseCacheKey}:`, err);
      return res.status(500).json({ success: false, error: err.message });
    }
  };
}

// ---------------------------------------------------------------------------
// Health
// ---------------------------------------------------------------------------

app.get('/api/health', async (_req, res) => {
  const dbOk = await testConnection();
  res.json({ status: dbOk ? 'ok' : 'db_error', timestamp: new Date().toISOString() });
});

app.post('/api/cache/clear', (_req, res) => {
  cache.flushAll();
  res.json({ success: true, message: 'Cache cleared' });
});

// =========================================================================
// SECTION 1 — Executive  /api/executive
// =========================================================================

// GET /api/executive/kpis  (TTL 900s)
// Filters: date_range overrides the current/prev month logic; product, state, broker on sold_policies_data
app.get(
  '/api/executive/kpis',
  cachedHandler('executive:kpis', 900, async (filters) => {
    // Build sold_policies_data filters (product, state, broker only — date handled specially)
    const spf = buildSoldPolicyFilters({ ...filters, dateRange: null }, '', 1);
    const extraSoldWhere = andAppend(spf.clauses);
    const params = spf.params;

    // Reuse broker $N across daily_quote_counts and agent_wise_monthly_activity_summary CTEs
    const brokerParamIdx = filters.broker ? spf.nextIdx - 1 : null;
    const quoteBrokerClause = brokerParamIdx
      ? ` AND agent_id IN (SELECT u.id FROM users u WHERE u.saleschanneluserid IN (SELECT id FROM users WHERE fullname = $${brokerParamIdx}))`
      : '';
    const activityBrokerClause = brokerParamIdx
      ? ` AND sales_channel_id IN (SELECT id FROM users WHERE fullname = $${brokerParamIdx})`
      : '';

    // If date_range is provided, override cur/prev month logic to use range-based approach
    if (filters.dateRange && filters.dateRange !== 'all_time') {
      const interval = getDateInterval(filters.dateRange);
      // For range-based KPIs: "current" = first half of range, "previous" = second half
      // Simpler: current = the range, previous = the equal range before it
      const sql = `
        WITH cur_policies AS (
          SELECT
            COUNT(*)            AS total_policies,
            COALESCE(SUM(premium_amount), 0) AS total_premium,
            COUNT(DISTINCT agent) AS active_agents,
            CASE WHEN COUNT(*) > 0 THEN ROUND(SUM(premium_amount) / COUNT(*), 2) ELSE 0 END AS avg_ticket
          FROM sold_policies_data
          WHERE sold_date >= (CURRENT_DATE - ${interval})${extraSoldWhere}
        ),
        prev_policies AS (
          SELECT
            COUNT(*)            AS total_policies,
            COALESCE(SUM(premium_amount), 0) AS total_premium,
            COUNT(DISTINCT agent) AS active_agents,
            CASE WHEN COUNT(*) > 0 THEN ROUND(SUM(premium_amount) / COUNT(*), 2) ELSE 0 END AS avg_ticket
          FROM sold_policies_data
          WHERE sold_date >= (CURRENT_DATE - ${interval} - ${interval})
            AND sold_date < (CURRENT_DATE - ${interval})${extraSoldWhere}
        ),
        cur_quotes AS (
          SELECT COALESCE(SUM(quote_count), 0) AS total_quotes
          FROM daily_quote_counts
          WHERE quote_date >= (CURRENT_DATE - ${interval})${quoteBrokerClause}
        ),
        prev_quotes AS (
          SELECT COALESCE(SUM(quote_count), 0) AS total_quotes
          FROM daily_quote_counts
          WHERE quote_date >= (CURRENT_DATE - ${interval} - ${interval})
            AND quote_date < (CURRENT_DATE - ${interval})${quoteBrokerClause}
        ),
        cur_proposals AS (
          SELECT COALESCE(SUM(
            proposal_count_2w + proposal_count_4w + proposal_count_health +
            proposal_count_gcv + proposal_count_pcv + proposal_count_term +
            proposal_count_personal_accident + proposal_count_savings + proposal_count_miscd
          ), 0) AS total_proposals
          FROM agent_wise_monthly_activity_summary
          WHERE activity_month >= TO_CHAR(CURRENT_DATE - ${interval}, 'YYYY-MM')${activityBrokerClause}
        ),
        prev_proposals AS (
          SELECT COALESCE(SUM(
            proposal_count_2w + proposal_count_4w + proposal_count_health +
            proposal_count_gcv + proposal_count_pcv + proposal_count_term +
            proposal_count_personal_accident + proposal_count_savings + proposal_count_miscd
          ), 0) AS total_proposals
          FROM agent_wise_monthly_activity_summary
          WHERE activity_month >= TO_CHAR(CURRENT_DATE - ${interval} - ${interval}, 'YYYY-MM')
            AND activity_month < TO_CHAR(CURRENT_DATE - ${interval}, 'YYYY-MM')${activityBrokerClause}
        )
        SELECT
          cp.total_policies,
          cp.total_premium,
          cp.active_agents,
          cp.avg_ticket,
          cq.total_quotes,
          cprop.total_proposals,
          CASE WHEN cq.total_quotes > 0
            THEN ROUND(cp.total_policies::numeric / cq.total_quotes * 100, 2) ELSE 0
          END AS conversion_rate,
          pp.total_policies  AS prev_total_policies,
          pp.total_premium   AS prev_total_premium,
          pp.active_agents   AS prev_active_agents,
          pp.avg_ticket      AS prev_avg_ticket,
          pq.total_quotes    AS prev_total_quotes,
          pprop.total_proposals AS prev_total_proposals,
          CASE WHEN pq.total_quotes > 0
            THEN ROUND(pp.total_policies::numeric / pq.total_quotes * 100, 2) ELSE 0
          END AS prev_conversion_rate,
          CASE WHEN pp.total_policies > 0
            THEN ROUND((cp.total_policies - pp.total_policies)::numeric / pp.total_policies * 100, 2) ELSE 0
          END AS policies_mom_pct,
          CASE WHEN pp.total_premium > 0
            THEN ROUND((cp.total_premium - pp.total_premium)::numeric / pp.total_premium * 100, 2) ELSE 0
          END AS premium_mom_pct,
          CASE WHEN pp.active_agents > 0
            THEN ROUND((cp.active_agents - pp.active_agents)::numeric / pp.active_agents * 100, 2) ELSE 0
          END AS agents_mom_pct,
          CASE WHEN pp.avg_ticket > 0
            THEN ROUND((cp.avg_ticket - pp.avg_ticket)::numeric / pp.avg_ticket * 100, 2) ELSE 0
          END AS avg_ticket_mom_pct,
          CASE WHEN pq.total_quotes > 0
            THEN ROUND((cq.total_quotes - pq.total_quotes)::numeric / pq.total_quotes * 100, 2) ELSE 0
          END AS quotes_mom_pct
        FROM cur_policies cp, prev_policies pp,
             cur_quotes cq, prev_quotes pq,
             cur_proposals cprop, prev_proposals pprop;
      `;
      const result = await query(sql, params);
      return result.rows[0] || {};
    }

    // Default: original month-based logic with product/state/broker filters
    const sql = `
      WITH months AS (
        SELECT
          TO_CHAR(CURRENT_DATE, 'YYYY-MM') AS cur,
          TO_CHAR(CURRENT_DATE - INTERVAL '1 month', 'YYYY-MM') AS prev
      ),
      cur_policies AS (
        SELECT
          COUNT(*)            AS total_policies,
          COALESCE(SUM(premium_amount), 0) AS total_premium,
          COUNT(DISTINCT agent) AS active_agents,
          CASE WHEN COUNT(*) > 0 THEN ROUND(SUM(premium_amount) / COUNT(*), 2) ELSE 0 END AS avg_ticket
        FROM sold_policies_data, months m
        WHERE TO_CHAR(sold_date, 'YYYY-MM') = m.cur${extraSoldWhere}
      ),
      prev_policies AS (
        SELECT
          COUNT(*)            AS total_policies,
          COALESCE(SUM(premium_amount), 0) AS total_premium,
          COUNT(DISTINCT agent) AS active_agents,
          CASE WHEN COUNT(*) > 0 THEN ROUND(SUM(premium_amount) / COUNT(*), 2) ELSE 0 END AS avg_ticket
        FROM sold_policies_data, months m
        WHERE TO_CHAR(sold_date, 'YYYY-MM') = m.prev${extraSoldWhere}
      ),
      cur_quotes AS (
        SELECT COALESCE(SUM(quote_count), 0) AS total_quotes
        FROM daily_quote_counts, months m
        WHERE TO_CHAR(quote_date, 'YYYY-MM') = m.cur${quoteBrokerClause}
      ),
      prev_quotes AS (
        SELECT COALESCE(SUM(quote_count), 0) AS total_quotes
        FROM daily_quote_counts, months m
        WHERE TO_CHAR(quote_date, 'YYYY-MM') = m.prev${quoteBrokerClause}
      ),
      cur_proposals AS (
        SELECT COALESCE(SUM(
          proposal_count_2w + proposal_count_4w + proposal_count_health +
          proposal_count_gcv + proposal_count_pcv + proposal_count_term +
          proposal_count_personal_accident + proposal_count_savings + proposal_count_miscd
        ), 0) AS total_proposals
        FROM agent_wise_monthly_activity_summary, months m
        WHERE activity_month = m.cur${activityBrokerClause}
      ),
      prev_proposals AS (
        SELECT COALESCE(SUM(
          proposal_count_2w + proposal_count_4w + proposal_count_health +
          proposal_count_gcv + proposal_count_pcv + proposal_count_term +
          proposal_count_personal_accident + proposal_count_savings + proposal_count_miscd
        ), 0) AS total_proposals
        FROM agent_wise_monthly_activity_summary, months m
        WHERE activity_month = m.prev${activityBrokerClause}
      )
      SELECT
        cp.total_policies,
        cp.total_premium,
        cp.active_agents,
        cp.avg_ticket,
        cq.total_quotes,
        cprop.total_proposals,
        CASE WHEN cq.total_quotes > 0
          THEN ROUND(cp.total_policies::numeric / cq.total_quotes * 100, 2) ELSE 0
        END AS conversion_rate,
        pp.total_policies  AS prev_total_policies,
        pp.total_premium   AS prev_total_premium,
        pp.active_agents   AS prev_active_agents,
        pp.avg_ticket      AS prev_avg_ticket,
        pq.total_quotes    AS prev_total_quotes,
        pprop.total_proposals AS prev_total_proposals,
        CASE WHEN pq.total_quotes > 0
          THEN ROUND(pp.total_policies::numeric / pq.total_quotes * 100, 2) ELSE 0
        END AS prev_conversion_rate,
        CASE WHEN pp.total_policies > 0
          THEN ROUND((cp.total_policies - pp.total_policies)::numeric / pp.total_policies * 100, 2) ELSE 0
        END AS policies_mom_pct,
        CASE WHEN pp.total_premium > 0
          THEN ROUND((cp.total_premium - pp.total_premium)::numeric / pp.total_premium * 100, 2) ELSE 0
        END AS premium_mom_pct,
        CASE WHEN pp.active_agents > 0
          THEN ROUND((cp.active_agents - pp.active_agents)::numeric / pp.active_agents * 100, 2) ELSE 0
        END AS agents_mom_pct,
        CASE WHEN pp.avg_ticket > 0
          THEN ROUND((cp.avg_ticket - pp.avg_ticket)::numeric / pp.avg_ticket * 100, 2) ELSE 0
        END AS avg_ticket_mom_pct,
        CASE WHEN pq.total_quotes > 0
          THEN ROUND((cq.total_quotes - pq.total_quotes)::numeric / pq.total_quotes * 100, 2) ELSE 0
        END AS quotes_mom_pct
      FROM cur_policies cp, prev_policies pp,
           cur_quotes cq, prev_quotes pq,
           cur_proposals cprop, prev_proposals pprop;
    `;
    const result = await query(sql, params);
    return result.rows[0] || {};
  }),
);

// GET /api/executive/growth  (TTL 900s)
// Filters: date_range replaces 12-month default; product, state, broker on sold_policies_data
app.get(
  '/api/executive/growth',
  cachedHandler('executive:growth', 900, async (filters) => {
    const dateInterval = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getDateInterval(filters.dateRange)
      : "INTERVAL '12 months'";
    const dateClause = dateInterval ? `sold_date >= (CURRENT_DATE - ${dateInterval})` : '1=1';

    const extraClauses = [];
    const params = [];
    let idx = 1;
    if (filters.product) { extraClauses.push(`product_type = $${idx++}`); params.push(filters.product); }
    if (filters.state) { extraClauses.push(`UPPER(policy_holder_state) = UPPER($${idx++})`); params.push(filters.state); }
    if (filters.broker) { extraClauses.push(`sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${idx++})`); params.push(filters.broker); }

    const whereClause = [dateClause, ...extraClauses].join(' AND ');

    const sql = `
      SELECT
        TO_CHAR(sold_date, 'YYYY-MM') AS month,
        COUNT(*)                       AS policies,
        COUNT(DISTINCT agent)          AS active_agents,
        COALESCE(SUM(premium_amount), 0) AS total_premium
      FROM sold_policies_data
      WHERE ${whereClause}
      GROUP BY TO_CHAR(sold_date, 'YYYY-MM')
      ORDER BY month;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// GET /api/executive/concentration  (TTL 3600s)
// Filters: date_range + broker on channel_wise; date_range + product/state/broker on sold_policies_data
app.get(
  '/api/executive/concentration',
  cachedHandler('executive:concentration', 3600, async (filters) => {
    // Channel-wise date cutoff
    const channelMonthCutoff = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getMonthCutoff(filters.dateRange)
      : "TO_CHAR(CURRENT_DATE - INTERVAL '6 months', 'YYYY-MM')";
    const channelDateClause = channelMonthCutoff ? `sold_month >= ${channelMonthCutoff}` : '1=1';

    // Sold_policies_data date cutoff
    const soldInterval = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getDateInterval(filters.dateRange)
      : "INTERVAL '6 months'";
    const soldDateClause = soldInterval ? `sold_date >= (CURRENT_DATE - ${soldInterval})` : '1=1';

    // Broker filter for channel_wise
    const channelBrokerClauses = [];
    const channelParams = [];
    let cidx = 1;
    if (filters.broker) {
      channelBrokerClauses.push(`broker_name = $${cidx++}`);
      channelParams.push(filters.broker);
    }
    const channelExtraWhere = channelBrokerClauses.length > 0 ? ' AND ' + channelBrokerClauses.join(' AND ') : '';

    // Extra filters for sold_policies_data
    const soldClauses = [];
    const soldParams = [];
    let sidx = channelParams.length + 1;
    if (filters.product) { soldClauses.push(`product_type = $${sidx++}`); soldParams.push(filters.product); }
    if (filters.state) { soldClauses.push(`UPPER(policy_holder_state) = UPPER($${sidx++})`); soldParams.push(filters.state); }
    if (filters.broker) { soldClauses.push(`sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${sidx++})`); soldParams.push(filters.broker); }
    const soldExtraWhere = soldClauses.length > 0 ? ' AND ' + soldClauses.join(' AND ') : '';

    const allParams = [...channelParams, ...soldParams];

    const sql = `
      WITH total AS (
        SELECT COALESCE(SUM(${CH_POLICY_PREMIUM}), 0) AS grand_total
        FROM channel_wise_monthly_activity_summary
        WHERE ${channelDateClause}${channelExtraWhere}
      ),
      broker_totals AS (
        SELECT broker_name, SUM(${CH_POLICY_PREMIUM}) AS broker_premium
        FROM channel_wise_monthly_activity_summary
        WHERE ${channelDateClause}${channelExtraWhere}
        GROUP BY broker_name
        ORDER BY broker_premium DESC
      ),
      top_broker AS (
        SELECT broker_name, broker_premium,
               CASE WHEN t.grand_total > 0
                 THEN ROUND(broker_premium::numeric / t.grand_total * 100, 2)
                 ELSE 0
               END AS pct_of_total
        FROM broker_totals, total t
        LIMIT 1
      ),
      top7_brokers_detail AS (
        SELECT broker_name, broker_premium
        FROM broker_totals
        LIMIT 7
      ),
      agent_totals AS (
        SELECT agent, SUM(premium_amount) AS agent_premium
        FROM sold_policies_data
        WHERE ${soldDateClause}${soldExtraWhere}
        GROUP BY agent
        ORDER BY agent_premium DESC
      ),
      total_agent_premium AS (
        SELECT COALESCE(SUM(premium_amount), 0) AS grand_total
        FROM sold_policies_data
        WHERE ${soldDateClause}${soldExtraWhere}
      ),
      top10_agents AS (
        SELECT SUM(agent_premium) AS top10_premium
        FROM (SELECT agent_premium FROM agent_totals LIMIT 10) sub
      ),
      top5_agents_detail AS (
        SELECT at.agent AS agent_id, u.fullname AS agent_name, at.agent_premium
        FROM agent_totals at
        LEFT JOIN users u ON u.id = at.agent
        LIMIT 5
      )
      SELECT
        tb.broker_name       AS top_broker_name,
        tb.broker_premium    AS top_broker_premium,
        tb.pct_of_total      AS top_broker_pct,
        CASE WHEN tap.grand_total > 0
          THEN ROUND(t10.top10_premium::numeric / tap.grand_total * 100, 2)
          ELSE 0
        END AS top10_agents_pct,
        t10.top10_premium    AS top10_agents_premium,
        tap.grand_total      AS total_6m_agent_premium,
        (SELECT json_agg(row_to_json(t5)) FROM top5_agents_detail t5) AS top5_agents,
        (SELECT json_agg(row_to_json(t7)) FROM top7_brokers_detail t7) AS top7_brokers
      FROM top_broker tb, top10_agents t10, total_agent_premium tap;
    `;
    const result = await query(sql, allParams);
    return result.rows[0] || {};
  }),
);

// =========================================================================
// SECTION 2 — Agents  /api/agents
// =========================================================================

// GET /api/agents/segmentation  (TTL 86400s)
// Filters: date_range adjusts the 3-month window; product, state, broker on sold_policies_data
app.get(
  '/api/agents/segmentation',
  cachedHandler('agents:segmentation', 86400, async (filters) => {
    // Determine the months to look at based on date_range
    // Default: 3 months (m0, m1, m2). With date_range, we expand/contract.
    const activityCutoff = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getMonthCutoff(filters.dateRange)
      : null;
    const quoteDateFilter = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getDateInterval(filters.dateRange)
      : null;

    if (activityCutoff) {
      // Use range-based approach instead of 3 specific months
      const quoteInterval = quoteDateFilter || "INTERVAL '3 months'";

      // Build product/state/broker filters for sold_policies_data (date handled separately)
      const spf = buildSoldPolicyFilters({ ...filters, dateRange: null }, '', 1);
      const extraSoldWhere = andAppend(spf.clauses);
      const params = spf.params;

      const sql = `
        WITH agent_sales AS (
          SELECT
            agent,
            COUNT(*) FILTER (WHERE TO_CHAR(sold_date, 'YYYY-MM') = TO_CHAR(CURRENT_DATE, 'YYYY-MM')) AS sales_m0,
            COUNT(*) AS sales_range,
            COALESCE(SUM(premium_amount), 0) AS premium_range
          FROM sold_policies_data
          WHERE sold_date >= (CURRENT_DATE - ${quoteInterval})${extraSoldWhere}
          GROUP BY agent
        ),
        agent_quotes AS (
          SELECT
            agent_id,
            COALESCE(SUM(quote_count), 0) AS quotes_range
          FROM daily_quote_counts
          WHERE quote_date >= (CURRENT_DATE - ${quoteInterval})
          GROUP BY agent_id
        ),
        all_agents AS (
          SELECT id AS agent_id FROM users
          WHERE roleid IS NOT NULL AND saleschanneluserid IS NOT NULL AND deletedat IS NULL
        ),
        classified AS (
          SELECT
            a.agent_id,
            COALESCE(s.sales_m0, 0)      AS sales_m0,
            COALESCE(s.sales_range, 0)    AS sales_3m,
            COALESCE(s.premium_range, 0)  AS premium_3m,
            COALESCE(q.quotes_range, 0)   AS quotes_3m,
            CASE
              WHEN COALESCE(s.sales_m0, 0) >= 10 THEN 'Star'
              WHEN COALESCE(s.sales_range, 0) >= 5  THEN 'Rising'
              WHEN COALESCE(s.sales_range, 0) >= 1 OR COALESCE(q.quotes_range, 0) >= 5 THEN 'Occasional'
              WHEN COALESCE(q.quotes_range, 0) > 0  THEN 'Dormant'
              ELSE 'Dead'
            END AS segment
          FROM all_agents a
          LEFT JOIN agent_sales s ON s.agent = a.agent_id
          LEFT JOIN agent_quotes q ON q.agent_id = a.agent_id
        )
        SELECT
          segment,
          COUNT(*)                       AS agent_count,
          COALESCE(SUM(premium_3m), 0)   AS total_premium,
          COALESCE(SUM(sales_3m), 0)     AS total_sales,
          COALESCE(SUM(quotes_3m), 0)    AS total_quotes
        FROM classified
        GROUP BY segment
        ORDER BY
          CASE segment
            WHEN 'Star' THEN 1 WHEN 'Rising' THEN 2
            WHEN 'Occasional' THEN 3 WHEN 'Dormant' THEN 4 WHEN 'Dead' THEN 5
          END;
      `;
      const result = await query(sql, params);
      return result.rows;
    }

    // Default: original 3-month logic
    // Build product/state/broker filters for sold_policies_data
    const spf = buildSoldPolicyFilters({ ...filters, dateRange: null }, '', 1);
    const extraSoldWhere = andAppend(spf.clauses);
    const params = spf.params;

    const sql = `
      WITH months AS (
        SELECT
          TO_CHAR(CURRENT_DATE, 'YYYY-MM')                          AS m0,
          TO_CHAR(CURRENT_DATE - INTERVAL '1 month', 'YYYY-MM')     AS m1,
          TO_CHAR(CURRENT_DATE - INTERVAL '2 months', 'YYYY-MM')    AS m2
      ),
      agent_sales AS (
        SELECT
          agent,
          COUNT(*) FILTER (WHERE TO_CHAR(sold_date, 'YYYY-MM') = m.m0) AS sales_m0,
          COUNT(*) AS sales_3m,
          COALESCE(SUM(premium_amount), 0) AS premium_3m
        FROM sold_policies_data, months m
        WHERE TO_CHAR(sold_date, 'YYYY-MM') IN (m.m0, m.m1, m.m2)${extraSoldWhere}
        GROUP BY agent, m.m0
      ),
      agent_quotes AS (
        SELECT
          agent_id,
          COALESCE(SUM(quote_count), 0) AS quotes_3m
        FROM daily_quote_counts, months m
        WHERE TO_CHAR(quote_date, 'YYYY-MM') IN (m.m0, m.m1, m.m2)
        GROUP BY agent_id
      ),
      all_agents AS (
        SELECT id AS agent_id FROM users
        WHERE roleid IS NOT NULL AND saleschanneluserid IS NOT NULL AND deletedat IS NULL
      ),
      classified AS (
        SELECT
          a.agent_id,
          COALESCE(s.sales_m0, 0)   AS sales_m0,
          COALESCE(s.sales_3m, 0)   AS sales_3m,
          COALESCE(s.premium_3m, 0) AS premium_3m,
          COALESCE(q.quotes_3m, 0)  AS quotes_3m,
          CASE
            WHEN COALESCE(s.sales_m0, 0) >= 10 THEN 'Star'
            WHEN COALESCE(s.sales_3m, 0) >= 5  THEN 'Rising'
            WHEN COALESCE(s.sales_3m, 0) >= 1 OR COALESCE(q.quotes_3m, 0) >= 5 THEN 'Occasional'
            WHEN COALESCE(q.quotes_3m, 0) > 0  THEN 'Dormant'
            ELSE 'Dead'
          END AS segment
        FROM all_agents a
        LEFT JOIN agent_sales s ON s.agent = a.agent_id
        LEFT JOIN agent_quotes q ON q.agent_id = a.agent_id
      )
      SELECT
        segment,
        COUNT(*)                       AS agent_count,
        COALESCE(SUM(premium_3m), 0)   AS total_premium,
        COALESCE(SUM(sales_3m), 0)     AS total_sales,
        COALESCE(SUM(quotes_3m), 0)    AS total_quotes
      FROM classified
      GROUP BY segment
      ORDER BY
        CASE segment
          WHEN 'Star' THEN 1 WHEN 'Rising' THEN 2
          WHEN 'Occasional' THEN 3 WHEN 'Dormant' THEN 4 WHEN 'Dead' THEN 5
        END;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// GET /api/agents/activation  (TTL 86400s)
// Filters: date_range adjusts the 18-month cohort window; product, state, broker on sold_policies_data
app.get(
  '/api/agents/activation',
  cachedHandler('agents:activation', 86400, async (filters) => {
    const cohortInterval = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getDateInterval(filters.dateRange)
      : "INTERVAL '18 months'";
    const cohortClause = cohortInterval ? `u.createdat >= (CURRENT_DATE - ${cohortInterval})` : '1=1';

    // Build product/state/broker filters for sold_policies_data
    const spf = buildSoldPolicyFilters({ ...filters, dateRange: null }, 's.', 1);
    const extraSoldWhere = andAppend(spf.clauses);
    const params = spf.params;

    const sql = `
      SELECT
        TO_CHAR(u.createdat, 'YYYY-MM') AS join_month,
        COUNT(DISTINCT u.id)            AS total_joined,
        COUNT(DISTINCT s.agent)         AS ever_sold,
        CASE WHEN COUNT(DISTINCT u.id) > 0
          THEN ROUND(COUNT(DISTINCT s.agent)::numeric / COUNT(DISTINCT u.id) * 100, 2)
          ELSE 0
        END AS activation_rate
      FROM users u
      LEFT JOIN sold_policies_data s ON u.id = s.agent${extraSoldWhere}
      WHERE ${cohortClause}
        AND u.deletedat IS NULL
      GROUP BY TO_CHAR(u.createdat, 'YYYY-MM')
      ORDER BY join_month;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// GET /api/agents/performance-distribution  (TTL 86400s)
// Filters: date_range adjusts the 3-month window; product, state, broker on sold_policies_data
app.get(
  '/api/agents/performance-distribution',
  cachedHandler('agents:performance-distribution', 86400, async (filters) => {
    const dateInterval = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getDateInterval(filters.dateRange)
      : "INTERVAL '3 months'";
    const dateClause = dateInterval ? `sold_date >= (CURRENT_DATE - ${dateInterval})` : '1=1';

    // Build product/state/broker filters for sold_policies_data
    const spf = buildSoldPolicyFilters({ ...filters, dateRange: null }, '', 1);
    const extraSoldWhere = andAppend(spf.clauses);
    const params = spf.params;

    const sql = `
      WITH agent_counts AS (
        SELECT agent, COUNT(*) AS policy_count
        FROM sold_policies_data
        WHERE ${dateClause}${extraSoldWhere}
        GROUP BY agent
      ),
      all_agents AS (
        SELECT id AS agent_id FROM users
        WHERE roleid IS NOT NULL AND saleschanneluserid IS NOT NULL AND deletedat IS NULL
      ),
      bucketed AS (
        SELECT
          CASE
            WHEN COALESCE(ac.policy_count, 0) = 0  THEN '0 policies'
            WHEN ac.policy_count BETWEEN 1 AND 2    THEN '1-2 policies'
            WHEN ac.policy_count BETWEEN 3 AND 5    THEN '3-5 policies'
            WHEN ac.policy_count BETWEEN 6 AND 10   THEN '6-10 policies'
            ELSE '10+ policies'
          END AS bucket,
          CASE
            WHEN COALESCE(ac.policy_count, 0) = 0  THEN 0
            WHEN ac.policy_count BETWEEN 1 AND 2    THEN 1
            WHEN ac.policy_count BETWEEN 3 AND 5    THEN 2
            WHEN ac.policy_count BETWEEN 6 AND 10   THEN 3
            ELSE 4
          END AS sort_order
        FROM all_agents a
        LEFT JOIN agent_counts ac ON ac.agent = a.agent_id
      )
      SELECT bucket, COUNT(*) AS agent_count, sort_order
      FROM bucketed
      GROUP BY bucket, sort_order
      ORDER BY sort_order;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// =========================================================================
// SECTION 3 — Funnel  /api/funnel
// =========================================================================

// GET /api/funnel/conversion  (TTL 3600s)
// Filters: date_range adjusts the 6-month window on activity_month
app.get(
  '/api/funnel/conversion',
  cachedHandler('funnel:conversion', 3600, async (filters) => {
    const monthCutoff = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getMonthCutoff(filters.dateRange)
      : "TO_CHAR(CURRENT_DATE - INTERVAL '6 months', 'YYYY-MM')";
    const dateClause = monthCutoff ? `activity_month >= ${monthCutoff}` : '1=1';

    // Broker filter: agent_wise_monthly_activity_summary.sales_channel_id → users.id
    const brokerParams = [];
    let brokerClause = '';
    if (filters.broker) {
      brokerClause = ` AND sales_channel_id IN (SELECT id FROM users WHERE fullname = $1)`;
      brokerParams.push(filters.broker);
    }

    const sql = `
      SELECT
        activity_month,
        SUM(quote_count_2w + quote_count_4w + quote_count_health +
            quote_count_gcv + quote_count_pcv + quote_count_term +
            quote_count_personal_accident + quote_count_savings + quote_count_miscd
        ) AS total_quotes,
        SUM(proposal_count_2w + proposal_count_4w + proposal_count_health +
            proposal_count_gcv + proposal_count_pcv + proposal_count_term +
            proposal_count_personal_accident + proposal_count_savings + proposal_count_miscd
        ) AS total_proposals,
        SUM(policy_count_2w + policy_count_4w + policy_count_health +
            policy_count_gcv + policy_count_pcv + policy_count_term +
            policy_count_personal_accident + policy_count_savings + policy_count_miscd
        ) AS total_policies,
        CASE WHEN SUM(quote_count_2w + quote_count_4w + quote_count_health +
                      quote_count_gcv + quote_count_pcv + quote_count_term +
                      quote_count_personal_accident + quote_count_savings + quote_count_miscd) > 0
          THEN ROUND(
            SUM(proposal_count_2w + proposal_count_4w + proposal_count_health +
                proposal_count_gcv + proposal_count_pcv + proposal_count_term +
                proposal_count_personal_accident + proposal_count_savings + proposal_count_miscd)::numeric
            / SUM(quote_count_2w + quote_count_4w + quote_count_health +
                  quote_count_gcv + quote_count_pcv + quote_count_term +
                  quote_count_personal_accident + quote_count_savings + quote_count_miscd) * 100, 2)
          ELSE 0
        END AS quote_to_proposal_rate,
        CASE WHEN SUM(proposal_count_2w + proposal_count_4w + proposal_count_health +
                      proposal_count_gcv + proposal_count_pcv + proposal_count_term +
                      proposal_count_personal_accident + proposal_count_savings + proposal_count_miscd) > 0
          THEN ROUND(
            SUM(policy_count_2w + policy_count_4w + policy_count_health +
                policy_count_gcv + policy_count_pcv + policy_count_term +
                policy_count_personal_accident + policy_count_savings + policy_count_miscd)::numeric
            / SUM(proposal_count_2w + proposal_count_4w + proposal_count_health +
                  proposal_count_gcv + proposal_count_pcv + proposal_count_term +
                  proposal_count_personal_accident + proposal_count_savings + proposal_count_miscd) * 100, 2)
          ELSE 0
        END AS proposal_to_policy_rate,
        CASE WHEN SUM(quote_count_2w + quote_count_4w + quote_count_health +
                      quote_count_gcv + quote_count_pcv + quote_count_term +
                      quote_count_personal_accident + quote_count_savings + quote_count_miscd) > 0
          THEN ROUND(
            SUM(policy_count_2w + policy_count_4w + policy_count_health +
                policy_count_gcv + policy_count_pcv + policy_count_term +
                policy_count_personal_accident + policy_count_savings + policy_count_miscd)::numeric
            / SUM(quote_count_2w + quote_count_4w + quote_count_health +
                  quote_count_gcv + quote_count_pcv + quote_count_term +
                  quote_count_personal_accident + quote_count_savings + quote_count_miscd) * 100, 2)
          ELSE 0
        END AS overall_conversion_rate
      FROM agent_wise_monthly_activity_summary
      WHERE ${dateClause}${brokerClause}
      GROUP BY activity_month
      ORDER BY activity_month;
    `;
    const result = await query(sql, brokerParams);
    return result.rows;
  }),
);

// GET /api/funnel/stuck-quoters  (TTL 14400s)
// Filters: date_range adjusts the 2-month window
app.get(
  '/api/funnel/stuck-quoters',
  cachedHandler('funnel:stuck-quoters', 14400, async (filters) => {
    const monthCutoff = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getMonthCutoff(filters.dateRange)
      : "TO_CHAR(CURRENT_DATE - INTERVAL '2 months', 'YYYY-MM')";
    const dateClause = monthCutoff ? `activity_month >= ${monthCutoff}` : '1=1';

    // Broker filter via sales_channel_id → users.id
    const brokerParams = [];
    let brokerClause = '';
    if (filters.broker) {
      brokerClause = ` AND sales_channel_id IN (SELECT id FROM users WHERE fullname = $1)`;
      brokerParams.push(filters.broker);
    }

    const sql = `
      WITH recent AS (
        SELECT
          agent_id,
          SUM(quote_count_2w + quote_count_4w + quote_count_health +
              quote_count_gcv + quote_count_pcv + quote_count_term +
              quote_count_personal_accident + quote_count_savings + quote_count_miscd
          ) AS total_quotes,
          SUM(policy_count_2w + policy_count_4w + policy_count_health +
              policy_count_gcv + policy_count_pcv + policy_count_term +
              policy_count_personal_accident + policy_count_savings + policy_count_miscd
          ) AS total_policies
        FROM agent_wise_monthly_activity_summary
        WHERE ${dateClause}${brokerClause}
        GROUP BY agent_id
        HAVING SUM(quote_count_2w + quote_count_4w + quote_count_health +
                   quote_count_gcv + quote_count_pcv + quote_count_term +
                   quote_count_personal_accident + quote_count_savings + quote_count_miscd) > 0
           AND SUM(policy_count_2w + policy_count_4w + policy_count_health +
                   policy_count_gcv + policy_count_pcv + policy_count_term +
                   policy_count_personal_accident + policy_count_savings + policy_count_miscd) = 0
      )
      SELECT
        r.agent_id,
        u.fullname AS agent_name,
        u.phone,
        r.total_quotes,
        r.total_policies
      FROM recent r
      LEFT JOIN users u ON u.id = r.agent_id
      ORDER BY r.total_quotes DESC
      LIMIT 50;
    `;
    const result = await query(sql, brokerParams);
    return result.rows;
  }),
);

// GET /api/funnel/by-product  (TTL 3600s)
// Filters: date_range adjusts the 3-month window; product filter narrows to specific product
app.get(
  '/api/funnel/by-product',
  cachedHandler('funnel:by-product', 3600, async (filters) => {
    const monthCutoff = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getMonthCutoff(filters.dateRange)
      : "TO_CHAR(CURRENT_DATE - INTERVAL '3 months', 'YYYY-MM')";
    const dateClause = monthCutoff ? `activity_month >= ${monthCutoff}` : '1=1';

    // Broker filter ($1 when present); product filter follows ($2 if broker present, $1 otherwise)
    const params = [];
    let idx = 1;
    let brokerClause = '';
    if (filters.broker) {
      brokerClause = ` AND sales_channel_id IN (SELECT id FROM users WHERE fullname = $${idx++})`;
      params.push(filters.broker);
    }
    const productFilter = filters.product ? `WHERE product_type = $${idx++}` : '';
    if (filters.product) params.push(filters.product);

    const rowWhere = `${dateClause}${brokerClause}`;

    const sql = `
      WITH raw_data AS (
        SELECT
          'Two Wheeler' AS product_type,
          COALESCE(SUM(quote_count_2w), 0) AS quotes,
          COALESCE(SUM(proposal_count_2w), 0) AS proposals,
          COALESCE(SUM(policy_count_2w), 0) AS policies
        FROM agent_wise_monthly_activity_summary
        WHERE ${rowWhere}

        UNION ALL SELECT 'Four Wheeler',
          COALESCE(SUM(quote_count_4w), 0),
          COALESCE(SUM(proposal_count_4w), 0),
          COALESCE(SUM(policy_count_4w), 0)
        FROM agent_wise_monthly_activity_summary
        WHERE ${rowWhere}

        UNION ALL SELECT 'Health',
          COALESCE(SUM(quote_count_health), 0),
          COALESCE(SUM(proposal_count_health), 0),
          COALESCE(SUM(policy_count_health), 0)
        FROM agent_wise_monthly_activity_summary
        WHERE ${rowWhere}

        UNION ALL SELECT 'GCV',
          COALESCE(SUM(quote_count_gcv), 0),
          COALESCE(SUM(proposal_count_gcv), 0),
          COALESCE(SUM(policy_count_gcv), 0)
        FROM agent_wise_monthly_activity_summary
        WHERE ${rowWhere}

        UNION ALL SELECT 'PCV',
          COALESCE(SUM(quote_count_pcv), 0),
          COALESCE(SUM(proposal_count_pcv), 0),
          COALESCE(SUM(policy_count_pcv), 0)
        FROM agent_wise_monthly_activity_summary
        WHERE ${rowWhere}

        UNION ALL SELECT 'Term Life',
          COALESCE(SUM(quote_count_term), 0),
          COALESCE(SUM(proposal_count_term), 0),
          COALESCE(SUM(policy_count_term), 0)
        FROM agent_wise_monthly_activity_summary
        WHERE ${rowWhere}

        UNION ALL SELECT 'Personal Accident',
          COALESCE(SUM(quote_count_personal_accident), 0),
          COALESCE(SUM(proposal_count_personal_accident), 0),
          COALESCE(SUM(policy_count_personal_accident), 0)
        FROM agent_wise_monthly_activity_summary
        WHERE ${rowWhere}

        UNION ALL SELECT 'Savings',
          COALESCE(SUM(quote_count_savings), 0),
          COALESCE(SUM(proposal_count_savings), 0),
          COALESCE(SUM(policy_count_savings), 0)
        FROM agent_wise_monthly_activity_summary
        WHERE ${rowWhere}

        UNION ALL SELECT 'Misc / D',
          COALESCE(SUM(quote_count_miscd), 0),
          COALESCE(SUM(proposal_count_miscd), 0),
          COALESCE(SUM(policy_count_miscd), 0)
        FROM agent_wise_monthly_activity_summary
        WHERE ${rowWhere}
      )
      SELECT * FROM raw_data
      ${productFilter}
      ORDER BY policies DESC;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// =========================================================================
// SECTION 4 — Products  /api/products
// =========================================================================

// GET /api/products/mix  (TTL 86400s)
// Filters: all 4 on sold_policies_data
app.get(
  '/api/products/mix',
  cachedHandler('products:mix', 86400, async (filters) => {
    const dateInterval = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getDateInterval(filters.dateRange)
      : "INTERVAL '6 months'";
    const dateClause = dateInterval ? `sold_date >= (CURRENT_DATE - ${dateInterval})` : '1=1';

    const extraClauses = [];
    const params = [];
    let idx = 1;
    if (filters.product) { extraClauses.push(`product_type = $${idx++}`); params.push(filters.product); }
    if (filters.state) { extraClauses.push(`UPPER(policy_holder_state) = UPPER($${idx++})`); params.push(filters.state); }
    if (filters.broker) { extraClauses.push(`sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${idx++})`); params.push(filters.broker); }

    const whereClause = [dateClause, ...extraClauses].join(' AND ');

    const sql = `
      WITH product_stats AS (
        SELECT
          product_type,
          COUNT(*)                           AS policy_count,
          COALESCE(SUM(premium_amount), 0)   AS total_premium,
          ROUND(AVG(premium_amount), 2)      AS avg_ticket
        FROM sold_policies_data
        WHERE ${whereClause}
        GROUP BY product_type
      ),
      grand AS (
        SELECT SUM(total_premium) AS grand_total FROM product_stats
      )
      SELECT
        ps.product_type,
        ps.policy_count,
        ps.total_premium,
        ps.avg_ticket,
        CASE WHEN g.grand_total > 0
          THEN ROUND(ps.total_premium::numeric / g.grand_total * 100, 2)
          ELSE 0
        END AS pct_of_total
      FROM product_stats ps, grand g
      ORDER BY ps.total_premium DESC;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// GET /api/products/trend  (TTL 86400s)
// Filters: date_range, broker (via sales_channel_id), product (outer filter)
// Source: channel_wise_monthly_activity_summary unpivoted via UNION ALL (replaces category_wise_monthly_sold_policies)
app.get(
  '/api/products/trend',
  cachedHandler('products:trend', 86400, async (filters) => {
    const monthCutoff = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getMonthCutoff(filters.dateRange)
      : "TO_CHAR(CURRENT_DATE - INTERVAL '12 months', 'YYYY-MM')";
    const dateClause = monthCutoff ? `sold_month >= ${monthCutoff}` : '1=1';

    // Broker filter goes first ($1), product filter follows in outer WHERE
    const params = [];
    let idx = 1;
    let brokerClause = '';
    if (filters.broker) {
      brokerClause = ` AND sales_channel_id IN (SELECT id FROM users WHERE fullname = $${idx++})`;
      params.push(filters.broker);
    }
    const productFilter = filters.product ? `WHERE product_type = $${idx++}` : '';
    if (filters.product) params.push(filters.product);

    const rowWhere = `${dateClause}${brokerClause}`;

    const sql = `
      WITH raw_data AS (
        SELECT 'Two Wheeler' AS product_type, sold_month,
               COALESCE(SUM(policy_count_2w), 0) AS policy_count,
               COALESCE(SUM(policy_premium_2w), 0) AS total_premium
        FROM channel_wise_monthly_activity_summary WHERE ${rowWhere} GROUP BY sold_month
        UNION ALL
        SELECT 'Four Wheeler', sold_month,
               COALESCE(SUM(policy_count_4w), 0), COALESCE(SUM(policy_premium_4w), 0)
        FROM channel_wise_monthly_activity_summary WHERE ${rowWhere} GROUP BY sold_month
        UNION ALL
        SELECT 'Health', sold_month,
               COALESCE(SUM(policy_count_health), 0), COALESCE(SUM(policy_premium_health), 0)
        FROM channel_wise_monthly_activity_summary WHERE ${rowWhere} GROUP BY sold_month
        UNION ALL
        SELECT 'GCV', sold_month,
               COALESCE(SUM(policy_count_gcv), 0), COALESCE(SUM(policy_premium_gcv), 0)
        FROM channel_wise_monthly_activity_summary WHERE ${rowWhere} GROUP BY sold_month
        UNION ALL
        SELECT 'PCV', sold_month,
               COALESCE(SUM(policy_count_pcv), 0), COALESCE(SUM(policy_premium_pcv), 0)
        FROM channel_wise_monthly_activity_summary WHERE ${rowWhere} GROUP BY sold_month
        UNION ALL
        SELECT 'Term Life', sold_month,
               COALESCE(SUM(policy_count_term), 0), COALESCE(SUM(policy_premium_term), 0)
        FROM channel_wise_monthly_activity_summary WHERE ${rowWhere} GROUP BY sold_month
        UNION ALL
        SELECT 'Personal Accident', sold_month,
               COALESCE(SUM(policy_count_personal_accident), 0), COALESCE(SUM(policy_premium_personal_accident), 0)
        FROM channel_wise_monthly_activity_summary WHERE ${rowWhere} GROUP BY sold_month
        UNION ALL
        SELECT 'Savings', sold_month,
               COALESCE(SUM(policy_count_savings), 0), COALESCE(SUM(policy_premium_savings), 0)
        FROM channel_wise_monthly_activity_summary WHERE ${rowWhere} GROUP BY sold_month
        UNION ALL
        SELECT 'Misc / D', sold_month,
               COALESCE(SUM(policy_count_miscd), 0), COALESCE(SUM(policy_premium_miscd), 0)
        FROM channel_wise_monthly_activity_summary WHERE ${rowWhere} GROUP BY sold_month
      )
      SELECT product_type, sold_month, policy_count, total_premium
      FROM raw_data
      ${productFilter}
      ORDER BY sold_month, product_type;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// GET /api/products/business-type  (TTL 86400s)
// Filters: date_range replaces 12 months; product, state, broker on sold_policies_data
app.get(
  '/api/products/business-type',
  cachedHandler('products:business-type', 86400, async (filters) => {
    const dateInterval = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getDateInterval(filters.dateRange)
      : "INTERVAL '12 months'";
    const dateClause = dateInterval ? `sold_date >= (CURRENT_DATE - ${dateInterval})` : '1=1';

    const extraClauses = [];
    const params = [];
    let idx = 1;
    if (filters.product) { extraClauses.push(`product_type = $${idx++}`); params.push(filters.product); }
    if (filters.state) { extraClauses.push(`UPPER(policy_holder_state) = UPPER($${idx++})`); params.push(filters.state); }
    if (filters.broker) { extraClauses.push(`sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${idx++})`); params.push(filters.broker); }

    const whereClause = [dateClause, ...extraClauses].join(' AND ');

    const sql = `
      SELECT
        TO_CHAR(sold_date, 'YYYY-MM') AS month,
        policy_business_type,
        COUNT(*)                       AS policy_count,
        COALESCE(SUM(premium_amount), 0) AS total_premium
      FROM sold_policies_data
      WHERE ${whereClause}
      GROUP BY TO_CHAR(sold_date, 'YYYY-MM'), policy_business_type
      ORDER BY month, policy_business_type;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// =========================================================================
// SECTION 5 — Brokers  /api/brokers
// =========================================================================

// GET /api/brokers/performance  (TTL 86400s)
// Filters: date_range, broker
app.get(
  '/api/brokers/performance',
  cachedHandler('brokers:performance', 86400, async (filters) => {
    const monthCutoff = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getMonthCutoff(filters.dateRange)
      : "TO_CHAR(CURRENT_DATE - INTERVAL '3 months', 'YYYY-MM')";
    const dateClause = monthCutoff ? `sold_month >= ${monthCutoff}` : '1=1';

    const brokerClauses = [];
    const params = [];
    let idx = 1;
    if (filters.broker) { brokerClauses.push(`broker_name = $${idx++}`); params.push(filters.broker); }
    const brokerWhere = brokerClauses.length > 0 ? ' AND ' + brokerClauses.join(' AND ') : '';

    const sql = `
      SELECT
        sales_channel_id,
        broker_name,
        SUM(${CH_POLICY_COUNT})   AS total_policies,
        SUM(${CH_POLICY_PREMIUM}) AS total_premium,
        SUM(${CH_QUOTE_COUNT})    AS total_quotes,
        COUNT(DISTINCT sold_month) AS active_months,
        CASE WHEN SUM(${CH_QUOTE_COUNT}) > 0
          THEN ROUND(SUM(${CH_POLICY_COUNT})::numeric / SUM(${CH_QUOTE_COUNT}) * 100, 2)
          ELSE 0
        END AS conversion_rate,
        CASE
          WHEN SUM(${CH_POLICY_COUNT}) > 1000 THEN 'Platinum'
          WHEN SUM(${CH_POLICY_COUNT}) > 500  THEN 'Gold'
          WHEN SUM(${CH_POLICY_COUNT}) > 100  THEN 'Silver'
          WHEN SUM(${CH_POLICY_COUNT}) > 0    THEN 'Bronze'
          ELSE 'Inactive'
        END AS tier
      FROM channel_wise_monthly_activity_summary
      WHERE ${dateClause}${brokerWhere}
      GROUP BY sales_channel_id, broker_name
      ORDER BY total_policies DESC;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// GET /api/brokers/dormant  (TTL 86400s)
// Filters: date_range, broker
app.get(
  '/api/brokers/dormant',
  cachedHandler('brokers:dormant', 86400, async (filters) => {
    const monthCutoff = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getMonthCutoff(filters.dateRange)
      : "TO_CHAR(CURRENT_DATE - INTERVAL '3 months', 'YYYY-MM')";
    const dateClause = monthCutoff ? `sold_month >= ${monthCutoff}` : '1=1';

    const brokerClauses = [];
    const params = [];
    let idx = 1;
    if (filters.broker) { brokerClauses.push(`broker_name = $${idx++}`); params.push(filters.broker); }
    const brokerWhere = brokerClauses.length > 0 ? ' AND ' + brokerClauses.join(' AND ') : '';

    const sql = `
      WITH broker_activity AS (
        SELECT
          sales_channel_id,
          broker_name,
          SUM(
            quote_count_2w + quote_count_4w + quote_count_health +
            quote_count_gcv + quote_count_pcv + quote_count_term +
            quote_count_personal_accident + quote_count_savings + quote_count_miscd
          ) AS total_quotes,
          SUM(
            policy_count_2w + policy_count_4w + policy_count_health +
            policy_count_gcv + policy_count_pcv + policy_count_term +
            policy_count_personal_accident + policy_count_savings + policy_count_miscd
          ) AS total_policies
        FROM channel_wise_monthly_activity_summary
        WHERE ${dateClause}${brokerWhere}
        GROUP BY sales_channel_id, broker_name
        HAVING SUM(
          quote_count_2w + quote_count_4w + quote_count_health +
          quote_count_gcv + quote_count_pcv + quote_count_term +
          quote_count_personal_accident + quote_count_savings + quote_count_miscd
        ) > 0
        AND SUM(
          policy_count_2w + policy_count_4w + policy_count_health +
          policy_count_gcv + policy_count_pcv + policy_count_term +
          policy_count_personal_accident + policy_count_savings + policy_count_miscd
        ) = 0
      )
      SELECT
        sales_channel_id,
        broker_name,
        total_quotes,
        total_policies,
        'Dormant - quoting but not converting' AS status
      FROM broker_activity
      ORDER BY total_quotes DESC;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// GET /api/brokers/trend  (TTL 86400s)
// Filters: date_range, broker
app.get(
  '/api/brokers/trend',
  cachedHandler('brokers:trend', 86400, async (filters) => {
    const monthCutoff = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getMonthCutoff(filters.dateRange)
      : "TO_CHAR(CURRENT_DATE - INTERVAL '6 months', 'YYYY-MM')";
    const dateClause = monthCutoff ? `sold_month >= ${monthCutoff}` : '1=1';

    const brokerClauses = [];
    const params = [];
    let idx = 1;
    if (filters.broker) { brokerClauses.push(`broker_name = $${idx++}`); params.push(filters.broker); }
    const brokerWhere = brokerClauses.length > 0 ? ' AND ' + brokerClauses.join(' AND ') : '';

    // If a specific broker is requested, show only that broker's trend
    const sql = filters.broker
      ? `
        SELECT
          c.broker_name,
          c.sold_month,
          SUM(${CH_POLICY_COUNT})   AS policy_count,
          SUM(${CH_POLICY_PREMIUM}) AS total_premium
        FROM channel_wise_monthly_activity_summary c
        WHERE ${dateClause}${brokerWhere}
        GROUP BY c.broker_name, c.sold_month
        ORDER BY c.broker_name, c.sold_month;
      `
      : `
        WITH top_brokers AS (
          SELECT broker_name
          FROM channel_wise_monthly_activity_summary
          WHERE ${dateClause}
          GROUP BY broker_name
          ORDER BY SUM(${CH_POLICY_PREMIUM}) DESC
          LIMIT 10
        )
        SELECT
          c.broker_name,
          c.sold_month,
          SUM(${CH_POLICY_COUNT})   AS policy_count,
          SUM(${CH_POLICY_PREMIUM}) AS total_premium
        FROM channel_wise_monthly_activity_summary c
        INNER JOIN top_brokers tb ON tb.broker_name = c.broker_name
        WHERE ${dateClause}
        GROUP BY c.broker_name, c.sold_month
        ORDER BY c.broker_name, c.sold_month;
      `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// =========================================================================
// SECTION 6 — Geographic  /api/geographic
// =========================================================================

// GET /api/geographic/states  (TTL 604800s)
// Filters: date_range, product, broker on sold_policies_data; state narrows to one state
app.get(
  '/api/geographic/states',
  cachedHandler('geographic:states', 604800, async (filters) => {
    const dateInterval = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getDateInterval(filters.dateRange)
      : "INTERVAL '6 months'";
    const dateClause = dateInterval ? `sold_date >= (CURRENT_DATE - ${dateInterval})` : '1=1';

    const extraClauses = [];
    const params = [];
    let idx = 1;
    if (filters.product) { extraClauses.push(`product_type = $${idx++}`); params.push(filters.product); }
    if (filters.state) { extraClauses.push(`UPPER(policy_holder_state) = UPPER($${idx++})`); params.push(filters.state); }
    if (filters.broker) { extraClauses.push(`sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${idx++})`); params.push(filters.broker); }

    const whereClause = [dateClause, ...extraClauses, "policy_holder_state IS NOT NULL", "policy_holder_state <> ''"].join(' AND ');

    const sql = `
      SELECT
        policy_holder_state AS state,
        COUNT(*)                           AS policies,
        COALESCE(SUM(premium_amount), 0)   AS total_premium,
        COUNT(DISTINCT agent)              AS agents,
        ROUND(AVG(premium_amount), 2)      AS avg_ticket
      FROM sold_policies_data
      WHERE ${whereClause}
      GROUP BY policy_holder_state
      ORDER BY total_premium DESC
      LIMIT 20;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// GET /api/geographic/state-product  (TTL 604800s)
// Filters: date_range, product, state, broker on sold_policies_data
app.get(
  '/api/geographic/state-product',
  cachedHandler('geographic:state-product', 604800, async (filters) => {
    const dateInterval = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getDateInterval(filters.dateRange)
      : "INTERVAL '6 months'";
    // CTE uses unaliased, main query uses 's.' alias
    const cteDateClause = dateInterval ? `sold_date >= (CURRENT_DATE - ${dateInterval})` : '1=1';
    const mainDateClause = dateInterval ? `s.sold_date >= (CURRENT_DATE - ${dateInterval})` : '1=1';

    const cteExtraClauses = [];
    const mainExtraClauses = [];
    const params = [];
    let idx = 1;
    if (filters.product) { cteExtraClauses.push(`product_type = $${idx}`); mainExtraClauses.push(`s.product_type = $${idx}`); params.push(filters.product); idx++; }
    if (filters.state) { cteExtraClauses.push(`UPPER(policy_holder_state) = UPPER($${idx})`); mainExtraClauses.push(`UPPER(s.policy_holder_state) = UPPER($${idx})`); params.push(filters.state); idx++; }
    if (filters.broker) { cteExtraClauses.push(`sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${idx})`); mainExtraClauses.push(`s.sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${idx})`); params.push(filters.broker); idx++; }

    const cteWhere = [cteDateClause, ...cteExtraClauses, "policy_holder_state IS NOT NULL", "policy_holder_state <> ''"].join(' AND ');
    const mainWhere = [mainDateClause, ...mainExtraClauses, "s.policy_holder_state IS NOT NULL", "s.policy_holder_state <> ''"].join(' AND ');

    // If a specific state is requested, skip the top_states CTE and show just that state
    const sql = filters.state
      ? `
        SELECT
          s.policy_holder_state AS state,
          s.product_type,
          COUNT(*)                           AS policies,
          COALESCE(SUM(s.premium_amount), 0) AS total_premium
        FROM sold_policies_data s
        WHERE ${mainWhere}
        GROUP BY s.policy_holder_state, s.product_type
        ORDER BY s.policy_holder_state, total_premium DESC;
      `
      : `
        WITH top_states AS (
          SELECT policy_holder_state
          FROM sold_policies_data
          WHERE ${cteWhere}
          GROUP BY policy_holder_state
          ORDER BY SUM(premium_amount) DESC
          LIMIT 10
        )
        SELECT
          s.policy_holder_state AS state,
          s.product_type,
          COUNT(*)                           AS policies,
          COALESCE(SUM(s.premium_amount), 0) AS total_premium
        FROM sold_policies_data s
        INNER JOIN top_states ts ON ts.policy_holder_state = s.policy_holder_state
        WHERE ${mainWhere}
        GROUP BY s.policy_holder_state, s.product_type
        ORDER BY s.policy_holder_state, total_premium DESC;
      `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// =========================================================================
// SECTION 7 — Insurers  /api/insurers
// =========================================================================

// GET /api/insurers/share  (TTL 86400s)
// Filters: all 4 on sold_policies_data
app.get(
  '/api/insurers/share',
  cachedHandler('insurers:share', 86400, async (filters) => {
    const dateInterval = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getDateInterval(filters.dateRange)
      : "INTERVAL '6 months'";
    const dateClause = dateInterval ? `sold_date >= (CURRENT_DATE - ${dateInterval})` : '1=1';

    const extraClauses = [];
    const params = [];
    let idx = 1;
    if (filters.product) { extraClauses.push(`product_type = $${idx++}`); params.push(filters.product); }
    if (filters.state) { extraClauses.push(`UPPER(policy_holder_state) = UPPER($${idx++})`); params.push(filters.state); }
    if (filters.broker) { extraClauses.push(`sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${idx++})`); params.push(filters.broker); }

    const whereClause = [dateClause, ...extraClauses, "insurer IS NOT NULL"].join(' AND ');

    const sql = `
      WITH insurer_stats AS (
        SELECT
          insurer,
          COUNT(*)                         AS policies,
          COALESCE(SUM(premium_amount), 0) AS total_premium,
          ROUND(AVG(premium_amount), 2)    AS avg_ticket
        FROM sold_policies_data
        WHERE ${whereClause}
        GROUP BY insurer
      ),
      grand AS (
        SELECT SUM(total_premium) AS grand_total FROM insurer_stats
      )
      SELECT
        i.insurer,
        i.policies,
        i.total_premium,
        i.avg_ticket,
        CASE WHEN g.grand_total > 0
          THEN ROUND(i.total_premium::numeric / g.grand_total * 100, 2)
          ELSE 0
        END AS pct_share
      FROM insurer_stats i, grand g
      ORDER BY i.total_premium DESC;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// GET /api/insurers/trend  (TTL 86400s)
// Filters: all 4 on sold_policies_data
app.get(
  '/api/insurers/trend',
  cachedHandler('insurers:trend', 86400, async (filters) => {
    const dateInterval = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getDateInterval(filters.dateRange)
      : "INTERVAL '6 months'";
    // CTE uses unaliased table, main query uses 's.' alias
    const cteDateClause = dateInterval ? `sold_date >= (CURRENT_DATE - ${dateInterval})` : '1=1';
    const mainDateClause = dateInterval ? `s.sold_date >= (CURRENT_DATE - ${dateInterval})` : '1=1';

    const cteExtraClauses = [];
    const mainExtraClauses = [];
    const params = [];
    let idx = 1;
    if (filters.product) { cteExtraClauses.push(`product_type = $${idx}`); mainExtraClauses.push(`s.product_type = $${idx}`); params.push(filters.product); idx++; }
    if (filters.state) { cteExtraClauses.push(`UPPER(policy_holder_state) = UPPER($${idx})`); mainExtraClauses.push(`UPPER(s.policy_holder_state) = UPPER($${idx})`); params.push(filters.state); idx++; }
    if (filters.broker) { cteExtraClauses.push(`sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${idx})`); mainExtraClauses.push(`s.sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${idx})`); params.push(filters.broker); idx++; }

    const cteWhereClause = [cteDateClause, ...cteExtraClauses, "insurer IS NOT NULL"].join(' AND ');
    const mainWhereClause = [mainDateClause, ...mainExtraClauses, "s.insurer IS NOT NULL"].join(' AND ');

    const sql = `
      WITH top_insurers AS (
        SELECT insurer
        FROM sold_policies_data
        WHERE ${cteWhereClause}
        GROUP BY insurer
        ORDER BY SUM(premium_amount) DESC
        LIMIT 8
      )
      SELECT
        TO_CHAR(s.sold_date, 'YYYY-MM') AS month,
        s.insurer,
        COUNT(*)                         AS policies,
        COALESCE(SUM(s.premium_amount), 0) AS total_premium
      FROM sold_policies_data s
      INNER JOIN top_insurers ti ON ti.insurer = s.insurer
      WHERE ${mainWhereClause}
      GROUP BY TO_CHAR(s.sold_date, 'YYYY-MM'), s.insurer
      ORDER BY month, s.insurer;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// =========================================================================
// SECTION 8 — Renewals  /api/renewals
// =========================================================================

// GET /api/renewals/upcoming  (TTL 86400s)
// Filters: product, state, broker (date is inherent to renewals)
app.get(
  '/api/renewals/upcoming',
  cachedHandler('renewals:upcoming', 86400, async (filters) => {
    const extraClauses = [];
    const params = [];
    let idx = 1;
    if (filters.product) { extraClauses.push(`product_type = $${idx++}`); params.push(filters.product); }
    if (filters.state) { extraClauses.push(`UPPER(policy_holder_state) = UPPER($${idx++})`); params.push(filters.state); }
    if (filters.broker) { extraClauses.push(`sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${idx++})`); params.push(filters.broker); }
    const extraWhere = extraClauses.length > 0 ? ' AND ' + extraClauses.join(' AND ') : '';

    const sql = `
      SELECT
        CASE
          WHEN policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days' THEN '0-30 days'
          WHEN policy_expiry_date BETWEEN CURRENT_DATE + INTERVAL '31 days' AND CURRENT_DATE + INTERVAL '60 days' THEN '31-60 days'
          WHEN policy_expiry_date BETWEEN CURRENT_DATE + INTERVAL '61 days' AND CURRENT_DATE + INTERVAL '90 days' THEN '61-90 days'
        END AS expiry_bucket,
        COUNT(*)                           AS policy_count,
        COALESCE(SUM(premium_amount), 0)   AS premium_at_stake,
        COUNT(DISTINCT agent)              AS agents_involved,
        CASE
          WHEN policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days' THEN 1
          WHEN policy_expiry_date BETWEEN CURRENT_DATE + INTERVAL '31 days' AND CURRENT_DATE + INTERVAL '60 days' THEN 2
          ELSE 3
        END AS sort_order
      FROM sold_policies_data
      WHERE policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days'${extraWhere}
      GROUP BY expiry_bucket, sort_order
      ORDER BY sort_order;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// GET /api/renewals/at-risk  (TTL 86400s)
// Filters: product, state, broker
app.get(
  '/api/renewals/at-risk',
  cachedHandler('renewals:at-risk', 86400, async (filters) => {
    const extraClauses = [];
    const params = [];
    let idx = 1;
    if (filters.product) { extraClauses.push(`e.product_type = $${idx++}`); params.push(filters.product); }
    if (filters.state) { extraClauses.push(`UPPER(e.policy_holder_state) = UPPER($${idx++})`); params.push(filters.state); }
    if (filters.broker) { extraClauses.push(`e.sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${idx++})`); params.push(filters.broker); }
    const extraWhere = extraClauses.length > 0 ? ' AND ' + extraClauses.join(' AND ') : '';

    const sql = `
      WITH expired AS (
        SELECT
          e.id,
          e.premium_amount,
          e.policy_expiry_date,
          e.vehicle_make_model,
          e.policy_holder_phone,
          e.product_type,
          CASE
            WHEN e.policy_expiry_date BETWEEN CURRENT_DATE - INTERVAL '30 days' AND CURRENT_DATE THEN 'Expired 0-30 days'
            WHEN e.policy_expiry_date BETWEEN CURRENT_DATE - INTERVAL '60 days' AND CURRENT_DATE - INTERVAL '31 days' THEN 'Expired 31-60 days'
            WHEN e.policy_expiry_date BETWEEN CURRENT_DATE - INTERVAL '90 days' AND CURRENT_DATE - INTERVAL '61 days' THEN 'Expired 61-90 days'
          END AS expiry_window
        FROM sold_policies_data e
        WHERE e.policy_expiry_date BETWEEN CURRENT_DATE - INTERVAL '90 days' AND CURRENT_DATE${extraWhere}
      ),
      renewed AS (
        SELECT DISTINCT s.vehicle_make_model, s.policy_holder_phone
        FROM sold_policies_data s
        WHERE s.sold_date >= (CURRENT_DATE - INTERVAL '90 days')
          AND s.policy_business_type IN ('Renewal', 'Roll Over')
      ),
      at_risk AS (
        SELECT e.*
        FROM expired e
        LEFT JOIN renewed r
          ON r.vehicle_make_model = e.vehicle_make_model
         AND r.policy_holder_phone = e.policy_holder_phone
        WHERE r.vehicle_make_model IS NULL
      )
      SELECT
        expiry_window,
        COUNT(*)                           AS policy_count,
        COALESCE(SUM(premium_amount), 0)   AS premium_at_risk,
        COUNT(DISTINCT product_type)       AS product_types_affected
      FROM at_risk
      WHERE expiry_window IS NOT NULL
      GROUP BY expiry_window
      ORDER BY
        CASE expiry_window
          WHEN 'Expired 0-30 days'   THEN 1
          WHEN 'Expired 31-60 days'  THEN 2
          WHEN 'Expired 61-90 days'  THEN 3
        END;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// =========================================================================
// SECTION 9 — Alerts  /api/alerts
// =========================================================================

// GET /api/alerts/summary  (TTL 14400s)
// Filters: date_range adjusts the various windows; product/state/broker filter expiring
app.get(
  '/api/alerts/summary',
  cachedHandler('alerts:summary', 14400, async (filters) => {
    // Date range for declining agents comparison
    let curDateClause, prevDateClause;
    if (filters.dateRange && filters.dateRange !== 'all_time') {
      const interval = getDateInterval(filters.dateRange);
      if (interval) {
        curDateClause = `quote_date >= (CURRENT_DATE - ${interval})`;
        prevDateClause = `quote_date >= (CURRENT_DATE - ${interval} - ${interval}) AND quote_date < (CURRENT_DATE - ${interval})`;
      } else {
        curDateClause = `quote_date >= DATE_TRUNC('month', CURRENT_DATE)`;
        prevDateClause = `quote_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month' AND quote_date < DATE_TRUNC('month', CURRENT_DATE)`;
      }
    } else {
      curDateClause = `quote_date >= DATE_TRUNC('month', CURRENT_DATE)`;
      prevDateClause = `quote_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month' AND quote_date < DATE_TRUNC('month', CURRENT_DATE)`;
    }

    // Activity month cutoff for stuck quoters
    const activityCutoff = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getMonthCutoff(filters.dateRange)
      : "TO_CHAR(CURRENT_DATE - INTERVAL '2 months', 'YYYY-MM')";
    const activityDateClause = activityCutoff ? `activity_month >= ${activityCutoff}` : '1=1';

    // Inactive agent windows
    let activeWindowStart, activeWindowEnd, recentWindow;
    if (filters.dateRange === 'last_30_days') {
      activeWindowStart = "CURRENT_DATE - INTERVAL '30 days'";
      activeWindowEnd = "CURRENT_DATE - INTERVAL '14 days'";
      recentWindow = "INTERVAL '3 days'";
    } else if (filters.dateRange === 'last_3_months') {
      activeWindowStart = "CURRENT_DATE - INTERVAL '90 days'";
      activeWindowEnd = "CURRENT_DATE - INTERVAL '30 days'";
      recentWindow = "INTERVAL '7 days'";
    } else {
      activeWindowStart = "CURRENT_DATE - INTERVAL '60 days'";
      activeWindowEnd = "CURRENT_DATE - INTERVAL '30 days'";
      recentWindow = "INTERVAL '7 days'";
    }

    // Expiring renewals: product/state/broker filters
    const spf = buildSoldPolicyFilters({ ...filters, dateRange: null }, '', 1);
    const expiringExtra = andAppend(spf.clauses);
    const params = spf.params;

    // Reuse the same broker $N across declining (daily_quote_counts) and stuck (activity_summary)
    const brokerParamIdx = filters.broker ? spf.nextIdx - 1 : null;
    const quoteBrokerClause = brokerParamIdx
      ? ` AND agent_id IN (SELECT u.id FROM users u WHERE u.saleschanneluserid IN (SELECT id FROM users WHERE fullname = $${brokerParamIdx}))`
      : '';
    const activityBrokerClause = brokerParamIdx
      ? ` AND sales_channel_id IN (SELECT id FROM users WHERE fullname = $${brokerParamIdx})`
      : '';

    const sql = `
      WITH declining AS (
        SELECT COUNT(DISTINCT agent_id) AS cnt
        FROM (
          SELECT p.agent_id
          FROM (
            SELECT agent_id, SUM(quote_count) AS prev_quotes
            FROM daily_quote_counts
            WHERE ${prevDateClause}${quoteBrokerClause}
            GROUP BY agent_id
          ) p
          LEFT JOIN (
            SELECT agent_id, SUM(quote_count) AS cur_quotes
            FROM daily_quote_counts
            WHERE ${curDateClause}${quoteBrokerClause}
            GROUP BY agent_id
          ) c ON c.agent_id = p.agent_id
          WHERE p.prev_quotes > 0
            AND (p.prev_quotes - COALESCE(c.cur_quotes, 0))::numeric / p.prev_quotes > 0.40
        ) sub
      ),
      stuck AS (
        SELECT COUNT(DISTINCT agent_id) AS cnt
        FROM agent_wise_monthly_activity_summary
        WHERE ${activityDateClause}${activityBrokerClause}
        GROUP BY agent_id
        HAVING SUM(quote_count_2w + quote_count_4w + quote_count_health +
                   quote_count_gcv + quote_count_pcv + quote_count_term +
                   quote_count_personal_accident + quote_count_savings + quote_count_miscd) > 0
           AND SUM(policy_count_2w + policy_count_4w + policy_count_health +
                   policy_count_gcv + policy_count_pcv + policy_count_term +
                   policy_count_personal_accident + policy_count_savings + policy_count_miscd) = 0
      ),
      inactive AS (
        SELECT COUNT(DISTINCT pa.agent_id) AS cnt
        FROM (
          SELECT agent_id
          FROM agent_daily_logins
          WHERE login_date BETWEEN ${activeWindowStart} AND ${activeWindowEnd}
          GROUP BY agent_id
          HAVING SUM(login_count) >= 5
        ) pa
        LEFT JOIN (
          SELECT agent_id, MAX(login_date) AS last_login_date
          FROM agent_daily_logins
          GROUP BY agent_id
        ) ll ON ll.agent_id = pa.agent_id
        WHERE ll.last_login_date IS NULL
           OR ll.last_login_date < CURRENT_DATE - ${recentWindow}
      ),
      expiring AS (
        SELECT COUNT(*) AS cnt
        FROM sold_policies_data
        WHERE policy_expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days'${expiringExtra}
      )
      SELECT
        d.cnt AS declining_agents_count,
        (SELECT COUNT(*) FROM stuck) AS stuck_quoters_count,
        i.cnt AS inactive_agents_count,
        e.cnt AS expiring_renewals_count
      FROM declining d, inactive i, expiring e;
    `;
    const result = await query(sql, params);
    return result.rows[0] || {};
  }),
);

// GET /api/alerts/declining-agents  (TTL 14400s)
// Filters: date_range adjusts comparison periods; product/state/broker filter lifetime CTE
app.get(
  '/api/alerts/declining-agents',
  cachedHandler('alerts:declining-agents', 14400, async (filters) => {
    // Build date-based comparison periods
    let curDateClause, prevDateClause;
    if (filters.dateRange && filters.dateRange !== 'all_time') {
      const interval = getDateInterval(filters.dateRange);
      if (interval) {
        curDateClause = `quote_date >= (CURRENT_DATE - ${interval})`;
        prevDateClause = `quote_date >= (CURRENT_DATE - ${interval} - ${interval}) AND quote_date < (CURRENT_DATE - ${interval})`;
      } else {
        curDateClause = `quote_date >= DATE_TRUNC('month', CURRENT_DATE)`;
        prevDateClause = `quote_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month' AND quote_date < DATE_TRUNC('month', CURRENT_DATE)`;
      }
    } else {
      curDateClause = `quote_date >= DATE_TRUNC('month', CURRENT_DATE)`;
      prevDateClause = `quote_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month' AND quote_date < DATE_TRUNC('month', CURRENT_DATE)`;
    }

    // Build sold_policies_data filters for lifetime CTE
    const spf = buildSoldPolicyFilters({ ...filters, dateRange: null }, '', 1);
    const lifetimeWhere = spf.clauses.length > 0 ? ' WHERE ' + spf.clauses.join(' AND ') : '';
    const params = spf.params;

    // Reuse the same broker $N for daily_quote_counts CTEs
    const brokerParamIdx = filters.broker ? spf.nextIdx - 1 : null;
    const quoteBrokerClause = brokerParamIdx
      ? ` AND agent_id IN (SELECT u.id FROM users u WHERE u.saleschanneluserid IN (SELECT id FROM users WHERE fullname = $${brokerParamIdx}))`
      : '';

    const sql = `
      WITH cur_period AS (
        SELECT agent_id, SUM(quote_count) AS cur_quotes
        FROM daily_quote_counts
        WHERE ${curDateClause}${quoteBrokerClause}
        GROUP BY agent_id
      ),
      prev_period AS (
        SELECT agent_id, SUM(quote_count) AS prev_quotes
        FROM daily_quote_counts
        WHERE ${prevDateClause}${quoteBrokerClause}
        GROUP BY agent_id
      ),
      declining AS (
        SELECT
          p.agent_id,
          COALESCE(c.cur_quotes, 0) AS cur_quotes,
          p.prev_quotes,
          ROUND((p.prev_quotes - COALESCE(c.cur_quotes, 0))::numeric / p.prev_quotes * 100, 2) AS decline_pct
        FROM prev_period p
        LEFT JOIN cur_period c ON c.agent_id = p.agent_id
        WHERE p.prev_quotes > 0
          AND (p.prev_quotes - COALESCE(c.cur_quotes, 0))::numeric / p.prev_quotes > 0.40
      ),
      lifetime AS (
        SELECT agent, COALESCE(SUM(premium_amount), 0) AS lifetime_premium, COUNT(*) AS lifetime_policies
        FROM sold_policies_data${lifetimeWhere}
        GROUP BY agent
      )
      SELECT
        d.agent_id,
        u.fullname AS agent_name,
        u.phone,
        d.cur_quotes,
        d.prev_quotes,
        d.decline_pct,
        COALESCE(lt.lifetime_premium, 0) AS lifetime_premium,
        COALESCE(lt.lifetime_policies, 0) AS lifetime_policies
      FROM declining d
      LEFT JOIN users u ON u.id = d.agent_id
      LEFT JOIN lifetime lt ON lt.agent = d.agent_id
      ORDER BY lt.lifetime_premium DESC
      LIMIT 50;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// GET /api/alerts/stuck-quoters  (TTL 14400s)
// Filters: date_range adjusts the 2-month window
app.get(
  '/api/alerts/stuck-quoters',
  cachedHandler('alerts:stuck-quoters', 14400, async (filters) => {
    const monthCutoff = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getMonthCutoff(filters.dateRange)
      : "TO_CHAR(CURRENT_DATE - INTERVAL '2 months', 'YYYY-MM')";
    const dateClause = monthCutoff ? `activity_month >= ${monthCutoff}` : '1=1';

    // Broker filter via sales_channel_id → users.id
    const brokerParams = [];
    let brokerClause = '';
    if (filters.broker) {
      brokerClause = ` AND sales_channel_id IN (SELECT id FROM users WHERE fullname = $1)`;
      brokerParams.push(filters.broker);
    }

    const sql = `
      WITH recent AS (
        SELECT
          agent_id,
          SUM(quote_count_2w + quote_count_4w + quote_count_health +
              quote_count_gcv + quote_count_pcv + quote_count_term +
              quote_count_personal_accident + quote_count_savings + quote_count_miscd
          ) AS total_quotes,
          SUM(proposal_count_2w + proposal_count_4w + proposal_count_health +
              proposal_count_gcv + proposal_count_pcv + proposal_count_term +
              proposal_count_personal_accident + proposal_count_savings + proposal_count_miscd
          ) AS total_proposals,
          SUM(policy_count_2w + policy_count_4w + policy_count_health +
              policy_count_gcv + policy_count_pcv + policy_count_term +
              policy_count_personal_accident + policy_count_savings + policy_count_miscd
          ) AS total_policies
        FROM agent_wise_monthly_activity_summary
        WHERE ${dateClause}${brokerClause}
        GROUP BY agent_id
        HAVING SUM(quote_count_2w + quote_count_4w + quote_count_health +
                   quote_count_gcv + quote_count_pcv + quote_count_term +
                   quote_count_personal_accident + quote_count_savings + quote_count_miscd) > 0
           AND SUM(policy_count_2w + policy_count_4w + policy_count_health +
                   policy_count_gcv + policy_count_pcv + policy_count_term +
                   policy_count_personal_accident + policy_count_savings + policy_count_miscd) = 0
      )
      SELECT
        r.agent_id,
        u.fullname AS agent_name,
        u.phone,
        r.total_quotes,
        r.total_proposals,
        r.total_policies,
        CASE
          WHEN r.total_quotes >= 50 THEN 'Critical'
          WHEN r.total_quotes >= 20 THEN 'High'
          WHEN r.total_quotes >= 10 THEN 'Medium'
          ELSE 'Low'
        END AS intervention_level,
        CASE
          WHEN r.total_proposals > 0 THEN 'Stuck at proposal stage'
          ELSE 'Not converting quotes to proposals'
        END AS stuck_at
      FROM recent r
      LEFT JOIN users u ON u.id = r.agent_id
      ORDER BY r.total_quotes DESC
      LIMIT 50;
    `;
    const result = await query(sql, brokerParams);
    return result.rows;
  }),
);

// GET /api/alerts/inactive-agents  (TTL 14400s)
// Filters: date_range scales inactivity windows; product/state/broker filter lifetime CTE
app.get(
  '/api/alerts/inactive-agents',
  cachedHandler('alerts:inactive-agents', 14400, async (filters) => {
    // Scale inactivity detection windows based on date range
    let activeWindowStart, activeWindowEnd, recentWindow;
    if (filters.dateRange === 'last_30_days') {
      activeWindowStart = "CURRENT_DATE - INTERVAL '30 days'";
      activeWindowEnd = "CURRENT_DATE - INTERVAL '14 days'";
      recentWindow = "INTERVAL '3 days'";
    } else if (filters.dateRange === 'last_3_months') {
      activeWindowStart = "CURRENT_DATE - INTERVAL '90 days'";
      activeWindowEnd = "CURRENT_DATE - INTERVAL '30 days'";
      recentWindow = "INTERVAL '7 days'";
    } else {
      // default (6 months, 12 months, all_time)
      activeWindowStart = "CURRENT_DATE - INTERVAL '60 days'";
      activeWindowEnd = "CURRENT_DATE - INTERVAL '30 days'";
      recentWindow = "INTERVAL '7 days'";
    }

    // Build sold_policies_data filters for lifetime CTE
    const spf = buildSoldPolicyFilters({ ...filters, dateRange: null }, '', 1);
    const lifetimeWhere = spf.clauses.length > 0 ? ' WHERE ' + spf.clauses.join(' AND ') : '';
    const params = spf.params;

    const sql = `
      WITH previously_active AS (
        SELECT agent_id, SUM(login_count) AS logins_active_window
        FROM agent_daily_logins
        WHERE login_date BETWEEN ${activeWindowStart} AND ${activeWindowEnd}
        GROUP BY agent_id
        HAVING SUM(login_count) >= 5
      ),
      last_login AS (
        SELECT agent_id, MAX(login_date) AS last_login_date
        FROM agent_daily_logins
        GROUP BY agent_id
      ),
      inactive AS (
        SELECT
          pa.agent_id,
          pa.logins_active_window AS logins_30_60,
          ll.last_login_date,
          CURRENT_DATE - ll.last_login_date AS days_inactive,
          CASE
            WHEN ll.last_login_date >= CURRENT_DATE - INTERVAL '14 days' THEN '7-14 day inactive'
            WHEN ll.last_login_date >= CURRENT_DATE - INTERVAL '30 days' THEN '14-30 day inactive'
            ELSE '30+ day inactive'
          END AS inactivity_class
        FROM previously_active pa
        LEFT JOIN last_login ll ON ll.agent_id = pa.agent_id
        WHERE ll.last_login_date IS NULL
           OR ll.last_login_date < CURRENT_DATE - ${recentWindow}
      ),
      lifetime AS (
        SELECT agent, COALESCE(SUM(premium_amount), 0) AS lifetime_premium, COUNT(*) AS lifetime_policies
        FROM sold_policies_data${lifetimeWhere}
        GROUP BY agent
      )
      SELECT
        i.agent_id,
        u.fullname AS agent_name,
        u.phone,
        u.status,
        i.logins_30_60,
        i.last_login_date,
        i.days_inactive,
        i.inactivity_class,
        COALESCE(lt.lifetime_premium, 0) AS lifetime_premium,
        COALESCE(lt.lifetime_policies, 0) AS lifetime_policies
      FROM inactive i
      LEFT JOIN users u ON u.id = i.agent_id
      LEFT JOIN lifetime lt ON lt.agent = i.agent_id
      ORDER BY i.days_inactive DESC
      LIMIT 100;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// =========================================================================
// SECTION 10 — Operations  /api/operations
// =========================================================================

// GET /api/operations/today  (TTL 900s)
// Filters: product, state, broker on sold_policies_data (date is inherent — "today")
app.get(
  '/api/operations/today',
  cachedHandler('operations:today', 900, async (filters) => {
    const extraClauses = [];
    const params = [];
    let idx = 1;
    if (filters.product) { extraClauses.push(`product_type = $${idx++}`); params.push(filters.product); }
    if (filters.state) { extraClauses.push(`UPPER(policy_holder_state) = UPPER($${idx++})`); params.push(filters.state); }
    let quoteBrokerClause = '';
    if (filters.broker) {
      const bIdx = idx++;
      extraClauses.push(`sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${bIdx})`);
      params.push(filters.broker);
      quoteBrokerClause = ` AND agent_id IN (SELECT u.id FROM users u WHERE u.saleschanneluserid IN (SELECT id FROM users WHERE fullname = $${bIdx}))`;
    }
    const extraWhere = extraClauses.length > 0 ? ' AND ' + extraClauses.join(' AND ') : '';

    const sql = `
      WITH today AS (
        SELECT
          COUNT(*)                         AS policies,
          COALESCE(SUM(premium_amount), 0) AS premium,
          COUNT(DISTINCT agent)            AS active_agents
        FROM sold_policies_data
        WHERE sold_date = CURRENT_DATE${extraWhere}
      ),
      today_quotes AS (
        SELECT COALESCE(SUM(quote_count), 0) AS quotes
        FROM daily_quote_counts
        WHERE quote_date = CURRENT_DATE${quoteBrokerClause}
      ),
      avg_30 AS (
        SELECT
          ROUND(COUNT(*)::numeric / GREATEST(COUNT(DISTINCT sold_date), 1), 2) AS avg_policies,
          ROUND(SUM(premium_amount)::numeric / GREATEST(COUNT(DISTINCT sold_date), 1), 2) AS avg_premium,
          ROUND(COUNT(DISTINCT agent)::numeric / GREATEST(COUNT(DISTINCT sold_date), 1), 2) AS avg_agents
        FROM sold_policies_data
        WHERE sold_date >= CURRENT_DATE - INTERVAL '30 days'
          AND sold_date < CURRENT_DATE${extraWhere}
      ),
      avg_30_quotes AS (
        SELECT
          ROUND(SUM(quote_count)::numeric / GREATEST(COUNT(DISTINCT quote_date), 1), 2) AS avg_quotes
        FROM daily_quote_counts
        WHERE quote_date >= CURRENT_DATE - INTERVAL '30 days'
          AND quote_date < CURRENT_DATE${quoteBrokerClause}
      )
      SELECT
        t.policies            AS today_policies,
        t.premium             AS today_premium,
        t.active_agents       AS today_agents,
        tq.quotes             AS today_quotes,
        a.avg_policies        AS avg30_policies,
        a.avg_premium         AS avg30_premium,
        a.avg_agents          AS avg30_agents,
        aq.avg_quotes         AS avg30_quotes,
        CASE WHEN a.avg_policies > 0
          THEN ROUND(t.policies::numeric / a.avg_policies * 100, 2)
          ELSE 0
        END AS policies_pct_of_avg,
        CASE WHEN a.avg_premium > 0
          THEN ROUND(t.premium::numeric / a.avg_premium * 100, 2)
          ELSE 0
        END AS premium_pct_of_avg,
        CASE WHEN a.avg_agents > 0
          THEN ROUND(t.active_agents::numeric / a.avg_agents * 100, 2)
          ELSE 0
        END AS agents_pct_of_avg,
        CASE WHEN aq.avg_quotes > 0
          THEN ROUND(tq.quotes::numeric / aq.avg_quotes * 100, 2)
          ELSE 0
        END AS quotes_pct_of_avg
      FROM today t, today_quotes tq, avg_30 a, avg_30_quotes aq;
    `;
    const result = await query(sql, params);
    return result.rows[0] || {};
  }),
);

// GET /api/operations/week-comparison  (TTL 900s)
// Filters: product, state, broker on sold_policies_data
app.get(
  '/api/operations/week-comparison',
  cachedHandler('operations:week-comparison', 900, async (filters) => {
    const extraClauses = [];
    const params = [];
    let idx = 1;
    if (filters.product) { extraClauses.push(`product_type = $${idx++}`); params.push(filters.product); }
    if (filters.state) { extraClauses.push(`UPPER(policy_holder_state) = UPPER($${idx++})`); params.push(filters.state); }
    let quoteBrokerClause = '';
    if (filters.broker) {
      const bIdx = idx++;
      extraClauses.push(`sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${bIdx})`);
      params.push(filters.broker);
      quoteBrokerClause = ` AND agent_id IN (SELECT u.id FROM users u WHERE u.saleschanneluserid IN (SELECT id FROM users WHERE fullname = $${bIdx}))`;
    }
    const extraWhere = extraClauses.length > 0 ? ' AND ' + extraClauses.join(' AND ') : '';

    const sql = `
      WITH this_week AS (
        SELECT
          COUNT(*)                         AS policies,
          COALESCE(SUM(premium_amount), 0) AS premium,
          COUNT(DISTINCT agent)            AS agents
        FROM sold_policies_data
        WHERE sold_date >= CURRENT_DATE - INTERVAL '7 days'${extraWhere}
      ),
      this_week_quotes AS (
        SELECT COALESCE(SUM(quote_count), 0) AS quotes
        FROM daily_quote_counts
        WHERE quote_date >= CURRENT_DATE - INTERVAL '7 days'${quoteBrokerClause}
      ),
      last_week AS (
        SELECT
          COUNT(*)                         AS policies,
          COALESCE(SUM(premium_amount), 0) AS premium,
          COUNT(DISTINCT agent)            AS agents
        FROM sold_policies_data
        WHERE sold_date >= CURRENT_DATE - INTERVAL '14 days'
          AND sold_date < CURRENT_DATE - INTERVAL '7 days'${extraWhere}
      ),
      last_week_quotes AS (
        SELECT COALESCE(SUM(quote_count), 0) AS quotes
        FROM daily_quote_counts
        WHERE quote_date >= CURRENT_DATE - INTERVAL '14 days'
          AND quote_date < CURRENT_DATE - INTERVAL '7 days'${quoteBrokerClause}
      )
      SELECT
        tw.policies  AS tw_policies,
        tw.premium   AS tw_premium,
        tw.agents    AS tw_agents,
        twq.quotes   AS tw_quotes,
        lw.policies  AS lw_policies,
        lw.premium   AS lw_premium,
        lw.agents    AS lw_agents,
        lwq.quotes   AS lw_quotes,
        CASE WHEN lw.policies > 0
          THEN ROUND((tw.policies - lw.policies)::numeric / lw.policies * 100, 2) ELSE 0
        END AS policies_wow_pct,
        CASE WHEN lw.premium > 0
          THEN ROUND((tw.premium - lw.premium)::numeric / lw.premium * 100, 2) ELSE 0
        END AS premium_wow_pct,
        CASE WHEN lw.agents > 0
          THEN ROUND((tw.agents - lw.agents)::numeric / lw.agents * 100, 2) ELSE 0
        END AS agents_wow_pct,
        CASE WHEN lwq.quotes > 0
          THEN ROUND((twq.quotes - lwq.quotes)::numeric / lwq.quotes * 100, 2) ELSE 0
        END AS quotes_wow_pct
      FROM this_week tw, this_week_quotes twq, last_week lw, last_week_quotes lwq;
    `;
    const result = await query(sql, params);
    return result.rows[0] || {};
  }),
);

// GET /api/operations/leaderboard  (TTL 900s)
// Filters: product, state, broker on sold_policies_data; date_range overrides current month
app.get(
  '/api/operations/leaderboard',
  cachedHandler('operations:leaderboard', 900, async (filters) => {
    const extraClauses = [];
    const params = [];
    let idx = 1;
    if (filters.product) { extraClauses.push(`s.product_type = $${idx++}`); params.push(filters.product); }
    if (filters.state) { extraClauses.push(`UPPER(s.policy_holder_state) = UPPER($${idx++})`); params.push(filters.state); }
    if (filters.broker) { extraClauses.push(`s.sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${idx++})`); params.push(filters.broker); }
    const extraWhere = extraClauses.length > 0 ? ' AND ' + extraClauses.join(' AND ') : '';

    // Date range: if provided, override the "current month" logic
    let dateClause;
    if (filters.dateRange && filters.dateRange !== 'all_time') {
      const interval = getDateInterval(filters.dateRange);
      dateClause = interval ? `s.sold_date >= (CURRENT_DATE - ${interval})` : '1=1';
    } else {
      dateClause = `TO_CHAR(s.sold_date, 'YYYY-MM') = TO_CHAR(CURRENT_DATE, 'YYYY-MM')`;
    }

    const sql = `
      SELECT
        s.agent                            AS agent_id,
        u.fullname                         AS agent_name,
        u.phone,
        COUNT(*)                           AS policies,
        COALESCE(SUM(s.premium_amount), 0) AS total_premium,
        ROUND(AVG(s.premium_amount), 2)    AS avg_ticket,
        COUNT(DISTINCT s.product_type)     AS product_types
      FROM sold_policies_data s
      LEFT JOIN users u ON u.id = s.agent
      WHERE ${dateClause}${extraWhere}
      GROUP BY s.agent, u.fullname, u.phone
      ORDER BY policies DESC
      LIMIT 20;
    `;
    const result = await query(sql, params);
    return result.rows;
  }),
);

// =========================================================================
// SECTION 11 — Advanced  /api/advanced
// =========================================================================

// GET /api/advanced/revenue-at-risk  (TTL 86400s)
// Filters: date_range adjusts the 6-month windows; product, state, broker on sold_policies_data
app.get(
  '/api/advanced/revenue-at-risk',
  cachedHandler('advanced:revenue-at-risk', 86400, async (filters) => {
    const soldInterval = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getDateInterval(filters.dateRange)
      : "INTERVAL '6 months'";
    const soldDateClause = soldInterval ? `sold_date >= (CURRENT_DATE - ${soldInterval})` : '1=1';
    const soldDateExpr = soldInterval ? `(CURRENT_DATE - ${soldInterval})` : "'1970-01-01'::date";

    const monthCutoff = (filters.dateRange && filters.dateRange !== 'all_time')
      ? getMonthCutoff(filters.dateRange)
      : "TO_CHAR(CURRENT_DATE - INTERVAL '6 months', 'YYYY-MM')";
    const channelDateClause = monthCutoff ? `sold_month >= ${monthCutoff}` : '1=1';

    const expiryInterval = soldInterval || "INTERVAL '6 months'";

    // Build product/state/broker filters for sold_policies_data
    const spf = buildSoldPolicyFilters({ ...filters, dateRange: null }, '', 1);
    const extraSoldWhere = andAppend(spf.clauses);
    const params = spf.params;

    // For expired_not_renewed CTE, we need filters on both 'e.' and 'r.' aliases
    const spfE = buildSoldPolicyFilters({ ...filters, dateRange: null }, 'e.', 1);
    const extraSoldWhereE = andAppend(spfE.clauses);
    const spfR = buildSoldPolicyFilters({ ...filters, dateRange: null }, 'r.', 1);
    const extraSoldWhereR = andAppend(spfR.clauses);

    const sql = `
      WITH total_6m AS (
        SELECT COALESCE(SUM(premium_amount), 0) AS grand_total
        FROM sold_policies_data
        WHERE ${soldDateClause}${extraSoldWhere}
      ),
      top_broker AS (
        SELECT SUM(${CH_POLICY_PREMIUM}) AS broker_premium
        FROM channel_wise_monthly_activity_summary
        WHERE ${channelDateClause}
        GROUP BY broker_name
        ORDER BY broker_premium DESC
        LIMIT 1
      ),
      top10_agents AS (
        SELECT SUM(agent_premium) AS agents_premium
        FROM (
          SELECT SUM(premium_amount) AS agent_premium
          FROM sold_policies_data
          WHERE ${soldDateClause}${extraSoldWhere}
          GROUP BY agent
          ORDER BY agent_premium DESC
          LIMIT 10
        ) sub
      ),
      expired_not_renewed AS (
        SELECT COUNT(*) AS cnt, COALESCE(SUM(e.premium_amount), 0) AS leaked_premium
        FROM sold_policies_data e
        LEFT JOIN sold_policies_data r
          ON r.policy_holder_phone = e.policy_holder_phone
         AND r.vehicle_make_model = e.vehicle_make_model
         AND r.sold_date >= ${soldDateExpr}
         AND r.policy_business_type IN ('Renewal', 'Roll Over')${extraSoldWhereR}
        WHERE e.policy_expiry_date BETWEEN ${soldDateExpr} AND CURRENT_DATE
          AND r.id IS NULL${extraSoldWhereE}
      )
      SELECT
        t6.grand_total AS total_6m_premium,
        COALESCE(tb.broker_premium, 0) AS top_broker_premium,
        CASE WHEN t6.grand_total > 0
          THEN ROUND(COALESCE(tb.broker_premium, 0)::numeric / t6.grand_total * 100, 2) ELSE 0
        END AS broker_concentration_pct,
        COALESCE(t10.agents_premium, 0) AS top10_agents_premium,
        CASE WHEN t6.grand_total > 0
          THEN ROUND(COALESCE(t10.agents_premium, 0)::numeric / t6.grand_total * 100, 2) ELSE 0
        END AS agent_dependency_pct,
        enr.leaked_premium AS renewal_leakage_premium,
        enr.cnt AS renewal_leakage_policies,
        CASE WHEN t6.grand_total > 0
          THEN ROUND(enr.leaked_premium::numeric / t6.grand_total * 100, 2) ELSE 0
        END AS renewal_leakage_pct
      FROM total_6m t6, top_broker tb, top10_agents t10, expired_not_renewed enr;
    `;
    const result = await query(sql, params);
    return result.rows[0] || {};
  }),
);

// GET /api/advanced/weekly-pulse  (TTL 900s)
// Filters: product, state, broker on sold_policies_data
app.get(
  '/api/advanced/weekly-pulse',
  cachedHandler('advanced:weekly-pulse', 900, async (filters) => {
    const extraClauses = [];
    const params = [];
    let idx = 1;
    if (filters.product) { extraClauses.push(`product_type = $${idx++}`); params.push(filters.product); }
    if (filters.state) { extraClauses.push(`UPPER(policy_holder_state) = UPPER($${idx++})`); params.push(filters.state); }
    let quoteBrokerClause = '';
    if (filters.broker) {
      const bIdx = idx++;
      extraClauses.push(`sales_channel_user_id IN (SELECT id FROM users WHERE fullname = $${bIdx})`);
      params.push(filters.broker);
      quoteBrokerClause = ` AND agent_id IN (SELECT u.id FROM users u WHERE u.saleschanneluserid IN (SELECT id FROM users WHERE fullname = $${bIdx}))`;
    }
    const extraWhere = extraClauses.length > 0 ? ' AND ' + extraClauses.join(' AND ') : '';

    const sql = `
      WITH this_week AS (
        SELECT
          COUNT(*)                         AS policies,
          COALESCE(SUM(premium_amount), 0) AS premium,
          COUNT(DISTINCT agent)            AS agents
        FROM sold_policies_data
        WHERE sold_date >= CURRENT_DATE - INTERVAL '7 days'${extraWhere}
      ),
      tw_quotes AS (
        SELECT COALESCE(SUM(quote_count), 0) AS quotes
        FROM daily_quote_counts
        WHERE quote_date >= CURRENT_DATE - INTERVAL '7 days'${quoteBrokerClause}
      ),
      last_week AS (
        SELECT
          COUNT(*)                         AS policies,
          COALESCE(SUM(premium_amount), 0) AS premium,
          COUNT(DISTINCT agent)            AS agents
        FROM sold_policies_data
        WHERE sold_date >= CURRENT_DATE - INTERVAL '14 days'
          AND sold_date < CURRENT_DATE - INTERVAL '7 days'${extraWhere}
      ),
      lw_quotes AS (
        SELECT COALESCE(SUM(quote_count), 0) AS quotes
        FROM daily_quote_counts
        WHERE quote_date >= CURRENT_DATE - INTERVAL '14 days'
          AND quote_date < CURRENT_DATE - INTERVAL '7 days'${quoteBrokerClause}
      ),
      tw_conversion AS (
        SELECT
          CASE WHEN twq.quotes > 0
            THEN ROUND(tw.policies::numeric / twq.quotes * 100, 2) ELSE 0
          END AS conversion
        FROM this_week tw, tw_quotes twq
      ),
      lw_conversion AS (
        SELECT
          CASE WHEN lwq.quotes > 0
            THEN ROUND(lw.policies::numeric / lwq.quotes * 100, 2) ELSE 0
          END AS conversion
        FROM last_week lw, lw_quotes lwq
      )
      SELECT
        tw.policies     AS tw_policies,
        tw.premium      AS tw_premium,
        tw.agents       AS tw_agents,
        twq.quotes      AS tw_quotes,
        twc.conversion  AS tw_conversion,
        lw.policies     AS lw_policies,
        lw.premium      AS lw_premium,
        lw.agents       AS lw_agents,
        lwq.quotes      AS lw_quotes,
        lwc.conversion  AS lw_conversion,
        -- WoW changes
        CASE WHEN lw.policies > 0
          THEN ROUND((tw.policies - lw.policies)::numeric / lw.policies * 100, 2) ELSE 0
        END AS policies_wow,
        CASE WHEN lw.premium > 0
          THEN ROUND((tw.premium - lw.premium)::numeric / lw.premium * 100, 2) ELSE 0
        END AS premium_wow,
        CASE WHEN lw.agents > 0
          THEN ROUND((tw.agents - lw.agents)::numeric / lw.agents * 100, 2) ELSE 0
        END AS agents_wow,
        CASE WHEN lwq.quotes > 0
          THEN ROUND((twq.quotes - lwq.quotes)::numeric / lwq.quotes * 100, 2) ELSE 0
        END AS quotes_wow,
        CASE WHEN lwc.conversion > 0
          THEN ROUND((twc.conversion - lwc.conversion)::numeric / lwc.conversion * 100, 2) ELSE 0
        END AS conversion_wow,
        -- Flags
        CASE
          WHEN lw.policies = 0 THEN 'GREEN'
          WHEN (tw.policies - lw.policies)::numeric / lw.policies >= 0.05 THEN 'GREEN'
          WHEN (tw.policies - lw.policies)::numeric / lw.policies >= -0.05 THEN 'YELLOW'
          ELSE 'RED'
        END AS policies_flag,
        CASE
          WHEN lw.premium = 0 THEN 'GREEN'
          WHEN (tw.premium - lw.premium)::numeric / lw.premium >= 0.05 THEN 'GREEN'
          WHEN (tw.premium - lw.premium)::numeric / lw.premium >= -0.05 THEN 'YELLOW'
          ELSE 'RED'
        END AS premium_flag,
        CASE
          WHEN lw.agents = 0 THEN 'GREEN'
          WHEN (tw.agents - lw.agents)::numeric / lw.agents >= 0.05 THEN 'GREEN'
          WHEN (tw.agents - lw.agents)::numeric / lw.agents >= -0.05 THEN 'YELLOW'
          ELSE 'RED'
        END AS agents_flag,
        CASE
          WHEN lwq.quotes = 0 THEN 'GREEN'
          WHEN (twq.quotes - lwq.quotes)::numeric / lwq.quotes >= 0.05 THEN 'GREEN'
          WHEN (twq.quotes - lwq.quotes)::numeric / lwq.quotes >= -0.05 THEN 'YELLOW'
          ELSE 'RED'
        END AS quotes_flag,
        CASE
          WHEN lwc.conversion = 0 THEN 'GREEN'
          WHEN (twc.conversion - lwc.conversion)::numeric / GREATEST(lwc.conversion, 0.01) >= 0.05 THEN 'GREEN'
          WHEN (twc.conversion - lwc.conversion)::numeric / GREATEST(lwc.conversion, 0.01) >= -0.05 THEN 'YELLOW'
          ELSE 'RED'
        END AS conversion_flag
      FROM this_week tw, tw_quotes twq, last_week lw, lw_quotes lwq,
           tw_conversion twc, lw_conversion lwc;
    `;
    const result = await query(sql, params);
    return result.rows[0] || {};
  }),
);

// =========================================================================
// Start server (only in local dev — skipped on Vercel)
// =========================================================================

if (!process.env.VERCEL) {
  app.listen(PORT, async () => {
    console.log(`InsurTech API server running on http://localhost:${PORT}`);
    await testConnection();
    console.log('Available endpoint sections:');
    console.log('  /api/executive, /api/agents, /api/funnel, /api/products');
    console.log('  /api/brokers, /api/geographic, /api/insurers, /api/renewals');
    console.log('  /api/alerts, /api/operations, /api/advanced, /api/health');
    console.log('  Filter params: ?date_range=...&broker=...&product=...&state=...');
  });
}

// Export for Vercel serverless function
export default app;
