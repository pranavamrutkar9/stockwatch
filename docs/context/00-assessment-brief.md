# 00 — VEGAH Practical Assessment Brief

## Objective

Deliver a small full-stack application, containerize its services, implement CI/CD, and deploy it to AWS or Azure. The application is a vehicle for demonstrating infrastructure and deployment capability; do not overbuild the product.

## Assessment areas and weights

| Area | Weight |
|---|---:|
| Docker and containerization | 20% |
| CI/CD pipeline | 25% |
| Cloud deployment | 20% |
| Redis-backed background processing | 15% |
| Deployment reliability and security | 10% |
| Documentation and communication | 10% |

Docker, CI/CD, and Cloud account for 65% of the assessment.

## Required tasks

### Task 1 — Docker (20%)

- Separate Dockerfiles for Next.js frontend, NestJS backend, and background worker.
- Docker Compose includes frontend, backend, worker, PostgreSQL, and Redis.
- Services communicate over the Compose network.
- Configuration is supplied through environment variables.
- Health checks are provided.
- Use multi-stage builds where appropriate.
- Persist PostgreSQL data using a named volume.
- A single command starts the local application.

### Task 2 — CI/CD (25%)

Use GitHub Actions or Azure DevOps.

- Trigger on pushes to `main`.
- Install dependencies and run appropriate checks.
- Build the three application images.
- Push images to GHCR, ACR, or ECR.
- Deploy a successful build to the cloud environment.
- Use secrets management and traceable image tags (commit SHA).
- Avoid unnecessary image rebuilding.
- A failed build must not deploy.
- Document the pipeline and deployment process.

### Task 3 — Cloud deployment (20%)

Deploy frontend, backend, and worker to AWS or Azure. Provide PostgreSQL and Redis using managed services or appropriately configured infrastructure. Configure networking, environment variables, and permissions. Expose a public application endpoint.

Kubernetes is explicitly not required. Docker Compose or a suitable cloud-native approach is acceptable.

### Task 4 — Background processing (15%)

Demonstrate this workflow:

1. User submits a request through the frontend.
2. NestJS receives the request.
3. Backend adds a job to a Redis-backed queue.
4. A separate worker processes it.
5. Processing status or result is available through an API.
6. Frontend displays the status or result.

BullMQ is acceptable.

### Task 5 — Reliability and documentation (10%)

Explain and demonstrate:

- Application crash handling.
- Secret protection.
- Database persistence.
- Rollback after a failed deployment.
- Investigation of a failing container.
- Application health monitoring.

Provide a README describing architecture, deployment, environment variables, and important decisions.

## Required deliverables

- GitHub repository containing source, Dockerfiles, Compose configuration, and CI/CD workflow.
- Public deployment URL.
- Architecture diagram.
- README with setup and deployment instructions.
- Actual screen-recorded walkthrough under 3 minutes. A slide deck is not a substitute.

## Walkthrough timing

| Time | Demonstration |
|---|---|
| 0:00–0:30 | Architecture and cloud services |
| 0:30–1:00 | Dockerfiles and Compose |
| 1:00–1:40 | CI/CD build and image push |
| 1:40–2:20 | Deployed frontend, backend, and worker |
| 2:20–2:50 | Secrets, persistence, failure handling, and rollback |

The hard limit is less than 180 seconds.

## Constraints and ownership

AI-assisted coding is permitted, but the candidate must understand and explain the implementation. Do not claim a feature or deployment works until it has been tested. Choose cloud resources carefully, enable billing alerts, and clean up resources after the assessment if they are no longer needed.
