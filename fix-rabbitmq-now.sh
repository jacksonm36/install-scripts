#!/bin/bash
#
# Emergency RabbitMQ Fix Script
# Reads password from docker-compose and sets it correctly in RabbitMQ
#
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[OK]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

INSTALL_DIR="${1:-/opt/matrix-discord-killer}"

echo -e "${GREEN}=== Emergency RabbitMQ Fix ===${NC}"
echo ""

# Check if running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run as root: sudo $0"
    exit 1
fi

cd "$INSTALL_DIR" || { err "Directory not found: $INSTALL_DIR"; exit 1; }

# Detect docker compose command
if docker compose version &>/dev/null 2>&1; then
    DC="docker compose"
else
    DC="docker-compose"
fi

log "Working in: $INSTALL_DIR"

# Get credentials from docker-compose config
log "Reading RabbitMQ configuration..."
RABBIT_USER=$($DC config 2>/dev/null | grep -A1 "RABBITMQ_DEFAULT_USER" | tail -1 | sed 's/.*: //' | tr -d ' ' || true)
RABBIT_PASS=$($DC config 2>/dev/null | grep -A1 "RABBITMQ_DEFAULT_PASS" | tail -1 | sed 's/.*: //' | tr -d ' ' || true)

if [[ -z "$RABBIT_USER" || -z "$RABBIT_PASS" ]]; then
    err "Could not find RabbitMQ credentials in docker-compose config"
    exit 1
fi

log "Found credentials:"
log "  User: $RABBIT_USER"
log "  Password: ${RABBIT_PASS:0:10}...${RABBIT_PASS: -10}"
echo ""

# Stop services first
log "Stopping affected services..."
$DC stop api pushd events 2>/dev/null || warn "Failed to stop some services"

# Recreate RabbitMQ container to reset it
log "Resetting RabbitMQ container..."
$DC stop rabbit 2>/dev/null || true
$DC rm -f rabbit 2>/dev/null || true

# Start RabbitMQ fresh
log "Starting RabbitMQ..."
$DC up -d rabbit

# Wait for RabbitMQ to be ready
log "Waiting for RabbitMQ to initialize (this takes ~30 seconds)..."
sleep 30

MAX_WAIT=60
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if $DC exec -T rabbit rabbitmq-diagnostics ping &>/dev/null; then
        log "RabbitMQ is ready!"
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    echo -n "."
done
echo ""

if [ $WAITED -ge $MAX_WAIT ]; then
    err "RabbitMQ did not start in time"
    exit 1
fi

# Check if user was auto-created
log "Checking RabbitMQ users..."
if $DC exec -T rabbit rabbitmqctl list_users 2>/dev/null | grep -q "^${RABBIT_USER}"; then
    log "User '${RABBIT_USER}' was auto-created"
    
    # Verify it has admin permissions
    if $DC exec -T rabbit rabbitmqctl list_users 2>/dev/null | grep "^${RABBIT_USER}" | grep -q "\[administrator\]"; then
        log "User has administrator permissions"
    else
        warn "User exists but missing admin permissions, fixing..."
        $DC exec -T rabbit rabbitmqctl set_user_tags "$RABBIT_USER" administrator &>/dev/null
    fi
    
    # Ensure permissions are set
    $DC exec -T rabbit rabbitmqctl set_permissions -p / "$RABBIT_USER" ".*" ".*" ".*" &>/dev/null
    log "Permissions configured"
else
    warn "User not auto-created, creating manually..."
    $DC exec -T rabbit rabbitmqctl add_user "$RABBIT_USER" "$RABBIT_PASS" &>/dev/null
    $DC exec -T rabbit rabbitmqctl set_user_tags "$RABBIT_USER" administrator &>/dev/null
    $DC exec -T rabbit rabbitmqctl set_permissions -p / "$RABBIT_USER" ".*" ".*" ".*" &>/dev/null
    log "User created and configured"
fi

echo ""
log "RabbitMQ users:"
$DC exec -T rabbit rabbitmqctl list_users
echo ""

# Start all services
log "Starting all services..."
$DC up -d

# Wait a bit for services to start
sleep 10

# Check status
log "Service status:"
$DC ps api pushd events rabbit
echo ""

# Check for errors
log "Checking for errors in last 30 seconds..."
ERROR_COUNT=$($DC logs --since=30s api pushd 2>/dev/null | grep -ci "invalid credentials\|connection reset\|failed.*rabbitmq" || true)

if [ "$ERROR_COUNT" -gt 0 ]; then
    warn "Found $ERROR_COUNT error mentions in logs"
    warn "Waiting 10 more seconds and checking again..."
    sleep 10
    ERROR_COUNT=$($DC logs --since=10s api pushd 2>/dev/null | grep -ci "invalid credentials\|connection reset\|failed.*rabbitmq" || true)
    
    if [ "$ERROR_COUNT" -gt 0 ]; then
        err "Still seeing errors. Manual check needed:"
        echo "  $DC logs -f api pushd"
        exit 1
    fi
fi

log "✓ No errors found!"
echo ""
echo -e "${GREEN}=== Fix Complete ===${NC}"
echo ""
log "Next steps:"
echo "  1. Monitor: $DC logs -f api pushd"
echo "  2. Check: $DC ps"
echo ""
