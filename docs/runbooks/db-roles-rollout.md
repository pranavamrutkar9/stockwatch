# Runbook — Production Database Role Rollout (`stockwatch_app` / `stockwatch_migrator`)

**Status:** APPLIED to production on 2026-11-11 (Phase 2 02:34:37Z, Phase 3 02:44:58Z, Phase 4 02:46:34Z). Backend and worker run as `stockwatch_app`; the temporary transition grant has been removed. See "Production result and RDS master privileges" below — it corrects an earlier claim in this runbook.
**Target:** RDS `stockwatch-primary-db` (PostgreSQL 16.15), database `stockwatch`.
**Code:** branch `feat/db-roles-rollout` (adds `--transition-grant`, `--end-transition`, `--rollback`, `lock_timeout 5s`).

## Production result and RDS master privileges (correction, 2026-11-11)

**Correction.** Earlier versions of this runbook stated that, after the ownership transfer and the end of the transition, the RDS master user would have *no direct access to application tables* and would need `SET ROLE stockwatch_migrator` to read or write them. **That is false on Amazon RDS** and was based on an isolated PostgreSQL emulation that does not model RDS's AWS-managed roles.

Verified on production after Phase 4 (read-only catalog queries):

| Fact | Value |
|---|---|
| Explicit table grants to `stockwatch_admin` | **0** — the temporary transition grant was removed by `--end-transition` (no `stockwatch_admin` entry in any table ACL) |
| `stockwatch_admin` memberships | `rds_superuser` (granted by `rdsadmin`), which inherits `pg_read_all_data` and `pg_write_all_data`; plus `stockwatch_migrator` (`INHERIT FALSE, SET TRUE`) |
| `has_table_privilege('stockwatch_admin', …)` on application tables | SELECT, INSERT, UPDATE, DELETE and TRUNCATE all **true** (`rds_superuser` itself reports these on every table) |
| Can the master user remove this? | **No** — the memberships are granted and managed by AWS (`rdsadmin`); revoking them is neither possible nor supported |

Consequences:

- The RDS master account `stockwatch_admin` is an **elevated, AWS-managed account with direct data access by design**. It is not a restricted role and must be protected as a credential (long random password, not stored in application configuration, containers, source control or logs).
- `SET ROLE stockwatch_migrator` is the **emergency migration-access mechanism** — it lets the master act as the schema owner (DDL, ownership changes, `migrate` operations). It is **not** a prerequisite for the master's data access.
- The transition grant was a sound precaution derived from the emulation; on RDS it turned out to be **redundant**, because the master user kept data access through `rds_superuser` throughout. It caused no harm and has been removed.
- What the rollout does deliver on RDS: the application no longer uses the master credential (rotating it cannot take the application down — the cause of the 2026-11-10 outage); runtime and migration privileges are separated; the runtime role cannot change the schema, truncate tables or read migration history.

## Role model (production, after rollout)

| Account | Type | Data access | Schema (DDL) | Migration history | Used by |
|---|---|---|---|---|---|
| `stockwatch_app` | restricted runtime role | SELECT/INSERT/UPDATE/DELETE on application tables only | **denied** | **denied** | backend, worker (`DATABASE_URL`) |
| `stockwatch_migrator` | migration role, schema owner | full (owner) | yes | yes | `deploy.sh` migrations (`MIGRATION_DATABASE_URL`); emergency migration access via `SET ROLE` |
| `stockwatch_admin` | **elevated RDS master** (`rds_superuser`) | **direct, all tables** (AWS-managed `pg_read_all_data` / `pg_write_all_data` and `rds_superuser` privileges) | via `SET ROLE stockwatch_migrator` (or as database/role administrator) | yes (direct) | administrators only — **never** application containers |

## Evidence (2026-11-11, production read-only / rolled-back only)

