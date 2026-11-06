#!/bin/bash
set -e

# ========================================================
# StockWatch Ubuntu VM Provisioning & Setup Script
# Compatible with AWS EC2 (Ubuntu 22.04 / 24.04 LTS) and Azure Ubuntu VMs
# ========================================================

echo "========================================================"
echo "Starting StockWatch Cloud VM Setup"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "========================================================"

# 1. Update OS packages
echo "[1/6] Updating system packages..."
sudo apt-get update -y
sudo apt-get upgrade -y

# 2. Install prerequisites
echo "[2/6] Installing prerequisites..."
sudo apt-get install -y ca-certificates curl gnupg lsb-release ufw git

# 3. Install Docker Engine & Compose plugin
echo "[3/6] Installing Docker Engine and Docker Compose..."
sudo install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
fi

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add current user to docker group
sudo usermod -aG docker "$USER"
echo "Docker installed successfully: $(docker --version)"

# 4. Configure Firewall (UFW)
echo "[4/6] Configuring UFW firewall rules..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw allow 80/tcp comment 'HTTP Web Application'
sudo ufw allow 443/tcp comment 'HTTPS'
# Ensure PostgreSQL (5432) and Redis (6379) are NEVER opened publicly
sudo ufw delete allow 5432 2>/dev/null || true
sudo ufw delete allow 6379 2>/dev/null || true
sudo ufw --force enable
sudo ufw status verbose

# 5. Setup Project Directory and Environment Configuration
echo "[5/6] Setting up project workspace at ~/stockwatch..."
mkdir -p ~/stockwatch/infrastructure/deployment
mkdir -p ~/stockwatch/infrastructure/docker

# Clone repository if not already cloned
if [ ! -d ~/stockwatch/.git ]; then
  echo "Cloning repository..."
  git clone https://github.com/pranavamrutkar9/stockwatch.git ~/stockwatch_temp
  cp -r ~/stockwatch_temp/* ~/stockwatch/
  cp -r ~/stockwatch_temp/.* ~/stockwatch/ 2>/dev/null || true
  rm -rf ~/stockwatch_temp
fi

# Generate production environment file if not already present
if [ ! -f ~/stockwatch/.env ]; then
  echo "Generating production .env configuration with secure credentials..."
  POSTGRES_PASS=$(openssl rand -hex 16)
  REDIS_PASS=$(openssl rand -hex 16)

  cat <<EOF > ~/stockwatch/.env
NODE_ENV=production
POSTGRES_USER=stockwatch
POSTGRES_PASSWORD=${POSTGRES_PASS}
POSTGRES_DB=stockwatch
DATABASE_URL=postgresql://stockwatch:${POSTGRES_PASS}@postgres:5432/stockwatch?schema=public
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PASS}
WORKER_SIMULATE_FAILURE=false
PORT=4000
FRONTEND_PORT=3000
BACKEND_INTERNAL_URL=http://backend:4000
EOF
  chmod 600 ~/stockwatch/.env
  echo "Protected production .env created (permissions: 0600)."
fi

# Make deployment scripts executable
chmod +x ~/stockwatch/infrastructure/deployment/*.sh

# 6. Verify Docker daemon
echo "[6/6] Verifying Docker daemon..."
sudo systemctl enable docker
sudo systemctl restart docker

echo "========================================================"
echo "StockWatch VM Provisioning Complete!"
echo "You can now execute deployment using:"
echo "  cd ~/stockwatch && bash infrastructure/deployment/deploy.sh <COMMIT_SHA>"
echo "========================================================"
