# Runbook — Production Recovery: Stale RDS Credentials + Redis Password Rotation

**Status:** EXECUTED 2026-11-10 19:54:34–19:56:49 UTC (Steps 0–4, 6 and read-only Step 5; Step 5b not approved, not run). Results: `docs/dr-progress-log.md`.
**Incident:** backend/worker were created (2026-11-10 11:43 UTC) with an RDS password that was changed later (~17:12 UTC). New DB connections fail with Prisma P1000 → `/api/health` 503, `/api/inventory` 500, frontend unhealthy (it proxies backend health).
**Complication:** `.env` already contains the *new* Redis password; the running Redis, backend and worker use the *old* one. Recreating backend/worker from `.env` without first rotating Redis would break Redis auth.

## Rehearsal evidence (2026-11-10 19:42 UTC)

The exact procedure was rehearsed against an isolated replica (`compose -p rh`, all container/network/volume names rewritten, frontend excluded, throwaway passwords, same `1cc73a2` images, real RDS with `SELECT 1` only):

| Step | Rehearsal result |
|---|---|
| 1 `CONFIG SET requirepass` via stdin | `OK` |
| 2 auth check | new pw `PONG`; old pw `WRONGPASS`; existing backend connection stayed authenticated (health 200) |
| Redis container health after step 1 | stayed `healthy` (old healthcheck cannot detect WRONGPASS — see note) |
| 3 recreate backend+worker `--no-deps` | Redis untouched (same StartedAt); backend healthy after 17 s |
| 6 recreate Redis | healthy after 6 s; persistent keys preserved (only TTL key `stalled-check` differed); backend health 200; worker reconnected without errors |
| Secret scan of all logs | 0 occurrences of either password |

Production was verified unchanged after the rehearsal (same container start times, volumes, network).

## Common setup (run once per shell; prints no secrets)

```bash
cd /home/ubuntu/stockwatch
git status --short                       # expect: clean, branch fix/rds-deployment-hardening
export IMAGE_TAG=1cc73a26a79e98d1a96735ca8c86caf09911eb8a   # currently deployed tag (= .current_tag)
DC=(docker compose -p docker --env-file .env -f infrastructure/docker/docker-compose.prod.yml)
EVID=~/stockwatch-recovery/$(date -u +%Y%m%dT%H%M%SZ); mkdir -p -m 700 "$EVID"
newpw() { grep -E '^REDIS_PASSWORD=' .env | cut -d= -f2- | tr -d '"\n'; }   # never echoed
rnew() { REDISCLI_AUTH="$(newpw)" docker exec -i -e REDISCLI_AUTH stockwatch-redis redis-cli "$@"; }
rold() { docker exec -i stockwatch-redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli "$@"' _ "$@"; }
```

- `-p docker` pins the existing Compose project name (containers are labelled `com.docker.compose.project=docker`).
- `docker exec -e REDISCLI_AUTH` (no `=value`) forwards the value from the environment, so the password is not in any process argv.
- `rold` uses the password in the Redis container's own environment (the old one) and never leaves the container.

## Step 0 — Pre-flight and evidence (read-only + local backup)

```bash
"${DC[@]}" config --quiet && echo "compose ok"
docker inspect stockwatch-backend stockwatch-worker stockwatch-redis stockwatch-frontend \
  --format '{{.Name}} {{.Image}} {{.State.StartedAt}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' | tee "$EVID/pre-containers.txt"
echo "wait=$(rold LLEN bull:stock-check:wait) active=$(rold LLEN bull:stock-check:active) id=$(rold GET bull:stock-check:id) dbsize=$(rold DBSIZE)" | tee "$EVID/pre-queue.txt"
rold BGSAVE; sleep 2
docker run --rm -v stockwatch_redis_data:/data:ro -v "$EVID":/backup redis:7-alpine tar -czf /backup/redis-data-pre.tgz -C /data .
ls -la "$EVID"
```

- **Impact:** none on service. `BGSAVE` forks Redis briefly (dataset is ~11 keys).
- **Gate:** abort if `wait` or `active` > 0 — wait for the queue to drain first.
- **Rollback:** not applicable. Evidence directory is outside the repository and mode 700.

## Step 1 — Change the running Redis password to the `.env` value

```bash
newpw | sed 's/^/CONFIG SET requirepass /' | docker exec -i stockwatch-redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli'
# expected output: OK
```

- **Mechanism:** the command is sent on **stdin**; the new password never appears on the terminal, in shell history, or in process arguments. Authentication uses the old password from the container's environment.
- **Impact:** existing authenticated client connections (backend, worker, BullMQ) are **not** dropped. Only new connections must use the new password.
- **Expected downtime:** none.
- **Risk window:** `CONFIG SET` is runtime-only. If the Redis container restarts before Step 6 (host reboot, crash), it starts with the old password from its container env, and the recreated backend/worker (new password) would fail Redis auth. Execute Step 6 the same session.
- **Rollback** (restore old password; authenticates with new, sets value from container env inside the container):

  ```bash
  REDISCLI_AUTH="$(newpw)" docker exec -i -e REDISCLI_AUTH stockwatch-redis sh -c 'printf "CONFIG SET requirepass %s\n" "$REDIS_PASSWORD" | redis-cli'
  ```

