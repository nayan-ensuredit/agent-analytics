import { useFilteredApi } from '../api';
import KpiCard from '../components/KpiCard';
import ChartCard from '../components/ChartCard';
import DataTable from '../components/DataTable';
import type { Column } from '../components/DataTable';
import { formatINR, formatNumber, CHART_COLORS, inrTooltipFormatter } from '../utils';
import { Clock, AlertTriangle, CalendarCheck } from 'lucide-react';
import {
  BarChart, Bar,
  XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer,
} from 'recharts';

/* All API values come as strings from PostgreSQL */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type UpcomingRow = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AtRiskRow = Record<string, any>;

export default function Renewals() {
  const { data: upcoming, loading: upLoading } = useFilteredApi<UpcomingRow[]>('/api/renewals/upcoming', 300000);
  const { data: atRisk, loading: riskLoading } = useFilteredApi<AtRiskRow[]>('/api/renewals/at-risk', 300000);

  /* Convert upcoming data for charts */
  const upcomingChartData = (upcoming ?? []).map(d => ({
    expiry_bucket: d.expiry_bucket,
    policy_count: Number(d.policy_count),
    premium_at_stake: Number(d.premium_at_stake),
    agents_involved: Number(d.agents_involved),
    sort_order: Number(d.sort_order),
  })).sort((a, b) => a.sort_order - b.sort_order);

  /* Convert at-risk data */
  const atRiskChartData = (atRisk ?? []).map(d => ({
    expiry_window: d.expiry_window,
    policy_count: Number(d.policy_count),
    premium_at_risk: Number(d.premium_at_risk),
    product_types_affected: Number(d.product_types_affected),
  }));

  const riskColumns: Column[] = [
    { key: 'expiry_window', label: 'Window' },
    { key: 'policy_count', label: 'Policies', align: 'right', format: (v) => formatNumber(v) },
    { key: 'premium_at_risk', label: 'Premium at Risk', align: 'right', format: (v) => formatINR(v) },
    { key: 'product_types_affected', label: 'Product Types', align: 'right', format: (v) => formatNumber(v) },
  ];

  const kpiIcons = [
    <CalendarCheck key="30d" className="w-5 h-5" />,
    <Clock key="60d" className="w-5 h-5" />,
    <AlertTriangle key="90d" className="w-5 h-5" />,
  ];
  const kpiColors = ['#10B981', '#F59E0B', '#EF4444'];

  return (
    <div className="space-y-6">
      {/* Upcoming Renewal KPI Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
        {upLoading ? (
          [0, 1, 2].map(i => (
            <div key={i} className="bg-white rounded-xl shadow-sm border border-slate-200 p-6 animate-pulse">
              <div className="h-3 w-20 bg-slate-200 rounded mb-3" />
              <div className="h-8 w-32 bg-slate-200 rounded" />
            </div>
          ))
        ) : (
          upcomingChartData.map((item, i) => (
            <KpiCard
              key={item.expiry_bucket}
              title={`${item.expiry_bucket} Renewals`}
              value={formatNumber(item.policy_count)}
              subtitle={`${formatINR(item.premium_at_stake)} premium at stake`}
              icon={kpiIcons[i]}
              color={kpiColors[i]}
            />
          ))
        )}
        {!upLoading && upcomingChartData.length === 0 && (
          <div className="col-span-3 text-center text-sm text-slate-400 py-8">
            No upcoming renewal data available
          </div>
        )}
      </div>

      {/* Renewal pipeline bar chart */}
      {upcomingChartData.length > 0 && (
        <ChartCard title="Renewal Pipeline" subtitle="Premium at risk by time window" loading={upLoading}>
          <ResponsiveContainer width="100%" height={250}>
            <BarChart data={upcomingChartData}>
              <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
              <XAxis dataKey="expiry_bucket" tick={{ fontSize: 12 }} stroke="#94a3b8" />
              <YAxis tick={{ fontSize: 12 }} stroke="#94a3b8" tickFormatter={(v: unknown) => formatINR(v)} />
              <Tooltip formatter={(value: unknown, name: string | undefined) => {
                if (name === 'Premium' || name === 'premium_at_stake') return [inrTooltipFormatter(value), 'Premium'];
                return [formatNumber(value), 'Policies'];
              }} />
              <Legend />
              <Bar dataKey="policy_count" fill={CHART_COLORS[0]} name="Policies" radius={[4, 4, 0, 0]} />
              <Bar dataKey="premium_at_stake" fill={CHART_COLORS[1]} name="Premium" radius={[4, 4, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
          <div className="mt-3 p-3 bg-amber-50 rounded-lg text-sm text-amber-800">
            <strong>Insight:</strong> Prioritize 30-day renewals immediately. Assign dedicated renewal teams and automate reminder workflows to maximize retention rates.
          </div>
        </ChartCard>
      )}

      {/* Premium at Risk Table */}
      <ChartCard title="Premium at Risk (Expired, Not Renewed)" subtitle="Expired policies grouped by time window" loading={riskLoading}>
        {atRiskChartData.length > 0 ? (
          <>
            <DataTable
              columns={riskColumns}
              data={atRiskChartData as unknown as Record<string, unknown>[]}
              pageSize={10}
            />
            <div className="mt-3 p-3 bg-red-50 rounded-lg text-sm text-red-800">
              <strong>Insight:</strong> Every expired policy without renewal is lost revenue. Contact policyholders within 7 days of expiry for highest win-back rates. After 30 days, win-back probability drops below 20%.
            </div>
          </>
        ) : (
          <p className="text-sm text-slate-400 text-center py-12">No at-risk data available</p>
        )}
      </ChartCard>
    </div>
  );
}
