import { createContext, useContext, useState, type ReactNode } from 'react';

interface Filters {
  dateRange: string;
  brokers: string[];
  product: string;
  state: string;
}

const DEFAULT_FILTERS: Filters = {
  dateRange: 'last_6_months',
  brokers: [],
  product: 'all',
  state: 'all',
};

interface FilterContextType {
  filters: Filters;
  setFilters: (f: Filters) => void;
  updateFilter: <K extends keyof Filters>(key: K, value: Filters[K]) => void;
  resetFilters: () => void;
  activeFilterCount: number;
}

const FilterContext = createContext<FilterContextType | null>(null);

export function FilterProvider({ children }: { children: ReactNode }) {
  const [filters, setFilters] = useState<Filters>(DEFAULT_FILTERS);

  const updateFilter = <K extends keyof Filters>(key: K, value: Filters[K]) => {
    setFilters(prev => ({ ...prev, [key]: value }));
  };

  const resetFilters = () => setFilters(DEFAULT_FILTERS);

  const activeFilterCount = [
    filters.dateRange !== DEFAULT_FILTERS.dateRange ? 1 : 0,
    filters.brokers.length > 0 ? 1 : 0,
    filters.product !== 'all' ? 1 : 0,
    filters.state !== 'all' ? 1 : 0,
  ].reduce((a, b) => a + b, 0);

  return (
    <FilterContext.Provider value={{ filters, setFilters, updateFilter, resetFilters, activeFilterCount }}>
      {children}
    </FilterContext.Provider>
  );
}

export function useFilters() {
  const ctx = useContext(FilterContext);
  if (!ctx) throw new Error('useFilters must be used within FilterProvider');
  return ctx;
}
