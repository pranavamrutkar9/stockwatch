#!/usr/bin/env bash
set -Euo pipefail
# ==========================================================================
# Tests for scripts/dr-demo-walkthrough.sh (interactive DR video controller).
#
# Part A (fast): the controller against a STUB engine — exact command sequence,
#   wrong-stage refusal, confirmations, user abort, Ctrl-C, failed initialization,
#   failed selfcheck, failed promotion (retry + quit), failed integrity check, RPO>0
#   warning, resume, cleanup, EOF safety, and proof that the controller itself never
#   runs docker or reads a .env file.
# Part B (real, ~2-3 min): the full walkthrough driven by keystrokes against the real
#   dr-demo.sh, then an interrupted real run cleaned up with --cleanup; no leftovers,
#   no leaked credentials, production containers untouched.
#   Skip part B with: SKIP_REAL=1 scripts/test-dr-demo-walkthrough.sh
# ==========================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="${ROOT}/scripts/dr-demo-walkthrough.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/sw-walk-test.XXXXXX")"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
cleanup() {
  [[ -f "${T}/real/state.env" ]] && STOCKWATCH_DEMO_DIR="${T}/real" bash "${ROOT}/scripts/dr-demo.sh" down >/dev/null 2>&1
  docker run --rm -v "$T:/w" alpine:latest sh -c 'rm -rf /w/real' >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

# ---------------------------------------------------------------- stub engine
mkdir -p "${T}/bin"
cat > "${T}/stub-demo.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
S="${STOCKWATCH_DEMO_DIR}/state.env"
setp() { sed -i "s/^PHASE=.*/PHASE=$1/" "$S"; }
v="STUB_RC_${1//-/_}"; rc="${!v:-0}"
if [[ "$rc" != 0 ]]; then echo "stub: $1 failed"; exit "$rc"; fi
case "$1" in
  up) mkdir -p "$STOCKWATCH_DEMO_DIR"; printf 'P=sw-demo-1\nPHASE=primary\nAPP_PW=stubsecret\n' > "$S"; echo "sydney backend healthy" ;;
  seed) echo "SEED_CHECK_ID=abc" >> "$S"; echo "   seed checksum (md5 of all seed rows) on sydney primary: 0123" ;;
  disaster) setp disaster; echo "   PRIMARY DOWN detected after 2400 ms" ;;
  failover) setp failed-over; echo "   detection (3 failed probes):          2400 ms" ;;
  failback) setp failed-back; echo "   dr-failback.sh end-to-end: 4.1 s" ;;
  verify) echo "   seed checksum: baseline 0123 | now 0123 -> MATCH" ;;
  down) rm -rf "$STOCKWATCH_DEMO_DIR" ;;
  *) echo "stub $*" ;;
esac
STUB
printf '#!/bin/sh\necho "docker $*" >> "%s/docker-calls.log"\nexit 1\n' "$T" > "${T}/bin/docker"
chmod +x "${T}/stub-demo.sh" "${T}/bin/docker"

walk() { # walk <input-lines> [args...] -> OUT RC CALLS
  local input="$1"; shift
  rm -rf "${T}/state"; : > "${T}/calls.log"
  [[ -n "${PRESTATE:-}" ]] && { mkdir -p "${T}/state"; printf '%b' "$PRESTATE" > "${T}/state/state.env"; }
  OUT="$(printf '%b' "$input" | env -u TMUX PATH="${T}/bin:$PATH" STOCKWATCH_DEMO_SCRIPT="${T}/stub-demo.sh" STUB_LOG="${T}/calls.log" \
        STOCKWATCH_DEMO_DIR="${T}/state" NO_COLOR=1 bash "$W" "$@" 2>&1)"; RC=$?
  CALLS="$(paste -sd'|' "${T}/calls.log")"
}
FULL='\n\n\n\n\nDESTROY\n\n\nPROMOTE\n\n\n\n\n\nFAILBACK\n\n\n\nDOWN\n'
SEQ='up|selfcheck|status|seed|traffic start|traffic show 6|status|disaster|traffic show 8|status|failover|traffic show 8|status|verify|write-read|stock-check|failback|verify|status|report|traffic stop|down'

echo "Part A — controller logic (stub engine)"
walk "$FULL"
[[ "$RC" == 0 ]] && ok "complete walkthrough exits 0" || { bad "complete walkthrough: exit $RC"; tail -15 <<<"$OUT"; }
[[ "$CALLS" == "$SEQ" ]] && ok "exact stage command sequence (22 engine calls)" || bad "sequence: $CALLS"
[[ "$(grep -c 'STAGE [0-9][0-9]/16' <<<"$OUT")" == 16 ]] && ok "16 numbered stages shown" || bad "stage headers"
grep -q 'Measured (this run):' <<<"$OUT" && grep -q 'PRIMARY DOWN detected after 2400 ms' <<<"$OUT" && ok "measurements are read from the engine's real output" || bad "measured"
grep -q 'Open a second terminal' <<<"$OUT" && grep -q 'scripts/dr-demo.sh traffic watch' <<<"$OUT" && ok "without tmux: second-terminal instruction for live traffic" || bad "traffic fallback instruction"
[[ ! -s "${T}/docker-calls.log" ]] && ok "controller never invoked docker itself" || bad "docker invoked: $(head -2 "${T}/docker-calls.log")"
grep -q 'stubsecret' <<<"$OUT" && bad "state value printed" || ok "no simulation credential printed"

