# OneShotMatrix Deployment Guide with RabbitMQ Fix

This guide covers deploying OneShotMatrix (Revolt + Matrix) using the improved installer with automatic RabbitMQ credential configuration.

## Quick Start

### Fresh Installation

```bash
# Download the installer
curl -O https://raw.githubusercontent.com/jacksonm36/install-scripts/cursor/rabbitmq-connection-credentials-0f84/oneshotmatrix-install.sh
chmod +x oneshotmatrix-install.sh

# Run the installer (will apply RabbitMQ fixes automatically)
sudo ./oneshotmatrix-install.sh
```

The installer now includes:
- ✅ Automatic RabbitMQ credential configuration
- ✅ Safe SSH port detection
- ✅ Improved error handling
- ✅ No curl dependency in containers

### Fix Existing Deployment

If you already deployed OneShotMatrix and are seeing RabbitMQ errors:

```bash
# Download the post-setup fix script
curl -O https://raw.githubusercontent.com/jacksonm36/install-scripts/cursor/rabbitmq-connection-credentials-0f84/oneshotmatrix-rabbitmq-fix.sh
chmod +x oneshotmatrix-rabbitmq-fix.sh

# Run the fix (default install dir: /opt/matrix-discord-killer)
sudo ./oneshotmatrix-rabbitmq-fix.sh
```

Or specify a custom installation directory:

```bash
sudo ./oneshotmatrix-rabbitmq-fix.sh /custom/path/to/installation
```

## Problem Symptoms

If you see these errors in your logs:

```bash
cd /opt/matrix-discord-killer
docker compose logs api pushd
```

### Error Indicators

```
PLAIN login refused: user 'rabbituser' - invalid credentials
Connection reset by peer (os error 104)
Failed to connect to RabbitMQ: NetworkError
```

### Service Status

```bash
docker ps
```

Services showing "Restarting" instead of "Up":
- `matrix-discord-killer-api-1`
- `matrix-discord-killer-pushd-1`

## Deployment Options

### Option 1: Default Installation

```bash
sudo ./oneshotmatrix-install.sh
```

Installs to: `/opt/matrix-discord-killer`  
Source: `https://github.com/loponai/oneshotmatrix.git`  
Branch: `main`

### Option 2: Custom Installation Directory

```bash
sudo ./oneshotmatrix-install.sh --install-dir /custom/path
```

### Option 3: Different Repository/Branch

```bash
sudo ./oneshotmatrix-install.sh \
  --repo-url https://github.com/your-fork/oneshotmatrix.git \
  --repo-ref develop
```

### Option 4: Clone Only (No Setup)

```bash
sudo ./oneshotmatrix-install.sh --skip-setup
```

This clones the repository and applies hotfixes but doesn't run the interactive setup.

### Option 5: Force Re-clone

```bash
sudo ./oneshotmatrix-install.sh --force-reclone
```

Removes existing installation and starts fresh.

## What Gets Fixed

### Automatic Hotfixes Applied

The installer automatically patches the upstream `setup.sh` with these fixes:

1. **Safe SSH Port Detection**
   - Prevents script failures when SSH_CONNECTION is unavailable
   - Safer under `set -e` mode

2. **dnf-plugins-core Installation**
   - Installs required package before using `dnf config-manager`
   - Fixes RHEL/Rocky/Fedora deployments

3. **Safe .env Secret Reuse**
   - Prevents script failure if .env keys are missing
   - Preserves Matrix secrets on updates (Postgres, Synapse, TURN)
   - Preserves Revolt secrets on updates (Mongo, RabbitMQ, MinIO, Redis, VAPID)

4. **Matrix Readiness Probe**
   - Uses Python instead of curl for health checks
   - Removes curl container dependency

5. **Revolt Readiness Probe**
   - Uses docker inspect instead of curl
   - More reliable container status checking

6. **RabbitMQ Credential Configuration** (NEW)
   - Automatically configures RabbitMQ user after deployment
   - Uses credentials from .env file
   - Grants proper permissions

## Post-Deployment Verification

### Check All Services

```bash
cd /opt/matrix-discord-killer  # or your install dir
docker compose ps
```

