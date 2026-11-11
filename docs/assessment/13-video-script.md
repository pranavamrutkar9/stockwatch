# 13 — Video Script (DR failover demonstration, ≈ 8–9 minutes)

Procedure, expected output and troubleshooting: [12](12-video-demonstration-runbook.md). Everything shown is a **local simulation on one EC2 host** — say so on screen and in speech. Numbers you quote must be the ones **your** recording prints (`scripts/dr-demo.sh report`); the figures below are from the 2026-11-11 rehearsal and are only for orientation.

## Before recording (not on camera)

```bash
cd ~/stockwatch && git fetch && git switch docs/dr-video-demonstration && git pull --ff-only   # after merge: main
scripts/dr-demo.sh status          # expect "no demo environment" (exit 2); else: scripts/dr-demo-walkthrough.sh --cleanup
```

Do one complete rehearsal with the controller (`scripts/dr-demo-walkthrough.sh --tmux`, through stage 16 `DOWN`) before recording.

**Screen layout (1920 × 1080):**

- Terminal maximised, font ≥ 16 pt, at least ~200 columns wide. `--tmux` splits it: **left** = controller, **right** = live traffic (opens at stage 4). Without tmux: two terminal windows side by side; the controller tells you when to run `scripts/dr-demo.sh traffic watch` in the right one.
- Browser tab: production StockWatch (Inventory, Stock checks, `/api/health`), **read-only** — never run a production stock check.
- Editor (VS Code or `less`) with the six files of the code walkthrough already open.

## Recording — one command

```bash
scripts/dr-demo-walkthrough.sh --tmux
```

The controller prints, at every stage, *What / Why / Expected*, the exact engine command and the real result, then waits. Type `DESTROY`, `PROMOTE`, `FAILBACK` and `DOWN` when asked. If something fails, it stops and explains; do not edit or hide output (see "Fallback" below).

## Timeline

| Time | Stage(s) | Requirement | Show | Say (short) |
|---|---|---|---|---|
| 0:00–1:30 | 01, 02 | context | Stage 01 checks, press Enter: stage 02 builds and starts the simulation (≈ 40–90 s). **While it builds**, switch to the browser: production **Inventory**, **Stock checks**, an existing low-stock alert, `/api/health`; then the `02-system-architecture.md` diagram. Back to the terminal for the stage 02 result and `selfcheck`. | "This is StockWatch in production on EC2 with RDS in Sydney. For disaster recovery I've built replication, failover and failback automation, traffic switching and queue reconstruction. Because of the zero-spend constraint, Melbourne is designed in Terraform but not provisioned, so this demonstration runs **two simulated sites on one EC2 host** — real application, real PostgreSQL streaming replication, our real failover scripts — not a real multi-region AWS deployment. The self-check shows the simulation is isolated: internal network, no published ports. Production is not touched." |
| 1:30–2:30 | 03, 04 | **1. primary handling live traffic** | Stage 03 seed output; stage 04 opens the traffic pane on the right. | "I create ten known records, DEMO-001 to 010, and one stock check through the API, the queue and the worker. This checksum covers every seed row — it's the integrity baseline. A client now writes an item every 200 ms through a front door — a simulated DNS record it resolves before every request. Every request goes to Sydney and gets 201." |
| 2:30–3:00 | 05 | replication | Stage 05 status | "Sydney is the active primary, replication is streaming with zero bytes of lag, and the Melbourne standby already holds the identical checksum." |
| 3:00–4:00 | 06, 07 | **2. disaster** | Type `DESTROY`. Point at the traffic pane turning to `FAILED (000)`; the detector's three failed probes; stage 07 status: `pg-sydney DESTROYED`. | "I destroy the whole simulated Sydney site — database and its volume, API, worker, Redis. The health checker probes every second and needs three consecutive failures, so one lost probe can't trigger a promotion — here it took <N> seconds. It pages the operator rather than promoting automatically: promotion is irreversible, so it is an approved step, as in the AWS runbook." |
| 4:00–5:00 | 08, 09 | **3a. traffic failover** | Type `PROMOTE`; read the step log; traffic pane turns to `backend-melbourne 201 Created`; stage 09 status. | "The same dr-failover.sh we'd run against AWS, with the local provider: check lag — zero — promote Melbourne, start its application and worker on an empty Redis, wait for health, and only then switch the front door. Automation took <N> seconds; the first write acknowledged by Melbourne came <N> seconds after the disaster, including my pause before confirming." |
| 5:00–6:15 | 10, 11, 12 | **3b. data integrity on DR** | Stage 10 verify, 11 write-read, 12 stock-check. | "All ten known records by primary key, the checksum matches the baseline, and every write the client saw acknowledged is present — <N> lost in this run. A new write read back through the API, and a stock check processed by Melbourne's worker: the queue is rebuilt from PostgreSQL, not from the lost Redis." |
| 6:15–7:00 | 13, 14 | failback | Type `FAILBACK`; stage 14 verify + status (melbourne marked RETIRED). | "Failback is controlled: rebuild Sydney as a replica of Melbourne, wait for lag zero, stop Melbourne's writers, re-check, promote Sydney, start its app, switch the front door back. Database writes paused for <N> ms. The checksum still matches and the record written on Melbourne is present." |
| 7:00–8:15 | (pause at 15) | **4. code walkthrough** | Editor, in this order (below) | see below |
| 8:15–9:00 | 15, 16 | numbers + limits | Stage 15 report; stage 16 type `DOWN`. | see "Closing" |

