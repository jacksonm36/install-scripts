#!/bin/bash
#
# Post-Setup RabbitMQ Fix for OneShotMatrix/Revolt Deployments
#
# This script fixes RabbitMQ credentials after OneShotMatrix deployment
# Run this if you see "PLAIN login refused: user 'rabbituser' - invalid credentials"
#
# Usage: sudo ./oneshotmatrix-rabbitmq-fix.sh [install-dir]
#

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default installation directory
INSTALL_DIR="${1:-/opt/matrix-discord-killer}"

log() { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die() { err "$*"; exit 1; }

echo -e "${BLUE}=== OneShotMatrix RabbitMQ Credentials Fix ===${NC}\n"

# Check if running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "This script must be run as root (use sudo)"
fi

# Check if install directory exists
if [[ ! -d "$INSTALL_DIR" ]]; then
    die "Installation directory not found: $INSTALL_DIR"
fi

# Change to install directory
cd "$INSTALL_DIR" || die "Cannot change to directory: $INSTALL_DIR"

log "Working in: $INSTALL_DIR"

# Check if docker-compose.yml exists
if [[ ! -f "docker-compose.yml" ]]; then
    die "docker-compose.yml not found in $INSTALL_DIR"
fi

# Determine docker compose command
if docker compose version &>/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
else
    DOCKER_COMPOSE="docker-compose"
fi

# Read credentials from .env file
if [[ ! -f ".env" ]]; then
    warn ".env file not found, using defaults"
    RABBIT_USER="rabbituser"
    RABBIT_PASSWORD="rabbitpass"
else
    log "Reading credentials from .env file"
    # shellcheck disable=SC1091
    source .env
    
    RABBIT_USER="${RABBIT_USER:-rabbituser}"
    RABBIT_PASSWORD="${RABBIT_PASSWORD:-rabbitpass}"
fi

log "Using RabbitMQ credentials:"
log "  User: $RABBIT_USER"
log "  Password: [REDACTED]"
echo ""

# Find RabbitMQ container
log "Searching for RabbitMQ container..."
RABBIT_CONTAINER=$($DOCKER_COMPOSE ps -q rabbit 2>/dev/null || true)

if [[ -z "$RABBIT_CONTAINER" ]]; then
    # Try to find by name pattern
    RABBIT_CONTAINER=$(docker ps --filter "name=rabbit" --format "{{.ID}}" | head -n 1)
fi

if [[ -z "$RABBIT_CONTAINER" ]]; then
    err "RabbitMQ container not found or not running"
    echo ""
    log "Available containers:"
    docker ps --format "table {{.Names}}\t{{.Status}}"
    echo ""
    die "Please ensure RabbitMQ container is running (docker compose up -d)"
fi

RABBIT_CONTAINER_NAME=$(docker inspect --format '{{.Name}}' "$RABBIT_CONTAINER" | sed 's/^\///')
log "Found RabbitMQ container: $RABBIT_CONTAINER_NAME"
echo ""

# Wait for RabbitMQ to be ready
log "Waiting for RabbitMQ to be ready..."
MAX_WAIT=60
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if docker exec "$RABBIT_CONTAINER" rabbitmq-diagnostics ping >/dev/null 2>&1; then
        log "RabbitMQ is ready"
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done

if [ $WAITED -ge $MAX_WAIT ]; then
    die "RabbitMQ did not become ready within ${MAX_WAIT} seconds"
fi
echo ""

# Check current users
log "Current RabbitMQ users:"
docker exec "$RABBIT_CONTAINER" rabbitmqctl list_users 2>/dev/null || warn "Failed to list users"
echo ""

# Check if user already exists
USER_EXISTS=$(docker exec "$RABBIT_CONTAINER" rabbitmqctl list_users 2>/dev/null | grep -c "^${RABBIT_USER}" || true)

if [ "$USER_EXISTS" -gt 0 ]; then
    warn "User '$RABBIT_USER' already exists, recreating with correct credentials..."
    docker exec "$RABBIT_CONTAINER" rabbitmqctl delete_user "$RABBIT_USER" 2>/dev/null || warn "Failed to delete existing user"
fi

# Create the user
log "Creating RabbitMQ user: $RABBIT_USER"
if docker exec "$RABBIT_CONTAINER" rabbitmqctl add_user "$RABBIT_USER" "$RABBIT_PASSWORD" 2>/dev/null; then
    log "User created successfully"
else
    die "Failed to create user"
fi

# Set administrator tag
log "Setting administrator permissions"
if docker exec "$RABBIT_CONTAINER" rabbitmqctl set_user_tags "$RABBIT_USER" administrator 2>/dev/null; then
    log "Administrator tag set"
else
    die "Failed to set administrator tag"
fi

# Set permissions
log "Granting full permissions on vhost '/'"
if docker exec "$RABBIT_CONTAINER" rabbitmqctl set_permissions -p / "$RABBIT_USER" ".*" ".*" ".*" 2>/dev/null; then
    log "Permissions granted"
else
    die "Failed to grant permissions"
fi
echo ""

# Verify configuration
log "Verifying configuration:"
docker exec "$RABBIT_CONTAINER" rabbitmqctl list_users 2>/dev/null | grep "^${RABBIT_USER}" || warn "User verification failed"
docker exec "$RABBIT_CONTAINER" rabbitmqctl list_permissions -p / 2>/dev/null | grep "^${RABBIT_USER}" || warn "Permission verification failed"
echo ""

# Update .env file if needed
if [[ -f ".env" ]]; then
    if ! grep -q "^RABBITMQ_URI=" .env 2>/dev/null; then
        log "Adding RABBITMQ_URI to .env file..."
        echo "" >> .env
        echo "# RabbitMQ Connection URI" >> .env
        echo "RABBITMQ_URI=amqp://${RABBIT_USER}:${RABBIT_PASSWORD}@rabbit:5672/" >> .env
        log ".env file updated"
    fi
else
    log "Creating .env file with RabbitMQ credentials..."
    cat > .env << EOF
# RabbitMQ Credentials
RABBIT_USER=${RABBIT_USER}
RABBIT_PASSWORD=${RABBIT_PASSWORD}
RABBITMQ_URI=amqp://${RABBIT_USER}:${RABBIT_PASSWORD}@rabbit:5672/
EOF
    log ".env file created"
fi
echo ""

# Restart affected services
log "Restarting Revolt services..."
SERVICES_TO_RESTART="api pushd events"

for service in $SERVICES_TO_RESTART; do
    if $DOCKER_COMPOSE ps "$service" >/dev/null 2>&1; then
        log "Restarting $service..."
        $DOCKER_COMPOSE restart "$service" >/dev/null 2>&1 || warn "Failed to restart $service"
    else
        warn "Service $service not found"
    fi
done
echo ""

# Wait a moment for services to start
sleep 5

# Check service status
log "Checking service status:"
echo ""
$DOCKER_COMPOSE ps api pushd events 2>/dev/null || true
echo ""

# Check for errors in logs
log "Checking recent logs for errors..."
ERROR_COUNT=$($DOCKER_COMPOSE logs --tail=20 api pushd 2>/dev/null | grep -ci "invalid credentials\|connection reset\|failed to connect to rabbitmq" || true)

if [ "$ERROR_COUNT" -gt 0 ]; then
    warn "Still seeing RabbitMQ connection errors ($ERROR_COUNT mentions)"
    warn "Check logs with: cd $INSTALL_DIR && docker compose logs -f api pushd"
    echo ""
else
    echo -e "${GREEN}✓ No recent RabbitMQ errors found!${NC}"
    echo ""
fi

echo -e "${GREEN}=== RabbitMQ Configuration Complete ===${NC}"
echo ""
log "Next steps:"
echo "  1. Monitor logs: cd $INSTALL_DIR && docker compose logs -f api pushd"
echo "  2. Check status: cd $INSTALL_DIR && docker compose ps"
echo "  3. If issues persist, check: docker compose logs rabbit"
echo ""
log "RabbitMQ Credentials:"
echo "  Username: $RABBIT_USER"
echo "  Password: [stored in .env]"
echo "  URI: amqp://${RABBIT_USER}:***@rabbit:5672/"
echo ""
