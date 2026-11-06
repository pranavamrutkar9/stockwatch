# StockWatch — Agent Instructions

Read these files before making changes, in this order:

1. `docs/context/00-assessment-brief.md`
2. `docs/context/01-project-overview.md` through `docs/context/15-acceptance-criteria.md`
3. The specific instruction file in `docs/phases/` for the phase requested.

## Non-negotiable rules

- Work only on the requested phase. Do not silently begin later phases.
- Preserve the repository structure in `04-repository-structure.md`.
- Preserve the stack in `05-technology-stack.md`.
- Do not add features outside `02-functional-requirements.md`.
- Do not add API routes outside `07-api-contracts.md` without asking first.
- Do not introduce Kubernetes, authentication, extra queues, another ORM, managed databases, or unrelated infrastructure.
- Keep the application intentionally small. The assessment is primarily about containerization, CI/CD, cloud deployment, and reliable background processing.
- Use TypeScript with strict settings wherever practical.
- Never commit `.env`, credentials, private keys, registry tokens, or cloud secrets.
- Do not invent successful test results. Run checks and report their actual output.
- Do not overwrite working code or restructure files without explaining why.
- Before finishing, list changed files, commands run, test results, known limitations, and the next safe step.

## Phase discipline

The implementation order is Phase 0 through Phase 8. Each phase has its own file under `docs/phases/`. Complete the current phase's acceptance checks before moving forward.

## Important architecture constraints

- The worker is a separate process and container, not part of the NestJS HTTP server.
- Backend is the BullMQ producer; worker is the consumer.
- PostgreSQL is the source of truth for StockCheck status and results.
- Next.js proxies `/api/*` to the backend using an internal service URL.
- PostgreSQL and Redis must not be publicly exposed in production.
- Dockerfiles live only in `infrastructure/docker/` and use the repository root as build context.
