import { useMemo } from 'react';
import { useFilteredApi } from '../api';
import ChartCard from '../components/ChartCard';
import { formatPercent, CHART_COLORS, inrTooltipFormatter, formatINR } from '../utils';
import {
  PieChart, Pie, Cell,
  LineChart, Line,
  XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer,
} from 'recharts';

/* All API values come as strings from PostgreSQL */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type InsurerShareRow = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type InsurerTrendRow = Record<string, any>;

export default function Insurers() {
  const { data: share, loading: shareLoading } = useFilteredApi<InsurerShareRow[]>('/api/insurers/share', 300000);
  const { data: trend, loading: trendLoading } = useFilteredApi<InsurerTrendRow[]>('/api/insurers/trend', 300000);

  /* Group into top 5 + Others for cleaner donut chart */
  const sortedShare = [...(share ?? [])].sort((a, b) => Number(b.total_premium) - Number(a.total_premium));
  const top5 = sortedShare.slice(0, 5).map(d => ({
    insurer: d.insurer,
    total_premium: Number(d.total_premium),
    pct_share: Number(d.pct_share),
  }));
  const othersTotal = sortedShare.slice(5).reduce((sum, d) => sum + Number(d.total_premium), 0);
  const othersPct = sortedShare.slice(5).reduce((sum, d) => sum + Number(d.pct_share), 0);
  const shareChartData = [
    ...top5,
    ...(othersTotal > 0 ? [{ insurer: 'Others', total_premium: othersTotal, pct_share: othersPct }] : []),
  ];

  /* Pivot trend data: flat rows -> { month, InsurerA: premium, InsurerB: premium, ... } */
  /* Limit to top 8 insurers by total premium to keep chart readable */
  const { pivotedTrend, insurerKeys } = useMemo(() => {
    if (!trend || trend.length === 0) return { pivotedTrend: [], insurerKeys: [] };

    const monthMap = new Map<string, Record<string, number>>();
    const insurerTotals = new Map<string, number>();

    for (const row of trend) {
      const month = row.month as string;
      const insurer = row.insurer as string;
      const premium = Number(row.total_premium);
      insurerTotals.set(insurer, (insurerTotals.get(insurer) ?? 0) + premium);
      if (!monthMap.has(month)) monthMap.set(month, {});
      const entry = monthMap.get(month)!;
      entry[insurer] = (entry[insurer] ?? 0) + premium;
    }

    /* Only show top 8 insurers by total premium */
    const keys = Array.from(insurerTotals.entries())
      .sort(([, a], [, b]) => b - a)
      .slice(0, 8)
      .map(([key]) => key);

    const pivoted = Array.from(monthMap.entries())
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([month, insurers]) => ({ month, ...insurers }));

    return { pivotedTrend: pivoted, insurerKeys: keys };
  }, [trend]);

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Insurer Market Share */}
        <ChartCard title="Insurer Market Share" subtitle="Premium distribution by insurer" loading={shareLoading}>
          {shareChartData.length > 0 ? (
            <>
              <ResponsiveContainer width="100%" height={300}>
                <PieChart>
                  <Pie
                    data={shareChartData}
                    cx="50%"
                    cy="50%"
                    innerRadius={65}
                    outerRadius={105}
                    dataKey="total_premium"
                    nameKey="insurer"
                    labelLine={false}
                  >
                    {shareChartData.map((_entry, index) => (
                      <Cell key={index} fill={CHART_COLORS[index % CHART_COLORS.length]} />
                    ))}
                  </Pie>
                  <Tooltip formatter={(value: unknown) => [inrTooltipFormatter(value), 'Premium']} />
                  <Legend />
                </PieChart>
              </ResponsiveContainer>
              {/* Summary table */}
              <div className="mt-4 space-y-1">
                {shareChartData.slice(0, 5).map((item, i) => (
                  <div key={item.insurer} className="flex items-center justify-between text-sm py-1.5 px-2 rounded hover:bg-slate-50">
                    <div className="flex items-center gap-2">
                      <div className="w-3 h-3 rounded" style={{ backgroundColor: CHART_COLORS[i % CHART_COLORS.length] }} />
                      <span className="text-slate-700">{item.insurer}</span>
                    </div>
                    <span className="font-medium text-slate-900">{formatPercent(item.pct_share)}</span>
                  </div>
                ))}
              </div>
              <div className="mt-3 p-3 bg-blue-50 rounded-lg text-sm text-blue-800">
                <strong>Insight:</strong> Monitor insurer concentration. Over-reliance on a single insurer creates negotiation risk. Diversify placements to maintain competitive terms and ensure business continuity.
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-400 text-center py-12">No insurer share data available</p>
          )}
        </ChartCard>

        {/* Monthly Insurer Trend */}
        <ChartCard title="Monthly Insurer Trend" subtitle="Premium trend by insurer partner" loading={trendLoading}>
          {pivotedTrend.length > 0 ? (
            <>
              <ResponsiveContainer width="100%" height={300}>
                <LineChart data={pivotedTrend}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
                  <XAxis dataKey="month" tick={{ fontSize: 11 }} stroke="#94a3b8" />
                  <YAxis tick={{ fontSize: 12 }} stroke="#94a3b8" tickFormatter={(v: unknown) => formatINR(v)} />
                  <Tooltip formatter={(value: unknown) => [inrTooltipFormatter(value), 'Premium']} />
                  <Legend />
                  {insurerKeys.map((key, i) => (
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
              <div className="mt-3 p-3 bg-amber-50 rounded-lg text-sm text-amber-800">
                <strong>Insight:</strong> Look for insurer trend divergence. Declining insurer volumes may indicate pricing issues, claim settlement problems, or shifting agent preferences. Engage insurer partners proactively.
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-400 text-center py-12">No insurer trend data available</p>
          )}
        </ChartCard>
      </div>
    </div>
  );
}
