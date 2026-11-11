# 02 — System Architecture

```mermaid
flowchart LR
  user([Users / HTTP :80]) --> fe
  subgraph EC2["EC2 i-07590867e7e49c18b — ap-southeast-2a (Docker Compose project 'docker')"]
    fe["frontend<br/>Next.js 15 (:3000→80)<br/>/api/* proxy"] --> be["backend<br/>NestJS 10 (:4000)<br/>BullMQ producer<br/>StockCheckRecoveryService"]
    be --> rd[("redis 7<br/>AOF everysec, auth<br/>volume stockwatch_redis_data")]
    wk["worker<br/>BullMQ consumer<br/>runtime readiness probe"] --> rd
  end
  subgraph RDS["RDS stockwatch-primary-db — PostgreSQL 16.15, db.t4g.micro, Single-AZ, encrypted, private"]
    db[("database stockwatch")]
  end
  be -- "TLS verify (Sydney CA)<br/>stockwatch_app" --> db
  wk -- "TLS verify<br/>stockwatch_app" --> db
  mig["deploy.sh migrations<br/>(one-off container)"] -- "stockwatch_migrator" --> db
  adm["operator (hidden prompt)"] -. "stockwatch_admin<br/>admin only" .-> db
  subgraph MEL["ap-southeast-4 Melbourne — DESIGNED, NOT PROVISIONED (region not enabled)"]
    tf["Terraform: VPC 10.42.0.0/16, SGs, DB subnet/param groups<br/>(billable host/replica gated by allow_billable)"]
  end
  db -. "cross-region replica / backup replication<br/>(not created — cost)" .-> tf
```

## Components

| Component | Role | Recovery-relevant behaviour |
|---|---|---|
| frontend | UI + `/api/*` proxy | container health = end-to-end backend health |
| backend | REST API, enqueues stock checks | `/api/health` (DB + Redis, 3 s timeouts); enqueue persists PENDING row first, then job with **jobId = stock-check id**; `StockCheckRecoveryService` re-enqueues PENDING/PROCESSING checks whose job is missing (60 s interval, 120 s grace) |
| worker | processes jobs | runtime readiness re-checks Redis + DB every 30 s; COMPLETED checks are never recomputed; alerts + COMPLETED committed atomically with `ON CONFLICT DO NOTHING` |
| redis | BullMQ queue | AOF `everysec`; healthcheck requires `PONG` (detects wrong password) |
| RDS | source of truth | private, SG allows 5432 only from the app SG, TLS verify-full |

## Data flow (stock check)

`POST /api/stock-checks` → backend inserts `stock_checks` (PENDING, `jobId = id`) → BullMQ job `id` → worker marks PROCESSING → reads inventory, inserts alerts for low-stock items, marks COMPLETED in one transaction → API returns the record. Production example: job `825a658d-a649-49f4-b70a-231ef3968ddb` (2026-11-11 02:51:03Z, 5 items, 1 alert, completed in 49 ms).

## Database roles

| Account | Use |
|---|---|
| `stockwatch_app` | backend + worker: SELECT/INSERT/UPDATE/DELETE only |
| `stockwatch_migrator` | schema owner; `deploy.sh` migrations; logical backups (run manually) |
| `stockwatch_admin` | RDS master (`rds_superuser`): administrators only |

Details: [04](04-security-and-iam.md), [`docs/database-roles.md`](../database-roles.md).

## Recovery architecture

Primary-environment recovery uses Docker restart policies, `deploy.sh`/`rollback.sh` (target profiles, automatic rollback), verified backups and PostgreSQL-backed queue reconstruction. Regional recovery is designed (Terraform + `dr-failover.sh`/`dr-failback.sh`) and exercised end-to-end only in local simulation — see [07](07-failover-and-failback.md).
