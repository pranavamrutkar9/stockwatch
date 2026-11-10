# StockWatch — Disaster Recovery Design (Phase 3)

**Status:** DESIGN — nothing in this document has been provisioned or tested unless explicitly marked VERIFIED.
**Date:** 2026-11-10. **Author context:** produced on the primary EC2 host without AWS API access (see `docs/aws/iam-access-requirements.md`). Every AWS fact marked *(verify)* must be confirmed with read-only discovery before implementation. Unit prices in §9 come from the public AWS Price List offer files (publication 2026-10-29) unless marked *(unverified)*.

## 1. Current state (facts)

| Component | State | Evidence |
|---|---|---|
| App host | EC2 `i-07590867e7e49c18b`, c7i-flex.large, ap-southeast-2a, public IPv4 present (auto-assigned or EIP? *(verify)*) | IMDS, VERIFIED |
| Containers | frontend (port 80), backend, worker, Redis, legacy local postgres; Compose project `docker` | VERIFIED |
| Database | RDS PostgreSQL 16.15 `stockwatch-primary-db`, db.t4g.micro, Single-AZ, private, TLS strictly verified, backup retention 1 day *(verify)*, encryption *(verify)* | TLS + version VERIFIED from host |
| App DB identity | application connects as the **RDS master user** `stockwatch_admin` | VERIFIED (error text) |
| Redis | `redis:7.4.12` container, AOF `appendfsync everysec`, `noeviction`, named volume `stockwatch_redis_data` on the root EBS volume | VERIFIED |
| Queue semantics | BullMQ; PostgreSQL `stock_checks` is the source of truth; alerts written with idempotent `upsert` on `(stockCheckId, inventoryItemId)` | VERIFIED (code) |
| Exposure | only 22 and 80 listening publicly; no TLS on port 80 | VERIFIED (`ss`) |
| DNS | no domain / hosted zone known | *(verify)* |

## 2. Findings that shape the design

1. **Credentials are a single point of failure.** Today's outage was a master-password change under running containers. If the master password is Secrets Manager–managed with rotation, it will recur on every rotation. **Design decision:** the application must use a dedicated, least-privilege DB role (`stockwatch_app`) whose password is owned by us, not the RDS master secret. Roles replicate with physical replication and are included in snapshots/PITR, so the same credentials work on a promoted replica or restored instance — this simplifies every DR path.
2. **BullMQ job-ID collision after Redis loss (DR blocker).** `stock_checks.jobId` is `UNIQUE`, and the backend stores BullMQ's auto-increment ID (`bull:stock-check:id`, currently 6). After Redis is restored from an older backup or started empty (any regional failover), IDs restart and collide: the `update` violates the unique constraint → API 500 → the check is marked `FAILED` while its job is already queued. **Fix (Phase 4, small code change):** enqueue with `jobId = stockCheck.id` (BullMQ custom job ID). This also gives free de-duplication for queue reconstruction.
3. **Queue is reconstructible from PostgreSQL.** Because job processing is idempotent (VERIFIED: upsert + unit test), any `PENDING`/`PROCESSING` stock check older than a threshold can be safely re-enqueued with `jobId = id`. With finding 2 fixed, **Redis loss costs zero accepted work** — Redis does not need cross-region replication.
4. **`deploy.sh` hard-codes the primary RDS hostname and Sydney CA bundle.** Failover to a promoted replica/restored instance needs `RDS_EXPECTED_HOST` and `RDS_CA_BUNDLE` parameters (Melbourne/Singapore have their own regional bundles).
5. **Redis healthcheck could not detect auth failure** — fixed in `3691918`.
6. **Worker start depends on backend health** (`depends_on: service_healthy`): during a DB outage a recreated worker will not start. Acceptable (worker is useless without DB) but documented.
7. **Public entry point has no stable address guarantee** unless an Elastic IP is attached *(verify)* — DNS failover requires stable primary/secondary addresses.

## 3. Targets (proposed, to be measured in Phase 5)

