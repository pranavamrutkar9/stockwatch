'use client';

import { useState, useEffect, useCallback } from 'react';
import { Play, RefreshCw, CheckCircle2, XCircle, AlertTriangle, ChevronDown, ChevronRight } from 'lucide-react';

interface StockAlert {
  id: string;
  inventoryItemId: string;
  quantity: number;
  minQuantity: number;
  message: string;
  createdAt: string;
  inventoryItem?: {
    name: string;
    sku: string;
  };
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
  alerts?: StockAlert[];
}

export default function StockChecksPage() {
  const [checks, setChecks] = useState<StockCheck[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [isRunningCheck, setIsRunningCheck] = useState(false);
  const [activeCheckId, setActiveCheckId] = useState<string | null>(null);

  const loadChecks = useCallback(async () => {
    setIsLoading(true);
    try {
      const res = await fetch('/api/stock-checks');
      if (res.ok) {
        const data = await res.json();
        setChecks(data);
      }
    } catch (err) {
      console.error('Failed to load stock checks:', err);
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    loadChecks();
  }, [loadChecks]);

  // Polling active check until terminal state
  useEffect(() => {
    if (!activeCheckId) return;

    const interval = setInterval(async () => {
      try {
        const res = await fetch(`/api/stock-checks/${activeCheckId}`);
        if (res.ok) {
          const updated: StockCheck = await res.json();
          setChecks((prev) => prev.map((c) => (c.id === updated.id ? updated : c)));
          if (updated.status === 'COMPLETED' || updated.status === 'FAILED') {
            setActiveCheckId(null);
            setIsRunningCheck(false);
            loadChecks();
          }
        }
      } catch (err) {
        console.error('Polling error:', err);
      }
    }, 1500);

    return () => clearInterval(interval);
  }, [activeCheckId, loadChecks]);

  const handleRunCheck = async () => {
    setIsRunningCheck(true);
    try {
      const res = await fetch('/api/stock-checks', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
      });
      if (res.ok) {
        const data = await res.json();
        setActiveCheckId(data.id);
        // Prepend placeholder check into list immediately
        setChecks((prev) => [
          {
            id: data.id,
            jobId: data.jobId,
            status: 'PENDING',
            totalChecked: 0,
            lowStockCount: 0,
            createdAt: new Date().toISOString(),
          },
          ...prev,
        ]);
      } else {
        setIsRunningCheck(false);
        alert('Failed to enqueue stock check');
      }
    } catch (err) {
      setIsRunningCheck(false);
      alert('Error triggering stock check');
    }
  };

  const toggleExpand = async (id: string) => {
    if (expandedId === id) {
      setExpandedId(null);
      return;
    }
    setExpandedId(id);
    try {
      const res = await fetch(`/api/stock-checks/${id}`);
      if (res.ok) {
        const detailed = await res.json();
        setChecks((prev) => prev.map((c) => (c.id === id ? detailed : c)));
      }
    } catch (err) {
      console.error('Failed to load check details:', err);
    }
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4 border-b border-slate-200 pb-5">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-slate-900">Stock Check History</h1>
          <p className="text-sm text-slate-500 mt-1">
            Asynchronous background job runs, processing status, and alert results
          </p>
        </div>
        <div className="flex items-center space-x-3">
          <button
            onClick={loadChecks}
            title="Refresh checks"
            className="p-2 text-slate-500 hover:text-slate-800 hover:bg-slate-100 rounded-lg border border-slate-200 transition-colors"
          >
            <RefreshCw className={`h-4 w-4 ${isLoading ? 'animate-spin' : ''}`} />
          </button>
          <button
            onClick={handleRunCheck}
            disabled={isRunningCheck}
            className="inline-flex items-center space-x-2 bg-emerald-600 hover:bg-emerald-700 text-white font-medium px-4 py-2 rounded-lg text-sm shadow-sm transition-colors disabled:opacity-50"
          >
            <Play className={`h-4 w-4 ${isRunningCheck ? 'animate-spin' : ''}`} />
            <span>{isRunningCheck ? 'Processing...' : 'Run New Check'}</span>
          </button>
        </div>
      </div>

      {/* History Table */}
      <div className="bg-white rounded-xl border border-slate-200 overflow-hidden shadow-sm">
        {checks.length === 0 ? (
          <div className="p-12 text-center text-slate-500">
            <RefreshCw className="h-10 w-10 text-slate-300 mx-auto mb-3" />
            <p className="text-base font-medium text-slate-800">No stock checks have been run yet</p>
            <p className="text-sm text-slate-500 mt-1">
              Trigger a check above to queue an asynchronous BullMQ evaluation.
            </p>
          </div>
        ) : (
          <div className="divide-y divide-slate-200">
            {checks.map((check) => {
              const isExpanded = expandedId === check.id;
              return (
                <div key={check.id} className="transition-colors hover:bg-slate-50/50">
                  <div
                    onClick={() => toggleExpand(check.id)}
                    className="p-6 cursor-pointer flex flex-col md:flex-row md:items-center justify-between gap-4"
                  >
                    <div className="flex items-start md:items-center space-x-3">
                      {isExpanded ? (
                        <ChevronDown className="h-4 w-4 text-slate-400 mt-1 md:mt-0 flex-shrink-0" />
                      ) : (
                        <ChevronRight className="h-4 w-4 text-slate-400 mt-1 md:mt-0 flex-shrink-0" />
                      )}
                      <div>
                        <div className="flex items-center space-x-2">
                          <span className="font-mono text-xs font-medium text-slate-900">
                            {check.jobId}
                          </span>
                          <span
                            className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold ${
                              check.status === 'COMPLETED'
                                ? 'bg-emerald-100 text-emerald-800'
                                : check.status === 'FAILED'
                                ? 'bg-red-100 text-red-800'
                                : check.status === 'PROCESSING'
                                ? 'bg-blue-100 text-blue-800'
                                : 'bg-slate-100 text-slate-700'
                            }`}
                          >
                            {check.status === 'PROCESSING' && (
                              <RefreshCw className="w-2.5 h-2.5 mr-1 animate-spin" />
                            )}
                            {check.status}
                          </span>
                        </div>
                        <p className="text-xs text-slate-400 mt-1">
                          Started: {new Date(check.createdAt).toLocaleString()}
                          {check.completedAt && ` • Finished: ${new Date(check.completedAt).toLocaleTimeString()}`}
                        </p>
                      </div>
                    </div>

                    <div className="flex items-center space-x-6 text-sm">
                      <div className="text-right">
                        <span className="text-xs text-slate-400 block">Total Checked</span>
                        <span className="font-semibold text-slate-700">{check.totalChecked} items</span>
                      </div>
                      <div className="text-right">
                        <span className="text-xs text-slate-400 block">Low Stock Alerts</span>
                        <span
                          className={`font-semibold ${
                            check.lowStockCount > 0 ? 'text-amber-600' : 'text-emerald-600'
                          }`}
                        >
                          {check.lowStockCount} alerts
                        </span>
                      </div>
                    </div>
                  </div>

                  {/* Expanded Alert Details / Error message */}
                  {isExpanded && (
                    <div className="px-6 pb-6 pt-2 bg-slate-50 border-t border-slate-100">
                      {check.status === 'FAILED' && (
                        <div className="p-4 bg-red-50 border border-red-200 rounded-lg text-red-800 text-xs">
                          <p className="font-semibold">Worker Error Diagnostic:</p>
                          <p className="mt-1 font-mono">{check.error || 'Unknown failure'}</p>
                        </div>
                      )}

                      {check.status === 'COMPLETED' && (!check.alerts || check.alerts.length === 0) && (
                        <p className="text-xs text-emerald-700 flex items-center space-x-1.5 py-2">
                          <CheckCircle2 className="h-4 w-4" />
                          <span>All items were healthy. No low-stock alerts created.</span>
                        </p>
                      )}

                      {check.alerts && check.alerts.length > 0 && (
                        <div className="space-y-2">
                          <h4 className="text-xs font-semibold text-slate-700 uppercase tracking-wider">
                            Alert Snapshots for this Run:
                          </h4>
                          <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                            {check.alerts.map((alert) => (
                              <div
                                key={alert.id}
                                className="bg-white p-3 rounded-lg border border-slate-200 text-xs flex justify-between items-center shadow-2xs"
                              >
                                <div>
                                  <p className="font-semibold text-slate-900">
                                    {alert.inventoryItem?.name || 'Inventory Item'}
                                  </p>
                                  <p className="font-mono text-[11px] text-slate-500">
                                    SKU: {alert.inventoryItem?.sku || '---'}
                                  </p>
                                </div>
                                <div className="text-right">
                                  <span className="text-amber-600 font-bold">
                                    Qty: {alert.quantity}
                                  </span>
                                  <span className="text-slate-400 block text-[11px]">
                                    (Min: {alert.minQuantity})
                                  </span>
                                </div>
                              </div>
                            ))}
                          </div>
                        </div>
                      )}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}
