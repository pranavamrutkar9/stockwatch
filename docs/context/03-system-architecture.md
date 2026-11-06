# 03 — System Architecture

## Services

The Docker Compose deployment contains five services:

1. `frontend` — Next.js web application.
2. `backend` — NestJS REST API and BullMQ job producer.
3. `worker` — standalone BullMQ consumer with its own process and image.
4. `postgres` — PostgreSQL database.
5. `redis` — Redis queue backend.

## Logical flow

```text
Browser
  |
  v
Next.js frontend
  |  /api/* rewrite over internal Docker network
  v
NestJS backend ----------------------> PostgreSQL
  |
  v
Redis (BullMQ queue)
  |
  v
Standalone worker ------------------> PostgreSQL
```

## Communication rules

- The browser talks only to the frontend's public origin.
- Next.js rewrites `/api/*` to `http://backend:4000` on the internal network. The browser does not need to know the backend service address.
- Backend and worker independently connect to PostgreSQL and Redis using Compose service names (`postgres`, `redis`).
- The worker is not part of the NestJS HTTP server.
- PostgreSQL and Redis must not publish host ports in production.
- Local development may publish database/Redis ports if useful, but production configuration must not.

## Cloud target

Use one Ubuntu VM on AWS EC2 or Azure VM, based on account eligibility and cost. Run Docker Compose on the VM. The frontend is the public entry point, optionally behind Nginx or Caddy for TLS and reverse proxying.

Firewall: expose only 80/443 and SSH. Restrict SSH source addresses where practical and use key-based authentication.

## Shared database code

`packages/database` contains the Prisma schema, migrations, and shared Prisma client export used by both backend and worker.