| Check | Result |
|---|---|
| RDS dry run, deployed script (`--transfer-ownership`) | exit 0, 447 ms incl. container start; transaction rolled back |
| RDS dry run, final plan (`--transfer-ownership --transition-grant`, this branch) | exit 0; master user keeps SELECT/DML on every table inside the transaction (`managing_user_select = t`) |
| Production catalog before vs after all dry runs | identical (no roles, objects owned by `stockwatch_admin`, default ACLs, no default privileges) |
| Production data after all dry runs | identical to verified backup `20261110T215542Z` (5 / 7 / 6 rows, content hashes match) |
| Secret scan of dry-run output | 0 SCRAM verifiers, 0 connection strings |
| Lifecycle rehearsal on a read-only copy of production (`scripts/rehearse-db-roles-on-copy.sh`) | **33/33**: apply with a simulated live app connected as the master user → 0 errors (pooled 66 OK, new connections 22 OK); negative control without the transition grant → 42 × permission denied; end-transition guard refuses while master sessions exist; rollback restores ownership, master DML, PUBLIC CONNECT and disables new logins; data hashes unchanged |
| Isolated integration harness | 35/35 (backend 7/7 and worker 9/9 suites as `stockwatch_app`) |

Defects found by the rehearsal and fixed before this proposal: (1) without a transition grant, the running app (connected as the master user) would lose all table access the instant the ownership transfer commits; (2) the first rollback could not transfer ownership back (`must be owner` — PostgreSQL 16 requires inheriting the current owner's privileges); (3) no lock timeout — the change could have queued behind, and in turn blocked, application queries.

Live facts: login roles are `rdsadmin` (AWS superuser, unaffected) and `stockwatch_admin` only; the application holds 2 sessions as `stockwatch_admin` (backend + worker pools).

## Exact SQL executed by the apply (captured from the RDS dry run with query echo)

```
BEGIN
SET LOCAL lock_timeout = '5s'
CREATE ROLE stockwatch_migrator LOGIN NOCREATEDB NOCREATEROLE PASSWORD '<SCRAM verifier>'
CREATE ROLE stockwatch_app      LOGIN NOCREATEDB NOCREATEROLE PASSWORD '<SCRAM verifier>'
ALTER ROLE stockwatch_migrator PASSWORD '<same verifier>'          -- redundant, harmless
ALTER ROLE stockwatch_app PASSWORD '<same verifier>'               -- redundant, harmless
ALTER ROLE stockwatch_app CONNECTION LIMIT 30
ALTER ROLE stockwatch_app SET statement_timeout = '30s'
ALTER ROLE stockwatch_app SET idle_in_transaction_session_timeout = '60s'
ALTER ROLE stockwatch_migrator CONNECTION LIMIT 5
ALTER ROLE stockwatch_migrator SET lock_timeout = '30s'
GRANT stockwatch_migrator TO stockwatch_admin WITH INHERIT FALSE, SET TRUE
REVOKE ALL ON DATABASE stockwatch FROM PUBLIC
GRANT CONNECT ON DATABASE stockwatch TO stockwatch_app, stockwatch_migrator
GRANT CONNECT, TEMPORARY ON DATABASE stockwatch TO stockwatch_admin
REVOKE CREATE ON SCHEMA public FROM PUBLIC                         -- no-op on PG16
GRANT USAGE ON SCHEMA public TO stockwatch_app
GRANT USAGE, CREATE ON SCHEMA public TO stockwatch_migrator
ALTER TABLE public._prisma_migrations OWNER TO stockwatch_migrator
ALTER TABLE public.inventory_items   OWNER TO stockwatch_migrator
ALTER TABLE public.stock_alerts      OWNER TO stockwatch_migrator
ALTER TABLE public.stock_checks      OWNER TO stockwatch_migrator
ALTER TYPE  public."CheckStatus"     OWNER TO stockwatch_migrator
SET ROLE stockwatch_migrator
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO stockwatch_app
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO stockwatch_app
ALTER DEFAULT PRIVILEGES FOR ROLE stockwatch_migrator IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO stockwatch_app
ALTER DEFAULT PRIVILEGES FOR ROLE stockwatch_migrator IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO stockwatch_app
REVOKE ALL ON public._prisma_migrations FROM stockwatch_app
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO stockwatch_admin   -- transition grant
RESET ROLE
COMMIT
```

No statement reads, writes or deletes application rows (`INSERT/UPDATE/DELETE/TRUNCATE` on data: none).

## Permission matrix

Verified on production after the rollout (runtime and migration roles: positive and negative tests; master: catalog privileges).

| Capability | `stockwatch_app` | `stockwatch_migrator` | `stockwatch_admin` (RDS master) |
|---|---|---|---|
| Connect to `stockwatch` | yes | yes | yes |
| SELECT/INSERT/UPDATE/DELETE data tables | **yes** | yes (owner) | **yes, directly** (`rds_superuser` → `pg_read_all_data` / `pg_write_all_data`; no grant from us) |
| TRUNCATE | **no** | yes (owner) | yes (`rds_superuser`) |
| Read `_prisma_migrations` | **no** | yes (owner) | yes (`pg_read_all_data`) |
| CREATE/ALTER/DROP application tables, types | **no** | **yes** (owner, CREATE on schema) | via `SET ROLE stockwatch_migrator` (emergency migration access) |
| Run `prisma migrate deploy` | no | **yes** (verified in production) | not used for migrations |
| Create/alter roles, reset passwords | no | no | yes (CREATEROLE, `rds_superuser`) |
| Database owner / backups / PITR / snapshots (AWS-level) | — | — | unaffected |
| Session limits | 30 conns, statement 30 s, idle-in-tx 60 s | 5 conns, lock_timeout 30 s | unchanged |
| Temporary transition grant | — | — | **removed** (2026-11-11 02:46:34Z) |

## Supplying the master credential for administrative commands

Since the rollout, `.env` holds only `stockwatch_app` and `stockwatch_migrator`. `db-roles.sh` (and `pg-restore.sh`) need the RDS master credential; supply it at the moment of use from the password manager, never from a file:

```bash
read -r -s -p 'RDS master password: ' PGPW; echo
export ADMIN_DATABASE_URL="postgresql://stockwatch_admin:${PGPW}@stockwatch-primary-db.cns8kouwop3n.ap-southeast-2.rds.amazonaws.com:5432/stockwatch?sslmode=require"
unset PGPW
infrastructure/deployment/db-roles.sh --end-transition --ca-file /home/ubuntu/ap-southeast-2-bundle.pem \
  --confirm-host stockwatch-primary-db.cns8kouwop3n.ap-southeast-2.rds.amazonaws.com   # dry run
unset ADMIN_DATABASE_URL
```

The password is alphanumeric (no URL escaping), is not echoed, does not enter shell history, and reaches `psql` only as `PGPASSWORD` in the container environment. Logical backups do **not** need it — they run as `stockwatch_migrator` (manual runs; no schedule is configured) (see [`docs/assessment/05-database-backup-and-recovery.md`](../assessment/05-database-backup-and-recovery.md)).

## Apply sequence (as executed on 2026-11-11)

All commands run on the EC2 host from `~/stockwatch` on branch `feat/db-roles-rollout`; nothing is printed that contains a secret.

**Phase 0 — pre-checks (read-only)**
1. Health 200, images `498e28b`, queue idle (`wait=0 active=0`).
2. Fresh verified backup: `SOURCE_DATABASE_URL=… infrastructure/deployment/backup/pg-backup-verify.sh --ca-file /home/ubuntu/ap-southeast-2-bundle.pem` → must report `VERIFIED`.

**Phase 1 — credentials (no production effect)**
3. Generate two 64-hex passwords; write `APP_DB_PASSWORD` / `MIGRATOR_DB_PASSWORD` and the prepared URLs into a staged file `/home/ubuntu/stockwatch/.env.next` (mode 600; copy of `.env` with `DATABASE_URL` user → `stockwatch_app`, new `MIGRATION_DATABASE_URL` user → `stockwatch_migrator`, same host/TLS parameters). `.env` itself is not changed.

**Phase 2 — database change (zero downtime)**
4. Dry run: `ADMIN_DATABASE_URL=<master URL> APP_DB_PASSWORD=… MIGRATOR_DB_PASSWORD=… infrastructure/deployment/db-roles.sh --transfer-ownership --transition-grant --ca-file … --confirm-host stockwatch-primary-db.cns8kouwop3n.ap-southeast-2.rds.amazonaws.com`
5. Apply: same command plus `--apply` (one transaction, sub-second; aborts after 5 s if a lock cannot be obtained).
6. Verify: app keeps 200 throughout (availability probe); TLS login probes `SELECT 1` as `stockwatch_app` and `stockwatch_migrator`; `prisma migrate status` as migrator → up to date; app DML in a rolled-back transaction; app denied on `_prisma_migrations` and DDL.

**Phase 3 — switch the application (same procedure as the 2026-11-11 deploy, ≈ 6–16 s API interruption)**
7. `cp .env .env.pre-roles` (600) then `mv .env.next .env`.
8. From `~/stockwatch-deploy` (at `498e28b`): `STOCKWATCH_ENV_FILE=/home/ubuntu/stockwatch/.env STOCKWATCH_STATE_DIR=/home/ubuntu/stockwatch/infrastructure/deployment bash infrastructure/deployment/deploy.sh 498e28b227d50eb082848a0c87d412093300e90f` — validates both URLs (expects "Runtime user 'stockwatch_app' and migration user 'stockwatch_migrator' are separated"), runs `migrate deploy` as the migrator, recreates backend and worker (frontend and Redis unchanged).
9. Verify: `pg_stat_activity` shows application sessions as `stockwatch_app`; health 200; data hashes unchanged.

**Phase 4 — end of transition**
10. `db-roles.sh --end-transition` (dry run) then `--apply`. The guard refuses while any client session still uses `stockwatch_admin`.
11. Verify: no explicit table grants remain for `stockwatch_admin` (transition grant removed); emergency `SET ROLE stockwatch_migrator` works; app healthy. Note: the master user keeps direct data access through AWS-managed `rds_superuser` privileges — this cannot be removed and is expected on RDS.

## Rollback

| When | Procedure | Downtime |
|---|---|---|
| Before step 5 | nothing to undo | 0 |
| After step 5, before step 7 | app still runs as master (transition grant) → `db-roles.sh --rollback --apply` | 0 |
| After step 8 (app on new roles, problems) | `mv .env.pre-roles .env` → `deploy.sh 498e28b…` (app back on master, which still has the transition grant) → `db-roles.sh --rollback --apply` | ≈ 6–16 s (container recreate) |
| After step 10 (transition ended) | re-grant: `db-roles.sh --transfer-ownership --transition-grant --apply` (idempotent; no passwords needed) → restore `.env.pre-roles` → `deploy.sh` → `db-roles.sh --rollback --apply` | ≈ 6–16 s |
| Data problem (not expected: no data statements) | restore from the Phase 0 backup with `pg-restore.sh` into a new database / RDS PITR | per DR runbooks |

`--rollback` returns ownership of all tables and the enum to `stockwatch_admin`, removes all grants to the new roles (incl. default privileges), restores the PostgreSQL default PUBLIC database privileges (CONNECT, TEMPORARY — as an explicit ACL rather than NULL), and sets both new roles `NOLOGIN` (kept for audit; drop separately if desired). Verified on the production copy.

## Risks

| Risk | Mitigation |
|---|---|
| App loses table access when ownership moves | transition grant in the same transaction (verified on the copy with a live simulated app). On RDS the master kept access via `rds_superuser` anyway, so the grant proved redundant there; it was removed in Phase 4 |
| Locks during ownership transfer | sub-second transaction on 4 small tables; `lock_timeout 5s` aborts and rolls back rather than blocking traffic |
| `REVOKE ALL ON DATABASE … FROM PUBLIC` | only `rdsadmin` (superuser, unaffected) and `stockwatch_admin` (explicit grant) can log in today |
| Master account remains elevated | by design on RDS: direct data access via `rds_superuser`, plus CREATEROLE, DB ownership and AWS-level recovery; `SET ROLE stockwatch_migrator` for emergency schema/migration work. Control: rotate the master password to a long random value and keep it out of application configuration (separate hardening task) |
| Credential handling | SCRAM verifiers computed locally; plaintext only in `.env` (600), as today; `.env.pre-roles` kept until sign-off then removed |
| CI deploy path still broken (SSH restricted) | Phase 3 uses the same on-host `deploy.sh` procedure as the 2026-11-11 deployment |
| `CREATE` + `ALTER ROLE … PASSWORD` both set the verifier | redundant, harmless; cosmetic follow-up |
