#!/usr/bin/env bash
# shellcheck shell=bash
# Shared step engine for dr-failover.sh / dr-failback.sh.
#   - DRY RUN by default: read-only checks run, mutating steps are only printed.
#   - --execute requires --confirm <ACTION>-<UTC yyyymmdd> (prevents accidental runs/replays).
#   - Billable mutations additionally require --allow-billable.
#   - Every step is timestamped to an evidence log (UTC, millisecond resolution).

DR_EXECUTE=false
DR_ALLOW_BILLABLE=false
DR_EVIDENCE_DIR=""
DR_LOG=""

dr_now_ms() { date +%s%3N; }
dr_ts() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }

dr_init_evidence() { # dr_init_evidence <action>
  DR_EVIDENCE_DIR="${DR_EVIDENCE_DIR:-${HOME}/stockwatch-dr-evidence/$(date -u +%Y%m%dT%H%M%SZ)-$1}"
  mkdir -p "$DR_EVIDENCE_DIR" && chmod 700 "$DR_EVIDENCE_DIR"
  DR_LOG="${DR_EVIDENCE_DIR}/events.log"
  : >> "$DR_LOG"
}

dr_log() { # dr_log <event> [detail]
  local line
  line="$(dr_ts) $(dr_now_ms) $1${2:+ $2}"
  printf '%s\n' "$line" | tee -a "$DR_LOG"
}

dr_mark() { # dr_mark <NAME> : named timestamp (ms) for RTO/RPO computation
  local t; t="$(dr_now_ms)"
  printf '%s=%s\n' "$1" "$t" >> "${DR_EVIDENCE_DIR}/marks.env"
  dr_log "MARK" "$1"
}

dr_die() { dr_log "ABORT" "$*"; echo "ERROR: $*" >&2; exit 1; }

dr_require_confirmation() { # dr_require_confirmation <ACTION> <token>
  local expected; expected="$1-$(date -u +%Y%m%d)"
  if [[ "$DR_EXECUTE" == true && "$2" != "$expected" ]]; then
    dr_die "--execute requires --confirm ${1}-<UTC yyyymmdd> (today: ${expected})."
  fi
}

# dr_mutate <billable:true|false> <description> -- <command...>
dr_mutate() {
  local billable="$1" desc="$2"; shift 3
  if [[ "$DR_EXECUTE" != true ]]; then
    dr_log "DRY-RUN" "$([[ "$billable" == true ]] && echo '[BILLABLE: needs --allow-billable] ')${desc} :: $(printf '%q ' "$@")"
    return 0
  fi
  if [[ "$billable" == true && "$DR_ALLOW_BILLABLE" != true ]]; then
    dr_die "Billable step refused without --allow-billable: ${desc}"
  fi
  dr_log "EXEC" "$desc"
  "$@"
}

# dr_wait_http <url> <timeout_s> : waits for HTTP 200 with "status":"ok"
dr_wait_http() {
  local url="$1" deadline=$(( $(date +%s) + $2 )) body
  while (( $(date +%s) < deadline )); do
    body="$(curl -s -m 5 "$url" 2>/dev/null || true)"
    grep -q '"status":"ok"' <<<"$body" && return 0
    sleep 1
  done
  return 1
}

dr_summary() { # writes summary.json from marks
  python3 - "$DR_EVIDENCE_DIR" "$@" <<'PY'
import json, sys, pathlib
d = pathlib.Path(sys.argv[1]); marks = {}
for line in (d / "marks.env").read_text().splitlines():
    k, v = line.split("=", 1); marks[k] = int(v)
extra = dict(a.split("=", 1) for a in sys.argv[2:])
out = {"marks_ms": marks, **extra}
if "T0" in marks and "T_RESTORED" in marks:
    out["rto_seconds"] = round((marks["T_RESTORED"] - marks["T0"]) / 1000, 3)
(d / "summary.json").write_text(json.dumps(out, indent=2) + "\n")
print(json.dumps(out))
PY
}
