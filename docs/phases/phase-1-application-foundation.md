# Phase 1 — Application Foundation

## Read first
`AGENTS.md`, context 01–05, 07, and 14.

## Goal
Initialize the minimal Next.js frontend, NestJS backend, and standalone worker entry point. No database or queue workflow yet.

## Tasks
1. Initialize Next.js + TypeScript + Tailwind in `apps/frontend`.
2. Initialize NestJS + TypeScript in `apps/backend`.
3. Create the standalone TypeScript worker package in `apps/worker` with a clear `src/index.ts` entry point; it may initially log startup and handle SIGTERM.
4. Add a minimal dashboard shell and navigation for Dashboard, Inventory, and Stock Checks. Do not implement full CRUD yet.
5. Add backend `GET /api/health` as a basic process health endpoint; dependency checks are added when integrations exist.
6. Configure frontend rewrite/proxy for `/api/*` to the backend service URL, using environment configuration that works in local development and Compose.
7. Ensure all apps build and run locally.

## Do not
No Prisma, Redis, BullMQ, Docker, cloud, auth, or extra product features.

## Acceptance
- Frontend starts and renders.
- Backend starts and responds to `/api/health`.
- Worker starts independently and exits gracefully on SIGTERM.
- Workspace scripts and builds work.

## Report
Show exact commands and outputs. Do not claim a service works unless it was run.
