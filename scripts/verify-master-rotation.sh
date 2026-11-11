#!/usr/bin/env bash
set -Euo pipefail
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
CA=/home/ubuntu/ap-southeast-2-bundle.pem
HOST=stockwatch-primary-db.cns8kouwop3n.ap-southeast-2.rds.amazonaws.com
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }

# psql_as <user> <password-from-stdin-var-name>: SQL as $3; prints result or error class only
psql_as() {
  local user="$1" pw="$2" sql="$3"
  PGPASSWORD="$pw" docker run --rm -i -e PGPASSWORD -e PGSSLMODE=verify-full -e PGSSLROOTCERT=/ca.pem -e PGAPPNAME=rotation-verify \
    -e PGOPTIONS="-c default_transaction_read_only=on" -v "$CA:/ca.pem:ro" postgres:16-alpine \
    psql -h "$HOST" -U "$user" -d stockwatch -X -q -t -A -c "$sql" 2>&1 | sed -E 's/password authentication failed.*/AUTH_FAILED/; s/postgres(ql)?:\/\/[^ ]*/<redacted>/g' | tail -1
}
url_pw() { python3 -c 'import sys;from urllib.parse import urlsplit,unquote;l=[x for x in open(sys.argv[1]) if x.startswith(sys.argv[2]+"=")][0];print(unquote(urlsplit(l.split("=",1)[1].strip().strip(chr(34))).password),end="")' "$1" "$2"; }

echo "1. RDS event"
ev="$(PATH=$HOME/.local/bin:$PATH aws rds describe-events --region ap-southeast-2 --source-type db-instance --source-identifier stockwatch-primary-db --start-time "$SINCE" --query "Events[?contains(Message,'master credentials')].Date" --output text 2>&1)"
[[ "$ev" =~ 20[0-9]{2}- ]] && ok "RDS event 'Reset master credentials' at ${ev}" || bad "no 'Reset master credentials' event since ${SINCE} (${ev:0:80})"

echo "2. Old master credential"
if [[ -f .env.pre-roles ]]; then
  r="$(psql_as stockwatch_admin "$(url_pw .env.pre-roles DATABASE_URL)" 'SELECT 1')"
  [[ "$r" == *AUTH_FAILED* ]] && ok "old master credential rejected" || bad "old master credential NOT rejected (${r:0:60})"
else
  bad ".env.pre-roles not found (old credential cannot be tested)"
fi

echo "3. New master credential (hidden prompt; not echoed or stored)"
read -r -s -p "  New RDS master password: " NEWPW; echo
r="$(psql_as stockwatch_admin "$NEWPW" "SELECT current_user || ' ssl=' || (SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()) || ' rds_superuser=' || pg_has_role('rds_superuser','MEMBER')")"
unset NEWPW
[[ "$r" == "stockwatch_admin ssl=true rds_superuser=true" ]] && ok "new master credential works ($r)" || bad "new master credential failed (${r:0:60})"

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
