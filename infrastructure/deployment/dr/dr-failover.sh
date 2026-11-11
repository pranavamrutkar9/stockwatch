#!/usr/bin/env bash
set -Eeuo pipefail
# ==========================================================================
# StockWatch failover: promote the secondary database and start the
# secondary application. DRY RUN by default.
#
#   dr-failover.sh --provider aws|local [--execute --confirm FAILOVER-<UTC yyyymmdd>]
#                  [--allow-billable] [--max-lag-seconds N] [--force-unknown-lag]
#                  [--evidence-dir DIR]
#
# Steps (each timestamped): preflight -> T0 -> RPO evidence (replication lag) ->
# fence primary -> promote (idempotent) -> wait writable -> start app ->
# verify health -> DNS switch -> T_RESTORED -> summary.json (RTO).
# Provider configuration: see providers/<provider>.sh.
# ==========================================================================
DR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infrastructure/deployment/dr/lib.sh
source "${DR_DIR}/lib.sh"

PROVIDER="" CONFIRM="" MAX_LAG=300 FORCE_UNKNOWN_LAG=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDER="${2:?}"; shift ;;
    --execute) DR_EXECUTE=true ;;
    --confirm) CONFIRM="${2:?}"; shift ;;
    --allow-billable) DR_ALLOW_BILLABLE=true ;;
    --max-lag-seconds) MAX_LAG="${2:?}"; shift ;;
    --force-unknown-lag) FORCE_UNKNOWN_LAG=true ;;
    --evidence-dir) DR_EVIDENCE_DIR="${2:?}"; shift ;;
    *) echo "ERROR: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$PROVIDER" =~ ^(aws|local)$ ]] || { echo "ERROR: --provider aws|local is required" >&2; exit 2; }
# shellcheck source=/dev/null
source "${DR_DIR}/providers/${PROVIDER}.sh"

dr_init_evidence failover
exec 9>"${DR_EVIDENCE_DIR}/.lock"; flock -n 9 || dr_die "another DR operation is running"
dr_require_confirmation FAILOVER "$CONFIRM"
dr_log "START" "failover provider=$(dr_p_name) mode=$([[ $DR_EXECUTE == true ]] && echo EXECUTE || echo DRY-RUN)"

dr_p_preflight
dr_mark T0

if dr_p_is_standby; then
  LAG="$(dr_p_replication_lag)"
  dr_log "RPO-EVIDENCE" "replication_lag_seconds=${LAG}"
  if [[ "$LAG" == unknown ]]; then
    [[ "$FORCE_UNKNOWN_LAG" == true ]] || dr_die "replication lag unknown; refusing to promote (use --force-unknown-lag after manual assessment)"
  elif python3 -c "import sys; sys.exit(0 if float('$LAG') <= float('$MAX_LAG') else 1)"; then
    :
  else
    dr_die "replication lag ${LAG}s exceeds --max-lag-seconds ${MAX_LAG}"
  fi
  dr_p_fence_primary
  dr_mark T_PROMOTE_START
  dr_p_promote
  dr_p_wait_writable
  dr_mark T_PROMOTED
else
  LAG="n/a"
  dr_log "SKIP" "secondary database already promoted (idempotent re-run)"
fi

ENDPOINT="$(dr_p_endpoint)"
dr_log "CHECK" "secondary database endpoint resolved"
dr_p_start_app "$ENDPOINT"
dr_mark T_APP_STARTED

if [[ "$DR_EXECUTE" == true ]]; then
  dr_wait_http "$(dr_p_health_url)" 180 || dr_die "secondary application did not become healthy"
  dr_mark T_APP_HEALTHY
else
  dr_log "DRY-RUN" "wait for $(dr_p_health_url) to report status ok"
fi

dr_p_switch_dns
dr_mark T_RESTORED
dr_summary provider="$PROVIDER" mode="$([[ $DR_EXECUTE == true ]] && echo execute || echo dry-run)" replication_lag_at_t0="$LAG" >/dev/null
dr_log "DONE" "evidence: ${DR_EVIDENCE_DIR}"
