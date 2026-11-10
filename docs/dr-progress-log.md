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

## 2026-11-10 (cont.) — Recovery preparation, IAM spec, DR design

- Commit `3691918` (code + compose healthcheck fix + this log). Re-tested on a clean export before commit: typecheck pass, 30/30 tests, builds pass; diff secret scan clean.
- **Recovery runbook PREPARED, NOT EXECUTED:** `docs/runbooks/production-credential-recovery.md`. Procedure rehearsed end-to-end on an isolated replica stack (`compose -p rh`): Redis `CONFIG SET` via stdin → new pw PONG / old pw WRONGPASS, existing connections kept; `--no-deps` recreate left Redis untouched, backend healthy in 17 s; Redis recreate healthy in 6 s with persistent keys preserved; 0 secret leaks. Command forms re-verified against throwaway Redis containers; runbook bash blocks pass `bash -n`. Production verified unchanged afterwards.
- Production queue at 19:45 UTC: wait=0 active=0, job id counter=6.
- **Finding:** deployed Redis healthcheck reports healthy on WRONGPASS (redis-cli exits 0) — VERIFIED; fixed in `3691918`, takes effect when Redis is recreated.
- **Finding:** deployed `1cc73a2` worker performs no DB check at startup — only job processing proves DB access.
- **Finding (DR blocker):** BullMQ auto-increment job IDs collide with `stock_checks.jobId UNIQUE` after Redis restore/empty start — design fix `jobId = stockCheck.id` (not implemented yet).
- **IAM:** `docs/aws/iam-readonly-discovery-policy.json`, `docs/aws/ec2-trust-policy.json`, `docs/aws/iam-access-requirements.md` — PREPARED. IMDS confirms no instance role (404).
- **DR design:** `docs/disaster-recovery-design.md` — DESIGN only; AWS facts marked *(verify)*; costs are unverified estimates.
- Housekeeping pending approval: two anonymous Docker volumes created by my isolated test Redis containers at 19:35:17 and 19:35:58 UTC (`7e6c2778b28a…`, `c5ff5e059b71…`, label `com.docker.volume.anonymous`). Pre-existing anonymous volume `63f11b1a…` (15:58 UTC) is NOT mine and must be preserved.

## 2026-11-10 19:54–19:57 UTC — Production recovery EXECUTED (approved Steps 0–4, 6, read-only 5)

Pushed `3691918`, `b49d0e2` to `origin/fix/rds-deployment-hardening` (fast-forward from `1264b3a`); `origin/main` unchanged at `1cc73a2`.

| Time (UTC) | Step | Result |
|---|---|---|
| 19:54:34 | 0 pre-flight | git clean; `.current_tag`=1cc73a2; compose valid; queue wait=0 active=0, id=6, dbsize=11; BGSAVE completed |
| 19:54:52 | 0 backup verification | `redis-data-pre.tgz`: 4/4 files sha256-identical to live volume; restore into network-less throwaway Redis → dbsize 11, id 6, completed 6, key set identical to live |
| 19:55:06 | 1 `CONFIG SET requirepass` | `OK` |
| 19:55:06 | 2 auth | new pw `PONG`; old pw `NOAUTH WRONGPASS`; 4 clients kept; backend still `redis: connected` |
| 19:55:19 → 19:55:35 | 3 recreate backend+worker (`--no-deps`, tag 1cc73a2) | Redis untouched (same StartedAt); backend **healthy in 16 s**; same image IDs (404bc5…, 3ac750…) |
| 19:55:40 | 4 frontend | **healthy at first observation without recreation**; port 80 `/api/health` 200 |
| 19:55:51 | 6a | queue idle; 10 persistent keys; `BGREWRITEAOF` ok; `redis-data-pre6.tgz` restore-tested (key set identical, id 6) |
| 19:56:10 → 19:56:15 | 6b recreate Redis | **healthy in 5 s**; loaded from AOF (base RDB 11 keys + incr) |
| 19:56:15 | 6c | persistent keys identical (10); job id 6 → 6; container-env password now PONG; fixed healthcheck active; worker reconnected after one 500 ms retry |
| 19:56:34 | 5 read-only validation | health `ok` (database+redis connected); inventory 200, 5 items (4 HEALTHY, 1 LOW_STOCK); stock-checks 6 (all COMPLETED); alerts 7; frontend `/` 200; queue wait/active/delayed/failed = 0, completed 6 |
| 19:56:49 | 5 worker | read-only `SELECT 1` with worker's own credentials: OK (`stockwatch_admin`, ssl=true); worker env DB/Redis hashes match `.env`; log secret scan 0/0/0 for all four containers; volume list unchanged |
| 19:57:05 | housekeeping | removed only own test volumes `7e6c2778b28a…`, `c5ff5e059b71…` after checks (anonymous label, 19:35 creation, unused, 8 KB `dump.rdb`); `63f11b1a…`, `stockwatch_postgres_data`, `stockwatch_redis_data` preserved |