| Scenario | Mechanism | RPO target | RTO target |
|---|---|---|---|
| Container crash / app failure | restart policy, `deploy.sh`/`rollback.sh` | 0 | ≤ 2 min |
| Redis container/data loss | AOF on volume; else empty Redis + reconciliation | 0 accepted checks (≤ 1 s queue state) | ≤ 5 min |
| Bad data / logical corruption | RDS PITR to new instance in-region | ≤ 5 min | ≤ 45 min |
| Primary DB instance loss (AZ) | PITR (Single-AZ) — or Multi-AZ if approved | ≤ 5 min | ≤ 45 min (Multi-AZ: 1–2 min) |
| Primary region/environment loss | cross-region recovery + Route 53 failover | Option B: < 1 min · Option A: ≤ 15 min *(measure)* | Option B: ≤ 20 min · Option A: ≤ 60 min |

Targets are **not** claims; Phase 5 records measured values beside them.

## 4. Cross-region database options

| | A. Cross-region automated backup replication (pilot light) | B. Cross-region read replica (warm standby) | C. Manual snapshot copy (scheduled) |
|---|---|---|---|
| How | RDS replicates snapshots + transaction logs to DR region; PITR there on demand | async physical replica in DR region; promote on failover | cron copies snapshot cross-region |
| RPO | minutes (log shipping lag) *(measure)* | seconds (replica lag) | hours (snapshot interval) |
| RTO | restore (~15–30 min for 20 GB) + app start | promotion (~2–5 min) + app start | restore + app start |
| Steady cost | backup storage $0.095/GB-mo in Melbourne (≤ 20 GB) + transfer: **~$1–3/mo** | db.t4g.micro $0.025/h + 20 GB × $0.138: **~$21/mo** + transfer | storage + transfer: ~$1–3/mo |
| Failback | restore back / reverse replication | create reverse replica, planned switchover (RPO 0) | restore back |
| Prereqs | region pair supported (`DescribeSourceRegions`), KMS key in DR region if encrypted, retention ≥ 1 | automated backups on source; KMS key in DR region if encrypted | snapshot copy permissions |
| Complexity | low | medium (replica lifecycle, promotion breaks replication) | low, but poor RPO |

**Recommendation:** **B (read replica)** for the assessment demonstration — it delivers the strongest measurable RPO/RTO and a real promotion/failback exercise, and its cost over a few days is negligible (~$0.70/day). Document **A** as the cost-optimised steady-state alternative and implement it too if approved (it is one API call and independently tests PITR in the DR region). C is rejected (RPO too weak).

In-region, independent of the choice: raise automated backup retention **1 → 7 days** (no downtime for a non-zero → non-zero change; backup storage up to the provisioned size is free) and **test PITR** to a temporary instance `stockwatch-pitr-test`, validating row counts and deterministic table hashes, then delete it.

**Multi-AZ** for the primary (db.t4g.micro $0.051/h vs $0.025/h: **+~$22/mo** incl. storage) is the correct answer for AZ failure, but it is optional for this assessment; recommended for real production.

## 4a. Melbourne (ap-southeast-4) compatibility verification

Verified 2026-11-10 without AWS credentials, from AWS public sources. Items still requiring account-level API verification are listed separately and **block provisioning**.

