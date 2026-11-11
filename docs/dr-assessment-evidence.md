# StockWatch DR / Business Continuity — Assessment Evidence

Last updated: 2026-11-11. Constraint throughout: **zero additional AWS spend** (no AWS resource created or modified by this work).

Every item below is in exactly one category:

- **[A] Implemented and tested in isolation** — throwaway Docker infrastructure on the primary host, or stubs.
- **[B] Implemented and verified in production** — observed on the live Sydney environment.
- **[C] Designed but not demonstrated in AWS** — code/IaC/runbooks exist; nothing provisioned.

No live Melbourne recovery and no public global DNS failover have been performed.

## 1. Architecture

```
                           users (HTTP :80)
                                 │   (no domain; public IPv4 auto-assigned, no EIP)
 ap-southeast-2 (Sydney) ────────┼───────────────────────────────────────────────── PRIMARY [B]
  EC2 i-07590867e7e49c18b (c7i-flex.large, default VPC 172.31.0.0/16, SG launch-wizard-1)
   ├─ frontend (Next.js, :80 → /api proxy)
   ├─ backend  (NestJS; BullMQ producer; /api/health; PostgreSQL-backed queue recovery*)
   ├─ worker   (BullMQ consumer; runtime readiness probe*)
   ├─ redis    (AOF everysec, password, volume stockwatch_redis_data)
   └─ (legacy local postgres, preserved, unused)
  RDS stockwatch-primary-db (PG 16.15, db.t4g.micro, Single-AZ, encrypted aws/rds,
      private, SG stockwatch-rds-sg: 5432 from app SG only, backups 1 day)
  Route 53 private zone stockwatch-hz (NS/SOA only, Sydney VPC)
                                 ┆
 ap-southeast-4 (Melbourne) ─────┆──────────────────────────────────────────────── DESIGNED [C]
  NOT ENABLED on the account. Terraform (zero-cost default): VPC 10.42.0.0/16, public +
  DB subnets, SGs, DB subnet/parameter groups; optional (billable, gated) t3.small + EIP,
  cross-region read replica (KMS key in ap-southeast-4) or PITR restore.
  * deployed once the PR is merged (see §8)
```

## 2. IAM [B]

- Approved policy v1.0 (`docs/aws/iam-readonly-discovery-policy.json`, 65 Allow + 13 explicit Deny) attached as `stockwatch-dr-readonly-discovery`; verified with `sts get-caller-identity`.
- A broader default role (`AWSEC2RoleforDefaultAWSServiceAccess`, 19 managed policies incl. several FullAccess) was found attached first; work stopped, reported, and the user replaced it.
- Positive and negative tests: `docs/aws/discovery-2026-11-11.md` (explicit deny verified for secret values, SSM parameters, user-data, console output; writes and other regions denied; KMS decrypt inconclusive at API level, deny present in policy).
- Open recommendation: IMDS hop limit 1 (containers can currently obtain instance credentials).

## 3. Database role separation

| Item | Category | Evidence |
|---|---|---|
| `stockwatch_app` (DML only) / `stockwatch_migrator` (owner) / RDS master (elevated; direct data access via AWS-managed `rds_superuser`, see `docs/database-roles.md` correction) | [A] | `scripts/test-integration.sh` 35/35 (privilege boundary, ownership transfer, rotation) |
| Plan against a copy of production data | [A] (source read-only) | `scripts/rehearse-db-roles-on-copy.sh` 19/19; live catalog facts recorded in `docs/database-roles.md` |
| Applied in production | **not done** — requires explicit approval (`docs/database-roles.md` rollout plan) | — |

## 4. Backup and restore

| Item | Category | Evidence |
|---|---|---|
| Verified logical backup of production (snapshot-consistent dump + manifest + isolated restore) | [B] read-only | `~/stockwatch-backups/postgres/20261110T215542Z` (checksum OK, VERIFIED, 5/7/6 rows) |
| Restore into empty target, tamper/token/non-empty refusals | [A] | `scripts/test-backup-restore.sh` 16/16 |
| Redis backup/restore (key set + job counter) | [A]; production Redis backup during the 2026-11-10 recovery was [B] | same suite; `docs/dr-progress-log.md` |
| RDS automated backups | [B] observed | retention 1 day, PITR window since 2026-11-10T07:48Z, 2 automated snapshots |
| RDS PITR restore test | [C] | would create a billable instance |

## 5. Queue recovery and idempotency [A]

