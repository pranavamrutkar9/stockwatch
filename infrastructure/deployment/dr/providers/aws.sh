#!/usr/bin/env bash
# shellcheck shell=bash
# AWS provider: Sydney primary -> Melbourne cross-region read replica.
# Configuration (environment):
#   DR_REGION=ap-southeast-4  PRIMARY_REGION=ap-southeast-2
#   DR_REPLICA_ID=stockwatch-dr-replica  PRIMARY_DB_ID=stockwatch-primary-db
#   DR_IMAGE_TAG=<40-char sha>  DR_SSM_PREFIX=/stockwatch/dr/  DR_HEALTH_URL=http://localhost/api/health
#   PRIMARY_INSTANCE_ID=<i-...> (optional: fence the Sydney app via SSM)
#   DNS_ZONE_ID / DNS_NAME / DNS_VALUE / DNS_FAILBACK_VALUE (optional: private-zone record switch)
#   FAILBACK_REPLICA_ID=stockwatch-primary-db-v2 (failback target in Sydney)

: "${DR_REGION:=ap-southeast-4}" "${PRIMARY_REGION:=ap-southeast-2}"
: "${DR_REPLICA_ID:=stockwatch-dr-replica}" "${PRIMARY_DB_ID:=stockwatch-primary-db}"
: "${DR_SSM_PREFIX:=/stockwatch/dr/}" "${DR_HEALTH_URL:=http://localhost/api/health}"
: "${FAILBACK_REPLICA_ID:=stockwatch-primary-db-v2}"

# Repository root (this file lives in infrastructure/deployment/dr/providers/).
DR_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

_aws() { aws --output json "$@"; }
_db() { _aws rds describe-db-instances --region "$1" --db-instance-identifier "$2"; }
_jq() { python3 -c "import json,sys;d=json.load(sys.stdin)['DBInstances'][0];print(eval(sys.argv[1]))" "$1"; }

dr_p_name() { echo "aws (${PRIMARY_REGION} -> ${DR_REGION})"; }

_host_region() { # region of the machine running this script (IMDSv2), overridable for tests
  if [[ -n "${DR_HOST_REGION:-}" ]]; then echo "$DR_HOST_REGION"; return; fi
  local tok
  tok="$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)"
  curl -s -m 2 -H "X-aws-ec2-metadata-token: ${tok}" http://169.254.169.254/latest/meta-data/placement/region || echo unknown
}

dr_p_preflight() {
  # Failover rewrites .env and redeploys on THIS host: it must be the DR host, never the primary.
  local host_region; host_region="$(_host_region)"
  if [[ "$DR_EXECUTE" == true && "$host_region" != "$DR_REGION" ]]; then
    dr_die "this host is in ${host_region}; failover must run on the ${DR_REGION} DR host"
  fi
  dr_log "CHECK" "host region=${host_region}"
  command -v aws >/dev/null || dr_die "aws CLI not found"
  _aws sts get-caller-identity >/dev/null || dr_die "no AWS credentials"
  [[ "${DR_IMAGE_TAG:-}" =~ ^[0-9a-f]{40}$ ]] || dr_die "DR_IMAGE_TAG must be a 40-character commit SHA"
  local status; status="$(_db "$DR_REGION" "$DR_REPLICA_ID" | _jq "d['DBInstanceStatus']")" || dr_die "replica ${DR_REPLICA_ID} not found in ${DR_REGION}"
  dr_log "CHECK" "replica status=${status}"
}

dr_p_is_standby() { # true while still a replica
  local src; src="$(_db "$DR_REGION" "$DR_REPLICA_ID" | _jq "d.get('ReadReplicaSourceDBInstanceIdentifier') or ''")"
  [[ -n "$src" ]]
}

dr_p_replication_lag() { # seconds (CloudWatch ReplicaLag, last 5 min) or "unknown"
  local end start
  end="$(date -u +%FT%TZ)"; start="$(date -u -d '-5 min' +%FT%TZ)"
  _aws cloudwatch get-metric-data --region "$DR_REGION" --start-time "$start" --end-time "$end" \
    --metric-data-queries "[{\"Id\":\"lag\",\"MetricStat\":{\"Metric\":{\"Namespace\":\"AWS/RDS\",\"MetricName\":\"ReplicaLag\",\"Dimensions\":[{\"Name\":\"DBInstanceIdentifier\",\"Value\":\"${DR_REPLICA_ID}\"}]},\"Period\":60,\"Stat\":\"Maximum\"}}]" \
    | python3 -c 'import json,sys;v=json.load(sys.stdin)["MetricDataResults"][0]["Values"];print(v[0] if v else "unknown")' 2>/dev/null || echo unknown
}

dr_p_fence_primary() {
  if [[ -z "${PRIMARY_INSTANCE_ID:-}" ]]; then dr_log "SKIP" "fence primary: PRIMARY_INSTANCE_ID not set (assumed unreachable)"; return 0; fi
  dr_mutate false "fence Sydney app (stop backend/worker via SSM)" -- \
    aws ssm send-command --region "$PRIMARY_REGION" --instance-ids "$PRIMARY_INSTANCE_ID" --document-name AWS-RunShellScript \
    --parameters 'commands=["cd /home/ubuntu/stockwatch && docker compose -p docker -f infrastructure/docker/docker-compose.prod.yml stop backend worker"]' || \
    dr_log "WARN" "fencing failed (primary may be down); continuing"
}

