#!/usr/bin/env bash
set -Eeuo pipefail
# ==========================================================================
# StockWatch disaster simulation (isolated, zero cost).
#
# Builds a two-"region" environment on a private Docker network:
#   "sydney":    PostgreSQL 16 primary  + Redis + backend + worker (current branch)
#   "melbourne": PostgreSQL 16 hot standby (streaming replication)
# A marker writer creates inventory items through the API every ~100 ms and
# logs which writes were ACKNOWLEDGED (HTTP 201). RPO = acknowledged writes
# missing after recovery. All timestamps are wall-clock ms on this host.
#
# Scenarios: S1 app crash, S2 DB connectivity loss, S3 total Redis loss,
# S4 worker kill mid-queue, S5 region failover (dr-failover.sh, local
# provider), S6 planned failback (dr-failback.sh), S7 primary DB destroyed ->
# restore from verified backup.
#
# These are SIMULATED results on one host. They are not measurements of a
# real cross-region AWS recovery.
#
# Usage: scripts/dr-simulate.sh [--results FILE]
# ==========================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="${ROOT}/scripts/dr-simulate.sh"

# ---------------------------------------------------------------- internal entry point
# Called by the local DR provider (LOCAL_START_APP_CMD) with the state file exported.
if [[ "${1:-}" == "_start_app" ]]; then
  # shellcheck source=/dev/null
  source "$SIM_STATE"
  role="$2" db_host="$3"
  # shellcheck disable=SC2154
  docker run -d --name "${P}-redis-${role}" --network "$NET" -e REDIS_PASSWORD="$REDIS_PW" redis:7-alpine \
    sh -c 'exec redis-server --appendonly yes --requirepass "$REDIS_PASSWORD"' >/dev/null
  for app in backend worker; do
    docker run -d --name "${P}-${app}-${role}" --network "$NET" --network-alias "${app}-${role}" --init --restart unless-stopped \
      --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$SRC:/work:ro" -w /work \
      -e DATABASE_URL="postgresql://stockwatch_app:${APP_PW}@${db_host}:5432/stockwatch?schema=public" \
      -e REDIS_HOST="${P}-redis-${role}" -e REDIS_PASSWORD="$REDIS_PW" -e NODE_ENV=production \
      -e STOCK_CHECK_RECOVERY_INTERVAL_MS=3000 -e STOCK_CHECK_RECOVERY_STALE_AFTER_MS=3000 -e WORKER_HEALTH_INTERVAL_MS=2000 \
      node:22-bookworm node "apps/${app}/dist/$([[ $app == backend ]] && echo main.js || echo index.js)" >/dev/null
  done
  exit 0
fi

RESULTS="${ROOT}/docs/dr-simulation-results.md"
[[ "${1:-}" == "--results" ]] && RESULTS="$2"
RUN="$(date +%s)"; P="sw-sim-${RUN}"; NET="${P}-net"
WORK="${HOME}/.cache/sw-sim/${RUN}"; SRC="${WORK}/src"; EVID="${WORK}/evidence"
mkdir -p "$SRC" "$EVID"; chmod 700 "$WORK"
SUPER_PW="$(openssl rand -hex 16)"; APP_PW="$(openssl rand -hex 16)"; MIG_PW="$(openssl rand -hex 16)"
REPL_PW="$(openssl rand -hex 16)"; REDIS_PW="$(openssl rand -hex 16)"
SIM_STATE="${WORK}/state.env"
cat > "$SIM_STATE" <<EOF
P=$P
NET=$NET
SRC=$SRC
APP_PW=$APP_PW
REDIS_PW=$REDIS_PW
EOF
chmod 600 "$SIM_STATE"; export SIM_STATE

