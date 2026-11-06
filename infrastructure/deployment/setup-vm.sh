#!/bin/bash
set -e

# ========================================================
# StockWatch Ubuntu VM Provisioning & Setup Script
# Compatible with Ubuntu 22.04 / 24.04 / 26.04 LTS (AWS EC2 / Azure)
# ========================================================

echo "========================================================"
echo "Starting StockWatch Cloud VM Setup"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "========================================================"

# Target workspace directory for StockWatch
TARGET_DIR="${PROJECT_DIR:-$HOME/stockwatch}"
REPO_URL="https://github.com/pranavamrutkar9/stockwatch.git"

# 1. Update OS packages
echo "[1/6] Updating system packages..."
sudo apt-get update -y
sudo apt-get upgrade -y

# 2. Install prerequisites
echo "[2/6] Installing prerequisites..."
sudo apt-get install -y ca-certificates curl gnupg lsb-release ufw git

# 3. Detect OS & Install Docker Engine & Compose plugin
echo "[3/6] Detecting OS and configuring Docker Engine..."

# Detect OS codename
DISTRO_ID="ubuntu"
DISTRO_CODENAME=""

if [ -f /etc/os-release ]; then
  # Source os-release safely
  . /etc/os-release
  DISTRO_ID="${ID:-ubuntu}"
  DISTRO_CODENAME="${VERSION_CODENAME:-}"
  if [ -z "$DISTRO_CODENAME" ] && [ -n "${UBUNTU_CODENAME:-}" ]; then
    DISTRO_CODENAME="$UBUNTU_CODENAME"
  fi
fi

if [ -z "$DISTRO_CODENAME" ]; then
  DISTRO_CODENAME="$(lsb_release -cs 2>/dev/null || echo "noble")"
fi

echo "Detected OS distribution: ${DISTRO_ID} (${DISTRO_CODENAME})"

# Check if Docker is already installed
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "Docker Engine and Docker Compose are already installed:"
  sudo docker --version
  sudo docker compose version
else
  # Probe official Docker repository for the detected codename
  DOCKER_BASE_URL="https://download.docker.com/linux/ubuntu"
  TARGET_CODENAME=""
  USE_OFFICIAL_REPO=false

  echo "Verifying Docker CE official repository support for '${DISTRO_CODENAME}'..."
  if curl -fsSL -I "${DOCKER_BASE_URL}/dists/${DISTRO_CODENAME}/Release" >/dev/null 2>&1; then
    echo "Confirmed: Official Docker repository publishes verified packages for '${DISTRO_CODENAME}'."
    TARGET_CODENAME="${DISTRO_CODENAME}"
    USE_OFFICIAL_REPO=true
  elif curl -fsSL -I "${DOCKER_BASE_URL}/dists/noble/Release" >/dev/null 2>&1; then
    echo "Notice: '${DISTRO_CODENAME}' Release metadata was not found on Docker CE repository."
    echo "Falling back to verified upstream LTS codename 'noble' (Ubuntu 24.04 LTS)."
    TARGET_CODENAME="noble"
    USE_OFFICIAL_REPO=true
  else
    echo "Notice: Upstream Docker CE repository unreachable. Using Ubuntu native packages."
    USE_OFFICIAL_REPO=false
  fi

  if [ "$USE_OFFICIAL_REPO" = "true" ]; then
    echo "Installing Docker CE via official Docker repository (${TARGET_CODENAME})..."
    sudo install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      sudo chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      ${TARGET_CODENAME} stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    echo "Installing Docker via Ubuntu native distribution packages (docker.io and docker-compose-v2)..."
    sudo apt-get update -y
    sudo apt-get install -y docker.io docker-compose-v2
  fi
fi

# Manage docker group membership
echo "Checking Docker user permissions..."
if ! groups "$USER" 2>/dev/null | grep -q '\bdocker\b'; then
  sudo usermod -aG docker "$USER"
  echo "[NOTE] User '$USER' has been added to the 'docker' group."
  echo "[IMPORTANT] Group membership takes effect on new login sessions."
  echo "  To use docker without sudo in your current session, run: newgrp docker"
  echo "  Or disconnect and reconnect your SSH session."
else
  echo "User '$USER' is already a member of the 'docker' group."
fi

