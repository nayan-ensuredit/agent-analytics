export const CHART_COLORS = [
  '#3B82F6', '#10B981', '#F59E0B', '#EF4444',
  '#8B5CF6', '#EC4899', '#06B6D4', '#84CC16',
];

/** Coerce any value (string, number, null, undefined) to a number */
export function toNum(v: unknown): number {
  if (v == null) return 0;
  const n = Number(v);
  return isNaN(n) ? 0 : n;
}

export function formatINR(amount: unknown): string {
  const a = toNum(amount);
  if (a === 0) return '\u20B90';
  const abs = Math.abs(a);
  const sign = a < 0 ? '-' : '';
  if (abs >= 1_00_00_000) {
    const cr = abs / 1_00_00_000;
    return `${sign}\u20B9${cr.toFixed(cr < 10 ? 2 : 1)}Cr`;
  }
  if (abs >= 1_00_000) {
    const lakh = abs / 1_00_000;
    return `${sign}\u20B9${lakh.toFixed(lakh < 10 ? 2 : 1)}L`;
  }
  if (abs >= 1_000) {
    const k = abs / 1_000;
    return `${sign}\u20B9${k.toFixed(k < 10 ? 1 : 0)}K`;
  }
  return `${sign}\u20B9${abs.toFixed(0)}`;
}

export function formatNumber(n: unknown): string {
  return toNum(n).toLocaleString('en-IN');
}

export function formatPercent(n: unknown): string {
  return `${toNum(n).toFixed(1)}%`;
}

export function getStatusColor(status: string): string {
  const s = status.toLowerCase();
  if (s === 'green' || s === 'ok' || s === 'good') {
    return 'bg-emerald-100 text-emerald-800';
  }
  if (s === 'yellow' || s === 'warning' || s === 'warn') {
    return 'bg-amber-100 text-amber-800';
  }
  if (s === 'red' || s === 'critical' || s === 'danger') {
    return 'bg-red-100 text-red-800';
  }
  return 'bg-slate-100 text-slate-800';
}

export function abbreviateNumber(n: unknown): string {
  const v = toNum(n);
  if (v === 0) return '0';
  const abs = Math.abs(v);
  const sign = v < 0 ? '-' : '';
  if (abs >= 1_00_00_000) {
    return `${sign}${(abs / 1_00_00_000).toFixed(1)}Cr`;
  }
  if (abs >= 1_00_000) {
    return `${sign}${(abs / 1_00_000).toFixed(1)}L`;
  }
  if (abs >= 1_000) {
    return `${sign}${(abs / 1_000).toFixed(1)}K`;
  }
  return `${sign}${abs}`;
}

export function inrTooltipFormatter(value: unknown): string {
  return formatINR(value);
}
