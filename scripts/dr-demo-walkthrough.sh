#!/usr/bin/env bash
set -Euo pipefail
# ==========================================================================
# StockWatch DR demonstration — guided, interactive controller (LOCAL SIMULATION).
#
# One command for the whole video. It orchestrates the tested commands of
# scripts/dr-demo.sh stage by stage and waits for you before every stage.
# It never calls docker itself, never reads the production .env and never addresses
# the production containers: every action goes through dr-demo.sh, whose simulation
# runs on an internal Docker network on this host (verified by 'dr-demo.sh selfcheck'
# before anything is changed).
#
# Usage: scripts/dr-demo-walkthrough.sh [--tmux] [--no-tmux] [--resume] [--cleanup] [--help]
#   --tmux      start inside a new tmux session (traffic pane opens automatically)
#   --no-tmux   never open a tmux pane (show the second-terminal instruction instead)
#   --resume    continue an existing simulation from its current phase
#   --cleanup   remove the simulation (only its own containers, volumes, network); keep evidence
#
# At every pause:  Enter = next stage   s = status   v = verify (read-only)
#                  t = recent traffic   r = report   q = quit (simulation is kept)
# Exit codes: 0 completed; 1 a stage failed and you quit; 2 refused (safety / wrong state);
#             130 aborted by you (q or Ctrl-C).
# ==========================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="${STOCKWATCH_DEMO_SCRIPT:-${ROOT}/scripts/dr-demo.sh}"
D="${STOCKWATCH_DEMO_DIR:-${HOME}/.cache/sw-demo}"
STATE="${D}/state.env"
SELF="${BASH_SOURCE[0]}"
LAST="$(mktemp "${TMPDIR:-/tmp}/sw-walkthrough.XXXXXX")"
USE_TMUX=auto RESUME=false PANE="" STAGE=0 START_STAGE=1
TOTAL=16

for a in "$@"; do
  case "$a" in
    --tmux) USE_TMUX=launch ;; --no-tmux) USE_TMUX=no ;; --resume) RESUME=true ;;
    --cleanup) bash "$DEMO" down </dev/null; exit $? ;;
    --help|-h) sed -n '/^# Usage:/,/^# Exit codes/p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a (see --help)" >&2; exit 2 ;;
  esac
done

if [[ "$USE_TMUX" == launch && -z "${TMUX:-}" ]]; then
  command -v tmux >/dev/null || { echo "tmux is not installed; run without --tmux" >&2; exit 2; }
  args=(); [[ "$RESUME" == true ]] && args+=(--resume)
  exec tmux new-session -s "stockwatch-dr-demo-$$" -e "STOCKWATCH_DEMO_DIR=${D}" \
    "bash '${SELF}' ${args[*]:-}; echo; read -r -p 'Walkthrough finished. Press Enter to close this tmux session. '"
fi

