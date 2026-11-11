#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================================
# Validates the production database-role migration plan WITHOUT changing the
# source database:
#   1. read-only catalog inspection of the source (SELECT only);
#   2. pg_dump of the source (read-only) restored into an isolated, throwaway
#      PostgreSQL 16 that emulates RDS (non-superuser CREATEROLE admin owning
#      the database and all objects, as in production);
#   3. db-roles.sh guard / dry run / --transfer-ownership --apply on the copy;
#   4. `prisma migrate status` + `migrate deploy` as stockwatch_migrator;
#   5. runtime privilege checks as stockwatch_app;
#   6. per-table row counts and deterministic content hashes compared between
#      the source and the copy before and after the role change.
#
# The dump is written to a private temp directory and deleted on exit.
# No secrets are printed.
#
# Usage:
#   SOURCE_DATABASE_URL=... scripts/rehearse-db-roles-on-copy.sh --ca-file /path/to/region-bundle.pem
# ==========================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CA_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ca-file) CA_FILE="${2:?}"; shift ;;
    *) echo "ERROR: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "${SOURCE_DATABASE_URL:-}" ]] || { echo "ERROR: SOURCE_DATABASE_URL is required." >&2; exit 2; }

RUN_ID="$(date +%s)-$$"; NET="sw-rh-net-${RUN_ID}"; PG="sw-rh-pg-${RUN_ID}"
PRIV="$(mktemp -d "${TMPDIR:-/tmp}/sw-rehearsal.XXXXXX")"; chmod 700 "$PRIV"
PG_IMAGE="postgres:16-alpine"
rand() { openssl rand -hex 24; }
SUPER_PW="$(rand)"; ADMIN_PW="$(rand)"; APP_PW="$(rand)"; MIGRATOR_PW="$(rand)"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
cleanup() { local rc=$?; docker rm -fv "$PG" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; rm -rf "$PRIV"; exit "$rc"; }
trap cleanup EXIT

# Source connection as libpq env (verify-full TLS when a CA file is given).
eval "$(python3 - "$CA_FILE" <<'PY'
import os, shlex, sys
from urllib.parse import urlsplit, unquote
u = urlsplit(os.environ["SOURCE_DATABASE_URL"])
env = {"SRC_HOST": u.hostname, "SRC_PORT": str(u.port or 5432), "SRC_USER": unquote(u.username or ""),
       "SRC_PASSWORD": unquote(u.password or ""), "SRC_DB": u.path.lstrip("/"),
       "SRC_SSLMODE": "verify-full" if sys.argv[1] else "prefer"}
for k, v in env.items(): print(f"{k}={shlex.quote(v)}")
PY
)"
src_psql() { # read-only session to the source
  local args=(run --rm -i -e PGPASSWORD="$SRC_PASSWORD" -e PGSSLMODE="$SRC_SSLMODE" -e PGOPTIONS="-c default_transaction_read_only=on")
  [[ -z "$CA_FILE" ]] || args+=(-e PGSSLROOTCERT=/ca.pem -v "$(realpath "$CA_FILE"):/ca.pem:ro")
  docker "${args[@]}" "$PG_IMAGE" psql -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" -X -q -A -F ' | ' -v ON_ERROR_STOP=1 "$@"
}
copy_psql() { # copy_psql <user> <password> <db> [psql args]
  PGPASSWORD="$2" docker run --rm -i --network "$NET" -e PGPASSWORD "$PG_IMAGE" psql -h "$PG" -U "$1" -d "$3" -X -q -A -t -v ON_ERROR_STOP=1 "${@:4}" 2>&1
}

HASH_SQL="SELECT t.relname || ' rows=' || (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM public.%I', t.relname), false, true, '')))[1]::text
  || ' sha256=' || left(encode(sha256(convert_to(coalesce((xpath('/row/h/text()', query_to_xml(format(
     'SELECT string_agg(md5(x::text), '','' ORDER BY md5(x::text)) AS h FROM public.%I x', t.relname), false, true, '')))[1]::text, ''), 'UTF8')), 'hex'), 16)
FROM pg_class t JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'public' AND t.relkind = 'r' AND t.relname <> '_prisma_migrations' ORDER BY 1;"

