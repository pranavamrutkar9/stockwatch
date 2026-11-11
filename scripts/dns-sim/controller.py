"""Health-check-driven DNS failover controller (plays Route 53's role in the local demo).
Probes the PRIMARY endpoint every INTERVAL seconds; after FAIL_THRESHOLD consecutive failures it
rewrites the CoreDNS hosts file so app.<zone> points to the SECONDARY; after OK_THRESHOLD consecutive
successes it fails back. All events are JSON lines with monotonic (CLOCK_MONOTONIC, shared by all
containers on the host kernel) and wall-clock timestamps."""
import json, os, sys, time, urllib.request
P_IP, S_IP = os.environ["PRIMARY_IP"], os.environ["SECONDARY_IP"]
NAME, HOSTS, LOG = os.environ["RECORD_NAME"], os.environ["HOSTS_FILE"], os.environ["EVENT_LOG"]
INTERVAL = float(os.environ.get("INTERVAL", "1")); FAILS = int(os.environ.get("FAIL_THRESHOLD", "3")); OKS = int(os.environ.get("OK_THRESHOLD", "3"))
def ev(kind, **kw):
    with open(LOG, "a") as f:
        f.write(json.dumps({"t_mono_ms": time.monotonic_ns() // 1_000_000, "t_wall": time.strftime("%H:%M:%S", time.gmtime()) + f".{int(time.time()*1000)%1000:03d}Z", "src": "controller", "event": kind, **kw}) + "\n")
def write_record(ip):
    tmp = HOSTS + ".tmp"
    with open(tmp, "w") as f: f.write(f"{ip} {NAME}\n")
    os.replace(tmp, HOSTS)
def healthy():
    try:
        with urllib.request.urlopen(f"http://{P_IP}/api/health", timeout=1) as r:
            return r.status == 200 and json.load(r).get("status") == "ok"
    except Exception:
        return False
active = "primary"; write_record(P_IP); ev("dns_record_set", target="primary", ip=P_IP)
fails = oks = 0
while True:
    ok = healthy()
    if ok: fails, oks = 0, oks + 1
    else: oks, fails = 0, fails + 1
    ev("probe", target="primary", healthy=ok)
    if active == "primary" and fails >= FAILS:
        ev("failure_detected", consecutive_failures=fails); write_record(S_IP); active = "secondary"; ev("dns_record_set", target="secondary", ip=S_IP)
    elif active == "secondary" and oks >= OKS:
        ev("recovery_detected", consecutive_successes=oks); write_record(P_IP); active = "primary"; ev("dns_record_set", target="primary", ip=P_IP)
    sys.stdout.flush(); time.sleep(INTERVAL)
