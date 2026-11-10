#!/bin/bash
set -Eeuo pipefail

# ========================================================
# StockWatch RDS-aware deployment
# ========================================================

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${DEPLOY_DIR}/../.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/infrastructure/docker/docker-compose.prod.yml"
ENV_FILE="${PROJECT_ROOT}/.env"
RECORD_DIR="${PROJECT_ROOT}/infrastructure/deployment"

# Serialize deployment and rollback operations.
LOCK_FILE="${RECORD_DIR}/.deployment.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "ERROR: Another deployment or rollback is already running."
  exit 1
fi
export STOCKWATCH_DEPLOY_LOCK_HELD=1

DEPLOYMENT_STARTED=false
DEPLOYMENT_COMMITTED=false
PREVIOUS_VERIFIED_TAG=""

if [[ -s "${RECORD_DIR}/.current_tag" ]]; then
  PREVIOUS_VERIFIED_TAG="$(tr -d '[:space:]' < "${RECORD_DIR}/.current_tag")"
  if [[ ! "$PREVIOUS_VERIFIED_TAG" =~ ^[a-fA-F0-9]{7,64}$ ]]; then
    echo "ERROR: Current verified deployment tag is invalid."
    exit 1
  fi
fi

on_deploy_exit() {
  local exit_code=$?
  trap - EXIT

  if [[ "$exit_code" -ne 0 &&
        "$DEPLOYMENT_STARTED" == "true" &&
        "$DEPLOYMENT_COMMITTED" != "true" ]]; then
    echo "CRITICAL: Deployment failed. Attempting automatic rollback."

    if [[ -n "$PREVIOUS_VERIFIED_TAG" ]]; then
      if bash "${DEPLOY_DIR}/rollback.sh" "$PREVIOUS_VERIFIED_TAG"; then
        echo "Automatic rollback completed."
      else
        echo "CRITICAL: Automatic rollback failed. Manual intervention required."
      fi
    else
      echo "No previously verified release exists. Automatic rollback unavailable."
    fi
  fi

  exit "$exit_code"
}
trap on_deploy_exit EXIT

# Deployment target (region, expected RDS endpoint, regional CA bundle).
# STOCKWATCH_TARGET=primary (default) | melbourne; see infrastructure/deployment/targets/.
# shellcheck source=infrastructure/deployment/lib/target.sh
source "${DEPLOY_DIR}/lib/target.sh"
stockwatch_load_target "$DEPLOY_DIR"

IMAGE_TAG="${1:-${IMAGE_TAG:-}}"

if [[ -z "$IMAGE_TAG" ]]; then
  echo "ERROR: IMAGE_TAG must be supplied."
  exit 1
fi

if [[ ! "$IMAGE_TAG" =~ ^[a-fA-F0-9]{7,64}$ ]]; then
  echo "ERROR: IMAGE_TAG must be a valid Git commit SHA."
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: Runtime .env file is missing."
  exit 1
fi

stockwatch_validate_target

# Load runtime environment without printing secrets.
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "ERROR: DATABASE_URL is missing."
  exit 1
fi

# Runtime traffic uses DATABASE_URL (least-privilege stockwatch_app once provisioned).
# Schema migrations use MIGRATION_DATABASE_URL (stockwatch_migrator) when set; otherwise
# they fall back to DATABASE_URL for backward compatibility.
export MIGRATION_DATABASE_URL="${MIGRATION_DATABASE_URL:-$DATABASE_URL}"

# Validate that both URLs target the expected endpoint for this target with strict TLS.
stockwatch_validate_database_urls

export IMAGE_TAG
export GITHUB_REPOSITORY_OWNER="${GITHUB_REPOSITORY_OWNER:-pranavamrutkar9}"
export REGISTRY="${REGISTRY:-ghcr.io}"

DC=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

echo "========================================================"
echo "StockWatch deployment"
echo "Image tag: ${IMAGE_TAG}"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "Target: ${STOCKWATCH_TARGET} (${STOCKWATCH_REGION})"
echo "========================================================"

# Validate Compose before changing containers.
"${DC[@]}" config --quiet

# Preserve the previous deployment tag.
if [[ -s "${RECORD_DIR}/.current_tag" ]]; then
  PREV_TAG="$(tr -d '[:space:]' < "${RECORD_DIR}/.current_tag")"
  if [[ -n "$PREV_TAG" && "$PREV_TAG" != "$IMAGE_TAG" ]]; then
    printf '%s\n' "$PREV_TAG" > "${RECORD_DIR}/.previous_tag"
  fi