Expected output - all services should show "Up":
```
NAME                              STATUS
matrix-discord-killer-api-1       Up
matrix-discord-killer-autumn-1    Up
matrix-discord-killer-caddy-1     Up
matrix-discord-killer-crond-1     Up
matrix-discord-killer-database-1  Up (healthy)
matrix-discord-killer-events-1    Up
matrix-discord-killer-gifbox-1    Up
matrix-discord-killer-january-1   Up
matrix-discord-killer-minio-1     Up
matrix-discord-killer-pushd-1     Up
matrix-discord-killer-rabbit-1    Up (healthy)
matrix-discord-killer-redis-1     Up
matrix-discord-killer-web-1       Up
```

### Check RabbitMQ Credentials

```bash
cd /opt/matrix-discord-killer
docker compose exec rabbit rabbitmqctl list_users
```

Should show:
```
Listing users ...
user         tags
rabbituser   [administrator]
guest        [administrator]
```

### Check for Errors

```bash
cd /opt/matrix-discord-killer
docker compose logs --tail=50 api pushd | grep -i error
```

Should return no RabbitMQ authentication errors.

### Monitor Logs

```bash
cd /opt/matrix-discord-killer
docker compose logs -f api pushd
```

Press Ctrl+C to exit.

## Troubleshooting

### Services Keep Restarting

```bash
# Check what's failing
cd /opt/matrix-discord-killer
docker compose ps

# View logs
docker compose logs api pushd rabbit

# Run the fix script
curl -O https://raw.githubusercontent.com/jacksonm36/install-scripts/cursor/rabbitmq-connection-credentials-0f84/oneshotmatrix-rabbitmq-fix.sh
chmod +x oneshotmatrix-rabbitmq-fix.sh
sudo ./oneshotmatrix-rabbitmq-fix.sh
```

### RabbitMQ User Doesn't Exist

```bash
cd /opt/matrix-discord-killer

# Create user manually
docker compose exec rabbit rabbitmqctl add_user rabbituser rabbitpass
docker compose exec rabbit rabbitmqctl set_user_tags rabbituser administrator
docker compose exec rabbit rabbitmqctl set_permissions -p / rabbituser ".*" ".*" ".*"

# Restart services
docker compose restart api pushd events
```

### Wrong RabbitMQ Password

```bash
cd /opt/matrix-discord-killer

# Check .env file
cat .env | grep RABBIT

# If credentials are different, run the fix script
sudo ./oneshotmatrix-rabbitmq-fix.sh
```

### Complete Reset

```bash
cd /opt/matrix-discord-killer

# Stop all services
docker compose down

# Optionally remove volumes (WARNING: deletes data)
# docker compose down -v

# Start services
docker compose up -d

# Wait 30 seconds for RabbitMQ to initialize
sleep 30

# Apply RabbitMQ fix
sudo /path/to/oneshotmatrix-rabbitmq-fix.sh
```

## Configuration Files

### Installation Directory Structure

```
/opt/matrix-discord-killer/
├── docker-compose.yml       # Main compose file
├── .env                     # Environment variables and secrets
├── setup.sh                 # Patched setup script
├── install.sh               # Installation script
├── uninstall.sh             # Uninstallation script
├── caddy/                   # Caddy reverse proxy config
├── data/                    # Persistent data volumes
└── ...
```

### Important .env Variables

```bash
# RabbitMQ (Revolt messaging)
RABBIT_USER=rabbituser
RABBIT_PASSWORD=<random>
RABBITMQ_URI=amqp://rabbituser:<password>@rabbit:5672/

# MongoDB (Revolt database)
MONGO_USER=revolt
MONGO_PASSWORD=<random>

# MinIO (Object storage)
MINIO_USER=revolt
MINIO_PASSWORD=<random>

# Redis (Caching)
REDIS_PASSWORD=<random>

# PostgreSQL (Matrix database)
POSTGRES_PASSWORD=<random>

# Matrix Synapse
SYNAPSE_REGISTRATION_SHARED_SECRET=<random>
SYNAPSE_MACAROON_SECRET_KEY=<random>
SYNAPSE_FORM_SECRET=<random>

# TURN Server
TURN_SHARED_SECRET=<random>

# Web Push (VAPID)
VAPID_PRIVATE_KEY=<generated>
VAPID_PUBLIC_KEY=<generated>

# Encryption
FILE_ENCRYPTION_KEY=<generated>
```

