# Phase 2 — Database and API

## Read first
`AGENTS.md`, context 02, 06, 07, 13, and 14.

## Goal
Implement Prisma/PostgreSQL persistence and the small inventory/stock-check API surface. Queue processing is not part of this phase.

## Tasks
1. Add Prisma schema for InventoryItem, StockCheck, and StockAlert exactly as documented.
2. Export a shared Prisma client from `packages/database`.
3. Create and commit the initial Prisma migration.
4. Implement inventory list/get/create/update endpoints and validation.
5. Enforce unique SKU and map duplicate errors to HTTP 409.
6. Return 404 for unknown IDs and 400 for invalid payloads.
7. Compute inventory status from `quantity <= minQuantity`.
8. Implement stock-check read endpoints. The enqueue endpoint may be a clearly marked temporary stub only if needed for staged development; do not pretend it queues work yet.
9. Add focused unit/API tests.

## Acceptance
- Migration applies to a clean PostgreSQL database.
- CRUD endpoints persist data.
- Validation and error cases behave as documented.
- Backend and worker can import the shared database package.
