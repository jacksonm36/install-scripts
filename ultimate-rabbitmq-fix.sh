#!/bin/bash
#
# ULTIMATE RabbitMQ Fix - Nuclear Option
# Completely resets RabbitMQ and ensures proper configuration
#
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[✓]${NC} $*"; }
err() { echo -e "${RED}[✗]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

INSTALL_DIR="${1:-/opt/matrix-discord-killer}"

echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  ULTIMATE RabbitMQ Fix - Nuclear Option   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
echo ""

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "Run as root: sudo $0"; exit 1; }
[[ -d "$INSTALL_DIR" ]] || { err "Directory not found: $INSTALL_DIR"; exit 1; }

cd "$INSTALL_DIR" || exit 1

if docker compose version &>/dev/null 2>&1; then
    DC="docker compose"
else
    DC="docker-compose"
fi

info "Working directory: $INSTALL_DIR"
echo ""

# Step 1: Stop ALL services
log "Step 1/7: Stopping all services..."
$DC down || warn "Failed to stop services cleanly"
sleep 3
echo ""

# Step 2: Remove RabbitMQ volume completely
log "Step 2/7: Removing RabbitMQ data (complete reset)..."
RABBIT_VOLUMES=$($DC config --volumes 2>/dev/null | grep -i rabbit || docker volume ls -q | grep rabbit || true)
if [ -n "$RABBIT_VOLUMES" ]; then
    for vol in $RABBIT_VOLUMES; do
        docker volume rm "$vol" 2>/dev/null && log "  Removed volume: $vol" || warn "  Could not remove: $vol"
    done
else
    info "  No RabbitMQ volumes found"
fi
echo ""

# Step 3: Check environment configuration
log "Step 3/7: Checking environment configuration..."
if [ -f .env ]; then
    log "  Found .env file"
    
    # Extract RabbitMQ configuration
    RABBIT_USER=$(grep "^RABBIT_USER=" .env 2>/dev/null | cut -d= -f2 || echo "")
    RABBIT_PASS_FROM_ENV=$(grep "^RABBIT_PASSWORD=" .env 2>/dev/null | cut -d= -f2 || echo "")
    
    info "  RABBIT_USER from .env: ${RABBIT_USER:-not set}"
    info "  RABBIT_PASSWORD from .env: ${RABBIT_PASS_FROM_ENV:+***set***}"
    
    # Get configuration from docker-compose
    RABBIT_USER_DC=$($DC config 2>/dev/null | grep -A1 "RABBITMQ_DEFAULT_USER" | tail -1 | sed 's/.*: //' | tr -d ' ' || echo "")
    RABBIT_PASS_DC=$($DC config 2>/dev/null | grep -A1 "RABBITMQ_DEFAULT_PASS" | tail -1 | sed 's/.*: //' | tr -d ' ' || echo "")
    
    info "  RABBITMQ_DEFAULT_USER from compose: ${RABBIT_USER_DC:-not set}"
    info "  RABBITMQ_DEFAULT_PASS from compose: ${RABBIT_PASS_DC:0:20}...${RABBIT_PASS_DC: -10}"
    
    # Use docker-compose values as they're what RabbitMQ will use
    RABBIT_USER="${RABBIT_USER_DC:-rabbituser}"
    RABBIT_PASS="${RABBIT_PASS_DC}"
    
else
    err "  .env file not found!"
    exit 1
fi
echo ""

# Step 4: Ensure environment variables are correct in .env
log "Step 4/7: Ensuring .env has correct RABBITMQ_URI..."
if [ -n "$RABBIT_PASS" ]; then
    # Update or add RABBITMQ_URI
    if grep -q "^RABBITMQ_URI=" .env; then
        sed -i "s|^RABBITMQ_URI=.*|RABBITMQ_URI=amqp://${RABBIT_USER}:${RABBIT_PASS}@rabbit:5672/|" .env
        log "  Updated RABBITMQ_URI in .env"
    else
        echo "RABBITMQ_URI=amqp://${RABBIT_USER}:${RABBIT_PASS}@rabbit:5672/" >> .env
        log "  Added RABBITMQ_URI to .env"
    fi
    
    # Also ensure RABBIT_USER and RABBIT_PASSWORD match
    if grep -q "^RABBIT_USER=" .env; then
        sed -i "s/^RABBIT_USER=.*/RABBIT_USER=${RABBIT_USER}/" .env
    else
        echo "RABBIT_USER=${RABBIT_USER}" >> .env
    fi
    
    if grep -q "^RABBIT_PASSWORD=" .env; then
        sed -i "s|^RABBIT_PASSWORD=.*|RABBIT_PASSWORD=${RABBIT_PASS}|" .env
    else
        echo "RABBIT_PASSWORD=${RABBIT_PASS}" >> .env
    fi
    
    log "  All RabbitMQ variables synchronized"
