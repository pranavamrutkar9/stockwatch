#!/usr/bin/env bash
set -Euo pipefail
# ==========================================================================
# Verifies whether containers can reach the EC2 instance-role credentials via
# IMDSv2 (the token handshake requires a PUT whose response must traverse the
# container network hop). Read-only: never fetches the credential document.
#
# For each running StockWatch container (plus a probe container on the app
# network for images without an HTTP client):
#   1. PUT /latest/api/token (IMDSv2 session token)
#   2. with the token: GET /latest/meta-data/iam/security-credentials/
#      -> returns only the ROLE NAME if credentials are reachable.
# The host itself is tested the same way (it must keep working: AWS CLI).
#
# Expected with HttpPutResponseHopLimit = 1: host REACHABLE, every container BLOCKED.
# Exit 0 only if no container can reach the credential path.
# ==========================================================================
NET="${STOCKWATCH_NETWORK:-stockwatch-network}"
PROBE_IMAGE="${PROBE_IMAGE:-node:22-bookworm}"
NODE_PROBE='
const http=require("http");
const req=(o,b)=>new Promise(r=>{const q=http.request({host:"169.254.169.254",timeout:2000,...o},s=>{let d="";s.on("data",c=>d+=c);s.on("end",()=>r({code:s.statusCode,body:d}))});q.on("timeout",()=>{q.destroy();r({code:"timeout"})});q.on("error",e=>r({code:e.code||"error"}));if(b)q.write(b);q.end()});
(async()=>{
 const t=await req({method:"PUT",path:"/latest/api/token",headers:{"X-aws-ec2-metadata-token-ttl-seconds":"60"}});
 if(t.code!==200){console.log(`token=${t.code} credential_path=not-attempted`);return}
 const c=await req({method:"GET",path:"/latest/meta-data/iam/security-credentials/",headers:{"X-aws-ec2-metadata-token":t.body}});
 console.log(`token=200 credential_path=${c.code}${c.code===200?" role="+c.body.trim().split("\n")[0]:""}`);
})();'
reachable=0
printf '%-28s %s\n' "host (EC2)" "$(t=$(curl -s -m 3 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' -o /dev/stdout -w '' 2>/dev/null); if [[ -n "$t" ]]; then echo "token=200 credential_path=$(curl -s -m 3 -o /dev/null -w '%{http_code}' -H "X-aws-ec2-metadata-token: $t" http://169.254.169.254/latest/meta-data/iam/security-credentials/)"; else echo "token=failed"; fi)"
for c in $(docker ps --format '{{.Names}}' | grep '^stockwatch-' | sort); do
  if docker exec "$c" sh -c 'command -v node >/dev/null' 2>/dev/null; then
    out="$(docker exec "$c" node -e "$NODE_PROBE" 2>&1 | tail -1)"; how="in-container (node)"
  else
    out="$(docker run --rm --network "$NET" "$PROBE_IMAGE" node -e "$NODE_PROBE" 2>&1 | tail -1)"; how="probe on ${NET}"
  fi
  [[ "$out" == *"credential_path=200"* ]] && reachable=$((reachable + 1))
  printf '%-28s %-58s [%s]\n' "$c" "$out" "$how"
done
out="$(docker run --rm --network bridge "$PROBE_IMAGE" node -e "$NODE_PROBE" 2>&1 | tail -1)"
[[ "$out" == *"credential_path=200"* ]] && reachable=$((reachable + 1))
printf '%-28s %-58s [%s]\n' "any container (bridge)" "$out" "probe on default bridge"
echo
if [[ "$reachable" -eq 0 ]]; then echo "RESULT: containers CANNOT reach instance-role credentials (isolated)"; exit 0; fi
echo "RESULT: ${reachable} container context(s) CAN reach instance-role credentials (hop limit too high)"; exit 1
