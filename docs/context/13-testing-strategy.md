# 13 — Testing Strategy

Keep tests focused on the behaviours that protect the assessment's critical path. Do not chase arbitrary coverage.

## Unit tests

- Low-stock rule: `quantity <= minQuantity` is low stock; greater quantity is healthy.
- Inventory validation: negative or non-integer quantity/minimum is rejected.
- Worker processor: counts all items and creates alerts only for low-stock items.
- Worker retry/idempotency: retrying a stock check does not duplicate alerts.

## API tests

- Create and list inventory.
- Duplicate SKU returns 409.
- Unknown inventory/stock-check ID returns 404.
- `POST /api/stock-checks` returns promptly with a persisted pending record and job identifier.
- Health endpoint reports unavailable dependencies as unhealthy.

## Integration test

With PostgreSQL and Redis available:

1. Create healthy and low-stock inventory rows.
2. Submit a stock check.
3. Confirm the worker consumes it.
4. Poll the API until terminal status.
5. Verify totals and alert snapshots in PostgreSQL.

## Container smoke tests

- All five services start.
- Health checks become healthy.
- Frontend loads.
- Frontend can call backend through `/api/*`.
- Backend and worker can reach PostgreSQL and Redis.
- Restarting the stack does not erase PostgreSQL data.

## CI gate

At minimum, CI runs dependency installation, lint/type checks, relevant tests, and production builds before image publication. Report skipped tests honestly; do not fabricate passing results.
