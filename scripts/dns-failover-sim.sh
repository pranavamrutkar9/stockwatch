#!/usr/bin/env bash
set -Eeuo pipefail
# ==========================================================================
# LOCAL DNS FAILOVER SIMULATION (Option C) — NOT AWS Route 53.
#
# Isolated Docker network (internal, test-only names under dr.test):
#   sydney     simulated primary endpoint     10.249.0.10
#   melbourne  simulated secondary endpoint   10.249.0.20
#   coredns    authoritative for dr.test      10.249.0.53  (hosts plugin, reload 1 s, TTL 5 s)
#   controller health-checks the primary every 1 s; 3 failures -> record points to melbourne;
#              3 successes -> record points back to sydney (Route 53's role)
#   client     resolves app.stockwatch.dr.test with a TTL-honouring cache every 250 ms and
#              records which region served each request
# Per round: steady state -> stop sydney (failure) -> automatic failover -> start sydney ->
# automatic failback. Timings use CLOCK_MONOTONIC shared by all containers on this kernel.
#
# Usage: scripts/dns-failover-sim.sh [--rounds N]
# Evidence: ~/stockwatch-dr-evidence/dns-sim-<run>/
# ==========================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="${ROOT}/scripts/dns-sim"
ROUNDS=3
[[ "${1:-}" == "--rounds" ]] && ROUNDS="${2:?}"
RUN="$(date +%s)"; P="sw-dns-${RUN}"; NET="${P}-net"
EVID="${HOME}/stockwatch-dr-evidence/dns-sim-${RUN}"; mkdir -p "$EVID"; chmod 700 "$EVID"
PY=python:3.13-alpine; COREDNS=coredns/coredns:1.12.1
NAME="app.stockwatch.dr.test"; TTL=5; INTERVAL=1; FAILS=3; OKS=3

