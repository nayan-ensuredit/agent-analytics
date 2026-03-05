import { inrTooltipFormatter } from "../utils";

export const CustomTooltip = ({ active, payload, label }: any) => {
  if (!active || !payload || payload.length === 0) return null;

  return (
    <div
      className="bg-white border border-slate-200 rounded-md shadow-md p-3 w-[260px] pointer-events-auto"
      style={{ maxHeight: 180 }}
    >
      <p className="font-semibold text-slate-800 mb-2">{label}</p>

      <div
        style={{
          maxHeight: 120,
          overflowY: "auto",
        }}
      >
        {payload.map((entry: any, index: number) => (
          <div key={index} className="text-sm flex justify-between mb-1">
            <span style={{ color: entry.color }}>{entry.name}</span>
            <span>{inrTooltipFormatter(entry.value)}</span>
          </div>
        ))}
      </div>
    </div>
  );
};