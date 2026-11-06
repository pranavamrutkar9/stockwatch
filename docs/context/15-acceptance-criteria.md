# 15 — Acceptance Criteria and Submission Checklist

## Application

- [ ] Inventory items can be created, listed, and updated.
- [ ] Low-stock status uses exactly `quantity <= minQuantity`.
- [ ] A stock check returns immediately with an ID/job identifier.
- [ ] Worker processes jobs independently from the API server.
- [ ] Status transitions persist in PostgreSQL.
- [ ] Results and alert snapshots are visible through the API/UI.
- [ ] Failed jobs show a useful terminal failure state.

## Docker — 20%

- [ ] Three separate application Dockerfiles exist.
- [ ] Images use appropriate multi-stage builds and non-root runtime users.
- [ ] Compose starts frontend, backend, worker, PostgreSQL, and Redis.
- [ ] Health checks and restart policies are configured.
- [ ] PostgreSQL data survives container recreation.
- [ ] A single documented command starts the local stack.

## CI/CD — 25%

- [ ] Workflow triggers on push to `main`.
- [ ] Dependencies, lint/type checks, tests, and builds run.
- [ ] Three images are built and pushed to GHCR.
- [ ] Images use immutable commit-SHA tags.
- [ ] Failed validation/build cannot deploy.
- [ ] Deployment uses the exact images built by the workflow.
- [ ] Deployment health check and rollback path are documented.

## Cloud — 20%

- [ ] Application is deployed to AWS or Azure.
- [ ] Frontend has a public URL.
- [ ] Frontend-to-backend communication works.
- [ ] Backend and worker can reach PostgreSQL and Redis.
- [ ] Database and Redis are not publicly exposed.
- [ ] Firewall and runtime environment variables are configured.

## Background processing — 15%

- [ ] Frontend can submit a stock check.
- [ ] Backend enqueues a Redis/BullMQ job.
- [ ] Separate worker processes the job.
- [ ] API exposes status/result.
- [ ] Frontend displays status/result.
- [ ] Failure path is demonstrated safely.

## Security and reliability — 10%

- [ ] No secrets are committed or baked into images.
- [ ] Runtime secrets are protected on the VM.
- [ ] PostgreSQL persistence is configured.
- [ ] Crash/restart and health behaviour are explainable.
- [ ] Rollback to previous immutable image tags is documented and tested.
- [ ] Container troubleshooting commands are documented.

## Documentation and communication — 10%

- [ ] README includes architecture, local setup, environment variables, deployment, and decisions.
- [ ] Architecture diagram reflects the actual implementation.
- [ ] Public deployment URL is included.
- [ ] Walkthrough is an actual screen recording under 180 seconds.
- [ ] Candidate can explain Docker, CI/CD, cloud networking, queue flow, secrets, persistence, and rollback.

Do not check an item merely because the code exists. Check it only after verifying it.
