# StockWatch — Corrected Documentation Bundle

Start with `AGENTS.md`. The authoritative context is in `docs/context/`, and phase-specific agent instructions are in `docs/phases/`.

## Context documents

00 assessment brief  
01 project overview  
02 functional requirements  
03 system architecture  
04 repository structure  
05 technology stack  
06 database design  
07 API contracts  
08 background processing  
09 Docker and containerization  
10 CI/CD pipeline  
11 cloud deployment  
12 security and reliability  
13 testing strategy  
14 coding guidelines  
15 acceptance criteria  

## Implementation phases

Phase 0 through Phase 8, in strict order. See `docs/phases/`.

## Important reconciliations

- The previous Phase 9 was removed. README, architecture diagram, deployment guide, walkthrough, reliability, rollback, and final submission are now combined into Phase 8.
- The old combined Docker/deployment document was split into focused Docker, CI/CD, Cloud, and Security/Reliability documents.
- Dockerfiles have one authoritative location: `infrastructure/docker/`, with repository root as build context.
- PostgreSQL is the source of truth for StockCheck status. Worker retries must be idempotent to prevent duplicate alerts.
- The API contract now defines request/response expectations and common HTTP errors without adding product scope.
- Deliverable docs are useful templates with TODOs for facts that cannot be known before deployment.
