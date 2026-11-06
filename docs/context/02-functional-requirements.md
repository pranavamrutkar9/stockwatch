# 02 — Functional Requirements

## Views

Only three application views are required:

1. Dashboard — inventory summary, latest stock check, low-stock alerts, and a Run Stock Check action.
2. Inventory — list, create, and update inventory items.
3. Stock Checks — current and previous check runs, statuses, counts, and errors.

Keep the UI clear and functional. Do not spend assessment time on elaborate design.

## Inventory item

Fields:

- `id`: UUID.
- `name`: required string.
- `sku`: required unique string.
- `category`: string.
- `quantity`: non-negative integer.
- `minQuantity`: non-negative integer.
- `createdAt` and `updatedAt`: timestamps.

Status is computed, not stored:

- `LOW_STOCK` when `quantity <= minQuantity`.
- `HEALTHY` when `quantity > minQuantity`.

## Stock check

A user can manually start a stock check. The API acknowledges the request immediately. The worker evaluates all inventory items and creates an alert for each item that meets the low-stock rule.

A check has one of these statuses:

- `PENDING`
- `PROCESSING`
- `COMPLETED`
- `FAILED`

A completed check exposes `totalChecked` and `lowStockCount`. A failed check exposes a safe, useful error message.

## Alerts and history

Each alert belongs to one inventory item and one stock check. Store the quantity and minimum quantity observed at check time so historical alerts remain meaningful after the inventory record changes.

The stock-check history lists previous runs and allows a user to inspect an individual run.

## Explicit exclusions

No authentication, roles, email, supplier/purchase-order workflows, advanced analytics, or automatic recurring checks are required. A tiny optional scheduled check must not delay the manual workflow.
