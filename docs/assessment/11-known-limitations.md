# 11 — Known Limitations

State as of 2026-11-11. Items are open unless marked otherwise.

## Not demonstrated

| Item | Why | Needed to close |
|---|---|---|
| Real Melbourne (ap-southeast-4) recovery | Region not opted in; replica, DR host and Elastic IPs are billable | Enable region; apply `infrastructure/terraform/envs/dr-melbourne` with `allow_billable`; cross-region replica or backup replication |
| Public DNS failover | `stockwatch-hz` is a private zone with no health checks; no registered domain (Route 53 Domains unavailable on this free-plan account) | Public hosted zone + domain + Route 53 health checks (billable) |
| RDS point-in-time restore | Creates a billable instance | Authorized restore to a temporary instance, then delete |
| AWS-level RTO/RPO | Every RTO/RPO in [09](09-rto-rpo-measurements.md) is local simulation or primary-host production; no cross-region timing exists | The two items above |

## Security

| Item | Status |
|---|---|
| RDS master password rotation | **Not done.** The pre-rotation master credential was still accepted on 2026-11-11 08:17 UTC. Procedure: [`docs/runbooks/rds-master-password-rotation.md`](../runbooks/rds-master-password-rotation.md); verify with `scripts/verify-master-rotation.sh`. |
| `.env.pre-roles` (holds the pre-rotation master URL, mode 600, untracked) | Kept deliberately until the rotation is verified; then delete (`verify-master-rotation.sh --delete-pre-roles`). |
| RDS master is inherently elevated | `rds_superuser` inherits `pg_read_all_data` / `pg_write_all_data` (granted by `rdsadmin`, cannot be revoked). Mitigation: no application use, credential held outside configuration, rotation. |
| IMDS container isolation | **Closed** — hop limit 1, isolation verified 2026-11-11 08:17 UTC ([04](04-security-and-iam.md)). Must be re-applied on any replacement instance. |
| EC2 root volume | Unencrypted. |

## Availability and operations

- Single-AZ RDS, **1-day** backup retention (PITR window ≈ last 24 h).
- One EC2 host, auto-assigned public IPv4 (**no Elastic IP**): a stop/start changes the address.
- CI deploy job cannot reach EC2 (SSH restricted to one operator /32); production deploys are run on the host ([07](07-failover-and-failback.md)). Proposed no-cost fix (GitHub OIDC + SSM Run Command) not implemented.
- Logical backups are run manually (no cron job or timer configured) and are local to the primary host (`~/stockwatch-backups/`); no off-host or cross-region copy.
- A SIGKILLed worker's in-flight jobs wait up to ≈ 60 s (BullMQ lock + stalled check); queue reconstruction after Redis loss runs every 60 s with a 120 s grace in production.
- Deploys interrupt the API for several seconds (≈ 6.2 s measured for `498e28b`).
