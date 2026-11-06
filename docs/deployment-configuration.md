# StockWatch — Production Deployment Configuration Handover

This document specifies every production environment variable and deployment secret required to deploy StockWatch, where each must be configured, and whether manual generation is required.

---

## 1. Runtime Environment Variables (Configured on Cloud VM)

These variables live in the protected server-side environment file: `~/stockwatch/.env` on the Ubuntu VM with permissions `0600`. They are automatically populated with random secure credentials if you run `infrastructure/deployment/setup-vm.sh`.

| Variable Name | Purpose | Production Value / Format | Generation Required? |
|---|---|---|:---:|
| `NODE_ENV` | Sets production runtime optimization mode for Node.js | `production` | **No** (static) |
| `PORT` | HTTP port on which the NestJS backend listens internally | `4000` | **No** (static) |
| `FRONTEND_PORT` | Host port on which Next.js receives public web traffic | `80` (or `3000`) | **No** (static) |
| `POSTGRES_USER` | PostgreSQL superuser username | `stockwatch` | **No** (static) |
| `POSTGRES_PASSWORD` | PostgreSQL database authentication password | 32-character hexadecimal string | **Auto-generated** by `setup-vm.sh` (or generated via `openssl rand -hex 16`) |
| `POSTGRES_DB` | PostgreSQL primary database name | `stockwatch` | **No** (static) |
| `DATABASE_URL` | Prisma PostgreSQL connection URI | `postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}?schema=public` | **Auto-generated** by `setup-vm.sh` |
| `REDIS_HOST` | Hostname of Redis inside Docker bridge network | `redis` | **No** (Docker DNS) |
| `REDIS_PORT` | Port for Redis broker | `6379` | **No** (standard) |
| `REDIS_PASSWORD` | Authentication password for Redis server | 32-character hexadecimal string | **Auto-generated** by `setup-vm.sh` (or generated via `openssl rand -hex 16`) |
| `BACKEND_INTERNAL_URL` | Address used by Next.js Route Handler proxy to contact NestJS API | `http://backend:4000` | **No** (internal network) |
| `WORKER_SIMULATE_FAILURE`| Controlled flag to simulate processing failures | `false` | **No** (defaults to `false`) |
| `IMAGE_TAG` | Immutable commit SHA tag to pull from GHCR | Injected by `deploy.sh` (e.g. `f52b89908b...`) | **No** (managed by deployment script) |
| `REGISTRY` | Container registry host | `ghcr.io` | **No** (static) |
| `GITHUB_REPOSITORY_OWNER`| GitHub account namespace hosting the container images | `pranavamrutkar9` | **No** (static) |

---

## 2. CI/CD Secrets & Variables (Configured in GitHub Settings)

These credentials allow GitHub Actions to securely connect to your VM over SSH and trigger deployment. Configure them at:
`https://github.com/pranavamrutkar9/stockwatch/settings/secrets/actions`

### Repository Secrets

| Secret Name | Purpose | Where to Obtain Value | Generation Required? |
|---|---|---|:---:|
| `VM_HOST` | Public IPv4 address or public DNS name of the Ubuntu cloud VM | Cloud console (AWS EC2 / Azure portal) after instance launch | **YES** (User copies VM public IP) |
| `VM_USER` | SSH user account on the VM | Default for Ubuntu AMI is `ubuntu` | **No** (enter `ubuntu`) |
| `VM_SSH_KEY` | Private SSH key (`.pem` format) matching the public key deployed on the VM | Generated during VM creation (e.g., `stockwatch-key.pem`) | **YES** (User pastes private key content) |

### Repository Variables (`Settings -> Secrets and variables -> Actions -> Variables`)

| Variable Name | Purpose | Recommended Value | Generation Required? |
|---|---|---|:---:|
| `SSH_DEPLOY_ENABLED` | Feature flag to activate automated SSH deployment to the VM | `true` | **YES** (Set to `true` when VM is ready) |

---

## 3. Network & Firewall Port Allocation

| Port | Protocol | Scope | Exposure | Purpose |
|---|---|---|---|---|
| `22` | TCP | Host / VM | Restricted to Admin IP | SSH access for administration and GitHub Actions deployment |
| `80` | TCP | Host / VM | **Public** (`0.0.0.0/0`) | HTTP access to Next.js Frontend |
| `443`| TCP | Host / VM | **Public** (`0.0.0.0/0`) | HTTPS access (when TLS reverse proxy is enabled) |
| `4000`| TCP | Internal Docker | **Internal only** | NestJS HTTP API server |
| `5432`| TCP | Internal Docker | **BLOCKED / Internal only** | PostgreSQL database (never open to internet) |
| `6379`| TCP | Internal Docker | **BLOCKED / Internal only** | Redis queue broker (never open to internet) |

---

## 4. Summary of Manual User Actions Needed Before Deployment

When you are ready to execute Phase 7 cloud deployment:
1. **Launch 1 Ubuntu VM** (AWS EC2 `t3.small` / `t3.medium` or Azure `Standard_B2s`).
2. **Execute Setup Script** on the VM via SSH:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/pranavamrutkar9/stockwatch/main/infrastructure/deployment/setup-vm.sh | bash
   ```
3. **Add GitHub Secrets**: In GitHub repository settings, add `VM_HOST`, `VM_SSH_KEY`, and set variable `SSH_DEPLOY_ENABLED=true`.

