# Phase 4 — Docker Containerization

## Read first
`AGENTS.md`, context 03–05, 09, 12–14.

## Goal
Containerize frontend, backend, and worker and run all five services locally with Docker Compose.

## Tasks
1. Create the three Dockerfiles only under `infrastructure/docker/`.
2. Use repository root as build context.
3. Implement multi-stage builds and non-root runtime users.
4. Create Compose services for frontend, backend, worker, PostgreSQL, and Redis.
5. Add private network, health checks, restart policies, PostgreSQL named volume, and Redis persistence configuration.
6. Ensure internal service URLs use Compose DNS.
7. Keep production database/Redis ports unpublished.
8. Document local start/stop commands.

## Acceptance
- One documented command starts the full stack.
- All services become healthy.
- Frontend can reach backend; backend/worker can reach DB and Redis.
- PostgreSQL data survives container recreation.
- Images build without relying on untracked local files.
