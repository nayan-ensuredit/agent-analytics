import { useMemo } from 'react';
import { useFilteredApi } from '../api';
import ChartCard from '../components/ChartCard';
import DataTable from '../components/DataTable';
import type { Column } from '../components/DataTable';
import StatusBadge from '../components/StatusBadge';
import { formatINR, formatNumber, formatPercent, CHART_COLORS, inrTooltipFormatter } from '../utils';
import {
  LineChart, Line,
  XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer,
} from 'recharts';
import type { ReactNode } from 'react';

/* All API values come as strings from PostgreSQL */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type BrokerPerfRow = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type DormantBrokerRow = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type BrokerTrendRow = Record<string, any>;

export default function Brokers() {
  const { data: performance, loading: perfLoading } = useFilteredApi<BrokerPerfRow[]>('/api/brokers/performance', 300000);
  const { data: dormant, loading: dormLoading } = useFilteredApi<DormantBrokerRow[]>('/api/brokers/dormant', 300000);
  const { data: trend, loading: trendLoading } = useFilteredApi<BrokerTrendRow[]>('/api/brokers/trend', 300000);

  const perfColumns: Column[] = [
    { key: 'broker_name', label: 'Broker' },
    {
      key: 'tier', label: 'Tier',
      format: (v) => {
        const tier = String(v ?? '');
        const color = tier === 'Platinum' ? 'green' : tier === 'Gold' ? 'yellow' : 'red';
        return <StatusBadge status={color} label={tier} /> as ReactNode;
      }
    },
    { key: 'total_policies', label: 'Policies', align: 'right', format: (v) => formatNumber(v) },
    { key: 'total_premium', label: 'Premium', align: 'right', format: (v) => formatINR(v) },
    { key: 'total_quotes', label: 'Quotes', align: 'right', format: (v) => formatNumber(v) },
    { key: 'active_months', label: 'Active Months', align: 'right', format: (v) => formatNumber(v) },
    { key: 'conversion_rate', label: 'Conv. Rate', align: 'right', format: (v) => formatPercent(v) },
  ];

  const dormantColumns: Column[] = [
    { key: 'broker_name', label: 'Broker' },
    { key: 'total_quotes', label: 'Quotes', align: 'right', format: (v) => formatNumber(v) },
    { key: 'total_policies', label: 'Policies', align: 'right', format: (v) => formatNumber(v) },
    {
      key: 'status', label: 'Status',
      format: (v) => <StatusBadge status="red" label={String(v ?? '')} /> as ReactNode,
    },
  ];

  /* Pivot trend data: flat rows -> { month, BrokerA: premium, BrokerB: premium, ... } */
  const { pivotedTrend, brokerKeys } = useMemo(() => {
    if (!trend || trend.length === 0) return { pivotedTrend: [], brokerKeys: [] };

    const monthMap = new Map<string, Record<string, number>>();
    const brokerSet = new Set<string>();

    for (const row of trend) {
      const month = row.sold_month as string;
      const broker = row.broker_name as string;
      const premium = Number(row.total_premium);
      brokerSet.add(broker);
      if (!monthMap.has(month)) monthMap.set(month, {});
      const entry = monthMap.get(month)!;
      entry[broker] = (entry[broker] ?? 0) + premium;
    }

    const keys = Array.from(brokerSet);
    const pivoted = Array.from(monthMap.entries())
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([month, brokers]) => ({ month, ...brokers }));

    return { pivotedTrend: pivoted, brokerKeys: keys };
  }, [trend]);

  return (
    <div className="space-y-6">
      {/* Insight Callout */}
      <div className="p-4 bg-amber-50 border border-amber-200 rounded-xl">
        <p className="text-sm text-amber-900">
          <strong>Key Finding:</strong> Revenue concentration in top brokers is extremely high. Multiple brokers have zero conversions despite active quoting, representing wasted distribution potential.
        </p>
      </div>

      {/* Broker Scorecard */}
      <ChartCard title="Broker Scorecard" subtitle="Performance rankings with tier badges" loading={perfLoading}>
        {performance && performance.length > 0 ? (
          <>
            <DataTable
              columns={perfColumns}
              data={performance as unknown as Record<string, unknown>[]}
              pageSize={10}
            />
            <div className="mt-3 p-3 bg-blue-50 rounded-lg text-sm text-blue-800">
              <strong>Insight:</strong> Platinum brokers should receive priority support. Gold brokers are candidates for upgrade with the right incentive programs. Review underperforming brokers quarterly for continuation decisions.
            </div>
          </>
        ) : (
          <p className="text-sm text-slate-400 text-center py-12">No broker performance data available</p>
        )}
      </ChartCard>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Zero-Conversion Brokers */}
        <ChartCard title="Zero-Conversion Brokers" subtitle="Brokers with quotes but no policies" loading={dormLoading}>
          {dormant && dormant.length > 0 ? (
            <>
              <DataTable
                columns={dormantColumns}
                data={dormant as unknown as Record<string, unknown>[]}
                pageSize={8}
              />
              <div className="mt-3 p-3 bg-red-50 rounded-lg text-sm text-red-800">
                <strong>Insight:</strong> These brokers are generating overhead without revenue. Investigate integration issues, pricing competitiveness, or agent quality for each broker. Consider suspending inactive partnerships.
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-400 text-center py-12">No dormant broker data available</p>
          )}
        </ChartCard>

        {/* Top Broker Trends */}
        <ChartCard title="Top Broker Monthly Trends" subtitle="Premium trend for leading brokers" loading={trendLoading}>
          {pivotedTrend.length > 0 ? (
            <>
              <ResponsiveContainer width="100%" height={300}>
                <LineChart data={pivotedTrend}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
                  <XAxis dataKey="month" tick={{ fontSize: 11 }} stroke="#94a3b8" />
                  <YAxis tick={{ fontSize: 12 }} stroke="#94a3b8" tickFormatter={(v: unknown) => formatINR(v)} />
                  <Tooltip formatter={(value: unknown) => [inrTooltipFormatter(value), 'Premium']} />
                  <Legend />
                  {brokerKeys.map((key, i) => (
                    <Line
                      key={key}
                      type="monotone"
                      dataKey={key}
                      stroke={CHART_COLORS[i % CHART_COLORS.length]}
                      strokeWidth={2}
                      dot={{ r: 3 }}
                      name={key}
                    />
                  ))}
                </LineChart>
              </ResponsiveContainer>
              <div className="mt-3 p-3 bg-emerald-50 rounded-lg text-sm text-emerald-800">
                <strong>Insight:</strong> Watch for diverging trends. If a top broker's volume is declining, engage immediately to understand the cause. Rising secondary brokers may be ready for expanded partnerships.
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-400 text-center py-12">No trend data available</p>
          )}
        </ChartCard>
      </div>
    </div>
  );
}
