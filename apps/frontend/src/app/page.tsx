'use client';

import { useState, useEffect, useCallback } from 'react';
import Link from 'next/link';
import {
  Package,
  AlertTriangle,
  Play,
  RefreshCw,
  CheckCircle2,
  XCircle,
  Clock,
  ArrowRight,
} from 'lucide-react';

interface InventoryItem {
  id: string;
  name: string;
  sku: string;
  category: string;
  quantity: number;
  minQuantity: number;
  status: 'LOW_STOCK' | 'HEALTHY';
}

interface StockAlert {
  id: string;
  inventoryItemId: string;
  stockCheckId: string;
  quantity: number;
  minQuantity: number;
  message: string;
  createdAt: string;
  inventoryItem?: InventoryItem;
}

interface StockCheck {
  id: string;
  jobId: string;
  status: 'PENDING' | 'PROCESSING' | 'COMPLETED' | 'FAILED';
  totalChecked: number;
  lowStockCount: number;
  error?: string | null;
  startedAt?: string | null;
  completedAt?: string | null;
  createdAt: string;
}

export default function DashboardPage() {
  const [healthStatus, setHealthStatus] = useState<string>('Checking...');
  const [items, setItems] = useState<InventoryItem[]>([]);
  const [alerts, setAlerts] = useState<StockAlert[]>([]);
  const [latestCheck, setLatestCheck] = useState<StockCheck | null>(null);
  const [activeCheck, setActiveCheck] = useState<StockCheck | null>(null);
  const [isRunningCheck, setIsRunningCheck] = useState(false);
  const [isLoading, setIsLoading] = useState(true);

  const loadData = useCallback(async () => {
    try {
      const [healthRes, invRes, alertsRes, checksRes] = await Promise.allSettled([
        fetch('/api/health'),
        fetch('/api/inventory'),
        fetch('/api/alerts'),
        fetch('/api/stock-checks'),
      ]);

      if (healthRes.status === 'fulfilled' && healthRes.value.ok) {
        setHealthStatus('Backend Online');
      } else {
        setHealthStatus('Backend Offline');
      }

      if (invRes.status === 'fulfilled' && invRes.value.ok) {
        const invData = await invRes.value.json();
        setItems(invData);
      }

      if (alertsRes.status === 'fulfilled' && alertsRes.value.ok) {
        const alertsData = await alertsRes.value.json();
        setAlerts(alertsData);
      }

      if (checksRes.status === 'fulfilled' && checksRes.value.ok) {
        const checksData = await checksRes.value.json();
        if (checksData.length > 0) {
          setLatestCheck(checksData[0]);
        }
      }
    } catch {
      setHealthStatus('Backend Offline');
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    loadData();
  }, [loadData]);

  // Poll for active check if pending or processing
  useEffect(() => {
    if (!activeCheck || activeCheck.status === 'COMPLETED' || activeCheck.status === 'FAILED') {
      setIsRunningCheck(false);
      return;
    }

    const interval = setInterval(async () => {
      try {
        const res = await fetch(`/api/stock-checks/${activeCheck.id}`);
        if (res.ok) {
          const updated: StockCheck = await res.json();
          setActiveCheck(updated);
          if (updated.status === 'COMPLETED' || updated.status === 'FAILED') {
            setLatestCheck(updated);
            setIsRunningCheck(false);
            loadData(); // Refresh summary and alerts
          }
        }
      } catch (err) {
        console.error('Polling error:', err);
      }
    }, 1500);

    return () => clearInterval(interval);
  }, [activeCheck, loadData]);

  const handleRunStockCheck = async () => {
    setIsRunningCheck(true);
    try {
      const res = await fetch('/api/stock-checks', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
      });
      if (res.ok) {
        const data = await res.json();
        setActiveCheck({
          id: data.id,
          jobId: data.jobId,
          status: 'PENDING',
          totalChecked: 0,
          lowStockCount: 0,
          createdAt: new Date().toISOString(),
        });
      } else {
        setIsRunningCheck(false);
        alert('Failed to enqueue stock check');
      }
    } catch (err) {
      setIsRunningCheck(false);
      alert('Error triggering stock check');
    }
  };

  const lowStockItemsCount = items.filter((i) => i.status === 'LOW_STOCK').length;

  return (
    <div className="space-y-8">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4 border-b border-slate-200 pb-5">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-slate-900">Inventory Dashboard</h1>
          <p className="text-sm text-slate-500 mt-1">
            Real-time overview of inventory levels and background stock checks
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
            onClick={loadData}
            title="Refresh dashboard data"
            className="p-2 text-slate-500 hover:text-slate-800 hover:bg-slate-100 rounded-lg border border-slate-200 transition-colors"
          >
            <RefreshCw className={`h-4 w-4 ${isLoading ? 'animate-spin' : ''}`} />
          </button>
          <button
            onClick={handleRunStockCheck}
            disabled={isRunningCheck}
            className="inline-flex items-center space-x-2 bg-emerald-600 hover:bg-emerald-700 text-white font-medium px-4 py-2 rounded-lg text-sm shadow-sm transition-colors disabled:opacity-50"
          >
            <Play className={`h-4 w-4 ${isRunningCheck ? 'animate-spin' : ''}`} />
            <span>{isRunningCheck ? 'Processing Check...' : 'Run Stock Check'}</span>
          </button>
        </div>
      </div>

      {/* Active Running Stock Check Notification Banner */}
      {activeCheck && (
        <div
          className={`p-4 rounded-xl border flex items-center justify-between transition-all ${
            activeCheck.status === 'COMPLETED'
              ? 'bg-emerald-50 border-emerald-200 text-emerald-900'
              : activeCheck.status === 'FAILED'
              ? 'bg-red-50 border-red-200 text-red-900'
              : 'bg-blue-50 border-blue-200 text-blue-900'
          }`}
        >
          <div className="flex items-center space-x-3">
            {activeCheck.status === 'COMPLETED' && (
              <CheckCircle2 className="h-5 w-5 text-emerald-600 flex-shrink-0" />
            )}
            {activeCheck.status === 'FAILED' && (
              <XCircle className="h-5 w-5 text-red-600 flex-shrink-0" />
            )}
            {(activeCheck.status === 'PENDING' || activeCheck.status === 'PROCESSING') && (
              <RefreshCw className="h-5 w-5 text-blue-600 animate-spin flex-shrink-0" />
            )}
            <div>
              <p className="font-semibold text-sm">
                Stock Check: {activeCheck.status} (Job ID: {activeCheck.jobId})
              </p>
              <p className="text-xs opacity-90 mt-0.5">
                {activeCheck.status === 'COMPLETED'
                  ? `Completed evaluation: ${activeCheck.totalChecked} items checked, ${activeCheck.lowStockCount} low-stock alerts created.`
                  : activeCheck.status === 'FAILED'
                  ? `Execution failed: ${activeCheck.error || 'Unknown error'}`
                  : 'Asynchronous job queued in Redis; consumer worker is evaluating items...'}
              </p>
            </div>
          </div>
          <Link
            href="/stock-checks"
            className="text-xs font-semibold underline hover:opacity-80 px-2 py-1"
          >
            View History
          </Link>
        </div>
      )}

      {/* Summary Metrics */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        <div className="bg-white p-6 rounded-xl border border-slate-200 shadow-sm">
          <div className="flex items-center justify-between">
            <span className="text-sm font-medium text-slate-500">Total Items</span>
            <Package className="h-5 w-5 text-slate-400" />
          </div>
          <p className="text-3xl font-bold text-slate-900 mt-2">{items.length}</p>
          <span className="text-xs text-slate-400 mt-1 block">Active product catalog</span>
        </div>

        <div className="bg-white p-6 rounded-xl border border-slate-200 shadow-sm">
          <div className="flex items-center justify-between">
            <span className="text-sm font-medium text-amber-600">Low Stock Items</span>
            <AlertTriangle className="h-5 w-5 text-amber-500" />
          </div>
          <p className="text-3xl font-bold text-amber-600 mt-2">{lowStockItemsCount}</p>
          <span className="text-xs text-slate-400 mt-1 block">
            Items where quantity &le; minQuantity
          </span>
        </div>

        <div className="bg-white p-6 rounded-xl border border-slate-200 shadow-sm">
          <div className="flex items-center justify-between">
            <span className="text-sm font-medium text-slate-500">Latest Stock Check</span>
            <Clock className="h-5 w-5 text-slate-400" />
          </div>
          <div className="mt-2 flex items-center space-x-2">
            <span
              className={`inline-block w-2.5 h-2.5 rounded-full ${
                latestCheck?.status === 'COMPLETED'
                  ? 'bg-emerald-500'
                  : latestCheck?.status === 'FAILED'
                  ? 'bg-red-500'
                  : 'bg-slate-400'
              }`}
            />
            <p className="text-lg font-bold text-slate-900">
              {latestCheck ? latestCheck.status : 'No runs yet'}
            </p>
          </div>
          <span className="text-xs text-slate-400 mt-1 block">
            {latestCheck?.completedAt
              ? `Completed ${new Date(latestCheck.completedAt).toLocaleTimeString()}`
              : 'Background BullMQ worker'}
          </span>
        </div>
      </div>

      {/* Active Low Stock Alerts Table */}
      <div className="bg-white rounded-xl border border-slate-200 overflow-hidden shadow-sm">
        <div className="p-6 border-b border-slate-200 flex justify-between items-center">
          <div>
            <h2 className="text-base font-semibold text-slate-900">Recent Low-Stock Alerts</h2>
            <p className="text-xs text-slate-500 mt-0.5">
              Snapshots generated by worker when stock reaches critical thresholds
            </p>
          </div>
          <Link
            href="/inventory"
            className="text-xs font-medium text-emerald-600 hover:text-emerald-700 flex items-center space-x-1"
          >
            <span>Manage Inventory</span>
            <ArrowRight className="h-3 w-3" />
          </Link>
        </div>

        {alerts.length === 0 ? (
          <div className="p-8 text-center text-slate-500 text-sm">
            No low-stock alerts recorded yet. Click &quot;Run Stock Check&quot; to evaluate inventory.
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="bg-slate-50 text-slate-600 text-xs font-semibold uppercase tracking-wider border-b border-slate-200">
                <tr>
                  <th className="px-6 py-3">Product Name</th>
                  <th className="px-6 py-3">SKU</th>
                  <th className="px-6 py-3">Quantity</th>
                  <th className="px-6 py-3">Min Threshold</th>
                  <th className="px-6 py-3">Alert Time</th>
                  <th className="px-6 py-3">Check Status</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-200">
                {alerts.slice(0, 10).map((alert) => (
                  <tr key={alert.id} className="hover:bg-slate-50/50">
                    <td className="px-6 py-4 font-medium text-slate-900">
                      {alert.inventoryItem?.name || 'Inventory Item'}
                    </td>
                    <td className="px-6 py-4 font-mono text-xs text-slate-600">
                      {alert.inventoryItem?.sku || '---'}
                    </td>
                    <td className="px-6 py-4 text-amber-600 font-semibold">{alert.quantity}</td>
                    <td className="px-6 py-4 text-slate-500">{alert.minQuantity}</td>
                    <td className="px-6 py-4 text-xs text-slate-500">
                      {new Date(alert.createdAt).toLocaleString()}
                    </td>
                    <td className="px-6 py-4">
                      <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-amber-100 text-amber-800">
                        LOW_STOCK
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}
