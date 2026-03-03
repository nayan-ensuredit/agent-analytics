import { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import { useFilters } from './contexts/FilterContext';

interface ApiResponse<T> {
  success: boolean;
  data: T;
  meta?: Record<string, unknown>;
}

interface UseApiResult<T> {
  data: T | null;
  loading: boolean;
  error: string | null;
  refetch: () => void;
  lastUpdated: Date | null;
}

export function useApi<T = unknown>(url: string, refreshInterval?: number): UseApiResult<T> {
  const [data, setData] = useState<T | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const fetchData = useCallback(async () => {
    if (abortRef.current) {
      abortRef.current.abort();
    }
    const controller = new AbortController();
    abortRef.current = controller;

    try {
      setLoading(true);
      setError(null);
      const response = await fetch(url, { signal: controller.signal });
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }
      const json: ApiResponse<T> = await response.json();
      if (json.success && json.data !== undefined) {
        setData(json.data);
      } else {
        setData(json as unknown as T);
      }
      setLastUpdated(new Date());
    } catch (err: unknown) {
      if (err instanceof Error && err.name === 'AbortError') return;
      setError(err instanceof Error ? err.message : 'Unknown error');
    } finally {
      setLoading(false);
    }
  }, [url]);

  useEffect(() => {
    fetchData();

    let interval: ReturnType<typeof setInterval> | undefined;
    if (refreshInterval && refreshInterval > 0) {
      interval = setInterval(fetchData, refreshInterval);
    }

    return () => {
      if (abortRef.current) {
        abortRef.current.abort();
      }
      if (interval) {
        clearInterval(interval);
      }
    };
  }, [fetchData, refreshInterval]);

  return { data, loading, error, refetch: fetchData, lastUpdated };
}

/**
 * Filter-aware API hook. Reads current filters from FilterContext and appends
 * them as query params so the backend can apply SQL WHERE clauses.
 *
 * Re-fetches automatically whenever filters change.
 */
export function useFilteredApi<T = unknown>(baseUrl: string, refreshInterval?: number): UseApiResult<T> {
  const { filters } = useFilters();

  const url = useMemo(() => {
    const params = new URLSearchParams();

    // date_range — always send it so backend applies the correct time window
    if (filters.dateRange) {
      params.set('date_range', filters.dateRange);
    }

    // broker (first selected broker — backend accepts single broker for now)
    if (filters.brokers.length > 0) {
      params.set('broker', filters.brokers[0]);
    }

    // product
    if (filters.product && filters.product !== 'all') {
      params.set('product', filters.product);
    }

    // state
    if (filters.state && filters.state !== 'all') {
      params.set('state', filters.state);
    }

    const qs = params.toString();
    return qs ? `${baseUrl}?${qs}` : baseUrl;
  }, [baseUrl, filters.dateRange, filters.brokers, filters.product, filters.state]);

  return useApi<T>(url, refreshInterval);
}
