#!/usr/bin/env bash
set -Euo pipefail
# ==========================================================================
# End-to-end test of scripts/dr-demo.sh (the video demonstration) — LOCAL SIMULATION.
# Runs the complete demo (up, seed, traffic, disaster, failover, verify, write-check,
# failback, verify, down) in its own state and evidence directories, plus failure handling:
# commands out of order, a failed failover (standby missing) that must not switch the
# front door, checksum tampering that must be detected, no leaked credentials, and no
# change to the production containers (stockwatch-*). Takes about 2 minutes.
# ==========================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/sw-demo-test.XXXXXX")"
export STOCKWATCH_DEMO_DIR="${T}/state" STOCKWATCH_DEMO_EVIDENCE_ROOT="${T}/evidence"
DEMO="${ROOT}/scripts/dr-demo.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
run() { OUT="$(bash "$DEMO" "$@" 2>&1)"; RC=$?; printf '%s\n' "$OUT" >> "${T}/all-output.log"; }
expect_rc() { local want="$1" label="$2"; shift 2; run "$@"; [[ "$RC" == "$want" ]] && ok "$label (exit $RC)" || { bad "$label: exit $RC, expected $want"; tail -5 <<<"$OUT"; }; }
cleanup() {
  [[ -f "${STOCKWATCH_DEMO_DIR}/state.env" ]] && bash "$DEMO" down >/dev/null 2>&1
  docker run --rm -v "$T:/w" alpine:latest sh -c 'rm -rf /w/state' >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT
prod_started() { docker ps --filter name='^stockwatch-' -q | xargs -r docker inspect -f '{{.Name}} {{.State.StartedAt}}' | sort; }
PROD_BEFORE="$(prod_started)"

echo "Order and environment guards"
expect_rc 2 "status without an environment is refused" status
expect_rc 2 "unknown command prints usage" bogus
expect_rc 0 "up: both sites, replication and client start" up
grep -q 'sydney backend healthy' <<<"$OUT" && ok "up reports a healthy primary application" || bad "up output"
expect_rc 2 "second 'up' is refused while an environment exists" up
expect_rc 2 "disaster before seed is refused" disaster
expect_rc 2 "failover before disaster is refused" failover
expect_rc 2 "failback before failover is refused" failback

echo "Primary site"
expect_rc 0 "seed creates the known dataset" seed
expect_rc 2 "seed cannot run twice (baseline is immutable)" seed
# shellcheck source=/dev/null
source "${STOCKWATCH_DEMO_DIR}/state.env"
[[ "$(wc -l < "${EVID}/seed_ids.txt")" == 10 ]] && ok "10 known record ids saved as evidence" || bad "seed ids"
expect_rc 0 "traffic starts" traffic start
expect_rc 2 "traffic cannot be started twice" traffic start
sleep 4
expect_rc 0 "status" status
grep -q 'state=streaming' <<<"$OUT" && ok "primary reports a streaming replica" || bad "no streaming replica in status"
[[ "$(grep -c "seed_checksum=${SEED_SUM}" <<<"$OUT")" == 2 ]] && ok "standby already holds the identical seed checksum" || bad "standby checksum differs"
expect_rc 0 "verify on the primary" verify
grep -q -- '-> MATCH' <<<"$OUT" && ok "baseline checksum matches on the primary" || bad "primary checksum"

echo "Disaster and failover"
expect_rc 0 "disaster: sydney site destroyed and detected" disaster
grep -q 'consecutive failures=3' <<<"$OUT" && grep -q 'PRIMARY DOWN detected' <<<"$OUT" && ok "detector needed 3 consecutive failed probes" || bad "detector output"
docker inspect "${P}-pg-sydney" >/dev/null 2>&1 && bad "primary database still exists" || ok "primary database container is gone"
docker rename "${P}-pg-melbourne" "${P}-pg-melbourne-hidden"
expect_rc 1 "failover with the standby missing fails" failover
[[ "$(cat "${STOCKWATCH_DEMO_DIR}/dns/zone")" == app=primary ]] && ok "failed failover did not switch the front door" || bad "front door switched after a failed failover"
grep -q '^PHASE=disaster' "${STOCKWATCH_DEMO_DIR}/state.env" && ok "failed failover left the phase unchanged (retry possible)" || bad "phase changed"
docker rename "${P}-pg-melbourne-hidden" "${P}-pg-melbourne"
rm -rf "${EVID}/failover" "${EVID}/failover.out"
expect_rc 0 "failover (retry) succeeds" failover
[[ "$(cat "${STOCKWATCH_DEMO_DIR}/dns/zone")" == app=secondary ]] && ok "front door switched to the secondary" || bad "front door not switched"
grep -q 'first write acknowledged by melbourne' <<<"$OUT" && ok "client traffic acknowledged by melbourne" || bad "no melbourne traffic"
run verify
[[ "$RC" == 0 || "$RC" == 3 ]] && grep -q -- '-> MATCH' <<<"$OUT" && ok "after failover: seed checksum MATCH on melbourne (exit $RC; $(grep -o 'RPO (this run).*' <<<"$OUT"))" || bad "verify after failover: exit $RC"
expect_rc 0 "write + read-back and stock check on the DR site" write-check

echo "Failback"
expect_rc 0 "failback" failback
[[ "$(cat "${STOCKWATCH_DEMO_DIR}/dns/zone")" == app=primary ]] && grep -q '^primary=backend-sydney2' "${STOCKWATCH_DEMO_DIR}/dns/hosts" && ok "front door back on the rebuilt primary" || bad "front door after failback"
run verify
[[ "$RC" == 0 || "$RC" == 3 ]] && grep -q -- '-> MATCH' <<<"$OUT" && grep -q 'DR-WRITE-failed-over-[0-9]*: present' <<<"$OUT" && ok "after failback: seed MATCH and the DR-site write is present (exit $RC)" || bad "verify after failback: exit $RC"

echo "Integrity check is real"
docker exec -i "${P}-pg-sydney2" psql -U postgres -d stockwatch -tAq -c "UPDATE inventory_items SET quantity = quantity + 1 WHERE sku = 'DEMO-003'" >/dev/null
expect_rc 1 "tampered seed row is detected" verify
grep -q -- '-> MISMATCH' <<<"$OUT" && ok "verify prints MISMATCH" || bad "no MISMATCH"
docker exec -i "${P}-pg-sydney2" psql -U postgres -d stockwatch -tAq -c "UPDATE inventory_items SET quantity = quantity - 1 WHERE sku = 'DEMO-003'" >/dev/null
run verify; [[ "$RC" == 0 || "$RC" == 3 ]] && ok "restored row matches again" || bad "restore: exit $RC"

echo "Report, secrets and cleanup"
expect_rc 0 "report" report
m=0; for k in detection_ms failover_automation_s client_rto_ms failback_automation_s failback_db_write_freeze_ms; do
  grep -q "^${k}=[0-9.]*$" "${EVID}/measurements.txt" || { m=1; bad "measurement ${k} missing"; }
done; [[ "$m" == 0 ]] && ok "all measurements recorded as numbers"
leak=0
for v in "$SUPER_PW" "$REPL_PW" "$APP_PW" "$MIG_PW" "$REDIS_PW"; do grep -rqF -- "$v" "${EVID}" "${T}/all-output.log" && leak=1; done
[[ "$leak" == 0 ]] && ok "no simulation credential in any output or evidence file" || bad "credential leaked"
expect_rc 0 "down" down
[[ "$(docker ps -a --format '{{.Names}}' | grep -c "^${P}-")" == 0 && -z "$(docker network ls -q --filter "name=${NET}")" ]] && ok "no demo containers or network left" || bad "leftovers"
[[ ! -e "${STOCKWATCH_DEMO_DIR}" && -s "${EVID}/measurements.txt" ]] && ok "state removed, evidence kept" || bad "state/evidence"
[[ "$(prod_started)" == "$PROD_BEFORE" ]] && ok "production containers untouched (same start times)" || bad "production containers changed"

echo; echo "Summary: ${PASS} passed, ${FAIL} failed"; [[ "$FAIL" -eq 0 ]]
