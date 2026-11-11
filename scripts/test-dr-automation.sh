#!/usr/bin/env bash
set -Eeuo pipefail
# ==========================================================================
# Behavioural tests for infrastructure/deployment/dr (aws provider) using a
# stub `aws` CLI and a stub deploy.sh in a sandbox copy. No AWS API is called
# and no container is touched. Verifies dry-run safety, confirmation tokens,
# lag gates, billable gates, step order, idempotency and secret handling.
# ==========================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/sw-dr-test.XXXXXX")"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
TOKEN_F="FAILOVER-$(date -u +%Y%m%d)"; TOKEN_B="FAILBACK-$(date -u +%Y%m%d)"
SECRET="s3cret-$(openssl rand -hex 8)"

setup() { # setup <replica_is_standby:true|false> <lag:number|none>
  rm -rf "${SB:?}/repo" "${SB:?}/bin" "${SB:?}/ev"; mkdir -p "$SB/repo" "$SB/bin" "$SB/ev"
  (cd "$ROOT" && git ls-files -co --exclude-standard -z infrastructure/deployment | tar --null -T - -cf -) | tar -xf - -C "$SB/repo"
  cat > "$SB/repo/infrastructure/deployment/deploy.sh" <<'STUB'
#!/usr/bin/env bash
echo "deploy.sh $* target=${STOCKWATCH_TARGET:-} host=${RDS_EXPECTED_HOST:-}" >> "$CALLS"
STUB
  printf '{"status":"ok"}' > "$SB/health.json"
  cat > "$SB/bin/aws" <<STUB
#!/usr/bin/env bash
echo "aws \$*" >> "\$CALLS"
case "\$*" in
  *"sts get-caller-identity"*) echo '{"Account":"111122223333"}' ;;
  *"rds describe-db-instances"*)
    src=\$([[ "$1" == true ]] && echo '"ReadReplicaSourceDBInstanceIdentifier":"arn:aws:rds:ap-southeast-2:111122223333:db:stockwatch-primary-db",' || echo '')
    echo "{\"DBInstances\":[{\$src\"DBInstanceStatus\":\"available\",\"DBInstanceArn\":\"arn:aws:rds:ap-southeast-4:111122223333:db:stockwatch-dr-replica\",\"Endpoint\":{\"Address\":\"stockwatch-dr-replica.abc123.ap-southeast-4.rds.amazonaws.com\"}}]}" ;;
  *"cloudwatch get-metric-data"*) [[ "$2" == none ]] && echo '{"MetricDataResults":[{"Values":[]}]}' || echo '{"MetricDataResults":[{"Values":[$2]}]}' ;;
  *"ssm get-parameters-by-path"*) echo '{"Parameters":[{"Name":"/stockwatch/dr/DATABASE_URL","Value":"postgresql://stockwatch_app:$SECRET@old-host:5432/stockwatch?sslmode=require"},{"Name":"/stockwatch/dr/REDIS_PASSWORD","Value":"$SECRET"}]}' ;;
  *) echo '{}' ;;
esac
STUB
  chmod +x "$SB/bin/aws" "$SB/repo/infrastructure/deployment/deploy.sh"; : > "$SB/calls"
}
run() { # run <script> [args]
  set +e
  OUT="$(env PATH="$SB/bin:$PATH" CALLS="$SB/calls" HOME="$SB" DR_HOST_REGION="${HOST_REGION:-ap-southeast-4}" DR_IMAGE_TAG=0123456789abcdef0123456789abcdef01234567 \
    DR_HEALTH_URL="file://$SB/health.json" DNS_ZONE_ID=Z123 DNS_NAME=app.stockwatch-hz DNS_VALUE=10.42.0.10 \
    bash "$SB/repo/infrastructure/deployment/dr/$1" --provider aws --evidence-dir "$SB/ev/$RANDOM" "${@:2}" 2>&1)"; RC=$?
  set -e
}
mutating() { grep -cE 'promote-read-replica|send-command|change-resource-record-sets|create-db-instance-read-replica|deploy.sh|rds wait' "$SB/calls" || true; }
expect() { if [[ "$RC" == "$2" ]] && grep -qE -- "$3" <<<"$OUT"; then ok "$1"; else bad "$1 (rc=$RC)"; tail -4 <<<"$OUT" | sed 's/^/        /'; fi; }