# ---------------------------------------------------------------- presentation helpers
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\e[1m' DIM=$'\e[2m' G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' C=$'\e[36m' N=$'\e[0m'
else B="" DIM="" G="" R="" Y="" C="" N=""; fi
line() { printf '%s\n' "${DIM}────────────────────────────────────────────────────────────────────────────${N}"; }
banner() {
  line
  printf '%s\n' "${B}  STOCKWATCH — DISASTER RECOVERY WALKTHROUGH${N}   ${Y}LOCAL SIMULATION on one host${N}"
  printf '%s\n' "  Two simulated sites (sydney / melbourne) in Docker; not an AWS regional failover."
  line
}
okk() { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
err() { printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
txt() { printf '  %s\n' "$*"; }
state_get() { [[ -f "$STATE" ]] && grep -m1 "^$1=" "$STATE" | cut -d= -f2- || true; }   # only PHASE / SEED_CHECK_ID are read
demo() { bash "$DEMO" "$@" </dev/null; }   # the engine never shares our stdin

stage() { # stage <n> <title> <what> <why> <expected>
  STAGE="$1"; echo; line
  printf '%s\n' "${B}${C}  STAGE $(printf '%02d' "$1")/${TOTAL} — $2${N}   ${DIM}phase: $(state_get PHASE || true)${N}"
  line
  txt "${B}What:${N}     $3"
  txt "${B}Why:${N}      $4"
  txt "${B}Expected:${N} $5"
}

read_key() { # read_key <prompt> -> REPLY (EOF = q)
  printf '\n%s' "$1"
  if ! read -r REPLY; then REPLY=q; echo; fi
}

abort() { # user quit or Ctrl-C
  echo; line
  warn "Walkthrough stopped by you at stage ${STAGE}."
  if [[ -f "$STATE" ]]; then
    txt "The simulation is still running; nothing was deleted. Evidence is kept."
    txt "  inspect:  scripts/dr-demo.sh status"
    txt "  continue: scripts/dr-demo-walkthrough.sh --resume"
    txt "  remove:   scripts/dr-demo-walkthrough.sh --cleanup"
  fi
  close_pane; rm -f "$LAST"; exit 130
}
trap 'echo; warn "Interrupted (Ctrl-C). If a stage was running it may be incomplete — check status before continuing."; abort' INT

side_menu() { # handles s/v/t/r; returns 1 if the key was not a side action
  case "$1" in
    s) demo status ;; v) demo verify; true ;; t) demo traffic show 12 ;; r) demo report ;;
    *) return 1 ;;
  esac
  return 0
}

pause() { # pause [next-stage-title]
  while true; do
    read_key "${B}[Enter]${N} ${1:-next stage}   ${DIM}s status · v verify · t traffic · r report · q quit${N} > "
    case "$REPLY" in
      "") return 0 ;;
      q|Q) abort ;;
      *) side_menu "$REPLY" || warn "unknown key '${REPLY}'" ;;
    esac
  done
}

confirm() { # confirm <WORD> <what will happen>
  while true; do
    read_key "${Y}${B}Type ${1}${N}${Y} to $2${N}   ${DIM}(s/v/t/r = look first, q = quit)${N} > "
    case "$REPLY" in
      "$1") return 0 ;;
      q|Q) abort ;;
      *) side_menu "$REPLY" || warn "not confirmed — nothing was changed" ;;
    esac
  done
}

recovery_help() { # recovery_help <command>
  case "$1" in
    up) txt "Initialization failed. Remove the partial simulation with: scripts/dr-demo-walkthrough.sh --cleanup, then start again." ;;
    selfcheck) txt "The environment is NOT the expected isolated simulation. Do not continue. Remove it: scripts/dr-demo-walkthrough.sh --cleanup" ;;
    failover) txt "The front door was NOT switched and the phase is unchanged. Read the evidence file failover.out shown above." \
                  "If the failure happened before 'start secondary app', fix the cause and retry; otherwise quit and --cleanup." ;;
    failback) txt "Read failback.out in the evidence directory. Traffic stays on the DR site until failback succeeds. Quit and --cleanup if unsure." ;;
    verify) txt "${R}INTEGRITY CHECK FAILED.${N} Do not hide this: the seed data on the active database differs from the baseline or is missing." \
                "Show the output above. Inspect with 's' (status). The evidence directory keeps the baseline." ;;
    *) txt "Inspect with 's' (status). Retry with 'r', or quit with 'q' (the simulation is kept for diagnosis)." ;;
  esac
}

run() { # run <allowed-exit-codes e.g. "0" or "0 3"> <dr-demo args...> ; sets RC
  local allowed="$1"; shift
  while true; do
    printf '\n  %s$ scripts/dr-demo.sh %s%s\n' "$DIM" "$*" "$N"
    local t0 t1; t0="$(date +%s%3N)"
    demo "$@" 2>&1 | tee "$LAST"; RC="${PIPESTATUS[0]}"
    t1="$(date +%s%3N)"
    if [[ " $allowed " == *" $RC "* ]]; then
      okk "completed in $(( (t1 - t0) / 1000 )).$(printf '%03d' $(( (t1 - t0) % 1000 ))) s (exit ${RC})"
      return 0
    fi
    echo; err "${B}stage ${STAGE} failed:${N} 'scripts/dr-demo.sh $*' exited ${RC}"
    recovery_help "$1"
    while true; do
      read_key "${B}r${N} retry · s status · t traffic · q quit (simulation kept) > "
      case "$REPLY" in
        r|R) break ;;
        q|Q) echo; err "Stopped after a failed stage (${STAGE}). Nothing further was changed."
             txt "inspect: scripts/dr-demo.sh status   remove: scripts/dr-demo-walkthrough.sh --cleanup"
             close_pane; rm -f "$LAST"; exit 1 ;;
        s|t) side_menu "$REPLY" ;;
        *) warn "choose r, s, t or q" ;;
      esac
    done
  done
}

