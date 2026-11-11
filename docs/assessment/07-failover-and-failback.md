# 07 — Failover and Failback

## Application-level endpoint switching (Option D)

- Explicit deployment targets: [`infrastructure/deployment/targets/primary.env`](../../infrastructure/deployment/targets/primary.env) (Sydney — production) and [`melbourne.env`](../../infrastructure/deployment/targets/melbourne.env) (placeholders → refused until provisioned). `deploy.sh`/`rollback.sh` validate region, endpoint, regional CA bundle and both database URLs; `STOCKWATCH_ENV_FILE` / `STOCKWATCH_STATE_DIR` let CI deploy from a dedicated clone.
- Automation: [`infrastructure/deployment/dr/`](../../infrastructure/deployment/dr/) — `dr-failover.sh`, `dr-failback.sh`, providers `aws` and `local`.

| Safety property | Evidence |
|---|---|
| Dry run by default; mutations only with `--execute` + dated `--confirm FAILOVER-YYYYMMDD` | 25 behavioural tests (stub AWS CLI) |
| Billable steps need `--allow-billable` | tests |
| Refuses unknown/excessive replication lag | tests |
| Idempotent promotion | tests |
| Refuses execution on the Sydney host (would overwrite production `.env`) | tests **and production verified** (real `--execute` on the primary aborted before any AWS call) |
| Real-AWS dry run | **Production verified**: aborts cleanly ("replica not found or not accessible in ap-southeast-4") |

## End-to-end (Local simulation verified)

`scripts/dr-simulate.sh` promotes a real PostgreSQL streaming standby and starts the secondary application with empty Redis + queue reconstruction, then fails back by re-seeding the old region and switching with writers stopped. Results in [09](09-rto-rpo-measurements.md) (S5/S6).

## Deployment procedure used in production

Merge → GitHub Actions validates and publishes images; the **deploy job cannot reach EC2** (SSH restricted to one operator /32; the runner's 30 s connect timeout; no sshd log entries). Production release `498e28b` and the role switchover were therefore deployed **on the host** with the identical script:

```bash
cd ~/stockwatch-deploy && git fetch origin main && git checkout --detach <sha>
STOCKWATCH_ENV_FILE=/home/ubuntu/stockwatch/.env STOCKWATCH_STATE_DIR=/home/ubuntu/stockwatch/infrastructure/deployment \
  IMAGE_TAG=<sha> bash infrastructure/deployment/deploy.sh <sha>
```

Recommended no-cost fix (not implemented — needs IAM changes by an administrator): GitHub OIDC → IAM role allowed `ssm:SendCommand` on this instance only, SSM agent permissions on the instance role; the job runs the same command via SSM Run Command (no inbound SSH). Opening SSH to GitHub runner ranges is rejected.

Rollback: `rollback.sh <previous-sha>` (also automatic when post-deploy health checks fail).

## Real regional failover

**Not demonstrated.** Requires enabling ap-southeast-4, a cross-region replica or backup replication, a DR host and Elastic IPs (all billable or account-level changes).
