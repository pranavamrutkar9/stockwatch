#!/usr/bin/env bash
set -Euo pipefail
# Never trace this script: xtrace would print passwords passed between functions.
case $- in *x*) set +x; echo "NOTE: shell tracing disabled for this script (credentials)." >&2 ;; esac
# ==========================================================================
# Post-rotation verification for the RDS master password (stockwatch_admin).
# Run AFTER the password was changed in the RDS console. Nothing secret is
# printed or written to disk; the new password is read from a hidden prompt.
#
#   scripts/verify-master-rotation.sh --since <ISO-8601 UTC> [--delete-pre-roles]
#
# Checks:
#   1. RDS event "Reset master credentials" after --since (read-only API)
#   2. OLD master credential (from .env.pre-roles) is REJECTED
#   3. NEW master credential (hidden prompt) works, is stockwatch_admin, TLS verify-full
#   4. stockwatch_app and stockwatch_migrator (from .env) still work
#   5. backend/worker still connect as stockwatch_app and were NOT restarted
#   6. /api/health 200
# --delete-pre-roles removes .env.pre-roles only if every check passed.
# ==========================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 2
SINCE="" DELETE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="${2:?}"; shift ;;
    --delete-pre-roles) DELETE=true ;;
    *) echo "ERROR: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$SINCE" ]] || { echo "ERROR: --since <ISO-8601 UTC time just before the rotation> is required" >&2; exit 2; }
# Strict UTC format: the restart check compares timestamps as strings.
[[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { echo "ERROR: --since must be UTC like 2026-11-11T08:00:00Z" >&2; exit 2; }
CA=/home/ubuntu/ap-southeast-2-bundle.pem
HOST=stockwatch-primary-db.cns8kouwop3n.ap-southeast-2.rds.amazonaws.com
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }

# psql_as <user> <password> <sql>: read-only session (verify-full TLS). The password reaches psql only
# through the environment (never argv). Prints the single-line result, or one of:
#   AUTH_FAILED              - server reachable, credential rejected
#   CONN_FAILED: <reason>    - no authentication result (network, TLS, DNS, timeout, docker)
psql_as() {
  local user="$1" pw="$2" sql="$3" out
  out="$(PGPASSWORD="$pw" PGCONNECT_TIMEOUT=10 docker run --rm -i -e PGPASSWORD -e PGCONNECT_TIMEOUT -e PGSSLMODE=verify-full -e PGSSLROOTCERT=/ca.pem \
    -e PGAPPNAME=rotation-verify -e PGOPTIONS="-c default_transaction_read_only=on" -v "$CA:/ca.pem:ro" postgres:16-alpine \
    psql -h "$HOST" -U "$user" -d stockwatch -X -q -t -A -c "$sql" 2>&1 | tail -1)"
  if [[ "$out" == *"password authentication failed"* ]]; then echo "AUTH_FAILED"
  elif [[ "$out" == *"psql: error:"* || "$out" == *"docker:"* || "$out" == *"Error response from daemon"* || -z "$out" ]]; then
    echo "CONN_FAILED: $(sed -E 's/postgres(ql)?:\/\/[^ ]*/<redacted>/g; s/.*(timeout expired|Connection timed out|could not translate host name|certificate verify failed|Connection refused|No route to host|Error response from daemon).*/\1/' <<<"${out:-no output}" | cut -c1-60)"
  else echo "$out"; fi
}
url_pw() { python3 -c 'import sys;from urllib.parse import urlsplit,unquote;l=[x for x in open(sys.argv[1]) if x.startswith(sys.argv[2]+"=")][0];print(unquote(urlsplit(l.split("=",1)[1].strip().strip(chr(34))).password),end="")' "$1" "$2"; }

echo "1. RDS event"
ev="$(PATH=$HOME/.local/bin:$PATH aws rds describe-events --region ap-southeast-2 --source-type db-instance --source-identifier stockwatch-primary-db --start-time "$SINCE" --query "Events[?contains(Message,'master credentials')].Date" --output text 2>&1)"
ev_safe="$(sed -E 's/[0-9]{12}/<account>/g' <<<"$ev")"   # AWS error texts contain account IDs
[[ "$ev" =~ 20[0-9]{2}- ]] && ok "RDS event 'Reset master credentials' at ${ev_safe}" || bad "no 'Reset master credentials' event since ${SINCE} (${ev_safe:0:80})"

echo "2. Old master credential"
if [[ -f .env.pre-roles ]]; then
  r="$(psql_as stockwatch_admin "$(url_pw .env.pre-roles DATABASE_URL)" 'SELECT 1')"
  case "$r" in
    AUTH_FAILED) ok "old master credential rejected (authentication failed)" ;;
    CONN_FAILED*) bad "old credential could not be tested - ${r} (connection problem, not an authentication result)" ;;
    1) bad "old master credential still ACCEPTED" ;;
    *) bad "old master credential not verified (unexpected result: ${r:0:60})" ;;
  esac
else
  bad ".env.pre-roles not found (old credential cannot be tested)"
fi

echo "3. New master credential (hidden prompt; not echoed or stored)"
read -r -s -p "  New RDS master password: " NEWPW; echo
r="$(psql_as stockwatch_admin "$NEWPW" "SELECT current_user || ' ssl=' || (SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()) || ' rds_superuser=' || pg_has_role('rds_superuser','MEMBER')")"
unset NEWPW
case "$r" in
  "stockwatch_admin ssl=true rds_superuser=true") ok "new master credential works ($r)" ;;
  AUTH_FAILED) bad "new master credential REJECTED (authentication failed)" ;;
  *) bad "new master credential not verified (${r:0:60})" ;;
esac

echo "4. Application and migration credentials"
r="$(psql_as stockwatch_app "$(url_pw .env DATABASE_URL)" 'SELECT current_user')"; [[ "$r" == stockwatch_app ]] && ok "stockwatch_app works" || bad "stockwatch_app: ${r:0:60}"
r="$(psql_as stockwatch_migrator "$(url_pw .env MIGRATION_DATABASE_URL)" 'SELECT current_user')"; [[ "$r" == stockwatch_migrator ]] && ok "stockwatch_migrator works" || bad "stockwatch_migrator: ${r:0:60}"

echo "5. Running application"
for c in backend worker; do
  u="$(docker exec -w /app/packages/database "stockwatch-$c" node -e "const {PrismaClient}=require('@prisma/client');const p=new PrismaClient();p.\$queryRaw\`SELECT current_user u\`.then(r=>console.log(r[0].u)).catch(e=>console.log('ERR '+(e.errorCode||e.code))).finally(()=>p.\$disconnect())" 2>&1 | tail -1)"
  [[ "$u" == stockwatch_app ]] && ok "$c connects as stockwatch_app" || bad "$c: $u"
  started="$(docker inspect "stockwatch-$c" --format '{{.State.StartedAt}}')"
  [[ "$started" < "$SINCE" ]] && ok "$c not restarted (started ${started})" || bad "$c restarted at ${started}"
done
[[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://localhost/api/health)" == 200 ]] && ok "/api/health 200" || bad "/api/health not 200"

echo; echo "Summary: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -eq 0 && "$DELETE" == true ]]; then
  rm -f .env.pre-roles && echo "Deleted .env.pre-roles (last on-host copy of the old master credential)."
elif [[ "$DELETE" == true ]]; then
  echo ".env.pre-roles kept because a check failed."
fi
[[ "$FAIL" -eq 0 ]]
