import { useFilteredApi } from '../api';
import KpiCard from '../components/KpiCard';
import ChartCard from '../components/ChartCard';
import StatusBadge from '../components/StatusBadge';
import { formatINR, formatNumber, formatPercent, toNum } from '../utils';
import { AlertTriangle, TrendingDown, Users, ShieldAlert } from 'lucide-react';

/* All API values come as strings from PostgreSQL */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type RevenueAtRiskData = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type WeeklyPulseData = Record<string, any>;

export default function Advanced() {
  const { data: risk, loading: riskLoading } = useFilteredApi<RevenueAtRiskData>('/api/advanced/revenue-at-risk', 300000);
  const { data: pulse, loading: pulseLoading } = useFilteredApi<WeeklyPulseData>('/api/advanced/weekly-pulse', 300000);

  /* Helper to get flag color for StatusBadge */
  const flagColor = (flag: string | undefined) => {
    if (!flag) return 'green';
    const f = String(flag).toUpperCase();
    if (f === 'RED') return 'red';
    if (f === 'YELLOW') return 'yellow';
    return 'green';
  };

  return (
    <div className="space-y-6">
      {/* Revenue at Risk Section */}
      <div>
        <h3 className="text-lg font-semibold text-slate-800 mb-4">Revenue at Risk Dashboard</h3>
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <KpiCard
            title="Total 6-Month Premium"
            value={riskLoading ? '...' : formatINR(risk?.total_6m_premium)}
            subtitle="Combined premium base"
            icon={<ShieldAlert className="w-5 h-5" />}
            color="#3B82F6"
          />
          <KpiCard
            title="Broker Concentration"
            value={riskLoading ? '...' : formatINR(risk?.top_broker_premium)}
            subtitle={riskLoading ? '' : `${formatPercent(risk?.broker_concentration_pct)} of total`}
            icon={<TrendingDown className="w-5 h-5" />}
            color="#EF4444"
          />
          <KpiCard
            title="Agent Dependency"
            value={riskLoading ? '...' : formatINR(risk?.top10_agents_premium)}
            subtitle={riskLoading ? '' : `Top 10 agents: ${formatPercent(risk?.agent_dependency_pct)}`}
            icon={<Users className="w-5 h-5" />}
            color="#F59E0B"
          />
          <KpiCard
            title="Renewal Leakage"
            value={riskLoading ? '...' : formatINR(risk?.renewal_leakage_premium)}
            subtitle={riskLoading ? '' : `${formatNumber(risk?.renewal_leakage_policies)} policies expired`}
            icon={<AlertTriangle className="w-5 h-5" />}
            color="#DC2626"
          />
        </div>

        {/* Risk Summary */}
        <div className="mt-4 p-4 bg-red-50 border border-red-200 rounded-xl">
          <p className="text-sm text-red-900">
            <strong>Insight:</strong> Revenue concentration in a single broker ({formatPercent(risk?.broker_concentration_pct)}) is extremely high. Renewal leakage of {formatINR(risk?.renewal_leakage_premium)} represents policies that expired without being renewed. Address broker dependency and renewal automation as top priorities.
          </p>
        </div>
      </div>

      {/* Weekly Pulse */}
      <ChartCard title="Weekly Pulse" subtitle="This week vs last week performance" loading={pulseLoading}>
        {pulse ? (
          <div className="space-y-6">
            {/* Key Metrics Grid */}
            <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-4">
              <div className="p-3 bg-slate-50 rounded-lg">
                <div className="flex items-center justify-between mb-1">
                  <p className="text-xs text-slate-500 uppercase tracking-wider">Policies</p>
                  <StatusBadge status={flagColor(pulse.policies_flag)} label={String(pulse.policies_flag ?? '')} />
                </div>
                <p className="text-xl font-bold text-slate-900 mt-1">{formatNumber(pulse.tw_policies)}</p>
                <p className={`text-xs font-medium mt-1 ${toNum(pulse.policies_wow) >= 0 ? 'text-emerald-600' : 'text-red-600'}`}>
                  {toNum(pulse.policies_wow) >= 0 ? '+' : ''}{formatPercent(pulse.policies_wow)} WoW
                </p>
              </div>
              <div className="p-3 bg-slate-50 rounded-lg">
                <div className="flex items-center justify-between mb-1">
                  <p className="text-xs text-slate-500 uppercase tracking-wider">Premium</p>
                  <StatusBadge status={flagColor(pulse.premium_flag)} label={String(pulse.premium_flag ?? '')} />
                </div>
                <p className="text-xl font-bold text-slate-900 mt-1">{formatINR(pulse.tw_premium)}</p>
                <p className={`text-xs font-medium mt-1 ${toNum(pulse.premium_wow) >= 0 ? 'text-emerald-600' : 'text-red-600'}`}>
                  {toNum(pulse.premium_wow) >= 0 ? '+' : ''}{formatPercent(pulse.premium_wow)} WoW
                </p>
              </div>
              <div className="p-3 bg-slate-50 rounded-lg">
                <div className="flex items-center justify-between mb-1">
                  <p className="text-xs text-slate-500 uppercase tracking-wider">Active Agents</p>
                  <StatusBadge status={flagColor(pulse.agents_flag)} label={String(pulse.agents_flag ?? '')} />
                </div>
                <p className="text-xl font-bold text-slate-900 mt-1">{formatNumber(pulse.tw_agents)}</p>
                <p className={`text-xs font-medium mt-1 ${toNum(pulse.agents_wow) >= 0 ? 'text-emerald-600' : 'text-red-600'}`}>
                  {toNum(pulse.agents_wow) >= 0 ? '+' : ''}{formatPercent(pulse.agents_wow)} WoW
                </p>
              </div>
              <div className="p-3 bg-slate-50 rounded-lg">
                <div className="flex items-center justify-between mb-1">
                  <p className="text-xs text-slate-500 uppercase tracking-wider">Quotes</p>
                  <StatusBadge status={flagColor(pulse.quotes_flag)} label={String(pulse.quotes_flag ?? '')} />
                </div>
                <p className="text-xl font-bold text-slate-900 mt-1">{formatNumber(pulse.tw_quotes)}</p>
                <p className={`text-xs font-medium mt-1 ${toNum(pulse.quotes_wow) >= 0 ? 'text-emerald-600' : 'text-red-600'}`}>
                  {toNum(pulse.quotes_wow) >= 0 ? '+' : ''}{formatPercent(pulse.quotes_wow)} WoW
                </p>
              </div>
              <div className="p-3 bg-slate-50 rounded-lg">
                <div className="flex items-center justify-between mb-1">
                  <p className="text-xs text-slate-500 uppercase tracking-wider">Conversion</p>
                  <StatusBadge status={flagColor(pulse.conversion_flag)} label={String(pulse.conversion_flag ?? '')} />
                </div>
                <p className="text-xl font-bold text-slate-900 mt-1">{formatPercent(pulse.tw_conversion)}</p>
                <p className={`text-xs font-medium mt-1 ${toNum(pulse.conversion_wow) >= 0 ? 'text-emerald-600' : 'text-red-600'}`}>
                  {toNum(pulse.conversion_wow) >= 0 ? '+' : ''}{formatPercent(pulse.conversion_wow)} WoW
                </p>
              </div>
            </div>

            {/* Last Week Comparison */}
            <div className="p-4 bg-slate-50 rounded-lg">
              <p className="text-xs text-slate-500 uppercase tracking-wider font-medium mb-3">Last Week Comparison</p>
              <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
                <div>
                  <p className="text-xs text-slate-400">LW Policies</p>
                  <p className="text-sm font-semibold text-slate-700">{formatNumber(pulse.lw_policies)}</p>
                </div>
                <div>
                  <p className="text-xs text-slate-400">LW Premium</p>
                  <p className="text-sm font-semibold text-slate-700">{formatINR(pulse.lw_premium)}</p>
                </div>
                <div>
                  <p className="text-xs text-slate-400">LW Agents</p>
                  <p className="text-sm font-semibold text-slate-700">{formatNumber(pulse.lw_agents)}</p>
                </div>
                <div>
                  <p className="text-xs text-slate-400">LW Quotes</p>
                  <p className="text-sm font-semibold text-slate-700">{formatNumber(pulse.lw_quotes)}</p>
                </div>
                <div>
                  <p className="text-xs text-slate-400">LW Conversion</p>
                  <p className="text-sm font-semibold text-slate-700">{formatPercent(pulse.lw_conversion)}</p>
                </div>
              </div>
            </div>

            <div className="p-3 bg-blue-50 rounded-lg text-sm text-blue-800">
              <strong>Insight:</strong> The weekly pulse is your executive snapshot. If policies are up but premium is flat, ticket sizes are shrinking. If active agents decline despite stable policies, top performers are compensating for attrition.
            </div>
          </div>
        ) : (
          <p className="text-sm text-slate-400 text-center py-12">No weekly pulse data available</p>
        )}
      </ChartCard>
    </div>
  );
}