| Requirement | Result | Source |
|---|---|---|
| db.t4g.micro RDS for PostgreSQL offered in Melbourne | **VERIFIED** — Single-AZ $0.025/h, Multi-AZ $0.051/h (identical to Sydney) | AWS Price List `AmazonRDS/current/ap-southeast-4` |
| gp2/gp3 RDS storage in Melbourne | **VERIFIED** — $0.138/GB-mo (both) | Price List |
| Cross-region automated backup replication Sydney → Melbourne | **VERIFIED (docs)** — Melbourne listed as a supported destination for Asia Pacific (Sydney); "supports backup replication for all currently available versions of RDS for PostgreSQL" | RDS User Guide, *Replicating automated backups to another AWS Region* |
| Cross-region read replicas for RDS for PostgreSQL | **VERIFIED (docs)** — "available in all Regions" for PostgreSQL 10–18 (all available versions); no PostgreSQL Region exceptions listed | RDS User Guide, *Cross-Region read replicas* |
| Regional RDS CA bundle | **VERIFIED** — `ap-southeast-4-bundle.pem` downloaded: 3 roots (RSA2048 G1, ECC384 G1, RSA4096 G1). DR containers must mount this bundle, not the Sydney one. | `truststore.pki.rds.amazonaws.com` |
| x86 EC2 for the DR host | **VERIFIED** — t3.small $0.0264/h; gp3 EBS $0.096/GB-mo. Images are **linux/amd64 only** (VERIFIED via `docker image inspect`; CI sets no `platforms`), so Graviton (t4g, $0.0212/h) would require multi-arch builds. | Price List `AmazonEC2/current/ap-southeast-4` |
| **Melbourne opt-in status** | *(verify — BLOCKER)* Regions launched after 20 March 2019 are disabled by default; Melbourne (2023) is in that class. Enabling a Region is an account-level change (approval). Check: `aws ec2 describe-regions --all-regions --query "Regions[?RegionName=='ap-southeast-4'].OptInStatus"` | AWS general rule; account API |
| PostgreSQL **16.15** minor version available in Melbourne | *(verify — BLOCKER for replica)* A cross-region replica must run a version available in the destination. `aws rds describe-db-engine-versions --engine postgres --engine-version 16.15 --region ap-southeast-4` | account API |
| Source encryption / KMS | *(verify — BLOCKER)* If `StorageEncrypted=true`, a KMS key **in Melbourne** must be specified for the replica / replicated backups (and `PreSignedUrl` when using the raw API). An unencrypted source yields an unencrypted replica. | RDS docs; `DescribeDBInstances` |
| Default retention ≥ 1 day on source | *(verify)* required for replicas and backup replication; last seen 1 day | `DescribeDBInstances` |
| Route 53 health-checker reachability | *(verify)* SG/NACL must allow health-checker ranges on port 80 | `DescribeSecurityGroupRules` |

Documented constraints that shape automation:
- Deleting the source of a PostgreSQL cross-region replica sets the replica to **terminated, not promoted** — promotion must always be explicit (`dr-failover.sh`).
- Cross-region replication data transfer is charged; current dataset is tiny (5/6/7 rows in the three tables), so transfer cost is negligible.
- The replica is created with the **default security group** unless one is specified — Terraform/automation must pass the DR DB security group explicitly.
- Account limits: ≤ 5 cross-region replicas guaranteed per source; 20 cross-region automated backups per account by default.

## 5. Redis recovery design

| Layer | Design |
|---|---|
| Durability on host | keep AOF `everysec` (≤ 1 s loss on crash) on the named volume — VERIFIED survives container recreation (rehearsal) |
| Backups | scheduled `BGSAVE` + tarball of `stockwatch_redis_data` every 15 min; 7-day local retention; upload to S3 in the DR region (requires bucket + scoped IAM; approval) |
| Restore (same host) | stop Redis → restore tarball into volume → start → verify key set and `bull:stock-check:id` → backend/worker reconnect automatically |
| Region failover | **do not restore Redis**; start empty Redis in DR and run reconciliation (re-enqueue `PENDING`/`PROCESSING` checks with `jobId = id`). Requires finding-2 fix. |
| BullMQ behaviour | jobs `active` at crash become *stalled* after the lock expires (~30 s) and are retried (max stalled count 1 by default; job `attempts: 3`); processing is idempotent |
| Managed Redis | ElastiCache single node (~$15–25/mo est.) adds managed patching but no cross-region continuity; Global Datastore requires larger node types (~$100+/mo est.). **Not justified**: PostgreSQL is the source of truth and the queue is reconstructible. |
| Replication | Redis replica in DR region would need encrypted transport across regions — **not justified** for the same reason. |

## 6. Secondary environment and DNS failover

