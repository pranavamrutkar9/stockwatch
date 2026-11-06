# 14 — Coding Guidelines and Implementation Boundaries

## Principles

- Minimal application, complete infrastructure.
- Readable over clever. The owner must be able to explain every file.
- TypeScript with strict settings.
- Configuration through environment variables; document names in `.env.example`.
- Never hardcode credentials or commit `.env`.
- No dead code, speculative abstractions, or unnecessary packages.

## Boundaries for coding agents

- Do not add features beyond `02-functional-requirements.md`.
- Do not add endpoints beyond `07-api-contracts.md`.
- Do not change the repository layout in `04-repository-structure.md`.
- Do not add technologies outside `05-technology-stack.md` without approval.
- Work only on the phase requested.
- Read `AGENTS.md` and the relevant phase instruction before coding.

## Implementation phases

| Phase | Deliverable |
|---|---|
| 0 | Repository scaffold and workspace configuration |
| 1 | Minimal frontend, backend, and worker foundations |
| 2 | Prisma schema, migrations, and database-backed API |
| 3 | Redis + BullMQ asynchronous workflow |
| 4 | Dockerfiles and Docker Compose |
| 5 | Local integration and failure testing |
| 6 | GitHub Actions + GHCR |
| 7 | Cloud VM deployment |
| 8 | Reliability, rollback, documentation, and submission |

Do not start Docker until the applications work locally. Do not start cloud deployment until local Compose integration is working.

## Conventions

- Files: kebab-case.
- Classes: PascalCase.
- Variables/functions: camelCase.
- NestJS: one module per domain (health, inventory, stock-checks, queue); validate DTOs with `class-validator`.
- Logging: structured, useful output to stdout so `docker logs` can diagnose issues.
- Commits: small, one concern per commit.
- Tests: meaningful coverage of status rule, API enqueue path, worker processor, and critical integration.

## Definition of done

See `15-acceptance-criteria.md`. A phase is complete only when its acceptance checks have been run and results are reported.
