#!/usr/bin/env bash
set -Eeuo pipefail
# ==========================================================================
# StockWatch planned failback (RPO 0): re-establish a primary-region replica
# of the promoted secondary, wait until caught up, stop secondary writers,
# promote, start the primary application, restore DNS. DRY RUN by default.
#
#   dr-failback.sh --provider aws|local [--execute --confirm FAILBACK-<UTC yyyymmdd>]
#                  [--allow-billable] [--evidence-dir DIR]
# ==========================================================================
DR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infrastructure/deployment/dr/lib.sh
source "${DR_DIR}/lib.sh"

PROVIDER="" CONFIRM="" PRIMARY_HEALTH_URL="${PRIMARY_HEALTH_URL:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDER="${2:?}"; shift ;;
    --execute) DR_EXECUTE=true ;;
    --confirm) CONFIRM="${2:?}"; shift ;;
    --allow-billable) DR_ALLOW_BILLABLE=true ;;
    --evidence-dir) DR_EVIDENCE_DIR="${2:?}"; shift ;;
    *) echo "ERROR: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$PROVIDER" =~ ^(aws|local)$ ]] || { echo "ERROR: --provider aws|local is required" >&2; exit 2; }
# shellcheck source=/dev/null
source "${DR_DIR}/providers/${PROVIDER}.sh"

dr_init_evidence failback
exec 9>"${DR_EVIDENCE_DIR}/.lock"; flock -n 9 || dr_die "another DR operation is running"
dr_require_confirmation FAILBACK "$CONFIRM"
dr_log "START" "failback provider=$(dr_p_name) mode=$([[ $DR_EXECUTE == true ]] && echo EXECUTE || echo DRY-RUN)"

dr_mark T0
dr_p_create_reverse_standby
dr_mark T_REVERSE_READY

if [[ "$DR_EXECUTE" == true ]]; then
  for _ in $(seq 1 120); do [[ "$(dr_p_reverse_lag)" == 0 ]] && break; sleep 1; done
  [[ "$(dr_p_reverse_lag)" == 0 ]] || dr_die "reverse replica not caught up; refusing switchover"
fi
dr_log "CHECK" "reverse replica caught up (lag 0)"

dr_mark T_WRITES_STOPPED_START
dr_p_fence_secondary
# Re-check after writers stopped: the switchover must lose nothing (RPO 0).
if [[ "$DR_EXECUTE" == true ]]; then
  for _ in $(seq 1 60); do [[ "$(dr_p_reverse_lag)" == 0 ]] && break; sleep 0.5; done
  [[ "$(dr_p_reverse_lag)" == 0 ]] || dr_die "reverse replica lag not 0 after stopping writers"
fi
dr_p_promote_reverse
dr_mark T_PROMOTED
dr_p_start_primary_app
if [[ "$DR_EXECUTE" == true && -n "$PRIMARY_HEALTH_URL" ]]; then
  dr_wait_http "$PRIMARY_HEALTH_URL" 180 || dr_die "primary application did not become healthy"
fi
dr_p_restore_dns
dr_mark T_RESTORED
dr_summary provider="$PROVIDER" mode="$([[ $DR_EXECUTE == true ]] && echo execute || echo dry-run)" >/dev/null
dr_log "DONE" "evidence: ${DR_EVIDENCE_DIR}"
