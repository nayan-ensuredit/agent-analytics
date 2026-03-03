import { useEffect, useState } from 'react';
import { SlidersHorizontal, X } from 'lucide-react';
import { useFilters } from '../contexts/FilterContext';

const DATE_RANGE_OPTIONS = [
  { value: 'last_30_days', label: 'Last 30 Days' },
  { value: 'last_3_months', label: 'Last 3 Months' },
  { value: 'last_6_months', label: 'Last 6 Months' },
  { value: 'last_12_months', label: 'Last 12 Months' },
  { value: 'all_time', label: 'All Time' },
];

const PRODUCT_OPTIONS = [
  { value: 'all', label: 'All Products' },
  { value: 'Private Car', label: 'Private Car' },
  { value: 'Two Wheeler', label: 'Two Wheeler' },
  { value: 'Health', label: 'Health' },
];

interface OptionItem {
  value: string;
  label: string;
}

const selectClasses =
  'h-8 px-2 pr-7 rounded-md border border-slate-200 bg-white text-xs text-slate-700 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500 truncate appearance-none cursor-pointer';

export default function FilterBar() {
  const { filters, updateFilter, resetFilters, activeFilterCount } = useFilters();
  const [stateOptions, setStateOptions] = useState<OptionItem[]>([{ value: 'all', label: 'All States' }]);
  const [brokerOptions, setBrokerOptions] = useState<OptionItem[]>([{ value: 'all', label: 'All Brokers' }]);

  /* Fetch states & brokers from DB on mount */
  useEffect(() => {
    fetch('/api/geographic/states?date_range=all_time')
      .then((r) => r.json())
      .then((json) => {
        const data = json.success ? json.data : json;
        if (Array.isArray(data)) {
          const opts: OptionItem[] = [{ value: 'all', label: 'All States' }];
          data.forEach((row: Record<string, unknown>) => {
            const s = String(row.state ?? '').trim();
            if (s) {
              // Title case for display, original value for filter
              const label = s.split(' ').map(w => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()).join(' ');
              opts.push({ value: s, label });
            }
          });
          setStateOptions(opts);
        }
      })
      .catch(() => { /* keep defaults */ });

    fetch('/api/brokers/performance?date_range=all_time')
      .then((r) => r.json())
      .then((json) => {
        const data = json.success ? json.data : json;
        if (Array.isArray(data)) {
          const opts: OptionItem[] = [{ value: 'all', label: 'All Brokers' }];
          data.forEach((row: Record<string, unknown>) => {
            const b = String(row.broker_name ?? '').trim();
            if (b) {
              opts.push({ value: b, label: b });
            }
          });
          setBrokerOptions(opts);
        }
      })
      .catch(() => { /* keep defaults */ });
  }, []);

  return (
    <div className="bg-white border-b border-slate-200 px-4 lg:px-6 py-2 flex items-center gap-3 flex-wrap">
      <div className="flex items-center gap-1.5 text-slate-500 shrink-0">
        <SlidersHorizontal className="w-3.5 h-3.5" />
        <span className="text-xs font-medium">Filters</span>
        {activeFilterCount > 0 && (
          <span className="bg-blue-100 text-blue-700 text-[10px] font-bold rounded-full px-1.5 py-0.5 min-w-[18px] text-center">
            {activeFilterCount}
          </span>
        )}
      </div>

      {/* Date Range */}
      <select
        value={filters.dateRange}
        onChange={(e) => updateFilter('dateRange', e.target.value)}
        className={selectClasses}
        title="Date Range"
      >
        {DATE_RANGE_OPTIONS.map((opt) => (
          <option key={opt.value} value={opt.value}>{opt.label}</option>
        ))}
      </select>

      {/* Broker */}
      <select
        value={filters.brokers.length > 0 ? filters.brokers[0] : 'all'}
        onChange={(e) => {
          const val = e.target.value;
          updateFilter('brokers', val === 'all' ? [] : [val]);
        }}
        className={selectClasses}
        title="Broker"
      >
        {brokerOptions.map((opt) => (
          <option key={opt.value} value={opt.value}>{opt.label}</option>
        ))}
      </select>

      {/* Product */}
      <select
        value={filters.product}
        onChange={(e) => updateFilter('product', e.target.value)}
        className={selectClasses}
        title="Product"
      >
        {PRODUCT_OPTIONS.map((opt) => (
          <option key={opt.value} value={opt.value}>{opt.label}</option>
        ))}
      </select>

      {/* State */}
      <select
        value={filters.state}
        onChange={(e) => updateFilter('state', e.target.value)}
        className={selectClasses}
        title="State"
      >
        {stateOptions.map((opt) => (
          <option key={opt.value} value={opt.value}>{opt.label}</option>
        ))}
      </select>

      {/* Clear All */}
      {activeFilterCount > 0 && (
        <button
          onClick={resetFilters}
          className="flex items-center gap-1 text-xs text-slate-500 hover:text-red-600 transition-colors ml-1 shrink-0"
        >
          <X className="w-3 h-3" />
          Clear
        </button>
      )}
    </div>
  );
}
