# 10 — CI/CD Pipeline

## Workflow

File: `.github/workflows/deploy.yml`.

Trigger on pushes to `main`. Pull requests may run validation without deployment.

## Required stages

1. Checkout source.
2. Set up the supported Node.js and pnpm versions.
3. Install dependencies using the lockfile (`pnpm install --frozen-lockfile`).
4. Run lint, tests, and production builds.
5. Only if checks pass, build frontend, backend, and worker images.
6. Tag each image with the full commit SHA. A `latest` convenience tag may also be pushed, but deployment must use the immutable SHA tag.
7. Authenticate to GHCR using GitHub-provided token/permissions.
8. Push the three images.
9. Deploy the exact SHA images to the VM over SSH.
10. Apply database migrations in a controlled step, restart services, and run health checks.

## Job dependencies

Use separate jobs or explicit dependencies (`needs:`) so deployment cannot run if validation or image publication fails. A failed build must never deploy.

## Build efficiency

- Use Docker layer caching.
- Avoid building the same image twice in one workflow.
- Build once, push once, and deploy the exact published SHA.
- Keep image tags traceable to the source commit.

## Secrets

Store SSH credentials and any deployment-only secrets in GitHub Actions Secrets. Use least-privilege credentials. Do not print secrets in logs. Application runtime secrets should be stored on the VM in a protected server-side environment file, not in the repository or image.

## Deployment verification

After deployment, check backend health and frontend availability. If the new version fails its health check, trigger the rollback procedure and fail the workflow. Preserve logs needed to diagnose the failure.
