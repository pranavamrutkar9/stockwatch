# 12 — Video Demonstration Runbook (DR failover, LOCAL SIMULATION)

> **What this demonstrates — and what it does not.** Everything below runs in disposable Docker containers on **one EC2 host**, on an internal Docker network with no published ports. The "sydney" and "melbourne" sites are **simulated regions**; the "front door" is a **simulated DNS record**. The database replication, promotion, failover/failback automation, application, worker and queue recovery are the real StockWatch code and real PostgreSQL 16 streaming replication. This is **not** an AWS cross-region failover: no RDS replica, no second region, no Route 53. Production (`stockwatch-*` containers, RDS) is never touched.

Timings and ids in the "Expected" blocks below come from rehearsal 1 and differ on every run; quote only what your run prints (`scripts/dr-demo.sh report`).

Tool: [`scripts/dr-demo.sh`](../../scripts/dr-demo.sh) — a step-by-step driver for scenarios S5/S6 of [`scripts/dr-simulate.sh`](../../scripts/dr-simulate.sh). Automated end-to-end test: [`scripts/test-dr-demo.sh`](../../scripts/test-dr-demo.sh) (42 checks, ≈ 1 min). Interactive controller for the video: [`scripts/dr-demo-walkthrough.sh`](../../scripts/dr-demo-walkthrough.sh) (next section).

## Recommended: the interactive controller

```bash
cd ~/stockwatch
scripts/dr-demo-walkthrough.sh --tmux      # or without --tmux: open a 2nd terminal with 'scripts/dr-demo.sh traffic watch'
```

[`scripts/dr-demo-walkthrough.sh`](../../scripts/dr-demo-walkthrough.sh) runs the commands of this runbook in 16 numbered stages and **waits for you before each one**. For every stage it prints what happens, why it matters, the exact `scripts/dr-demo.sh …` command, the expected result, and then the real output and measured values of this run.

| Stage | Engine command(s) | Confirmation |
|---|---|---|
| 01 Introduction and safety checks | — | Enter |
| 02 Initialize the isolated environment | `up`, `selfcheck`, `status` | Enter |
| 03 Seed ten known records, checksum baseline | `seed` | Enter |
| 04 Start primary traffic (opens the tmux traffic pane) | `traffic start`, `traffic show 6` | Enter |
| 05 Primary status and streaming replication | `status` | Enter |
| 06 Simulate the primary-site disaster | `disaster` | type **DESTROY** |
| 07 Detection and failed traffic | `traffic show 8`, `status` | Enter |
| 08 Controlled failover | `failover` | type **PROMOTE** |
| 09 Traffic switched to DR | `traffic show 8`, `status` | Enter |
| 10 Integrity on the DR database | `verify` | Enter |
| 11 New write and read-back on DR | `write-read` | Enter |
| 12 Stock check through the DR worker | `stock-check` | Enter |
| 13 Controlled failback | `failback` | type **FAILBACK** |
| 14 Final integrity and status | `verify`, `status` | Enter |
| 15 Measured RTO/RPO report | `report` | Enter |
| 16 Cleanup | `traffic stop`, `down` | type **DOWN** (or `k` to keep) |

- At every pause: `s` status, `v` verify, `t` recent traffic, `r` report (read-only repeats), `q` quit. Quitting or Ctrl-C keeps the simulation; continue with `--resume` (re-runs the isolation self-check, then continues from the recorded phase) or remove it with `--cleanup`.
- A failed stage stops the walkthrough with an explanation and recovery steps (`r` retry, `s` status, `q` quit). It never continues on its own. A failed integrity check is printed as **INTEGRITY CHECK FAILED**; lost acknowledged writes (verify exit 3) are highlighted, not hidden.
- Safety: the controller never calls `docker` itself and never reads the production `.env`; every action goes through `dr-demo.sh`. Before the first change, `dr-demo.sh selfcheck` must confirm the `sw-demo-<run>` prefix, an **internal** Docker network, no published ports, no container on another network, and a state directory outside the repository. Tests: [`scripts/test-dr-demo-walkthrough.sh`](../../scripts/test-dr-demo-walkthrough.sh) (35 checks: 24 against a stub engine, 11 in a real run).

