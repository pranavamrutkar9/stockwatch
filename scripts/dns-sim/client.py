"""Test client: resolves RECORD_NAME via the simulated DNS server with a TTL-honouring cache (like a
stub resolver), then calls the resolved endpoint. Logs every resolution change and every request
outcome as JSON lines (monotonic + wall clock)."""
import json, os, random, socket, struct, time, urllib.request
DNS, NAME, LOG = os.environ["DNS_SERVER"], os.environ["RECORD_NAME"], os.environ["EVENT_LOG"]
PERIOD = float(os.environ.get("PERIOD", "0.25"))
def ev(kind, **kw):
    with open(LOG, "a") as f:
        f.write(json.dumps({"t_mono_ms": time.monotonic_ns() // 1_000_000, "t_wall": time.strftime("%H:%M:%S", time.gmtime()) + f".{int(time.time()*1000)%1000:03d}Z", "src": "client", "event": kind, **kw}) + "\n")
def resolve(name):
    tid = random.randint(0, 65535)
    q = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0"
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1)
    s.sendto(struct.pack(">HHHHHH", tid, 0x0100, 1, 0, 0, 0) + q + struct.pack(">HH", 1, 1), (DNS, 53))
    d, _ = s.recvfrom(512); an = struct.unpack(">H", d[6:8])[0]; o = 12 + len(q) + 4
    for _ in range(an):
        o += 2 if d[o] & 0xC0 == 0xC0 else len(q)
        t, _c, ttl, rl = struct.unpack(">HHIH", d[o:o + 10]); o += 10
        if t == 1: return socket.inet_ntoa(d[o:o + rl]), ttl
        o += rl
    return None, 0
cached_ip, expires, last_ip, last_region = None, 0.0, None, None
while True:
    now = time.monotonic()
    if cached_ip is None or now >= expires:
        try:
            ip, ttl = resolve(NAME)
            cached_ip, expires = ip, now + ttl
            if ip != last_ip: ev("resolved_new_ip", ip=ip, ttl=ttl); last_ip = ip
        except Exception as e:
            ev("dns_error", error=type(e).__name__)
    region = None
    try:
        with urllib.request.urlopen(f"http://{cached_ip}/api/region", timeout=1) as r: region = json.load(r)["region"]
    except Exception:
        region = None
    if region != last_region: ev("served_by", region=region or "UNAVAILABLE"); last_region = region
    time.sleep(PERIOD)