fi

# Pull application images.
echo "Pulling application images..."
"${DC[@]}" pull backend worker frontend

# Start Redis only. Never start local PostgreSQL.
echo "Ensuring Redis is running..."
"${DC[@]}" up -d redis

REDIS_READY=false
for i in $(seq 1 30); do
  REDIS_STATUS="$(docker inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    stockwatch-redis 2>/dev/null || true)"

  if [[ "$REDIS_STATUS" == "healthy" ]]; then
    REDIS_READY=true
    break
  fi
  sleep 2
done

if [[ "$REDIS_READY" != "true" ]]; then
  echo "ERROR: Redis did not become healthy."
  exit 1
fi

# Apply Prisma migrations to RDS using the same CA as the app.
echo "Applying Prisma migrations to RDS (${STOCKWATCH_REGION})..."

docker run --rm \
  --network stockwatch-network \
  --mount "type=bind,source=${RDS_CA_BUNDLE_HOST_PATH},target=${RDS_CA_CONTAINER_PATH},readonly" \
  -e DATABASE_URL="$MIGRATION_DATABASE_URL" \
  "${REGISTRY}/${GITHUB_REPOSITORY_OWNER}/stockwatch-backend:${IMAGE_TAG}" \
  node /app/packages/database/node_modules/prisma/build/index.js \
  migrate deploy \
  --schema=/app/packages/database/prisma/schema.prisma

echo "Prisma migrations completed."

# Deploy application services.
echo "Starting backend, worker and frontend..."
DEPLOYMENT_STARTED=true
"${DC[@]}" up -d --remove-orphans backend worker frontend

# Verify backend health.
echo "Checking backend health..."
BACKEND_READY=false

for i in $(seq 1 30); do
  HEALTH_STATUS="$(docker exec stockwatch-backend \
    wget -qO- http://127.0.0.1:4000/api/health 2>/dev/null || true)"

  if echo "$HEALTH_STATUS" | grep -q '"status":"ok"'; then
    BACKEND_READY=true
    echo "Backend health check passed."
    break
  fi

  echo "Waiting for backend (attempt ${i}/30)..."
  sleep 2
done

if [[ "$BACKEND_READY" != "true" ]]; then
  echo "CRITICAL: Backend health verification failed."
  "${DC[@]}" logs --tail=80 backend
  exit 1
fi

# Verify worker startup readiness through Docker health status.
echo "Checking worker readiness..."
WORKER_READY=false

for i in $(seq 1 30); do
  WORKER_STATUS="$(docker inspect \
    --format '{{.State.Status}}' stockwatch-worker 2>/dev/null || true)"
  WORKER_HEALTH="$(docker inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    stockwatch-worker 2>/dev/null || true)"

  if [[ "$WORKER_STATUS" == "running" && "$WORKER_HEALTH" == "healthy" ]]; then
    WORKER_READY=true
    echo "Worker readiness check passed."
    break
  fi

  if [[ "$WORKER_STATUS" == "exited" || "$WORKER_STATUS" == "dead" ]]; then
    echo "Worker process exited unexpectedly."
    break
  fi

  echo "Waiting for worker readiness (attempt ${i}/30, status: ${WORKER_STATUS:-unknown}, health: ${WORKER_HEALTH:-unknown})..."
  sleep 2
done

if [[ "$WORKER_READY" != "true" ]]; then
  echo "CRITICAL: Worker did not become healthy."
  "${DC[@]}" logs --tail=80 worker
  exit 1
fi

# Verify frontend health.
echo "Checking frontend health..."
FRONTEND_READY=false

for i in $(seq 1 30); do
  FRONTEND_STATUS="$(docker inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    stockwatch-frontend 2>/dev/null || true)"

  if [[ "$FRONTEND_STATUS" == "healthy" ]]; then
    FRONTEND_READY=true
    break
  fi

  sleep 2
done

if [[ "$FRONTEND_READY" != "true" ]]; then
  echo "CRITICAL: Frontend health verification failed."
  "${DC[@]}" logs --tail=80 frontend
  exit 1
fi

# Record successful deployment.
printf '%s\n' "$IMAGE_TAG" > "${RECORD_DIR}/.current_tag"
DEPLOYMENT_COMMITTED=true

echo "========================================================"
echo "Deployment successful: ${IMAGE_TAG}"
echo "Backend: healthy"
echo "Worker: running"
echo "Frontend: healthy"
echo "Database: RDS"
echo "========================================================"

"${DC[@]}" ps