The sections below describe the same steps as individual commands (useful for troubleshooting or re-running one step).

## How the simulation maps to the design

| Demo component | Container(s) `sw-demo-<run>-…` | Production / AWS equivalent |
|---|---|---|
| sydney site | `pg-sydney` (PostgreSQL 16 primary), `redis-sydney`, `backend-sydney`, `worker-sydney` | EC2 + RDS in ap-southeast-2 |
| melbourne site | `pg-melbourne` (hot standby, `pg_basebackup` + streaming replication) | cross-region RDS read replica in ap-southeast-4 (designed, **not provisioned**) |
| front door | file `app=primary\|secondary` + host map, re-read by the client before **every** request | Route 53 failover record (not available: private zone only, no domain) |
| detector | `dr-demo.sh disaster`: health probe every 1 s, 3 consecutive failures = DOWN | Route 53 health check (30 s × 3) / CloudWatch alarm |
| failover | `infrastructure/deployment/dr/dr-failover.sh --provider local` (promote, start DR app, switch front door) | same script, `--provider aws` |
| failback | `infrastructure/deployment/dr/dr-failback.sh --provider local` | same script, `--provider aws` |
| client | `client`: `POST /api/inventory` every ~0.2 s, logs time, HTTP code, site | users |

The application runs as `stockwatch_app`, provisioned by the same `db-roles.sh` as production. Credentials are random per run and exist only in `~/.cache/sw-demo/state.env` (mode 600) and the disposable containers.

## 1. Prerequisites

- The primary EC2 host (or any Linux host with Docker), a checkout of this repository, ~2 GB free RAM.
- Docker images (pulled automatically on first use): `postgres:16-alpine`, `redis:7-alpine`, `node:22-bookworm`, `alpine:latest`.
- No AWS credentials, no production `.env`, no RDS access are used.
- Recording layout: **two terminal panes** side by side — left: commands; right: live traffic (`scripts/dr-demo.sh traffic watch`).
- Check that no earlier demo is running: `scripts/dr-demo.sh status` → `ERROR: no demo environment` (exit 2). If one exists: `scripts/dr-demo.sh down`.

## 2. Environment startup

```bash
cd ~/stockwatch
scripts/dr-demo.sh up          # 40–90 s (builds backend + worker from this checkout)
```

Expected (names include a run id):

```
== Sydney site: PostgreSQL 16 primary on internal network sw-demo-<run>-net
   schema migrated; stockwatch_app / stockwatch_migrator provisioned (same db-roles.sh as production)
== Melbourne site: PostgreSQL 16 hot standby (pg_basebackup + streaming replication)
   standby in recovery (read-only), streaming from sydney
== Client (traffic generator) and sydney application
   sydney backend healthy; front door: app=primary -> backend-sydney
   evidence directory: /home/ubuntu/stockwatch-dr-evidence/demo-<run>
```

## 3. Generate the known test data (disposable)

```bash
scripts/dr-demo.sh seed
```

Creates, **through the API**, items `DEMO-001` … `DEMO-010` (odd numbers below their minimum) and runs one stock check end to end (API → BullMQ → worker → PostgreSQL). Expected:

```
   10 inventory items DEMO-001..DEMO-010 (odd = low stock), ids:
     DEMO-001 74fa3aa7-…
   stock check b5483b97-…: status=COMPLETED totalChecked=10 lowStockCount=5
   seed checksum (md5 of all seed rows) on sydney primary: 8e6c0fdc…
```

The **seed checksum** is an md5 over every seed row (all columns of the 10 items, the seed stock check, its 5 alerts), sorted. It is the integrity baseline for the rest of the demo. All ids: `<evidence>/seed_ids.txt`.

