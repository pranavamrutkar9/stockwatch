#!/usr/bin/env bash
set -Eeuo pipefail
# ==========================================================================
# DESTRUCTIVE: restore a verified redis-backup.sh archive into a Redis data
# volume. Stops the container, keeps a safety copy of the current volume
# contents, replaces them, starts the container and verifies the key set.
#
#   redis-restore.sh --container NAME --volume VOLUME --backup DIR --confirm REDIS-RESTORE-<UTC yyyymmdd>
#
# After a restore, BullMQ jobs newer than the backup are absent; PENDING and
# PROCESSING stock checks are re-enqueued by the backend's
# StockCheckRecoveryService (PostgreSQL is the source of truth).
# ==========================================================================
CONTAINER="" VOLUME="" BACKUP="" CONFIRM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --container) CONTAINER="${2:?}"; shift ;;
    --volume) VOLUME="${2:?}"; shift ;;
    --backup) BACKUP="${2:?}"; shift ;;
    --confirm) CONFIRM="${2:?}"; shift ;;
    *) echo "ERROR: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$CONFIRM" == "REDIS-RESTORE-$(date -u +%Y%m%d)" ]] || { echo "ERROR: --confirm REDIS-RESTORE-$(date -u +%Y%m%d) required (destructive)." >&2; exit 2; }
[[ -n "$CONTAINER" && -n "$VOLUME" && -f "$BACKUP/redis-data.tgz" ]] || { echo "ERROR: --container, --volume and --backup are required." >&2; exit 2; }
grep -q '^verification=VERIFIED' "$BACKUP/manifest.txt" || { echo "ERROR: backup was not verified." >&2; exit 1; }
(cd "$BACKUP" && sha256sum -c --quiet redis-data.tgz.sha256) || { echo "ERROR: archive checksum mismatch." >&2; exit 1; }
BACKUP="$(realpath "$BACKUP")"
SAFETY="${BACKUP%/*}/pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -m 700 "$SAFETY"

echo "$(date -u +%FT%T.%3NZ) stopping ${CONTAINER}"; docker stop -t 30 "$CONTAINER" >/dev/null
docker run --rm --network none -v "$VOLUME:/data:ro" -v "$SAFETY:/out" redis:7-alpine tar -czf /out/redis-data.tgz -C /data .
echo "$(date -u +%FT%T.%3NZ) safety copy of current volume: ${SAFETY}"
docker run --rm --network none -v "$VOLUME:/data" -v "$BACKUP:/backup:ro" redis:7-alpine \
  sh -euc 'find /data -mindepth 1 -delete && tar -xzf /backup/redis-data.tgz -C /data && chown -R redis:redis /data'
docker start "$CONTAINER" >/dev/null; echo "$(date -u +%FT%T.%3NZ) started ${CONTAINER}"

# Persistent keys (TTL -1), filtered inside the container in one call (sorted).
persistent_keys() { # persistent_keys <container> [auth:true|false]
  docker exec "$1" sh -c 'if [ -n "$REDIS_PASSWORD" ] && [ "$0" = true ]; then export REDISCLI_AUTH="$REDIS_PASSWORD"; fi
    redis-cli --scan | while read -r k; do [ "$(redis-cli TTL "$k")" = "-1" ] && echo "$k"; done; true' "${2:-true}" | sort
}
rcli() { docker exec -i "$CONTAINER" sh -c 'if [ -n "$REDIS_PASSWORD" ]; then export REDISCLI_AUTH="$REDIS_PASSWORD"; fi; redis-cli "$@"' _ "$@"; }
for _ in $(seq 1 60); do [[ "$(rcli PING 2>/dev/null)" == PONG ]] && break; sleep 0.5; done
persistent_keys "$CONTAINER" > /tmp/restored-keys.$$
if diff -q "$BACKUP/keys.txt" /tmp/restored-keys.$$ >/dev/null; then
  rm -f /tmp/restored-keys.$$; echo "$(date -u +%FT%T.%3NZ) restore VERIFIED ($(wc -l < "$BACKUP/keys.txt") persistent keys)"
else
  rm -f /tmp/restored-keys.$$; echo "ERROR: restored key set differs from backup; safety copy at ${SAFETY}" >&2; exit 1
fi
