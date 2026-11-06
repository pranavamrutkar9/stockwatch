# 05 — Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| Frontend | Next.js + TypeScript | Web UI |
| UI styling | Tailwind CSS | Minimal styling |
| Backend | NestJS + TypeScript | REST API |
| Database | PostgreSQL | Persistent application data |
| ORM | Prisma | Database access and migrations |
| Queue | Redis + BullMQ | Asynchronous job queue |
| Worker | Node.js + TypeScript | Independent job processor |
| Containers | Docker, Docker Compose | Local and VM deployment |
| CI/CD | GitHub Actions | Build, publish, deploy |
| Registry | GitHub Container Registry (GHCR) | Store versioned images |
| Cloud | AWS or Azure Ubuntu VM | Public deployment |
| Package manager | pnpm workspaces | Monorepo dependency management |

Do not introduce extra queues, ORMs, UI libraries, state managers, Kubernetes, or managed cloud databases without an explicit requirement. If a required platform constraint makes a change necessary, document the reason before implementing it.