```
                     Route 53 (failover routing, TTL 60)
                 ┌───────────────┴────────────────┐
        PRIMARY record                        SECONDARY record
  health check: GET /api/health           (optionally its own health check)
                 │                                   │
  ap-southeast-2 (Sydney)                    DR region (Melbourne*)
  EC2 + Docker Compose                       EC2 + Docker Compose (same images, pinned SHA)
  frontend → backend → RDS primary  ──async──▶ RDS read replica (promote on failover)
  worker ⇄ Redis (AOF)                       worker ⇄ Redis (empty + reconciliation)
```

\* **DR region: ap-southeast-4 (Melbourne) — selected.** Same jurisdiction for data residency, low latency to Sydney. RDS cross-region support and instance/price availability verified from public sources (§4a); opt-in status, engine minor version and KMS remain to be verified via API.

- **Health check:** HTTP `GET http://<primary>/api/health` (port 80 → frontend → backend → DB + Redis), i.e. an end-to-end check. Interval 30 s, failure threshold 3 → detection ≈ 90 s; + TTL 60 s. The primary security group must allow the Route 53 health-checker ranges on port 80 (it is currently open to the world *(verify)*).
- **Stable addresses:** Elastic IPs for primary and secondary *(approval; attaching an EIP to the primary changes its public IP)*.
- **Domain:** required for real end-user failover. If no domain is available, Route 53 failover can still be demonstrated by creating a hosted zone and querying its authoritative name servers directly (`dig @ns-xxx.awsdns-xx.com stockwatch.<zone>`); end users would not follow it until delegated. **Decision needed from you.**
- **Forced failover** (primary partially up, e.g. DB down but frontend answering): the backend returns 503, which already fails the end-to-end check. For a planned switchover, the automation inverts the primary health check rather than editing records.
- **Split-brain protection:** DNS may fail over automatically, but **DB promotion is never automatic**. `dr-failover.sh` requires an explicit confirmation token, fences the primary app (stop backend/worker if reachable) before promotion, and refuses to run if the replica lag is unknown.

## 7. Terraform design

```
infrastructure/terraform/
  bootstrap/            # S3 state bucket (versioning, SSE, public-access block) — created once
  modules/
    network/            # VPC, public subnet(s), private DB subnets (2 AZs), IGW, routes
    security/           # app SG (80 from world/health checkers, no 22 — use SSM), db SG (5432 from app SG only)
    app_host/           # EC2 (x86: images are amd64-only), IAM instance profile, EIP, user-data: Docker + compose + pinned image SHA + ap-southeast-4 CA bundle
    database_dr/        # mode = "replica" | "pitr_restore" | "none"; KMS key; subnet/parameter groups
    dns_failover/       # health checks + PRIMARY/SECONDARY failover records
  envs/
    dr-secondary/       # the reproducible recovery environment (apply/destroy)
    primary/            # data sources only — reads existing primary; no management of production resources initially
```

- **State:** S3 backend with **native S3 locking** (`use_lockfile = true`, Terraform ≥ 1.10; no DynamoDB table needed), versioning enabled, SSE-S3/KMS, bucket in the DR region so state survives a primary-region outage.
- **Secrets:** never in `.tf`, `tfvars`, or outputs. Runtime secrets live in SSM Parameter Store `SecureString` (replicated by writing to both regions) and are read by the host at boot via its instance role; Terraform only references parameter *names*. RDS passwords for new instances: `manage_master_user_password` or ephemeral resources — not plain variables.
- **Primary resources** are not imported in this assessment (avoids any risk of a plan proposing changes to production). Backup-retention change is executed as a single approved CLI command and documented.
- **Teardown:** `terraform destroy` in `envs/dr-secondary` with `deletion_protection`/`skip_final_snapshot` set explicitly; destroy order documented (DNS → app → DB).

## 8. Failover and failback procedure (automation outline)

Scripts in `infrastructure/deployment/dr/` (bash, `set -Eeuo pipefail`, lock file, timestamps to a log, `--dry-run` default, confirmation token for destructive steps):