## 4. Primary environment verification (live traffic)

```bash
scripts/dr-demo.sh traffic start
scripts/dr-demo.sh traffic watch        # right-hand pane; Ctrl-C only stops the display
scripts/dr-demo.sh status
scripts/dr-demo.sh verify
```

Expected:

```
09:07:33.083  #17    POST /api/inventory -> backend-sydney     201 Created          (traffic watch)

== Simulation sw-demo-<run> — phase: primary   front door: app=primary -> backend-sydney
   pg-sydney      PRIMARY (read-write)   items=30  seed_checksum=8e6c0fdc…  <- ACTIVE (used by the front-door application)
     replication -> walreceiver state=streaming replay_lag_bytes=0
   pg-melbourne   standby (read-only)    items=31  seed_checksum=8e6c0fdc…
   backend-sydney /api/health 200
```

The standby already holds the **same seed checksum** — replication is visible before anything fails. (Item counts of the two databases are read a moment apart while traffic is writing, so they can differ by one or two.)

`verify` prints the role of the active database, row counts, the 10 known ids by primary key, the checksum comparison, and the traffic RPO check (`acknowledged but missing here`).

## 5. Inject the simulated disaster and 6. failure detection

```bash
scripts/dr-demo.sh disaster
```

Removes the **entire sydney site** — database container and its volume, backend, worker, Redis — then runs the detector. Expected:

```
   replication just before: streaming, 0 bytes behind
   09:07:42.178  sydney site destroyed (containers and volumes removed)
== Health-check detector: probe http://backend-sydney:4000/api/health every 1 s; 3 consecutive failures = DOWN
   09:07:42.527  probe 1: FAILED (000)  consecutive failures=1
   09:07:43.590  probe 2: FAILED (000)  consecutive failures=2
   09:07:44.653  probe 3: FAILED (000)  consecutive failures=3
   PRIMARY DOWN detected after 2479 ms -> page the operator: run 'scripts/dr-demo.sh failover'
```

The traffic pane now shows `FAILED (000)` for every request: the front door still points at sydney. Promotion is deliberately an **operator decision** (as in the AWS design: promoting a replica is irreversible and must be confirmed), so the detector pages rather than promotes.

## 7. Traffic switches to DR

```bash
scripts/dr-demo.sh failover
```

Runs the real `dr-failover.sh --provider local --execute --confirm FAILOVER-<UTC date>`:

```
   RPO-EVIDENCE replication_lag_seconds=0
   SKIP fence …-backend-sydney: not present (primary region down)
   EXEC promote standby …-pg-melbourne (pg_promote)
   EXEC start secondary app against …-pg-melbourne
   EXEC simulated DNS: app -> secondary
   front door now: app=secondary -> backend-melbourne
== Measured (this run, local simulation)
   detection (3 failed probes):          2479 ms
   dr-failover.sh automation (T0->T_RESTORED): 2.39 s
   first write acknowledged by melbourne: 09:07:47.271 -> client-observed RTO 5093 ms after the disaster
```

Order matters and is enforced by the script: the front door switches **only after** the DR application is healthy. A failed failover (e.g. standby unavailable) exits 1 and leaves the front door unchanged (covered by `test-dr-demo.sh`).

## 8. Verify requests are served by DR

- Traffic pane: `POST /api/inventory -> backend-melbourne  201 Created`.
- `scripts/dr-demo.sh status`: `pg-sydney DESTROYED / absent`; `pg-melbourne PRIMARY (read-write) <- ACTIVE`; `backend-melbourne /api/health 200`.
- `scripts/dr-demo.sh write-check` (= `write-read` + `stock-check`):

```
   POST /api/inventory  -> 201, id 4a285dc9-…, sku DR-WRITE-failed-over-090757
   GET  /api/inventory/4a285dc9-… -> sku DR-WRITE-failed-over-090757
   database pg-melbourne: 1 row(s)
   stock check 0d3d1616-… on this site: status=COMPLETED totalChecked=118 lowStockCount=6
```

