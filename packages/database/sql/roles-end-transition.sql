-- End the zero-downtime transition: remove the temporary DML grant given to the managing (master)
-- user by roles.sql (:transition_grant). Run only after backend and worker connect as stockwatch_app.
-- Idempotent. Applied by: db-roles.sh --end-transition
\set ON_ERROR_STOP on
-- Never queue behind (and block) application traffic: give up after 5 s and roll back instead.
SET LOCAL lock_timeout = '5s';
SELECT current_user AS managing_user \gset

-- Refuse while application sessions still use the managing user (would break them).
SELECT format('DO $$ BEGIN RAISE EXCEPTION ''%s client session(s) still connected as %s; switch the application first''; END $$', n, :'managing_user')
FROM (SELECT count(*) AS n FROM pg_stat_activity
      WHERE datname = current_database() AND usename = :'managing_user' AND pid <> pg_backend_pid()
        AND backend_type = 'client backend' AND coalesce(application_name, '') NOT IN ('psql', 'stockwatch-db-roles')) s
WHERE n > 0 AND :'force_end_transition' <> 'true' \gexec

SET ROLE stockwatch_migrator;
SELECT format('REVOKE SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM %I', :'managing_user') \gexec
RESET ROLE;

SELECT c.relname AS object,
       has_table_privilege(:'managing_user', c.oid, 'SELECT') AS managing_user_select,
       has_table_privilege('stockwatch_app', c.oid, 'SELECT') AS app_select
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') ORDER BY 1;
