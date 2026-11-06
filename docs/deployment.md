# StockWatch Deployment & Operations Runbook

## 1. Overview
This runbook describes the automated deployment, configuration, and rollback lifecycle for StockWatch on a cloud Ubuntu virtual machine (AWS EC2 or Azure VM) utilizing Docker Compose and GitHub Container Registry (GHCR).

---

## 2. Infrastructure Specification

- **Target OS**: Ubuntu 22.04 LTS / 24.04 LTS / 26.04 LTS x86_64
- **Recommended VM Size**:
  - AWS: `t3.small` (2 vCPU, 2 GiB RAM) or `t3.medium`
  - Azure: `Standard_B2s` (2 vCPU, 4 GiB RAM)
- **Disk**: 20 GiB gp3 / Standard SSD
- **Network Ingress Rules**:
  - Port 22 (TCP): SSH (restricted to deployment/admin IP)
  - Port 80 (TCP): HTTP (Public)
  - Port 443 (TCP): HTTPS (Public)
  - **Ports 5432 and 6379**: BLOCKED from external internet ingress.

---

## 3. Initial Cloud VM Provisioning

Run the provided automated bootstrap script on the newly provisioned Ubuntu VM:

```bash
# Connect to the cloud VM
ssh -i ~/.ssh/stockwatch_vm_key.pem ubuntu@<VM_PUBLIC_IP>

# Download and execute setup script
curl -fsSL https://raw.githubusercontent.com/pranavamrutkar9/stockwatch/main/infrastructure/deployment/setup-vm.sh -o setup-vm.sh
bash setup-vm.sh
```

The script automatically:
1. Installs Docker Engine, Docker Buildx, and Docker Compose plugin.
2. Creates non-root docker group permissions.
3. Sets up UFW firewall (allows 22, 80, 443; rejects 5432, 6379).
4. Creates `~/stockwatch` directory and generates a protected `~/.env` with random hex passwords.

---

## 4. GitHub Actions CI/CD Secrets Setup

In your GitHub repository (`Settings -> Secrets and variables -> Actions`), configure the following repository secrets:

| Secret Name | Value Description |
|---|---|
| `VM_HOST` | Public IP or DNS hostname of your cloud Ubuntu VM |
| `VM_USER` | SSH user account (typically `ubuntu`) |
| `VM_SSH_KEY` | Private SSH key matching the public key installed on the VM |

*Note: The built-in `${{ secrets.GITHUB_TOKEN }}` automatically authenticates image pushes and pulls with GHCR.*

---

## 5. Deployment Procedure (`deploy.sh`)

Deployments run automatically via GitHub Actions on every push to `main`. To invoke deployment manually on the VM for a specific commit SHA:

```bash
cd ~/stockwatch
bash infrastructure/deployment/deploy.sh <COMMIT_SHA>
```

### Deployment Flow:
1. Loads protected server-side `.env` configuration.
2. Backs up the current active image SHA into `.previous_tag`.
3. Pulls immutable SHA images:
   - `ghcr.io/pranavamrutkar9/stockwatch-backend:<SHA>`
   - `ghcr.io/pranavamrutkar9/stockwatch-worker:<SHA>`
   - `ghcr.io/pranavamrutkar9/stockwatch-frontend:<SHA>`
4. Starts/verifies healthy PostgreSQL and Redis containers.
5. Applies database schema migrations via Prisma.
6. Launches updated backend, worker, and frontend containers.
7. Polls `/api/health` probe for up to 60 seconds.
8. If the health check fails, **automatically triggers rollback** and halts with exit code 1.

---

## 6. Automated Rollback Procedure (`rollback.sh`)

If a deployment fails health checks or a regression is detected in production, rollback can be executed instantly:

```bash
cd ~/stockwatch
bash infrastructure/deployment/rollback.sh
```

### Rollback Flow:
1. Reads the previously verified commit SHA tag from `.previous_tag`.
2. Pulls and relaunches the previous containers from GHCR.
3. Verifies that the restored stack passes health checks.
4. Updates `.current_tag` to the restored tag.

---

## 7. Operational Troubleshooting & Diagnostics

### View Service Status
```bash
docker compose -f infrastructure/docker/docker-compose.prod.yml ps
```

### Inspect Container Logs
```bash
# Stream backend logs
docker logs -f stockwatch-backend

# Stream worker logs
docker logs -f stockwatch-worker

# Stream frontend logs
docker logs -f stockwatch-frontend
```

### Inspect PostgreSQL Database Directly
```bash
docker exec -it stockwatch-postgres psql -U stockwatch -d stockwatch -c "SELECT COUNT(*) FROM \"InventoryItem\";"
```

### Inspect Redis Queue Directly
```bash
docker exec -it stockwatch-redis redis-cli ping
docker exec -it stockwatch-redis redis-cli keys "bull:stock-check:*"
```
