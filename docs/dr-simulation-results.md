# DR Simulation Results (isolated, simulated)

**Run:** 2026-11-11T01:04:55Z on the primary EC2 host, isolated Docker network `sw-sim-1794358922-net` (removed after the run).
**Nature of results:** SIMULATED on a single host with Docker containers standing in for regions.
They measure the application, queue and database-recovery mechanics and the automation, NOT AWS cross-region
behaviour (RDS promotion time, cross-region replication lag, Route 53 propagation). No AWS resources were used.

**Workload during scenarios:** marker writer creating an inventory item every ~100 ms via the API;
RPO counts **acknowledged** (HTTP 201) writes missing after recovery. Times are milliseconds from failure injection.

| ID | Failure injected | Recovery mechanism | Detection (ms) | Restoration (ms) | Data (RPO) | Kind |
|---|---|---|---|---|---|---|
| S1 | App process crash (backend SIGKILL) | Docker restart policy | 230 | 1170 | acked=40 missing=0 | simulated |
| S2 | DB connectivity lost 15 s | automatic reconnect (Prisma pool) | 2100 | 17210 (recovery 100 after restore) | acked=51 missing=0 | simulated |
| S3 | Redis destroyed (no backup used) with 10 PENDING checks | empty Redis + PostgreSQL-backed recovery | 2170 | queue restored 3470 after Redis back; total 5830 | lost checks=0, completed=11, duplicate alerts=0 | simulated |
| S4 | Worker SIGKILL with 30 queued checks (down 5 s) | restart + BullMQ stalled-job recovery | n/a (injected) | all drained 60680 after restart; total 65820 | non-terminal=0, alert/lowStockCount mismatches=0 | simulated |
| S5 | Primary region lost (DB, app, Redis destroyed) | dr-failover.sh: promote standby, start secondary app, empty Redis + recovery | 310 (simulated; +~90 s with Route 53) | 2870; queue drained 5050 | acked=812 missing=0; standby at T0: streaming, 0 bytes behind primary | simulated |
| S6 | Planned failback to primary region | dr-failback.sh: reseed, lag 0, stop writers, promote, start primary app | n/a (planned) | 4380 end-to-end; write unavailability (writers stopped -> promoted) 730 | acked=845 missing=0 | simulated |
| S7 | Primary DB destroyed | restore verified logical backup into new instance, re-provision roles, restart app | 270 | 6100 | acked=874 missing=28 (first missing seq 1037, last 1064); expected loss = 27 writes acknowledged after the backup; RPO window = backup age at failure 3190 ms | simulated |

## Not represented

- RDS cross-region replica promotion time (minutes) and real replication lag; Route 53 health-check detection (~90 s) and TTL (60 s).
- EC2 boot / image pull time for a cold DR host.
- S1 relies on Docker's restart policy; production containers use `restart: unless-stopped` (same mechanism).

## Interpretation (added after review of the run)

- **Timing method:** durations use the kernel monotonic clock (`/proc/uptime`, 10 ms resolution). An earlier run used wall-clock time and produced impossible values (negative detection, restoration shorter than the injected outage); those numbers were discarded.
- **S1** — the restart policy alone restores service in about 1.2 s; no acknowledged write was lost (writes during the outage were rejected, not lost).
- **S2** — detection varies between runs (110 ms–2.1 s), depending on when the next health probe opens a new database connection. Recovery after the database returns took about 100 ms. No acknowledged writes were lost.
- **S3** — Redis was destroyed **without** using a backup. All 10 queued checks completed through PostgreSQL-backed reconciliation (`StockCheckRecoveryService`, 3 s interval in the simulation; production defaults are 60 s interval / 120 s grace, so expect minutes there). No duplicate alerts.
- **S4** — about 60 s to drain is BullMQ's documented behaviour for **SIGKILLed** workers: active jobs keep their lock until `lockDuration` (30 s) expires and the stalled-job checker (`stalledInterval`, 30 s) re-queues them. A graceful stop (SIGTERM, as `docker stop` sends) avoids this. Every check reached a terminal state and alert counts matched `lowStockCount` for every check.
- **S5** — the standby was streaming and 0 bytes behind the primary at T0 (measured on the primary via `pg_stat_replication`). Promotion through `dr-failover.sh` plus the secondary app start took 2.9 s. 812 acknowledged writes were checked and **none were missing**. Detection is instantaneous only because the simulation injects the failure; with Route 53 (30 s × 3) plus a 60 s TTL, add about 90–150 s.
- **S6** — planned failback with RPO 0 (no acknowledged write missing); writes were unavailable for 730 ms.
- **S7** — restore from the verified logical backup: **every write acknowledged after the backup was lost (28)**, and nothing before it. The RPO equals the backup age (here about 3.2 s; in production it would be the interval between backups, or about 5 minutes with RDS PITR).
- An earlier S7 run reported `missing=0` because the marker writer stopped immediately (a stop-flag race). That run was discarded; the script now aborts if no writes were acknowledged after the backup.

Evidence (per-step logs, marker logs, failover/failback `events.log` + `summary.json`): `~/stockwatch-dr-evidence/sim-1794358922/` on the primary host (not committed).