| Script | Steps |
|---|---|
| `dr-check-primary.sh` | end-to-end health, DB `SELECT 1`, Redis PING, replica lag |
| `dr-check-secondary.sh` | DR host reachable, images present, replica status/lag, CA bundle, SSM parameters readable |
| `dr-failover.sh` | record T0 → fence primary (best effort) → record replica lag (RPO evidence) → promote replica (or PITR restore) → wait available → write DR `.env` from SSM with new host → `deploy.sh <sha>` with DR host/CA params → reconciliation → verify → confirm Route 53 serves secondary → record T_end |
| `dr-failback.sh` | create replica of promoted DB back in primary region → wait lag ≈ 0 → maintenance: stop DR writers → promote primary-region replica → repoint primary `.env` → deploy → restore primary health check → DNS returns → rebuild DR replica |
| `db-consistency-check.sh` | per-table row counts + deterministic ordered-row hashes, compared between two endpoints |

## 9. Cost summary (Melbourne DR)

Unit prices from the AWS Price List (2026-10-29) unless marked *(unverified)*; monthly = 730 h. Excludes tax and free-tier effects.

| Item | Unit price | Monthly (steady) | Per day |
|---|---|---|---|
| Backup retention 1 → 7 days (Sydney) | free up to provisioned storage | ~$0 | ~$0 |
| PITR test instance (temporary, Sydney) | $0.025/h + storage | — | < $0.70 while running |
| Option B read replica, db.t4g.micro + 20 GB | $0.025/h + $0.138/GB-mo | **$21.01** | $0.69 |
| Option A backup replication (≤ 20 GB) | $0.095/GB-mo + snapshot copy transfer | **$1–3** | negligible |
| DR EC2 t3.small (x86) running | $0.0264/h | **$19.27** | $0.63 |
| DR EBS 20 GB gp3 | $0.096/GB-mo | $1.92 | $0.06 |
| Elastic IPs ×2 | $0.005/h each *(unverified — AmazonVPC price list not checked)* | $7.30 | $0.24 |
| Route 53 zone + 2 health checks | $0.50 zone (verified); $0.50/check for AWS endpoints *(unverified)*, $0.75 non-AWS (verified) | $1.50–2.00 | negligible |
| S3 state + Redis backups | *(unverified)* | < $1 | negligible |
| Primary Multi-AZ (optional) | $0.051/h vs $0.025/h + storage | +$21.74 | +$0.71 |
| **Warm standby (B + DR EC2 running + EIPs + R53 + S3)** | | **≈ $52/mo** | **≈ $1.70/day** |
| **Pilot light (A + primary EIP + R53 + S3, DR EC2 only during tests)** | | **≈ $7–9/mo** | |

A three-day assessment window with full warm standby costs ≈ $5.

## 10. Approvals required (none requested to execute yet)

| # | Action | Cost / risk |
|---|---|---|
| 1 | Production recovery runbook (`docs/runbooks/production-credential-recovery.md`) | ~20 s API restart, ~6 s Redis restart |
| 2 | Read-only IAM role on the EC2 instance | none |
| 3 | RDS backup retention 1 → 7 days | no downtime |
| 4 | Create `stockwatch_app` DB role and switch app to it | DB DDL on production + container recreate |
| 5 | Code fix: `jobId = stockCheck.id` + reconciliation | via normal PR/deploy |
| 6 | PITR test instance (create, validate, delete) | small hourly cost |
| 7 | Enable Melbourne Region if opt-in is required; cross-region replica (B) and/or backup replication (A); KMS key in Melbourne if source is encrypted | see §9 |
| 8 | Terraform state bucket + DR environment apply/destroy | see §9 |
| 9 | Elastic IP for primary (changes public IP) | brief reachability change |
| 10 | Route 53 hosted zone, health checks, failover records; domain decision | ~$2/mo |
| 11 | Operator IAM policy (scoped write permissions) for Phase 4 | security review |
