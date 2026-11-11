-- StockWatch database roles: runtime (DML only) separated from migrations (DDL).
--
-- Applied by infrastructure/deployment/db-roles.sh, connected as the RDS master
-- user (or another role with CREATEROLE that owns the database). Idempotent.
--
-- psql variables supplied by the script (never written to disk or argv):
--   :app_verifier       SCRAM-SHA-256 verifier for stockwatch_app       ('' = keep existing)
--   :migrator_verifier  SCRAM-SHA-256 verifier for stockwatch_migrator  ('' = keep existing)
--   :transfer_ownership 'true' to make stockwatch_migrator own existing objects in schema public
--   :transition_grant   'true' to also grant DML on all tables to the managing (master) user, so
--                       sessions still connected as that user keep working until the application
--                       has switched to stockwatch_app (remove with roles-end-transition.sql)
--
-- Roles:
--   stockwatch_migrator  LOGIN; owns the schema objects; runs `prisma migrate deploy`.
--   stockwatch_app       LOGIN; SELECT/INSERT/UPDATE/DELETE only; no DDL, no TRUNCATE,
--                        no access to _prisma_migrations. Used by backend and worker.
--   master user          break-glass and role management only; no application traffic.

\set ON_ERROR_STOP on
-- Never queue behind (and block) application traffic: give up after 5 s and roll back instead.
SET LOCAL lock_timeout = '5s';
SELECT current_user AS managing_user \gset

-- 1. Roles (created only if absent; a new role requires a verifier).
SELECT CASE WHEN :'migrator_verifier' = '' THEN
         'DO $$ BEGIN RAISE EXCEPTION ''stockwatch_migrator does not exist and no password was supplied''; END $$'
       ELSE format('CREATE ROLE stockwatch_migrator LOGIN NOCREATEDB NOCREATEROLE PASSWORD %L',
                   :'migrator_verifier') END
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stockwatch_migrator') \gexec

SELECT CASE WHEN :'app_verifier' = '' THEN
         'DO $$ BEGIN RAISE EXCEPTION ''stockwatch_app does not exist and no password was supplied''; END $$'
       ELSE format('CREATE ROLE stockwatch_app LOGIN NOCREATEDB NOCREATEROLE PASSWORD %L',
                   :'app_verifier') END
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stockwatch_app') \gexec

-- Password rotation for existing roles (only when a verifier is supplied).
SELECT format('ALTER ROLE stockwatch_migrator PASSWORD %L', :'migrator_verifier') WHERE :'migrator_verifier' <> '' \gexec
SELECT format('ALTER ROLE stockwatch_app PASSWORD %L', :'app_verifier') WHERE :'app_verifier' <> '' \gexec

-- Guardrails. SUPERUSER/REPLICATION/BYPASSRLS can only be changed by a superuser (the RDS master is
-- not one), so they are verified rather than set: fail if either role is elevated.
SELECT format('DO $$ BEGIN RAISE EXCEPTION ''role %s has elevated attributes; refusing to continue''; END $$', rolname)
FROM pg_roles
WHERE rolname IN ('stockwatch_app', 'stockwatch_migrator')
  AND (rolsuper OR rolreplication OR rolbypassrls OR rolcreaterole OR rolcreatedb) \gexec

-- Per-role limits and timeouts (protect a db.t4g.micro from runaway sessions).
ALTER ROLE stockwatch_app CONNECTION LIMIT 30;
ALTER ROLE stockwatch_app SET statement_timeout = '30s';
ALTER ROLE stockwatch_app SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE stockwatch_migrator CONNECTION LIMIT 5;
ALTER ROLE stockwatch_migrator SET lock_timeout = '30s';

-- 2. The managing user must be able to SET ROLE stockwatch_migrator (to transfer ownership and
--    to grant on migrator-owned objects) but must not inherit its privileges implicitly.
--    PostgreSQL 16 syntax; a CREATEROLE user holds ADMIN OPTION on roles it created.
SELECT format('GRANT stockwatch_migrator TO %I WITH INHERIT FALSE, SET TRUE', current_user)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_auth_members m
  WHERE m.roleid = 'stockwatch_migrator'::regrole AND m.member = current_user::regrole AND m.set_option
) \gexec

