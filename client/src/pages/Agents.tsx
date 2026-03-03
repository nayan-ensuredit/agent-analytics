import { useFilteredApi } from '../api';
import ChartCard from '../components/ChartCard';
import { formatNumber, formatPercent, CHART_COLORS } from '../utils';
import {
  PieChart, Pie, Cell, BarChart, Bar,
  XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer,
} from 'recharts';

/* All API values come as strings from PostgreSQL */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type SegmentItem = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type CohortItem = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type DistBucket = Record<string, any>;

export default function Agents() {
  const { data: segmentation, loading: segLoading } = useFilteredApi<SegmentItem[]>('/api/agents/segmentation', 300000);
  const { data: activation, loading: actLoading } = useFilteredApi<CohortItem[]>('/api/agents/activation', 300000);
  const { data: distribution, loading: distLoading } = useFilteredApi<DistBucket[]>('/api/agents/performance-distribution', 300000);

  /* Convert string values to numbers for Recharts */
  const segChartData = (segmentation ?? []).map(d => ({
    segment: d.segment,
    agent_count: Number(d.agent_count),
    total_premium: Number(d.total_premium),
    total_sales: Number(d.total_sales),
  }));

  const totalAgents = segChartData.reduce((sum, d) => sum + d.agent_count, 0);

  const actChartData = (activation ?? []).map(d => ({
    join_month: d.join_month,
    total_joined: Number(d.total_joined),
    ever_sold: Number(d.ever_sold),
    activation_rate: Number(d.activation_rate),
  }));

  const distChartData = (distribution ?? []).map(d => ({
    bucket: d.bucket,
    agent_count: Number(d.agent_count),
    sort_order: Number(d.sort_order),
  })).sort((a, b) => a.sort_order - b.sort_order);

  return (
    <div className="space-y-6">
      {/* Insight Callout */}
      <div className="p-4 bg-amber-50 border border-amber-200 rounded-xl">
        <p className="text-sm text-amber-900">
          <strong>Key Finding:</strong> Only a small fraction of agents are active monthly. A handful of power users drive the vast majority of volume. Activating dormant agents represents the single largest growth opportunity.
        </p>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Agent Segmentation Donut */}
        <ChartCard title="Agent Segmentation" subtitle="Star / Rising / Occasional / Dormant / Dead" loading={segLoading}>
          {segChartData.length > 0 ? (
            <>
              <ResponsiveContainer width="100%" height={300}>
                <PieChart>
                  <Pie
                    data={segChartData}
                    cx="50%"
                    cy="50%"
                    innerRadius={70}
                    outerRadius={110}
                    dataKey="agent_count"
                    nameKey="segment"
                    label={((props: { segment?: string; agent_count?: number }) => {
                      const pct = totalAgents > 0 ? ((props.agent_count ?? 0) / totalAgents * 100) : 0;
                      if (pct < 3) return null; // Don't label tiny slices
                      return `${props.segment ?? ''}: ${pct.toFixed(1)}%`;
                    }
                    // eslint-disable-next-line @typescript-eslint/no-explicit-any
                    ) as any}
                    labelLine={{ stroke: '#94a3b8' }}
                  >
                    {segChartData.map((_entry, index) => (
                      <Cell key={index} fill={CHART_COLORS[index % CHART_COLORS.length]} />
                    ))}
                  </Pie>
                  <Tooltip formatter={(value: unknown) => [formatNumber(value), 'Agents']} />
                  <Legend />
                </PieChart>
              </ResponsiveContainer>
              <div className="mt-3 p-3 bg-blue-50 rounded-lg text-sm text-blue-800">
                <strong>Insight:</strong> Focus retention programs on Rising agents and reactivation campaigns on Dormant agents. Dead agents should be pruned from active lists to improve reporting accuracy.
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-400 text-center py-12">No segmentation data available</p>
          )}
        </ChartCard>

        {/* Cohort Activation Rates */}
        <ChartCard title="Cohort Activation Rates" subtitle="Activation rate by agent join month" loading={actLoading}>
          {actChartData.length > 0 ? (
            <>
              <ResponsiveContainer width="100%" height={300}>
                <BarChart data={actChartData}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
                  <XAxis dataKey="join_month" tick={{ fontSize: 11 }} stroke="#94a3b8" />
                  <YAxis tick={{ fontSize: 12 }} stroke="#94a3b8" tickFormatter={(v: number) => `${v}%`} />
                  <Tooltip formatter={(value: unknown, name: string | undefined) => [
                    name === 'activation_rate' ? formatPercent(value) : formatNumber(value),
                    name === 'activation_rate' ? 'Activation Rate' : name === 'total_joined' ? 'Total Joined' : 'Ever Sold'
                  ]} />
                  <Legend />
                  <Bar dataKey="activation_rate" fill={CHART_COLORS[0]} radius={[4, 4, 0, 0]} name="Activation Rate" />
                </BarChart>
              </ResponsiveContainer>
              <div className="mt-3 p-3 bg-emerald-50 rounded-lg text-sm text-emerald-800">
                <strong>Insight:</strong> Recent cohorts should have higher activation rates if onboarding improvements are working. Declining rates indicate process issues that need immediate attention.
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-400 text-center py-12">No activation data available</p>
          )}
        </ChartCard>
      </div>

      {/* Performance Distribution */}
      <ChartCard title="Performance Distribution" subtitle="Agents bucketed by policy count" loading={distLoading}>
        {distChartData.length > 0 ? (
          <>
            <ResponsiveContainer width="100%" height={300}>
              <BarChart data={distChartData}>
                <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
                <XAxis dataKey="bucket" tick={{ fontSize: 11 }} stroke="#94a3b8" />
                <YAxis tick={{ fontSize: 12 }} stroke="#94a3b8" />
                <Tooltip formatter={(value: unknown) => [formatNumber(value), 'Agents']} />
                <Bar dataKey="agent_count" fill={CHART_COLORS[4]} radius={[4, 4, 0, 0]} name="Agents" />
              </BarChart>
            </ResponsiveContainer>
            <div className="mt-3 p-3 bg-blue-50 rounded-lg text-sm text-blue-800">
              <strong>Insight:</strong> A heavy left-skew indicates most agents sell very few policies. Gamification and incentive programs should target the middle buckets to move agents up the performance curve.
            </div>
          </>
        ) : (
          <p className="text-sm text-slate-400 text-center py-12">No distribution data available</p>
        )}
      </ChartCard>
    </div>
  );
}