walk '\n\n\n\n\nyes\nq\n'
[[ "$RC" == 130 && "$CALLS" != *disaster* ]] && grep -q 'not confirmed — nothing was changed' <<<"$OUT" && ok "wrong confirmation word: disaster NOT executed; quit = exit 130" || bad "confirmation: rc=$RC calls=$CALLS"
walk '\n\n\n\n\nDESTROY\n\n\nnope\nq\n'
[[ "$RC" == 130 && "$CALLS" != *failover* ]] && ok "promotion requires typing PROMOTE" || bad "promote confirmation: rc=$RC"

walk '\n\nq\n'
[[ "$RC" == 130 && "$CALLS" == "up|selfcheck|status|seed" ]] && grep -q 'simulation is still running; nothing was deleted' <<<"$OUT" && ok "user abort: exit 130, nothing deleted, resume/cleanup instructions" || bad "abort: rc=$RC calls=$CALLS"
walk '\n'
[[ "$RC" == 130 ]] && ok "end of input is treated as quit (never loops or proceeds)" || bad "EOF: rc=$RC"

STUB_RC_up=1 walk '\nq\n'
[[ "$RC" == 1 && "$CALLS" == up ]] && grep -q -- '--cleanup' <<<"$OUT" && ok "failed initialization: stops (exit 1), shows cleanup instruction, no further stage" || bad "failed up: rc=$RC calls=$CALLS"
STUB_RC_selfcheck=1 walk '\nq\n'
[[ "$RC" == 1 && "$CALLS" == "up|selfcheck" ]] && grep -q 'NOT the expected isolated simulation' <<<"$OUT" && ok "failed isolation selfcheck: refuses to continue" || bad "selfcheck: rc=$RC"
STUB_RC_failover=1 walk '\n\n\n\n\nDESTROY\n\n\nPROMOTE\nr\nq\n'
[[ "$RC" == 1 && "$(grep -o failover <<<"$CALLS" | wc -l)" == 2 && "$CALLS" != *verify* ]] && grep -q 'front door was NOT switched' <<<"$OUT" && ok "failed promotion: retry offered, never continues, exit 1" || bad "failed failover: rc=$RC calls=$CALLS"
STUB_RC_verify=1 walk '\n\n\n\n\nDESTROY\n\n\nPROMOTE\n\n\nq\n'
[[ "$RC" == 1 && "$CALLS" != *write-read* ]] && grep -q 'INTEGRITY CHECK FAILED' <<<"$OUT" && ok "failed integrity check is shown and stops the walkthrough" || bad "failed verify: rc=$RC calls=$CALLS"
STUB_RC_verify=3 walk "$FULL"
[[ "$RC" == 0 ]] && grep -q 'This run lost acknowledged writes' <<<"$OUT" && ok "RPO > 0 (exit 3) is highlighted, not hidden, and the demo continues" || bad "verify rc 3: rc=$RC"

walk '\n\n\n\ns\nv\nt\nr\nq\n'
[[ "$CALLS" == "up|selfcheck|status|seed|traffic start|traffic show 6|status|status|verify|traffic show 12|report" ]] && ok "read-only side actions (s/v/t/r) repeat checks without advancing" || bad "side menu: $CALLS"

PRESTATE='P=sw-demo-1\nPHASE=primary\n' walk ''
[[ "$RC" == 2 && "$CALLS" == "" ]] && ok "existing simulation without --resume is refused (exit 2), nothing run" || bad "existing: rc=$RC calls=$CALLS"
PRESTATE='P=sw-demo-1\nPHASE=failed-over\nSEED_CHECK_ID=x\n' walk 'q\n' --resume
[[ "$CALLS" == "selfcheck|traffic show 8|status" ]] && grep -q 'STAGE 09/16' <<<"$OUT" && ok "--resume re-checks isolation and continues at the right stage (failed-over -> 9)" || bad "resume: $CALLS"
walk '' --resume
[[ "$RC" == 2 ]] && ok "--resume with nothing to resume is refused" || bad "resume none: rc=$RC"
PRESTATE='P=sw-demo-1\nPHASE=disaster\n' walk '' --cleanup
[[ "$CALLS" == down && ! -e "${T}/state" ]] && ok "--cleanup only calls the engine's down" || bad "cleanup: $CALLS"