# Durations use the kernel's monotonic boot clock (immune to wall-clock adjustments),
# 10 ms resolution. Wall-clock times appear only in log lines.
now() { awk '{printf "%d\n", $1 * 1000}' /proc/uptime; }
dur() { local d=$(( $2 - $1 )); (( d >= 0 )) && echo "$d" || echo "ANOMALY(${d})"; }
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S.%3N)" "$*" | tee -a "$EVID/sim.log"; }
cleanup() {
  local rc=$?
  log "cleanup"
  if [[ -d "$EVID" ]]; then
    KEEP="${HOME}/stockwatch-dr-evidence/sim-${RUN}"; mkdir -p "$KEEP" && chmod 700 "$KEEP"
    cp -r "$EVID"/. "$KEEP"/ 2>/dev/null || true
    echo "evidence preserved: ${KEEP}"
  fi
  docker ps -a --format '{{.Names}}' | grep "^${P}-" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  if [[ -d "$WORK" ]]; then
    docker run --rm -v "$WORK:/w" alpine:latest sh -c 'rm -rf /w/src /w/pgbackup /w/evidence' >/dev/null 2>&1 || true
    rm -rf "${WORK:?}"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- helpers
psql_c() { docker exec -i "$1" psql -U postgres -d stockwatch -tAq -v ON_ERROR_STOP=1 -c "$2"; }
client() { docker exec "${P}-client" "$@"; }
health_code() { client curl -s -o /dev/null -m 2 -w '%{http_code}' "http://$1:4000/api/health" 2>/dev/null || echo 000; }
wait_health() { # wait_health <host> <want:200|non200> <timeout_s> -> prints ms timestamp when reached
  local deadline=$(( $(date +%s) + $3 )) c
  while (( $(date +%s) < deadline )); do
    c="$(health_code "$1")"
    if [[ "$2" == 200 && "$c" == 200 ]] || [[ "$2" == non200 && "$c" != 200 ]]; then now; return 0; fi
    sleep 0.2
  done
  return 1
}
api() { client curl -s -m 5 "$@"; }
count_status() { psql_c "$1" "SELECT count(*) FROM stock_checks WHERE status = '$2'"; }

marker_start() { # marker_start <api-host>  (target set and stop flag cleared BEFORE the loop starts)
  client bash -c "echo '$1' > /tmp/marker.target; rm -f /tmp/marker.stop"
  docker exec -d "${P}-client" bash -c "
    i=\$(cat /tmp/marker.seq 2>/dev/null || echo 0)
    while [ ! -f /tmp/marker.stop ]; do
      i=\$((i+1)); echo \$i > /tmp/marker.seq
      t=\$(date +%s%3N)
      code=\$(curl -s -o /dev/null -m 2 -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
        -d '{\"name\":\"marker\",\"sku\":\"MARKER-'\$i'\",\"category\":\"dr\",\"quantity\":5,\"minQuantity\":10}' \
        http://\$(cat /tmp/marker.target):4000/api/inventory)
      echo \"\$i \$t \$code\" >> /tmp/markers.log
      sleep 0.1
    done"
}
marker_target() { client bash -c "echo '$1' > /tmp/marker.target"; }
marker_stop() { client touch /tmp/marker.stop; sleep 0.5; }
# RPO: acknowledged (201) markers missing from the given database.
rpo_check() { # rpo_check <db-container> -> "acked=N missing=M"
  client cat /tmp/markers.log > "$EVID/markers.log"
  psql_c "$1" "SELECT substr(sku, 8) FROM inventory_items WHERE sku LIKE 'MARKER-%'" > "$EVID/present.txt"
  python3 - "$EVID/markers.log" "$EVID/present.txt" <<'PY'
import sys
acked = {l.split()[0] for l in open(sys.argv[1]) if len(l.split()) == 3 and l.split()[2] == "201"}
present = {l.strip() for l in open(sys.argv[2]) if l.strip()}
missing = sorted(acked - present, key=int)
print(f"acked={len(acked)} missing={len(missing)}" + (f" (first missing seq {missing[0]}, last {missing[-1]})" if missing else ""))
PY
}
declare -a ROWS=()
row() { ROWS+=("$*"); log "RESULT | $*"; }

# ---------------------------------------------------------------- build
log "Run ${RUN}: preparing working tree and dependencies"
(cd "$ROOT" && git ls-files -co --exclude-standard -z | grep -zv '^node_modules/' | tar --null -T - -cf -) | tar -xf - -C "$SRC"
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e CI=true -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 -e COREPACK_HOME=/work/.corepack \
  -v "$SRC:/work" -w /work node:22-bookworm bash -c 'set -o pipefail; mkdir -p /tmp/bin && corepack enable --install-directory /tmp/bin && export PATH=/tmp/bin:$PATH &&
  pnpm install --frozen-lockfile >/dev/null 2>&1 && pnpm db:build >/dev/null 2>&1 && pnpm --filter @stockwatch/backend build >/dev/null 2>&1 && pnpm --filter @stockwatch/worker build >/dev/null 2>&1 && echo build-ok' | tail -1

log "Creating isolated network, PostgreSQL primary + streaming standby"
docker network create --internal "$NET" >/dev/null
docker run -d --name "${P}-pg-sydney" --network "$NET" -e POSTGRES_PASSWORD="$SUPER_PW" -e POSTGRES_DB=stockwatch postgres:16-alpine \
  postgres -c wal_level=replica -c max_wal_senders=10 -c hot_standby=on -c wal_keep_size=256MB >/dev/null
for _ in $(seq 1 30); do docker exec "${P}-pg-sydney" pg_isready -U postgres -q && break; sleep 1; done; sleep 2
psql_c "${P}-pg-sydney" "CREATE ROLE replicator REPLICATION LOGIN PASSWORD '${REPL_PW}'" >/dev/null
docker exec "${P}-pg-sydney" sh -c 'echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"'
psql_c "${P}-pg-sydney" "SELECT pg_reload_conf()" >/dev/null

docker run --rm -i --network "$NET" -e PGPASSWORD="$SUPER_PW" postgres:16-alpine \
  psql -h "${P}-pg-sydney" -U postgres -d stockwatch -q -v ON_ERROR_STOP=1 -f - < "${SRC}/packages/database/prisma/migrations/20261106000000_init/migration.sql" >/dev/null
ADMIN_DATABASE_URL="postgresql://postgres:${SUPER_PW}@${P}-pg-sydney:5432/stockwatch" APP_DB_PASSWORD="$APP_PW" MIGRATOR_DB_PASSWORD="$MIG_PW" \
  bash "${SRC}/infrastructure/deployment/db-roles.sh" --docker-network "$NET" --transfer-ownership --apply >/dev/null
log "schema migrated; roles provisioned (app runs as stockwatch_app)"

start_standby() { # start_standby <name> <upstream>
  docker run -d --name "$1" --network "$NET" -e PGPASSWORD="$REPL_PW" postgres:16-alpine sh -c "
    rm -rf /var/lib/postgresql/data/* && pg_basebackup -h $2 -U replicator -D /var/lib/postgresql/data -R -X stream -c fast &&
    chown -R postgres:postgres /var/lib/postgresql/data && chmod 700 /var/lib/postgresql/data && exec su-exec postgres postgres -c hot_standby=on" >/dev/null
  for _ in $(seq 1 60); do [[ "$(docker exec "$1" psql -U postgres -d stockwatch -tAq -c 'SELECT pg_is_in_recovery()' 2>/dev/null)" == t ]] && return 0; sleep 1; done
  return 1
}
start_standby "${P}-pg-melbourne" "${P}-pg-sydney" && log "melbourne standby streaming"

docker run -d --name "${P}-client" --network "$NET" node:22-bookworm sleep infinity >/dev/null
bash "$SELF" _start_app sydney "${P}-pg-sydney"
SYD="${P}-backend-sydney"
wait_health "$SYD" 200 120 >/dev/null || { log "sydney app failed to start"; docker logs "$SYD" | tail -20; exit 1; }
log "sydney app healthy"
api -X POST -H 'Content-Type: application/json' -d '{"name":"Seed low","sku":"SEED-1","category":"s","quantity":1,"minQuantity":5}' "http://${SYD}:4000/api/inventory" >/dev/null
api -X POST -H 'Content-Type: application/json' -d '{"name":"Seed ok","sku":"SEED-2","category":"s","quantity":50,"minQuantity":5}' "http://${SYD}:4000/api/inventory" >/dev/null
# Functional gate: health alone is not proof (it only checks connectivity). Require real writes.
[[ "$(psql_c "${P}-pg-sydney" "SELECT count(*) FROM inventory_items WHERE sku LIKE 'SEED-%'")" == 2 ]] \
  || { log "ABORT: seed writes through the API did not persist (schema/privileges?)"; docker logs "$SYD" 2>&1 | tail -20; exit 1; }
[[ "$(api -o /dev/null -w '%{http_code}' -X POST "http://${SYD}:4000/api/stock-checks")" == 201 ]] || { log "ABORT: enqueue failed"; exit 1; }
for _ in $(seq 1 40); do [[ "$(count_status "${P}-pg-sydney" COMPLETED)" == 1 ]] && break; sleep 0.5; done
[[ "$(count_status "${P}-pg-sydney" COMPLETED)" == 1 ]] || { log "ABORT: worker did not complete the gate stock check"; exit 1; }
log "functional gate passed: API writes persisted, stock check completed end-to-end as stockwatch_app"
marker_start "$SYD"; sleep 3
[[ "$(client sh -c "awk '\$3==201' /tmp/markers.log | wc -l")" -gt 5 ]] || { log "ABORT: marker writes are not being acknowledged"; exit 1; }

# ================================================================ S1 application crash
log "S1: application process crash (SIGKILL backend; Docker restart policy)"
T0="$(now)"; client true; docker exec "$SYD" sh -c 'kill -9 $(pgrep -f "node apps/backend") 2>/dev/null || pkill -9 node' || true
TD="$(wait_health "$SYD" non200 10 || echo "$T0")"; TR="$(wait_health "$SYD" 200 60)"
sleep 1; r="$(rpo_check "${P}-pg-sydney")"
row "S1 | App process crash (backend SIGKILL) | Docker restart policy | $(dur "$T0" "$TD") | $(dur "$T0" "$TR") | ${r} | simulated"

# ================================================================ S2 database connectivity loss
log "S2: database connectivity loss (primary DB disconnected from network for 15 s)"
T0="$(now)"; docker network disconnect "$NET" "${P}-pg-sydney"
TD="$(wait_health "$SYD" non200 20)"; sleep 15; TREC="$(now)"; docker network connect "$NET" "${P}-pg-sydney"
TR="$(wait_health "$SYD" 200 90)"; sleep 1; r="$(rpo_check "${P}-pg-sydney")"
row "S2 | DB connectivity lost 15 s | automatic reconnect (Prisma pool) | $(dur "$T0" "$TD") | $(dur "$T0" "$TR") (recovery $(dur "$TREC" "$TR") after restore) | ${r} | simulated"

# ================================================================ S3 total Redis loss
log "S3: total Redis loss with queued checks (worker stopped, Redis container + data destroyed)"
docker stop "${P}-worker-sydney" >/dev/null
for _ in $(seq 1 10); do api -X POST "http://${SYD}:4000/api/stock-checks" >/dev/null; done
pending_before="$(count_status "${P}-pg-sydney" PENDING)"
T0="$(now)"; docker rm -fv "${P}-redis-sydney" >/dev/null
TD="$(wait_health "$SYD" non200 20)"
docker run -d --name "${P}-redis-sydney" --network "$NET" -e REDIS_PASSWORD="$REDIS_PW" redis:7-alpine \
  sh -c 'exec redis-server --appendonly yes --requirepass "$REDIS_PASSWORD"' >/dev/null
TREC="$(now)"; docker start "${P}-worker-sydney" >/dev/null
for _ in $(seq 1 120); do [[ "$(count_status "${P}-pg-sydney" PENDING)$(count_status "${P}-pg-sydney" PROCESSING)" == 00 ]] && break; sleep 0.5; done
TR="$(now)"; completed="$(psql_c "${P}-pg-sydney" "SELECT count(*) FROM stock_checks WHERE status='COMPLETED'")"
dupes="$(psql_c "${P}-pg-sydney" "SELECT count(*) FROM (SELECT \"stockCheckId\", \"inventoryItemId\" FROM stock_alerts GROUP BY 1,2 HAVING count(*) > 1) d")"
row "S3 | Redis destroyed (no backup used) with ${pending_before} PENDING checks | empty Redis + PostgreSQL-backed recovery | $(dur "$T0" "$TD") | queue restored $(dur "$TREC" "$TR") after Redis back; total $(dur "$T0" "$TR") | lost checks=$(count_status "${P}-pg-sydney" PENDING), completed=${completed}, duplicate alerts=${dupes} | simulated"

# ================================================================ S4 worker interruption
log "S4: worker SIGKILL while 30 checks are queued"
for _ in $(seq 1 30); do api -X POST "http://${SYD}:4000/api/stock-checks" >/dev/null & done; wait
T0="$(now)"; docker kill -s KILL "${P}-worker-sydney" >/dev/null || true
sleep 5; TREC="$(now)"; docker start "${P}-worker-sydney" >/dev/null
for _ in $(seq 1 240); do [[ "$(count_status "${P}-pg-sydney" PENDING)$(count_status "${P}-pg-sydney" PROCESSING)" == 00 ]] && break; sleep 0.5; done
TR="$(now)"
bad_counts="$(psql_c "${P}-pg-sydney" "SELECT count(*) FROM stock_checks c WHERE c.status='COMPLETED' AND c.\"lowStockCount\" <> (SELECT count(*) FROM stock_alerts a WHERE a.\"stockCheckId\" = c.id)")"
row "S4 | Worker SIGKILL with 30 queued checks (down 5 s) | restart + BullMQ stalled-job recovery | n/a (injected) | all drained $(dur "$TREC" "$TR") after restart; total $(dur "$T0" "$TR") | non-terminal=$(( $(count_status "${P}-pg-sydney" PENDING) + $(count_status "${P}-pg-sydney" PROCESSING) )), alert/lowStockCount mismatches=${bad_counts} | simulated"

# ================================================================ S5 region failover
log "S5: primary region loss -> dr-failover.sh --provider local --execute"
for _ in $(seq 1 5); do api -X POST "http://${SYD}:4000/api/stock-checks" >/dev/null; done   # in-flight work at failure
lag_before="$(psql_c "${P}-pg-sydney" "SELECT coalesce((SELECT state || ', ' || pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) || ' bytes behind primary' FROM pg_stat_replication LIMIT 1), 'NOT STREAMING')")"
T0="$(now)"
docker rm -fv "${P}-pg-sydney" "${P}-backend-sydney" "${P}-worker-sydney" "${P}-redis-sydney" >/dev/null   # whole "region" gone
TD="$(now)"  # detection is immediate here; Route 53 (30 s x 3) would add ~90 s
CONFIRM="FAILOVER-$(date -u +%Y%m%d)"
LOCAL_PRIMARY_DB="${P}-pg-sydney" LOCAL_STANDBY_DB="${P}-pg-melbourne" LOCAL_PRIMARY_APP="${P}-backend-sydney ${P}-worker-sydney" \
LOCAL_START_APP_CMD="bash '${SELF}' _start_app melbourne '${P}-pg-melbourne'" LOCAL_HEALTH_URL="http://backend-melbourne:4000/api/health" \
DR_HEALTH_CMD="docker exec ${P}-client curl -s -m 2 http://${P}-backend-melbourne:4000/api/health" \
  bash "${SRC}/infrastructure/deployment/dr/dr-failover.sh" --provider local --evidence-dir "$EVID/failover" --execute --confirm "$CONFIRM" --force-unknown-lag > "$EVID/failover.out" 2>&1 || true
MEL="${P}-backend-melbourne"
TR="$(wait_health "$MEL" 200 180)"
marker_target "$MEL"; sleep 2
for _ in $(seq 1 120); do [[ "$(count_status "${P}-pg-melbourne" PENDING)$(count_status "${P}-pg-melbourne" PROCESSING)" == 00 ]] && break; sleep 0.5; done
TQ="$(now)"; r="$(rpo_check "${P}-pg-melbourne")"
row "S5 | Primary region lost (DB, app, Redis destroyed) | dr-failover.sh: promote standby, start secondary app, empty Redis + recovery | $(dur "$T0" "$TD") (simulated; +~90 s with Route 53) | $(dur "$T0" "$TR"); queue drained $(dur "$T0" "$TQ") | ${r}; standby at T0: ${lag_before} | simulated"
grep -E 'EXEC|MARK|ABORT' "$EVID/failover.out" | sed 's/^/    /' >> "$EVID/sim.log" || true

# ================================================================ S6 planned failback
log "S6: planned failback -> dr-failback.sh --provider local --execute"
T0="$(now)"
LOCAL_STANDBY_DB="${P}-pg-melbourne" LOCAL_REVERSE_DB="${P}-pg-sydney2" LOCAL_NETWORK="$NET" LOCAL_REPL_PASSWORD="$REPL_PW" \
LOCAL_SECONDARY_APP="${P}-backend-melbourne ${P}-worker-melbourne" \
LOCAL_START_PRIMARY_APP_CMD="bash '${SELF}' _start_app sydney2 '${P}-pg-sydney2'" \
PRIMARY_HEALTH_URL="http://backend-sydney2:4000/api/health" DR_HEALTH_CMD="docker exec ${P}-client curl -s -m 2 http://${P}-backend-sydney2:4000/api/health" \
  bash "${SRC}/infrastructure/deployment/dr/dr-failback.sh" --provider local --evidence-dir "$EVID/failback" --execute --confirm "FAILBACK-$(date -u +%Y%m%d)" > "$EVID/failback.out" 2>&1 || true
SYD2="${P}-backend-sydney2"
TR="$(wait_health "$SYD2" 200 180)"; marker_target "$SYD2"; sleep 2
r="$(rpo_check "${P}-pg-sydney2")"
TW="$(python3 - "$EVID/failback/marks.env" <<'PY'
import sys; m=dict(l.strip().split("=") for l in open(sys.argv[1]))
print(int(m["T_PROMOTED"]) - int(m["T_WRITES_STOPPED_START"]))
PY
)"
row "S6 | Planned failback to primary region | dr-failback.sh: reseed, lag 0, stop writers, promote, start primary app | n/a (planned) | $(dur "$T0" "$TR") end-to-end; write unavailability (writers stopped -> promoted) ${TW} | ${r} | simulated"

# ================================================================ S7 database destroyed -> restore from backup
log "S7: primary database destroyed -> restore from verified logical backup"
marker_stop; sleep 1
SYD2DB="${P}-pg-sydney2"
mkdir -p "$WORK/pgbackup"
SOURCE_DATABASE_URL="postgresql://postgres:${SUPER_PW}@${SYD2DB}:5432/stockwatch" \
  bash "${SRC}/infrastructure/deployment/backup/pg-backup-verify.sh" --dest "$WORK/pgbackup" --docker-network "$NET" > "$EVID/backup.out" 2>&1
BK="$(find "$WORK/pgbackup" -mindepth 1 -maxdepth 1 -type d -name '20*Z' | head -1)"
SEQ_AT_BACKUP="$(client cat /tmp/marker.seq)"; T_BACKUP="$(now)"
marker_start "$SYD2"; sleep 3   # writes after the backup will be lost (RPO = backup age)
ACKED_AFTER="$(client sh -c "awk -v s=${SEQ_AT_BACKUP} '\$1>s && \$3==201' /tmp/markers.log | wc -l")"
[[ "$ACKED_AFTER" -gt 0 ]] || { log "ABORT: no writes acknowledged after the backup; S7 would not measure RPO"; exit 1; }
T0="$(now)"; docker rm -fv "$SYD2DB" >/dev/null
TD="$(wait_health "$SYD2" non200 20)"
docker run -d --name "${P}-pg-restored" --network "$NET" -e POSTGRES_PASSWORD="$SUPER_PW" -e POSTGRES_DB=stockwatch postgres:16-alpine >/dev/null
for _ in $(seq 1 30); do docker exec "${P}-pg-restored" pg_isready -U postgres -q && break; sleep 1; done; sleep 1
ADMIN_DATABASE_URL="postgresql://postgres:${SUPER_PW}@${P}-pg-restored:5432/stockwatch" APP_DB_PASSWORD="$APP_PW" MIGRATOR_DB_PASSWORD="$MIG_PW" \
  bash "${SRC}/infrastructure/deployment/db-roles.sh" --docker-network "$NET" --apply >/dev/null 2>&1 || true   # roles are cluster-level: recreate
TARGET_DATABASE_URL="postgresql://postgres:${SUPER_PW}@${P}-pg-restored:5432/stockwatch" \
  bash "${SRC}/infrastructure/deployment/backup/pg-restore.sh" --backup "$BK" --confirm "RESTORE-$(date -u +%Y%m%d)" --docker-network "$NET" > "$EVID/restore.out" 2>&1
ADMIN_DATABASE_URL="postgresql://postgres:${SUPER_PW}@${P}-pg-restored:5432/stockwatch" \
  bash "${SRC}/infrastructure/deployment/db-roles.sh" --docker-network "$NET" --transfer-ownership --apply >/dev/null
docker rm -fv "${P}-backend-sydney2" "${P}-worker-sydney2" "${P}-redis-sydney2" >/dev/null
bash "$SELF" _start_app sydney3 "${P}-pg-restored"
TR="$(wait_health "${P}-backend-sydney3" 200 180)"
marker_stop
r="$(rpo_check "${P}-pg-restored")"
row "S7 | Primary DB destroyed | restore verified logical backup into new instance, re-provision roles, restart app | $(dur "$T0" "$TD") | $(dur "$T0" "$TR") | ${r}; expected loss = ${ACKED_AFTER} writes acknowledged after the backup; RPO window = backup age at failure $(dur "$T_BACKUP" "$T0") ms | simulated"

# ---------------------------------------------------------------- report
{
  echo "# DR Simulation Results (isolated, simulated)"
  echo
  echo "**Run:** $(date -u +%FT%TZ) on the primary EC2 host, isolated Docker network \`${NET}\` (removed after the run)."
  echo "**Nature of results:** SIMULATED on a single host with Docker containers standing in for regions."
  echo "They measure the application, queue and database-recovery mechanics and the automation, NOT AWS cross-region"
  echo "behaviour (RDS promotion time, cross-region replication lag, Route 53 propagation). No AWS resources were used."
  echo
  echo "**Workload during scenarios:** marker writer creating an inventory item every ~100 ms via the API;"
  echo "RPO counts **acknowledged** (HTTP 201) writes missing after recovery. Times are milliseconds from failure injection."
  echo
  echo "| ID | Failure injected | Recovery mechanism | Detection (ms) | Restoration (ms) | Data (RPO) | Kind |"
  echo "|---|---|---|---|---|---|---|"
  for r in "${ROWS[@]}"; do echo "| ${r} |"; done
  echo
  echo "## Not represented"
  echo
  echo "- RDS cross-region replica promotion time (minutes) and real replication lag; Route 53 health-check detection (~90 s) and TTL (60 s)."
  echo "- EC2 boot / image pull time for a cold DR host."
  echo "- S1 relies on Docker's restart policy; production containers use \`restart: unless-stopped\` (same mechanism)."
} > "$RESULTS"
log "results written to ${RESULTS}"
cat "$RESULTS"
