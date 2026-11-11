# 13 — Video Script (DR failover demonstration, ≈ 8–9 minutes)

Procedure, expected output and troubleshooting: [12](12-video-demonstration-runbook.md). Everything shown is a **local simulation on one EC2 host** — say so on screen and in speech. Numbers you quote must be the ones **your** recording prints (`scripts/dr-demo.sh report`); the figures below are from the 2026-11-11 rehearsal and are only for orientation.

## Before recording (not on camera)

```bash
cd ~/stockwatch && git switch main && git pull --ff-only
scripts/dr-demo.sh status          # expect: no demo environment (exit 2); else: scripts/dr-demo.sh down
scripts/dr-demo.sh up              # 40–90 s; keep this terminal output to scroll back on camera
```

Layout: terminal **left** (commands), terminal **right** (`scripts/dr-demo.sh traffic watch`, started at 1:30), editor (VS Code or `less`) for the code walkthrough, browser tab with the production app (read-only).
Font ≥ 16 pt; clear the screen between segments (`clear`).

## Timeline

| Time | Requirement | Show | Say (short) |
|---|---|---|---|
| 0:00–0:40 | context | Browser: production StockWatch **Inventory** and **Stock checks** pages (read-only; do not run a check). Then `docs/assessment/02-system-architecture.md` diagram. | "This is StockWatch in production on EC2 with RDS in Sydney. Melbourne is designed in Terraform but not provisioned — zero-spend constraint. So the failover you'll see is a **local simulation on one host**, using the real application, real PostgreSQL streaming replication and our real failover scripts. Production is not touched." |
| 0:40–1:30 | setup | Scroll the `up` output: two sites, standby streaming, `stockwatch_app`. Then `scripts/dr-demo.sh seed`. | "Two simulated regions on an isolated Docker network: Sydney primary, Melbourne hot standby fed by streaming replication. I create ten known records, DEMO-001 to 010, and one stock check that runs through the API, the queue and the worker. This checksum covers every seed row — it's our integrity baseline." |
| 1:30–2:30 | **1. primary handling live traffic** | Left: `scripts/dr-demo.sh traffic start` · right: `scripts/dr-demo.sh traffic watch` · left: `scripts/dr-demo.sh status` | "A client writes an item every 200 ms through a front door — a simulated DNS record that the client resolves before every request. All requests go to Sydney and get 201. Status shows the replica streaming with zero bytes of lag, and Melbourne already holds the identical seed checksum." |
| 2:30–3:30 | **2. disaster** | `scripts/dr-demo.sh disaster` — point at the traffic pane turning to `FAILED (000)` | "I now destroy the whole Sydney site — database and its volume, API, worker, Redis. The health checker probes every second; three consecutive failures mark the primary down — here after about 2.5 seconds. It pages the operator instead of promoting automatically: promotion is irreversible, so it's an approved step, just like the AWS runbook." |
| 3:30–4:30 | **3a. traffic failover** | `scripts/dr-demo.sh failover` — read the step log; traffic pane turns to `backend-melbourne 201` | "The operator runs the same dr-failover.sh we'd use against AWS, with the local provider and a dated confirmation token. It checks replication lag — zero — promotes Melbourne, starts the application there, waits for it to be healthy, and only then switches the front door. Automation took <N> seconds — read it from the output; it has varied from 2.4 to 6.7 s, mostly in the promotion step. The first write acknowledged by Melbourne came <N> seconds after the disaster, which includes how long I paused before typing the command." |
| 4:30–5:45 | **3b. data integrity on DR** | `scripts/dr-demo.sh verify` · `scripts/dr-demo.sh write-check` · `scripts/dr-demo.sh status` | "On Melbourne: all ten known records by primary key, the seed checksum matches the baseline, and every write the client saw acknowledged is present — zero lost in this run. A new write and its read-back through the API, and a stock check processed by Melbourne's worker on an empty Redis: the queue is rebuilt from PostgreSQL. Sydney's database is gone." |
| 5:45–6:45 | failback | `scripts/dr-demo.sh failback` · `scripts/dr-demo.sh verify` | "Failback is planned: rebuild Sydney as a replica of Melbourne, wait for lag zero, stop Melbourne's writers, re-check lag, promote Sydney, start its app, switch the front door back. Writes paused for about 0.7 s in the database; clients saw about 2.6 s of errors because we switch only after the app is healthy. Checksum matches; the record written on Melbourne is present; nothing acknowledged was lost." |
| 6:45–8:15 | **4. code walkthrough** | Editor, in this order (below) | see below |
| 8:15–9:00 | numbers + limits | `scripts/dr-demo.sh report`, then `scripts/dr-demo.sh down` | see "Closing" |

