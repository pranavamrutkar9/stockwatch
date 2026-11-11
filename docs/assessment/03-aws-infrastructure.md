# 03 — AWS Infrastructure

Source: read-only discovery with the approved IAM role, 2026-11-11 ([`docs/aws/discovery-2026-11-11.md`](../aws/discovery-2026-11-11.md)). Account ID intentionally omitted.

## Primary — ap-southeast-2 (Production verified)

| Resource | Configuration |
|---|---|
| EC2 `i-07590867e7e49c18b` | c7i-flex.large, ap-southeast-2a, default VPC public subnet, **auto-assigned public IPv4 (no Elastic IP)**, IMDSv2 required, hop limit **1** (changed from 2 on 2026-11-11; containers verified unable to reach instance credentials), root gp3 25 GiB unencrypted, instance role `stockwatch-dr-readonly-discovery` |
| VPC `vpc-02371e067f7e28e42` | default VPC 172.31.0.0/16; private DB subnets 172.31.48.0/20 (2a), 172.31.64.0/20 (2b) |
| App SG `launch-wizard-1` | in: 80 from 0.0.0.0/0, 22 from one operator /32 |
| DB SG `stockwatch-rds-sg` | in: 5432 only from the app SG |
| RDS `stockwatch-primary-db` | PostgreSQL 16.15, db.t4g.micro, **Single-AZ**, 20 GiB gp2, encrypted (`alias/aws/rds`), not public, deletion protection, CA `rds-ca-rsa2048-g1`, **backup retention 1 day** (PITR window ≈ last 24 h, 2 automated snapshots observed), master credentials **not** Secrets-Manager-managed |
| Route 53 | one **private** hosted zone `stockwatch-hz` (NS/SOA only, Sydney VPC), no health checks, no registered domain (Route 53 Domains unavailable on this free-plan account) |
| GHCR | images per commit SHA (production release `498e28b`) |

## Secondary — ap-southeast-4 Melbourne (Not implemented)

Region status: **not opted in** (all API calls fail). Public sources confirm db.t4g.micro PostgreSQL availability, Sydney→Melbourne backup replication and cross-region replicas ([`docs/disaster-recovery-design.md`](../disaster-recovery-design.md) §4a). Terraform for the environment exists ([`infrastructure/terraform`](../../infrastructure/terraform)) with a zero-cost default and a `cost_guard` that refuses billable resources unless `allow_billable = true`; it has never been planned or applied against AWS. Because the primary is encrypted with a single-region key, a Melbourne replica would need a KMS key in ap-southeast-4.

## Cost

Additional AWS spend from this work: **$0**. Estimated costs for the designed DR options (Price List): warm standby ≈ $52/month, pilot light ≈ $7–9/month ([`docs/disaster-recovery-design.md`](../disaster-recovery-design.md) §9).