log "1. Read-only catalog inspection of the source (default_transaction_read_only=on)"
src_psql <<'SQL' | sed 's/^/    /'
\pset footer off
SELECT 'server' AS item, current_setting('server_version') AS value
UNION ALL SELECT 'current_user', current_user
UNION ALL SELECT 'session read-only', current_setting('default_transaction_read_only')
UNION ALL SELECT 'user attributes', format('super=%s createrole=%s createdb=%s', rolsuper, rolcreaterole, rolcreatedb) FROM pg_roles WHERE rolname = current_user
UNION ALL SELECT 'member of rds_superuser', coalesce((SELECT 'yes' FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid WHERE r.rolname = 'rds_superuser' AND m.member = current_user::regrole), 'no')
UNION ALL SELECT 'createrole_self_grant', coalesce(current_setting('createrole_self_grant', true), '(unset)')
UNION ALL SELECT 'password_encryption', current_setting('password_encryption')
UNION ALL SELECT 'rds.force_ssl', coalesce(current_setting('rds.force_ssl', true), '(n/a)')
UNION ALL SELECT 'max_connections', current_setting('max_connections')
UNION ALL SELECT 'database owner', pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database()
UNION ALL SELECT 'database ACL', coalesce(datacl::text, '(default: PUBLIC has CONNECT, TEMP)') FROM pg_database WHERE datname = current_database()
UNION ALL SELECT 'public schema owner', pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'public'
UNION ALL SELECT 'existing stockwatch_* roles', coalesce(string_agg(rolname, ', '), '(none)') FROM pg_roles WHERE rolname LIKE 'stockwatch\_%' AND rolname <> current_user
UNION ALL SELECT 'object owners (public)', string_agg(DISTINCT pg_get_userbyid(relowner), ', ') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND relkind IN ('r','S','v','m')
UNION ALL SELECT 'enum owner', pg_get_userbyid(typowner) FROM pg_type WHERE typname = 'CheckStatus'
UNION ALL SELECT 'applied migrations', string_agg(migration_name || CASE WHEN finished_at IS NULL THEN ' (UNFINISHED)' ELSE '' END, ', ') FROM _prisma_migrations
UNION ALL SELECT 'sessions by user', string_agg(u || '=' || n, ', ') FROM (SELECT coalesce(usename, '(bg)') u, count(*) n FROM pg_stat_activity WHERE datname = current_database() GROUP BY 1) s;
SQL
src_psql -t <<<"$HASH_SQL" > "$PRIV/source-hashes.txt"; sed 's/^/    source: /' "$PRIV/source-hashes.txt"

log "2. Dump (read-only) and restore into isolated PostgreSQL 16 emulating RDS ownership"
docker network create --internal "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" -e POSTGRES_USER=pgsuper -e POSTGRES_PASSWORD="$SUPER_PW" "$PG_IMAGE" >/dev/null
for _ in $(seq 1 30); do docker exec "$PG" pg_isready -U pgsuper -q && break; sleep 1; done; sleep 2
copy_psql pgsuper "$SUPER_PW" postgres >/dev/null <<SQL
CREATE ROLE stockwatch_admin LOGIN CREATEROLE CREATEDB NOSUPERUSER PASSWORD '${ADMIN_PW}';
CREATE DATABASE stockwatch OWNER stockwatch_admin;
SQL
dump_args=(run --rm -e PGPASSWORD="$SRC_PASSWORD" -e PGSSLMODE="$SRC_SSLMODE" -v "$PRIV:/out")
[[ -z "$CA_FILE" ]] || dump_args+=(-e PGSSLROOTCERT=/ca.pem -v "$(realpath "$CA_FILE"):/ca.pem:ro")
docker "${dump_args[@]}" "$PG_IMAGE" pg_dump -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" \
  --format=custom --no-owner --no-privileges -f /out/source.dump
ok "pg_dump of source completed ($(du -h "$PRIV/source.dump" | cut -f1))"
docker run --rm -i --network "$NET" -e PGPASSWORD="$ADMIN_PW" -v "$PRIV:/in:ro" "$PG_IMAGE" \
  pg_restore -h "$PG" -U stockwatch_admin -d stockwatch --no-owner --role=stockwatch_admin --exit-on-error /in/source.dump \
  && ok "restored into copy as stockwatch_admin (objects admin-owned, as in production)" || bad "restore failed"
copy_psql stockwatch_admin "$ADMIN_PW" stockwatch <<<"$HASH_SQL" > "$PRIV/copy-before.txt"
diff -q "$PRIV/source-hashes.txt" "$PRIV/copy-before.txt" >/dev/null && ok "copy content identical to source (row counts + hashes)" || bad "copy differs from source"

db_roles() { ADMIN_DATABASE_URL="postgresql://stockwatch_admin:${ADMIN_PW}@${PG}:5432/stockwatch" \
  APP_DB_PASSWORD="$APP_PW" MIGRATOR_DB_PASSWORD="$MIGRATOR_PW" bash "$ROOT/infrastructure/deployment/db-roles.sh" --docker-network "$NET" "$@"; }

log "3. Role plan on the copy"
db_roles > "$PRIV/guard.txt" 2>&1 && bad "plan accepted admin-owned schema without --transfer-ownership" \
  || { grep -q 'not owned by stockwatch_migrator' "$PRIV/guard.txt" && ok "guard: refuses admin-owned schema without --transfer-ownership" || { bad "unexpected guard error"; cat "$PRIV/guard.txt"; }; }
