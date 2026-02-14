#!/usr/bin/env bash
set -Eeuo pipefail

# Fix RabbitMQ authentication issue in oneshotmatrix deployment
# This script reconfigures RabbitMQ to match the credentials in .env

INSTALL_DIR="${1:-/opt/matrix-discord-killer}"
COMPOSE_PROJECT="matrix-discord-killer"

log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

[[ -d "$INSTALL_DIR" ]] || die "Install directory not found: $INSTALL_DIR"
[[ -f "$INSTALL_DIR/.env" ]] || die ".env file not found at $INSTALL_DIR/.env"

cd "$INSTALL_DIR" || die "Failed to cd to $INSTALL_DIR"

# Extract RabbitMQ credentials from .env
log "Reading credentials from .env file..."
RABBIT_USER=$(grep "^RABBIT_USER=" .env | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
RABBIT_PASSWORD=$(grep "^RABBIT_PASSWORD=" .env | cut -d= -f2- | tr -d '"' | tr -d "'" || true)

[[ -n "$RABBIT_USER" ]] || die "RABBIT_USER not found in .env"
[[ -n "$RABBIT_PASSWORD" ]] || die "RABBIT_PASSWORD not found in .env"

log "Found credentials: RABBIT_USER=$RABBIT_USER"

# Check if RabbitMQ container is running
if ! docker compose ps rabbit | grep -q "Up\|running"; then
    warn "RabbitMQ container is not running. Starting it..."
    docker compose up -d rabbit || die "Failed to start RabbitMQ"
    sleep 5
fi

# Wait for RabbitMQ to be ready
log "Waiting for RabbitMQ to be ready..."
for i in {1..30}; do
    if docker compose exec -T rabbit rabbitmqctl status >/dev/null 2>&1; then
        log "RabbitMQ is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        die "RabbitMQ did not become ready in time"
    fi
    sleep 1
done

# Check if user already exists
log "Checking if user '$RABBIT_USER' exists..."
if docker compose exec -T rabbit rabbitmqctl list_users 2>/dev/null | grep -q "^${RABBIT_USER}[[:space:]]"; then
    log "User exists. Deleting and recreating to ensure correct password..."
    docker compose exec -T rabbit rabbitmqctl delete_user "$RABBIT_USER" 2>/dev/null || true
fi

# Create the user with the correct password
log "Creating RabbitMQ user '$RABBIT_USER'..."
docker compose exec -T rabbit rabbitmqctl add_user "$RABBIT_USER" "$RABBIT_PASSWORD" || die "Failed to create user"

# Set administrator tag
log "Setting administrator permissions..."
docker compose exec -T rabbit rabbitmqctl set_user_tags "$RABBIT_USER" administrator || die "Failed to set user tags"

# Grant full permissions on default vhost
log "Granting permissions on vhost '/'..."
docker compose exec -T rabbit rabbitmqctl set_permissions -p / "$RABBIT_USER" ".*" ".*" ".*" || die "Failed to set permissions"

# Verify the user was created
log "Verifying user creation..."
if docker compose exec -T rabbit rabbitmqctl list_users 2>/dev/null | grep -q "^${RABBIT_USER}[[:space:]]"; then
    log "✓ User '$RABBIT_USER' successfully configured"
else
    die "User verification failed"
fi

# Show permissions
log "User permissions:"
docker compose exec -T rabbit rabbitmqctl list_user_permissions "$RABBIT_USER" || true

log ""
log "RabbitMQ authentication fix completed!"
log "Now restart the affected services:"
log "  cd $INSTALL_DIR"
log "  docker compose restart api pushd events"
log ""
