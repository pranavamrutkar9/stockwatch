# 11 — Cloud Deployment

## Target

Deploy to one Ubuntu VM on AWS EC2 or Azure VM. Select the provider based on account eligibility, available credits, region, and cost. Do not provision both.

## VM setup

- Install Docker Engine and the Docker Compose plugin using official instructions.
- Create a non-root deployment user with the minimum required Docker/deployment permissions.
- Use SSH key authentication; disable password-based SSH where practical.
- Configure firewall/security-group ingress for 80/443 and restricted SSH only.
- Do not expose PostgreSQL or Redis publicly.
- Configure disk space and memory deliberately. A small VM may require swap, but swap is not a substitute for sufficient memory.

## Runtime

- Pull images from GHCR by commit SHA.
- Run the Compose production configuration.
- Persist PostgreSQL in a named volume.
- Store runtime secrets in a server-side `.env` file with restrictive permissions.
- Use a reverse proxy such as Nginx/Caddy if needed for public HTTP/HTTPS routing and TLS.
- The public endpoint should route to the frontend. The frontend proxies `/api/*` to the backend over the private Docker network.

## Connectivity

- Frontend → backend via internal Compose DNS.
- Backend → PostgreSQL and Redis via internal Compose DNS.
- Worker → PostgreSQL and Redis via internal Compose DNS.
- Browser must not call Docker-only service names.

## Cost and cleanup

Cloud VMs, disks, public IPs, bandwidth, and snapshots may incur charges. Enable billing alerts before provisioning. Stop or delete resources after the assessment if they are no longer needed. Never assume a free tier covers every resource or region.
