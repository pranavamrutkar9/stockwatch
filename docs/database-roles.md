# Database Roles — Runtime vs Migration Privileges

**Status:** APPLIED to production on 2026-11-11 (`docs/runbooks/db-roles-rollout.md`). Backend and worker connect as `stockwatch_app`; migrations run as `stockwatch_migrator`; the temporary transition grant has been removed.

## Why

On 2026-11-10 the application (connected as the RDS master user `stockwatch_admin`) went down when the master password changed under the running containers. The master user also gives the application full DDL rights. Separating identities fixes both for the application — the RDS master account itself remains elevated (see below):

| Role | Login | Privileges | Used by |
|---|---|---|---|
| `stockwatch_admin` (RDS master) | yes | **elevated, AWS-managed**: member of `rds_superuser` (→ `pg_read_all_data`, `pg_write_all_data`), owns the database, `CREATEROLE`; **direct read/write/TRUNCATE on all tables**; schema changes via `SET ROLE stockwatch_migrator` | administrators only (role management, emergency access) — never application containers |
| `stockwatch_migrator` | yes | owns all schema objects; `USAGE, CREATE` on `public`; `lock_timeout 30s`; ≤ 5 connections | `deploy.sh` → `prisma migrate deploy` (`MIGRATION_DATABASE_URL`) |
| `stockwatch_app` | yes | `SELECT, INSERT, UPDATE, DELETE` on tables, `USAGE, SELECT` on sequences (incl. future objects via default privileges); **no** DDL, `TRUNCATE`, `REFERENCES`, `TRIGGER`, migration ledger; `statement_timeout 30s`, `idle_in_transaction_session_timeout 60s`; ≤ 30 connections | backend and worker (`DATABASE_URL`) |
| `PUBLIC` | — | `CONNECT`/`TEMP` on the database revoked; no `CREATE` on `public` | — |

Rotating the master password no longer affects the application. It does **not** make the master account restricted: on RDS its data access comes from AWS-managed roles that cannot be revoked, so it must be protected as a high-privilege credential. Physical replicas, snapshots and PITR restores carry the roles and their SCRAM verifiers, so DR instances accept the same application credentials.

## Components

| File | Purpose |
|---|---|
| `packages/database/sql/roles.sql` | idempotent role/privilege definition (psql `\gexec`; no plaintext secrets) |
| `infrastructure/deployment/db-roles.sh` | applies the SQL as the admin; **dry run by default** (transaction rolled back); SCRAM-SHA-256 verifiers computed locally so plaintext never reaches the server, logs or argv; refuses RDS targets without `--confirm-host` and `--ca-file` (verify-full TLS) |
| `infrastructure/deployment/deploy.sh` | migrations use `MIGRATION_DATABASE_URL` (falls back to `DATABASE_URL`); validates both URLs; warns when runtime and migration users are the same |
| `apps/backend/src/prisma/prisma.service.ts` | runtime DDL now only with `DB_BOOTSTRAP_SCHEMA=true` (local docker-compose); production relies on migrations |
| `scripts/test-integration.sh` | isolated verification (below) |

Guards in `roles.sql`: refuses to continue if either role has `SUPERUSER/REPLICATION/BYPASSRLS/CREATEROLE/CREATEDB`; refuses to grant on a schema not owned by `stockwatch_migrator` (would otherwise silently grant nothing) unless `--transfer-ownership` is given; refuses to create a role without a password.

## Test evidence (isolated, 2026-11-10)

`scripts/test-integration.sh` — throwaway `postgres:16-alpine` + `redis:7-alpine` on an `--internal` Docker network; admin emulates RDS (non-superuser, `CREATEROLE`, owns the database). Result: **35 passed, 0 failed**, including:

- dry run leaves no roles; apply; idempotent re-apply; passwords stored as SCRAM verifiers; no verifier/password in output;
- migrations as `stockwatch_migrator`;
- `stockwatch_app`: DML and `ON CONFLICT DO NOTHING` allowed; `CREATE TABLE`, `DROP TABLE`, `ALTER TABLE`, `TRUNCATE`, `CREATE TYPE`, `CREATE ROLE`, reading `_prisma_migrations` denied; role timeout applied; unprivileged role cannot connect;
- production path: schema created by the admin (as in production) is rejected without `--transfer-ownership`; dry run leaves owners unchanged; apply transfers all tables and the enum to `stockwatch_migrator`; existing data stays readable/writable by the app; migrator can run `migrate deploy` afterwards;
- password rotation: new password works, old rejected;
- backend and worker integration suites run **as `stockwatch_app`**.

