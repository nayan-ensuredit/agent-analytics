import { useFilteredApi } from '../api';
import ChartCard from '../components/ChartCard';
import DataTable from '../components/DataTable';
import type { Column } from '../components/DataTable';
import { formatINR, formatNumber, CHART_COLORS, inrTooltipFormatter } from '../utils';
import {
  BarChart, Bar,
  XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer,
} from 'recharts';

/* All API values come as strings from PostgreSQL */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type StateRow = Record<string, any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type StateProductRow = Record<string, any>;

export default function Geographic() {
  const { data: states, loading: statesLoading } = useFilteredApi<StateRow[]>('/api/geographic/states', 300000);
  const { data: stateProduct, loading: spLoading } = useFilteredApi<StateProductRow[]>('/api/geographic/state-product', 300000);

  const spColumns: Column[] = [
    { key: 'state', label: 'State' },
    { key: 'product_type', label: 'Product' },
    { key: 'policies', label: 'Policies', align: 'right', format: (v) => formatNumber(v) },
    { key: 'total_premium', label: 'Premium', align: 'right', format: (v) => formatINR(v) },
  ];

  /* Convert string values to numbers for Recharts, take top 15 */
  const topStates = (states ?? []).slice(0, 15).map(d => ({
    state: d.state,
    policies: Number(d.policies),
    total_premium: Number(d.total_premium),
    agents: Number(d.agents),
    avg_ticket: Number(d.avg_ticket),
  }));

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Top 15 States */}
        <ChartCard title="Top 15 States by Premium" subtitle="Geographic distribution of premium" loading={statesLoading}>
          {topStates.length > 0 ? (
            <>
              <ResponsiveContainer width="100%" height={400}>
                <BarChart data={topStates} layout="vertical" margin={{ left: 10 }}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
                  <XAxis type="number" tick={{ fontSize: 11 }} stroke="#94a3b8" tickFormatter={(v: unknown) => formatINR(v)} />
                  <YAxis type="category" dataKey="state" tick={{ fontSize: 11 }} stroke="#94a3b8" width={100} />
                  <Tooltip
                    formatter={(value: unknown) => [inrTooltipFormatter(value), 'Premium']}
                  />
                  <Bar dataKey="total_premium" fill={CHART_COLORS[0]} radius={[0, 4, 4, 0]} name="Premium" />
                </BarChart>
              </ResponsiveContainer>
              <div className="mt-3 p-3 bg-blue-50 rounded-lg text-sm text-blue-800">
                <strong>Insight:</strong> Geographic concentration reveals market penetration opportunities. States with low premium but high vehicle/population density are underpenetrated markets worth targeting.
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-400 text-center py-12">No state data available</p>
          )}
        </ChartCard>

        {/* State x Product Breakdown */}
        <ChartCard title="State x Product Breakdown" subtitle="Product performance by state" loading={spLoading}>
          {stateProduct && stateProduct.length > 0 ? (
            <>
              <DataTable
                columns={spColumns}
                data={stateProduct as unknown as Record<string, unknown>[]}
                pageSize={12}
              />
              <div className="mt-3 p-3 bg-emerald-50 rounded-lg text-sm text-emerald-800">
                <strong>Insight:</strong> Identify states where specific products outperform national averages. These are ideal for targeted campaigns and agent recruitment.
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-400 text-center py-12">No state-product data available</p>
          )}
        </ChartCard>
      </div>
    </div>
  );
}
