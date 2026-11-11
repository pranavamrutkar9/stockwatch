# 01 — Executive Summary

StockWatch (inventory monitoring: NestJS API, Next.js frontend, BullMQ worker, Redis, PostgreSQL) runs in **ap-southeast-2** on one EC2 host with **Amazon RDS PostgreSQL 16**. The assessment goal was a demonstrable, measured disaster-recovery capability under a **zero-additional-AWS-spend** constraint.

## What was achieved

| Outcome | Status |
|---|---|
| Root-caused and recovered a production outage (RDS master password reset under running containers; confirmed by RDS event `Reset master credentials` 2026-11-10T17:04:17Z) | **Production verified** |
| Application decoupled from the RDS master credential: runtime `stockwatch_app` (DML only), migrations `stockwatch_migrator` (schema owner); rollout with one failed health probe and no failed inventory request | **Production verified** |
| Health checks that surface real causes, bounded timeouts, worker runtime readiness, Redis auth-aware healthcheck | **Production verified** (release `498e28b`) |
| Queue recovery from PostgreSQL after Redis loss; idempotent at-least-once processing; job ID = stock-check ID | **Code implemented and tested** + **Local simulation verified**; one controlled production job completed correctly |
| Verified, checksum-protected PostgreSQL backups (now taken with the migration role, not the master) | **Isolated restore verified** (production data) |
| Redis backup/restore with key-set verification | **Local simulation verified** |
| Region failover / failback automation (dry-run default, confirmation tokens, billable gate, primary-host guard) | **Code implemented and tested**; **Local simulation verified** (streaming-replica promotion) |
| DNS failover behaviour (health-check-driven record switch, TTL effects) | **Local simulation verified** (CoreDNS) |
| Melbourne recovery environment (Terraform, zero-cost default) | **Code implemented and tested** (offline); **not applied** |
| Least-privilege read-only IAM role with explicit denies | **Production verified** |
| Containers cannot reach instance-role credentials (IMDSv2 required, hop limit 1; setting changed outside the assessment tooling, isolation verified 2026-11-11 08:17 UTC) | **Production verified** |

## Headline measurements (all labelled; see chapter 09)

- Region failover (local Docker simulation, real PostgreSQL streaming replication): **≈ 2.9 s** to a healthy secondary, **0** acknowledged writes lost.
- Planned failback (local simulation): **0.73 s** write unavailability, **0** writes lost.
- Total Redis loss (local simulation): queue rebuilt from PostgreSQL in **≈ 3.5 s**, **0** checks lost.
- Production deployments: **≈ 6.2 s** API interruption (release `498e28b`); role switchover with **one** failed `/api/health` probe (≤ 3.1 s between surrounding successes; inventory and web requests stayed 200).
- These are **not** AWS cross-region measurements; AWS detection (Route 53 ≈ 90–150 s) and RDS promotion times are not included.

## What is not done (chapter 11)

No real Melbourne recovery, no public Route 53 failover, no cross-region replica, Single-AZ RDS with 1-day backup retention, no Elastic IP, CI cannot reach EC2 over SSH, RDS master password rotation pending a human console action, and the RDS master is inherently elevated.