### Code walkthrough (6:45–8:15)

| File | Point at | Say |
|---|---|---|
| `infrastructure/deployment/dr/dr-failover.sh` | lines 43–80: preflight → T0 → lag check → fence → promote → wait writable → start app → `dr_wait_http` → `dr_p_switch_dns` | "One step engine for both providers; dry-run by default, a dated confirmation token to execute, refuses unknown or excessive lag, timestamps every step for RTO." |
| `infrastructure/deployment/dr/providers/local.sh` | `dr_p_promote` (line 45, `pg_promote`), `dr_p_switch_dns` (line 60) | "In the simulation, promotion is PostgreSQL's `pg_promote`, and DNS is a record file." |
| `infrastructure/deployment/dr/providers/aws.sh` | `promote-read-replica` (line 73), `route53 change-resource-record-sets` (line 95), `create-db-instance-read-replica` for failback (line 105) | "The AWS provider replaces those with RDS replica promotion and a Route 53 record change. It is tested against a stub AWS CLI and a real read-only dry run; it has **not** run against a real replica, because none exists." |
| `infrastructure/deployment/dr/dr-failback.sh` | lines 36–60: reverse standby, lag 0 twice, fence, promote | "Failback waits for zero lag before and after stopping writers — that's what makes it zero-loss." |
| `apps/backend/src/stock-checks/stock-check-recovery.service.ts` | `StockCheckRecoveryService` (line 43) | "PostgreSQL is the source of truth. After a Redis loss — which is what a failover is for the queue — pending checks are re-enqueued from the database, with the stock-check id as the job id, so a re-enqueued check cannot produce duplicate results." |
| `scripts/dr-demo.sh` | `seed_checksum` (line 75), traffic loop in `cmd_traffic` (line 173), detector in `cmd_disaster` (line 220) | "The checksum, the client that resolves the front door per request, and the three-strike detector. The test suite proves the checksum is real: changing one seed row makes verify fail." |

### Closing (8:15–9:00) — say exactly this, with your measured numbers

> "Measured in this local simulation on one host: detection X seconds with a three-strike, one-second health check; failover automation Y seconds; first acknowledged write on the DR site Z seconds after the disaster; zero acknowledged writes lost because replication lag was zero. Failback: under a second of database write freeze, zero loss.
> What this does **not** show: a real AWS regional failover. There is no cross-region RDS replica, no second region and no public Route 53 failover — the account has only a private hosted zone and no domain. In AWS you'd add about 90 to 150 seconds of Route 53 detection and TTL, plus several minutes of RDS replica promotion, and asynchronous replication could lose recent writes. Recovery from a backup instead of a replica loses every write since the backup — 28 writes in our backup-restore test. Our production regional RPO has not been measured."

## Do not say or show

- "Failover to Melbourne / to AWS ap-southeast-4" without "simulated".
- Any production kill, restart or stock check; the production `.env`; `docker ps` of production containers with environment details.
- RTO/RPO numbers from this document instead of your run's `report`.
- "Zero data loss" without "in this simulation run, with zero replication lag".

## Fallback if something fails on camera

`scripts/dr-demo.sh down`, then restart from "Before recording". If `verify` exits 3 (acknowledged writes lost), keep it: say "this run lost N acknowledged writes — that is asynchronous replication's RPO" and show the missing sequence numbers.