## Step 2 — Verify authentication

```bash
echo "new password PING: $(rnew PING)"                      # expect PONG
echo "old password PING: $(rold PING 2>&1 | grep -oE 'PONG|WRONGPASS|NOAUTH' | sort -u | tr '\n' ' ')"   # expect: NOAUTH WRONGPASS
echo "connected clients: $(rnew INFO clients | grep -E '^connected_clients' | tr -d '\r')"   # expect unchanged (~4)
docker exec stockwatch-backend wget -qO- -T 5 http://127.0.0.1:4000/api/health 2>/dev/null | grep -o '"redis":"[a-z]*"'
# expect "redis":"connected" (existing backend connection still authenticated; database still disconnected)
```

- **Impact:** read-only. **Downtime:** none. **Rollback:** Step 1 rollback if the new password does not return PONG.
- **Note:** `docker inspect` health for Redis will keep showing `healthy` even though its own env password is now wrong — the deployed healthcheck does not detect `WRONGPASS` (fixed in commit `3691918`, takes effect at Step 6).

## Step 3 — Recreate only backend and worker on tag `1cc73a2`

```bash
"${DC[@]}" up -d --no-deps --force-recreate --pull never backend worker
docker inspect stockwatch-redis --format 'redis StartedAt (must be unchanged): {{.State.StartedAt}}'
for i in $(seq 1 30); do s=$(docker inspect stockwatch-backend --format '{{.State.Health.Status}}'); echo "$(date -u +%T) backend=$s"; [ "$s" = healthy ] && break; sleep 3; done
```

- **What it does:** replaces the two containers with identical images (`1cc73a2`) but with `DATABASE_URL` and `REDIS_PASSWORD` from the current `.env`. `--no-deps` leaves Redis (and the legacy local postgres) untouched; `--pull never` uses the local images; `-p docker` keeps the same project, network and container names. Compose waits for backend to be healthy before starting worker (`depends_on: service_healthy`).
- **Expected downtime:** API ~15–20 s (rehearsal: healthy after 17 s). The API is already failing every DB request, so user-visible impact is nil. Worker paused for the same window; queue is empty (Step 0 gate).
- **Rollback:** the previous containers had invalid DB credentials, so there is no working state to return to. If the new containers fail:
  - Redis auth errors in logs → re-run Step 2. `.env` only holds the new password, so the fix is forward (make Redis accept the `.env` password), not Step 1 rollback.
  - DB errors → run the isolated credential probe (Phase 1 `dbcheck.js`) against `.env`; do not edit `.env` blindly.
  - Image regression (unexpected) → `bash infrastructure/deployment/rollback.sh c0c8c9281fae453d7ea405e93b54a319d3f3d648` (recreates backend/worker/frontend on the previous verified tag; separate approval).

## Step 4 — Let the frontend recover naturally

```bash
for i in $(seq 1 12); do s=$(docker inspect stockwatch-frontend --format '{{.State.Health.Status}}'); echo "$(date -u +%T) frontend=$s"; [ "$s" = healthy ] && break; sleep 10; done
curl -s -o /dev/null -w 'port 80 /api/health -> %{http_code}\n' -m 10 http://localhost/api/health
```

- **Expected:** `healthy` within 10–60 s. The frontend healthcheck proxies to `http://backend:4000`; the recreated backend keeps the `backend` DNS alias on `stockwatch-network`. No action required.
- **Only if** still unhealthy after 2 minutes **and** the cause is the frontend itself (not backend): `"${DC[@]}" up -d --no-deps --force-recreate --pull never frontend` — ~5–10 s outage on port 80. Separate approval.
- **Rollback:** none needed (read-only observation).

## Step 5 — Validate

```bash
# API and dependencies (via the public entry point on port 80)
curl -s -m 10 http://localhost/api/health | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["status"],d["dependencies"])'
curl -s -m 10 -o /dev/null -w 'inventory -> %{http_code}\n' http://localhost/api/inventory
for p in inventory stock-checks alerts; do echo "$p count: $(curl -s -m 10 http://localhost/api/$p | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"; done
# Worker (deployed 1cc73a2 worker has no healthcheck and no DB startup check — logs + job processing are the evidence)
docker logs --since 10m stockwatch-worker 2>&1 | grep -E 'Connected to Redis|active and consuming|rror' | tail -5
# Redis
echo "clients: $(rnew INFO clients | grep -E '^connected_clients' | tr -d '\r')"; rnew CLIENT LIST | grep -oE 'name=[^ ]*' | sort | uniq -c
# Secret leak scan (counts only)
for c in stockwatch-backend stockwatch-worker stockwatch-frontend; do echo "$c url-leaks=$(docker logs --since 15m $c 2>&1 | grep -cE 'postgres(ql)?://')"; done
```