## Advanced Usage

### Update Existing Installation

```bash
# Pull latest changes and reapply hotfixes
sudo ./oneshotmatrix-install.sh

# This will:
# 1. Git pull latest upstream changes
# 2. Reapply all hotfixes
# 3. Run setup.sh again (interactive)
```

### Skip Interactive Setup

```bash
# Clone and patch only
sudo ./oneshotmatrix-install.sh --skip-setup

# Then manually:
cd /opt/matrix-discord-killer
sudo ./setup.sh
```

### Use Custom .env Before Setup

```bash
# Clone and patch
sudo ./oneshotmatrix-install.sh --skip-setup

# Create custom .env
cd /opt/matrix-discord-killer
cat > .env << 'EOF'
RABBIT_USER=my_custom_user
RABBIT_PASSWORD=my_super_secure_password
# ... other variables
EOF

# Run setup (will preserve your .env values)
sudo ./setup.sh
```

## Security Recommendations

### Change Default Credentials

After deployment, update these in `.env`:

```bash
cd /opt/matrix-discord-killer

# Generate secure passwords
RABBIT_PASS=$(openssl rand -base64 32)
MONGO_PASS=$(openssl rand -base64 32)
MINIO_PASS=$(openssl rand -base64 32)
REDIS_PASS=$(openssl rand -base64 32)

# Update .env file
sed -i "s/^RABBIT_PASSWORD=.*/RABBIT_PASSWORD=${RABBIT_PASS}/" .env
sed -i "s/^MONGO_PASSWORD=.*/MONGO_PASSWORD=${MONGO_PASS}/" .env
# ... etc

# Apply new RabbitMQ credentials
sudo /path/to/oneshotmatrix-rabbitmq-fix.sh
```

### Protect .env File

```bash
cd /opt/matrix-discord-killer
chmod 600 .env
chown root:root .env
```

### Enable Firewall

```bash
# The installer pre-opens these ports:
# - SSH (auto-detected port)
# - 80 (HTTP)
# - 443 (HTTPS)

# On Debian/Ubuntu with UFW
sudo ufw status
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable

# On RHEL/Rocky/Fedora with firewalld
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --reload
```

## Maintenance

### View Logs

```bash
cd /opt/matrix-discord-killer

# All services
docker compose logs -f

# Specific services
docker compose logs -f api pushd events

# Last 100 lines
docker compose logs --tail=100
```

### Restart Services

```bash
cd /opt/matrix-discord-killer

# Restart all
docker compose restart

# Restart specific service
docker compose restart api
```

### Update Services

```bash
cd /opt/matrix-discord-killer

# Pull new images
docker compose pull

# Recreate containers with new images
docker compose up -d

# Fix RabbitMQ if needed
sudo /path/to/oneshotmatrix-rabbitmq-fix.sh
```

### Backup

```bash
cd /opt/matrix-discord-killer

# Stop services
docker compose down

# Backup data directory
tar -czf oneshotmatrix-backup-$(date +%Y%m%d).tar.gz data/ .env

# Restart services
docker compose up -d
```

## Support Resources

- **OneShotMatrix Repository**: https://github.com/loponai/oneshotmatrix
- **Revolt Documentation**: https://developers.revolt.chat/
- **Matrix Documentation**: https://matrix.org/docs/
- **RabbitMQ Fix Tools**: See `REVOLT_RABBITMQ_FIX.md` in this repository

## Quick Reference

### Essential Commands

```bash
# Installation
sudo ./oneshotmatrix-install.sh

# Fix RabbitMQ
sudo ./oneshotmatrix-rabbitmq-fix.sh

# Check status
cd /opt/matrix-discord-killer && docker compose ps

# View logs
cd /opt/matrix-discord-killer && docker compose logs -f api pushd

# Restart services
cd /opt/matrix-discord-killer && docker compose restart api pushd events

# Stop all
cd /opt/matrix-discord-killer && docker compose down

# Start all
cd /opt/matrix-discord-killer && docker compose up -d
```

---

**Last Updated**: 2026-02-14  
**Installer Version**: 1.0.0 with RabbitMQ fixes  
**Tested On**: Ubuntu 22.04, Rocky Linux 9, Fedora 39
