# StockWatch Architecture

> Update this document after implementation so it describes the deployed system, not just the plan.

## Runtime diagram

```text
Browser -> Frontend (Next.js) -> Backend (NestJS) -> PostgreSQL
                                      |
                                      v
                                Redis / BullMQ
                                      |
                                      v
                               Worker -> PostgreSQL
```

## Services

| Service | Responsibility | Publicly exposed? |
|---|---|---|
| Frontend | Web UI and `/api/*` proxy | Yes |
| Backend | REST API and queue producer | No direct public exposure required |
| Worker | Background job consumer | No |
| PostgreSQL | Persistent application data | No |
| Redis | BullMQ queue | No |

## Actual deployment details

- Cloud provider/region: TODO after deployment
- VM size: TODO after deployment
- Public URL: TODO after deployment
- Image tag/deployment commit: TODO after deployment
- Reverse proxy/TLS: TODO after implementation
