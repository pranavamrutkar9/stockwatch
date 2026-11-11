#!/usr/bin/env bash
set -Eeuo pipefail
# ==========================================================================
# Redis backup + verification.
#   1. BGSAVE and wait until LASTSAVE advances (consistent RDB snapshot);
#   2. archive the data volume READ-ONLY (RDB + AOF directory) with sha256;
#   3. verify: load the archive into a network-less throwaway Redis and compare
#      the persistent key set (keys without TTL) and the BullMQ job-id counter;
#   4. retention: keep the newest --keep backups (default 14).
#
#   redis-backup.sh --container NAME --volume VOLUME [--dest DIR] [--keep N]
# The Redis password is taken from the container's own REDIS_PASSWORD variable
# inside the container; it is never passed on a command line or printed.
# ==========================================================================
CONTAINER="" VOLUME="" DEST="${HOME}/stockwatch-backups/redis" KEEP=14
while [[ $# -gt 0 ]]; do
  case "$1" in
    --container) CONTAINER="${2:?}"; shift ;;
    --volume) VOLUME="${2:?}"; shift ;;
    --dest) DEST="${2:?}"; shift ;;
    --keep) KEEP="${2:?}"; shift ;;
    *) echo "ERROR: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$CONTAINER" && -n "$VOLUME" ]] || { echo "ERROR: --container and --volume are required." >&2; exit 2; }
docker volume inspect "$VOLUME" >/dev/null || { echo "ERROR: volume ${VOLUME} not found." >&2; exit 1; }

# Persistent keys (TTL -1), filtered inside the container in one call (sorted).
persistent_keys() { # persistent_keys <container> [auth:true|false]
  docker exec "$1" sh -c 'if [ -n "$REDIS_PASSWORD" ] && [ "$0" = true ]; then export REDISCLI_AUTH="$REDIS_PASSWORD"; fi
    redis-cli --scan | while read -r k; do [ "$(redis-cli TTL "$k")" = "-1" ] && echo "$k"; done; true' "${2:-true}" | sort
}
rcli() { docker exec -i "$CONTAINER" sh -c 'if [ -n "$REDIS_PASSWORD" ]; then export REDISCLI_AUTH="$REDIS_PASSWORD"; fi; redis-cli "$@"' _ "$@"; }
TS="$(date -u +%Y%m%dT%H%M%SZ)"; OUT="${DEST}/.incomplete-${TS}"; RESULT=""
mkdir -p "$DEST" && chmod 700 "$DEST"; mkdir -m 700 "$OUT"
VERIFY="sw-rv-${TS,,}-$$"
finalize_backup() { # finalize_backup <exit code>: publish only verified backups (called from the EXIT trap)
  local rc="$1"
  if [[ "${OUT:-}" == *"/.incomplete-"* && -d "$OUT" ]]; then
    if [[ "$rc" -eq 0 && "${RESULT:-}" == VERIFIED ]]; then mv "$OUT" "${DEST}/${TS}" && OUT="${DEST}/${TS}"
    else mv "$OUT" "${DEST}/${TS}.FAILED" 2>/dev/null && echo "Backup NOT published; kept for diagnosis: ${DEST}/${TS}.FAILED" >&2; fi
  fi
  return "$rc"
}
# errexit must not abort cleanup half-way (finalize_backup returns the failing code by design).
trap 'rc=$?; set +e; finalize_backup "$rc"; docker rm -fv "$VERIFY" >/dev/null 2>&1; exit $rc' EXIT
# On SIGTERM/SIGINT exit via the EXIT trap after the running docker command returns (no leaked containers).
trap 'exit 143' TERM
trap 'exit 130' INT

[[ "$(rcli PING)" == PONG ]] || { echo "ERROR: cannot authenticate to ${CONTAINER}." >&2; exit 1; }
before="$(rcli LASTSAVE)"; rcli BGSAVE >/dev/null
for _ in $(seq 1 60); do [[ "$(rcli LASTSAVE)" != "$before" ]] && break; sleep 0.5; done
[[ "$(rcli LASTSAVE)" != "$before" ]] || { echo "ERROR: BGSAVE did not complete." >&2; exit 1; }
# Persistent keys only (TTL -1); volatile keys (e.g. BullMQ stalled-check) legitimately differ.
persistent_keys "$CONTAINER" > "$OUT/keys.txt"
rcli GET bull:stock-check:id > "$OUT/job-id-counter.txt" || true

docker run --rm --network none -v "$VOLUME:/data:ro" -v "$OUT:/backup" redis:7-alpine \
  tar -czf /backup/redis-data.tgz -C /data .
docker run --rm --network none -v "$OUT:/backup" redis:7-alpine chown "$(id -u):$(id -g)" /backup/redis-data.tgz
(cd "$OUT" && sha256sum redis-data.tgz > redis-data.tgz.sha256)

docker run -d --name "$VERIFY" --network none -v "$OUT:/backup:ro" redis:7-alpine \
  sh -c 'mkdir -p /v && tar -xzf /backup/redis-data.tgz -C /v && exec redis-server --dir /v --appendonly yes' >/dev/null
for _ in $(seq 1 30); do [[ "$(docker exec "$VERIFY" redis-cli PING 2>/dev/null)" == PONG ]] && break; sleep 0.5; done
persistent_keys "$VERIFY" false > "$OUT/restored-keys.txt"
restored_counter="$(docker exec "$VERIFY" redis-cli GET bull:stock-check:id)"

RESULT=FAILED
if diff -q "$OUT/keys.txt" "$OUT/restored-keys.txt" >/dev/null && [[ "$restored_counter" == "$(cat "$OUT/job-id-counter.txt")" ]]; then RESULT=VERIFIED; fi
{
  echo "created_utc=${TS}"; echo "container=${CONTAINER} volume=${VOLUME}"
  echo "archive_sha256=$(cut -d' ' -f1 "$OUT/redis-data.tgz.sha256")"; echo "archive_bytes=$(stat -c %s "$OUT/redis-data.tgz")"
  echo "persistent_keys=$(wc -l < "$OUT/keys.txt")"; echo "job_id_counter=$(cat "$OUT/job-id-counter.txt")"
  echo "verification=${RESULT} (archive loaded into network-less Redis; persistent key set + job-id counter compared)"
} > "$OUT/manifest.txt"
rm -f "$OUT/restored-keys.txt"; chmod 600 "$OUT"/*
cat "$OUT/manifest.txt"

[[ "$RESULT" == VERIFIED ]] || { echo "ERROR: Redis backup verification FAILED" >&2; exit 1; }
mv "$OUT" "${DEST}/${TS}" && OUT="${DEST}/${TS}"
# Retention runs only after a VERIFIED backup and counts only VERIFIED backups; failed
# runs (<ts>.FAILED) and in-progress runs (.incomplete-*) never displace good backups.
mapfile -t verified < <(for d in "$DEST"/20*Z; do [[ -d "$d" ]] && grep -q '^verification=VERIFIED' "$d/manifest.txt" 2>/dev/null && echo "$d"; done | sort -r)
for d in "${verified[@]:$KEEP}"; do rm -rf "$d" && echo "retention: removed $(basename "$d")"; done
echo "Backup verified: ${OUT}"
