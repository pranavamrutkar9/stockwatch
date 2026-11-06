# StockWatch Assessment Walkthrough Script (< 180 Seconds)

**Target Video Duration**: 2 minutes 45 seconds (~165 seconds)  
**Strict Upper Limit**: 180 seconds

---

## Timed Video Script

### [0:00 – 0:30] Architecture & Cloud Security Boundaries
- **Visual**: Show `docs/architecture.md` diagram and terminal running on the Ubuntu VM.
- **Narrator**:
  > *"Welcome to the StockWatch demonstration. StockWatch is a distributed inventory monitoring system structured around five isolated services in a Docker bridge network.*
  > *Frontend runs Next.js 15, backend runs NestJS 10, background jobs are queued in Redis 7 with BullMQ, persistent data is housed in PostgreSQL 16, and our worker runs as an independent Node.js process.*
  > *Notice that only port 80 is exposed publicly. PostgreSQL and Redis have no host port bindings and are inaccessible from the internet, protecting data integrity."*

### [0:30 – 1:00] Docker Containerization & Compose Configuration
- **Visual**: Highlight `infrastructure/docker/` in the code editor (`backend.Dockerfile`, `worker.Dockerfile`, `frontend.Dockerfile`, `docker-compose.prod.yml`).
- **Narrator**:
  > *"Each application image uses multi-stage builds. In stage one, pnpm installs dependencies and compiles TypeScript. In stage two, lean runtime images are constructed and run strictly as non-root user `node` for defense in depth.*
  > *Our Compose configuration features health checks for all services, restart policies, and named volumes for database persistence across reboots."*

### [1:00 – 1:35] Automated CI/CD & GHCR Publication
- **Visual**: Show GitHub Actions workflow tab (`.github/workflows/deploy.yml`) and GitHub Container Registry packages.
- **Narrator**:
  > *"Every push to main triggers our GitHub Actions pipeline.*
  > *First, it validates type checks and runs all unit tests.*
  > *If and only if checks pass, it builds Docker images and pushes immutable SHA-tagged images to GHCR.*
  > *The CD job then SSHs into the VM, invokes `deploy.sh`, applies Prisma database migrations, updates the stack, and verifies the `/api/health` probe."*

### [1:35 – 2:15] Live Application & Background Queue Flow
- **Visual**: Open web browser at the application URL. Create a low-stock item and click "Run Stock Check". Show terminal logs streaming from `stockwatch-worker`.
- **Narrator**:
  > *"Here is the live dashboard. Let's create an item with quantity 3 and minimum threshold 10.*
  > *When we click 'Run Stock Check', the backend returns immediately with a jobId.*
  > *In the terminal, you can see the standalone worker consuming the BullMQ job, calculating low-stock items, and idempotently upserting alert records.*
  > *The frontend polls the check status and renders the completed check and alert badge in real time."*

### [2:15 – 2:45] Resilience, Secrets & Automated Rollback
- **Visual**: Show `.previous_tag` file on the VM and execute `rollback.sh` or show failure handling.
- **Narrator**:
  > *"For security, all database and Redis credentials live in a protected `0600` `.env` on the host, never in Git.*
  > *In the event of an unhealthy deployment, `rollback.sh` immediately pulls the previously recorded immutable image SHA from `.previous_tag` and restores the known-good stack with zero manual intervention.*
  > *StockWatch fulfills all containerization, background processing, CI/CD, and reliability requirements."*

---

## Submission Checklist Verification
- [x] Walkthrough is an actual live recording, not slides.
- [x] Application URL and container logs are visible.
- [x] No sensitive secrets or passwords appear on screen.
- [x] Video length is strictly under 180 seconds.
