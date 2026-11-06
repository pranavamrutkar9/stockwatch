# 08 — Background Processing

## Required flow

1. Frontend sends `POST /api/stock-checks`.
2. NestJS creates a `StockCheck` record with status `PENDING`.
3. Backend adds a job to the BullMQ queue named `stock-check`.
4. The independent worker consumes the job and updates the record to `PROCESSING`.
5. Worker reads inventory items.
6. For each item where `quantity <= minQuantity`, worker creates a `StockAlert` containing quantity/minimum snapshots.
7. Worker updates `totalChecked`, `lowStockCount`, `completedAt`, and status `COMPLETED`.
8. On an unrecoverable error, worker persists status `FAILED` and a useful error message.
9. Frontend polls the API and displays the final state.

## Ownership boundaries

- Worker is a separate Node process with entry point `apps/worker/src/index.ts` and its own container.
- Backend is the queue producer only; worker is the consumer.
- Backend and worker use the shared Prisma client from `packages/database`.
- Use the persisted StockCheck ID in job data so the worker can find its record.
- PostgreSQL is the source of truth for status shown in the UI.

## Reliability requirements

- Configure a small retry count and exponential backoff.
- Keep failed jobs for inspection.
- Make processing idempotent. A retry must not duplicate alerts for the same stock-check/item pair. Enforce this with a database uniqueness constraint or a transaction-safe upsert strategy.
- Persist failure state even when the processing operation fails.
- Close the worker gracefully on SIGTERM and allow active work to finish within the shutdown grace period.
- Configure Redis connection retry/backoff so a temporary startup ordering issue does not cause an immediate permanent process exit.
- Do not mark a check completed before all alert writes and final status updates succeed.

## Failure demonstration

Provide a controlled way to make a job fail for the walkthrough, such as a worker environment flag `WORKER_SIMULATE_FAILURE=true` in a non-production demo configuration. The failed check must show `FAILED` and a safe error message in the UI. Never expose a public unauthenticated failure switch in the deployed production app.

## Optional

A recurring scheduled check is optional and should be omitted unless the manual flow is already complete and tested.
