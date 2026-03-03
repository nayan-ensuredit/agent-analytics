import { getStatusColor } from '../utils';

interface StatusBadgeProps {
  status: 'green' | 'yellow' | 'red' | string;
  label: string;
}

export default function StatusBadge({ status, label }: StatusBadgeProps) {
  const colorClass = getStatusColor(status);
  return (
    <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${colorClass}`}>
      <span
        className={`w-1.5 h-1.5 rounded-full mr-1.5 ${
          status.toLowerCase() === 'green' || status.toLowerCase() === 'ok' || status.toLowerCase() === 'good'
            ? 'bg-emerald-500'
            : status.toLowerCase() === 'yellow' || status.toLowerCase() === 'warning' || status.toLowerCase() === 'warn'
              ? 'bg-amber-500'
              : status.toLowerCase() === 'red' || status.toLowerCase() === 'critical' || status.toLowerCase() === 'danger'
                ? 'bg-red-500'
                : 'bg-slate-500'
        }`}
      />
      {label}
    </span>
  );
}
