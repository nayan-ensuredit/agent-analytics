import { useFilteredApi } from '../api';
import KpiCard from '../components/KpiCard';
import ChartCard from '../components/ChartCard';
import { formatINR, formatNumber, formatPercent, CHART_COLORS, inrTooltipFormatter } from '../utils';
import {
  FileText, IndianRupee, Users, Receipt, TrendingUp, BarChart3,
} from 'lucide-react';
import {
  LineChart, Line, BarChart, Bar,
  XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer,
} from 'recharts';

/* API returns all values as strings from PostgreSQL */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type KpiData = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type GrowthPoint = Record<string, any>;

interface ConcentrationData {
  top_broker_name: string;
  top_broker_premium: string;
  top_broker_pct: string;
  top10_agents_pct: string;
  top10_agents_premium: string;
  total_6m_agent_premium: string;
  top5_agents: Array<{ agent_id: number; agent_name: string; agent_premium: number }>;
}

export default function Executive() {
  const { data: kpi, loading: kpiLoading } = useFilteredApi<KpiData>('/api/executive/kpis', 300000);
  const { data: growth, loading: growthLoading } = useFilteredApi<GrowthPoint[]>('/api/executive/growth', 300000);
  const { data: concentration, loading: concLoading } = useFilteredApi<ConcentrationData>('/api/executive/concentration', 300000);

  /* Convert growth data string values to numbers for Recharts */
  const growthChartData = (growth ?? []).map(d => ({
    month: d.month,
    policies: Number(d.policies),
    total_premium: Number(d.total_premium),
  }));

  /* Reshape concentration object into chart-friendly array */
  const concentrationChartData = concentration ? [
    { name: concentration.top_broker_name, premium: Number(concentration.top_broker_premium), type: 'broker' },
    ...(concentration.top5_agents ?? []).map(a => ({
      name: a.agent_name,
      premium: Number(a.agent_premium),
      type: 'agent',
    })),
  ] : [];

  return (
    <div className="space-y-6">
      {/* KPI Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        <KpiCard
          title="Policies (MTD)"
          value={kpiLoading ? '...' : formatNumber(kpi?.total_policies)}
          icon={<FileText className="w-5 h-5" />}
          color="#3B82F6"
        />
        <KpiCard
          title="Premium (MTD)"
          value={kpiLoading ? '...' : formatINR(kpi?.total_premium)}
          icon={<IndianRupee className="w-5 h-5" />}
          color="#10B981"
        />
        <KpiCard
          title="Active Agents"
          value={kpiLoading ? '...' : formatNumber(kpi?.active_agents)}
          icon={<Users className="w-5 h-5" />}
          color="#8B5CF6"
        />
        <KpiCard
          title="Avg Ticket Size"
          value={kpiLoading ? '...' : formatINR(kpi?.avg_ticket)}
          icon={<Receipt className="w-5 h-5" />}
          color="#F59E0B"
        />
        <KpiCard
          title="Quote-to-Policy"
          value={kpiLoading ? '...' : formatPercent(kpi?.conversion_rate)}
          icon={<TrendingUp className="w-5 h-5" />}
          color="#06B6D4"
        />
        <KpiCard
          title="MoM Growth"
          value={kpiLoading ? '...' : formatPercent(kpi?.policies_mom_pct)}
          delta={kpi?.policies_mom_pct}
          icon={<BarChart3 className="w-5 h-5" />}
          color="#EC4899"
        />
      </div>

      {/* Charts Row */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* 12-Month Sales Trend */}
        <ChartCard title="12-Month Sales Trend" subtitle="Policies and premium over time" loading={growthLoading}>
          {growthChartData.length > 0 ? (
            <>
              <ResponsiveContainer width="100%" height={300}>
                <LineChart data={growthChartData}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
                  <XAxis dataKey="month" tick={{ fontSize: 12 }} stroke="#94a3b8" />
                  <YAxis
                    yAxisId="left"
                    tick={{ fontSize: 12 }}
                    stroke="#94a3b8"
                    label={{ value: 'Policies', angle: -90, position: 'insideLeft', style: { fontSize: 11, fill: '#94a3b8' } }}
                  />
                  <YAxis
                    yAxisId="right"
                    orientation="right"
                    tick={{ fontSize: 12 }}
                    stroke="#94a3b8"
                    tickFormatter={(v: unknown) => formatINR(v)}
                    label={{ value: 'Premium', angle: 90, position: 'insideRight', style: { fontSize: 11, fill: '#94a3b8' } }}
                  />
                  <Tooltip formatter={(value: unknown, name: string | undefined) => [name === 'total_premium' ? inrTooltipFormatter(value) : formatNumber(value), name === 'total_premium' ? 'Premium' : 'Policies']} />
                  <Legend />
                  <Line yAxisId="left" type="monotone" dataKey="policies" stroke={CHART_COLORS[0]} strokeWidth={2} dot={{ r: 3 }} name="Policies" />
                  <Line yAxisId="right" type="monotone" dataKey="total_premium" stroke={CHART_COLORS[1]} strokeWidth={2} dot={{ r: 3 }} name="Premium" />
                </LineChart>
              </ResponsiveContainer>
              <div className="mt-3 p-3 bg-blue-50 rounded-lg text-sm text-blue-800">
                <strong>Insight:</strong> Track monthly policy and premium trajectories to identify seasonal patterns and growth momentum. Sustained upward trend indicates healthy business growth.
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-400 text-center py-12">No growth data available</p>
          )}
        </ChartCard>

        {/* Revenue Concentration */}
        <ChartCard title="Revenue Concentration" subtitle="Top brokers and agents by premium" loading={concLoading}>
          {concentrationChartData.length > 0 ? (
            <>
              <ResponsiveContainer width="100%" height={300}>
                <BarChart data={concentrationChartData} layout="vertical" margin={{ left: 20 }}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
                  <XAxis type="number" tick={{ fontSize: 12 }} stroke="#94a3b8" tickFormatter={(v: unknown) => formatINR(v)} />
                  <YAxis type="category" dataKey="name" tick={{ fontSize: 11 }} stroke="#94a3b8" width={120} />
                  <Tooltip formatter={(value: unknown) => [inrTooltipFormatter(value), 'Premium']} />
                  <Bar dataKey="premium" radius={[0, 4, 4, 0]}>
                    {concentrationChartData.map((_entry, index) => {
                      const barColor = _entry.type === 'broker' ? CHART_COLORS[0] : CHART_COLORS[2];
                      return <rect key={index} fill={barColor} />;
                    })}
                  </Bar>
                </BarChart>
              </ResponsiveContainer>
              {/* Summary stats */}
              {concentration && (
                <div className="flex flex-wrap gap-3 mt-3">
                  <div className="px-3 py-1.5 bg-slate-100 rounded-full text-xs font-medium text-slate-700">
                    Top Broker: {formatPercent(concentration.top_broker_pct)} of premium
                  </div>
                  <div className="px-3 py-1.5 bg-slate-100 rounded-full text-xs font-medium text-slate-700">
                    Top 10 Agents: {formatPercent(concentration.top10_agents_pct)} of agent premium
                  </div>
                </div>
              )}
              <div className="mt-3 p-3 bg-amber-50 rounded-lg text-sm text-amber-800">
                <strong>Insight:</strong> High revenue concentration in few entities is a risk. Diversify distribution to reduce dependency on top performers.
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-400 text-center py-12">No concentration data available</p>
          )}
        </ChartCard>
      </div>
    </div>
  );
}
