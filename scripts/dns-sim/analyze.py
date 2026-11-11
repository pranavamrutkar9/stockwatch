"""Computes failover/failback timings from the controller/client/orchestrator event logs."""
import json, sys
evs = sorted((json.loads(l) for p in sys.argv[1:] for l in open(p) if l.strip()), key=lambda e: e["t_mono_ms"])
def first(after, src, event, **match):
    for e in evs:
        if e["t_mono_ms"] >= after and e["src"] == src and e["event"] == event and all(e.get(k) == v for k, v in match.items()):
            return e["t_mono_ms"]
    return None
out = {}
for phase, inject_evt, target, region in (("failover", "primary_stopped", "secondary", "melbourne"), ("failback", "primary_restored", "primary", "sydney")):
    t0 = first(0, "orchestrator", inject_evt)
    det = first(t0, "controller", "failure_detected" if phase == "failover" else "recovery_detected")
    upd = first(t0, "controller", "dns_record_set", target=target)
    seen = first(t0, "client", "resolved_new_ip")
    served = first(t0, "client", "served_by", region=region)
    unavailable = first(t0, "client", "served_by", region="UNAVAILABLE")
    d = lambda a, b: None if a is None or b is None else b - a
    out[phase] = {"detection_ms": d(t0, det), "dns_update_ms": d(t0, upd), "client_observed_new_ip_ms": d(t0, seen),
                  "client_served_by_target_ms": d(t0, served), "client_saw_errors": unavailable is not None and (served is None or unavailable < served),
                  "client_error_window_ms": d(unavailable, served) if unavailable and served and unavailable < served else 0}
print(json.dumps(out, indent=2))
