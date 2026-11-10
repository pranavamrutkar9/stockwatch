# StockWatch DR Assessment — Progress Log

Status legend: **VERIFIED** (executed, evidence collected) · **IMPLEMENTED-UNTESTED** · **PLANNED** · **BLOCKED**

## 2026-11-10 — Phase 0 baseline and Phase 1 diagnosis

### Baseline (read-only, ~19:30 UTC)

| Item | Finding |
|---|---|
| Host | `ip-172-31-1-61`, branch `fix/rds-deployment-hardening` @ `1264b3a`, in sync with origin |
| Disk / memory | `/` 24G, 6.0G free (75%); `/tmp` tmpfs 1.9G; RAM 3.7G (2.1G available) |
| Docker usage | Images 5.9G (4.0G reclaimable), build cache 7.4G (4.7G reclaimable) — **not pruned** |
| Compose project | `docker` (from `infrastructure/docker/docker-compose.prod.yml`, env file `.env`) |
| backend | image `stockwatch-backend:latest` = `1cc73a2` build, created 11:43, **unhealthy** |
| worker | image `stockwatch-worker:latest` = `1cc73a2` build (no healthcheck), created 11:44 |
| frontend | image `1cc73a2`, created 2026-11-06, **unhealthy** (proxies backend `/api/health`) |
| redis | `redis:7-alpine`, AOF on, `noeviction`, healthy; volume `stockwatch_redis_data` |
| postgres (local, legacy) | running, healthy; volume `stockwatch_postgres_data` — **preserve** |
| Exposed ports | 22, 80 only. PostgreSQL/Redis not published. |
| Deployment state | `.current_tag`=`1cc73a2…`, `.previous_tag`=`c0c8c92…` |

Resources to preserve: volumes `stockwatch_postgres_data`, `stockwatch_redis_data`, the anonymous volume `63f11b1a…`; GHCR SHA-tagged images `1cc73a2…` and `c0c8c92…`; `/home/ubuntu/ap-southeast-2-bundle.pem`; `/home/ubuntu/.stockwatch-redis-password`; `.env`.

### Root cause of backend HTTP 503 — VERIFIED

- Backend log: `PrismaClientKnownRequestError … Authentication failed … credentials for stockwatch_admin are not valid` (P1000). `/api/inventory` also returns 500 — not health-check specific.
- `.env` was modified at 17:12 UTC; its `DATABASE_URL` differs (hash compare) from the one baked into the running backend/worker (started 11:43).
- Isolated probe with `.env` credentials: `SELECT 1` OK over TLS (`ssl=true`, PostgreSQL 16.15). Same probe with the running containers' credentials: authentication failed.
- Conclusion: the RDS master password was changed after the containers were created; pooled connections survived until recycled, then every new connection failed. The worker processed job #6 at 11:52 because that was before the change.
- Redis password in `.env` is the **new, not-yet-rotated** password (matches `~/.stockwatch-redis-password`); running Redis/backend/worker share the old one. Recreating backend/worker from `.env` alone would therefore break Redis auth — remediation must be coordinated.

### Phase 1 code changes — IMPLEMENTED, unit- and isolated-runtime-tested, NOT deployed

- Backend `/api/health`: 3s timeouts on DB and Redis probes (previously a Redis outage could hang the endpoint forever because of `maxRetriesPerRequest: null`); probes run concurrently; sanitized server-side logging (Prisma code + cause, credentials/URLs redacted, throttled). Response shape unchanged per API contract.
- Worker: periodic runtime dependency probe (default 30s) maintains the readiness file, so Docker health reflects stale credentials / Redis loss and recovery; sanitized startup-failure log.
- Redis compose healthcheck: `redis-cli` exits 0 on `NOAUTH`/`WRONGPASS`, so the old check reported healthy with a wrong password (verified). Now requires an explicit `PONG` and passes the password via `REDISCLI_AUTH` instead of argv. Verified: correct pw → 0, wrong pw → 1, missing pw → 1, no-auth server → 0.
- `rollback.sh`: fixed `printf '%s\\n'` that wrote a literal `\n` into `.current_tag`/`.previous_tag`, which would make every later `deploy.sh` abort with "Current verified deployment tag is invalid".

Evidence (isolated network `sw-phase1-test`, throwaway Redis, compiled code from a clean `git archive` + local changes):

| Scenario | Result |
|---|---|
| Unit tests | 30/30 pass (backend 27, worker 3); typecheck pass; backend/worker build pass (re-run on clean export before commit) |
| Current credentials | `/api/health` 200, db+redis connected |
| Stale (deployed) credentials | 503 in 112 ms; log `Database health check failed: PrismaClientInitializationError: Authentication failed…` |
| Redis stopped | 503 in 3016 ms (bounded, no hang); worker → NOT_READY |
| Redis restarted | 200; worker → READY ("Dependency check recovered") |
| SIGTERM worker | BullMQ closed, DB disconnected, exit code 0 |
| Strict TLS with wrong CA | rejected: `certificate verify failed` |
| Secret scan of all test logs | 0 password / 0 connection-string occurrences |

### Known pre-existing issues (not changed)

- `pnpm lint` (`next lint`) fails; CI does not run lint.
- Backend `onModuleInit` runs `CREATE … IF NOT EXISTS` DDL at startup in addition to Prisma migrations (schema-drift risk).
- `deploy.sh` hard-codes the primary RDS hostname — must be parameterised before DR failover to a restored/replica instance.
- `deploy.sh` runs `docker compose up -d redis`, which silently recreates Redis whenever its env (password) changes.
- Worker `depends_on: backend: service_healthy` couples worker start to backend/DB health.
- Frontend container health = backend health (proxy), so it is an end-to-end check, not frontend liveness.
- CI deploy job checks out a detached SHA in `~/stockwatch` on this host, the same working copy used for assessment work.

### Pending approvals / blockers

1. **Production remediation** (restart/recreate + Redis password rotation) — awaiting approval.
2. **AWS access** — no instance role, no AWS CLI. Needed to confirm whether RDS uses Secrets Manager–managed master password rotation (would cause this outage to recur) and for all DR phases.
