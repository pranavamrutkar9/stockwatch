# 07 — API Contracts

All routes are prefixed with `/api`. Keep this API surface small. Use JSON request and response bodies.

## Routes

| Method | Endpoint | Responsibility |
|---|---|---|
| GET | `/api/health` | Backend health; check database and Redis reachability |
| GET | `/api/inventory` | List inventory |
| GET | `/api/inventory/:id` | Get one item |
| POST | `/api/inventory` | Create item |
| PATCH | `/api/inventory/:id` | Update item details, quantity, or minimum |
| POST | `/api/stock-checks` | Enqueue a stock check |
| GET | `/api/stock-checks` | List previous checks |
| GET | `/api/stock-checks/:id` | Get status and result for one check |
| GET | `/api/alerts` | List low-stock alerts |

## Inventory request examples

Create:

```json
{
  "name": "Wireless Mouse",
  "sku": "MOUSE-001",
  "category": "Accessories",
  "quantity": 3,
  "minQuantity": 10
}
```

Update: accept only supplied mutable fields (`name`, `sku`, `category`, `quantity`, `minQuantity`). Reject an empty update body. Do not allow clients to set IDs or timestamps.

Inventory responses include a computed `status`: `LOW_STOCK` or `HEALTHY`.

## Enqueue behaviour

`POST /api/stock-checks` creates a persisted `StockCheck` record, enqueues a BullMQ job, and returns immediately. It must not wait for the worker to finish.

```json
{
  "success": true,
  "id": "stock-check-record-uuid",
  "jobId": "bullmq-job-id",
  "status": "PENDING",
  "message": "Stock check queued successfully"
}
```

The frontend polls `GET /api/stock-checks/:id` until status is `COMPLETED` or `FAILED`.

## Stock check response shape

Return at least:

```json
{
  "id": "stock-check-record-uuid",
  "jobId": "bullmq-job-id",
  "status": "COMPLETED",
  "totalChecked": 12,
  "lowStockCount": 3,
  "error": null,
  "startedAt": "ISO-8601 timestamp",
  "completedAt": "ISO-8601 timestamp"
}
```

## Validation and errors

- Validate request bodies using NestJS DTOs and `class-validator`.
- `quantity` and `minQuantity` must be non-negative integers.
- SKU must be unique; return HTTP `409 Conflict` for duplicates.
- Return `404 Not Found` for unknown IDs.
- Return `400 Bad Request` for invalid payloads.
- Return a generic `500` response for unexpected failures; log diagnostic details server-side without exposing secrets or stack traces to clients.
- Health endpoint should return a non-success status when required dependencies are unavailable.
- Use a consistent error response shape, for example `{ "statusCode": 400, "message": ["..."], "error": "Bad Request" }`.

## Scope control

Do not add authentication, pagination, sorting, filtering, or additional endpoints unless implementation scale or the assessment explicitly requires them. A simple bounded list is sufficient for this assessment.
