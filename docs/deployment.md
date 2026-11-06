# StockWatch Deployment Runbook

> Replace TODO values with the actual environment details. Never put secret values in this document.

## Prerequisites

- Ubuntu VM on the selected cloud provider
- Docker Engine and Docker Compose plugin
- GHCR access for the deployment host
- Protected runtime `.env` file on the VM

## Deploy

1. Confirm the target commit SHA and that CI passed.
2. Pull the three application images using that SHA.
3. Apply Prisma migrations using the documented controlled command.
4. Start/update the production Compose stack.
5. Verify frontend availability and backend health.
6. Submit a stock check and confirm worker completion.

## Rollback

1. Identify the previous known-good SHA tags.
2. Restore those tags in the deployment configuration.
3. Pull and restart the previous images.
4. Re-run health and workflow checks.
5. Treat database migration rollback separately; prefer backward-compatible migrations.

## Actual environment record

- Provider/region: TODO
- VM details: TODO
- Public URL: TODO
- Compose command: TODO
- Health-check URL: TODO
- Backup/restore procedure: TODO