dr_p_promote() {
  dr_mutate false "promote ${DR_REPLICA_ID} (IRREVERSIBLE: breaks replication)" -- \
    aws rds promote-read-replica --region "$DR_REGION" --db-instance-identifier "$DR_REPLICA_ID" --backup-retention-period 7
}

dr_p_wait_writable() {
  dr_mutate false "wait for ${DR_REPLICA_ID} available" -- aws rds wait db-instance-available --region "$DR_REGION" --db-instance-identifier "$DR_REPLICA_ID"
}

dr_p_endpoint() { _db "$DR_REGION" "$DR_REPLICA_ID" | _jq "d['Endpoint']['Address']"; }

# Renders .env from SSM SecureString parameters (no secret printed) and deploys with the Melbourne target.
dr_p_start_app() { # <endpoint>
  local endpoint="$1" root="$DR_REPO_ROOT"
  dr_mutate false "render .env from SSM ${DR_SSM_PREFIX} with DATABASE_URL host ${endpoint}" -- \
    python3 "${root}/infrastructure/deployment/dr/render_env.py" --region "$DR_REGION" --prefix "$DR_SSM_PREFIX" --db-host "$endpoint" --out "${root}/.env"
  dr_mutate false "deploy ${DR_IMAGE_TAG} to target melbourne" -- \
    env STOCKWATCH_TARGET=melbourne RDS_EXPECTED_HOST="$endpoint" bash "${root}/infrastructure/deployment/deploy.sh" "$DR_IMAGE_TAG"
}

dr_p_health_url() { echo "$DR_HEALTH_URL"; }

_dns_upsert() { # <value> <description>
  [[ -n "${DNS_ZONE_ID:-}" && -n "${DNS_NAME:-}" ]] || { dr_log "SKIP" "DNS: DNS_ZONE_ID/DNS_NAME not set"; return 0; }
  dr_mutate false "$2" -- aws route53 change-resource-record-sets --hosted-zone-id "$DNS_ZONE_ID" --change-batch \
    "{\"Comment\":\"stockwatch DR\",\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${DNS_NAME}\",\"Type\":\"A\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"$1\"}]}}]}"
}
dr_p_switch_dns() { _dns_upsert "${DNS_VALUE:-}" "point ${DNS_NAME:-<unset>} at secondary ${DNS_VALUE:-<unset>}"; }
dr_p_restore_dns() { _dns_upsert "${DNS_FAILBACK_VALUE:-}" "point ${DNS_NAME:-<unset>} back at primary ${DNS_FAILBACK_VALUE:-<unset>}"; }

# ---- failback ----
dr_p_create_reverse_standby() {
  local arn; arn="$(_db "$DR_REGION" "$DR_REPLICA_ID" | _jq "d['DBInstanceArn']")"
  dr_mutate true "create ${FAILBACK_REPLICA_ID} in ${PRIMARY_REGION} replicating from ${DR_REPLICA_ID} (BILLABLE)" -- \
    aws rds create-db-instance-read-replica --region "$PRIMARY_REGION" --db-instance-identifier "$FAILBACK_REPLICA_ID" \
    --source-db-instance-identifier "$arn" --source-region "$DR_REGION" --db-instance-class db.t4g.micro \
    --no-publicly-accessible --deletion-protection
  dr_mutate false "wait for ${FAILBACK_REPLICA_ID}" -- aws rds wait db-instance-available --region "$PRIMARY_REGION" --db-instance-identifier "$FAILBACK_REPLICA_ID"
}
dr_p_reverse_lag() {
  local saved="$DR_REGION" saved_id="$DR_REPLICA_ID" lag
  DR_REGION="$PRIMARY_REGION" DR_REPLICA_ID="$FAILBACK_REPLICA_ID"; lag="$(dr_p_replication_lag)"
  DR_REGION="$saved" DR_REPLICA_ID="$saved_id"; echo "$lag"
}
dr_p_fence_secondary() {
  local root="$DR_REPO_ROOT"
  dr_mutate false "stop Melbourne backend/worker (no writes during switchover)" -- \
    docker compose -p docker -f "${root}/infrastructure/docker/docker-compose.prod.yml" stop backend worker
}
dr_p_promote_reverse() {
  dr_mutate false "promote ${FAILBACK_REPLICA_ID} in ${PRIMARY_REGION}" -- aws rds promote-read-replica --region "$PRIMARY_REGION" --db-instance-identifier "$FAILBACK_REPLICA_ID" --backup-retention-period 7
  dr_mutate false "wait for ${FAILBACK_REPLICA_ID}" -- aws rds wait db-instance-available --region "$PRIMARY_REGION" --db-instance-identifier "$FAILBACK_REPLICA_ID"
}
dr_p_start_primary_app() {
  dr_log "MANUAL" "on the Sydney host: set targets/primary.env RDS_EXPECTED_HOST to the ${FAILBACK_REPLICA_ID} endpoint, update .env DATABASE_URL host, run deploy.sh <sha>"
}