: > "${T}/calls.log"
( printf '\n' ; sleep 6 ) | env -u TMUX STOCKWATCH_DEMO_SCRIPT="${T}/stub-demo.sh" STUB_LOG="${T}/calls.log" STOCKWATCH_DEMO_DIR="${T}/state" NO_COLOR=1 \
  timeout --preserve-status -s INT 3 bash "$W" > "${T}/int.out" 2>&1; rc=$?
[[ "$rc" == 130 ]] && grep -q 'Interrupted (Ctrl-C)' "${T}/int.out" && ok "Ctrl-C: exit 130 with recovery instructions" || bad "Ctrl-C: rc=$rc"

if grep -nE '^[^#]*\bdocker (run|exec|rm|ps|inspect|stop|kill|start|network|volume)\b' "$W" >/dev/null; then bad "controller contains direct docker commands"
else ok "static: controller contains no direct docker commands"; fi
if grep -nE '^[^#]*(\$ROOT|ROOT\})/\.env|source[^#]*\.env|cat[^#]*\.env' "$W" >/dev/null; then bad "controller reads a .env"
else ok "static: controller never reads the production .env"; fi

if [[ "${SKIP_REAL:-}" == 1 ]]; then echo "Part B skipped (SKIP_REAL=1)"; echo; echo "Summary: ${PASS} passed, ${FAIL} failed"; [[ "$FAIL" -eq 0 ]]; exit $?; fi

echo "Part B — real walkthrough against dr-demo.sh"
prod_started() { docker ps --filter name='^stockwatch-' -q | xargs -r docker inspect -f '{{.Name}} {{.State.StartedAt}}' | sort; }
PROD_BEFORE="$(prod_started)"
export STOCKWATCH_DEMO_DIR="${T}/real" STOCKWATCH_DEMO_EVIDENCE_ROOT="${T}/evidence"
# full run; a short pause after traffic starts so the client has acknowledged writes
OUT="$( { printf '\n\n\n\n'; sleep 3; printf '\nDESTROY\n'; sleep 1; printf '\n\nPROMOTE\n\n\n\n\n\nFAILBACK\n\n\n\nDOWN\n'; } \
       | env -u TMUX NO_COLOR=1 bash "$W" 2>&1)"; RC=$?
printf '%s\n' "$OUT" > "${T}/real-run.log"
[[ "$RC" == 0 ]] && ok "real walkthrough completed (exit 0)" || { bad "real walkthrough: exit $RC"; grep -E 'failed|ERROR|✗' <<<"$OUT" | head -8; }
[[ "$(grep -c -- '-> MATCH' <<<"$OUT")" -ge 2 ]] && ok "integrity MATCH on DR and after failback" || bad "MATCH lines"
grep -q "front door now: app=secondary -> backend-melbourne" <<<"$OUT" && grep -q "front door now: app=primary -> backend-sydney2" <<<"$OUT" && ok "traffic switched to DR and back" || bad "front door switches"
grep -q 'stock check .* on this site: status=COMPLETED' <<<"$OUT" && grep -q 'GET  /api/inventory/.* -> sku DR-WRITE-failed-over' <<<"$OUT" && ok "DR write/read-back and DR worker stock check" || bad "DR write/stock check"
grep -q 'client_rto_ms=[0-9]' <<<"$OUT" && ok "report shows measured values" || bad "report"
[[ -z "$(docker ps -a --format '{{.Names}}' | grep '^sw-demo-')" && ! -e "${T}/real" ]] && ok "DOWN removed every simulation container and the state" || bad "leftovers after DOWN"
ev="$(ls -d "${T}"/evidence/demo-* 2>/dev/null | head -1)"; [[ -s "${ev}/measurements.txt" ]] && ok "evidence preserved" || bad "evidence"
{ printf '%s\n' "$OUT"; cat -- "${ev}"/* "${ev}"/*/* 2>/dev/null; } | grep -qE 'postgresql://[^:]+:[0-9a-f]{32}@|[0-9a-f]{32}@' && bad "credential URL in output/evidence" || ok "no credential in output or evidence"

# interrupted real run, then cleanup
OUT="$( { printf '\n\n\n'; } | env -u TMUX NO_COLOR=1 bash "$W" 2>&1)"; RC=$?
[[ "$RC" == 130 && -f "${T}/real/state.env" ]] && ok "real run aborted after traffic started: exit 130, simulation kept" || bad "abort real: rc=$RC"
OUT="$(env -u TMUX NO_COLOR=1 bash "$W" --cleanup 2>&1 </dev/null)"; RC=$?
[[ "$RC" == 0 && -z "$(docker ps -a --format '{{.Names}}' | grep '^sw-demo-')" && -z "$(docker network ls --format '{{.Name}}' | grep '^sw-demo-')" ]] && ok "--cleanup after interruption leaves no containers or networks" || bad "cleanup after interruption: rc=$RC"
[[ "$(prod_started)" == "$PROD_BEFORE" ]] && ok "production containers untouched (same start times)" || bad "production containers changed"

echo; echo "Summary: ${PASS} passed, ${FAIL} failed"; [[ "$FAIL" -eq 0 ]]
