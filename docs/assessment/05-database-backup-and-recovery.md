# 05 — Database Backup and Recovery

## Layers

| Layer | Mechanism | Status |
|---|---|---|
| RDS automated backups | daily snapshot + transaction logs, **1-day** retention (PITR within ≈ last 24 h) | **Production verified** (configuration observed); **PITR restore not demonstrated** (would create a billable instance) |
| Logical backups | `pg-backup-verify.sh`: `pg_dump` + manifest from **one read-only snapshot**, sha256, restored into an isolated PostgreSQL 16 and compared by row counts + content hashes | **Isolated restore verified** with production data |
| Restore tooling | `pg-restore.sh`: verified backups only, checksum check, refuses non-empty targets, dated confirmation token, verifies restored content against the manifest | **Code implemented and tested**; exercised in local simulation (S7) |

## Logical backups no longer need the master credential

Tested (not assumed) on 2026-11-11: `pg-backup-verify.sh` run as **`stockwatch_migrator`** against production produced a VERIFIED backup including `_prisma_migrations`, with content hashes identical to the post-job baseline (inventory 5 / stock_checks 7 / stock_alerts 8). Backups are run manually — no cron job or timer is configured on the host. Command:

```bash
SOURCE_DATABASE_URL="$(grep -E '^MIGRATION_DATABASE_URL=' .env | cut -d= -f2- | tr -d '"')" \
  infrastructure/deployment/backup/pg-backup-verify.sh --ca-file /home/ubuntu/ap-southeast-2-bundle.pem [--keep 14]
```

The master credential remains necessary only for `db-roles.sh` and `pg-restore.sh` into a new database (supplied via hidden prompt).

## Reliability guarantees (verified by tests)

- Timestamped directories; dumps and manifests are mode 600 in 700 directories under `~/stockwatch-backups/` (outside the repository; backup artefacts are never tracked by Git).
- Failures exit non-zero and print no credentials.
- **Fixed defect (2026-11-11):** failed runs previously left directories that retention counted as backups, and a run whose verification failed still applied retention — repeated failures could delete every good backup. Now runs work in `.incomplete-<ts>`, are published only when VERIFIED, failures are kept as `<ts>.FAILED`, and retention (`--keep N`, default 14) counts only VERIFIED backups. The regression test fails on the old code (it deleted the previous good backup) and passes on the new.

## Production backups on record

| Backup (`~/stockwatch-backups/postgres/`) | Taken as | Rows: inventory / stock_checks / stock_alerts |
|---|---|---|
| `20261110T215542Z` | master (read-only) | 5 / 6 / 7 |
| `20261111T023252Z` | master (read-only) — pre-role-rollout | 5 / 6 / 7 |
| `20261111T032021Z` | **stockwatch_migrator** | 5 / 7 / 8 (after the controlled job) |

## Recovery procedures

- **Logical corruption / table loss:** restore a verified backup into an empty database with `pg-restore.sh`, re-run `db-roles.sh` (roles are cluster-level), repoint `DATABASE_URL`, `deploy.sh`. Local simulation S7: 6.1 s, RPO = writes after the backup ([09](09-rto-rpo-measurements.md)).
- **Instance loss:** RDS PITR to a new instance (console/CLI, authorized human) — not demonstrated.
- **Region loss:** see [07](07-failover-and-failback.md) — designed, not demonstrated in AWS.
