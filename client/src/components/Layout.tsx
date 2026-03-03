import { useState } from "react";
import type { ReactNode } from "react";
import { NavLink, useLocation } from "react-router-dom";
import {
  LayoutDashboard,
  Users,
  Filter,
  Package,
  Building2,
  MapPin,
  Shield,
  RotateCcw,
  Bell,
  Activity,
  Brain,
  Menu,
  X,
  RefreshCw,
  LogOut,
} from "lucide-react";
import { useFilteredApi } from "../api";
import { useAuth } from "../contexts/AuthContext";
import FilterBar from "./FilterBar";

interface AlertSummary {
  declining_agents_count?: number;
  stuck_quoters_count?: number;
  inactive_agents_count?: number;
  expiring_renewals_count?: number;
}

const NAV_ITEMS = [
  { to: "/", label: "Executive Summary", icon: LayoutDashboard },
  { to: "/agents", label: "Agent Analytics", icon: Users },
  { to: "/funnel", label: "Sales Funnel", icon: Filter },
  { to: "/products", label: "Products", icon: Package },
  { to: "/brokers", label: "Brokers", icon: Building2 },
  { to: "/geographic", label: "Geographic", icon: MapPin },
  { to: "/insurers", label: "Insurers", icon: Shield },
  { to: "/renewals", label: "Renewals", icon: RotateCcw },
  { to: "/alerts", label: "Alerts", icon: Bell },
  { to: "/operations", label: "Operations", icon: Activity },
  { to: "/advanced", label: "Advanced", icon: Brain },
];

const SECTION_NAMES: Record<string, string> = {
  "/": "Executive Summary",
  "/agents": "Agent Analytics",
  "/funnel": "Sales Funnel",
  "/products": "Product Intelligence",
  "/brokers": "Broker Deep Dive",
  "/geographic": "Geographic Intelligence",
  "/insurers": "Insurer Analytics",
  "/renewals": "Renewals & Retention",
  "/alerts": "Actionable Alerts",
  "/operations": "Daily Operations",
  "/advanced": "Advanced Analytics",
};

interface LayoutProps {
  children: ReactNode;
}

export default function Layout({ children }: LayoutProps) {
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const location = useLocation();
  const { user, logout } = useAuth();
  const { data: alertData } = useFilteredApi<AlertSummary>(
    "/api/alerts/summary",
    60000,
  );

  const alertCount = alertData
    ? (alertData.declining_agents_count ?? 0) +
      (alertData.stuck_quoters_count ?? 0) +
      (alertData.inactive_agents_count ?? 0) +
      (alertData.expiring_renewals_count ?? 0)
    : 0;
  const sectionName = SECTION_NAMES[location.pathname] || "Dashboard";

  return (
    <div className="flex h-screen overflow-hidden">
      {/* Mobile overlay */}
      {sidebarOpen && (
        <div
          className="fixed inset-0 bg-black/50 z-40 lg:hidden"
          onClick={() => setSidebarOpen(false)}
        />
      )}

      {/* Sidebar */}
      <aside
        className={`fixed lg:static inset-y-0 left-0 z-50 w-64 transform transition-transform duration-200 ease-in-out lg:translate-x-0 ${
          sidebarOpen ? "translate-x-0" : "-translate-x-full"
        }`}
        style={{ backgroundColor: "#0F172A" }}
      >
        <div className="flex flex-col h-full">
          {/* Brand */}
          <div className="flex items-center justify-between px-5 py-5 border-b border-slate-700">
            <div className="flex items-center gap-3">
              <div className="w-8 h-8 rounded-lg bg-blue-600 flex items-center justify-center">
                <Shield className="w-5 h-5 text-white" />
              </div>
              <div>
                <h1 className="text-white font-bold text-sm">InsurTech</h1>
                <p className="text-slate-400 text-xs">Analytics</p>
              </div>
            </div>
            <button
              onClick={() => setSidebarOpen(false)}
              className="lg:hidden text-slate-400 hover:text-white"
            >
              <X className="w-5 h-5" />
            </button>
          </div>

          {/* Nav Items */}
          <nav className="flex-1 overflow-y-auto py-4 px-3 space-y-1">
            {NAV_ITEMS.map((item) => (
              <NavLink
                key={item.to}
                to={item.to}
                end={item.to === "/"}
                onClick={() => setSidebarOpen(false)}
                className={({ isActive }) =>
                  `flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-colors ${
                    isActive
                      ? "bg-blue-600/20 text-blue-400"
                      : "text-slate-400 hover:text-white hover:bg-slate-800"
                  }`
                }
              >
                <item.icon className="w-4.5 h-4.5 shrink-0" />
                <span className="truncate">{item.label}</span>
                {item.to === "/alerts" && alertCount > 0 && (
                  <span className="ml-auto bg-red-500 text-white text-xs font-bold rounded-full px-2 py-0.5 min-w-[20px] text-center">
                    {alertCount > 99 ? "99+" : alertCount}
                  </span>
                )}
              </NavLink>
            ))}
          </nav>

          {/* Footer */}
          <div className="px-5 py-4 border-t border-slate-700">
            <p className="text-xs text-slate-500">
              v1.0.0 | Data refreshes every 5m
            </p>
          </div>
        </div>
      </aside>

      {/* Main content */}
      <div className="flex-1 flex flex-col overflow-hidden">
        {/* Top bar */}
        <header className="bg-white border-b border-slate-200 px-4 lg:px-6 py-3 flex items-center justify-between shrink-0">
          <div className="flex items-center gap-3">
            <button
              onClick={() => setSidebarOpen(true)}
              className="lg:hidden p-1 rounded-lg hover:bg-slate-100"
            >
              <Menu className="w-5 h-5 text-slate-600" />
            </button>
            <div>
              <h2 className="text-lg font-semibold text-slate-800">
                {sectionName}
              </h2>
            </div>
          </div>
          <div className="flex items-center gap-4">
            <div className="flex items-center gap-2 text-xs text-slate-400">
              <RefreshCw className="w-3.5 h-3.5" />
              <span>Auto-refresh active</span>
            </div>
            <div className="flex items-center gap-2">
              <span className="text-xs text-slate-500">{user?.username}</span>
              <button
                onClick={logout}
                className="flex items-center gap-1.5 px-2.5 py-1.5 text-xs font-medium text-slate-600 hover:text-slate-800 hover:bg-slate-100 rounded-lg transition-colors"
                title="Sign out"
              >
                <LogOut className="w-3.5 h-3.5" />
                Sign out
              </button>
            </div>
          </div>
        </header>

        {/* Global Filters */}
        <FilterBar />

        {/* Page content */}
        <main className="flex-1 overflow-y-auto p-4 lg:p-6">{children}</main>
      </div>
    </div>
  );
}
