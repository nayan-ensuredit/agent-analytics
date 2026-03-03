import { useFilteredApi } from '../api';
import KpiCard from '../components/KpiCard';
import ChartCard from '../components/ChartCard';
import DataTable from '../components/DataTable';
import type { Column } from '../components/DataTable';
import StatusBadge from '../components/StatusBadge';
import { formatNumber, formatINR, formatPercent, toNum } from '../utils';
import { AlertTriangle, TrendingDown, UserX, Clock } from 'lucide-react';
import type { ReactNode } from 'react';

/* All API values come as strings from PostgreSQL */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AlertSummaryData = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type DecliningAgentRow = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type StuckQuoterRow = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type InactiveAgentRow = Record<string, any>;

export default function Alerts() {
  const { data: summary, loading: sumLoading } = useFilteredApi<AlertSummaryData>('/api/alerts/summary', 60000);
  const { data: declining, loading: decLoading } = useFilteredApi<DecliningAgentRow[]>('/api/alerts/declining-agents', 300000);
  const { data: stuck, loading: stuckLoading } = useFilteredApi<StuckQuoterRow[]>('/api/alerts/stuck-quoters', 300000);
  const { data: inactive, loading: inactLoading } = useFilteredApi<InactiveAgentRow[]>('/api/alerts/inactive-agents', 300000);

  /* Compute total alerts from individual counts */
  const totalAlerts = summary
    ? toNum(summary.declining_agents_count) + toNum(summary.stuck_quoters_count) + toNum(summary.inactive_agents_count) + toNum(summary.expiring_renewals_count)
    : 0;

  const decliningColumns: Column[] = [
    { key: 'agent_name', label: 'Agent' },
    { key: 'agent_id', label: 'ID' },
    { key: 'phone', label: 'Phone' },
    { key: 'cur_quotes', label: 'Current Quotes', align: 'right', format: (v) => formatNumber(v) },
    { key: 'prev_quotes', label: 'Prev Quotes', align: 'right', format: (v) => formatNumber(v) },
    { key: 'decline_pct', label: 'Decline', align: 'right', format: (v) => {
      const pct = toNum(v);
      const color = pct > 50 ? 'text-red-600' : pct > 25 ? 'text-amber-600' : 'text-slate-600';
      return <span className={`font-medium ${color}`}>-{formatPercent(pct)}</span>;
    }},
    { key: 'lifetime_premium', label: 'Lifetime Premium', align: 'right', format: (v) => formatINR(v) },
  ];

  const stuckColumns: Column[] = [
    { key: 'agent_name', label: 'Agent' },
    { key: 'agent_id', label: 'ID' },
    { key: 'phone', label: 'Phone' },
    { key: 'total_quotes', label: 'Quotes', align: 'right', format: (v) => formatNumber(v) },
    { key: 'total_proposals', label: 'Proposals', align: 'right', format: (v) => formatNumber(v) },
    { key: 'total_policies', label: 'Policies', align: 'right', format: (v) => formatNumber(v) },
    { key: 'intervention_level', label: 'Level', format: (v) => {
      const level = String(v ?? '');
      const color = level === 'Critical' ? 'red' : level === 'Warning' ? 'yellow' : 'green';
      return <StatusBadge status={color} label={level} /> as ReactNode;
    }},
    { key: 'stuck_at', label: 'Stuck At' },
  ];

  const inactiveColumns: Column[] = [
    { key: 'agent_name', label: 'Agent' },
    { key: 'agent_id', label: 'ID' },
    { key: 'phone', label: 'Phone' },
    { key: 'last_login_date', label: 'Last Login', format: (v) => {
      if (!v) return '';
      const d = new Date(String(v));
      return d.toLocaleDateString('en-IN');
    }},
    { key: 'days_inactive', label: 'Days Inactive', align: 'right', format: (v) => {
      const days = toNum(v);
      const color = days > 30 ? 'text-red-600 font-bold' : days > 14 ? 'text-amber-600 font-medium' : 'text-slate-600';
      return <span className={color}>{days}d</span>;
    }},
    { key: 'lifetime_premium', label: 'Lifetime Premium', align: 'right', format: (v) => formatINR(v) },
    { key: 'inactivity_class', label: 'Status', format: (v) => {
      const cat = String(v ?? '');
      const color = cat.includes('30') ? 'red' : cat.includes('14') ? 'yellow' : 'green';
      return <StatusBadge status={color} label={cat} /> as ReactNode;
    }},
  ];

  return (
    <div className="space-y-6">
      {/* Alert Summary Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <KpiCard
          title="Total Alerts"
          value={sumLoading ? '...' : formatNumber(totalAlerts)}
          icon={<AlertTriangle className="w-5 h-5" />}
          color="#DC2626"
        />
        <KpiCard
          title="Declining Agents"
          value={sumLoading ? '...' : formatNumber(summary?.declining_agents_count)}
          icon={<TrendingDown className="w-5 h-5" />}
          color="#F59E0B"
        />
        <KpiCard
          title="Stuck Quoters"
          value={sumLoading ? '...' : formatNumber(summary?.stuck_quoters_count)}
          icon={<UserX className="w-5 h-5" />}
          color="#EF4444"
        />
        <KpiCard
          title="Inactive Agents"
          value={sumLoading ? '...' : formatNumber(summary?.inactive_agents_count)}
          icon={<Clock className="w-5 h-5" />}
          color="#8B5CF6"
        />
      </div>

      {/* Priority Alert Banner */}
      <div className="p-4 bg-red-50 border-l-4 border-red-500 rounded-r-xl">
        <p className="text-sm text-red-900">
          <strong>Action Required:</strong> Review and act on these alerts daily. Each declining agent and stuck quoter represents recoverable revenue. Prioritize by premium at risk.
        </p>
      </div>

      {/* Declining Agents */}
      <ChartCard title="Declining Agents" subtitle="Agents with significant month-over-month decline" loading={decLoading}>
        {declining && declining.length > 0 ? (
          <>
            <DataTable
              columns={decliningColumns}
              data={declining as unknown as Record<string, unknown>[]}
              pageSize={10}
            />
            <div className="mt-3 p-3 bg-red-50 rounded-lg text-sm text-red-800">
              <strong>Insight:</strong> Critical-level agents need immediate outreach within 24 hours. Warning-level agents should be contacted within the week. Track intervention success rates to refine the approach.
            </div>
          </>
        ) : (
          <p className="text-sm text-slate-400 text-center py-12">No declining agent alerts</p>
        )}
      </ChartCard>

      {/* Stuck Quoters */}
      <ChartCard title="Agents Quoting but Not Selling" subtitle="Agents generating quotes with zero or minimal closures" loading={stuckLoading}>
        {stuck && stuck.length > 0 ? (
          <>
            <DataTable
              columns={stuckColumns}
              data={stuck as unknown as Record<string, unknown>[]}
              pageSize={10}
            />
            <div className="mt-3 p-3 bg-amber-50 rounded-lg text-sm text-amber-800">
              <strong>Insight:</strong> These agents are engaged but failing to convert. Common causes: pricing issues, complex proposal process, or missing follow-up skills. Provide targeted training and simplified workflows.
            </div>
          </>
        ) : (
          <p className="text-sm text-slate-400 text-center py-12">No stuck quoter alerts</p>
        )}
      </ChartCard>

      {/* Inactive Agents */}
      <ChartCard title="Gone-Dark Agents" subtitle="Previously active agents with no recent activity" loading={inactLoading}>
        {inactive && inactive.length > 0 ? (
          <>
            <DataTable
              columns={inactiveColumns}
              data={inactive as unknown as Record<string, unknown>[]}
              pageSize={10}
            />
            <div className="mt-3 p-3 bg-blue-50 rounded-lg text-sm text-blue-800">
              <strong>Insight:</strong> 7-day inactive agents are still reactivatable with a simple check-in. 14-day agents need incentives. 30-day+ agents may have churned to competitors and need a win-back campaign.
            </div>
          </>
        ) : (
          <p className="text-sm text-slate-400 text-center py-12">No inactive agent alerts</p>
        )}
      </ChartCard>
    </div>
  );
}
