# StockWatch — DR / Business Continuity Assessment

Start here. Each chapter summarises one area and links to the detailed evidence and runbooks.

| # | Chapter |
|---|---|
| 01 | [Executive summary](01-executive-summary.md) |
| 02 | [System architecture](02-system-architecture.md) |
| 03 | [AWS infrastructure](03-aws-infrastructure.md) |
| 04 | [Security and IAM](04-security-and-iam.md) |
| 05 | [Database backup and recovery](05-database-backup-and-recovery.md) |
| 06 | [Redis and queue recovery](06-redis-and-queue-recovery.md) |
| 07 | [Failover and failback](07-failover-and-failback.md) |
| 08 | [DNS failover simulation](08-dns-failover-simulation.md) |
| 09 | [RTO / RPO measurements](09-rto-rpo-measurements.md) |
| 10 | [Test evidence index](10-test-evidence.md) |
| 11 | [Known limitations](11-known-limitations.md) |
| 12 | [Video demonstration runbook (local DR simulation)](12-video-demonstration-runbook.md) |
| 13 | [Video script](13-video-script.md) |

## Evidence classification used throughout

| Label | Meaning |
|---|---|
| **Production verified** | Observed on the live Sydney environment (EC2 `i-07590867e7e49c18b`, RDS `stockwatch-primary-db`) |
| **Isolated restore verified** | Real production data restored into a disposable PostgreSQL and compared by checksums |
| **Local simulation verified** | Docker containers on the primary host standing in for regions/services; real software, simulated topology |
| **Code implemented and tested** | Unit/integration/behavioural tests (stubs, mock providers) — no AWS changes |
| **Blocked by authorization** | Ready, but needs a human with an authorized AWS session |
| **Not implemented / not demonstrated** | Designed or out of scope; never claimed as working |

Hard constraint for the whole project: **zero additional AWS spend** — no AWS resource was created.