measured() { # measured <regex> : show measurement lines from the last command's real output
  local m; m="$(grep -E "$1" "$LAST" | sed -E 's/\x1b\[[0-9;]*m//g; s/^ +//' || true)"
  if [[ -n "$m" ]]; then printf '  %sMeasured (this run):%s\n' "$B" "$N"; while IFS= read -r l; do txt "  ${l}"; done <<<"$m"; fi
}

open_pane() {
  if [[ "$USE_TMUX" != no && -n "${TMUX:-}" ]] && command -v tmux >/dev/null; then
    PANE="$(tmux split-window -h -d -P -F '#{pane_id}' -e "STOCKWATCH_DEMO_DIR=${D}" "bash '${DEMO}' traffic watch" 2>/dev/null || true)"
    [[ -n "$PANE" ]] && { okk "live traffic opened in the right-hand tmux pane"; return; }
  fi
  warn "Open a ${B}second terminal${N} next to this one and run:"
  txt "    ${B}cd ${ROOT} && scripts/dr-demo.sh traffic watch${N}"
  txt "  (or restart this walkthrough with --tmux to get the pane automatically)"
}
close_pane() { [[ -n "$PANE" ]] && tmux kill-pane -t "$PANE" 2>/dev/null; PANE=""; true; }

# ---------------------------------------------------------------- resume point
if [[ -f "$STATE" ]]; then
  if [[ "$RESUME" != true ]]; then
    banner; err "A simulation already exists (phase: $(state_get PHASE))."
    txt "Continue it:  scripts/dr-demo-walkthrough.sh --resume"
    txt "Remove it:    scripts/dr-demo-walkthrough.sh --cleanup"
    exit 2
  fi
  case "$(state_get PHASE)" in
    primary) if [[ -z "$(state_get SEED_CHECK_ID)" ]]; then START_STAGE=3; else START_STAGE=4; fi ;;
    disaster) START_STAGE=7 ;; failed-over) START_STAGE=9 ;; failed-back) START_STAGE=14 ;;
    *) banner; err "The simulation is incomplete (phase $(state_get PHASE)); remove it with --cleanup."; exit 2 ;;
  esac
elif [[ "$RESUME" == true ]]; then
  banner; err "Nothing to resume: no simulation exists."; exit 2
fi
at() { (( START_STAGE <= $1 )); }

# ================================================================= STAGES
banner
if [[ "$RESUME" == true ]]; then
  txt "Resuming at stage ${START_STAGE} (phase $(state_get PHASE)). Re-checking isolation first:"
  run "0" selfcheck
  [[ "$START_STAGE" -ge 5 ]] && open_pane
fi
if at 1; then
  stage 1 "Introduction and safety checks" \
    "Check prerequisites and explain what will run." \
    "The demo must never touch production: separate containers, internal network, random credentials." \
    "All checks green; nothing is started yet."
  command -v docker >/dev/null && okk "docker CLI available" || { err "docker is not installed"; exit 2; }
  [[ -f "$DEMO" ]] && okk "demo engine: ${DEMO#"${ROOT}/"} (tested by scripts/test-dr-demo.sh)" || { err "demo engine not found"; exit 2; }
  [[ "$D" != "$ROOT"* ]] && okk "simulation state directory outside the repository: ${D}" || { err "state directory inside the repository — refusing"; exit 2; }
  okk "no existing simulation; production containers, RDS, AWS and the production .env are never used"
  if [[ -n "${TMUX:-}" && "$USE_TMUX" != no ]]; then okk "running inside tmux: the traffic pane will open automatically at stage 4"
  else warn "not in tmux: at stage 4 you will be asked to open a second terminal for live traffic (or use --tmux)"; fi
  txt "${DIM}Show now: production StockWatch in the browser (read-only), then the architecture diagram.${N}"
  pause "initialize the simulation"
