import { useFilteredApi } from '../api';
import ChartCard from '../components/ChartCard';
import DataTable from '../components/DataTable';
import type { Column } from '../components/DataTable';
import { formatNumber, formatPercent, CHART_COLORS } from '../utils';
import {
  BarChart, Bar,
  XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer,
  LineChart, Line,
} from 'recharts';

/* All API values come as strings from PostgreSQL */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type ConversionRow = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type ProductConvRow = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type StuckQuoterRow = Record<string, any>;

export default function Funnel() {
  const { data: conversion, loading: funnelLoading } = useFilteredApi<ConversionRow[]>('/api/funnel/conversion', 300000);
  const { data: byProduct, loading: prodLoading } = useFilteredApi<ProductConvRow[]>('/api/funnel/by-product', 300000);
  const { data: stuckQuoters, loading: stuckLoading } = useFilteredApi<StuckQuoterRow[]>('/api/funnel/stuck-quoters', 300000);

  const stuckColumns: Column[] = [
    { key: 'agent_name', label: 'Agent Name' },
    { key: 'agent_id', label: 'Agent ID' },
    { key: 'phone', label: 'Phone' },
    { key: 'total_quotes', label: 'Quotes', align: 'right', format: (v) => formatNumber(v) },
    { key: 'total_policies', label: 'Policies', align: 'right', format: (v) => formatNumber(v) },
  ];

  /* Convert monthly conversion data for line chart and build funnel totals */
  const convChartData = (conversion ?? []).map(d => ({
    activity_month: d.activity_month,
    total_quotes: Number(d.total_quotes),
    total_proposals: Number(d.total_proposals),
    total_policies: Number(d.total_policies),
    overall_conversion_rate: Number(d.overall_conversion_rate),
    quote_to_proposal_rate: Number(d.quote_to_proposal_rate),
    proposal_to_policy_rate: Number(d.proposal_to_policy_rate),
  }));

  /* Build funnel summary from the latest month's data or totals */
  const totals = convChartData.reduce(
    (acc, d) => ({
      quotes: acc.quotes + d.total_quotes,
      proposals: acc.proposals + d.total_proposals,
      policies: acc.policies + d.total_policies,
    }),
    { quotes: 0, proposals: 0, policies: 0 }
  );

  const funnelBarData = [
    { stage: 'Quotes', count: totals.quotes },
    { stage: 'Proposals', count: totals.proposals },
    { stage: 'Policies', count: totals.policies },
  ];

  /* Latest conversion rates */
  const latestConv = convChartData.length > 0 ? convChartData[convChartData.length - 1] : null;

  /* Convert by-product data for charts */
  const productChartData = (byProduct ?? []).map(d => ({
    product_type: d.product_type,
    quotes: Number(d.quotes),
    proposals: Number(d.proposals),
    policies: Number(d.policies),
  }));

  return (
    <div className="space-y-6">
      {/* Insight Callout */}
      <div className="p-4 bg-red-50 border border-red-200 rounded-xl">
        <p className="text-sm text-red-900">
          <strong>Quick Win:</strong> Thousands of agents are generating quotes but closing zero policies. This represents the #1 opportunity for immediate revenue uplift through targeted coaching and process simplification.
        </p>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Funnel Visualization */}
        <ChartCard title="Sales Funnel" subtitle="Quotes to Proposals to Policies with conversion rates" loading={funnelLoading}>
          {funnelBarData.length > 0 && totals.quotes > 0 ? (
            <>
              <ResponsiveContainer width="100%" height={200}>
                <BarChart data={funnelBarData} layout="vertical" margin={{ left: 20 }}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
                  <XAxis type="number" tick={{ fontSize: 12 }} stroke="#94a3b8" />
                  <YAxis type="category" dataKey="stage" tick={{ fontSize: 12 }} stroke="#94a3b8" width={100} />
                  <Tooltip formatter={(value: unknown) => [formatNumber(value), 'Count']} />
                  <Bar dataKey="count" radius={[0, 4, 4, 0]}>
                    {funnelBarData.map((_e, i) => {
                      const colors = ['#3B82F6', '#F59E0B', '#10B981'];
                      return <rect key={i} fill={colors[i % colors.length]} />;
                    })}
                  </Bar>
                </BarChart>
              </ResponsiveContainer>
              {/* Conversion rate badges */}
              {latestConv && (
                <div className="flex gap-3 mt-3 flex-wrap">
                  <div className="px-3 py-1.5 bg-slate-100 rounded-full text-xs font-medium text-slate-700">
                    Quote-to-Proposal: {formatPercent(latestConv.quote_to_proposal_rate)}
                  </div>
                  <div className="px-3 py-1.5 bg-slate-100 rounded-full text-xs font-medium text-slate-700">
                    Proposal-to-Policy: {formatPercent(latestConv.proposal_to_policy_rate)}
                  </div>
                  <div className="px-3 py-1.5 bg-slate-100 rounded-full text-xs font-medium text-slate-700">
                    Overall: {formatPercent(latestConv.overall_conversion_rate)}
                  </div>
                </div>
              )}
              {/* Monthly conversion rate trend */}
              {convChartData.length > 1 && (
                <div className="mt-4">
                  <p className="text-xs font-medium text-slate-500 mb-2 uppercase tracking-wider">Monthly Conversion Trend</p>
                  <ResponsiveContainer width="100%" height={150}>
                    <LineChart data={convChartData}>
                      <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
                      <XAxis dataKey="activity_month" tick={{ fontSize: 10 }} stroke="#94a3b8" />
                      <YAxis tick={{ fontSize: 10 }} stroke="#94a3b8" tickFormatter={(v: number) => `${v}%`} />
                      <Tooltip formatter={(value: unknown) => [formatPercent(value), 'Rate']} />
                      <Line type="monotone" dataKey="overall_conversion_rate" stroke={CHART_COLORS[1]} strokeWidth={2} dot={{ r: 2 }} name="Overall Rate" />
                    </LineChart>
                  </ResponsiveContainer>
                </div>
              )}
              <div className="mt-3 p-3 bg-blue-50 rounded-lg text-sm text-blue-800">
                <strong>Insight:</strong> Each funnel drop-off represents lost revenue. Focus on the largest absolute drop first to maximize impact per intervention.
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-400 text-center py-12">No funnel data available</p>
          )}
        </ChartCard>

        {/* Conversion by Product */}
        <ChartCard title="Conversion by Product Type" subtitle="Quote-to-policy rate by product" loading={prodLoading}>
          {productChartData.length > 0 ? (
            <>
              <ResponsiveContainer width="100%" height={300}>
                <BarChart data={productChartData}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
                  <XAxis dataKey="product_type" tick={{ fontSize: 11 }} stroke="#94a3b8" />
                  <YAxis tick={{ fontSize: 12 }} stroke="#94a3b8" />
                  <Tooltip formatter={(value: unknown, name: string | undefined) => [
                    formatNumber(value), name === 'quotes' ? 'Quotes' : name === 'proposals' ? 'Proposals' : 'Policies'
                  ]} />
                  <Legend />
                  <Bar dataKey="quotes" fill={CHART_COLORS[0]} name="Quotes" radius={[4, 4, 0, 0]} />
                  <Bar dataKey="proposals" fill={CHART_COLORS[2]} name="Proposals" radius={[4, 4, 0, 0]} />
                  <Bar dataKey="policies" fill={CHART_COLORS[1]} name="Policies" radius={[4, 4, 0, 0]} />
                </BarChart>
              </ResponsiveContainer>
              <div className="mt-3 p-3 bg-amber-50 rounded-lg text-sm text-amber-800">
                <strong>Insight:</strong> Products with high quote volume but low conversion need pricing or UX investigation. Products with high conversion are ready for volume scaling.
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-400 text-center py-12">No product conversion data available</p>
          )}
        </ChartCard>
      </div>

      {/* Stuck Quoters Table */}
      <ChartCard title="Top Agents Quoting but Not Selling" subtitle="Agents with quotes but zero or near-zero policies" loading={stuckLoading}>
        {stuckQuoters && stuckQuoters.length > 0 ? (
          <>
            <DataTable
              columns={stuckColumns}
              data={stuckQuoters as unknown as Record<string, unknown>[]}
              pageSize={10}
            />
            <div className="mt-3 p-3 bg-red-50 rounded-lg text-sm text-red-800">
              <strong>Insight:</strong> These agents are engaged (quoting) but failing to close. Assign sales coaches or simplify the proposal-to-policy flow to unlock this revenue.
            </div>
          </>
        ) : (
          <p className="text-sm text-slate-400 text-center py-12">No stuck quoter data available</p>
        )}
      </ChartCard>
    </div>
  );
}