Downtime: API unavailable ~16 s during Step 3 (it was already failing all DB requests since ~17:12); Redis unavailable ~5 s in Step 6 (health 503 window; no submissions occurred). No unexpected behaviour. Evidence directory on host: `~/stockwatch-recovery/20261110T195434Z/` (mode 700, not in repo; contains Redis data tarballs).

Not yet proven: a stock-check job processed end-to-end on the recovered stack (Step 5b not approved). Running images are still `1cc73a2` (without `1264b3a`/`3691918`).

## 2026-11-10 — Melbourne verification and IAM review

- Melbourne (ap-southeast-4) selected. Verified from public AWS sources: db.t4g.micro PostgreSQL offered (same price as Sydney), Sydney→Melbourne automated backup replication supported, cross-region PG replicas supported, regional CA bundle exists. Images are amd64-only → x86 DR host. Blockers needing API: Region opt-in status, PG 16.15 availability, source encryption/KMS. See design §4a/§9.
- `docs/aws/iam-policy-review.md`: per-action review of 78 Allow + 13 Deny actions (13 Optional actions identified for further tightening).

## 2026-11-10 20:00–20:35 UTC — Queue recovery, least-privilege DB roles, IAM v1.0, Melbourne spec

All work below is **implemented and tested on isolated infrastructure only**. Nothing was deployed; production containers, credentials and data were not touched (verified: production containers unchanged and healthy at 20:32 UTC).

- Pushed `d387678` (fast-forward); `origin/main` unchanged at `1cc73a2`.
- **Stock-check ID as BullMQ job ID + PostgreSQL-backed recovery** (`StockCheckRecoveryService`, backend/producer side, no new API routes). Processor made at-least-once-safe: no-op on redelivery of COMPLETED checks; alerts + COMPLETED committed atomically with `ON CONFLICT DO NOTHING`; non-final failures stay PROCESSING (previously a transient FAILED stopped client polling).
- **Least-privilege roles:** `stockwatch_app` (DML only) / `stockwatch_migrator` (owner, migrations) via `db-roles.sh` (dry run default, SCRAM verifiers computed locally, RDS guard); `deploy.sh` uses `MIGRATION_DATABASE_URL`; runtime DDL gated behind `DB_BOOTSTRAP_SCHEMA` (dev compose only).
- **Evidence:** unit 45/45 (backend 35, worker 10; 13 integration tests skipped without infrastructure); `scripts/test-integration.sh` 35/35 checks incl. backend 7/7 and worker 6/6 integration tests **as `stockwatch_app`** against real PostgreSQL 16 + Redis 7; SIGKILL mid-job → stalled job recovered by another worker in 2.0–3.0 s, completed once.
- **Mutation checks:** old enqueue path → 6/7 backend integration tests fail (e.g. 3 concurrent recoveries created 60 jobs instead of 10; job ID "1" instead of record ID). Old processor → "redelivery after completion" and "retry leaves PROCESSING" fail. The concurrent-duplicate-delivery test also passed on the old processor (race not reproduced), so it does not by itself prove the race fix.
- **Defects found by the harness and fixed:** `ALTER ROLE … NOSUPERUSER …` rejected for non-superuser admins (would have failed on RDS); harness false-pass due to missing `pipefail`; jest hang on open handles after failures (`--forceExit` + timeout).
- **IAM v1.0:** 65 Allow (13 optional removed) + 13 Deny; trust-policy review, approval checklist and verify/detach procedure in `docs/aws/iam-policy-review.md`. Not created or attached.
- **Melbourne:** verified from public price lists — Sydney→Melbourne transfer $0.080/GB, public IPv4 $0.005/h; 31 Route 53 health-checker prefixes. Specification and runbooks: `docs/dr-melbourne-environment.md`.