fi

if at 2; then
  stage 2 "Initialize the isolated DR environment" \
    "Build the app from this checkout; start sydney (primary DB, Redis, API, worker) and melbourne (hot standby) on an internal Docker network." \
    "The standby is created with pg_basebackup and kept current by PostgreSQL streaming replication." \
    "Sydney API healthy; standby in recovery; selfcheck: internal network, no published ports."
  run "0" up
  run "0" selfcheck
  run "0" status
  pause "seed the known test data"
fi

if at 3; then
  stage 3 "Seed ten known records and establish the checksum baseline" \
    "Create DEMO-001..DEMO-010 through the API and run one stock check end to end; md5 over every seed row." \
    "The checksum and the record ids are what we compare on the DR site after promotion." \
    "10 ids, stock check COMPLETED with lowStockCount=5, one baseline checksum."
  run "0" seed
  measured 'seed checksum'
  pause "start live traffic"
fi

if at 4; then
  stage 4 "Start primary traffic" \
    "A client writes an inventory item every ~0.2 s through the front door (simulated DNS record, resolved per request)." \
    "Makes the outage and the switch to DR visible; every acknowledged write is later checked for loss." \
    "Requests -> backend-sydney, 201 Created."
  if [[ "$RESUME" == true && "$START_STAGE" == 4 ]]; then run "0 2" traffic start; else run "0" traffic start; fi
  open_pane
  sleep 2; run "0" traffic show 6
  pause "show replication status"
fi

if at 5; then
  stage 5 "Primary status and streaming replication" \
    "Show both databases, their roles, replication state and per-database seed checksums." \
    "Proves the standby already holds the same data before anything fails." \
    "sydney PRIMARY <- ACTIVE, replication state=streaming, melbourne standby with the identical checksum."
  run "0" status
  pause "simulate the disaster (confirmation required)"
fi

if at 6; then
  stage 6 "Simulate the primary-site disaster" \
    "Remove the whole simulated sydney site: database container and volume, API, worker, Redis. Then run the 1 s, 3-strike health detector." \
    "A site loss, not a process crash: nothing on sydney can be restarted." \
    "Traffic turns to FAILED; PRIMARY DOWN detected after ~2.5 s."
  confirm DESTROY "destroy the simulated sydney site (simulation containers only)"
  run "0" disaster
  measured 'PRIMARY DOWN detected|replication just before'
  pause "show detection and failed traffic"
fi

if at 7; then
  stage 7 "Detection and failed traffic" \
    "Show the client's failed requests and the site status." \
    "Three consecutive failures avoid promoting on a single lost probe; promotion is an operator decision." \
    "Recent requests FAILED (000) to backend-sydney; pg-sydney DESTROYED."
  run "0" traffic show 8
  run "0" status
  pause "execute the controlled failover (confirmation required)"
fi

if at 8; then
  stage 8 "Controlled failover" \
    "Run dr-failover.sh (local provider): check lag, fence, promote melbourne, start DR app + worker on an empty Redis, wait for health, switch the front door." \
    "Same step engine as the AWS provider; the front door switches only after the DR app is healthy." \
    "Promotion, healthy DR app, 'front door now: app=secondary -> backend-melbourne'."
  confirm PROMOTE "promote the simulated melbourne database and switch traffic"
  run "0" failover
  measured 'detection|operator decision|automation|client-observed RTO|first write'
  pause "show traffic on the DR site"
fi

if at 9; then
  stage 9 "Traffic switched to DR" \
    "Show the client's requests and site status after the switch." \
    "Users are served by the DR site through the same front-door name." \
    "Requests -> backend-melbourne 201 Created; pg-melbourne PRIMARY <- ACTIVE."
  run "0" traffic show 8
  run "0" status
  pause "verify data integrity on DR"
