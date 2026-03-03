import { useFilteredApi } from '../api';
import KpiCard from '../components/KpiCard';
import ChartCard from '../components/ChartCard';
import DataTable from '../components/DataTable';
import type { Column } from '../components/DataTable';
import { formatINR, formatNumber, CHART_COLORS, toNum } from '../utils';
import { FileText, IndianRupee, Users, Activity } from 'lucide-react';
import {
  BarChart, Bar,
  XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer,
} from 'recharts';

/* All API values come as strings from PostgreSQL */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type TodayData = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type WeekData = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type LeaderboardRow = Record<string, any>;

export default function Operations() {
  const { data: today, loading: todayLoading } = useFilteredApi<TodayData>('/api/operations/today', 60000);
  const { data: weekComp, loading: weekLoading } = useFilteredApi<WeekData>('/api/operations/week-comparison', 300000);
  const { data: leaderboard, loading: leadLoading } = useFilteredApi<LeaderboardRow[]>('/api/operations/leaderboard', 300000);

  const leaderColumns: Column[] = [
    { key: '_rank', label: '#', align: 'center', format: (v) => {
      const rank = toNum(v);
      if (rank === 1) return <span className="text-amber-500 font-bold">1</span>;
      if (rank === 2) return <span className="text-slate-400 font-bold">2</span>;
      if (rank === 3) return <span className="text-amber-700 font-bold">3</span>;
      return <span className="text-slate-600">{rank}</span>;
    }},
    { key: 'agent_name', label: 'Agent' },
    { key: 'phone', label: 'Phone' },
    { key: 'policies', label: 'Policies', align: 'right', format: (v) => formatNumber(v) },
    { key: 'total_premium', label: 'Premium', align: 'right', format: (v) => formatINR(v) },
    { key: 'avg_ticket', label: 'Avg Ticket', align: 'right', format: (v) => formatINR(v) },
  ];

  /* Add rank to leaderboard data since API doesn't include it */
  const rankedLeaderboard = (leaderboard ?? []).map((row, i) => ({
    ...row,
    _rank: i + 1,
  }));

  /* Build week comparison bar chart data from the object */
  const weekChartData = weekComp ? [
    {
      metric: 'Policies',
      this_week: Number(weekComp.tw_policies),
      last_week: Number(weekComp.lw_policies),
      change_percent: Number(weekComp.policies_wow_pct),
    },
    {
      metric: 'Premium',
      this_week: Number(weekComp.tw_premium),
      last_week: Number(weekComp.lw_premium),
      change_percent: Number(weekComp.premium_wow_pct),
    },
    {
      metric: 'Agents',
      this_week: Number(weekComp.tw_agents),
      last_week: Number(weekComp.lw_agents),
      change_percent: Number(weekComp.agents_wow_pct),
    },
    {
      metric: 'Quotes',
      this_week: Number(weekComp.tw_quotes),
      last_week: Number(weekComp.lw_quotes),
      change_percent: Number(weekComp.quotes_wow_pct),
    },
  ] : [];

  /* Calculate deltas for today vs avg */
  const policyDelta = today ? toNum(today.policies_pct_of_avg) - 100 : undefined;
  const premiumDelta = today ? toNum(today.premium_pct_of_avg) - 100 : undefined;
  const agentDelta = today ? toNum(today.agents_pct_of_avg) - 100 : undefined;
  const quoteDelta = today ? toNum(today.quotes_pct_of_avg) - 100 : undefined;

  return (
    <div className="space-y-6">
      {/* Today's KPIs */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <KpiCard
          title="Policies Today"
          value={todayLoading ? '...' : formatNumber(today?.today_policies)}
          subtitle={todayLoading ? '' : `Avg: ${formatNumber(today?.avg30_policies)}/day`}
          delta={policyDelta}
          deltaLabel="vs avg"
          icon={<FileText className="w-5 h-5" />}
          color="#3B82F6"
        />
        <KpiCard
          title="Premium Today"
          value={todayLoading ? '...' : formatINR(today?.today_premium)}
          subtitle={todayLoading ? '' : `Avg: ${formatINR(today?.avg30_premium)}/day`}
          delta={premiumDelta}
          deltaLabel="vs avg"
          icon={<IndianRupee className="w-5 h-5" />}
          color="#10B981"
        />
        <KpiCard
          title="Active Agents Today"
          value={todayLoading ? '...' : formatNumber(today?.today_agents)}
          subtitle={todayLoading ? '' : `Avg: ${formatNumber(today?.avg30_agents)}/day`}
          delta={agentDelta}
          deltaLabel="vs avg"
          icon={<Users className="w-5 h-5" />}
          color="#8B5CF6"
        />
        <KpiCard
          title="Quotes Today"
          value={todayLoading ? '...' : formatNumber(today?.today_quotes)}
          subtitle={todayLoading ? '' : `Avg: ${formatNumber(today?.avg30_quotes)}/day`}
          delta={quoteDelta}
          deltaLabel="vs avg"
          icon={<Activity className="w-5 h-5" />}
          color="#F59E0B"
        />
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Week-over-Week Comparison */}
        <ChartCard title="This Week vs Last Week" subtitle="Key metrics compared side-by-side" loading={weekLoading}>
          {weekChartData.length > 0 ? (
            <>
              <ResponsiveContainer width="100%" height={300}>
                <BarChart data={weekChartData}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
                  <XAxis dataKey="metric" tick={{ fontSize: 11 }} stroke="#94a3b8" />
                  <YAxis tick={{ fontSize: 12 }} stroke="#94a3b8" />
                  <Tooltip formatter={(value: unknown) => [formatNumber(value), '']} />
                  <Legend />
                  <Bar dataKey="this_week" fill={CHART_COLORS[0]} name="This Week" radius={[4, 4, 0, 0]} />
                  <Bar dataKey="last_week" fill={CHART_COLORS[7]} name="Last Week" radius={[4, 4, 0, 0]} />
                </BarChart>
              </ResponsiveContainer>
              {/* Change summary */}
              <div className="flex flex-wrap gap-2 mt-3">
                {weekChartData.map((item) => {
                  const isPositive = item.change_percent >= 0;
                  return (
                    <div key={item.metric} className={`px-3 py-1.5 rounded-full text-xs font-medium ${isPositive ? 'bg-emerald-100 text-emerald-800' : 'bg-red-100 text-red-800'}`}>
                      {item.metric}: {isPositive ? '+' : ''}{item.change_percent.toFixed(1)}%
                    </div>
                  );
                })}
              </div>
              <div className="mt-3 p-3 bg-blue-50 rounded-lg text-sm text-blue-800">
                <strong>Insight:</strong> Week-over-week trends reveal short-term momentum. Consistent weekly declines warrant immediate operational review. Focus on metrics declining for 2+ consecutive weeks.
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-400 text-center py-12">No week comparison data available</p>
          )}
        </ChartCard>

        {/* Leaderboard */}
        <ChartCard title="Top 20 Agents This Month" subtitle="Agent performance leaderboard" loading={leadLoading}>
          {rankedLeaderboard.length > 0 ? (
            <>
              <DataTable
                columns={leaderColumns}
                data={rankedLeaderboard as unknown as Record<string, unknown>[]}
                pageSize={10}
              />
              <div className="mt-3 p-3 bg-emerald-50 rounded-lg text-sm text-emerald-800">
                <strong>Insight:</strong> Top performers set the benchmark. Study their workflows and replicate successful patterns. Publicly recognize leaders to drive healthy competition and motivate mid-tier agents.
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-400 text-center py-12">No leaderboard data available</p>
          )}
        </ChartCard>
      </div>
    </div>
  );
}
