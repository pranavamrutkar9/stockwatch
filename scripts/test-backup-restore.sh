#!/usr/bin/env bash
set -Eeuo pipefail
# ==========================================================================
# Isolated tests for infrastructure/deployment/backup/*.sh.
# Throwaway PostgreSQL 16 + Redis 7 (with a uniquely named test volume) on an
# internal Docker network; everything is removed on exit. No production
# container, network or volume is touched.
# ==========================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="${ROOT}/infrastructure/deployment/backup"
RUN="$(date +%s)-$$"; NET="sw-bt-net-${RUN}"; PG="sw-bt-pg-${RUN}"; RD="sw-bt-redis-${RUN}"; VOL="sw-bt-redis-data-${RUN}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sw-bt.XXXXXX")"
PGPW="$(openssl rand -hex 16)"; RPW="$(openssl rand -hex 16)"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
cleanup() {
  local rc=$?
  docker rm -fv "$PG" "$RD" >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker run --rm -v "$WORK:/w" alpine:latest rm -rf /w/pg /w/redis >/dev/null 2>&1 || true
  rm -rf "$WORK"; exit "$rc"
}
trap cleanup EXIT
psql_on() { docker run --rm -i --network "$NET" -e PGPASSWORD="$PGPW" postgres:16-alpine psql -h "$PG" -U postgres -d "$1" -X -q -t -A -v ON_ERROR_STOP=1; }
TODAY="$(date -u +%Y%m%d)"

docker network create --internal "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" -e POSTGRES_PASSWORD="$PGPW" -e POSTGRES_DB=stockwatch postgres:16-alpine >/dev/null
docker volume create "$VOL" >/dev/null
docker run -d --name "$RD" --network "$NET" -v "$VOL:/data" -e REDIS_PASSWORD="$RPW" redis:7-alpine \
  sh -c 'exec redis-server --appendonly yes --requirepass "$REDIS_PASSWORD"' >/dev/null
for _ in $(seq 1 30); do docker exec "$PG" pg_isready -U postgres -q && break; sleep 1; done; sleep 2

echo "== PostgreSQL"
psql_on stockwatch < "${ROOT}/packages/database/prisma/migrations/20261106000000_init/migration.sql" >/dev/null
psql_on stockwatch >/dev/null <<'SQL'
INSERT INTO inventory_items (id,name,sku,category,quantity,"minQuantity","updatedAt")
  SELECT 'i'||g, 'Item '||g, 'SKU-'||g, 'cat', g, 10, now() FROM generate_series(1,25) g;
INSERT INTO stock_checks (id,"jobId",status,"totalChecked","lowStockCount") VALUES ('c1','c1','COMPLETED',25,10);
INSERT INTO stock_alerts (id,"inventoryItemId","stockCheckId",quantity,"minQuantity",message)
  SELECT 'a'||g,'i'||g,'c1',g,10,'low' FROM generate_series(1,10) g;
SQL
SRC="postgresql://postgres:${PGPW}@${PG}:5432/stockwatch"
out="$(SOURCE_DATABASE_URL="$SRC" bash "$B/pg-backup-verify.sh" --dest "$WORK/pg" --docker-network "$NET" 2>&1)" \
  && grep -q 'verification=VERIFIED' <<<"$out" && ok "pg backup created and verified by isolated restore" || { bad "pg backup"; tail -5 <<<"$out"; }
grep -q 'inventory_items rows=25' <<<"$out" && grep -q 'stock_alerts rows=10' <<<"$out" && ok "manifest records row counts from the dump snapshot" || bad "manifest content"
grep -qF "$PGPW" <<<"$out" && bad "password printed" || ok "no password in output"
BK="$(find "$WORK/pg" -mindepth 1 -maxdepth 1 -type d -name '20*Z' | head -1)"
[[ -z "$(find "$WORK/pg" -mindepth 1 -maxdepth 1 -name '.incomplete-*')" ]] && ok "no .incomplete-* directory left after success" || bad "incomplete dir left behind"