echo "DR automation tests (aws provider, stub aws CLI; sandbox $SB)"
setup true 2.0; run dr-failover.sh
expect "failover dry run completes" 0 "DONE"
[[ "$(mutating)" == 0 ]] && ok "dry run makes no mutating AWS/deploy calls" || bad "dry run executed mutations: $(mutating)"
grep -q 'DRY-RUN.*promote stockwatch-dr-replica' <<<"$OUT" && ok "dry run shows the promotion step" || bad "promotion step not shown"

setup true 2.0; run dr-failover.sh --execute
expect "execute without --confirm refused" 1 "requires --confirm FAILOVER-"
setup true 2.0; run dr-failover.sh --execute --confirm FAILOVER-19990101
expect "execute with stale token refused" 1 "requires --confirm"
[[ "$(mutating)" == 0 ]] && ok "no mutation after refused confirmation" || bad "mutation despite refusal"

setup true none; run dr-failover.sh --execute --confirm "$TOKEN_F"
expect "unknown replication lag refused" 1 "lag unknown; refusing to promote"
setup true 900; run dr-failover.sh --execute --confirm "$TOKEN_F"
expect "lag above threshold refused" 1 "exceeds --max-lag-seconds 300"
[[ "$(mutating)" == 0 ]] && ok "no promotion when lag gate fails" || bad "promotion despite lag gate"

setup true 2.0; run dr-failover.sh --execute --confirm "$TOKEN_F"
expect "execute failover completes" 0 "DONE"
order="$(grep -oE 'promote-read-replica|rds wait|ssm get-parameters-by-path|deploy.sh|change-resource-record-sets' "$SB/calls" | tr '\n' ' ')"
[[ "$order" == "promote-read-replica rds wait ssm get-parameters-by-path deploy.sh change-resource-record-sets " ]] && ok "step order: promote -> wait -> render env -> deploy -> DNS" || bad "unexpected order: $order"
grep -q 'deploy.sh 0123456789abcdef0123456789abcdef01234567 target=melbourne host=stockwatch-dr-replica.abc123.ap-southeast-4' "$SB/calls" && ok "deploys pinned SHA with melbourne target and promoted endpoint" || bad "deploy invocation wrong"
[[ "$(stat -c %a "$SB/repo/.env")" == 600 ]] && ok ".env written with mode 600" || bad ".env mode"
grep -q '@stockwatch-dr-replica.abc123.ap-southeast-4.rds.amazonaws.com:5432/' "$SB/repo/.env" && ok ".env DATABASE_URL re-hosted to promoted endpoint" || bad ".env host not rewritten"
grep -qF "$SECRET" <<<"$OUT" && bad "secret printed" || ok "no secret in output"
grep -rqF "$SECRET" "$SB/ev" && bad "secret in evidence log" || ok "no secret in evidence"
s="$(cat "$SB"/ev/*/summary.json)"; grep -q '"rto_seconds"' <<<"$s" && grep -q '"replication_lag_at_t0": "2.0"' <<<"$s" && ok "summary.json records RTO and lag at T0" || bad "summary missing fields: $s"

setup false 0; run dr-failover.sh --execute --confirm "$TOKEN_F"
expect "re-run after promotion is idempotent" 0 "already promoted"
grep -q promote-read-replica "$SB/calls" && bad "promoted twice" || ok "no second promotion"

setup true 2.0; HOST_REGION=ap-southeast-2 run dr-failover.sh --execute --confirm "$TOKEN_F"
expect "execute on a Sydney (primary) host refused" 1 "must run on the ap-southeast-4 DR host"
[[ "$(mutating)" == 0 && ! -e "$SB/repo/.env" ]] && ok "primary-host refusal happens before any mutation or .env write" || bad "mutation on primary host"

setup false 0; run dr-failback.sh
expect "failback dry run shows billable reverse replica" 0 "BILLABLE: needs --allow-billable"
[[ "$(mutating)" == 0 ]] && ok "failback dry run makes no mutating calls" || bad "failback dry run mutated"
setup false 0; run dr-failback.sh --execute --confirm "$TOKEN_B"
expect "failback execute without --allow-billable refused" 1 "Billable step refused"
grep -q create-db-instance-read-replica "$SB/calls" && bad "billable call made" || ok "no billable call without --allow-billable"

echo; echo "Summary: ${PASS} passed, ${FAIL} failed"; [[ "$FAIL" -eq 0 ]]
