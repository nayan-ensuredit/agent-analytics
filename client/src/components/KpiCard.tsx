import type { ReactNode } from 'react';
import { TrendingUp, TrendingDown } from 'lucide-react';
import { toNum } from '../utils';

interface KpiCardProps {
  title: string;
  value: string | number;
  subtitle?: string;
  delta?: unknown;
  deltaLabel?: string;
  icon?: ReactNode;
  color?: string;
}

export default function KpiCard({ title, value, subtitle, delta, deltaLabel, icon, color }: KpiCardProps) {
  const deltaNum = delta != null ? toNum(delta) : undefined;
  const isPositive = deltaNum !== undefined && deltaNum >= 0;
  const colorBar = color || '#3B82F6';

  return (
    <div className="bg-white rounded-xl shadow-sm border border-slate-200 p-6 relative overflow-hidden">
      <div
        className="absolute top-0 left-0 w-full h-1"
        style={{ backgroundColor: colorBar }}
      />
      <div className="flex items-start justify-between">
        <div className="flex-1 min-w-0">
          <p className="text-xs uppercase tracking-wider text-slate-500 font-medium mb-1">
            {title}
          </p>
          <p className="text-2xl font-bold text-slate-900 truncate" title={String(value)}>{value}</p>
          {subtitle && (
            <p className="text-sm text-slate-500 mt-1">{subtitle}</p>
          )}
          {deltaNum !== undefined && (
            <div className="flex items-center gap-1 mt-2">
              {isPositive ? (
                <TrendingUp className="w-4 h-4 text-emerald-600" />
              ) : (
                <TrendingDown className="w-4 h-4 text-red-600" />
              )}
              <span
                className={`text-sm font-semibold ${
                  isPositive ? 'text-emerald-600' : 'text-red-600'
                }`}
              >
                {isPositive ? '+' : ''}{deltaNum.toFixed(1)}%
              </span>
              {deltaLabel && (
                <span className="text-xs text-slate-400 ml-1">{deltaLabel}</span>
              )}
            </div>
          )}
        </div>
        {icon && (
          <div className="ml-3 p-2 rounded-lg bg-slate-50 text-slate-600 shrink-0">
            {icon}
          </div>
        )}
      </div>
    </div>
  );
}
