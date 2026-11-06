# 06 — Database Design

The Prisma schema lives at `packages/database/prisma/schema.prisma`. Use three application tables.

## InventoryItem

| Field | Type / constraint |
|---|---|
| `id` | UUID primary key |
| `name` | required string |
| `sku` | required unique string |
| `category` | string |
| `quantity` | integer, non-negative |
| `minQuantity` | integer, non-negative |
| `createdAt` | timestamp |
| `updatedAt` | timestamp |

## StockCheck

| Field | Type / constraint |
|---|---|
| `id` | UUID primary key |
| `jobId` | unique string |
| `status` | enum: `PENDING`, `PROCESSING`, `COMPLETED`, `FAILED` |
| `totalChecked` | integer, default 0 |
| `lowStockCount` | integer, default 0 |
| `error` | nullable text |
| `startedAt` | nullable timestamp |
| `completedAt` | nullable timestamp |

## StockAlert

| Field | Type / constraint |
|---|---|
| `id` | UUID primary key |
| `inventoryItemId` | foreign key to InventoryItem |
| `stockCheckId` | foreign key to StockCheck |
| `quantity` | integer snapshot |
| `minQuantity` | integer snapshot |
| `message` | text |
| `createdAt` | timestamp |

An alert belongs to one item and one stock check. Snapshot `quantity` and `minQuantity` so the historical alert remains meaningful if the item changes later.

## Consistency

The worker persists `PROCESSING`, `COMPLETED`, and `FAILED` transitions to PostgreSQL. BullMQ state is useful operational metadata, but PostgreSQL is the source of truth presented by the API. Handle retries idempotently so a retried job does not create duplicate alerts for the same stock check/item pair.

## Migrations

Commit Prisma migrations to the repository. Apply production migrations using `prisma migrate deploy`, not `prisma migrate dev`. Run migrations as a controlled deployment step before application traffic depends on the new schema.
