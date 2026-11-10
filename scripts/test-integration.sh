#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================================
# StockWatch isolated integration test harness.
#
# Starts throwaway PostgreSQL 16 and Redis 7 containers on a private Docker
# network (unique names, no published ports, no named volumes), then:
#   1. emulates the RDS permission model (non-superuser CREATEROLE admin that
#      owns the database) and provisions roles with db-roles.sh
#      (dry run must change nothing; apply; idempotent re-apply);
#   2. runs `prisma migrate deploy` as stockwatch_migrator;
#   3. verifies runtime privileges (DML allowed; DDL/TRUNCATE/migration ledger
#      denied) and migration privileges;
#   4. verifies the production path: ownership transfer of an admin-owned
#      schema, and password rotation;
#   5. runs the backend and worker integration suites as stockwatch_app.
# Everything is removed on exit. Never touches production containers,
# networks or volumes. Passwords are random and never printed.
#
# Usage: scripts/test-integration.sh            (from the repository root)
# ==========================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date +%s)-$$"
NET="sw-it-net-${RUN_ID}"
PG="sw-it-pg-${RUN_ID}"
REDIS="sw-it-redis-${RUN_ID}"
WORK="${STOCKWATCH_IT_WORKDIR:-${HOME}/.cache/stockwatch-it}/${RUN_ID}"
PG_IMAGE="postgres:16-alpine"
NODE_IMAGE="node:22-bookworm"

rand() { openssl rand -hex 24; }
SUPER_PW="$(rand)"; ADMIN_PW="$(rand)"; APP_PW="$(rand)"; MIGRATOR_PW="$(rand)"; APP_PW2="$(rand)"; REDIS_PW="$(rand)"
PASS=0; FAIL=0

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }

cleanup() {
  local rc=$?
  docker rm -fv "$PG" "$REDIS" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT

# psql as a given role: psql_as <user> <password> <db> (SQL on stdin)
psql_as() {
  PGPASSWORD="$2" docker run --rm -i --network "$NET" -e PGPASSWORD "$PG_IMAGE" \
    psql -h "$PG" -U "$1" -d "$3" -X -q -t -A -v ON_ERROR_STOP=1 2>&1
}
expect_ok() { # desc user pw db sql
  local out; if out="$(psql_as "$2" "$3" "$4" <<<"$5")"; then ok "$1"; else bad "$1 :: ${out}"; fi
}
expect_denied() { # desc user pw db sql
  local out; if out="$(psql_as "$2" "$3" "$4" <<<"$5")"; then bad "$1 (unexpectedly succeeded)";
  elif grep -qiE 'permission denied|must be owner|must have admin|not allowed' <<<"$out"; then ok "$1";
  else bad "$1 (wrong error: ${out})"; fi
}

log "Run ${RUN_ID}: creating isolated network and containers"
docker network create --internal "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" -e POSTGRES_USER=pgsuper -e POSTGRES_PASSWORD="$SUPER_PW" \
  -e POSTGRES_DB=postgres "$PG_IMAGE" >/dev/null
docker run -d --name "$REDIS" --network "$NET" -e REDIS_PW="$REDIS_PW" redis:7-alpine \
  sh -c 'exec redis-server --requirepass "$REDIS_PW" --appendonly no' >/dev/null
for _ in $(seq 1 30); do docker exec "$PG" pg_isready -U pgsuper -q && break; sleep 1; done
sleep 2

log "Emulating RDS: non-superuser CREATEROLE admin owning the databases"
psql_as pgsuper "$SUPER_PW" postgres >/dev/null <<SQL
CREATE ROLE stockwatch_admin LOGIN CREATEROLE CREATEDB NOSUPERUSER PASSWORD '${ADMIN_PW}';
CREATE DATABASE stockwatch OWNER stockwatch_admin;
CREATE DATABASE stockwatch_legacy OWNER stockwatch_admin;
SQL
ok "admin role and databases created (admin is not superuser)"

log "Preparing working-tree copy and dependencies"
mkdir -p "$WORK/src"
(cd "$ROOT" && git ls-files -co --exclude-standard -z | grep -zv '^node_modules/' | tar --null -T - -cf -) | tar -xf - -C "$WORK/src"
node_run() { # node_run <network> <cmd> [env...]
  local net="$1" cmd="$2"; shift 2
  docker run --rm --user "$(id -u):$(id -g)" --network "$net" -e HOME=/tmp -e CI=true \
    -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 -e COREPACK_HOME=/work/.corepack "$@" \
    -v "$WORK/src:/work" -w /work "$NODE_IMAGE" \
    bash -c "set -o pipefail; mkdir -p /tmp/bin && corepack enable --install-directory /tmp/bin && export PATH=/tmp/bin:\$PATH && $cmd"
}
node_run bridge "pnpm install --frozen-lockfile >/dev/null 2>&1 && pnpm db:build >/dev/null 2>&1 && echo deps-ready" | tail -1

db_roles() { # db_roles <db> [args...]
  ADMIN_DATABASE_URL="postgresql://stockwatch_admin:${ADMIN_PW}@${PG}:5432/$1" \
  APP_DB_PASSWORD="${APP_DB_PASSWORD:-}" MIGRATOR_DB_PASSWORD="${MIGRATOR_DB_PASSWORD:-}" \
    bash "$WORK/src/infrastructure/deployment/db-roles.sh" --docker-network "$NET" "${@:2}"
}

log "1. Role provisioning"
APP_DB_PASSWORD="$APP_PW" MIGRATOR_DB_PASSWORD="$MIGRATOR_PW" db_roles stockwatch > "$WORK/dry.txt" 2>&1 \
  && ok "dry run succeeded" || { bad "dry run failed"; sed -E 's/SCRAM[^ ]*/<r>/g' "$WORK/dry.txt"; }
roles="$(psql_as pgsuper "$SUPER_PW" postgres <<<"SELECT count(*) FROM pg_roles WHERE rolname IN ('stockwatch_app','stockwatch_migrator')")"
[[ "$roles" == 0 ]] && ok "dry run left no roles behind (rolled back)" || bad "dry run created roles ($roles)"

APP_DB_PASSWORD="$APP_PW" MIGRATOR_DB_PASSWORD="$MIGRATOR_PW" db_roles stockwatch --apply > "$WORK/apply1.txt" 2>&1 \
  && ok "apply succeeded" || { bad "apply failed"; cat "$WORK/apply1.txt"; }
grep -c 'SCRAM-SHA-256\$' "$WORK"/dry.txt "$WORK"/apply1.txt | grep -q ':[1-9]' && bad "verifier printed" || ok "no SCRAM verifier in script output"
for f in dry apply1; do grep -qF "$APP_PW" "$WORK/$f.txt" && bad "password printed ($f)" || true; done
psql_as pgsuper "$SUPER_PW" postgres <<<"SELECT rolpassword LIKE 'SCRAM-SHA-256\$%' FROM pg_authid WHERE rolname='stockwatch_app'" | grep -qx t \
  && ok "stored password is a SCRAM-SHA-256 verifier" || bad "password not stored as SCRAM"

log "2. Migrations as stockwatch_migrator"
MIGRATOR_URL="postgresql://stockwatch_migrator:${MIGRATOR_PW}@${PG}:5432/stockwatch?schema=public"
node_run "$NET" "node packages/database/node_modules/prisma/build/index.js migrate deploy --schema=packages/database/prisma/schema.prisma 2>&1 | tail -2" \
  -e DATABASE_URL="$MIGRATOR_URL" && ok "prisma migrate deploy as stockwatch_migrator" || bad "migrate deploy as migrator failed"
db_roles stockwatch --apply > "$WORK/apply2.txt" 2>&1 && ok "re-apply is idempotent (no passwords needed)" || { bad "re-apply failed"; cat "$WORK/apply2.txt"; }
echo "  ownership/privilege report after migration:"; sed -n '/object|owner/,/^(/p' "$WORK/apply2.txt" | sed 's/^/    /'

log "3. Runtime privilege boundary (stockwatch_app)"
A=(stockwatch_app "$APP_PW" stockwatch)
expect_ok "app: INSERT/SELECT/UPDATE/DELETE inventory" "${A[@]}" "
  INSERT INTO inventory_items (id,name,sku,category,quantity,\"minQuantity\",\"updatedAt\") VALUES ('p1','x','PRIV-1','c',1,2,now());
  UPDATE inventory_items SET quantity=5 WHERE id='p1'; SELECT count(*) FROM inventory_items; DELETE FROM inventory_items WHERE id='p1';"
expect_ok "app: INSERT ... ON CONFLICT DO NOTHING (createMany skipDuplicates)" "${A[@]}" "
  INSERT INTO stock_checks (id,\"jobId\") VALUES ('c1','c1') ON CONFLICT DO NOTHING;
  INSERT INTO stock_checks (id,\"jobId\") VALUES ('c1','c1') ON CONFLICT DO NOTHING; DELETE FROM stock_checks WHERE id='c1';"
expect_denied "app: CREATE TABLE" "${A[@]}" "CREATE TABLE evil (id int)"
expect_denied "app: DROP TABLE" "${A[@]}" "DROP TABLE stock_alerts"
expect_denied "app: ALTER TABLE" "${A[@]}" "ALTER TABLE stock_checks ADD COLUMN x int"
expect_denied "app: TRUNCATE" "${A[@]}" "TRUNCATE stock_checks"
expect_denied "app: read migration ledger" "${A[@]}" "SELECT * FROM _prisma_migrations"
expect_denied "app: CREATE ROLE" "${A[@]}" "CREATE ROLE evil"
expect_denied "app: CREATE TYPE" "${A[@]}" "CREATE TYPE evil AS ENUM ('x')"
PROBE_PW="$(rand)"; psql_as pgsuper "$SUPER_PW" postgres >/dev/null <<<"CREATE ROLE sw_probe LOGIN PASSWORD '${PROBE_PW}'"
expect_denied "PUBLIC CONNECT revoked: unprivileged role cannot connect" sw_probe "$PROBE_PW" stockwatch "SELECT 1"
expect_ok "app: role settings applied (statement_timeout=30s)" "${A[@]}" "DO \$\$ BEGIN IF current_setting('statement_timeout') <> '30s' THEN RAISE EXCEPTION 'timeout %', current_setting('statement_timeout'); END IF; END \$\$"
expect_denied "migrator: CREATE ROLE" stockwatch_migrator "$MIGRATOR_PW" stockwatch "CREATE ROLE evil"
expect_ok "migrator: DDL on owned schema (in rolled-back txn)" stockwatch_migrator "$MIGRATOR_PW" stockwatch "BEGIN; ALTER TABLE stock_checks ADD COLUMN probe int; ROLLBACK;"

log "4a. Production path: transfer ownership of an admin-owned schema"
ADMIN_LEGACY_URL="postgresql://stockwatch_admin:${ADMIN_PW}@${PG}:5432/stockwatch_legacy?schema=public"
node_run "$NET" "node packages/database/node_modules/prisma/build/index.js migrate deploy --schema=packages/database/prisma/schema.prisma >/dev/null 2>&1 && echo ok" \
  -e DATABASE_URL="$ADMIN_LEGACY_URL" | grep -qx ok && ok "legacy schema created by admin (as in production)" || bad "legacy migrate as admin failed"
psql_as stockwatch_admin "$ADMIN_PW" stockwatch_legacy >/dev/null <<<"INSERT INTO inventory_items (id,name,sku,category,quantity,\"minQuantity\",\"updatedAt\") VALUES ('l1','legacy','L-1','c',1,1,now())"
db_roles stockwatch_legacy > "$WORK/xfer-guard.txt" 2>&1 && bad "admin-owned schema accepted without --transfer-ownership" \
  || { grep -q 'not owned by stockwatch_migrator' "$WORK/xfer-guard.txt" && ok "guard: refuses to run on admin-owned schema without --transfer-ownership" || { bad "guard: unexpected error"; cat "$WORK/xfer-guard.txt"; }; }
db_roles stockwatch_legacy --transfer-ownership > "$WORK/xfer-dry.txt" 2>&1 && ok "transfer-ownership dry run" || { bad "transfer dry run failed"; cat "$WORK/xfer-dry.txt"; }
owners="$(psql_as pgsuper "$SUPER_PW" stockwatch_legacy <<<"SELECT string_agg(DISTINCT pg_get_userbyid(relowner), ',') FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND relkind='r'")"
[[ "$owners" == stockwatch_admin ]] && ok "dry run left ownership unchanged (stockwatch_admin)" || bad "dry run changed owners: $owners"
db_roles stockwatch_legacy --transfer-ownership --apply > "$WORK/xfer.txt" 2>&1 && ok "transfer-ownership apply" || { bad "transfer apply failed"; cat "$WORK/xfer.txt"; }
owners="$(psql_as pgsuper "$SUPER_PW" stockwatch_legacy <<<"SELECT string_agg(DISTINCT pg_get_userbyid(relowner), ',') FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND relkind='r'")"
typeowner="$(psql_as pgsuper "$SUPER_PW" stockwatch_legacy <<<"SELECT pg_get_userbyid(typowner) FROM pg_type WHERE typname='CheckStatus'")"
[[ "$owners" == stockwatch_migrator && "$typeowner" == stockwatch_migrator ]] && ok "all tables and enum now owned by stockwatch_migrator" || bad "owners tables=$owners type=$typeowner"
expect_ok "legacy: existing data readable and writable by app" stockwatch_app "$APP_PW" stockwatch_legacy "SELECT name FROM inventory_items WHERE id='l1'; UPDATE inventory_items SET quantity=2 WHERE id='l1';"
expect_denied "legacy: app cannot read migration ledger" stockwatch_app "$APP_PW" stockwatch_legacy "SELECT * FROM _prisma_migrations"
node_run "$NET" "node packages/database/node_modules/prisma/build/index.js migrate deploy --schema=packages/database/prisma/schema.prisma 2>&1 | grep -E 'No pending|applied' | head -1" \
  -e DATABASE_URL="postgresql://stockwatch_migrator:${MIGRATOR_PW}@${PG}:5432/stockwatch_legacy?schema=public" | grep -q 'No pending' \
  && ok "migrator can run migrate deploy on transferred schema" || bad "migrator migrate deploy on legacy failed"

log "4b. Password rotation"
APP_DB_PASSWORD="$APP_PW2" MIGRATOR_DB_PASSWORD="$MIGRATOR_PW" db_roles stockwatch --set-passwords --apply >/dev/null 2>&1 && ok "rotation applied" || bad "rotation failed"
expect_ok "app: new password works" stockwatch_app "$APP_PW2" stockwatch "SELECT 1"
psql_as stockwatch_app "$APP_PW" stockwatch <<<"SELECT 1" >/dev/null 2>&1 && bad "old password still works" || ok "app: old password rejected"
APP_DB_PASSWORD="$APP_PW" MIGRATOR_DB_PASSWORD="$MIGRATOR_PW" db_roles stockwatch --set-passwords --apply >/dev/null 2>&1

log "5. Integration suites as stockwatch_app (real Redis + PostgreSQL)"
APP_URL="postgresql://stockwatch_app:${APP_PW}@${PG}:5432/stockwatch?schema=public"
IT_ENV=(-e INTEGRATION_REDIS_HOST="$REDIS" -e REDIS_HOST="$REDIS" -e REDIS_PORT=6379 -e REDIS_PASSWORD="$REDIS_PW" -e DATABASE_URL="$APP_URL" -e NODE_ENV=test)
for pkg in backend worker; do
  if node_run "$NET" "cd apps/${pkg} && timeout 600 npx jest --runInBand --forceExit --testPathPattern integration --verbose 2>&1" "${IT_ENV[@]}" > "$WORK/jest-${pkg}.txt"; then
    ok "${pkg} integration suite"
  else
    bad "${pkg} integration suite"
  fi
  grep -E '✓|✕|Tests:|\[evidence\]' "$WORK/jest-${pkg}.txt" | sed 's/^/    /'
  for s in "$APP_PW" "$REDIS_PW"; do grep -qF "$s" "$WORK/jest-${pkg}.txt" && bad "${pkg} output contains a secret" || true; done
done

echo
log "Summary: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