fi

if at 10; then
  stage 10 "Verify data integrity on the DR database" \
    "Known ids by primary key, seed checksum vs baseline, acknowledged writes vs rows present." \
    "Availability is not enough: the promoted database must hold the data users were told was saved." \
    "10/10 ids, checksum MATCH, acknowledged-but-missing = the measured RPO of this run."
  run "0 3" verify
  [[ "$RC" == 3 ]] && warn "${B}This run lost acknowledged writes (shown above).${N} That is the real RPO of asynchronous replication here — say so in the video."
  measured 'seed checksum|known records|traffic:|RPO'
  pause "write and read back on DR"
fi

if at 11; then
  stage 11 "New write and read-back on the DR site" \
    "POST a new item through the front door, read it back through the API and find the row in the DR database." \
    "Proves the promoted database accepts writes (it is no longer a read-only standby)." \
    "201, the same SKU read back, 1 row in pg-melbourne."
  run "0" write-read
  pause "run a stock check through the DR worker"
fi

if at 12; then
  stage 12 "Stock check through the DR worker" \
    "Enqueue a stock check on the DR site: API -> BullMQ on the DR Redis (empty after failover) -> DR worker -> PostgreSQL." \
    "The queue lives in Redis, the truth in PostgreSQL: background processing recovers without the old Redis." \
    "Status COMPLETED, alerts written by the DR worker."
  run "0" stock-check
  pause "fail back (confirmation required)"
fi

if at 13; then
  stage 13 "Controlled failback" \
    "Run dr-failback.sh: rebuild sydney2 as a replica of melbourne, wait for lag 0, stop DR writers, re-check lag 0, promote sydney2, start its app, switch the front door back." \
    "A planned return without data loss; the old primary is rebuilt, never simply switched back on." \
    "Write freeze under a second; 'front door now: app=primary -> backend-sydney2'."
  confirm FAILBACK "rebuild and promote the simulated sydney site and switch traffic back"
  run "0" failback
  measured 'end-to-end|failed requests|no failed client request'
  pause "verify final integrity"
fi

if at 14; then
  stage 14 "Final integrity and status" \
    "Repeat the integrity check on the restored primary and show all sites." \
    "Data must survive the round trip, including the record written on the DR site." \
    "checksum MATCH, DR-site record present; melbourne marked RETIRED (fenced, no client)."
  run "0 3" verify
  [[ "$RC" == 3 ]] && warn "${B}Acknowledged writes were lost in this run (shown above).${N} Report it."
  run "0" status
  pause "show the RTO/RPO report"
fi

if at 15; then
  stage 15 "Measured RTO / RPO report" \
    "Print every measurement of this run from the evidence directory." \
    "These, and only these, are the numbers to quote — measured in a LOCAL SIMULATION, not AWS." \
    "detection, operator decision, failover automation, client-observed RTO, failback freeze, RPO per phase."
  run "0" report
  txt "${Y}Not measured anywhere:${N} RDS replica promotion, cross-region lag, Route 53 detection/TTL, production regional RPO."
  pause "clean up"
fi

if at 16; then
  stage 16 "Cleanup" \
    "Stop traffic and remove only this simulation's containers, volumes and network; keep the evidence." \
    "Leaves the host exactly as before; production was never involved." \
    "'demo … removed; evidence kept in …'."
  while true; do
    read_key "${Y}Type DOWN to remove the simulation, or k to keep it running${N} > "
    case "$REPLY" in
      DOWN) run "0" traffic stop; close_pane; run "0" down; break ;;
      k|K) close_pane; warn "Simulation kept. Remove later with: scripts/dr-demo-walkthrough.sh --cleanup"; break ;;
      q|Q) abort ;;
      *) side_menu "$REPLY" || warn "type DOWN or k" ;;
    esac
  done
fi
echo; line; okk "${B}Walkthrough complete.${N}"; line
rm -f "$LAST"
exit 0
