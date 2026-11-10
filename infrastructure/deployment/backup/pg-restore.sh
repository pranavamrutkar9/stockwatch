#!/usr/bin/env bash
set -Eeuo pipefail
# ==========================================================================
# Restore a verified pg-backup-verify.sh backup into a TARGET database
# (e.g. a new instance after primary-database loss). Refuses a target that
# already contains tables; verifies the dump checksum first; compares the
# restored content with the backup manifest.
#
#   TARGET_DATABASE_URL=... pg-restore.sh --backup DIR --confirm RESTORE-<UTC yyyymmdd>
#                                          [--ca-file PEM] [--docker-network NET]
# ==========================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HASH_SQL="$(cat "${ROOT}/packages/database/sql/content-hash.sql")"
BACKUP="" CONFIRM="" CA_FILE="" NETWORK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup) BACKUP="${2:?}"; shift ;;
    --confirm) CONFIRM="${2:?}"; shift ;;
    --ca-file) CA_FILE="${2:?}"; shift ;;
    --docker-network) NETWORK="${2:?}"; shift ;;
    *) echo "ERROR: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$CONFIRM" == "RESTORE-$(date -u +%Y%m%d)" ]] || { echo "ERROR: --confirm RESTORE-$(date -u +%Y%m%d) required." >&2; exit 2; }
[[ -n "${TARGET_DATABASE_URL:-}" && -f "$BACKUP/stockwatch.dump" && -f "$BACKUP/manifest.txt" ]] || { echo "ERROR: TARGET_DATABASE_URL and a backup directory are required." >&2; exit 2; }
grep -q '^verification=VERIFIED' "$BACKUP/manifest.txt" || { echo "ERROR: backup was not verified." >&2; exit 1; }
(cd "$BACKUP" && sha256sum -c --quiet stockwatch.dump.sha256) || { echo "ERROR: dump checksum mismatch." >&2; exit 1; }

eval "$(python3 - "$CA_FILE" <<'PY'
import os, shlex, sys
from urllib.parse import urlsplit, unquote
u = urlsplit(os.environ["TARGET_DATABASE_URL"])
for k, v in {"T_HOST": u.hostname, "T_PORT": str(u.port or 5432), "T_USER": unquote(u.username or ""),
             "T_PASSWORD": unquote(u.password or ""), "T_DB": u.path.lstrip("/"),
             "T_SSLMODE": "verify-full" if sys.argv[1] else "prefer"}.items():
    print(f"{k}={shlex.quote(v)}")
PY
)"
args=(run --rm -i -e PGPASSWORD="$T_PASSWORD" -e PGSSLMODE="$T_SSLMODE" -v "$(realpath "$BACKUP"):/in:ro")
[[ -z "$NETWORK" ]] || args+=(--network "$NETWORK")
[[ -z "$CA_FILE" ]] || args+=(-e PGSSLROOTCERT=/ca.pem -v "$(realpath "$CA_FILE"):/ca.pem:ro")
tpsql() { docker "${args[@]}" postgres:16-alpine psql -h "$T_HOST" -p "$T_PORT" -U "$T_USER" -d "$T_DB" -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }

n="$(tpsql -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")"
[[ "$n" == 0 ]] || { echo "ERROR: target already has ${n} tables in schema public; refusing to overwrite." >&2; exit 1; }
echo "$(date -u +%FT%TZ) restoring $(basename "$BACKUP") into ${T_USER}@${T_HOST}/${T_DB}"
docker "${args[@]}" postgres:16-alpine pg_restore -h "$T_HOST" -p "$T_PORT" -U "$T_USER" -d "$T_DB" --no-owner --exit-on-error /in/stockwatch.dump
tpsql <<<"$HASH_SQL" > /tmp/restored.$$
if diff -q <(sed -n 's/^  //p' "$BACKUP/manifest.txt") /tmp/restored.$$ >/dev/null; then
  rm -f /tmp/restored.$$; echo "$(date -u +%FT%TZ) restore VERIFIED (row counts + content hashes match manifest)"
else
  rm -f /tmp/restored.$$; echo "ERROR: restored content differs from manifest." >&2; exit 1
fi
