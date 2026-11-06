# 04 — Repository Structure

Use a pnpm workspace monorepo. Do not restructure it without a concrete technical reason and explicit approval.

```text
stockwatch/
├── apps/
│   ├── frontend/        # Next.js (src/app, components, lib, types)
│   ├── backend/         # NestJS (health, inventory, stock-checks, queue)
│   └── worker/          # BullMQ worker (src/index.ts, processors, config)
├── packages/
│   └── database/        # Prisma schema, migrations, client export
├── infrastructure/
│   ├── docker/          # frontend.Dockerfile, backend.Dockerfile,
│   │                    # worker.Dockerfile, docker-compose.yml
│   └── deployment/      # deploy.sh, rollback.sh
├── .github/
│   └── workflows/
│       └── deploy.yml
├── docs/
│   ├── context/
│   ├── phases/
│   ├── architecture.md
│   ├── deployment.md
│   └── walkthrough.md
├── .env.example
├── .gitignore
├── package.json
├── pnpm-workspace.yaml
└── README.md
```

## Dockerfile location decision

Dockerfiles live only in `infrastructure/docker/`. Use the repository root as the Docker build context because backend and worker need access to the shared `packages/database` workspace package.

Do not create additional `apps/*/Dockerfile` copies.

## Scaffolding convention

Create only the directories and package manifests required for the current phase. `.gitkeep` may be used for intentionally empty directories. Add dependencies when the relevant app/package is initialized; do not create misleading placeholder dependencies.
