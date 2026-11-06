export default function InventoryPage() {
  return (
    <div className="space-y-6">
      <div className="flex justify-between items-center border-b border-slate-200 pb-5">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-slate-900">Inventory Items</h1>
          <p className="text-sm text-slate-500 mt-1">
            Manage product catalog, stock quantities, and minimum thresholds
          </p>
        </div>
        <button
          disabled
          className="bg-emerald-600 text-white font-medium px-4 py-2 rounded-lg text-sm shadow-sm opacity-50 cursor-not-allowed"
        >
          + Add Item
        </button>
      </div>

      <div className="bg-white rounded-xl border border-slate-200 p-12 text-center">
        <p className="text-slate-500 text-sm">
          Inventory database is being configured in Phase 2. Items will be displayed here.
        </p>
      </div>
    </div>
  );
}

