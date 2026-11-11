#!/usr/bin/env bash
set -Eeuo pipefail
# ==========================================================================
# StockWatch DR demonstration — LOCAL SIMULATION on one host (zero cost).
#
# A step-by-step, narratable version of scenarios S5/S6 of scripts/dr-simulate.sh,
# for the assessment video. Everything runs in disposable Docker containers on an
# internal (no internet, no published ports) network named sw-demo-<run>-net:
#
#   "sydney" site    : PostgreSQL 16 primary + Redis + backend + worker
#   "melbourne" site : PostgreSQL 16 hot standby (streaming replication)
#   front door       : simulated DNS record (file "app=primary|secondary"), written by
#                      dr-failover.sh / dr-failback.sh through the local provider's
#                      LOCAL_DNS_FILE hook — the role Route 53 failover plays in AWS
#   client           : traffic generator; resolves the front door before EVERY request
#
# It reuses the real automation: db-roles.sh, dr-failover.sh, dr-failback.sh (local
# provider) and dr-simulate.sh _start_app. It never touches the production containers
# (stockwatch-*), RDS, AWS or the production .env. Credentials are random, per run,
# and exist only in the state directory (mode 700) and the disposable containers.
#
# This is NOT a cross-region AWS failover. See docs/assessment/12-video-demonstration-runbook.md.
#
# Usage: scripts/dr-demo.sh <command>
#   up            build and start both sites, replication, client (1-3 min)
#   seed          create the known test dataset (DEMO-001..010 + one stock check); save baseline
#   traffic start|stop|show [n]|watch
#   status        sites, database roles, replication, front door, per-database checksums
#   disaster      destroy the whole sydney site, then run the health-check detector
#   failover      operator step: dr-failover.sh --execute (promote, start DR app, switch front door)
#   verify        integrity on the active database (counts, checksum, known IDs, RPO)
#   write-check   write-read + stock-check
#   write-read    write + read-back through the front door
#   stock-check   end-to-end stock check on the active site (API -> queue -> worker -> database)
#   selfcheck     prove the environment is the isolated simulation (prefix, internal network, no ports)
#   failback      dr-failback.sh --execute (re-seed sydney from melbourne, switch back)
#   report        measured timings of this run
#   down          remove all demo containers and the network (evidence is kept)
#
# Exit codes: 0 ok; 1 failure; 2 wrong order / no environment;
#             3 (verify only) seed data intact but acknowledged writes missing (RPO > 0).
# ==========================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="${STOCKWATCH_DEMO_DIR:-${HOME}/.cache/sw-demo}"
STATE="${D}/state.env"
DNS_DIR="${D}/dns"

