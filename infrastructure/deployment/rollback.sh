#!/bin/bash
set -e

# ========================================================
# StockWatch Automated Rollback Script
# ========================================================

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${DEPLOY_DIR}/../.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/infrastructure/docker/docker-compose.prod.yml"
ENV_FILE="${PROJECT_ROOT}/.env"
RECORD_DIR="${PROJECT_ROOT}/infrastructure/deployment"

if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

echo "========================================================"
echo "Initiating StockWatch rollback procedure"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "========================================================"

if [ ! -f "${RECORD_DIR}/.previous_tag" ] || [ ! -s "${RECORD_DIR}/.previous_tag" ]; then
  echo "Error: Rollback unavailable. No previous deployment tag found (${RECORD_DIR}/.previous_tag is missing or empty)."
  echo "Rollback cannot be performed because this is the first deployment or no prior verified tag exists."
  echo "Current stack status before aborting:"
  docker compose -f "$COMPOSE_FILE" ps
  exit 1
fi

ROLLBACK_TAG=$(cat "${RECORD_DIR}/.previous_tag" | tr -d '[:space:]')

if [ -z "$ROLLBACK_TAG" ]; then
  echo "Error: Recorded previous tag is empty."
  exit 1
fi

echo "Rolling back to verified previous tag: ${ROLLBACK_TAG}"

export IMAGE_TAG="$ROLLBACK_TAG"
export GITHUB_REPOSITORY_OWNER="${GITHUB_REPOSITORY_OWNER:-pranavamrutkar9}"
export REGISTRY="${REGISTRY:-ghcr.io}"

# 1. Pull previous verified images
echo "Pulling rollback images..."
docker compose -f "$COMPOSE_FILE" pull backend worker frontend

# 2. Restart services with previous image tags
echo "Restarting application stack with tag ${ROLLBACK_TAG}..."
docker compose -f "$COMPOSE_FILE" up -d --remove-orphans backend worker frontend

# 3. Verify health of rolled-back stack
echo "Verifying restored application health..."
HEALTHY=false
for i in $(seq 1 30); do
  HEALTH_STATUS=$(docker exec stockwatch-backend wget -qO- http://127.0.0.1:4000/api/health 2>/dev/null || true)
  if echo "$HEALTH_STATUS" | grep -q '"status":"ok"'; then
    HEALTHY=true
    echo "Restored service health check passed: ${HEALTH_STATUS}"
    break
  fi
  sleep 2
done

if [ "$HEALTHY" = "true" ]; then
  echo "$ROLLBACK_TAG" > "${RECORD_DIR}/.current_tag"
  echo "========================================================"
  echo "Rollback successfully completed! Restored active tag: ${ROLLBACK_TAG}"
  echo "========================================================"
  exit 0
else
  echo "EMERGENCY: Stack failed health check even after rollback to ${ROLLBACK_TAG}."
  docker compose -f "$COMPOSE_FILE" logs --tail=50
  exit 1
fi