else
    err "  Cannot determine RabbitMQ password!"
    exit 1
fi
echo ""

# Step 5: Start services
log "Step 5/7: Starting all services..."
$DC up -d || { err "Failed to start services"; exit 1; }
log "  Services started"
echo ""

# Step 6: Wait for RabbitMQ and verify auto-creation
log "Step 6/7: Waiting for RabbitMQ to initialize..."
info "  This takes about 30-40 seconds for first-time init..."
sleep 35

MAX_WAIT=60
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if $DC exec -T rabbit rabbitmq-diagnostics ping &>/dev/null; then
        log "  RabbitMQ is ready!"
        break
    fi
    echo -n "."
    sleep 2
    WAITED=$((WAITED + 2))
done
echo ""

if [ $WAITED -ge $MAX_WAIT ]; then
    err "  RabbitMQ failed to start"
    exit 1
fi

# Verify user was auto-created
log "  Checking RabbitMQ users..."
$DC exec -T rabbit rabbitmqctl list_users

if $DC exec -T rabbit rabbitmqctl list_users 2>/dev/null | grep -q "^${RABBIT_USER}"; then
    log "  User '${RABBIT_USER}' auto-created by RabbitMQ!"
    
    # Ensure it has admin tag
    if ! $DC exec -T rabbit rabbitmqctl list_users 2>/dev/null | grep "^${RABBIT_USER}" | grep -q "\[administrator\]"; then
        warn "  Adding administrator tag..."
        $DC exec -T rabbit rabbitmqctl set_user_tags "$RABBIT_USER" administrator &>/dev/null
    fi
    
    # Ensure permissions
    $DC exec -T rabbit rabbitmqctl set_permissions -p / "$RABBIT_USER" ".*" ".*" ".*" &>/dev/null
    log "  Permissions verified"
else
    warn "  User NOT auto-created, creating manually..."
    $DC exec -T rabbit rabbitmqctl add_user "$RABBIT_USER" "$RABBIT_PASS" &>/dev/null
    $DC exec -T rabbit rabbitmqctl set_user_tags "$RABBIT_USER" administrator &>/dev/null
    $DC exec -T rabbit rabbitmqctl set_permissions -p / "$RABBIT_USER" ".*" ".*" ".*" &>/dev/null
    log "  User created manually"
fi
echo ""

# Step 7: Restart Revolt services and verify
log "Step 7/7: Restarting Revolt services..."
for svc in api pushd events; do
    $DC restart "$svc" &>/dev/null && log "  Restarted $svc" || warn "  Failed to restart $svc"
done

info "  Waiting 15 seconds for services to stabilize..."
sleep 15
echo ""

# Final verification
echo -e "${BLUE}═══════════════════════════════════════════${NC}"
log "VERIFICATION"
echo -e "${BLUE}═══════════════════════════════════════════${NC}"
echo ""

info "Service Status:"
$DC ps api pushd events rabbit | grep -E "NAME|api|pushd|events|rabbit"
echo ""

info "Checking for RabbitMQ errors in last 20 lines..."
ERROR_COUNT=$($DC logs --tail=20 api pushd 2>/dev/null | grep -ci "invalid credentials\|connection reset\|failed.*rabbitmq" || true)

if [ "$ERROR_COUNT" -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          ✓ FIX SUCCESSFUL!                 ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
    echo ""
    log "No RabbitMQ errors detected!"
    log "Services should be running now"
    echo ""
    info "Monitor logs with:"
    echo "  cd $INSTALL_DIR && docker compose logs -f api pushd"
    echo ""
    exit 0
else
    echo -e "${YELLOW}╔════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║       Still seeing $ERROR_COUNT errors          ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════╝${NC}"
    echo ""
    warn "Check what the services see:"
    echo "  docker compose exec api env | grep -i rabbit"
    echo "  docker compose exec pushd env | grep -i rabbit"
    echo ""
    warn "Check docker-compose.yml api service:"
    echo "  grep -A20 'api:' docker-compose.yml | grep -i env"
    echo ""
    warn "View full logs:"
    echo "  cd $INSTALL_DIR && docker compose logs --tail=50 api pushd"
    exit 1
fi