now_ms() { date +%s%3N; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die() { echo "ERROR: $1" >&2; exit "${2:-1}"; }
fmt_ms() { printf '%(%H:%M:%S)T.%03d' "$(( $1 / 1000 ))" "$(( $1 % 1000 ))"; }
export TZ=UTC

load() {
  [[ -f "$STATE" ]] || die "no demo environment (run: scripts/dr-demo.sh up)" 2
  # shellcheck source=/dev/null
  source "$STATE"
}
set_state() { # set_state KEY VALUE (replace or append)
  local k="$1" v="$2"
  if grep -q "^${k}=" "$STATE"; then sed -i "s|^${k}=.*|${k}=${v}|" "$STATE"; else echo "${k}=${v}" >> "$STATE"; fi
  printf -v "$k" '%s' "$v"
}
psql_c() { docker exec -i "$1" psql -U postgres -d stockwatch -tAq -v ON_ERROR_STOP=1 -c "$2"; }
client() { docker exec "${P}-client" "$@"; }
zone() { cut -d= -f2 "${DNS_DIR}/zone"; }
front_door_host() { local z; z="$(zone)"; grep "^${z}=" "${DNS_DIR}/hosts" | cut -d= -f2; }
api() { # api <METHOD> <path> [json] -> body (via the front door)
  local h; h="$(front_door_host)"
  if [[ -n "${3:-}" ]]; then client curl -s -m 5 -X "$1" -H 'Content-Type: application/json' -d "$3" "http://${h}:4000$2"
  else client curl -s -m 5 -X "$1" "http://${h}:4000$2"; fi
}
health() { local c; c="$(client curl -s -o /dev/null -m 2 -w '%{http_code}' "http://$1:4000/api/health" 2>/dev/null || true)"; echo "${c:-000}"; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

# Integrity fingerprint of the seed dataset: every DEMO item, the seed stock check and its alerts.
seed_checksum() { # seed_checksum <db-container>
  psql_c "$1" "SELECT md5(coalesce(string_agg(x, E'\n' ORDER BY x), '')) FROM (
    SELECT 'item|'||id||'|'||sku||'|'||name||'|'||category||'|'||quantity||'|'||\"minQuantity\"||'|'||\"createdAt\" FROM inventory_items WHERE sku LIKE 'DEMO-%'
    UNION ALL SELECT 'check|'||id||'|'||status||'|'||\"totalChecked\"||'|'||\"lowStockCount\" FROM stock_checks WHERE id = '${SEED_CHECK_ID}'
    UNION ALL SELECT 'alert|'||id||'|'||\"inventoryItemId\"||'|'||quantity||'|'||\"minQuantity\" FROM stock_alerts WHERE \"stockCheckId\" = '${SEED_CHECK_ID}'
  ) s(x)"
}

# ---------------------------------------------------------------------------------------- up
cmd_up() {
  [[ ! -f "$STATE" ]] || die "a demo environment already exists (${STATE}); run: scripts/dr-demo.sh down" 2
  local RUN; RUN="$(date +%s)"
  P="sw-demo-${RUN}"; NET="${P}-net"; SRC="${D}/src"; EVID="${STOCKWATCH_DEMO_EVIDENCE_ROOT:-${HOME}/stockwatch-dr-evidence}/demo-${RUN}"
  mkdir -p "$D" "$SRC" "$DNS_DIR" "$EVID"; chmod 700 "$D" "$EVID"
  cat > "$STATE" <<EOF
RUN=${RUN}
P=${P}
NET=${NET}
SRC=${SRC}
EVID=${EVID}
SUPER_PW=$(openssl rand -hex 16)
REPL_PW=$(openssl rand -hex 16)
APP_PW=$(openssl rand -hex 16)
MIG_PW=$(openssl rand -hex 16)
REDIS_PW=$(openssl rand -hex 16)
PHASE=starting
ACTIVE_DB=${P}-pg-sydney
EOF
  chmod 600 "$STATE"; load
  printf 'app=primary\n' > "${DNS_DIR}/zone"
  printf 'primary=backend-sydney\nsecondary=backend-melbourne\n' > "${DNS_DIR}/hosts"

  say "Building the application from this checkout (disposable copy in ${SRC})"
  (cd "$ROOT" && git ls-files -co --exclude-standard -z | grep -zv '^node_modules/' | tar --null -T - -cf -) | tar -xf - -C "$SRC"
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e CI=true -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 -e COREPACK_HOME=/work/.corepack \
    -v "$SRC:/work" -w /work node:22-bookworm bash -c 'set -o pipefail; mkdir -p /tmp/bin && corepack enable --install-directory /tmp/bin && export PATH=/tmp/bin:$PATH &&
    pnpm install --frozen-lockfile >/dev/null 2>&1 && pnpm db:build >/dev/null 2>&1 && pnpm --filter @stockwatch/backend build >/dev/null 2>&1 && pnpm --filter @stockwatch/worker build >/dev/null 2>&1' \
    || die "application build failed"
  info "build ok"

  say "Sydney site: PostgreSQL 16 primary on internal network ${NET}"
  docker network create --internal "$NET" >/dev/null
  docker run -d --name "${P}-pg-sydney" --network "$NET" -e POSTGRES_PASSWORD="$SUPER_PW" -e POSTGRES_DB=stockwatch postgres:16-alpine \
    postgres -c wal_level=replica -c max_wal_senders=10 -c hot_standby=on -c wal_keep_size=256MB >/dev/null
  local i; for i in $(seq 1 30); do docker exec "${P}-pg-sydney" pg_isready -U postgres -q 2>/dev/null && break; sleep 1; done; sleep 2
  psql_c "${P}-pg-sydney" "CREATE ROLE replicator REPLICATION LOGIN PASSWORD '${REPL_PW}'" >/dev/null
  docker exec "${P}-pg-sydney" sh -c 'echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"'
  psql_c "${P}-pg-sydney" "SELECT pg_reload_conf()" >/dev/null
  docker run --rm -i --network "$NET" -e PGPASSWORD="$SUPER_PW" postgres:16-alpine \
    psql -h "${P}-pg-sydney" -U postgres -d stockwatch -q -v ON_ERROR_STOP=1 -f - < "${SRC}/packages/database/prisma/migrations/20261106000000_init/migration.sql" >/dev/null
  ADMIN_DATABASE_URL="postgresql://postgres:${SUPER_PW}@${P}-pg-sydney:5432/stockwatch" APP_DB_PASSWORD="$APP_PW" MIGRATOR_DB_PASSWORD="$MIG_PW" \
    bash "${SRC}/infrastructure/deployment/db-roles.sh" --docker-network "$NET" --transfer-ownership --apply >/dev/null
  info "schema migrated; stockwatch_app / stockwatch_migrator provisioned (same db-roles.sh as production)"

  say "Melbourne site: PostgreSQL 16 hot standby (pg_basebackup + streaming replication)"
  docker run -d --name "${P}-pg-melbourne" --network "$NET" -e PGPASSWORD="$REPL_PW" postgres:16-alpine sh -c "
    rm -rf /var/lib/postgresql/data/* && pg_basebackup -h ${P}-pg-sydney -U replicator -D /var/lib/postgresql/data -R -X stream -c fast &&
    chown -R postgres:postgres /var/lib/postgresql/data && chmod 700 /var/lib/postgresql/data && exec su-exec postgres postgres -c hot_standby=on" >/dev/null
  for i in $(seq 1 60); do [[ "$(psql_c "${P}-pg-melbourne" 'SELECT pg_is_in_recovery()' 2>/dev/null)" == t ]] && break; sleep 1; done
  [[ "$(psql_c "${P}-pg-melbourne" 'SELECT pg_is_in_recovery()' 2>/dev/null)" == t ]] || die "standby did not start"
  info "standby in recovery (read-only), streaming from sydney"

  say "Client (traffic generator) and sydney application"
  docker run -d --name "${P}-client" --network "$NET" -v "${DNS_DIR}:/dns:ro" node:22-bookworm sleep infinity >/dev/null
  SIM_STATE="$STATE" bash "${ROOT}/scripts/dr-simulate.sh" _start_app sydney "${P}-pg-sydney"
  for i in $(seq 1 120); do [[ "$(health backend-sydney)" == 200 ]] && break; sleep 1; done
  [[ "$(health backend-sydney)" == 200 ]] || die "sydney application did not become healthy"
  set_state PHASE primary
  info "sydney backend healthy; front door: app=primary -> backend-sydney"
  info "evidence directory: ${EVID}"
}

# ---------------------------------------------------------------------------------------- seed
cmd_seed() {
  load; [[ "$PHASE" == primary && -z "${SEED_CHECK_ID:-}" ]] || die "seed runs once, after 'up' and before 'disaster'" 2
  say "Creating the known test dataset through the API (front door -> $(front_door_host))"
  local n q body id
  : > "${D}/seed_ids.txt"
  for n in $(seq -w 1 10); do
    q=$(( 10#$n % 2 == 1 ? 2 : 40 ))   # odd items are below their minimum (10) -> alerts
    body="$(api POST /api/inventory "{\"name\":\"Demo item ${n}\",\"sku\":\"DEMO-0${n}\",\"category\":\"dr-demo\",\"quantity\":${q},\"minQuantity\":10}")"
    id="$(json 'd["id"]' <<<"$body")" || die "seed write failed: ${body:0:120}"
    echo "DEMO-0${n} ${id}" >> "${D}/seed_ids.txt"
  done
  id="$(api POST /api/stock-checks | json 'd["id"]')"
  local s=""; for _ in $(seq 1 60); do s="$(api GET "/api/stock-checks/${id}" | json 'd["status"]')"; [[ "$s" == COMPLETED || "$s" == FAILED ]] && break; sleep 0.5; done
  [[ "$s" == COMPLETED ]] || die "seed stock check did not complete (status ${s})"
  set_state SEED_CHECK_ID "$id"
  local sum; sum="$(seed_checksum "$ACTIVE_DB")"; set_state SEED_SUM "$sum"
  cp "${D}/seed_ids.txt" "${EVID}/seed_ids.txt"
  info "10 inventory items DEMO-001..DEMO-010 (odd = low stock), ids:"
  sed 's/^/     /' "${D}/seed_ids.txt" | head -3; info "  ... (all ids: ${EVID}/seed_ids.txt)"
  info "stock check ${id}: $(api GET "/api/stock-checks/${id}" | json '"status="+d["status"]+" totalChecked="+str(d["totalChecked"])+" lowStockCount="+str(d["lowStockCount"])')"
  info "seed checksum (md5 of all seed rows) on sydney primary: ${sum}"
  echo "SEED_SUM=${sum} SEED_CHECK_ID=${id} at $(date -u +%FT%TZ)" > "${EVID}/baseline.txt"
}

# ---------------------------------------------------------------------------------------- traffic
cmd_traffic() {
  load
  case "${1:-}" in
    start)
      client bash -c '[ -f /tmp/t.pid ] && kill -0 "$(cat /tmp/t.pid)" 2>/dev/null' && die "traffic already running" 2
      client rm -f /tmp/t.stop
      docker exec -d "${P}-client" bash -c '
        echo $$ > /tmp/t.pid
        i=$(cat /tmp/t.seq 2>/dev/null || echo 0)
        while [ ! -f /tmp/t.stop ]; do
          i=$((i+1)); echo $i > /tmp/t.seq
          z=$(cut -d= -f2 /dns/zone); h=$(grep "^$z=" /dns/hosts | cut -d= -f2)
          t=$(date +%s%3N)
          c=$(curl -s -o /dev/null -m 2 -w "%{http_code}" -X POST -H "Content-Type: application/json" \
            -d "{\"name\":\"traffic\",\"sku\":\"TRAFFIC-$i\",\"category\":\"dr-demo-traffic\",\"quantity\":50,\"minQuantity\":5}" \
            http://$h:4000/api/inventory)
          echo "$i $t $c $h" >> /tmp/traffic.log
          sleep 0.2
        done'
      info "traffic started: POST /api/inventory every ~0.2 s via the front door (SKU TRAFFIC-<n>)" ;;
    stop) client touch /tmp/t.stop; sleep 1; info "traffic stopped" ;;
    show) client tail -n "${2:-10}" /tmp/traffic.log | while read -r i t c h; do printf '   %s  #%-5s POST /api/inventory -> %-18s %s\n' "$(fmt_ms "$t")" "$i" "$h" "$([[ $c == 201 ]] && echo "201 Created" || echo "FAILED ($c)")"; done ;;
    watch) docker exec "${P}-client" tail -n 5 -F /tmp/traffic.log | while read -r i t c h; do printf '%s  #%-5s POST /api/inventory -> %-18s %s\n' "$(fmt_ms "$t")" "$i" "$h" "$([[ $c == 201 ]] && echo "201 Created" || echo "FAILED ($c)")"; done ;;
    *) die "usage: traffic start|stop|show [n]|watch" 2 ;;
  esac
}

# ---------------------------------------------------------------------------------------- status
cmd_status() {
  load
  say "Simulation ${P} — phase: ${PHASE}   front door: $(cat "${DNS_DIR}/zone") -> $(front_door_host)"
  local c role
  for c in "${P}-pg-sydney" "${P}-pg-melbourne" "${P}-pg-sydney2"; do
    if ! docker inspect "$c" >/dev/null 2>&1; then [[ "$c" == *sydney2 ]] || info "$(printf '%-28s' "${c#"${P}-"}") DESTROYED / absent"; continue; fi
    role="$(psql_c "$c" "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby (read-only)' ELSE 'PRIMARY (read-write)' END" 2>/dev/null || echo unreachable)"
    local tag=""
    if [[ "$c" == "$ACTIVE_DB" ]]; then tag="  <- ACTIVE (used by the front-door application)"
    elif [[ "$role" == PRIMARY* ]]; then tag="  <- RETIRED: application fenced, no client; would be rebuilt as a standby"; fi
    info "$(printf '%-28s %-22s items=%-6s seed_checksum=%s%s' "${c#"${P}-"}" "$role" "$(psql_c "$c" 'SELECT count(*) FROM inventory_items' 2>/dev/null)" "$([[ -n "${SEED_CHECK_ID:-}" ]] && seed_checksum "$c" 2>/dev/null || echo '(not seeded)')" "$tag")"
    [[ "$role" == PRIMARY* ]] && { psql_c "$c" "SELECT '     replication -> '||application_name||' state='||state||' replay_lag_bytes='||pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) FROM pg_stat_replication" 2>/dev/null || true; }
  done
  for c in sydney melbourne sydney2; do docker inspect "${P}-backend-${c}" >/dev/null 2>&1 && info "$(printf '%-28s /api/health %s' "backend-${c}" "$(health "backend-${c}")")"; done
  if [[ -n "${SEED_SUM:-}" ]]; then info "baseline seed checksum: ${SEED_SUM}"; fi
  return 0
}

# ---------------------------------------------------------------------------------------- disaster
cmd_disaster() {
  load; [[ "$PHASE" == primary ]] || die "disaster needs a healthy primary (phase is ${PHASE})" 2
  [[ -n "${SEED_CHECK_ID:-}" ]] || die "run 'seed' first" 2
  local lag; lag="$(psql_c "${P}-pg-sydney" "SELECT coalesce((SELECT state||', '||pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)||' bytes behind' FROM pg_stat_replication LIMIT 1), 'NOT STREAMING')")"
  say "DISASTER: destroying the entire sydney site (database, backend, worker, redis)"
  info "replication just before: ${lag}"
  local T0; T0="$(now_ms)"
  docker rm -fv "${P}-pg-sydney" "${P}-backend-sydney" "${P}-worker-sydney" "${P}-redis-sydney" >/dev/null
  set_state T_DISASTER "$T0"; set_state PHASE disaster
  info "$(fmt_ms "$T0")  sydney site destroyed (containers and volumes removed)"
  say "Health-check detector: probe http://backend-sydney:4000/api/health every 1 s; 3 consecutive failures = DOWN"
  local fails=0 n=0 code T_FIRST=""
  while (( n < 60 )); do
    n=$((n + 1)); code="$(health backend-sydney)"
    if [[ "$code" == 200 ]]; then fails=0; else fails=$((fails + 1)); [[ -n "$T_FIRST" ]] || T_FIRST="$(now_ms)"; fi
    info "$(fmt_ms "$(now_ms)")  probe ${n}: $([[ $code == 200 ]] && echo "200 healthy" || echo "FAILED (${code})")  consecutive failures=${fails}"
    (( fails >= 3 )) && break
    sleep 1
  done
  (( fails >= 3 )) || die "primary did not fail health checks"
  local TD; TD="$(now_ms)"; set_state T_DETECTED "$TD"
  info "PRIMARY DOWN detected after $(( TD - T0 )) ms -> page the operator: run 'scripts/dr-demo.sh failover'"
  echo "replication_at_disaster=${lag}" >> "${EVID}/measurements.txt"
}

# ---------------------------------------------------------------------------------------- failover
cmd_failover() {
  load; [[ "$PHASE" == disaster ]] || die "failover follows 'disaster' (phase is ${PHASE})" 2
  say "FAILOVER (operator-approved): dr-failover.sh --provider local --execute --confirm FAILOVER-$(date -u +%Y%m%d)"
  local TS; TS="$(now_ms)"; set_state T_FAILOVER_START "$TS"
  LOCAL_PRIMARY_DB="${P}-pg-sydney" LOCAL_STANDBY_DB="${P}-pg-melbourne" LOCAL_PRIMARY_APP="${P}-backend-sydney ${P}-worker-sydney" \
  LOCAL_START_APP_CMD="SIM_STATE='${STATE}' bash '${ROOT}/scripts/dr-simulate.sh' _start_app melbourne '${P}-pg-melbourne'" \
  LOCAL_HEALTH_URL="http://backend-melbourne:4000/api/health" LOCAL_DNS_FILE="${DNS_DIR}/zone" \
  DR_HEALTH_CMD="docker exec ${P}-client curl -s -m 2 http://backend-melbourne:4000/api/health" \
    bash "${ROOT}/infrastructure/deployment/dr/dr-failover.sh" --provider local --evidence-dir "${EVID}/failover" \
      --execute --confirm "FAILOVER-$(date -u +%Y%m%d)" > >(tee "${EVID}/failover.out" | sed -E '/^t$/d; /^[0-9a-f]{64}$/d; /^sw-demo-[^ ]*$/d; s/^[0-9TZ:.-]+ [0-9]+ /   /') 2>&1 \
    || { sleep 1; die "dr-failover.sh failed (see ${EVID}/failover.out)"; }
  sleep 0.5
  set_state ACTIVE_DB "${P}-pg-melbourne"; set_state PHASE failed-over
  info "front door now: $(cat "${DNS_DIR}/zone") -> $(front_door_host)"
  # client-observed recovery: first acknowledged write served by melbourne
  local first=""; for _ in $(seq 1 60); do first="$(client awk '$3==201 && $4=="backend-melbourne" {print $2; exit}' /tmp/traffic.log 2>/dev/null || true)"; [[ -n "$first" ]] && break; sleep 0.5; done
  [[ -n "$first" ]] || { info "WARNING: no acknowledged traffic on melbourne yet (is traffic running?)"; return 0; }
  local last_ok; last_ok="$(client awk -v t0="$T_DISASTER" '$3==201 && $2<t0 {x=$2} END {print x}' /tmp/traffic.log)"
  local rto_script; rto_script="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["rto_seconds"])' "${EVID}/failover/summary.json")"
  {
    echo "detection_ms=$(( T_DETECTED - T_DISASTER ))"
    echo "operator_decision_ms=$(( TS - T_DETECTED ))"
    echo "failover_automation_s=${rto_script}"
    echo "client_rto_ms=$(( first - T_DISASTER ))"
    echo "client_outage_ms=$(( first - ${last_ok:-$T_DISASTER} ))"
  } >> "${EVID}/measurements.txt"
  say "Measured (this run, local simulation)"
  info "detection (3 failed probes):          $(( T_DETECTED - T_DISASTER )) ms"
  info "operator decision time:               $(( TS - T_DETECTED )) ms"
  info "dr-failover.sh automation (T0->T_RESTORED): ${rto_script} s"
  info "first write acknowledged by melbourne: $(fmt_ms "$first") -> client-observed RTO $(( first - T_DISASTER )) ms after the disaster"
}

# ---------------------------------------------------------------------------------------- verify
cmd_verify() {
  load; [[ -n "${SEED_SUM:-}" ]] || die "run 'seed' first" 2
  local db="$ACTIVE_DB" rc=0
  say "Integrity check on the ACTIVE database: ${db#"${P}-"} (front door -> $(front_door_host))"
  info "role: $(psql_c "$db" "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby (read-only)' ELSE 'PRIMARY (read-write)' END")"
  info "row counts: $(psql_c "$db" "SELECT 'inventory_items='||(SELECT count(*) FROM inventory_items)||' (DEMO='||(SELECT count(*) FROM inventory_items WHERE sku LIKE 'DEMO-%')||', TRAFFIC='||(SELECT count(*) FROM inventory_items WHERE sku LIKE 'TRAFFIC-%')||', DR-WRITE='||(SELECT count(*) FROM inventory_items WHERE sku LIKE 'DR-WRITE-%')||')  stock_checks='||(SELECT count(*) FROM stock_checks)||'  stock_alerts='||(SELECT count(*) FROM stock_alerts)")"
  local missing_ids=0 sku id
  while read -r sku id; do
    [[ "$(psql_c "$db" "SELECT count(*) FROM inventory_items WHERE id='${id}' AND sku='${sku}'")" == 1 ]] || { missing_ids=$((missing_ids + 1)); info "MISSING known record ${sku} ${id}"; }
  done < "${D}/seed_ids.txt"
  info "known records DEMO-001..010 by id: $((10 - missing_ids))/10 present; seed stock check ${SEED_CHECK_ID}: $(psql_c "$db" "SELECT coalesce((SELECT status::text FROM stock_checks WHERE id='${SEED_CHECK_ID}'), 'MISSING')")"
  local sum; sum="$(seed_checksum "$db")"
  if [[ "$sum" == "$SEED_SUM" && "$missing_ids" == 0 ]]; then info "seed checksum: baseline ${SEED_SUM} | now ${sum} -> MATCH"
  else info "seed checksum: baseline ${SEED_SUM} | now ${sum} -> MISMATCH"; rc=1; fi
  # acknowledged traffic writes that are not in this database = data loss (RPO in writes)
  if client test -f /tmp/traffic.log; then
    client cat /tmp/traffic.log > "${D}/traffic.log"; cp "${D}/traffic.log" "${EVID}/traffic.log"
    psql_c "$db" "SELECT substr(sku, 9) FROM inventory_items WHERE sku LIKE 'TRAFFIC-%'" > "${D}/present.txt"
    local r; r="$(python3 - "${D}/traffic.log" "${D}/present.txt" <<'PY'
import sys
rows = [l.split() for l in open(sys.argv[1]) if len(l.split()) == 4]
acked = {r[0] for r in rows if r[2] == "201"}
present = {l.strip() for l in open(sys.argv[2]) if l.strip()}
missing = sorted(acked - present, key=int)
print(f"{len(rows)} {len(acked)} {len(missing)} {' '.join(missing[:10])}")
PY
)"
    read -r sent acked miss first_missing <<<"$r"
    info "traffic: ${sent} requests sent, ${acked} acknowledged (201); acknowledged but missing here: ${miss}${first_missing:+ (seq ${first_missing})}"
    if [[ "$miss" == 0 ]]; then info "RPO (this run): 0 acknowledged writes lost"
    else info "RPO (this run): ${miss} acknowledged writes LOST"; if (( rc == 0 )); then rc=3; fi; fi
    echo "verify_${PHASE}: checksum=$([[ $rc == 1 ]] && echo MISMATCH || echo MATCH) acked=${acked} missing=${miss}" >> "${EVID}/measurements.txt"
  fi
  local w; for w in ${DR_WRITES:+${DR_WRITES//,/ }}; do
    if [[ "$(psql_c "$db" "SELECT count(*) FROM inventory_items WHERE sku='${w}'")" == 1 ]]; then info "record written earlier via the front door, ${w}: present"
    else info "record written earlier via the front door, ${w}: MISSING"; rc=1; fi
  done
  return "$rc"
}

# ---------------------------------------------------------------------------------------- write-check
cmd_write_read() {
  load; [[ "$PHASE" == failed-over || "$PHASE" == failed-back || "$PHASE" == primary ]] || die "nothing is serving (phase ${PHASE})" 2
  local sku body id got; sku="DR-WRITE-${PHASE}-$(date -u +%H%M%S)"
  say "Write + read-back through the front door ($(front_door_host))"
  body="$(api POST /api/inventory "{\"name\":\"Written during ${PHASE}\",\"sku\":\"${sku}\",\"category\":\"dr-demo\",\"quantity\":3,\"minQuantity\":10}")"
  id="$(json 'd["id"]' <<<"$body")" || die "write failed: ${body:0:120}"
  info "POST /api/inventory  -> 201, id ${id}, sku ${sku}"
  got="$(api GET "/api/inventory/${id}" | json 'd["sku"]')"
  info "GET  /api/inventory/${id} -> sku ${got}"
  info "database ${ACTIVE_DB#"${P}-"}: $(psql_c "$ACTIVE_DB" "SELECT count(*) FROM inventory_items WHERE id='${id}'") row(s)"
  [[ "$got" == "$sku" ]] || die "read-back mismatch"
  set_state DR_WRITES "${DR_WRITES:-}${DR_WRITES:+,}${sku}"
}

cmd_stock_check() {
  load; [[ "$PHASE" == failed-over || "$PHASE" == failed-back || "$PHASE" == primary ]] || die "nothing is serving (phase ${PHASE})" 2
  local site s cid; site="$(front_door_host)"; site="${site#backend-}"
  say "Stock check end to end on the ${site} site: API -> BullMQ (redis-${site}) -> worker-${site} -> PostgreSQL"
  info "checks in the database before: $(psql_c "$ACTIVE_DB" "SELECT coalesce(string_agg(status||'='||n, ' '), 'none') FROM (SELECT status::text, count(*) n FROM stock_checks GROUP BY 1 ORDER BY 1) x")"
  cid="$(api POST /api/stock-checks | json 'd["id"]')"
  info "POST /api/stock-checks -> ${cid} (persisted as PENDING, then queued with job id = check id)"
  for _ in $(seq 1 60); do s="$(api GET "/api/stock-checks/${cid}" | json 'd["status"]')"; [[ "$s" == COMPLETED || "$s" == FAILED ]] && break; sleep 0.5; done
  info "stock check ${cid} on this site: $(api GET "/api/stock-checks/${cid}" | json '"status="+d["status"]+" totalChecked="+str(d["totalChecked"])+" lowStockCount="+str(d["lowStockCount"])')"
  info "alerts written by worker-${site} for this check: $(psql_c "$ACTIVE_DB" "SELECT count(*) FROM stock_alerts WHERE \"stockCheckId\"='${cid}'")"
  [[ "$s" == COMPLETED ]] || die "stock check did not complete (worker/queue on this site)"
}

cmd_write_check() { cmd_write_read; cmd_stock_check; }

# Proves that the environment is the isolated simulation (used by the walkthrough before any action).
cmd_selfcheck() {
  load; local ok=0 c n
  [[ "$P" =~ ^sw-demo-[0-9]+$ ]] && info "OK  simulation prefix ${P}" || { info "BAD prefix ${P}"; ok=1; }
  [[ "$(docker network inspect -f '{{.Internal}}' "$NET" 2>/dev/null)" == true ]] && info "OK  network ${NET} is internal (no route to the internet or the host's LAN)" || { info "BAD network ${NET} is not an internal network"; ok=1; }
  n=0
  for c in $(docker ps -a --format '{{.Names}}' | grep "^${P}-" || true); do
    n=$((n + 1))
    [[ -z "$(docker port "$c" 2>/dev/null)" ]] || { info "BAD ${c} publishes ports"; ok=1; }
    [[ "$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c")" == "${NET} " ]] || { info "BAD ${c} is attached to another network"; ok=1; }
  done
  info "OK  ${n} simulation containers, none publishes a port, all only on ${NET}"
  [[ "$D" != "$ROOT"* ]] && info "OK  state directory ${D} is outside the repository" || { info "BAD state directory inside the repository"; ok=1; }
  info "OK  production containers (stockwatch-*) are not part of this simulation and are never addressed"
  return "$ok"
}

# ---------------------------------------------------------------------------------------- failback
cmd_failback() {
  load; [[ "$PHASE" == failed-over ]] || die "failback follows 'failover' (phase is ${PHASE})" 2
  say "FAILBACK (planned): dr-failback.sh --provider local --execute --confirm FAILBACK-$(date -u +%Y%m%d)"
  info "rebuilt primary site will be sydney2; the front-door record 'primary' now points at backend-sydney2"
  sed -i 's/^primary=.*/primary=backend-sydney2/' "${DNS_DIR}/hosts"
  local TS; TS="$(now_ms)"; set_state T_FAILBACK_START "$TS"
  LOCAL_STANDBY_DB="${P}-pg-melbourne" LOCAL_REVERSE_DB="${P}-pg-sydney2" LOCAL_NETWORK="$NET" LOCAL_REPL_PASSWORD="$REPL_PW" \
  LOCAL_SECONDARY_APP="${P}-backend-melbourne ${P}-worker-melbourne" \
  LOCAL_START_PRIMARY_APP_CMD="SIM_STATE='${STATE}' bash '${ROOT}/scripts/dr-simulate.sh' _start_app sydney2 '${P}-pg-sydney2'" \
  PRIMARY_HEALTH_URL="http://backend-sydney2:4000/api/health" LOCAL_DNS_FILE="${DNS_DIR}/zone" \
  DR_HEALTH_CMD="docker exec ${P}-client curl -s -m 2 http://backend-sydney2:4000/api/health" \
    bash "${ROOT}/infrastructure/deployment/dr/dr-failback.sh" --provider local --evidence-dir "${EVID}/failback" \
      --execute --confirm "FAILBACK-$(date -u +%Y%m%d)" > >(tee "${EVID}/failback.out" | sed -E '/^t$/d; /^[0-9a-f]{64}$/d; /^sw-demo-[^ ]*$/d; s/^[0-9TZ:.-]+ [0-9]+ /   /') 2>&1 \
    || { sleep 1; die "dr-failback.sh failed (see ${EVID}/failback.out)"; }
  sleep 0.5
  set_state ACTIVE_DB "${P}-pg-sydney2"; set_state PHASE failed-back
  info "front door now: $(cat "${DNS_DIR}/zone") -> $(front_door_host)"
  local first=""; for _ in $(seq 1 60); do first="$(client awk '$3==201 && $4=="backend-sydney2" {print $2; exit}' /tmp/traffic.log 2>/dev/null || true)"; [[ -n "$first" ]] && break; sleep 0.5; done
  local fail_first; fail_first="$(client awk -v t="$TS" '$2>=t && $3!=201 {print $2; exit}' /tmp/traffic.log)"
  local tw; tw="$(python3 -c 'import sys;m=dict(l.strip().split("=") for l in open(sys.argv[1]));print(int(m["T_PROMOTED"])-int(m["T_WRITES_STOPPED_START"]))' "${EVID}/failback/marks.env")"
  local rto; rto="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["rto_seconds"])' "${EVID}/failback/summary.json")"
  { echo "failback_automation_s=${rto}"; echo "failback_db_write_freeze_ms=${tw}"
    if [[ -n "$first" && -n "$fail_first" ]]; then echo "failback_client_error_window_ms=$(( first - fail_first ))"; fi; } >> "${EVID}/measurements.txt"
  say "Measured (this run, local simulation)"
  info "dr-failback.sh end-to-end: ${rto} s; database write freeze (writers stopped -> promoted): ${tw} ms"
  if [[ -n "$first" && -n "$fail_first" ]]; then info "client-observed failed requests from $(fmt_ms "$fail_first") to first sydney2 ack $(fmt_ms "$first"): $(( first - fail_first )) ms"
  elif [[ -n "$first" ]]; then info "no failed client request during failback; first sydney2 ack $(fmt_ms "$first")"; fi
  return 0
}

cmd_report() { load; say "Measurements — run ${RUN} (LOCAL SIMULATION on one host)"; sed 's/^/   /' "${EVID}/measurements.txt" 2>/dev/null || info "(none yet)"; info "evidence: ${EVID}"; }

cmd_down() {
  [[ -f "$STATE" ]] || { echo "no demo environment"; return 0; }
  load
  client touch /tmp/t.stop 2>/dev/null || true
  [[ -f "${D}/traffic.log" ]] || client cat /tmp/traffic.log > "${EVID}/traffic.log" 2>/dev/null || true
  docker ps -a --format '{{.Names}}' | grep "^${P}-" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker run --rm -v "${D}:/w" alpine:latest sh -c 'rm -rf /w/src' >/dev/null 2>&1 || true
  rm -rf "${D:?}"
  echo "demo ${P} removed; evidence kept in ${EVID}"
}

case "${1:-}" in
  up) cmd_up ;; seed) cmd_seed ;; traffic) shift; cmd_traffic "$@" ;; status) cmd_status ;;
  disaster) cmd_disaster ;; failover) cmd_failover ;; verify) cmd_verify ;; write-check) cmd_write_check ;;
  write-read) cmd_write_read ;; stock-check) cmd_stock_check ;; selfcheck) cmd_selfcheck ;;
  failback) cmd_failback ;; report) cmd_report ;; down) cmd_down ;;
  *) sed -n '/^# Usage:/,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