The first harness run caught a real defect that would also have failed on RDS: `ALTER ROLE … NOSUPERUSER NOREPLICATION NOBYPASSRLS` is rejected for a non-superuser admin. Fixed by verifying (not setting) those attributes.

Not verified: the plan executed on the actual RDS engine. Catalog facts above match the emulation; a production `db-roles.sh` dry run (rolled back) is the remaining proof and requires approval.

## Production plan validation (2026-11-10, read-only against production)

`scripts/rehearse-db-roles-on-copy.sh` (source session forced `default_transaction_read_only=on`; dump in a private temp dir, deleted on exit) — **19 passed, 0 failed**.

Live RDS catalog facts (read-only `SELECT`s):

| Fact | Value | Plan implication |
|---|---|---|
| Engine | PostgreSQL 16.15 | PG16 `GRANT … WITH INHERIT FALSE, SET TRUE` supported |
| `stockwatch_admin` | `super=f createrole=t createdb=t`, member of `rds_superuser` | matches the emulated admin in the harness |
| `password_encryption` | `scram-sha-256` | SCRAM verifiers accepted |
| Existing `stockwatch_*` roles | none | roles will be created |
| Object / enum owners | `stockwatch_admin` | `--transfer-ownership` required (guard verified) |
| Database ACL | default (PUBLIC has CONNECT/TEMP) | `REVOKE ALL … FROM PUBLIC` changes this |
| `max_connections` | 79 | app limit 30 + migrator 5 fits |
| Applied migrations | `20261106000000_init` | migrator: `migrate status` up to date, `migrate deploy` permitted |
| Data | inventory 5, stock_checks 6, stock_alerts 7 | identical row counts + content hashes before/after the role change on the copy |

**Correction (2026-11-11, verified on production RDS):** an earlier version of this section said the master user would have no implicit table access after the ownership transfer and would need `SET ROLE stockwatch_migrator` to read or write data. That was observed only on the isolated emulation (a plain PostgreSQL `CREATEROLE` user) and is **false on RDS**: `stockwatch_admin` is a member of the AWS-managed `rds_superuser` role, which inherits `pg_read_all_data` and `pg_write_all_data` (granted by `rdsadmin`) and itself holds SELECT/INSERT/UPDATE/DELETE/TRUNCATE on application tables. The master therefore keeps **direct data access**; this cannot be revoked and was not changed. `SET ROLE stockwatch_migrator` (membership `INHERIT FALSE, SET TRUE`) is the **emergency migration-access mechanism** — acting as the schema owner for DDL and migration work — not a prerequisite for data access. The temporary transition grant to the master was removed by `--end-transition` (no explicit `stockwatch_admin` entries remain in table ACLs).

## Production rollout plan (original draft — superseded)

The executed procedure, evidence and corrections are in `docs/runbooks/db-roles-rollout.md`. The draft below is kept for history.

Prerequisite: the backend image containing `DB_BOOTSTRAP_SCHEMA` gating (this branch) is deployed via PR → `main` → CI. The currently deployed `1cc73a2` backend runs DDL at startup; as `stockwatch_app` that DDL would fail (caught and logged) — functional but noisy.

1. Generate two passwords (`openssl rand -hex 32`), add to `.env` as `APP_DB_PASSWORD` / `MIGRATOR_DB_PASSWORD` (mode 600, not committed).
2. **Dry run against RDS** (no change; brief locks held only inside the rolled-back transaction):
   ```bash
   set -a; source .env; set +a
   ADMIN_DATABASE_URL="$DATABASE_URL" infrastructure/deployment/db-roles.sh --transfer-ownership \
     --ca-file /home/ubuntu/ap-southeast-2-bundle.pem \
     --confirm-host stockwatch-primary-db.cns8kouwop3n.ap-southeast-2.rds.amazonaws.com
   ```
3. Apply (same command + `--apply`). Ownership transfer takes a short `ACCESS EXCLUSIVE` lock per table (5 objects).
4. Isolated credential probe for both new users (`SELECT 1`, no app restart).
5. Update `.env`: `DATABASE_URL` → `stockwatch_app`, `MIGRATION_DATABASE_URL` → `stockwatch_migrator`; recreate backend and worker (`--no-deps`, same procedure as the 2026-11-10 recovery, ~16 s).
6. Validate health, inventory, worker; confirm in `pg_stat_activity` that application sessions use `stockwatch_app`.

Rollback: revert `.env` `DATABASE_URL` to the master user and recreate backend/worker (roles can remain). Ownership can be returned with `ALTER TABLE … OWNER TO stockwatch_admin` per object (documented; not automated).