That is a post-failover write, its read-back through the API, the row in the DR database, and a stock check processed end to end by the DR worker on an **empty** Redis.

## 9. Verify database records and checksums

```bash
scripts/dr-demo.sh verify
```

```
== Integrity check on the ACTIVE database: pg-melbourne (front door -> backend-melbourne)
   role: PRIMARY (read-write)
   row counts: inventory_items=114 (DEMO=10, TRAFFIC=104, DR-WRITE=0)  stock_checks=1  stock_alerts=5
   known records DEMO-001..010 by id: 10/10 present; seed stock check b5483b97-…: COMPLETED
   seed checksum: baseline 8e6c0fdc… | now 8e6c0fdc… -> MATCH
   traffic: 128 requests sent, 105 acknowledged (201); acknowledged but missing here: 0
   RPO (this run): 0 acknowledged writes lost
```

Exit codes: `0` seed intact and no acknowledged write lost; `3` seed intact but acknowledged writes missing (the run's RPO > 0 — reported, never hidden); `1` seed data changed or missing. The test suite proves the check is real: altering one seed row makes `verify` print `MISMATCH` and exit 1.

## 10. Measure RTO and RPO

`scripts/dr-demo.sh report` prints what was measured in **this** run (also in `<evidence>/measurements.txt`):

| Metric | Meaning |
|---|---|
| `detection_ms` | disaster → 3rd failed probe |
| `operator_decision_ms` | detection → `failover` command (in a recording: your narration pause) |
| `failover_automation_s` | `dr-failover.sh` T0 → T_RESTORED (`summary.json`) |
| `client_rto_ms` | disaster → first write acknowledged by melbourne (what a user sees) |
| `client_outage_ms` | last acknowledged write on sydney → first on melbourne |
| `verify_<phase>: … missing=N` | RPO in acknowledged writes at that point |
| `failback_db_write_freeze_ms` | writers stopped → rebuilt primary promoted |
| `failback_client_error_window_ms` | first failed request during failback → first acknowledged write on sydney2 |

**RPO, stated precisely:**

- **This simulation:** asynchronous streaming replication on one host had **0 bytes** of lag at the disaster, so 0 acknowledged writes were lost. Asynchronous replication *can* lose the last transactions; a busy or distant replica will show `missing > 0` and `verify` exits 3.
- **Backup-restore recovery (S7, [09](09-rto-rpo-measurements.md)):** every write after the backup is lost (28 in that run): RPO = backup age.
- **Production regional RPO: not measured.** No cross-region replica exists; real replica lag, RDS promotion time and Route 53 detection (≈ 90–150 s) are absent from every number here.

## 11. Fail back

```bash
scripts/dr-demo.sh failback
scripts/dr-demo.sh verify
scripts/dr-demo.sh write-check
scripts/dr-demo.sh status
```

`dr-failback.sh`: build `pg-sydney2` as a streaming replica **of melbourne** (`pg_basebackup`), wait for lag 0, stop melbourne's writers, re-check lag 0, promote sydney2, start the sydney2 application, then switch the front door back. Expected:

```
   dr-failback.sh end-to-end: 4.32 s; database write freeze (writers stopped -> promoted): 730 ms
   client-observed failed requests from 09:08:06.594 to first sydney2 ack 09:08:09.217: 2623 ms
…
   seed checksum: baseline 8e6c0fdc… | now 8e6c0fdc… -> MATCH
   traffic: 189 requests sent, 154 acknowledged (201); acknowledged but missing here: 0
   record written earlier via the front door, DR-WRITE-failed-over-090757: present
```

`status` after failback shows `pg-melbourne PRIMARY (read-write) <- RETIRED: application fenced, no client`. That is the honest end state of a planned failback: the old DR database is no longer used by any application; in AWS it would be deleted and re-created as a new cross-region replica.

The client error window (≈ 2.6 s) is longer than the database write freeze (≈ 0.7 s) because the front door switches only once the rebuilt primary's application is healthy.

## 12. Cleanup

```bash
scripts/dr-demo.sh traffic stop
scripts/dr-demo.sh report
scripts/dr-demo.sh down
docker ps -a --format '{{.Names}}' | grep -c '^sw-demo-'     # expected: 0
```

`down` removes every `sw-demo-<run>-*` container, their volumes and the network, and the state directory. Evidence stays in `~/stockwatch-dr-evidence/demo-<run>/` (seed ids, baseline, traffic log, failover/failback `events.log` + `summary.json`, measurements; no credentials).

## Rehearsal results (2026-11-11, this host)

| Metric | Rehearsal 1 `demo-1794388002` (commands back to back) | Rehearsal 2 `demo-1794388368` (runbook, 8 s "narration" pause) | Earlier batch run `sim-1794358922` (S5/S6) |
|---|---|---|---|
| Detection (3 × 1 s probes) | 2 479 ms | 2 472 ms | 310 ms (single immediate probe) |
| Operator decision time | 16 ms | 8 013 ms | n/a |
| Failover automation (`dr-failover.sh`) | 2.39 s | 6.67 s | 2.44 s |
| — of which `pg_promote` | 220 ms | 4 530 ms | 220 ms |
| Client-observed RTO (disaster → first ack on DR) | 5 093 ms | 17 324 ms | 2 870 ms (no detection threshold) |
| Acknowledged writes lost at failover | 0 / 105 | 0 / 63 | 0 / 812 |
| Failback end-to-end | 4.32 s | 4.17 s | 4.38 s |
| Failback DB write freeze | 730 ms | 700 ms | 730 ms |
| Failback client error window | 2 623 ms | 2 366 ms | not measured |
| Acknowledged writes lost at failback | 0 / 154 | 0 / 79 | 0 / 845 |

Differences explained:

- **Detection** is longer than the batch run's because the demo requires three consecutive failed 1 s probes, as a real health check would; the batch run took a single probe immediately.
- **Client-observed RTO** = detection + operator decision + automation (+ ≤ 0.2 s until the client's next request). In a recording the operator decision is the narration pause, so expect 10–30 s.
- **Promotion took 4.5 s in rehearsal 2 but 0.2 s otherwise.** Every other step took the same time. The likely cause (not separately verified) is PostgreSQL's WAL retry loop: a standby that has lost its primary retries every `wal_retrieve_retry_interval` (default 5 s), and a promotion request can wait for the next cycle. Rehearsal 1 promoted within 20 ms of detection, before the loop settled. Expect 0.2–5 s for this step.
- **Failback** is consistent across runs (≈ 4.2–4.4 s; ≈ 0.7 s write freeze).

Automated test: `scripts/test-dr-demo.sh` → 42/42 (includes the same flow plus failure handling).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `ERROR: a demo environment already exists` | `scripts/dr-demo.sh down`, then `up` |
| `up` fails at build | network/npm registry problem; `down`, retry. The build log is suppressed; run the `pnpm` build in the repo to see errors |
| `failover follows 'disaster'` / other exit 2 | commands must run in order: up → seed → traffic start → disaster → failover → failback → down |
| `failover` exits 1 | read `<evidence>/failover.out`; the front door is not switched and the phase stays `disaster`. If it failed **before** `EXEC start secondary app` (e.g. preflight), fix the cause and run `failover` again (an already-promoted standby is detected and skipped). If it failed later, `down` and start over — re-running would try to create the melbourne containers twice |
| `verify` exits 3 | acknowledged writes were lost (real asynchronous-replication loss in this run) — report it, do not hide it |
| traffic pane shows nothing | `scripts/dr-demo.sh traffic start` was not run, or run `traffic show 20` |
| host under load (slow probes) | timings vary; record and report the measured values, never the table above |
