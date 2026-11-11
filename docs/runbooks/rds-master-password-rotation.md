# Runbook — RDS Master Password Rotation (`stockwatch_admin`)

**Status:** PREPARED. Requires a human with an authorized AWS console session — the EC2 instance role (`stockwatch-dr-readonly-discovery`) is read-only by design and must not be used for this.
**Cost:** none (no Secrets Manager; password kept in the operator's existing password manager).

## Pre-rotation facts (audited 2026-11-11, GNU grep / hashes only, no values printed)

| Location | Master credential |
|---|---|
| `~/stockwatch/.env` (live) | **absent** — holds `stockwatch_app` + `stockwatch_migrator` only |
| backend / worker containers, all images | absent; both connect as `stockwatch_app` |
| `~/stockwatch/.env.pre-roles` (600, git-ignored) | **present — the only host copy** (rollback artifact of the role rollout) |
| Git: all branches, tags, 41+ commits incl. reflog | absent |
| `.env.pre-rds-cutover` (600, git-ignored) | absent (legacy local-Postgres credential + an already-rotated Redis password) |

Consumers of the master credential: `db-roles.sh` (role management) and `pg-restore.sh` (restore into a new database) only — both supplied at time of use via a hidden prompt. Logical backups use `stockwatch_migrator` (verified 2026-11-11; runs are manual — no schedule is configured). Nothing in the running application uses it, so rotation needs **no restart**.

## Procedure

1. **Pre-check (operator host):** `curl -s localhost/api/health` → 200; record the time: `date -u +%Y-%m-%dT%H:%M:%SZ` (used as `--since`).
2. **Fresh verified backup (no master needed):**
   ```bash
   SOURCE_DATABASE_URL="$(grep -E '^MIGRATION_DATABASE_URL=' .env | cut -d= -f2- | tr -d '"')" \
     infrastructure/deployment/backup/pg-backup-verify.sh --ca-file /home/ubuntu/ap-southeast-2-bundle.pem
   ```
3. **Generate the password** in the password manager: ≥ 40 characters, letters and digits only (no URL escaping). Do not paste it into any server file or shell command line.
4. **Rotate (AWS console, authorized human):** RDS → Databases → `stockwatch-primary-db` → **Modify** → *Settings* → **New master password** (and confirm) → Continue → **Apply immediately** → Modify DB instance. No reboot; the instance briefly shows `resetting-master-credentials`. Do **not** enable "Manage master credentials in AWS Secrets Manager" (recurring cost and automatic rotation).
5. **Verify (operator host):**
   ```bash
   scripts/verify-master-rotation.sh --since <time from step 1>
   ```
   Paste the new password at the hidden prompt (it is passed to `psql` only via `PGPASSWORD`; the script disables shell tracing if run under `bash -x`). Exit codes: `0` all checks passed, `1` at least one check failed, `2` usage error (`--since` must be UTC, e.g. `2026-11-11T08:00:00Z`). A network/TLS failure is reported as a *connection problem*, never as "old credential rejected" — re-run when connectivity is restored. Expected: RDS event "Reset master credentials", old credential rejected, new credential works (`stockwatch_admin`, TLS, `rds_superuser`), `stockwatch_app`/`stockwatch_migrator` work, backend/worker still `stockwatch_app` and **not restarted**, health 200.
6. **Remove the last host copy of the old credential** (only if step 5 passed):
   ```bash
   scripts/verify-master-rotation.sh --since <time from step 1> --delete-pre-roles
   ```
7. `.env.pre-rds-cutover`: keep or archive — see [`docs/assessment/04-security-and-iam.md`](../assessment/04-security-and-iam.md#legacy-credential-files).

## If something goes wrong

The application does not use the master credential, so a failed rotation cannot cause an outage. If the new password is lost, reset it again from the console (same step 4). Do not restore `.env.pre-roles` into `.env`.
