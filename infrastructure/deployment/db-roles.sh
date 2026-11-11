#!/usr/bin/env bash
set -Eeuo pipefail

# ========================================================
# StockWatch database role provisioning (runtime vs migration privileges)
#
# Applies packages/database/sql/roles.sql as the database owner / RDS master.
# Default is a DRY RUN: everything executes inside a transaction that is rolled
# back, so the output shows exactly what would change and validates the SQL
# against the live server without changing it.
#
# Usage:
#   ADMIN_DATABASE_URL=... [APP_DB_PASSWORD=...] [MIGRATOR_DB_PASSWORD=...] \
#     db-roles.sh [--apply] [--transfer-ownership] [--set-passwords]
#                 [--ca-file PATH] [--docker-network NAME] [--confirm-host HOST]
#
#   --apply               COMMIT instead of ROLLBACK
#   --transfer-ownership  make stockwatch_migrator own existing public objects (one-time)
#   --set-passwords       (re)set passwords from APP_DB_PASSWORD / MIGRATOR_DB_PASSWORD;
#                         passwords are always required when a role does not exist yet
#   --ca-file             CA bundle for verify-full TLS (required for RDS)
#   --docker-network      network for the psql container (isolated test databases)
#   --confirm-host        must equal the target host when it is an RDS endpoint
#
# Secrets: passwords are read from the environment, converted to SCRAM-SHA-256
# verifiers locally and sent on stdin; plaintext never reaches the server, logs
# or process arguments. Nothing secret is printed.
# ========================================================

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${DEPLOY_DIR}/../.." && pwd)"
SQL_FILE="${PROJECT_ROOT}/packages/database/sql/roles.sql"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:16-alpine}"

APPLY=false TRANSFER=false SET_PASSWORDS=false CA_FILE="" NETWORK="" CONFIRM_HOST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true ;;
    --transfer-ownership) TRANSFER=true ;;
    --set-passwords) SET_PASSWORDS=true ;;
    --ca-file) CA_FILE="${2:?}"; shift ;;
    --docker-network) NETWORK="${2:?}"; shift ;;
    --confirm-host) CONFIRM_HOST="${2:?}"; shift ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ -n "${ADMIN_DATABASE_URL:-}" ]] || { echo "ERROR: ADMIN_DATABASE_URL is required." >&2; exit 2; }
[[ -f "$SQL_FILE" ]] || { echo "ERROR: $SQL_FILE not found." >&2; exit 2; }
[[ -z "$CA_FILE" || -f "$CA_FILE" ]] || { echo "ERROR: CA file not found." >&2; exit 2; }

# Parse the admin URL (Prisma or libpq style) into libpq environment variables.
eval "$(python3 - "$CA_FILE" <<'PY'
import os, shlex, sys
from urllib.parse import urlsplit, parse_qs, unquote
u = urlsplit(os.environ["ADMIN_DATABASE_URL"])
if u.scheme not in ("postgres", "postgresql") or not u.hostname or not u.username:
    sys.exit("ERROR: ADMIN_DATABASE_URL must be postgresql://user:password@host:port/db")
q = parse_qs(u.query)
ca = sys.argv[1]
ssl = q.get("sslmode", ["prefer"])[0]
if ca:
    ssl = "verify-full"
elif ssl == "require" and q.get("sslaccept", [""])[0] == "strict":
    sys.exit("ERROR: strict TLS requested but --ca-file not given.")
env = {
    "PGHOST": u.hostname, "PGPORT": str(u.port or 5432), "PGUSER": unquote(u.username),
    "PGPASSWORD": unquote(u.password or ""), "PGDATABASE": u.path.lstrip("/") or "postgres",
    "PGSSLMODE": ssl, "PGAPPNAME": "stockwatch-db-roles",
}
for k, v in env.items():
    print(f"export {k}={shlex.quote(v)}")
PY
)"

if [[ "$PGHOST" == *.rds.amazonaws.com && "$CONFIRM_HOST" != "$PGHOST" ]]; then
  echo "ERROR: target is an RDS endpoint (${PGHOST}); re-run with --confirm-host ${PGHOST}" >&2
  exit 2
fi
if [[ "$PGHOST" == *.rds.amazonaws.com && -z "$CA_FILE" ]]; then
  echo "ERROR: --ca-file is required for RDS (verify-full TLS)." >&2
  exit 2
fi