### Code walkthrough (7:00–8:15)

| File | Point at | Say |
|---|---|---|
| `infrastructure/deployment/dr/dr-failover.sh` | lines 43–80: preflight → T0 → lag check → fence → promote → wait writable → start app → `dr_wait_http` → `dr_p_switch_dns` | "One step engine for both providers; dry-run by default, a dated confirmation token to execute, refuses unknown or excessive lag, timestamps every step for RTO." |
| `infrastructure/deployment/dr/providers/local.sh` | `dr_p_promote` (line 45, `pg_promote`), `dr_p_switch_dns` (line 60) | "In the simulation, promotion is PostgreSQL's `pg_promote`, and DNS is a record file." |
| `infrastructure/deployment/dr/providers/aws.sh` | `promote-read-replica` (line 73), `route53 change-resource-record-sets` (line 95), `create-db-instance-read-replica` for failback (line 105) | "The AWS provider replaces those with RDS replica promotion and a Route 53 record change. It is tested against a stub AWS CLI and a real read-only dry run; it has **not** run against a real replica, because none exists." |
| `infrastructure/deployment/dr/dr-failback.sh` | lines 36–60: reverse standby, lag 0 twice, fence, promote | "Failback waits for zero lag before and after stopping writers — that's what makes it zero-loss." |
| `apps/backend/src/stock-checks/stock-check-recovery.service.ts` | `StockCheckRecoveryService` (line 43) | "PostgreSQL is the source of truth. After a Redis loss — which is what a failover is for the queue — pending checks are re-enqueued from the database, with the stock-check id as the job id, so a re-enqueued check cannot produce duplicate results." |
| `scripts/dr-demo.sh` (+ `scripts/dr-demo-walkthrough.sh`) | `seed_checksum`, the traffic loop in `cmd_traffic`, the detector in `cmd_disaster`; the controller only orchestrates these commands | "The checksum, the client that resolves the front door per request, and the three-strike detector. The test suite proves the checksum is real: changing one seed row makes verify fail." |

### Closing (8:15–9:00) — say exactly this, with your measured numbers

> "Measured in this local simulation on one host: detection X seconds with a three-strike, one-second health check; failover automation Y seconds; first acknowledged write on the DR site Z seconds after the disaster; zero acknowledged writes lost because replication lag was zero. Failback: under a second of database write freeze, zero loss.
> What this does **not** show: a real AWS regional failover. There is no cross-region RDS replica, no second region and no public Route 53 failover — the account has only a private hosted zone and no domain. In AWS you'd add about 90 to 150 seconds of Route 53 detection and TTL, plus several minutes of RDS replica promotion, and asynchronous replication could lose recent writes. Recovery from a backup instead of a replica loses every write since the backup — 28 writes in our backup-restore test. Our production regional RPO has not been measured."

## Do not say or show

- "Failover to Melbourne / to AWS ap-southeast-4" without "simulated".
- "I switched to another AWS server." Say instead: "I simulated a primary-site failure, promoted the replicated DR database, and switched traffic through the simulated DNS front door."
- Any production kill, restart or stock check; the production `.env`; `docker ps` of production containers with environment details.
- RTO/RPO numbers from this document instead of your run's `report`.
- "Zero data loss" without "in this simulation run, with zero replication lag".

## Fallback if something fails on camera

If a stage fails, the controller stops and explains. Either fix and press `r` (retry), or `q`, then `scripts/dr-demo-walkthrough.sh --resume` (continues from the recorded phase) or `--cleanup` and start again. If `verify` exits 3 (acknowledged writes lost), keep it: say "this run lost N acknowledged writes — that is asynchronous replication's RPO" and show the missing sequence numbers.
