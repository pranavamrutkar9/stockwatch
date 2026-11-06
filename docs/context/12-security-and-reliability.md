# 12 — Security and Reliability

| Concern | Required approach |
|---|---|
| Container crashes | Restart policies; inspect exit code and logs |
| Health | Docker health checks and backend `/api/health` |
| Secrets | GitHub Secrets for CI; protected server-side `.env` for runtime |
| Database persistence | Named PostgreSQL volume; document backup/restore |
| Redis persistence | Configure AOF/volume if relying on Redis persistence |
| Rollback | Redeploy previously known-good immutable image SHA tags |
| Troubleshooting | `docker compose ps`, `logs`, `inspect`, `stats`, health endpoint |
| Build safety | CI checks must pass before images publish/deploy |
| Network | Database and Redis internal only in production |

## Rollback

Record the currently deployed image SHA tags before updating. Deploy the new SHA, run health checks, and if they fail restore the previous known-good tags and restart the stack. Do not rely on a mutable `latest` tag for rollback.

Database migrations must be backward-compatible with the currently deployed version where possible. A container rollback does not automatically reverse a database schema migration.

## Troubleshooting commands

```bash
docker compose -f infrastructure/docker/docker-compose.yml ps
docker compose -f infrastructure/docker/docker-compose.yml logs --tail=100 backend
docker compose -f infrastructure/docker/docker-compose.yml logs --tail=100 worker
docker inspect <container>
docker stats
```

Use the actual Compose project and container names. Never paste secrets into logs or screenshots.

## Health endpoint

`/api/health` should verify that required dependencies are reachable. Return a non-success response when a critical dependency is unavailable. Keep liveness/readiness semantics simple and document what the endpoint checks.
