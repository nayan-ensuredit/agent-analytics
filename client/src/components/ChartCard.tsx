import type { ReactNode } from 'react';

interface ChartCardProps {
  title: string;
  subtitle?: string;
  children: ReactNode;
  className?: string;
  loading?: boolean;
}

function LoadingSkeleton() {
  return (
    <div className="space-y-3 p-4">
      <div className="h-4 w-1/3 bg-slate-200 rounded animate-pulse" />
      <div className="h-3 w-1/4 bg-slate-100 rounded animate-pulse" />
      <div className="flex items-end gap-2 mt-6" style={{ height: 200 }}>
        {[40, 65, 50, 80, 70, 55, 90, 60, 75, 45, 85, 70].map((h, i) => (
          <div
            key={i}
            className="flex-1 bg-slate-200 rounded-t animate-pulse"
            style={{ height: `${h}%` }}
          />
        ))}
      </div>
    </div>
  );
}

export default function ChartCard({ title, subtitle, children, className = '', loading }: ChartCardProps) {
  return (
    <div className={`bg-white rounded-xl shadow-sm border border-slate-200 p-6 ${className}`} style={{ minHeight: 320 }}>
      <div className="mb-4">
        <h3 className="text-base font-semibold text-slate-800">{title}</h3>
        {subtitle && (
          <p className="text-sm text-slate-500 mt-0.5">{subtitle}</p>
        )}
      </div>
      {loading ? <LoadingSkeleton /> : children}
    </div>
  );
}
