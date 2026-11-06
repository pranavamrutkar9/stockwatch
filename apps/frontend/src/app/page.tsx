'use client';

import { useState, useEffect } from 'react';
import Link from 'next/link';
import { Package, AlertTriangle, Play, RefreshCw, CheckCircle2, Clock } from 'lucide-react';

export default function DashboardPage() {
  const [healthStatus, setHealthStatus] = useState<string>('Checking...');
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    fetch('/api/health')
      .then((res) => res.json())
      .then((data) => {
        if (data.status === 'ok') {
          setHealthStatus('Backend Online');
        } else {
          setHealthStatus('Backend Unhealthy');
        }
      })
      .catch(() => {
        setHealthStatus('Backend Offline');
      });
  }, []);

  return (
    <div className="space-y-8">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4 border-b border-slate-200 pb-5">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-slate-900">Inventory Dashboard</h1>
          <p className="text-sm text-slate-500 mt-1">
            Real-time overview of inventory levels and low-stock alerts
          </p>
        </div>
        <div className="flex items-center space-x-3">
          <span
            className={`inline-flex items-center px-2.5 py-1 rounded-full text-xs font-medium ${
              healthStatus === 'Backend Online'
                ? 'bg-emerald-100 text-emerald-800'
                : 'bg-amber-100 text-amber-800'
            }`}
          >
            <span
              className={`w-2 h-2 mr-1.5 rounded-full ${
                healthStatus === 'Backend Online' ? 'bg-emerald-500' : 'bg-amber-500'
              }`}
            />
            {healthStatus}
          </span>
          <button
            disabled={loading}
            className="inline-flex items-center space-x-2 bg-emerald-600 hover:bg-emerald-700 text-white font-medium px-4 py-2 rounded-lg text-sm shadow-sm transition-colors disabled:opacity-50"
          >
            <Play className="h-4 w-4" />
            <span>Run Stock Check</span>
          </button>
        </div>
      </div>

      {/* Summary Cards */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        <div className="bg-white p-6 rounded-xl border border-slate-200 shadow-sm">
          <div className="flex items-center justify-between">
            <span className="text-sm font-medium text-slate-500">Total Items</span>
            <Package className="h-5 w-5 text-slate-400" />
          </div>
          <p className="text-3xl font-bold text-slate-900 mt-2">--</p>
          <span className="text-xs text-slate-400 mt-1 block">Configured inventory items</span>
        </div>

        <div className="bg-white p-6 rounded-xl border border-slate-200 shadow-sm">
          <div className="flex items-center justify-between">
            <span className="text-sm font-medium text-amber-600">Low Stock Alerts</span>
            <AlertTriangle className="h-5 w-5 text-amber-500" />
          </div>
          <p className="text-3xl font-bold text-amber-600 mt-2">--</p>
          <span className="text-xs text-slate-400 mt-1 block">Items at or below min quantity</span>
        </div>

        <div className="bg-white p-6 rounded-xl border border-slate-200 shadow-sm">
          <div className="flex items-center justify-between">
            <span className="text-sm font-medium text-slate-500">Latest Stock Check</span>
            <Clock className="h-5 w-5 text-slate-400" />
          </div>
          <p className="text-xl font-bold text-slate-900 mt-2">No runs yet</p>
          <span className="text-xs text-slate-400 mt-1 block">Queue processor status</span>
        </div>
      </div>

      {/* Quick Links / Empty state prompt */}
      <div className="bg-white rounded-xl border border-slate-200 p-8 text-center space-y-4">
        <div className="max-w-md mx-auto">
          <h3 className="text-base font-semibold text-slate-900">Application Foundation Ready</h3>
          <p className="text-sm text-slate-500 mt-1">
            Frontend shell initialized. Next phases will connect PostgreSQL persistence and Redis queue worker.
          </p>
          <div className="flex justify-center gap-3 mt-4">
            <Link
              href="/inventory"
              className="inline-flex items-center text-sm font-medium text-emerald-600 hover:text-emerald-700 bg-emerald-50 px-3 py-1.5 rounded-md"
            >
              View Inventory &rarr;
            </Link>
            <Link
              href="/stock-checks"
              className="inline-flex items-center text-sm font-medium text-slate-600 hover:text-slate-700 bg-slate-100 px-3 py-1.5 rounded-md"
            >
              View Stock Checks &rarr;
            </Link>
          </div>
        </div>
      </div>
    </div>
  );
}