-- 3. Database and schema access.
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database()) \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO stockwatch_app, stockwatch_migrator', current_database()) \gexec
SELECT format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', current_database(), current_user) \gexec
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO stockwatch_app;
GRANT USAGE, CREATE ON SCHEMA public TO stockwatch_migrator;

-- 4. Optional one-time ownership transfer of existing objects (production schema was created by
--    the master user). Takes brief ACCESS EXCLUSIVE locks per object.
SELECT format('ALTER %s public.%I OWNER TO stockwatch_migrator',
              CASE c.relkind WHEN 'S' THEN 'SEQUENCE' WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END,
              c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE :'transfer_ownership' = 'true'
  AND n.nspname = 'public'
  AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
  AND NOT (c.relkind = 'S' AND EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype IN ('a', 'i')))
  AND c.relowner <> 'stockwatch_migrator'::regrole \gexec

SELECT format('ALTER TYPE public.%I OWNER TO stockwatch_migrator', t.typname)
FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE :'transfer_ownership' = 'true'
  AND n.nspname = 'public' AND t.typtype IN ('e', 'd', 'c')
  AND (t.typtype <> 'c' OR EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = t.typrelid AND c.relkind = 'c'))
  AND t.typowner <> 'stockwatch_migrator'::regrole \gexec

-- Guard: grants below are issued as stockwatch_migrator and would silently grant nothing on objects
-- it does not own (e.g. the production schema created by the master user).
SELECT 'DO $$ BEGIN RAISE EXCEPTION ''objects in schema public are not owned by stockwatch_migrator; re-run with --transfer-ownership''; END $$'
WHERE EXISTS (
  SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
    AND NOT (c.relkind = 'S' AND EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype IN ('a', 'i')))
    AND c.relowner <> 'stockwatch_migrator'::regrole
) \gexec

-- 5. Runtime privileges, granted as the owner so they are valid on migrator-owned objects.
SET ROLE stockwatch_migrator;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO stockwatch_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO stockwatch_app;
ALTER DEFAULT PRIVILEGES FOR ROLE stockwatch_migrator IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO stockwatch_app;
ALTER DEFAULT PRIVILEGES FOR ROLE stockwatch_migrator IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO stockwatch_app;

-- The migration ledger is never runtime data. (Default privileges grant DML on new tables, so
-- re-run this script after the first `migrate deploy` on an empty database.)
SELECT 'REVOKE ALL ON public._prisma_migrations FROM stockwatch_app'
WHERE to_regclass('public._prisma_migrations') IS NOT NULL
  AND pg_get_userbyid((SELECT relowner FROM pg_class WHERE oid = to_regclass('public._prisma_migrations'))) = 'stockwatch_migrator' \gexec

-- Optional zero-downtime transition: the running application still connects as the managing
-- user, which loses implicit access when ownership moves to stockwatch_migrator.
SELECT format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO %I', :'managing_user')
WHERE :'transition_grant' = 'true' \gexec

RESET ROLE;

-- 6. Report (no secrets).
SELECT r.rolname, r.rolcanlogin AS login, r.rolconnlimit AS conn_limit,
       r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolbypassrls AS elevated,
       coalesce(array_to_string(r.rolconfig, ', '), '') AS settings
FROM pg_roles r WHERE r.rolname IN ('stockwatch_app', 'stockwatch_migrator') ORDER BY 1;

SELECT c.relname AS object, pg_get_userbyid(c.relowner) AS owner,
       has_table_privilege('stockwatch_app', c.oid, 'SELECT') AS app_select,
       has_table_privilege('stockwatch_app', c.oid, 'INSERT,UPDATE,DELETE') AS app_write,
       has_table_privilege('stockwatch_app', c.oid, 'TRUNCATE') AS app_truncate,
       has_table_privilege(:'managing_user', c.oid, 'SELECT') AS managing_user_select
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') ORDER BY 1;
