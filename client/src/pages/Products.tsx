import { useMemo } from 'react';
import { useFilteredApi } from '../api';
import ChartCard from '../components/ChartCard';
import DataTable from '../components/DataTable';
import type { Column } from '../components/DataTable';
import { formatINR, formatNumber, formatPercent, CHART_COLORS, inrTooltipFormatter } from '../utils';
import {
  PieChart, Pie, Cell,
  BarChart, Bar,
  XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer,
  AreaChart, Area,
} from 'recharts';

/* All API values come as strings from PostgreSQL */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type ProductMixRow = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type ProductTrendRow = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type BusinessTypeRow = Record<string, any>;

export default function Products() {
  const { data: mix, loading: mixLoading } = useFilteredApi<ProductMixRow[]>('/api/products/mix', 300000);
  const { data: trend, loading: trendLoading } = useFilteredApi<ProductTrendRow[]>('/api/products/trend', 300000);
  const { data: bizType, loading: bizLoading } = useFilteredApi<BusinessTypeRow[]>('/api/products/business-type', 300000);

  /* Convert mix data with correct field names */
  const mixChartData = (mix ?? []).map(d => ({
    product_type: d.product_type,
    policy_count: Number(d.policy_count),
    total_premium: Number(d.total_premium),
    avg_ticket: Number(d.avg_ticket),
    pct_of_total: Number(d.pct_of_total),
  }));

  const mixColumns: Column[] = [
    { key: 'product_type', label: 'Product' },
    { key: 'policy_count', label: 'Policies', align: 'right', format: (v) => formatNumber(v) },
    { key: 'total_premium', label: 'Premium', align: 'right', format: (v) => formatINR(v) },
    { key: 'avg_ticket', label: 'Avg Ticket', align: 'right', format: (v) => formatINR(v) },
    { key: 'pct_of_total', label: 'Share', align: 'right', format: (v) => formatPercent(v) },
  ];

  /* Pivot trend data: flat rows -> { sold_month, ProductA: premium, ProductB: premium, ... } */
  const { pivotedTrend, productKeys } = useMemo(() => {
    if (!trend || trend.length === 0) return { pivotedTrend: [], productKeys: [] };

    const monthMap = new Map<string, Record<string, number>>();
    const productSet = new Set<string>();

    for (const row of trend) {
      const month = row.sold_month as string;
      const product = row.product_type as string;
      const premium = Number(row.total_premium);
      productSet.add(product);
      if (!monthMap.has(month)) monthMap.set(month, {});
      const entry = monthMap.get(month)!;
      entry[product] = (entry[product] ?? 0) + premium;
    }

    const keys = Array.from(productSet);
    const pivoted = Array.from(monthMap.entries())
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([month, products]) => ({ month, ...products }));

    return { pivotedTrend: pivoted, productKeys: keys };
  }, [trend]);

  /* Pivot business type data: flat rows -> { month, "New Policy": count, "Renewal": count, ... } */
  const { pivotedBiz, bizKeys } = useMemo(() => {
    if (!bizType || bizType.length === 0) return { pivotedBiz: [], bizKeys: [] };

    const monthMap = new Map<string, Record<string, number>>();
    const typeSet = new Set<string>();

    for (const row of bizType) {
      const month = row.month as string;
      const bType = row.policy_business_type as string;
      const count = Number(row.policy_count);
      typeSet.add(bType);
      if (!monthMap.has(month)) monthMap.set(month, {});
      const entry = monthMap.get(month)!;
      entry[bType] = (entry[bType] ?? 0) + count;
    }

    const keys = Array.from(typeSet);
    const pivoted = Array.from(monthMap.entries())
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([month, types]) => ({ month, ...types }));

    return { pivotedBiz: pivoted, bizKeys: keys };
  }, [bizType]);

  return (
    <div className="space-y-6">
      {/* Insight Callout */}
      <div className="p-4 bg-amber-50 border border-amber-200 rounded-xl">
        <p className="text-sm text-amber-900">
          <strong>Key Finding:</strong> The product mix is heavily skewed towards motor insurance. Health insurance has significantly higher ticket sizes but minimal volume. Diversifying into health represents a major premium growth opportunity.
        </p>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Product Mix Donut + Table */}
        <ChartCard title="Product Mix by Premium" subtitle="Premium distribution across products" loading={mixLoading}>
          {mixChartData.length > 0 ? (
            <>
              <ResponsiveContainer width="100%" height={250}>
                <PieChart>
                  <Pie
                    data={mixChartData}
                    cx="50%"
                    cy="50%"
                    innerRadius={60}
                    outerRadius={95}
                    dataKey="total_premium"
                    nameKey="product_type"
                    label={((props: { product_type?: string; pct_of_total?: number }) => {
                      const pct = props.pct_of_total ?? 0;
                      if (pct < 3) return null; // Don't label tiny slices
                      return `${props.product_type ?? ''}: ${formatPercent(pct)}`;
                    }
                    // eslint-disable-next-line @typescript-eslint/no-explicit-any
                    ) as any}
                    labelLine={{ stroke: '#94a3b8' }}
                  >
                    {mixChartData.map((_entry, index) => (
                      <Cell key={index} fill={CHART_COLORS[index % CHART_COLORS.length]} />
                    ))}
                  </Pie>
                  <Tooltip formatter={(value: unknown) => [inrTooltipFormatter(value), 'Premium']} />
                </PieChart>
              </ResponsiveContainer>
              <div className="mt-4">
                <DataTable columns={mixColumns} data={mixChartData as unknown as Record<string, unknown>[]} pageSize={10} />
              </div>
              <div className="mt-3 p-3 bg-blue-50 rounded-lg text-sm text-blue-800">
                <strong>Insight:</strong> Diversification is critical. Over-reliance on a single product line creates vulnerability to regulatory or market changes. Target 20%+ share for the second product line.
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-400 text-center py-12">No product mix data available</p>
          )}
        </ChartCard>

        {/* Monthly Product Trend */}
        <ChartCard title="Monthly Product Trend" subtitle="Premium trend by product type" loading={trendLoading}>
          {pivotedTrend.length > 0 ? (
            <>
              <ResponsiveContainer width="100%" height={300}>
                <AreaChart data={pivotedTrend}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
                  <XAxis dataKey="month" tick={{ fontSize: 11 }} stroke="#94a3b8" />
                  <YAxis tick={{ fontSize: 12 }} stroke="#94a3b8" tickFormatter={(v: unknown) => formatINR(v)} />
                  <Tooltip formatter={(value: unknown) => [inrTooltipFormatter(value), 'Premium']} />
                  <Legend />
                  {productKeys.map((key, i) => (
                    <Area
                      key={key}
                      type="monotone"
                      dataKey={key}
                      stackId="1"
                      fill={CHART_COLORS[i % CHART_COLORS.length]}
                      stroke={CHART_COLORS[i % CHART_COLORS.length]}
                      fillOpacity={0.6}
                      name={key}
                    />
                  ))}
                </AreaChart>
              </ResponsiveContainer>
              <div className="mt-3 p-3 bg-emerald-50 rounded-lg text-sm text-emerald-800">
                <strong>Insight:</strong> Watch for declining product lines. If a product consistently shrinks while others grow, investigate competitive pricing or distribution channel issues.
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-400 text-center py-12">No trend data available</p>
          )}
        </ChartCard>
      </div>

      {/* Business Type Mix */}
      <ChartCard title="New vs Renewal vs Rollover" subtitle="Monthly business type breakdown" loading={bizLoading}>
        {pivotedBiz.length > 0 ? (
          <>
            <ResponsiveContainer width="100%" height={300}>
              <BarChart data={pivotedBiz}>
                <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
                <XAxis dataKey="month" tick={{ fontSize: 11 }} stroke="#94a3b8" />
                <YAxis tick={{ fontSize: 12 }} stroke="#94a3b8" />
                <Tooltip formatter={(value: unknown) => [formatNumber(value), 'Policies']} />
                <Legend />
                {bizKeys.map((key, i) => (
                  <Bar
                    key={key}
                    dataKey={key}
                    stackId="a"
                    fill={CHART_COLORS[i % CHART_COLORS.length]}
                    name={key}
                    radius={i === bizKeys.length - 1 ? [4, 4, 0, 0] : undefined}
                  />
                ))}
              </BarChart>
            </ResponsiveContainer>
            <div className="mt-3 p-3 bg-blue-50 rounded-lg text-sm text-blue-800">
              <strong>Insight:</strong> A healthy business should have growing new business AND stable renewals. If renewals are declining, retention issues need immediate attention. High rollover percentage may indicate limited net new customer acquisition.
            </div>
          </>
        ) : (
          <p className="text-sm text-slate-400 text-center py-12">No business type data available</p>
        )}
      </ChartCard>
    </div>
  );
}
