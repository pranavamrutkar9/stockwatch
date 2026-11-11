"""Simulated regional endpoint for the local DNS failover demo (test-only).
GET /api/health -> {"status":"ok","region":REGION}; other paths -> {"region":REGION}."""
import json, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
REGION = os.environ["REGION"]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"status": "ok", "region": REGION}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
ThreadingHTTPServer(("0.0.0.0", 80), H).serve_forever()