Job ID = stock-check ID; `StockCheckRecoveryService` re-enqueues PENDING/PROCESSING checks whose job is missing; processor safe under redelivery and concurrent delivery. Evidence: unit 45/45; integration backend 7/7 + worker 9/9 as `stockwatch_app` (forced transaction interleavings, SIGKILL recovery); mutation runs show the tests fail on the old code.

## 6. Local DNS failover simulation (Option C) [A] — LOCAL, not Route 53

`scripts/dns-failover-sim.sh` (CoreDNS `hosts` plugin reload 1 s, TTL 5 s; controller 1 s interval, 3 failures / 3 successes). 3 rounds, evidence `~/stockwatch-dr-evidence/dns-sim-1794361622/`:

| Metric (ms from injection, median of 3) | Failover | Failback |
|---|---|---|
| Failure / recovery detected | 5394 | 3262 |
| DNS record updated | 5394 | 3262 |
| Client resolves new endpoint | 10256 | 5019 |
| Client served by new region | 10257 | 5020 |
| Client error window | 9015 | 0 |

Interpretation: detection = 3 probes × (1 s timeout + 1 s interval); client switch = detection + reload (≤ 1 s) + TTL cache (≤ 5 s). Route 53 equivalents (30 s × 3, TTL 60 s) would give roughly 90–150 s; the private zone cannot provide public failover (`docs/dns-route53-analysis.md` §4).

## 7. Application-level failover/failback (Option D)

| Requirement | Category | Evidence |
|---|---|---|
| Regional target files (`targets/primary.env`, `targets/melbourne.env`), Sydney primary, Melbourne placeholders refused | [A] | `scripts/test-deploy-scripts.sh` 31/31 |
| Failover selects secondary DB + app endpoint; pinned SHA; `.env` re-hosted, mode 600 | [A] stub AWS | `scripts/test-dr-automation.sh` 25/25 |
| Refuses execution on the Sydney host | [A] + **real host check** | test suite, and on 2026-11-11 a real `--execute` on the primary aborted before any AWS call (`.env` untouched) |
| Dry-run default, dated confirmation, billable gate, lag gate, idempotent promotion | [A] | test suite |
| Real-AWS dry run | [B] read-only | aborts: replica not found/not accessible in ap-southeast-4 |
| End-to-end promotion, app start, queue reconstruction, failback | [A] | `scripts/dr-simulate.sh` S5/S6 (below) |
| Live Melbourne failover | [C] | — |

## 8. RTO / RPO measurements

All [A] (isolated Docker on one host, monotonic clock, marker writer every ~100 ms; RPO = acknowledged writes missing). Run `sim-1794358922`, `docs/dr-simulation-results.md`:

| Scenario | RTO (ms) | RPO |
|---|---|---|
| S1 app process crash | 1 170 | 0 / 40 |
| S2 DB connectivity lost 15 s | +100 after DB back | 0 / 51 |
| S3 Redis destroyed, 10 queued checks | 3 470 to rebuild queue | 0 checks lost |
| S4 worker SIGKILL, 30 queued | 60 680 (BullMQ lock expiry) | 0 |
| S5 region failover (promote standby + secondary app) | 2 870 (+ ~90–150 s detection with Route 53) | 0 / 812 |
| S6 planned failback | 4 380 end-to-end; 730 write unavailability | 0 / 845 |
| S7 DB destroyed → restore from backup | 6 100 | 28 lost = all writes after the backup (RPO = backup age) |
| DNS failover (local CoreDNS) | 10 257 client switch | n/a |

Not measured anywhere: RDS promotion time, real cross-region replication lag, Route 53 propagation, cold DR host boot.

## 9. Production deployment evidence [B]

- 2026-11-10 incident recovery (stale RDS credentials + Redis password rotation): `docs/runbooks/production-credential-recovery.md`, `docs/dr-progress-log.md`.
- PR merge and CI deployment of this branch: **pending** (to be recorded after merge, with workflow result, post-deploy validation and the single controlled stock-check job).

## 10. Remaining limitations

1. Melbourne not enabled; no replica, DR host or cross-region backups exist (billable / account change).
2. Public global DNS failover impossible without a public hosted zone and domain (Route 53 Domains unavailable on this free-plan account).
3. RDS backup retention 1 day; PITR not exercised on RDS.
4. Production runtime still uses the RDS master user until the role rollout is approved.
5. Single-AZ RDS; app host has no Elastic IP; unencrypted root volume; IMDS hop limit 2.
