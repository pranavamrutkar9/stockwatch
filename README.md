# StockWatch — Inventory Monitoring & Alert System

[![CI/CD Pipeline](https://github.com/pranavamrutkar9/stockwatch/actions/workflows/deploy.yml/badge.svg)](https://github.com/pranavamrutkar9/stockwatch/actions/workflows/deploy.yml)

StockWatch is a production-ready, containerized inventory monitoring and low-stock alert platform built with TypeScript across a pnpm monorepo. It features asynchronous background processing via Redis and BullMQ, PostgreSQL persistence via Prisma ORM, automated CI/CD via GitHub Actions and GitHub Container Registry (GHCR), and repeatable deployment to an isolated Ubuntu cloud VM.

---

## 1. System Architecture

```text
                               +-------------------------------------------------------+
                               |                 Isolated Docker Network               |
                               |                   (stockwatch-network)                |
                               |                                                       |
[Public Browser] ------------> | [Frontend: Next.js 15]                                |
    (Port 80/3000)             |    | (Next.js dynamic proxy /api/*)                   |
                               |    v                                                  |
                               | [Backend: NestJS API] (Port 4000)                     |
                               |    |                         \                        |
                               |    v (BullMQ Producer)        v (Prisma Client)       |
                               | [Redis 7 AOF]             [PostgreSQL 16]             |
                               |    ^ (stock-check queue)      ^ (Source of Truth)     |
                               |    |                          |                       |
                               | [Worker Process] -------------+                       |
                               | (Independent Node.js Consumer)                        |
                               +-------------------------------------------------------+
```

### Architectural Principles & Constraints
1. **Separation of Concerns**: The HTTP API server (`apps/backend`) and the background worker (`apps/worker`) run as separate operating system processes and isolated Docker containers.
2. **PostgreSQL as Source of Truth**: The database stores inventory items, stock check lifecycle states (`PENDING` -> `PROCESSING` -> `COMPLETED`/`FAILED`), and alert snapshots.
3. **Queue-Backed Processing**: Stock check triggers enqueue BullMQ jobs to Redis and return `202 Accepted` immediately with a `jobId`, preventing slow HTTP transactions.
4. **Network Isolation**: PostgreSQL (`5432`) and Redis (`6379`) are strictly bound to the private internal Docker network (`stockwatch-network`) and are never exposed publicly on the host or VM firewall.
5. **Idempotent Job Processing**: Alerts are recorded with a compound unique key `[stockCheckId, inventoryItemId]`, guaranteeing that retried or duplicate jobs will never produce duplicate alert records.

---

## 2. Technology Stack

| Layer | Technology | Key Features |
|---|---|---|
| **Monorepo** | `pnpm` Workspaces | Strict isolated dependencies, shared packages, reproducible lockfile |
| **Frontend** | Next.js 15 (App Router), React 19, Tailwind CSS | Server-side rendering, dynamic `/api/*` Route Handler proxy, real-time polling |
| **Backend** | NestJS 10, TypeScript | Modular architecture, DTO validation via `class-validator`, `/api/health` probe |
| **Database** | PostgreSQL 16 + Prisma ORM 6 | Type-safe queries, migration-controlled schema, named volume persistence |
| **Queue** | Redis 7 (AOF) + BullMQ 5 | Durable FIFO queue, exponential backoff retries, connection lifecycle hooks |
| **Worker** | Node.js 22 + TypeScript | Standalone consumer process, PID logging, graceful SIGTERM/SIGINT shutdown |
| **Containerization** | Docker & Docker Compose | Multi-stage builds, non-root `node` user, health checks, restart policies |
| **CI/CD** | GitHub Actions & GHCR | Automated validation, immutable commit SHA tags, layer caching, automated CD |

---

## 3. Repository Structure

```text
stockwatch/
├── .github/
│   └── workflows/
│       └── deploy.yml              # CI/CD: lint, test, build, GHCR push, VM deploy
├── apps/
│   ├── backend/                    # NestJS API application (port 4000)
│   ├── frontend/                   # Next.js 15 web application (port 3000 / 80)
│   └── worker/                     # Standalone BullMQ background worker
├── packages/
│   └── database/                   # Prisma schema, migrations, generated client
├── infrastructure/
│   ├── docker/
│   │   ├── backend.Dockerfile      # Multi-stage production image for NestJS API
│   │   ├── frontend.Dockerfile     # Multi-stage standalone image for Next.js
│   │   ├── worker.Dockerfile       # Multi-stage image for background worker
│   │   ├── docker-compose.yml      # Local development and integration stack
│   │   └── docker-compose.prod.yml # Production compose stack (GHCR SHA images)
│   └── deployment/
│       ├── setup-vm.sh             # Automated Ubuntu VM provisioning & firewall
│       ├── deploy.sh               # Zero-downtime deployment & health verification
│       └── rollback.sh             # Automated rollback to previous known-good SHA
├── scripts/
│   └── test-phase5-integration.ps1 # End-to-end integration & failure test suite
├── docs/                           # Architecture, deployment, and assessment docs
├── package.json                    # Monorepo root package definition
└── pnpm-workspace.yaml             # Workspace definitions
```

---

## 4. Quickstart — Local Execution

### Prerequisites
- Docker Engine & Docker Compose
- Node.js 22+ & pnpm 11+ (for local native development)

### One-Command Start (Local Docker Compose)
To launch the complete 5-container stack locally with health checks and volume persistence:

```bash
# Start all services in the background
docker-compose -f infrastructure/docker/docker-compose.yml up -d

# Verify container health
docker-compose -f infrastructure/docker/docker-compose.yml ps
```

### Access Points
- **Frontend Dashboard**: [http://localhost:3000](http://localhost:3000)
- **Frontend Health Proxy**: [http://localhost:3000/api/health](http://localhost:3000/api/health)
- **Direct Backend Health**: [http://localhost:4000/api/health](http://localhost:4000/api/health)

### Running Automated Integration Tests
Run the comprehensive integration and failure test suite locally:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-phase5-integration.ps1
```

---

## 5. Environment Variables Reference

| Variable | Description | Default (Local) | Production Example |
|---|---|---|---|
| `NODE_ENV` | Application runtime environment | `production` | `production` |
| `PORT` | Backend HTTP listening port | `4000` | `4000` |
| `POSTGRES_USER` | PostgreSQL superuser username | `stockwatch` | `stockwatch` |
| `POSTGRES_PASSWORD` | PostgreSQL superuser password | `stockwatch_secret` | *(32-char hex random)* |
| `POSTGRES_DB` | PostgreSQL primary database name | `stockwatch` | `stockwatch` |
| `DATABASE_URL` | Prisma PostgreSQL connection URI | `postgresql://stockwatch:...` | `postgresql://...` |
| `REDIS_HOST` | Redis hostname | `redis` | `redis` |
| `REDIS_PORT` | Redis TCP port | `6379` | `6379` |
| `REDIS_PASSWORD` | Redis authentication password | *none* | *(32-char hex random)* |
| `BACKEND_INTERNAL_URL` | Frontend-to-backend internal URI | `http://backend:4000` | `http://backend:4000` |
| `WORKER_SIMULATE_FAILURE` | Controlled failure testing flag | `false` | `false` |
| `IMAGE_TAG` | Immutable commit SHA image tag | `local` | `91e904ad8b34...` |

---

## 6. Background Workflow & Low-Stock Rules

1. **Inventory Low-Stock Condition**: An inventory item is classified as `LOW_STOCK` strictly when:
   $$\text{quantity} \le \text{minQuantity}$$
   Otherwise, its status is `HEALTHY`.
2. **Triggering a Stock Check**: A client sends `POST /api/stock-checks`. The backend creates a `StockCheck` record in PostgreSQL with status `PENDING`, pushes a job into the `stock-check` queue on Redis, and returns immediately with the record ID and `jobId`.
3. **Worker Processing**:
   - Updates status to `PROCESSING` and timestamps `startedAt`.
   - Iterates through all inventory items in the database.
   - For every low-stock item, performs an idempotent `upsert` into the `StockAlert` table matching on `[stockCheckId, inventoryItemId]`.
   - Computes `totalChecked` and `lowStockCount`.
   - Transitions status to `COMPLETED` and timestamps `completedAt`.
4. **Failure Simulation**:
   - When `WORKER_SIMULATE_FAILURE=true` is set, the worker catches the job, transitions the `StockCheck` state to `FAILED`, persists the error string (`Simulated worker processing failure for demonstration purposes`), and re-throws to allow BullMQ retry tracking.

---

## 7. CI/CD & Cloud Deployment

### GitHub Actions Pipeline (`.github/workflows/deploy.yml`)
The pipeline runs on every pull request and push to `main`:
1. **Validate**: Installs dependencies with `pnpm install --frozen-lockfile`, runs `pnpm typecheck`, executes all Jest test suites (`pnpm test`), and verifies production builds.
2. **Build & Push (GHCR)**: Builds multi-stage images for frontend, backend, and worker; tags each with the immutable `${{ github.sha }}` and `latest`; pushes to `ghcr.io/pranavamrutkar9/stockwatch-*`.
3. **Deploy (SSH)**: Connects to the cloud VM over SSH, fetches the latest revision, exports the SHA tag, runs `infrastructure/deployment/deploy.sh`, and validates the live `/api/health` endpoint.

### Automated Rollback Procedure
If a newly deployed image fails health checks during deployment, `infrastructure/deployment/rollback.sh` triggers automatically:
1. Reads previous verified tag from `.previous_tag`.
2. Pulls and redeploys the previous image SHA tags via Docker Compose.
3. Verifies health of the restored containers.

---

## 8. Verification & Test Results

- **Unit Tests**: 16/16 passed across backend and worker (`pnpm test`).
- **Type Checking**: 0 errors across monorepo (`tsc --noEmit`).
- **Container Health**: All 5 services (`frontend`, `backend`, `worker`, `postgres`, `redis`) report `healthy`.
- **Database Persistence**: Data remains completely intact across container restarts.
- **Worker Idempotency**: Verified no duplicate alerts on job retries.
- **Simulated Failure**: Successfully transitions to `FAILED` with persisted error description in PostgreSQL and UI.
