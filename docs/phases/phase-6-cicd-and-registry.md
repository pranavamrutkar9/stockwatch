# Phase 6 — GitHub Actions and GHCR

## Read first
`AGENTS.md`, context 09, 10, 12–15.

## Goal
Create a CI/CD workflow that validates code, builds three images once, publishes immutable SHA tags, and deploys only successful builds.

## Tasks
1. Create `.github/workflows/deploy.yml`.
2. Trigger validation on pull requests and push to main; deploy only from main.
3. Install dependencies reproducibly from the lockfile.
4. Run lint/type checks, tests, and builds.
5. Build frontend/backend/worker images with layer caching.
6. Publish images to GHCR with commit SHA tags.
7. Configure GitHub Actions permissions and deployment secrets.
8. Ensure deploy job depends on successful validation and image publishing.
9. Do not add cloud deployment until credentials/VM are configured in Phase 7.

## Acceptance
A failing check blocks image publication/deployment. A successful main push publishes all three SHA-tagged images. The workflow deploys the exact images it built; it does not rebuild them.
