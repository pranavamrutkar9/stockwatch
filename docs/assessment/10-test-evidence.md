# 10 — Test Evidence Index

## Automated tests (repository) — Code implemented and tested

Results from the validation run on branch `release/assessment-final`, 2026-11-11 (working tree including the review fixes). None of these suites contacts AWS or production data.

| Suite | Command | Result |
|---|---|---|
| Typecheck (4 packages) | `pnpm typecheck` | pass |
| Lint | `pnpm lint` | pass (exit 0) |
| Unit — backend / worker | `pnpm db:build && pnpm test` | 35 / 10 pass (database-backed specs run in the integration suite) |
| Builds — backend, worker, frontend | `pnpm build` | pass |
| Integration (real PostgreSQL + Redis containers) | `scripts/test-integration.sh` | 35 / 35 |
| Deployment scripts (deploy, rollback, targets) | `scripts/test-deploy-scripts.sh` | 31 / 31 |
| DR automation (stub AWS CLI) | `scripts/test-dr-automation.sh` | 25 / 25 |
| Backup / restore incl. failed, interrupted (SIGTERM/SIGINT) and retention cases | `scripts/test-backup-restore.sh` | 29 / 29 |
| Rotation verifier + IMDS script (mocked docker/aws/curl, fake passwords) | `scripts/test-security-scripts.sh` | 17 / 17 |
| DR video demonstration end to end + failure handling (local simulation) | `scripts/test-dr-demo.sh` | 42 / 42 |
| Terraform `app_host` / `database` modules, `dr-melbourne` plan | `terraform test` | 4 / 5 / 6 (offline, no apply) |
| ShellCheck (`-S warning`) | all 26 repository shell scripts | clean |

## Simulations — Local simulation verified

| Run | What | Evidence (host, not committed) | Summary |
|---|---|---|---|
| `sim-1794358922` | S1–S7 failure scenarios | `~/stockwatch-dr-evidence/sim-1794358922/` | [`docs/dr-simulation-results.md`](../dr-simulation-results.md) |
| `dns-sim-1794368074` | CoreDNS failover, 3 rounds | `~/stockwatch-dr-evidence/dns-sim-1794368074/` | [08](08-dns-failover-simulation.md) |

## Production observations — Production verified

| Date (UTC) | Observation | Evidence (host, not committed) |
|---|---|---|
| 2026-11-10 | Outage root cause and recovery | [`docs/runbooks/production-credential-recovery.md`](../runbooks/production-credential-recovery.md) |
| 2026-11-11 02:10 | Deploy `498e28b`, availability probe | `~/stockwatch-dr-evidence/deploy-498e28b/` |
| 2026-11-11 02:16–02:47 | DB role dry run, apply, application switch, transition-grant removal | `~/stockwatch-dr-evidence/db-roles-{dryrun,apply,rollout}-*/` |
| 2026-11-11 02:50 | One controlled stock-check job `825a658d-…` → COMPLETED | `~/stockwatch-dr-evidence/stock-check-job-20261111T025049Z/` |
| 2026-11-11 03:20 | Backup as `stockwatch_migrator`, VERIFIED | `~/stockwatch-backups/postgres/20261111T032021Z/manifest.txt` |
| 2026-11-11 08:17 | IMDS: hop limit 1, containers isolated (exit 0) | `~/stockwatch-dr-evidence/imds-isolation-20261111T081744Z.txt` |
| 2026-11-11 08:17 | Pre-rotation master credential still accepted (rotation not done) | read-only `SELECT 1`; not stored |
