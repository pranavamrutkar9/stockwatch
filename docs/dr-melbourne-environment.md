# Melbourne (ap-southeast-4) Recovery Environment — Specification and Runbooks

**Status:** DESIGN. Nothing here has been provisioned or executed. AWS facts marked *(verify)* need the read-only role (`docs/aws/iam-policy-review.md`). Commands below are the intended automation steps; each AWS-mutating step is an approval gate.

## 1. Inputs and constraints (verified unless marked)

| Fact | Value | Source |
|---|---|---|
| Primary network | default VPC `vpc-02371e067f7e28e42` (host 172.31.1.61, RDS 172.31.52.172 → **172.31.0.0/16**) | IMDS / TLS probe |
| Primary DB | PostgreSQL 16.15, db.t4g.micro, Single-AZ, TLS verify-full | probe |
| Images | linux/amd64 only (GHCR SHA tags) | `docker image inspect` |
| Melbourne RDS | db.t4g.micro PG offered; Sydney→Melbourne backup replication and cross-region replicas supported | Price List, RDS docs |
| Melbourne CA bundle | `ap-southeast-4-bundle.pem` (3 roots) | RDS truststore |
| Transfer / IPv4 | $0.080/GB Sydney→Melbourne; $0.005/h per public IPv4 | Price List |
| Route 53 health checkers | 31 IPv4 prefixes (`ROUTE53_HEALTHCHECKS`), also available as managed prefix list `com.amazonaws.<region>.route53-healthchecks` | ip-ranges.json (2026-11-10) |
| Melbourne opt-in, PG 16.15 availability, source encryption | *(verify — blockers)* | API |

## 2. Network

| Resource | Value | Notes |
|---|---|---|
| VPC | `10.42.0.0/16` | must not overlap 172.31.0.0/16 (keeps future peering possible) |
| Public subnets | `10.42.0.0/24` (ap-southeast-4a), `10.42.1.0/24` (4b) | app host; IGW route |
| DB subnets | `10.42.10.0/24` (4a), `10.42.11.0/24` (4b) | no internet route; RDS subnet group needs ≥ 2 AZs |
| NAT gateway | none | DB needs no egress; app host has a public IP (saves ~$45/mo) |
| VPC endpoints | none initially | SSM/S3 reached over the internet via the host's public IP |

## 3. Security groups

| SG | Ingress | Egress |
|---|---|---|
| `stockwatch-dr-app` | TCP 80 from 0.0.0.0/0 (public web app, same as primary) | 443 (GHCR, SSM, AWS APIs), 5432 to `stockwatch-dr-db` |
| `stockwatch-dr-db` | TCP 5432 from `stockwatch-dr-app` only | none |

No port 22: administration through SSM Session Manager (instance role needs `AmazonSSMManagedInstanceCore` — operator-policy approval). The replica **must** be created with `stockwatch-dr-db` explicitly; RDS otherwise attaches the default SG.

## 4. Database (Option B: cross-region read replica)

| Setting | Value |
|---|---|
| Identifier | `stockwatch-dr-replica` |
| Source | `arn:aws:rds:ap-southeast-2:<ACCOUNT_ID>:db:stockwatch-primary-db` |
| Class / storage | db.t4g.micro, gp3 20 GiB |
| Subnet group / SG | `stockwatch-dr-db-subnets` / `stockwatch-dr-db` |
| Encryption | if source is encrypted: customer or `aws/rds` KMS key **in ap-southeast-4** *(verify)* |
| Public access | false |
| Deletion protection | true (Terraform must disable explicitly before destroy) |
| After promotion | backup retention 7 days (enables PITR in Melbourne), Multi-AZ optional |
| Credentials | identical to primary (physical replica): `stockwatch_app` / `stockwatch_migrator` once provisioned |

Option A (backup replication, pilot light) uses the same subnet group/SG/KMS, restoring with `restore-db-instance-to-point-in-time --source-db-instance-automated-backups-arn …`.

## 5. Application host

| Setting | Value |
|---|---|
| Instance | t3.small (x86_64; amd64 images), Ubuntu LTS AMI from Canonical's SSM parameter *(verify)*, 20 GiB gp3 encrypted |
| Address | Elastic IP (stable target for the Route 53 SECONDARY record) |
| IMDS | v2 required, hop limit 1 |
| Instance role | `ssm:GetParameter(s)` on `/stockwatch/dr/*`, `kms:Decrypt` via `aws/ssm` (condition `kms:ViaService`), `AmazonSSMManagedInstanceCore` |
| Bootstrap (user-data) | install Docker Engine + Compose plugin; clone repo at a **pinned commit**; download `ap-southeast-4-bundle.pem`; render `.env` from SSM SecureString parameters; pull images by SHA; **do not start backend/worker** until the database is promoted (pilot light). Frontend may run to serve a maintenance response. |
| Redis | local container, empty on start; recovery via PostgreSQL-backed reconciliation (`StockCheckRecoveryService`, implemented and integration-tested) |

### Configuration that differs from the primary

| Variable | Primary | Melbourne |
|---|---|---|
| `DATABASE_URL` host | `stockwatch-primary-db.…ap-southeast-2…` | promoted `stockwatch-dr-replica.…ap-southeast-4…` |
| `sslcert` / mounted CA | `ap-southeast-2-bundle.pem` | `ap-southeast-4-bundle.pem` |
| `deploy.sh` expected host / CA | hard-coded | **must be parameterised** (`RDS_EXPECTED_HOST`, `RDS_CA_BUNDLE`) — Phase 4 code change |
| Redis password | primary `.env` | independent, from SSM |

