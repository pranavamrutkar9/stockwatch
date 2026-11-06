'use client';

import { useState, useEffect, useCallback, useId } from 'react';
import { Package, Plus, Edit2, AlertCircle, RefreshCw, CheckCircle } from 'lucide-react';

interface InventoryItem {
  id: string;
  name: string;
  sku: string;
  category: string;
  quantity: number;
  minQuantity: number;
  status: 'LOW_STOCK' | 'HEALTHY';
  createdAt: string;
  updatedAt: string;
}

export default function InventoryPage() {
  const [items, setItems] = useState<InventoryItem[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [showAddModal, setShowAddModal] = useState(false);
  const [editingItem, setEditingItem] = useState<InventoryItem | null>(null);

  const [name, setName] = useState('');
  const [sku, setSku] = useState('');
  const [category, setCategory] = useState('');
  const [quantity, setQuantity] = useState<number>(0);
  const [minQuantity, setMinQuantity] = useState<number>(0);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);

  const addNameId = useId();
  const addSkuId = useId();
  const addCategoryId = useId();
  const addQuantityId = useId();
  const addMinQuantityId = useId();

  const editNameId = useId();
  const editCategoryId = useId();
  const editQuantityId = useId();
  const editMinQuantityId = useId();

  const loadItems = useCallback(async () => {
    setIsLoading(true);
    try {
      const res = await fetch('/api/inventory');
      if (res.ok) {
        const data = await res.json();
        setItems(data);
      }
    } catch (err) {
      console.error('Failed to load inventory items:', err);
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    loadItems();
  }, [loadItems]);

  const handleOpenAdd = () => {
    setName('');
    setSku('');
    setCategory('General');
    setQuantity(10);
    setMinQuantity(5);
    setErrorMessage(null);
    setShowAddModal(true);
  };

  const handleOpenEdit = (item: InventoryItem) => {
    setEditingItem(item);
    setName(item.name);
    setSku(item.sku);
    setCategory(item.category);
    setQuantity(item.quantity);
    setMinQuantity(item.minQuantity);
    setErrorMessage(null);
  };

  const handleCreate = async (e: React.FormEvent) => {
    e.preventDefault();
    setIsSubmitting(true);
    setErrorMessage(null);

    try {
      const res = await fetch('/api/inventory', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name: name.trim(),
          sku: sku.trim().toUpperCase(),
          category: category.trim(),
          quantity: Number(quantity),
          minQuantity: Number(minQuantity),
        }),
      });

      if (!res.ok) {
        const errData = await res.json().catch(() => ({}));
        if (res.status === 409) {
          throw new Error(`SKU "${sku}" is already in use by another item.`);
        }
        throw new Error(errData.message || 'Failed to create inventory item');
      }

      setShowAddModal(false);
      loadItems();
    } catch (err) {
      setErrorMessage((err as Error).message);
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleUpdate = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!editingItem) return;
    setIsSubmitting(true);
    setErrorMessage(null);

    try {
      const res = await fetch(`/api/inventory/${editingItem.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name: name.trim(),
          category: category.trim(),
          quantity: Number(quantity),
          minQuantity: Number(minQuantity),
        }),
      });

      if (!res.ok) {
        const errData = await res.json().catch(() => ({}));
        throw new Error(errData.message || 'Failed to update item');
      }

      setEditingItem(null);
      loadItems();
    } catch (err) {
      setErrorMessage((err as Error).message);
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4 border-b border-slate-200 pb-5">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-slate-900">Inventory Items</h1>
          <p className="text-sm text-slate-500 mt-1">
            Maintain catalog items, monitor current quantities, and adjust alert thresholds
          </p>
        </div>
        <div className="flex items-center space-x-3">
          <button
            onClick={loadItems}
            title="Refresh inventory"
            className="p-2 text-slate-500 hover:text-slate-800 hover:bg-slate-100 rounded-lg border border-slate-200 transition-colors"
          >
            <RefreshCw className={`h-4 w-4 ${isLoading ? 'animate-spin' : ''}`} />
          </button>
          <button
            onClick={handleOpenAdd}
            className="inline-flex items-center space-x-2 bg-emerald-600 hover:bg-emerald-700 text-white font-medium px-4 py-2 rounded-lg text-sm shadow-sm transition-colors"
          >
            <Plus className="h-4 w-4" />
            <span>Add Item</span>
          </button>
        </div>
      </div>

      {/* Inventory Table */}
      <div className="bg-white rounded-xl border border-slate-200 overflow-hidden shadow-sm">
        {items.length === 0 ? (
          <div className="p-12 text-center text-slate-500">
            <Package className="h-10 w-10 text-slate-300 mx-auto mb-3" />
            <p className="text-base font-medium text-slate-800">No inventory items recorded</p>
            <p className="text-sm text-slate-500 mt-1">
              Add your first item above to start tracking inventory.
            </p>
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="bg-slate-50 text-slate-600 text-xs font-semibold uppercase tracking-wider border-b border-slate-200">
                <tr>
                  <th className="px-6 py-3">Product Name</th>
                  <th className="px-6 py-3">SKU</th>
                  <th className="px-6 py-3">Category</th>
                  <th className="px-6 py-3">Quantity</th>
                  <th className="px-6 py-3">Min Threshold</th>
                  <th className="px-6 py-3">Stock Status</th>
                  <th className="px-6 py-3 text-right">Actions</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-200">
                {items.map((item) => (
                  <tr key={item.id} className="hover:bg-slate-50/50">
                    <td className="px-6 py-4 font-medium text-slate-900">{item.name}</td>
                    <td className="px-6 py-4 font-mono text-xs text-slate-600">{item.sku}</td>
                    <td className="px-6 py-4 text-slate-500">{item.category}</td>
                    <td className="px-6 py-4 font-semibold text-slate-900">{item.quantity}</td>
                    <td className="px-6 py-4 text-slate-500">{item.minQuantity}</td>
                    <td className="px-6 py-4">
                      {item.status === 'LOW_STOCK' ? (
                        <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-amber-100 text-amber-800">
                          <span className="w-1.5 h-1.5 mr-1.5 rounded-full bg-amber-500" />
                          LOW_STOCK
                        </span>
                      ) : (
                        <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-emerald-100 text-emerald-800">
                          <span className="w-1.5 h-1.5 mr-1.5 rounded-full bg-emerald-500" />
                          HEALTHY
                        </span>
                      )}
                    </td>
                    <td className="px-6 py-4 text-right">
                      <button
                        onClick={() => handleOpenEdit(item)}
                        className="inline-flex items-center text-xs font-medium text-slate-600 hover:text-emerald-600 p-1 rounded hover:bg-slate-100"
                      >
                        <Edit2 className="h-3.5 w-3.5 mr-1" />
                        Edit
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* Add Modal */}
      {showAddModal && (
        <div className="fixed inset-0 bg-slate-900/40 backdrop-blur-sm z-50 flex items-center justify-center p-4">
          <div className="bg-white rounded-xl shadow-xl max-w-md w-full p-6 border border-slate-200">
            <h3 className="text-lg font-bold text-slate-900 mb-4">Add Inventory Item</h3>
            {errorMessage && (
              <div className="mb-4 p-3 bg-red-50 border border-red-200 text-red-700 text-xs rounded-lg flex items-center space-x-2">
                <AlertCircle className="h-4 w-4 flex-shrink-0" />
                <span>{errorMessage}</span>
              </div>
            )}
            <form onSubmit={handleCreate} className="space-y-4">
              <div>
                <label htmlFor={addNameId} className="block text-xs font-medium text-slate-700 mb-1">
                  Product Name
                </label>
                <input
                  id={addNameId}
                  required
                  type="text"
                  placeholder="e.g. Wireless Mouse"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  className="w-full px-3 py-2 border border-slate-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                />
              </div>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label htmlFor={addSkuId} className="block text-xs font-medium text-slate-700 mb-1">
                    SKU (Unique)
                  </label>
                  <input
                    id={addSkuId}
                    required
                    type="text"
                    placeholder="e.g. MOUSE-001"
                    value={sku}
                    onChange={(e) => setSku(e.target.value)}
                    className="w-full px-3 py-2 border border-slate-300 rounded-lg text-sm uppercase font-mono focus:outline-none focus:ring-2 focus:ring-emerald-500"
                  />
                </div>
                <div>
                  <label htmlFor={addCategoryId} className="block text-xs font-medium text-slate-700 mb-1">
                    Category
                  </label>
                  <input
                    id={addCategoryId}
                    required
                    type="text"
                    value={category}
                    onChange={(e) => setCategory(e.target.value)}
                    className="w-full px-3 py-2 border border-slate-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                  />
                </div>
              </div>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label htmlFor={addQuantityId} className="block text-xs font-medium text-slate-700 mb-1">
                    Current Quantity
                  </label>
                  <input
                    id={addQuantityId}
                    required
                    type="number"
                    min="0"
                    value={quantity}
                    onChange={(e) => setQuantity(Number(e.target.value))}
                    className="w-full px-3 py-2 border border-slate-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                  />
                </div>
                <div>
                  <label htmlFor={addMinQuantityId} className="block text-xs font-medium text-slate-700 mb-1">
                    Minimum Threshold
                  </label>
                  <input
                    id={addMinQuantityId}
                    required
                    type="number"
                    min="0"
                    value={minQuantity}
                    onChange={(e) => setMinQuantity(Number(e.target.value))}
                    className="w-full px-3 py-2 border border-slate-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                  />
                </div>
              </div>
              <div className="flex justify-end space-x-3 mt-6 pt-2 border-t border-slate-100">
                <button
                  type="button"
                  onClick={() => setShowAddModal(false)}
                  className="px-4 py-2 border border-slate-300 rounded-lg text-sm font-medium text-slate-700 hover:bg-slate-50"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={isSubmitting}
                  className="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg text-sm font-medium disabled:opacity-50"
                >
                  {isSubmitting ? 'Saving...' : 'Create Item'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Edit Modal */}
      {editingItem && (
        <div className="fixed inset-0 bg-slate-900/40 backdrop-blur-sm z-50 flex items-center justify-center p-4">
          <div className="bg-white rounded-xl shadow-xl max-w-md w-full p-6 border border-slate-200">
            <h3 className="text-lg font-bold text-slate-900 mb-1">Edit Item: {editingItem.sku}</h3>
            <p className="text-xs text-slate-500 mb-4">SKU cannot be modified.</p>
            {errorMessage && (
              <div className="mb-4 p-3 bg-red-50 border border-red-200 text-red-700 text-xs rounded-lg flex items-center space-x-2">
                <AlertCircle className="h-4 w-4 flex-shrink-0" />
                <span>{errorMessage}</span>
              </div>
            )}
            <form onSubmit={handleUpdate} className="space-y-4">
              <div>
                <label htmlFor={editNameId} className="block text-xs font-medium text-slate-700 mb-1">
                  Product Name
                </label>
                <input
                  id={editNameId}
                  required
                  type="text"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  className="w-full px-3 py-2 border border-slate-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                />
              </div>
              <div>
                <label htmlFor={editCategoryId} className="block text-xs font-medium text-slate-700 mb-1">
                  Category
                </label>
                <input
                  id={editCategoryId}
                  required
                  type="text"
                  value={category}
                  onChange={(e) => setCategory(e.target.value)}
                  className="w-full px-3 py-2 border border-slate-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                />
              </div>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label htmlFor={editQuantityId} className="block text-xs font-medium text-slate-700 mb-1">
                    Current Quantity
                  </label>
                  <input
                    id={editQuantityId}
                    required
                    type="number"
                    min="0"
                    value={quantity}
                    onChange={(e) => setQuantity(Number(e.target.value))}
                    className="w-full px-3 py-2 border border-slate-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                  />
                </div>
                <div>
                  <label htmlFor={editMinQuantityId} className="block text-xs font-medium text-slate-700 mb-1">
                    Minimum Threshold
                  </label>
                  <input
                    id={editMinQuantityId}
                    required
                    type="number"
                    min="0"
                    value={minQuantity}
                    onChange={(e) => setMinQuantity(Number(e.target.value))}
                    className="w-full px-3 py-2 border border-slate-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500"
                  />
                </div>
              </div>
              <div className="flex justify-end space-x-3 mt-6 pt-2 border-t border-slate-100">
                <button
                  type="button"
                  onClick={() => setEditingItem(null)}
                  className="px-4 py-2 border border-slate-300 rounded-lg text-sm font-medium text-slate-700 hover:bg-slate-50"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={isSubmitting}
                  className="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg text-sm font-medium disabled:opacity-50"
                >
                  {isSubmitting ? 'Updating...' : 'Save Changes'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
}
