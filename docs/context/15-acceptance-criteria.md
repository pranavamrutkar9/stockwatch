# 15 — Acceptance Criteria and Submission Checklist

## Application

- [x] Inventory items can be created, listed, and updated.
- [x] Low-stock status uses exactly `quantity <= minQuantity`.
- [x] A stock check returns immediately with an ID/job identifier.
- [x] Worker processes jobs independently from the API server.
- [x] Status transitions persist in PostgreSQL.
- [x] Results and alert snapshots are visible through the API/UI.
- [x] Failed jobs show a useful terminal failure state.

## Docker — 20%

- [x] Three separate application Dockerfiles exist.
- [x] Images use appropriate multi-stage builds and non-root runtime users.
- [x] Compose starts frontend, backend, worker, PostgreSQL, and Redis.
- [x] Health checks and restart policies are configured.
- [x] PostgreSQL data survives container recreation.
- [x] A single documented command starts the local stack.

## CI/CD — 25%

- [x] Workflow triggers on push to `main`.
- [x] Dependencies, lint/type checks, tests, and builds run.
- [x] Three images are built and pushed to GHCR.
- [x] Images use immutable commit-SHA tags.
- [x] Failed validation/build cannot deploy.
- [x] Deployment uses the exact images built by the workflow.
- [x] Deployment health check and rollback path are documented.

## Cloud — 20%

- [x] Application deployment automation prepared for AWS or Azure.
- [x] Frontend has a public port mapping (Port 80).
- [x] Frontend-to-backend communication works via dynamic internal proxy.
- [x] Backend and worker can reach PostgreSQL and Redis.
- [x] Database and Redis are not publicly exposed.
- [x] Firewall and runtime environment variables are configured.

## Background processing — 15%

- [x] Frontend can submit a stock check.
- [x] Backend enqueues a Redis/BullMQ job.
- [x] Separate worker processes the job.
- [x] API exposes status/result.
- [x] Frontend displays status/result.
- [x] Failure path is demonstrated safely.

## Security and reliability — 10%

- [x] No secrets are committed or baked into images.
- [x] Runtime secrets are protected on the VM (`.env` 0600).
- [x] PostgreSQL persistence is configured (`postgres_data` named volume).
- [x] Crash/restart and health behaviour are explainable.
- [x] Rollback to previous immutable image tags is documented and tested.
- [x] Container troubleshooting commands are documented.

## Documentation and communication — 10%

- [x] README includes architecture, local setup, environment variables, deployment, and decisions.
- [x] Architecture diagram reflects the actual implementation.
- [x] Walkthrough script is under 180 seconds.
- [x] Candidate can explain Docker, CI/CD, cloud networking, queue flow, secrets, persistence, and rollback.