mono() { python3 -c 'import time;print(time.monotonic_ns()//1000000)'; }
orch() { printf '{"t_mono_ms": %s, "t_wall": "%s", "src": "orchestrator", "event": "%s"}\n' "$(mono)" "$(date -u +%H:%M:%S.%3NZ)" "$1" >> "$ROUND_DIR/orchestrator.jsonl"; echo "[$(date -u +%H:%M:%S.%3N)] $1"; }
cleanup() { local rc=$?; docker ps -a --format '{{.Names}}' | grep "^${P}-" | xargs -r docker rm -fv >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; exit "$rc"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
wait_for() { # wait_for <jsonl> <grep pattern> <timeout_s>
  local deadline=$(( $(date +%s) + $3 ))
  while (( $(date +%s) < deadline )); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.2; done
  return 1
}

docker network create --internal --subnet 10.249.0.0/24 "$NET" >/dev/null
echo "Local DNS failover simulation ${RUN}: ${ROUNDS} round(s); evidence ${EVID}"

for round in $(seq 1 "$ROUNDS"); do
  ROUND_DIR="${EVID}/round-${round}"; mkdir -p "$ROUND_DIR/records"
  : > "$ROUND_DIR/controller.jsonl"; : > "$ROUND_DIR/client.jsonl"; : > "$ROUND_DIR/orchestrator.jsonl"
  cat > "$ROUND_DIR/Corefile" <<EOF
dr.test:53 {
    hosts /etc/coredns/records/hosts {
        ttl ${TTL}
        reload 1s
        no_reverse
    }
    errors
}
EOF
  echo "127.0.0.1 placeholder.dr.test" > "$ROUND_DIR/records/hosts"
  run_py() { # run_py <name> <ip> <script> [env...]
    local name="$1" ip="$2" script="$3"; shift 3
    docker run -d --name "${P}-${name}" --network "$NET" --ip "$ip" --user "$(id -u):$(id -g)" \
      -v "$SIM:/sim:ro" -v "$ROUND_DIR:/evidence" "$@" "$PY" python -u "/sim/${script}" >/dev/null
  }
  run_py sydney 10.249.0.10 endpoint.py -e REGION=sydney
  run_py melbourne 10.249.0.20 endpoint.py -e REGION=melbourne
  docker run -d --name "${P}-coredns" --network "$NET" --ip 10.249.0.53 \
    -v "$ROUND_DIR/Corefile:/etc/coredns/Corefile:ro" -v "$ROUND_DIR/records:/etc/coredns/records:ro" \
    "$COREDNS" -conf /etc/coredns/Corefile >/dev/null
  run_py controller 10.249.0.30 controller.py -e PRIMARY_IP=10.249.0.10 -e SECONDARY_IP=10.249.0.20 \
    -e RECORD_NAME="$NAME" -e HOSTS_FILE=/evidence/records/hosts -e EVENT_LOG=/evidence/controller.jsonl \
    -e INTERVAL="$INTERVAL" -e FAIL_THRESHOLD="$FAILS" -e OK_THRESHOLD="$OKS"
  run_py client 10.249.0.40 client.py -e DNS_SERVER=10.249.0.53 -e RECORD_NAME="$NAME" -e EVENT_LOG=/evidence/client.jsonl -e PERIOD=0.25

  wait_for "$ROUND_DIR/client.jsonl" '"region": "sydney"' 30 || { echo "ERROR: client never reached sydney"; docker logs "${P}-coredns" | tail -5; exit 1; }
  sleep 5; orch steady_state_on_primary
  orch primary_stopped; docker stop -t 0 "${P}-sydney" >/dev/null
  wait_for "$ROUND_DIR/client.jsonl" '"region": "melbourne"' 60 || { echo "ERROR: no failover"; exit 1; }
  sleep 5; orch steady_state_on_secondary
  orch primary_restored; docker start "${P}-sydney" >/dev/null
  sleep 1; grep -c '"region": "sydney"' "$ROUND_DIR/client.jsonl" >/dev/null
  deadline=$(( $(date +%s) + 60 ))
  until [[ "$(grep -c '"region": "sydney"' "$ROUND_DIR/client.jsonl")" -ge 2 ]] || (( $(date +%s) > deadline )); do sleep 0.2; done
  sleep 3; orch round_complete
  docker ps -a --format '{{.Names}}' | grep "^${P}-" | xargs -r docker rm -fv >/dev/null
  python3 "$SIM/analyze.py" "$ROUND_DIR/orchestrator.jsonl" "$ROUND_DIR/controller.jsonl" "$ROUND_DIR/client.jsonl" > "$ROUND_DIR/analysis.json"
  echo "round ${round}: $(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(" | ".join(f"{k}: detect {v["detection_ms"]} ms, dns {v["dns_update_ms"]} ms, client sees new IP {v["client_observed_new_ip_ms"]} ms, served by target {v["client_served_by_target_ms"]} ms" for k,v in d.items()))' "$ROUND_DIR/analysis.json")"
done

python3 - "$EVID" "$ROUNDS" "$INTERVAL" "$FAILS" "$OKS" "$TTL" > "$EVID/summary.md" <<'PY'
import json, statistics, sys, pathlib
ev, n = pathlib.Path(sys.argv[1]), int(sys.argv[2]); interval, fails, oks, ttl = sys.argv[3:7]
rounds = [json.loads((ev / f"round-{i}" / "analysis.json").read_text()) for i in range(1, n + 1)]
keys = ["detection_ms", "dns_update_ms", "client_observed_new_ip_ms", "client_served_by_target_ms", "client_error_window_ms"]
print(f"# Local DNS failover simulation — {n} rounds (LOCAL SIMULATION, not AWS Route 53)\n")
print(f"Parameters: health interval {interval} s, failover after {fails} failures, failback after {oks} successes, record TTL {ttl} s, CoreDNS hosts reload 1 s.\n")
for phase in ("failover", "failback"):
    print(f"## {phase}\n\n| Metric (ms from injection) | " + " | ".join(f"round {i}" for i in range(1, n + 1)) + " | median |\n|---|" + "---|" * (n + 1))
    for k in keys:
        vals = [r[phase][k] for r in rounds]
        med = statistics.median([v for v in vals if isinstance(v, (int, float))]) if all(isinstance(v, (int, float)) for v in vals) else "n/a"
        print(f"| {k} | " + " | ".join(str(v) for v in vals) + f" | {med} |")
    print()
PY
cat "$EVID/summary.md"
echo "Evidence: ${EVID}"
