#!/usr/bin/env bash
set -Eeuo pipefail
# ==========================================================================
# Logical PostgreSQL backup + verification (read-only against the source).
#   1. pg_dump (custom format) in a read-only snapshot; sha256 recorded;
#   2. manifest: per-table row counts + content hashes captured in the SAME
#      snapshot as the dump (exported snapshot), plus server version and time;
#   3. verification: restore into a throwaway, network-isolated PostgreSQL 16
#      and compare the manifest; result recorded in the manifest;
#   4. retention: keep the newest --keep backups (default 14).
#
#   SOURCE_DATABASE_URL=... pg-backup-verify.sh [--ca-file PEM] [--dest DIR] [--keep N]
#                                               [--docker-network NET]
# Output: <dest>/<UTC timestamp>/{stockwatch.dump,stockwatch.dump.sha256,manifest.txt}
# ==========================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HASH_SQL="$(cat "${ROOT}/packages/database/sql/content-hash.sql")"
CA_FILE="" DEST="${HOME}/stockwatch-backups/postgres" KEEP=14 NETWORK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ca-file) CA_FILE="${2:?}"; shift ;;
    --dest) DEST="${2:?}"; shift ;;
    --keep) KEEP="${2:?}"; shift ;;
    --docker-network) NETWORK="${2:?}"; shift ;;
    *) echo "ERROR: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "${SOURCE_DATABASE_URL:-}" ]] || { echo "ERROR: SOURCE_DATABASE_URL is required." >&2; exit 2; }
[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --keep must be a positive integer." >&2; exit 2; }

eval "$(python3 - "$CA_FILE" <<'PY'
import os, shlex, sys
from urllib.parse import urlsplit, unquote
u = urlsplit(os.environ["SOURCE_DATABASE_URL"])
for k, v in {"SRC_HOST": u.hostname, "SRC_PORT": str(u.port or 5432), "SRC_USER": unquote(u.username or ""),
             "SRC_PASSWORD": unquote(u.password or ""), "SRC_DB": u.path.lstrip("/"),
             "SRC_SSLMODE": "verify-full" if sys.argv[1] else "prefer"}.items():
    print(f"{k}={shlex.quote(v)}")
PY
)"

TS="$(date -u +%Y%m%dT%H%M%SZ)"; OUT="${DEST}/${TS}"
mkdir -p "$DEST" && chmod 700 "$DEST"; mkdir -m 700 "$OUT"
RUN_ID="$(date +%s)-$$"; VNET="sw-bv-net-${RUN_ID}"; VPG="sw-bv-pg-${RUN_ID}"
cleanup() { local rc=$?; docker rm -fv "$VPG" >/dev/null 2>&1 || true; docker network rm "$VNET" >/dev/null 2>&1 || true; exit "$rc"; }
trap cleanup EXIT

src_args=(run --rm -i --user "$(id -u):$(id -g)" -e PGPASSWORD="$SRC_PASSWORD" -e PGSSLMODE="$SRC_SSLMODE"
  -e PGHOST="$SRC_HOST" -e PGPORT="$SRC_PORT" -e PGUSER="$SRC_USER" -e PGDATABASE="$SRC_DB" -v "$OUT:/out")
[[ -z "$NETWORK" ]] || src_args+=(--network "$NETWORK")
[[ -z "$CA_FILE" ]] || src_args+=(-e PGSSLROOTCERT=/ca.pem -v "$(realpath "$CA_FILE"):/ca.pem:ro")

# Dump and manifest from ONE read-only snapshot, in a single psql session:
# export the snapshot, hand it to pg_dump (\setenv + \!), then compute the
# manifest inside the same transaction.
docker "${src_args[@]}" postgres:16-alpine psql -X -q -t -A -v ON_ERROR_STOP=1 <<SQL
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT pg_export_snapshot() AS snap \gset
\setenv SNAP :snap
\! pg_dump --snapshot="\$SNAP" --format=custom --no-owner --no-privileges -f /out/stockwatch.dump || echo PG_DUMP_FAILED > /out/dump.failed
\o /out/server-version.txt
SELECT current_setting('server_version');
\o /out/source-hashes.txt
${HASH_SQL}
\o
COMMIT;
SQL
[[ ! -e "$OUT/dump.failed" && -s "$OUT/stockwatch.dump" ]] || { echo "ERROR: pg_dump failed." >&2; exit 1; }
(cd "$OUT" && sha256sum stockwatch.dump > stockwatch.dump.sha256)

# Verify: restore into a network-isolated throwaway PostgreSQL 16 and compare.
docker network create --internal "$VNET" >/dev/null
VPW="$(openssl rand -hex 16)"
docker run -d --name "$VPG" --network "$VNET" -e POSTGRES_PASSWORD="$VPW" -e POSTGRES_DB=verify postgres:16-alpine >/dev/null
for _ in $(seq 1 30); do docker exec "$VPG" pg_isready -U postgres -q && break; sleep 1; done; sleep 2
docker run --rm --user "$(id -u):$(id -g)" --network "$VNET" -e PGPASSWORD="$VPW" -v "$OUT:/in:ro" postgres:16-alpine \
  pg_restore -h "$VPG" -U postgres -d verify --no-owner --exit-on-error /in/stockwatch.dump
docker run --rm -i --network "$VNET" -e PGPASSWORD="$VPW" postgres:16-alpine \
  psql -h "$VPG" -U postgres -d verify -X -q -t -A -v ON_ERROR_STOP=1 <<<"$HASH_SQL" > "$OUT/restored-hashes.txt"

RESULT=FAILED; diff -q "$OUT/source-hashes.txt" "$OUT/restored-hashes.txt" >/dev/null && RESULT=VERIFIED
{
  echo "created_utc=${TS}"
  echo "source=${SRC_USER}@${SRC_HOST}:${SRC_PORT}/${SRC_DB}"
  echo "server_version=$(cat "$OUT/server-version.txt")"
  echo "dump_sha256=$(cut -d' ' -f1 "$OUT/stockwatch.dump.sha256")"
  echo "dump_bytes=$(stat -c %s "$OUT/stockwatch.dump")"
  echo "verification=${RESULT} (restored into isolated PostgreSQL 16; row counts + content hashes compared)"
  echo "tables:"; sed 's/^/  /' "$OUT/source-hashes.txt"
} > "$OUT/manifest.txt"
rm -f "$OUT/restored-hashes.txt" "$OUT/server-version.txt"
chmod 600 "$OUT"/*
cat "$OUT/manifest.txt"

# Retention (only verified backup directories are counted; never deletes the current one).
mapfile -t old < <(find "$DEST" -mindepth 1 -maxdepth 1 -type d -name '20*Z' | sort -r | tail -n +"$((KEEP + 1))")
for d in "${old[@]}"; do [[ "$d" != "$OUT" ]] && rm -rf "$d" && echo "retention: removed $(basename "$d")"; done

[[ "$RESULT" == VERIFIED ]] || { echo "ERROR: backup verification FAILED: ${OUT}" >&2; exit 1; }
echo "Backup verified: ${OUT}"
