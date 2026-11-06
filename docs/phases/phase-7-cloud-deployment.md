# Phase 7 — Cloud VM Deployment

## Read first
`AGENTS.md`, context 03, 09–12, and 15.

## Goal
Deploy the working Compose stack to one AWS or Azure Ubuntu VM.

## Tasks
1. Confirm cloud account eligibility, region, estimated costs, and billing alerts before provisioning.
2. Provision one appropriately sized Ubuntu VM.
3. Configure SSH key access and firewall/security group (80/443 and restricted SSH only).
4. Install Docker Engine and Compose plugin.
5. Create protected runtime environment file on VM.
6. Configure production Compose so PostgreSQL and Redis are internal only.
7. Configure reverse proxy/TLS if needed.
8. Deploy exact SHA-tagged GHCR images through CI.
9. Apply migrations in a controlled deployment step.
10. Verify public frontend, backend health, queue processing, and worker.
11. Record public deployment URL and actual infrastructure choices.

## Acceptance
Public application URL works; all services communicate; DB/Redis are not publicly exposed; deployment can be repeated from CI. Do not claim production readiness beyond what has been tested.