echo "== Backup failure handling and retention"
rc=0; out="$(SOURCE_DATABASE_URL="postgresql://postgres:wrong-password@${PG}:5432/stockwatch" bash "$B/pg-backup-verify.sh" --dest "$WORK/pgfail" --docker-network "$NET" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] && ok "pg backup with bad credentials exits non-zero (rc=$rc)" || bad "bad-credential backup exited 0"
[[ -z "$(find "$WORK/pgfail" -mindepth 1 -maxdepth 1 -type d -name '20*Z' 2>/dev/null)" ]] && ok "failed backup is not published as a backup" || bad "failed backup published"
ls -d "$WORK"/pgfail/*.FAILED >/dev/null 2>&1 && ok "failed run kept as <ts>.FAILED for diagnosis" || bad "no .FAILED directory"
grep -qF "wrong-password" <<<"$out" && bad "credential printed on failure" || ok "no credential printed on failure"
sleep 1; SOURCE_DATABASE_URL="$SRC" bash "$B/pg-backup-verify.sh" --dest "$WORK/pgret" --docker-network "$NET" --keep 1 >/dev/null 2>&1
sleep 1; SOURCE_DATABASE_URL="$SRC" bash "$B/pg-backup-verify.sh" --dest "$WORK/pgret" --docker-network "$NET" --keep 1 >/dev/null 2>&1
n="$(find "$WORK/pgret" -mindepth 1 -maxdepth 1 -type d -name '20*Z' | wc -l)"; [[ "$n" == 1 ]] && ok "retention --keep 1: exactly 1 verified backup kept" || bad "retention kept $n"
KEPT="$(find "$WORK/pgret" -mindepth 1 -maxdepth 1 -type d -name '20*Z')"
sleep 1; SOURCE_DATABASE_URL="postgresql://postgres:wrong-password@${PG}:5432/stockwatch" bash "$B/pg-backup-verify.sh" --dest "$WORK/pgret" --docker-network "$NET" --keep 1 >/dev/null 2>&1 || true
[[ -d "$KEPT" ]] && ok "a failed run does NOT remove the last good backup (retention defect regression)" || bad "failed run deleted the last good backup"
sleep 1; SOURCE_DATABASE_URL="$SRC" bash "$B/pg-backup-verify.sh" --dest "$WORK/pgret" --docker-network "$NET" --keep 2 >/dev/null 2>&1
n="$(for d in "$WORK"/pgret/20*Z; do grep -q '^verification=VERIFIED' "$d/manifest.txt" 2>/dev/null && echo "$d"; done | wc -l)"
[[ -d "$KEPT" && "$n" == 2 ]] && ok "failed run + successful run with --keep 2: both good backups kept (failed run not counted)" || bad "retention counted a failed run: good backups kept=$n, previous good kept=$([[ -d "$KEPT" ]] && echo yes || echo no)"
[[ "$(stat -c %a "$BK")" == 700 && "$(stat -c %a "$BK/stockwatch.dump")" == 600 ]] && ok "backup dir 700 / files 600" || bad "backup permissions"

psql_on stockwatch <<<"CREATE DATABASE restored; CREATE DATABASE nonempty;" >/dev/null 2>&1 || true
psql_on postgres <<<"CREATE DATABASE restored" >/dev/null 2>&1 || true
psql_on postgres <<<"CREATE DATABASE nonempty" >/dev/null 2>&1 || true
psql_on nonempty <<<"CREATE TABLE inventory_items (id text)" >/dev/null
T="postgresql://postgres:${PGPW}@${PG}:5432"
out="$(TARGET_DATABASE_URL="$T/restored" bash "$B/pg-restore.sh" --backup "$BK" --confirm "RESTORE-19990101" --docker-network "$NET" 2>&1 || true)"
grep -q 'confirm RESTORE-' <<<"$out" && ok "pg restore: wrong token refused" || bad "pg restore token"
out="$(TARGET_DATABASE_URL="$T/nonempty" bash "$B/pg-restore.sh" --backup "$BK" --confirm "RESTORE-${TODAY}" --docker-network "$NET" 2>&1 || true)"
grep -q 'refusing to overwrite' <<<"$out" && ok "pg restore: non-empty target refused" || { bad "pg restore non-empty"; tail -3 <<<"$out"; }
out="$(TARGET_DATABASE_URL="$T/restored" bash "$B/pg-restore.sh" --backup "$BK" --confirm "RESTORE-${TODAY}" --docker-network "$NET" 2>&1)" \
  && grep -q 'restore VERIFIED' <<<"$out" && ok "pg restore into empty target verified against manifest" || { bad "pg restore"; tail -3 <<<"$out"; }
cp -a "$BK" "$WORK/tampered"; chmod 700 "$WORK/tampered"; chmod 600 "$WORK/tampered"/*; printf 'x' >> "$WORK/tampered/stockwatch.dump"
psql_on postgres <<<"CREATE DATABASE restored2" >/dev/null
out="$(TARGET_DATABASE_URL="$T/restored2" bash "$B/pg-restore.sh" --backup "$WORK/tampered" --confirm "RESTORE-${TODAY}" --docker-network "$NET" 2>&1 || true)"
grep -q 'checksum mismatch' <<<"$out" && ok "pg restore: tampered dump refused (checksum)" || bad "tamper not detected"

echo "== Interrupted backups (SIGTERM / Ctrl-C) leave nothing behind"
for sig in TERM INT; do
  for delay in 0.7 2.0; do
    D="$WORK/pg-int-$sig-$delay"; mkdir -p "$D"
    if [[ "$sig" == TERM ]]; then
      SOURCE_DATABASE_URL="$SRC" bash "$B/pg-backup-verify.sh" --dest "$D" --docker-network "$NET" >/dev/null 2>&1 & bp=$!
      sleep "$delay"; kill -TERM "$bp" 2>/dev/null; rc=0; wait "$bp" || rc=$?
    else   # foreground SIGINT, as delivered by Ctrl-C (background jobs ignore SIGINT)
      rc=0; SOURCE_DATABASE_URL="$SRC" timeout -s INT "$delay" bash "$B/pg-backup-verify.sh" --dest "$D" --docker-network "$NET" >/dev/null 2>&1 || rc=$?
    fi
    sleep 1
    left="$(docker ps -aq --filter name=sw-bv- | wc -l)$(docker network ls -q --filter name=sw-bv-net | wc -l)"
    pub="$(find "$D" -mindepth 1 -maxdepth 1 -name '20*Z' | wc -l)"; inc="$(find "$D" -mindepth 1 -maxdepth 1 -name '.incomplete-*' | wc -l)"
    if [[ "$rc" -ne 0 && "$pub" == 0 && "$inc" == 0 && "$left" == 00 ]]; then ok "SIG$sig after ${delay}s: non-zero exit, nothing published, no .incomplete, no leaked container/network"
    else bad "SIG$sig after ${delay}s: rc=$rc published=$pub incomplete=$inc leaked(containers,networks)=$left"; fi
    docker ps -aq --filter name=sw-bv- | xargs -r docker rm -fv >/dev/null 2>&1 || true; docker network ls -q --filter name=sw-bv-net | xargs -r docker network rm >/dev/null 2>&1 || true
  done
done

echo "== Redis"
r() { docker exec -i "$RD" sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli "$@"' _ "$@"; }
for _ in $(seq 1 20); do [[ "$(r PING 2>/dev/null)" == PONG ]] && break; sleep 0.5; done
r SET bull:stock-check:id 42 >/dev/null; r HSET bull:stock-check:c1 name process-check data '{"stockCheckId":"c1"}' >/dev/null
r ZADD bull:stock-check:completed 1 c1 >/dev/null; r SET bull:stock-check:stalled-check 1 PX 600000 >/dev/null
out="$(bash "$B/redis-backup.sh" --container "$RD" --volume "$VOL" --dest "$WORK/redis" 2>&1)" \
  && grep -q 'verification=VERIFIED' <<<"$out" && ok "redis backup created and verified in network-less Redis" || { bad "redis backup"; tail -5 <<<"$out"; }
grep -q 'persistent_keys=3' <<<"$out" && grep -q 'job_id_counter=42' <<<"$out" && ok "manifest: 3 persistent keys (volatile excluded), counter 42" || { bad "redis manifest"; grep -E 'persistent|counter' <<<"$out"; }
grep -qF "$RPW" <<<"$out" && bad "redis password printed" || ok "no redis password in output"
RB="$(find "$WORK/redis" -mindepth 1 -maxdepth 1 -type d -name '20*Z' | head -1)"
rc=0; out="$(bash "$B/redis-backup.sh" --container "$RD" --volume "sw-bt-no-such-volume-${RUN}" --dest "$WORK/redisfail" 2>&1)" || rc=$?
[[ "$rc" -ne 0 && -z "$(find "$WORK/redisfail" -mindepth 1 -maxdepth 1 -name '20*Z' 2>/dev/null)" ]] && ok "redis backup failure exits non-zero and publishes nothing" || bad "redis failure handling (rc=$rc)"

r FLUSHALL >/dev/null; r SET foreign-key 1 >/dev/null; r SET bull:stock-check:id 1 >/dev/null   # simulated loss + divergence
out="$(bash "$B/redis-restore.sh" --container "$RD" --volume "$VOL" --backup "$RB" --confirm "REDIS-RESTORE-19990101" 2>&1 || true)"
grep -q 'destructive' <<<"$out" && ok "redis restore: wrong token refused" || bad "redis restore token"
[[ "$(r GET foreign-key)" == 1 ]] && ok "refused restore left data untouched" || bad "refused restore changed data"
out="$(bash "$B/redis-restore.sh" --container "$RD" --volume "$VOL" --backup "$RB" --confirm "REDIS-RESTORE-${TODAY}" 2>&1)" \
  && grep -q 'restore VERIFIED' <<<"$out" && ok "redis restore verified (key set matches backup)" || { bad "redis restore"; tail -5 <<<"$out"; }
[[ "$(r GET bull:stock-check:id)" == 42 && -z "$(r GET foreign-key)" ]] && ok "job-id counter restored to 42; post-backup key gone" || bad "redis content after restore"
ls -d "$WORK"/redis/pre-restore-* >/dev/null 2>&1 && ok "safety copy of pre-restore volume kept" || bad "no safety copy"

echo; echo "Summary: ${PASS} passed, ${FAIL} failed"; [[ "$FAIL" -eq 0 ]]
