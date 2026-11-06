# Phase 3 — Redis and BullMQ Workflow

## Read first
`AGENTS.md`, context 06–08 and 13–14.

## Goal
Implement the real asynchronous stock-check flow using Redis and BullMQ.

## Tasks
1. Configure Redis/BullMQ connection settings through environment variables.
2. Implement the `stock-check` queue producer in the backend.
3. `POST /api/stock-checks` creates a PENDING database record, enqueues a job, and returns immediately.
4. Implement worker consumer in `apps/worker/src/index.ts`.
5. Persist PROCESSING, COMPLETED, and FAILED transitions.
6. Create alert snapshots for each item where quantity <= minQuantity.
7. Ensure retries are idempotent and cannot create duplicate alerts.
8. Add bounded retry/backoff and graceful SIGTERM shutdown.
9. Implement stock-check list/detail APIs and frontend polling/display.
10. Add a safe, non-production failure simulation mechanism.

## Acceptance
- A submitted job is processed by a separate worker process.
- Database status and results are correct.
- Retry does not duplicate alerts.
- Failure state is persisted and displayed.
