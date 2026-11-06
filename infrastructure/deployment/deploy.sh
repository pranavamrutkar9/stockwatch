#!/bin/bash
set -e

# ========================================================
# StockWatch Automated Deployment Script
# ========================================================

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${DEPLOY_DIR}/../.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/infrastructure/docker/docker-compose.prod.yml"
ENV_FILE="${PROJECT_ROOT}/.env"
RECORD_DIR="${PROJECT_ROOT}/infrastructure/deployment"

IMAGE_TAG="${1:-${IMAGE_TAG}}"

if [ -z "$IMAGE_TAG" ]; then
  echo "Error: IMAGE_TAG must be provided as argument 1 or set in environment."
  exit 1
fi

echo "========================================================"
echo "Starting deployment for StockWatch commit SHA: ${IMAGE_TAG}"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "========================================================"

# 1. Verify environment configuration
if [ ! -f "$ENV_FILE" ]; then
  echo "Warning: .env file not found at ${ENV_FILE}. Using existing environment variables."
else
  echo "Loading runtime environment configuration from ${ENV_FILE}..."
  set -a
  source "$ENV_FILE"
  set +a
fi

# 2. Record previous image tag for safe rollback
if [ -f "${RECORD_DIR}/.current_tag" ] && [ -s "${RECORD_DIR}/.current_tag" ]; then
  PREV_TAG=$(cat "${RECORD_DIR}/.current_tag" | tr -d '[:space:]')
  if [ -n "$PREV_TAG" ]; then
    echo "$PREV_TAG" > "${RECORD_DIR}/.previous_tag"
    echo "Recorded previous active deployment tag: ${PREV_TAG}"
  else
    echo "Notice: .current_tag is empty. No previous tag recorded."
    rm -f "${RECORD_DIR}/.previous_tag"
  fi
else
  echo "Notice: No previous deployment tag found (.current_tag does not exist). This is a first deployment."
  rm -f "${RECORD_DIR}/.previous_tag"
fi

export IMAGE_TAG
export GITHUB_REPOSITORY_OWNER="${GITHUB_REPOSITORY_OWNER:-pranavamrutkar9}"
export REGISTRY="${REGISTRY:-ghcr.io}"

# 3. Pull new versioned images from registry
echo "Pulling images from ${REGISTRY}/${GITHUB_REPOSITORY_OWNER} with tag ${IMAGE_TAG}..."
docker compose -f "$COMPOSE_FILE" pull frontend backend worker

# 4. Start database and redis first if not running
echo "Ensuring database and redis dependencies are healthy..."
docker compose -f "$COMPOSE_FILE" up -d postgres redis

# Wait up to 30 seconds for postgres to report healthy
echo "Waiting for postgres to become healthy..."
POSTGRES_READY=false
for i in $(seq 1 30); do
  if docker compose -f "$COMPOSE_FILE" ps postgres | grep -q "(healthy)"; then
    POSTGRES_READY=true
    echo "Postgres is healthy."
    break
  fi
  sleep 1
done

if [ "$POSTGRES_READY" != "true" ]; then
  echo "Error: Postgres failed to become healthy in time."
  exit 1
fi

# 5. Apply Prisma database migrations in a controlled step
echo "Applying Prisma database migrations..."
DATABASE_URL="${DATABASE_URL:-postgresql://${POSTGRES_USER:-stockwatch}:${POSTGRES_PASSWORD:-stockwatch_secure_password}@postgres:5432/${POSTGRES_DB:-stockwatch}?schema=public}"

PRISMA_CLI_PATH="/app/packages/database/node_modules/prisma/build/index.js"
PRISMA_SCHEMA_PATH="/app/packages/database/prisma/schema.prisma"

echo "Executing Prisma migration deploy via backend container..."
set +e
docker run --rm \
  --network stockwatch-network \
  -e DATABASE_URL="$DATABASE_URL" \
  "${REGISTRY}/${GITHUB_REPOSITORY_OWNER}/stockwatch-backend:${IMAGE_TAG}" \
  node "$PRISMA_CLI_PATH" migrate deploy --schema="$PRISMA_SCHEMA_PATH"
MIGRATION_STATUS=$?
set -e

if [ $MIGRATION_STATUS -ne 0 ]; then
  echo "CRITICAL: Database migration failed with exit code ${MIGRATION_STATUS}!"
  echo "Halting deployment immediately. Application services will not be deployed."
  exit $MIGRATION_STATUS
fi

echo "Database migrations successfully applied."

# 6. Deploy / update backend, worker, and frontend containers
echo "Updating application containers..."
docker compose -f "$COMPOSE_FILE" up -d --remove-orphans backend worker frontend

# 7. Deployment Health Verification
echo "Verifying deployment health..."
HEALTHY=false
for i in $(seq 1 30); do
  # Check backend internal health
  HEALTH_STATUS=$(docker exec stockwatch-backend wget -qO- http://127.0.0.1:4000/api/health 2>/dev/null || true)
  if echo "$HEALTH_STATUS" | grep -q '"status":"ok"'; then
    HEALTHY=true
    echo "Backend health check passed: ${HEALTH_STATUS}"
    break
  fi
  echo "Waiting for backend health check (attempt $i/30)..."
  sleep 2
done

if [ "$HEALTHY" != "true" ]; then
  echo "CRITICAL: Deployment health verification failed after 60 seconds!"
  if [ -f "${RECORD_DIR}/.previous_tag" ] && [ -s "${RECORD_DIR}/.previous_tag" ]; then
    echo "Initiating automated rollback to previous verified release..."
    "${DEPLOY_DIR}/rollback.sh"
    exit 1
  else
    echo "First deployment detected: no previous deployment tag available to roll back to."
    echo "Halting deployment. Stack status and recent logs:"
    docker compose -f "$COMPOSE_FILE" ps
    docker compose -f "$COMPOSE_FILE" logs --tail=50
    exit 1
  fi
fi

# 8. Record new active tag
echo "$IMAGE_TAG" > "${RECORD_DIR}/.current_tag"

echo "========================================================"
echo "Deployment of ${IMAGE_TAG} successfully completed!"
echo "========================================================"
