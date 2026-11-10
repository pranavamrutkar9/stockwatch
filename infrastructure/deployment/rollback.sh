#!/usr/bin/env bash
set -Eeuo pipefail

# ========================================================
# StockWatch Automated Rollback Script
# ========================================================

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${DEPLOY_DIR}/../.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/infrastructure/docker/docker-compose.prod.yml"
ENV_FILE="${PROJECT_ROOT}/.env"
RECORD_DIR="${PROJECT_ROOT}/infrastructure/deployment"

# Share the deployment lock with deploy.sh.
LOCK_FILE="${RECORD_DIR}/.deployment.lock"

if [[ "${STOCKWATCH_DEPLOY_LOCK_HELD:-0}" == "1" ]]; then
  INHERITED_LOCK_PATH="$(readlink "/proc/$$/fd/9" 2>/dev/null || true)"

  [[ "$INHERITED_LOCK_PATH" == "$LOCK_FILE" ]] || {
    echo "ERROR: Expected deployment lock descriptor was not inherited."
    exit 1
  }

  if flock -n "$LOCK_FILE" -c true >/dev/null 2>&1; then
    echo "ERROR: Inherited deployment lock is not held."
    exit 1
  fi

  echo "Verified inherited deployment lock."
else
  exec 9>"$LOCK_FILE"
  flock -n 9 || {
    echo "ERROR: Another deployment or rollback is already running."
    exit 1
  }
  export STOCKWATCH_DEPLOY_LOCK_HELD=1
  echo "Acquired deployment lock for manual rollback."
fi

DC=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: Runtime .env file is missing."
  exit 1
fi
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

# Same target resolution and database validation as deploy.sh (region, endpoint, CA bundle).
# shellcheck source=infrastructure/deployment/lib/target.sh
source "${DEPLOY_DIR}/lib/target.sh"
stockwatch_load_target "$DEPLOY_DIR"
stockwatch_validate_target
export MIGRATION_DATABASE_URL="${MIGRATION_DATABASE_URL:-${DATABASE_URL:-}}"
stockwatch_validate_database_urls

echo "========================================================"
echo "Initiating StockWatch rollback procedure"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "Target: ${STOCKWATCH_TARGET} (${STOCKWATCH_REGION})"
echo "========================================================"

if [[ -n "${1:-}" ]]; then
  ROLLBACK_TAG="$1"
elif [[ -s "${RECORD_DIR}/.previous_tag" ]]; then
  ROLLBACK_TAG="$(tr -d '[:space:]' < "${RECORD_DIR}/.previous_tag")"
else
  echo "ERROR: No rollback tag was supplied and no previous tag exists."
  "${DC[@]}" ps
  exit 1
fi

if [[ ! "$ROLLBACK_TAG" =~ ^[a-fA-F0-9]{7,64}$ ]]; then
  echo "ERROR: Invalid rollback image tag."
  exit 1
fi

echo "Rolling back to verified previous tag: ${ROLLBACK_TAG}"

export IMAGE_TAG="$ROLLBACK_TAG"
export GITHUB_REPOSITORY_OWNER="${GITHUB_REPOSITORY_OWNER:-pranavamrutkar9}"
export REGISTRY="${REGISTRY:-ghcr.io}"

CURRENT_TAG=""
if [[ -s "${RECORD_DIR}/.current_tag" ]]; then
  CURRENT_TAG="$(tr -d '[:space:]' < "${RECORD_DIR}/.current_tag")"
fi

# 1. Pull previous verified images
echo "Pulling rollback images..."
"${DC[@]}" pull backend worker frontend

# 2. Restart services with previous image tags
echo "Restarting application stack with tag ${ROLLBACK_TAG}..."
"${DC[@]}" up -d --remove-orphans backend worker frontend

# 3. Verify backend health.
echo "Checking restored backend..."
BACKEND_READY=false

for _ in $(seq 1 30); do
  HEALTH_STATUS="$(docker exec stockwatch-backend wget -qO- \
    http://127.0.0.1:4000/api/health 2>/dev/null || true)"

  if echo "$HEALTH_STATUS" | grep -q '"status":"ok"'; then
    BACKEND_READY=true
    break
  fi
  sleep 2
done

if [[ "$BACKEND_READY" != "true" ]]; then
  echo "CRITICAL: Backend did not recover."
  "${DC[@]}" logs --tail=80 backend
  exit 1
fi

# 4. Verify worker readiness.
echo "Checking restored worker..."
WORKER_READY=false

for _ in $(seq 1 30); do
  WORKER_STATUS="$(docker inspect --format '{{.State.Status}}' \
    stockwatch-worker 2>/dev/null || true)"
  WORKER_HEALTH="$(docker inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    stockwatch-worker 2>/dev/null || true)"

  if [[ "$WORKER_STATUS" == "running" && "$WORKER_HEALTH" == "healthy" ]]; then
    WORKER_READY=true
    break
  fi

  # Legacy images have no Docker healthcheck. Verify their worker startup log.
  if [[ "$WORKER_STATUS" == "running" && "$WORKER_HEALTH" == "none" ]]; then
    WORKER_LOGS="$(docker logs --tail=100 stockwatch-worker 2>&1 || true)"
    if echo "$WORKER_LOGS" | grep -q 'active and consuming'; then
      WORKER_READY=true
      echo "Legacy worker startup log verified; no Docker healthcheck is available."
      break
    fi
  fi

  if [[ "$WORKER_STATUS" == "exited" || "$WORKER_STATUS" == "dead" ]]; then
    break
  fi

  sleep 2
done

if [[ "$WORKER_READY" != "true" ]]; then
  echo "CRITICAL: Worker did not recover."
  "${DC[@]}" logs --tail=80 worker
  exit 1
fi

# 5. Verify frontend health.
echo "Checking restored frontend..."
FRONTEND_READY=false

for _ in $(seq 1 30); do
  FRONTEND_HEALTH="$(docker inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    stockwatch-frontend 2>/dev/null || true)"

  if [[ "$FRONTEND_HEALTH" == "healthy" ]]; then
    FRONTEND_READY=true
    break
  fi
  sleep 2
done

if [[ "$FRONTEND_READY" != "true" ]]; then
  echo "CRITICAL: Frontend did not recover."
  "${DC[@]}" logs --tail=80 frontend
  exit 1
fi

# 6. Update verified release state only after all checks pass.
if [[ -n "$CURRENT_TAG" && "$CURRENT_TAG" != "$ROLLBACK_TAG" ]]; then
  printf '%s\n' "$CURRENT_TAG" > "${RECORD_DIR}/.previous_tag.tmp"
  mv "${RECORD_DIR}/.previous_tag.tmp" "${RECORD_DIR}/.previous_tag"
fi

printf '%s\n' "$ROLLBACK_TAG" > "${RECORD_DIR}/.current_tag.tmp"
mv "${RECORD_DIR}/.current_tag.tmp" "${RECORD_DIR}/.current_tag"

echo "========================================================"
echo "Rollback successfully completed: ${ROLLBACK_TAG}"
echo "Backend: healthy"
echo "Worker: verified"
echo "Frontend: healthy"
echo "========================================================"

"${DC[@]}" ps