scram() { # stdin: password -> stdout: SCRAM-SHA-256 verifier
  python3 -c '
import base64, hashlib, hmac, os, sys
pw = sys.stdin.read()
if not pw or not pw.isascii() or not pw.isprintable() or len(pw) < 24:
    sys.exit("ERROR: passwords must be >= 24 printable ASCII characters.")
salt, it = os.urandom(16), 4096
salted = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt, it)
ck = hmac.new(salted, b"Client Key", "sha256").digest()
sk = hmac.new(salted, b"Server Key", "sha256").digest()
b = lambda x: base64.b64encode(x).decode()
print(f"SCRAM-SHA-256${it}:{b(salt)}${b(hashlib.sha256(ck).digest())}:{b(sk)}", end="")'
}

APP_VERIFIER="" MIGRATOR_VERIFIER=""
if [[ "$SET_PASSWORDS" == true || -n "${APP_DB_PASSWORD:-}" || -n "${MIGRATOR_DB_PASSWORD:-}" ]]; then
  if [[ "$SET_PASSWORDS" == true ]]; then
    [[ -n "${APP_DB_PASSWORD:-}" && -n "${MIGRATOR_DB_PASSWORD:-}" ]] ||
      { echo "ERROR: --set-passwords needs APP_DB_PASSWORD and MIGRATOR_DB_PASSWORD." >&2; exit 2; }
  fi
  [[ -z "${APP_DB_PASSWORD:-}" ]] || APP_VERIFIER="$(printf '%s' "$APP_DB_PASSWORD" | scram)"
  [[ -z "${MIGRATOR_DB_PASSWORD:-}" ]] || MIGRATOR_VERIFIER="$(printf '%s' "$MIGRATOR_DB_PASSWORD" | scram)"
fi
# Without --set-passwords, supplied passwords are used only to create missing roles.
if [[ "$SET_PASSWORDS" != true ]]; then
  CREATE_ONLY=true
else
  CREATE_ONLY=false
fi

echo "========================================================"
echo "StockWatch DB roles — $( [[ $APPLY == true ]] && echo APPLY || echo 'DRY RUN (rolled back)' )"
echo "Target: ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE} (sslmode=${PGSSLMODE})"
echo "Transfer ownership: ${TRANSFER}; set passwords: ${SET_PASSWORDS}"
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "========================================================"

DOCKER_ARGS=(run --rm -i -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE -e PGAPPNAME)
[[ -z "$NETWORK" ]] || DOCKER_ARGS+=(--network "$NETWORK")
if [[ -n "$CA_FILE" ]]; then
  DOCKER_ARGS+=(-e PGSSLROOTCERT=/ca.pem -v "$(realpath "$CA_FILE"):/ca.pem:ro")
fi

set +e
OUTPUT="$(
  {
    echo "\\set app_verifier '${APP_VERIFIER}'"
    echo "\\set migrator_verifier '${MIGRATOR_VERIFIER}'"
    if [[ "$CREATE_ONLY" == true ]]; then
      # Supply verifiers only for roles that do not exist yet.
      echo "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname='stockwatch_app') THEN '' ELSE :'app_verifier' END AS app_verifier \\gset"
      echo "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname='stockwatch_migrator') THEN '' ELSE :'migrator_verifier' END AS migrator_verifier \\gset"
    fi
    echo "\\set transfer_ownership '${TRANSFER}'"
    echo "BEGIN;"
    cat "$SQL_FILE"
    if [[ "$APPLY" == true ]]; then echo "COMMIT;"; else echo "ROLLBACK;"; fi
  } | docker "${DOCKER_ARGS[@]}" "$PSQL_IMAGE" psql -X -v ON_ERROR_STOP=1 -P pager=off 2>&1
)"
RC=$?
set -e

# Never print verifiers (error context lines can echo the failing statement).
printf '%s\n' "$OUTPUT" | sed -E "s/SCRAM-SHA-256\\\$[^' ]*/<redacted-verifier>/g" \
  | grep -vE '^(GRANT|REVOKE|ALTER ROLE|ALTER TABLE|ALTER TYPE|ALTER SEQUENCE|BEGIN|SET|RESET|CREATE ROLE|ROLLBACK|COMMIT|ALTER DEFAULT PRIVILEGES|DO)$' || true
unset OUTPUT

if [[ "$RC" -ne 0 ]]; then
  echo "ERROR: psql failed (exit ${RC}); the transaction was rolled back." >&2
  exit 1
fi

unset PGPASSWORD APP_VERIFIER MIGRATOR_VERIFIER
echo "Done ($( [[ $APPLY == true ]] && echo committed || echo 'dry run: rolled back' ))."