Expected: health `ok` with database and redis `connected`; inventory 200 with ≥5 items; worker log shows Redis connection; leak counts 0.

**Queue processing check — WRITES to production** (creates one `StockCheck` row and one alert row per low-stock item). Requires explicit approval:

```bash
ID=$(curl -s -m 10 -X POST http://localhost/api/stock-checks | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
for i in $(seq 1 30); do st=$(curl -s -m 10 http://localhost/api/stock-checks/$ID | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["status"],d.get("totalChecked"),d.get("lowStockCount"))'); echo "$(date -u +%T) $st"; case $st in COMPLETED*|FAILED*) break;; esac; sleep 2; done
docker logs --since 2m stockwatch-worker 2>&1 | grep -E 'Job .* (active|completed)'
```

- **Impact:** one additional stock check record + alerts (the normal effect of the product's primary action). **Rollback:** not required; records are legitimate history. Deleting them would be destructive SQL and is not proposed.

## Step 6 — Controlled Redis recreation (persist the new startup configuration)

Separate approval and maintenance moment, same session as Step 1.

```bash
# 6a. Gate + evidence
echo "wait=$(rnew LLEN bull:stock-check:wait) active=$(rnew LLEN bull:stock-check:active)"   # abort if > 0
rnew --scan | grep -v stalled-check | sort > "$EVID/pre6-keys.txt"; wc -l < "$EVID/pre6-keys.txt"
rnew GET bull:stock-check:id | tee "$EVID/pre6-jobid.txt"
rnew BGREWRITEAOF; sleep 3; rnew INFO persistence | grep -E 'aof_rewrite_in_progress|aof_last_bgrewrite_status' | tr -d '\r'
docker run --rm -v stockwatch_redis_data:/data:ro -v "$EVID":/backup redis:7-alpine tar -czf /backup/redis-data-pre6.tgz -C /data .

# 6b. Recreate Redis only (same named volume stockwatch_redis_data; new env + fixed healthcheck)
"${DC[@]}" up -d --no-deps --force-recreate redis
for i in $(seq 1 30); do s=$(docker inspect stockwatch-redis --format '{{.State.Health.Status}}'); echo "$(date -u +%T) redis=$s"; [ "$s" = healthy ] && break; sleep 2; done

# 6c. Verify data and clients
rnew --scan | grep -v stalled-check | sort | diff - "$EVID/pre6-keys.txt" && echo "persistent keys identical"
echo "job id counter: $(rnew GET bull:stock-check:id) (before: $(cat "$EVID/pre6-jobid.txt"))"
echo "container-env password: $(rold PING 2>&1 | grep -oE 'PONG|WRONGPASS|NOAUTH' | sort -u | tr '\n' ' ')"   # env now holds the NEW password: expect PONG
sleep 10; curl -s -m 10 http://localhost/api/health | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["status"],d["dependencies"])'
docker logs --since 2m stockwatch-worker 2>&1 | grep -E 'Reconnecting|Connected to Redis' | tail -3
```

- **Impact:** Redis restarts on the same volume; AOF (`appendfsync everysec`) and the pre-recreate `BGREWRITEAOF` preserve the dataset. backend/worker reconnect automatically (`retryStrategy`, verified in rehearsal).
- **Expected downtime:** Redis 5–10 s (rehearsal 6 s). During the window `/api/health` returns 503 and a `POST /api/stock-checks` would be recorded as `FAILED` (enqueue error path) — schedule when no checks are being submitted.
- **Rollback:**
  - Container fails to start → `docker logs stockwatch-redis`; the volume is unchanged, fix forward and re-run 6b.
  - Data mismatch (unexpected) → **destructive, separate approval**: `"${DC[@]}" stop redis`, then restore `$EVID/redis-data-pre6.tgz` into `stockwatch_redis_data` (`docker run --rm -v stockwatch_redis_data:/data -v "$EVID":/backup redis:7-alpine sh -c 'find /data -mindepth 1 -delete && tar -xzf /backup/redis-data-pre6.tgz -C /data'`), then `"${DC[@]}" up -d --no-deps redis`.
  - Reverting to the old password is not recommended after Step 3 (backend/worker use the new one).

## After recovery

- Record timestamps and outputs from `$EVID` in `docs/dr-progress-log.md`.
- `.current_tag` remains `1cc73a2…` (unchanged image).
- The running images still do **not** contain commits `1264b3a`/`3691918`; those reach production only through the normal PR → `main` → CI → `deploy.sh` path after approval.
- **Recurrence risk:** if RDS uses Secrets Manager–managed master-password rotation, this outage will recur on the next rotation. Confirm with read-only AWS access (`docs/aws/iam-access-requirements.md`); long-term fix is a dedicated application DB role (see `docs/disaster-recovery-design.md`).