db_roles --transfer-ownership > "$PRIV/dry.txt" 2>&1 && ok "dry run with --transfer-ownership (rolled back)" || { bad "dry run failed"; cat "$PRIV/dry.txt"; }
[[ "$(copy_psql pgsuper "$SUPER_PW" postgres <<<"SELECT count(*) FROM pg_roles WHERE rolname IN ('stockwatch_app','stockwatch_migrator')")" == 0 ]] \
  && ok "dry run left no roles" || bad "dry run left roles"
db_roles --transfer-ownership --apply > "$PRIV/apply.txt" 2>&1 && ok "apply with --transfer-ownership" || { bad "apply failed"; cat "$PRIV/apply.txt"; }
sed -n '/rolname/,/^(/p;/object |/,/^(/p' "$PRIV/apply.txt" | sed 's/^/    /'
grep -qF -- "$APP_PW" "$PRIV/apply.txt" && bad "password in output" || ok "no password in output"

log "4. Migrations as stockwatch_migrator"
MIG_URL="postgresql://stockwatch_migrator:${MIGRATOR_PW}@${PG}:5432/stockwatch?schema=public"
backend_image="$(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -m1 'stockwatch-backend:[0-9a-f]\{40\}' || true)"
if [[ -n "$backend_image" ]]; then
  out="$(docker run --rm --network "$NET" -e DATABASE_URL="$MIG_URL" "$backend_image" node /app/packages/database/node_modules/prisma/build/index.js migrate status --schema=/app/packages/database/prisma/schema.prisma 2>&1 || true)"
  grep -q 'Database schema is up to date' <<<"$out" && ok "migrate status as migrator: up to date (${backend_image##*:})" || { bad "migrate status"; tail -3 <<<"$out"; }
  out="$(docker run --rm --network "$NET" -e DATABASE_URL="$MIG_URL" "$backend_image" node /app/packages/database/node_modules/prisma/build/index.js migrate deploy --schema=/app/packages/database/prisma/schema.prisma 2>&1 || true)"
  grep -q 'No pending migrations' <<<"$out" && ok "migrate deploy as migrator: no pending migrations, permitted" || { bad "migrate deploy"; tail -3 <<<"$out"; }
else
  bad "no local stockwatch-backend:<sha> image available for prisma CLI"
fi

log "5. Runtime privileges as stockwatch_app"
app() { copy_psql stockwatch_app "$APP_PW" stockwatch <<<"$1"; }
out="$(app "SELECT count(*) FROM inventory_items; SELECT count(*) FROM stock_checks; SELECT count(*) FROM stock_alerts;")" && ok "app: reads all tables ($(tr '\n' '/' <<<"$out" | sed 's#/$##'))" || bad "app read: $out"
out="$(app "BEGIN; INSERT INTO stock_checks (id, \"jobId\") VALUES ('rehearsal', 'rehearsal'); UPDATE stock_checks SET status='COMPLETED' WHERE id='rehearsal'; DELETE FROM stock_checks WHERE id='rehearsal'; ROLLBACK;")" && ok "app: insert/update/delete (rolled back)" || bad "app DML: $out"
for sql in "CREATE TABLE x (i int)" "TRUNCATE stock_alerts" "DROP TABLE stock_alerts" "SELECT * FROM _prisma_migrations" "ALTER TABLE stock_checks ADD COLUMN x int"; do
  out="$(app "$sql" || true)"; grep -qiE 'permission denied|must be owner' <<<"$out" && ok "app denied: $sql" || bad "app NOT denied: $sql ($out)"
done

log "6. Data integrity after the role change"
# After the transfer the master user no longer owns or inherits table access (membership is
# INHERIT FALSE); break-glass reads require an explicit SET ROLE.
out="$(copy_psql stockwatch_admin "$ADMIN_PW" stockwatch <<<"SELECT 1 FROM stock_checks LIMIT 1" || true)"
grep -q 'permission denied' <<<"$out" \
  && ok "master user has no implicit table access after transfer (break-glass needs SET ROLE)" || bad "master user still reads tables implicitly"
copy_psql stockwatch_admin "$ADMIN_PW" stockwatch <<<"SET ROLE stockwatch_migrator; $HASH_SQL" > "$PRIV/copy-after.txt"
diff -q "$PRIV/source-hashes.txt" "$PRIV/copy-after.txt" >/dev/null && ok "row counts and content hashes unchanged by the role change" || bad "data changed"

echo
log "Summary: ${PASS} passed, ${FAIL} failed (source database was accessed read-only)"
[[ "$FAIL" -eq 0 ]]