# 4. Configure Firewall (UFW)
echo "[4/6] Configuring UFW firewall rules..."
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Ensure SSH remains accessible (both explicit port 22 and OpenSSH application profile)
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw allow OpenSSH comment 'OpenSSH service' 2>/dev/null || true

# Allow public web ingress
sudo ufw allow 80/tcp comment 'HTTP Web Application'
sudo ufw allow 443/tcp comment 'HTTPS'

# Ensure PostgreSQL (5432) and Redis (6379) are NEVER opened publicly
sudo ufw delete allow 5432 2>/dev/null || true
sudo ufw delete allow 6379 2>/dev/null || true
sudo ufw deny 5432/tcp comment 'Explicitly block Postgres public ingress' 2>/dev/null || true
sudo ufw deny 6379/tcp comment 'Explicitly block Redis public ingress' 2>/dev/null || true

# Enable firewall safely
sudo ufw --force enable
sudo ufw status verbose

# 5. Setup Project Workspace and Environment Configuration
echo "[5/6] Setting up project workspace at ${TARGET_DIR}..."

# Clone repository directly or pull latest changes
if [ ! -d "${TARGET_DIR}/.git" ]; then
  echo "Cloning repository directly into ${TARGET_DIR}..."
  mkdir -p "$(dirname "${TARGET_DIR}")"
  git clone "${REPO_URL}" "${TARGET_DIR}"
else
  echo "Repository already exists at ${TARGET_DIR}. Updating latest changes from main..."
  cd "${TARGET_DIR}"
  git fetch origin main
  git checkout main
  git pull origin main
fi

# Generate production environment file if not already present
if [ ! -f "${TARGET_DIR}/.env" ]; then
  echo "Generating production .env configuration with secure credentials..."
  POSTGRES_PASS=$(openssl rand -hex 16)
  REDIS_PASS=$(openssl rand -hex 16)

  cat <<EOF > "${TARGET_DIR}/.env"
NODE_ENV=production
POSTGRES_USER=stockwatch
POSTGRES_PASSWORD=${POSTGRES_PASS}
POSTGRES_DB=stockwatch
DATABASE_URL=postgresql://stockwatch:${POSTGRES_PASS}@postgres:5432/stockwatch?schema=public
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PASS}
WORKER_CONCURRENCY=5
WORKER_SIMULATE_FAILURE=false
PORT=4000
FRONTEND_PORT=80
BACKEND_INTERNAL_URL=http://backend:4000
EOF

  chmod 0600 "${TARGET_DIR}/.env"
  echo "Protected production .env created (permissions: 0600)."
else
  echo "Existing .env file detected at ${TARGET_DIR}/.env; preserving existing credentials."
  chmod 0600 "${TARGET_DIR}/.env"
fi

# Ensure .env is never tracked by git
if [ -d "${TARGET_DIR}/.git" ]; then
  if git -C "${TARGET_DIR}" check-ignore -q .env; then
    echo "Verified: .env is excluded by .gitignore."
  else
    echo "Warning: .env was not matched by .gitignore. Adding exclusion..."
    echo ".env" >> "${TARGET_DIR}/.gitignore"
  fi
fi

# Make deployment and rollback scripts executable
chmod +x "${TARGET_DIR}/infrastructure/deployment/"*.sh

# 6. Verify Docker daemon
echo "[6/6] Verifying Docker daemon service..."
sudo systemctl enable docker
sudo systemctl restart docker

echo "Verifying Docker service status..."
sudo docker --version
sudo docker compose version

echo "========================================================"
echo "StockWatch VM Provisioning Complete!"
echo ""
echo "IMPORTANT NEXT STEPS:"
echo "1. To apply your docker group membership immediately without logging out, run:"
echo "     newgrp docker"
echo "   (Or log out of SSH and log back in)."
echo "2. You can then run manual deployment with:"
echo "     cd ${TARGET_DIR} && bash infrastructure/deployment/deploy.sh <COMMIT_SHA>"
echo "3. Or enable automated CI/CD deployment via GitHub Actions by setting:"
echo "     Repository Secret:   VM_HOST       (your VM public IP)"
echo "     Repository Secret:   VM_SSH_KEY    (your private SSH key)"
echo "     Repository Variable: SSH_DEPLOY_ENABLED=true"
echo "========================================================"