## 6. DNS (Route 53 failover)

| Record | Routing | Target | Health check |
|---|---|---|---|
| `stockwatch.<zone>` A | Failover PRIMARY | primary EIP | HTTP :80 `/api/health`, interval 30 s, threshold 3, regions ≥ 3 |
| `stockwatch.<zone>` A | Failover SECONDARY | Melbourne EIP | optional (served whenever PRIMARY is unhealthy) |
| TTL | 60 s | | |

Detection ≈ 3 × 30 s = 90 s; client switch ≤ TTL 60 s after Route 53 flips. Domain decision is still open (real delegated domain vs. demonstration by querying the zone's authoritative name servers directly).

## 7. Failover runbook (region / primary environment loss)

`dr-failover.sh` (to be implemented in Phase 4) — every mutating step logs a UTC timestamp to the evidence log; `--dry-run` is the default; `--confirm <token>` required.

| # | Step | Command / check | Gate |
|---|---|---|---|
| 0 | Declare incident, record **T0** | evidence log | human decision |
| 1 | Capture RPO evidence | `aws cloudwatch get-metric-data` → `ReplicaLag` (ap-southeast-4) at T0; replica `StatusInfos` | read-only |
| 2 | Fence primary (best effort) | if reachable: stop primary backend/worker (prevents split-brain writes) | approval |
| 3 | Promote replica | `aws rds promote-read-replica --db-instance-identifier stockwatch-dr-replica --backup-retention-period 7 --region ap-southeast-4`; wait `db-instance-available` | approval (irreversible) |
| 4 | Start app | render `.env` with promoted endpoint + Melbourne CA → `deploy.sh <sha>` (Redis empty) | — |
| 5 | Queue recovery | `StockCheckRecoveryService` re-enqueues PENDING/PROCESSING checks within `STOCK_CHECK_RECOVERY_INTERVAL_MS`; verify with API | automatic |
| 6 | Verify | `/api/health` ok; row counts + table hashes vs. last known primary snapshot; marker row present | read-only |
| 7 | DNS | confirm Route 53 PRIMARY unhealthy → SECONDARY served (`dig @<zone NS>`); force via health-check inversion if primary is partially up | approval if forced |
| 8 | Record **T_restored** | RTO = T_restored − T0; RPO = writes after the last replicated LSN (marker-row method below) | — |

## 8. Failback runbook (planned, RPO 0)

1. Create `stockwatch-primary-db-v2` as a cross-region replica of the promoted Melbourne DB in ap-southeast-2 (Sydney CA, primary SG, subnet group).
2. Wait until `ReplicaLag` ≈ 0.
3. Maintenance window: stop Melbourne backend/worker (no writes) → confirm lag 0 → promote `stockwatch-primary-db-v2`.
4. Point primary `.env` / `deploy.sh` expected host at `stockwatch-primary-db-v2` → `deploy.sh <sha>`.
5. Restore the primary health check; Route 53 returns traffic to PRIMARY.
6. Re-create `stockwatch-dr-replica` from the new primary; keep the old primary instance (deletion protection) until the new one is verified, then retire it (approval).

## 9. RPO/RTO measurement method (Phase 5)

- **Marker row:** immediately before failure injection, write a timestamped marker through the normal API (e.g. a dedicated inventory item `DR-MARKER-<ts>`) — *a production write; requires approval*. RPO = 0 if the marker exists in the promoted DB, otherwise the gap between the last marker found and T0.
- **Replica lag:** `ReplicaLag` metric at T0 (seconds) as the upper bound for RPO.
- **Timestamps:** T0 (injection), T_detect (Route 53 health check unhealthy / alarm), T_promote_start/end, T_app_healthy, T_dns (resolver returns Melbourne EIP), T_restored. Each from command output, not estimates.
- **Consistency:** per-table row counts + deterministic ordered-row SHA-256 between the promoted DB and a pre-failure export.

## 9a. Discovery update (2026-11-11, read-only role)

- Melbourne is **not enabled** on the account (`not-opted-in`) — enabling it is a free, account-level change requiring approval.
- The primary is encrypted with AWS-managed `alias/aws/rds` (single-Region key): the replica needs `kms_key_arn` set to a key in ap-southeast-4.
- The primary has **no Elastic IP** (auto-assigned public IPv4 changes on stop/start); the app host is in a public subnet of the default VPC with an unencrypted 25 GiB root volume.
- Master credentials are not Secrets Manager–managed; the 2026-11-10 outage was a manual `Reset master credentials` at 17:04:17Z.

## 10. Remaining blockers before provisioning

1. Read-only IAM role (approval pending) → verify opt-in status, PG 16.15 availability, encryption/KMS, primary SG rules, EIP.
2. Enable ap-southeast-4 if it is not enabled (account-level change).
3. Domain / hosted-zone decision.
4. Operator IAM policy (scoped write permissions) for Phase 4.
5. Code: parameterise `deploy.sh` RDS host and CA bundle.
6. Production rollout of `stockwatch_app` / `stockwatch_migrator` (so the replica inherits least-privilege credentials).
