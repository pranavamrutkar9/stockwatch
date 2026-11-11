# 04 — Security and IAM

## IAM: least-privilege read-only instance role (Production verified)

- Policy v1.0 ([`docs/aws/iam-readonly-discovery-policy.json`](../aws/iam-readonly-discovery-policy.json)): 65 `Describe*/List*/Get*` actions, region-scoped, plus **13 explicit denies** (secret values, SSM parameter values, KMS decrypt, S3 object reads, EC2 user-data/console output, RDS log download, IAM DB auth). Per-action review: [`docs/aws/iam-policy-review.md`](../aws/iam-policy-review.md).
- Incident caught during verification: the instance first carried AWS's broad default role `AWSEC2RoleforDefaultAWSServiceAccess` (19 managed policies incl. several `*FullAccess`); work stopped, the user replaced it. Verified identity: `assumed-role/stockwatch-dr-readonly-discovery/i-07590867e7e49c18b`.
- Negative tests (2026-11-11): explicit deny confirmed for GetSecretValue, BatchGetSecretValue, SSM GetParameter, EC2 user-data and console output; writes (EC2 dry-run CreateTags/RunInstances, RDS snapshot/modify, Route 53 change, S3 bucket, IAM user) and other regions denied. `kms:Decrypt` **inconclusive at API level** (KMS validates ciphertext before authorization; the role cannot produce valid ciphertext) — the deny is present in the policy.
- Consequence by design: this role **cannot** rotate the RDS password or change IMDS settings — those are human actions.

## EC2 metadata (IMDS) isolation — Production verified (2026-11-11 08:17 UTC)

| Setting | Before (EC2 API, 2026-11-11 ~03:19 UTC) | Now (EC2 API, 2026-11-11 08:17 UTC) | Required |
|---|---|---|---|
| HttpTokens | `required` (IMDSv2 only) | `required` | `required` ✔ |
| HttpEndpoint | `enabled` | `enabled` | `enabled` (host AWS CLI uses the instance role) ✔ |
| HttpPutResponseHopLimit | **2** | **1** (`State: applied`) | **1** ✔ |

**Test method** ([`scripts/verify-imds-isolation.sh`](../../scripts/verify-imds-isolation.sh)): from inside each production container (via `node`) or a probe container on the app network / default bridge, perform the IMDSv2 `PUT /latest/api/token` handshake, then request only the credential *path* (`/meta-data/iam/security-credentials/`, returns the role name) — the credential document is never fetched. A failed unauthenticated request is not treated as proof. Exit codes: `0` isolated (every probe ran and was blocked), `1` at least one container reaches the credential path, `3` inconclusive (a probe failed or produced unrecognised output — never reported as isolated).

**Baseline (2026-11-11 03:19 UTC, hop limit 2):** host reachable; backend, worker, frontend, app-network probes and default-bridge probe **all reached the credential path** → exit 1.

**After the change (2026-11-11 08:17 UTC, hop limit 1):** host reachable (`token=200 credential_path=200`, required for the host AWS CLI); backend, worker, frontend, app-network probes and default-bridge probe all `token=timeout credential_path=not-attempted` → **exit 0, containers cannot reach instance-role credentials**. Evidence: `~/stockwatch-dr-evidence/imds-isolation-20261111T081744Z.txt` on the host (outside the repository).

The metadata change was not made by this assessment's tooling — the read-only discovery role cannot modify instance metadata — and that role cannot read CloudTrail, so the actor and exact time of the change are not recorded here. For reference, the change is EC2 → instance → Actions → Instance settings → *Modify instance metadata options* → IMDSv2 **Required**, **Hop limit 1**, or `aws ec2 modify-instance-metadata-options --instance-id i-07590867e7e49c18b --http-tokens required --http-put-response-hop-limit 1 --http-endpoint enabled`; it is free and needs no restart. Re-run `scripts/verify-imds-isolation.sh` after any instance replacement or launch-template change — a new instance does not inherit this setting unless the launch configuration sets it.

## Database credential separation (Production verified)

| Account | Type | Privileges (verified) | Used by |
|---|---|---|---|
| `stockwatch_app` | restricted runtime | SELECT/INSERT/UPDATE/DELETE on application tables; **denied**: CREATE/ALTER/DROP, TRUNCATE, `_prisma_migrations`, CREATE ROLE; statement_timeout 30 s; ≤ 30 connections | backend, worker |
| `stockwatch_migrator` | migration role, schema owner | owner of all tables/enum; DDL; `prisma migrate status/deploy`; no CREATE ROLE; ≤ 5 connections | `deploy.sh` migrations, logical backups (manual) |
| `stockwatch_admin` | **elevated RDS master** | member of AWS-managed `rds_superuser` (→ `pg_read_all_data`, `pg_write_all_data`, granted by `rdsadmin`): **direct read/write/TRUNCATE on all tables**, CREATEROLE, database owner; `SET ROLE stockwatch_migrator` for emergency schema work | administrators only |

The RDS master's data access is an AWS platform property and cannot be revoked; the control is credential handling (not in any application config) and rotation. Rollout evidence: [`docs/runbooks/db-roles-rollout.md`](../runbooks/db-roles-rollout.md); model and correction: [`docs/database-roles.md`](../database-roles.md).

## TLS (Production verified)

Backend, worker, migrations and all operator tooling connect with `sslmode=require&sslaccept=strict` (Prisma) or `verify-full` (psql) against the regional RDS CA bundle; sessions observed as TLS 1.3. A wrong CA is rejected (`certificate verify failed`, isolated test). Database and Redis are not publicly exposed (only ports 22 and 80 listen publicly).

## RDS master password rotation — Blocked by authorization

Audit (GNU grep, hashes/paths only): the master credential is **only** in `.env.pre-roles` (600, git-ignored); absent from `.env`, containers, images, Git history (all refs/reflog), shell history and Claude Code transcripts. Prepared procedure and verifier: [`docs/runbooks/rds-master-password-rotation.md`](../runbooks/rds-master-password-rotation.md), [`scripts/verify-master-rotation.sh`](../../scripts/verify-master-rotation.sh) (hidden prompt; deletes `.env.pre-roles` only after every check passes). **Not yet rotated.**

### Legacy credential files

| File | Contents | Assessment |
|---|---|---|
| `.env.pre-roles` | old master URL | delete after rotation (scripted) |
| `.env.pre-rds-cutover` | pre-RDS config: local Postgres credential (identical to the live `.env` value used by the preserved legacy `stockwatch-postgres` container — internal network, no published ports) and a **pre-rotation Redis password that Redis no longer accepts** | redundant; contains no RDS credential; retained pending owner decision (archive off-host or delete) |
