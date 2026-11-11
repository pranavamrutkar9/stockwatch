-- Roll back roles.sql: return schema ownership and access to the managing (master) user and
-- disable the stockwatch_app / stockwatch_migrator logins. Data is not touched.
-- Prerequisite: backend/worker DATABASE_URL already reverted to the managing user.
-- Roles are kept (NOLOGIN) for audit; dropping them is a separate, explicit step.
-- Applied by: db-roles.sh --rollback
\set ON_ERROR_STOP on
-- Never queue behind (and block) application traffic: give up after 5 s and roll back instead.
SET LOCAL lock_timeout = '5s';
SELECT current_user AS managing_user \gset

-- 0. Changing an object's owner requires holding the current owner's privileges. The managing
--    user's membership in stockwatch_migrator is INHERIT FALSE by design, so enable INHERIT for the
--    duration of this transaction (it holds ADMIN OPTION on the role it created). Reset in step 5.
SELECT format('GRANT stockwatch_migrator TO %I WITH INHERIT TRUE, SET TRUE', :'managing_user') \gexec

-- 1. Ownership back to the managing user.
SELECT format('ALTER %s public.%I OWNER TO %I',
              CASE c.relkind WHEN 'S' THEN 'SEQUENCE' WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END,
              c.relname, :'managing_user')
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
  AND NOT (c.relkind = 'S' AND EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype IN ('a', 'i')))
  AND pg_get_userbyid(c.relowner) = 'stockwatch_migrator' \gexec

SELECT format('ALTER TYPE public.%I OWNER TO %I', t.typname, :'managing_user')
FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'public' AND t.typtype IN ('e', 'd')
  AND pg_get_userbyid(t.typowner) = 'stockwatch_migrator' \gexec

-- 2. Remove runtime/migration privileges (grants were re-attributed to the new owner).
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM stockwatch_app;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM stockwatch_app;
SELECT format('REVOKE ALL ON ALL TABLES IN SCHEMA public FROM %I', 'stockwatch_migrator') \gexec
ALTER DEFAULT PRIVILEGES FOR ROLE stockwatch_migrator IN SCHEMA public REVOKE ALL ON TABLES FROM stockwatch_app;
ALTER DEFAULT PRIVILEGES FOR ROLE stockwatch_migrator IN SCHEMA public REVOKE ALL ON SEQUENCES FROM stockwatch_app;
REVOKE ALL ON SCHEMA public FROM stockwatch_app;
REVOKE ALL ON SCHEMA public FROM stockwatch_migrator;

-- 3. Database access back to the PostgreSQL default (PUBLIC: CONNECT, TEMPORARY).
SELECT format('REVOKE ALL ON DATABASE %I FROM stockwatch_app, stockwatch_migrator', current_database()) \gexec
SELECT format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO PUBLIC', current_database()) \gexec

-- 4. Disable logins (roles kept for audit).
ALTER ROLE stockwatch_app NOLOGIN;
ALTER ROLE stockwatch_migrator NOLOGIN;

-- 5. Restore the non-inheriting membership (break-glass via SET ROLE only).
SELECT format('GRANT stockwatch_migrator TO %I WITH INHERIT FALSE, SET TRUE', :'managing_user') \gexec

-- Report
SELECT c.relname AS object, pg_get_userbyid(c.relowner) AS owner,
       has_table_privilege(:'managing_user', c.oid, 'SELECT,INSERT,UPDATE,DELETE') AS managing_user_dml,
       has_table_privilege('stockwatch_app', c.oid, 'SELECT') AS app_select
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') ORDER BY 1;
SELECT rolname, rolcanlogin FROM pg_roles WHERE rolname IN ('stockwatch_app', 'stockwatch_migrator') ORDER BY 1;
