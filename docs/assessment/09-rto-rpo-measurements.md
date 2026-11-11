# 09 — RTO / RPO Measurements

Every number below is labelled with how it was obtained. **None of them is an AWS cross-region measurement.**

## Local simulation (single host, Docker containers standing in for regions) — Local simulation verified

Run `sim-1794358922`, 2026-11-11T01:04:55Z. Monotonic clock (`/proc/uptime`, 10 ms resolution); a marker writer creates an inventory item every ~100 ms; RPO = **acknowledged** (HTTP 201) writes missing after recovery. Full table and interpretation: [`docs/dr-simulation-results.md`](../dr-simulation-results.md).

| ID | Failure injected | RTO (restoration, ms) | RPO |
|---|---|---|---|
| S1 | Backend SIGKILL | 1 170 (Docker restart policy) | 0 of 40 acknowledged |
| S2 | DB connectivity lost 15 s | 100 after the DB returned | 0 of 51 |
| S3 | Redis destroyed, no backup used, 10 queued checks | 3 470 to rebuild the queue from PostgreSQL | 0 checks lost, 0 duplicate alerts |
| S4 | Worker SIGKILL with 30 queued checks | 60 680 to drain (BullMQ lock expiry for SIGKILLed workers) | 0 non-terminal checks |
| S5 | Primary "region" lost → promote streaming standby, start secondary app | 2 870 (queue drained 5 050) | 0 of 812 |
| S6 | Planned failback | 4 380 end-to-end; 730 write unavailability | 0 of 845 |
| S7 | Primary DB destroyed → restore verified logical backup | 6 100 | 28 lost = every write acknowledged after the backup (RPO = backup age, 3.2 s here) |

Detection in S1–S7 is near-instant because the failure is injected locally. In AWS, add Route 53 health-check detection (≈ 90–150 s) and the record TTL.

## Local DNS failover simulation (CoreDNS) — Local simulation verified

Run `dns-sim-1794368074`, 3 rounds, medians (ms from injection). Details: [08](08-dns-failover-simulation.md).

| | Detection | Client served by target | Client error window |
|---|---|---|---|
| Failover | 5 443 | 10 124 | 9 014 |
| Failback | 3 171 | 4 896 | 0 |

## Production (Sydney) — Production verified

Measured with an availability probe (~0.5 s interval) during real changes. Evidence is under `~/stockwatch-dr-evidence/` on the host (not committed).

| Change | Result | Evidence |
|---|---|---|
| Deploy release `498e28b` (2026-11-11 02:10 UTC) | API and web failed from 02:10:38.866 to 02:10:45.109 → **≈ 6.2 s** interruption (≤ 7.3 s between surrounding successes) | `deploy-498e28b/availability.log` |
| Switch application to `stockwatch_app` (2026-11-11 02:45 UTC) | **one** failed `/api/health` probe at 02:45:12.103 (≤ 3.1 s between surrounding successes); inventory and web stayed 200 | `db-roles-rollout-20261111T024429Z/availability-phase3.log` |
| Remove transition grant (2026-11-11 02:46 UTC) | 0 failed probes (11 samples) | `db-roles-rollout-20261111T024429Z/availability-phase4.log` |

## Not measured anywhere

RDS cross-region replica promotion time, real cross-region replication lag, Route 53 propagation, RDS point-in-time restore, cold DR host boot and image pull. Real Melbourne recovery and public DNS failover were **not demonstrated** ([11](11-known-limitations.md)).
