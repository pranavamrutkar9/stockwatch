# StockWatch System Architecture & Technical Design

## 1. High-Level Architecture Diagram

```mermaid
graph TD
    Client["Public Web Browser / HTTP Client"]
    
    subgraph Host ["Host / Cloud VM Environment"]
        subgraph Ports ["Public Network Boundary"]
            Port80["Port 80: HTTP Ingress"]
        end
        
        subgraph DockerNetwork ["Isolated Docker Bridge: stockwatch-network"]
            Frontend["Frontend Container (Next.js 15 App Router)\nInternal Port: 3000\nUser: node (UID 1000)"]
            Backend["Backend API Container (NestJS 10)\nInternal Port: 4000\nUser: node (UID 1000)"]
            Worker["Worker Process Container (BullMQ Consumer)\nUser: node (UID 1000)"]
            Redis["Queue Container (Redis 7 AOF)\nInternal Port: 6379"]
            Postgres["Database Container (PostgreSQL 16)\nInternal Port: 5432"]
            
            VolumePG[("Named Volume:\nstockwatch_postgres_data")]
            VolumeRedis[("Named Volume:\nstockwatch_redis_data")]
        end
    end

    Client -->|HTTP GET / POST| Port80
    Port80 --> Frontend
    Frontend -->|Next.js Proxy /api/*| Backend
    Backend -->|Enqueue Job / PING| Redis
    Backend -->|Prisma Client CRUD| Postgres
    Worker -->|Consume 'stock-check' queue| Redis
    Worker -->|Idempotent Upsert & State Updates| Postgres
    Postgres --- VolumePG
    Redis --- VolumeRedis

    classDef public fill:#dbeafe,stroke:#1d4ed8,stroke-width:2px;
    classDef private fill:#f3f4f6,stroke:#374151,stroke-width:1.5px;
    classDef storage fill:#fef3c7,stroke:#d97706,stroke-width:1.5px;

    class Client,Port80 public;
    class Frontend,Backend,Worker private;
    class Redis,Postgres,VolumePG,VolumeRedis storage;
```

---

## 2. Service Responsibilities & Isolation Boundaries

| Service | Runtime Container | Network Exposure | Primary Role |
|---|---|---|---|
| **Frontend** | `stockwatch-frontend` | Public (`80:3000`) | Serves SSR React UI, manages client state, and proxies `/api/*` to internal backend. |
| **Backend** | `stockwatch-backend` | Internal Only (`4000`) | Validates requests, enforces business rules, produces BullMQ jobs, and exposes health probes. |
| **Worker** | `stockwatch-worker` | Internal Only | Consumes background jobs, executes inventory evaluations, and persists alert snapshots. |
| **PostgreSQL** | `stockwatch-postgres` | Internal Only (`5432`) | ACID storage of inventory, stock checks, and alerts. Persists to named Docker volume. |
| **Redis** | `stockwatch-redis` | Internal Only (`6379`) | In-memory message queue broker running with Append-Only File (AOF) persistence. |

---

## 3. Data Flow & Sequence Diagram

The following sequence illustrates an asynchronous stock-check execution:

```mermaid
sequenceDiagram
    autonumber
    actor User as Client Browser
    participant FE as Next.js Frontend
    participant BE as NestJS Backend
    participant DB as PostgreSQL
    participant Q as Redis (BullMQ)
    participant W as Worker Consumer

    User->>FE: Click "Run Stock Check"
    FE->>BE: POST /api/stock-checks
    BE->>DB: INSERT INTO "StockCheck" (status: PENDING)
    DB-->>BE: StockCheck Record (ID: uuid)
    BE->>Q: Enqueue Job into "stock-check" { stockCheckId: uuid }
    BE-->>FE: 202 Accepted { id: uuid, jobId: 1, status: "PENDING" }
    FE-->>User: Display Pending State (Begin Polling)

    Note over W,Q: Worker polls Redis queue
    Q->>W: Deliver Job { stockCheckId: uuid }
    W->>DB: UPDATE "StockCheck" SET status = 'PROCESSING', startedAt = NOW()
    W->>DB: SELECT * FROM "InventoryItem"
    DB-->>W: Return items list
    
    loop Each Item (quantity <= minQuantity)
        W->>DB: UPSERT "StockAlert" ON CONFLICT (stockCheckId, inventoryItemId)
    end

    W->>DB: UPDATE "StockCheck" SET status = 'COMPLETED', totalChecked, lowStockCount, completedAt = NOW()
    
    loop Client Polling (every 2-3s)
        FE->>BE: GET /api/stock-checks/{id}
        BE->>DB: SELECT * FROM "StockCheck" WITH alerts
        DB-->>BE: StockCheck { status: 'COMPLETED', ... }
        BE-->>FE: Return JSON Status
        FE-->>User: Render Completed Results & Alert Badges
    end
```

---

## 4. Key Architectural Safeguards

1. **Idempotent Upsert for Low-Stock Alerts**:
   Worker uses Prisma compound index:
   ```prisma
   @@unique([stockCheckId, inventoryItemId])
   ```
   If a worker process restarts mid-job or BullMQ retries an interrupted task, the alerts are upserted without duplication.

2. **Controlled Failure Simulation**:
   When `WORKER_SIMULATE_FAILURE=true` is injected into the worker container, the processor deliberately transitions the job to `FAILED`, persists the reason in the database, and throws, demonstrating reliability under network or execution failures.

3. **Zero Secrets in Images**:
   Docker multi-stage builds strictly build binaries and discard compile-time build caches. Runtime secrets (such as database credentials and Redis authentication) are supplied exclusively through server-side environment variables (`.env`).
