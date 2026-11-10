#!/usr/bin/env bash
# shellcheck shell=bash
# Local provider (zero cost): Docker PostgreSQL 16 streaming replication on an isolated
# network. Used by scripts/dr-simulate.sh to exercise the same step engine end to end.
# Configuration (environment):
#   LOCAL_PRIMARY_DB / LOCAL_STANDBY_DB      container names (primary / streaming standby)
#   LOCAL_PG_USER=postgres  LOCAL_DB=stockwatch
#   LOCAL_PRIMARY_APP                        space-separated app containers to fence
#   LOCAL_START_APP_CMD                      command to start the secondary app (gets DR_DB_HOST)
#   LOCAL_HEALTH_URL                         secondary health URL
#   LOCAL_DNS_FILE                           simulated resolver mapping file (optional)
#   LOCAL_REVERSE_DB / LOCAL_START_PRIMARY_APP_CMD / LOCAL_SECONDARY_APP / LOCAL_NETWORK  (failback)

: "${LOCAL_PG_USER:=postgres}" "${LOCAL_DB:=stockwatch}"

_psql() { docker exec -i "$1" psql -U "$LOCAL_PG_USER" -d "$LOCAL_DB" -tAq -c "$2"; }

dr_p_name() { echo "local (${LOCAL_PRIMARY_DB} -> ${LOCAL_STANDBY_DB})"; }

dr_p_preflight() {
  docker inspect "$LOCAL_STANDBY_DB" >/dev/null 2>&1 || dr_die "standby container ${LOCAL_STANDBY_DB} not found"
  [[ -n "${LOCAL_START_APP_CMD:-}" ]] || dr_die "LOCAL_START_APP_CMD is required"
}

dr_p_is_standby() { [[ "$(_psql "$LOCAL_STANDBY_DB" "SELECT pg_is_in_recovery()")" == t ]]; }

dr_p_replication_lag() { # seconds since last replayed transaction (0 when fully caught up and idle)
  local v
  v="$(_psql "$LOCAL_STANDBY_DB" "SELECT CASE WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0 ELSE COALESCE(EXTRACT(EPOCH FROM now() - pg_last_xact_replay_timestamp()), -1) END" 2>/dev/null || true)"
  [[ -n "$v" && "$v" != "-1" ]] && echo "$v" || echo unknown
}

dr_p_fence_primary() {
  [[ -n "${LOCAL_PRIMARY_APP:-}" ]] || { dr_log "SKIP" "fence: LOCAL_PRIMARY_APP not set"; return 0; }
  local c
  for c in $LOCAL_PRIMARY_APP; do
    if docker inspect "$c" >/dev/null 2>&1; then
      dr_mutate false "fence primary app container ${c}" -- docker stop -t 10 "$c" || dr_log "WARN" "fence ${c} failed"
    else
      dr_log "SKIP" "fence ${c}: not present (primary region down)"
    fi
  done
}

dr_p_promote() { dr_mutate false "promote standby ${LOCAL_STANDBY_DB} (pg_promote)" -- _psql "$LOCAL_STANDBY_DB" "SELECT pg_promote(true, 60)"; }

dr_p_wait_writable() {
  [[ "$DR_EXECUTE" == true ]] || { dr_log "DRY-RUN" "wait until ${LOCAL_STANDBY_DB} accepts writes"; return 0; }
  local i
  for i in $(seq 1 60); do [[ "$(_psql "$LOCAL_STANDBY_DB" "SELECT pg_is_in_recovery()")" == f ]] && return 0; sleep 0.5; done
  dr_die "standby did not leave recovery (${i} checks)"
}

dr_p_endpoint() { echo "$LOCAL_STANDBY_DB"; }

dr_p_start_app() { dr_mutate false "start secondary app against ${1}" -- env DR_DB_HOST="$1" bash -c "$LOCAL_START_APP_CMD"; }

dr_p_health_url() { echo "$LOCAL_HEALTH_URL"; }

dr_p_switch_dns() {
  [[ -n "${LOCAL_DNS_FILE:-}" ]] || { dr_log "SKIP" "DNS not simulated"; return 0; }
  dr_mutate false "simulated DNS: app -> secondary" -- bash -c "echo 'app=secondary' > '$LOCAL_DNS_FILE'"
}
dr_p_restore_dns() {
  [[ -n "${LOCAL_DNS_FILE:-}" ]] || { dr_log "SKIP" "DNS not simulated"; return 0; }
  dr_mutate false "simulated DNS: app -> primary" -- bash -c "echo 'app=primary' > '$LOCAL_DNS_FILE'"
}

# ---- failback: re-seed a new primary-region standby from the promoted DB, then switch over ----
dr_p_create_reverse_standby() {
  dr_mutate false "create reverse standby ${LOCAL_REVERSE_DB} from ${LOCAL_STANDBY_DB} (pg_basebackup)" -- \
    docker run -d --name "$LOCAL_REVERSE_DB" --network "$LOCAL_NETWORK" -e PGPASSWORD="$LOCAL_REPL_PASSWORD" postgres:16-alpine \
    sh -c "rm -rf /var/lib/postgresql/data/* && pg_basebackup -h $LOCAL_STANDBY_DB -U replicator -D /var/lib/postgresql/data -R -X stream -c fast && chown -R postgres:postgres /var/lib/postgresql/data && chmod 700 /var/lib/postgresql/data && exec su-exec postgres postgres"
  [[ "$DR_EXECUTE" == true ]] || return 0
  local i
  for i in $(seq 1 60); do [[ "$(_psql "$LOCAL_REVERSE_DB" "SELECT pg_is_in_recovery()" 2>/dev/null)" == t ]] && return 0; sleep 1; done
  dr_die "reverse standby did not start (${i}s)"
}
dr_p_reverse_lag() {
  local v
  v="$(_psql "$LOCAL_REVERSE_DB" "SELECT CASE WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0 ELSE -1 END" 2>/dev/null || true)"
  [[ "$v" == 0 ]] && echo 0 || echo unknown
}
dr_p_fence_secondary() {
  local c
  for c in ${LOCAL_SECONDARY_APP:-}; do dr_mutate false "stop secondary app ${c}" -- docker stop -t 10 "$c"; done
}
dr_p_promote_reverse() {
  dr_mutate false "promote ${LOCAL_REVERSE_DB}" -- _psql "$LOCAL_REVERSE_DB" "SELECT pg_promote(true, 60)"
}
dr_p_start_primary_app() { dr_mutate false "start primary app against ${LOCAL_REVERSE_DB}" -- env DR_DB_HOST="$LOCAL_REVERSE_DB" bash -c "$LOCAL_START_PRIMARY_APP_CMD"; }
