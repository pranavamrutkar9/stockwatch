# 09 — Docker and Containerization

## Dockerfiles

Create exactly three Dockerfiles:

- `infrastructure/docker/frontend.Dockerfile`
- `infrastructure/docker/backend.Dockerfile`
- `infrastructure/docker/worker.Dockerfile`

Use repository root as build context. Each Dockerfile should use a multi-stage build (dependencies, build, runtime) where appropriate. Runtime images should contain only what is needed to run the service, use a non-root user, and avoid development dependencies where practical.

Because this is a pnpm workspace, Docker builds must copy the workspace manifests and shared package files required for dependency resolution. Do not assume an app can be built in isolation from the repository root.

## Docker Compose

File: `infrastructure/docker/docker-compose.yml`.

Services: `frontend`, `backend`, `worker`, `postgres`, `redis`.

Requirements:

- One private application network.
- Named persistent volume for PostgreSQL.
- Redis AOF persistence with a named volume if Redis persistence is enabled for the selected image/configuration.
- Environment configuration from a local `.env` file; `.env` must be ignored by Git.
- Health checks for PostgreSQL (`pg_isready`), Redis (`redis-cli ping`), and backend (`/api/health`).
- Use `depends_on` health conditions where supported, but also implement application-level connection retry. Compose startup order alone is not readiness.
- Restart policies such as `unless-stopped` for long-running services.
- Publish only ports needed for local access.

## Commands

Run from repository root:

```bash
docker compose -f infrastructure/docker/docker-compose.yml up --build
```

Local expected access:

- Frontend: `http://localhost:3000`
- Backend health: `http://localhost:4000/api/health` only if the backend port is published for local development.

Document a one-command shortcut in the README if useful.

## Production differences

- PostgreSQL and Redis must not publish host ports.
- Pull application images from GHCR using immutable commit-SHA tags.
- Persist database data in a named volume and define a backup/restore approach.
- Do not bake secrets into images or Docker build arguments.
- Avoid building images on the VM; CI builds and publishes them.
