#!/bin/bash
#
# Revolt RabbitMQ Credentials Fix Script
# 
# This script fixes the "PLAIN login refused: user 'rabbituser' - invalid credentials" error
# that occurs when Revolt services (api/delta and pushd) cannot authenticate to RabbitMQ.
#
# Usage: ./revolt-rabbitmq-credentials-fix.sh [docker-compose-directory]
#

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
RABBITMQ_USER="${RABBITMQ_USER:-rabbituser}"
RABBITMQ_PASS="${RABBITMQ_PASS:-rabbitpass}"
RABBITMQ_CONTAINER="${RABBITMQ_CONTAINER:-rabbit}"
COMPOSE_DIR="${1:-.}"

echo -e "${GREEN}=== Revolt RabbitMQ Credentials Fix ===${NC}\n"

# Check if docker is available
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed or not in PATH${NC}"
    exit 1
fi

# Check if docker-compose is available
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    echo -e "${RED}Error: docker-compose is not installed or not in PATH${NC}"
    exit 1
fi

# Determine docker compose command
if docker compose version &> /dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
else
    DOCKER_COMPOSE="docker-compose"
fi

cd "$COMPOSE_DIR" || {
    echo -e "${RED}Error: Cannot change to directory $COMPOSE_DIR${NC}"
    exit 1
}

# Find the RabbitMQ container
RABBIT_CONTAINER_ID=$(docker ps --filter "name=${RABBITMQ_CONTAINER}" --format "{{.ID}}" | head -n 1)

if [ -z "$RABBIT_CONTAINER_ID" ]; then
    echo -e "${RED}Error: RabbitMQ container not found${NC}"
    echo "Looking for container with name matching: ${RABBITMQ_CONTAINER}"
    echo ""
    echo "Available containers:"
    docker ps --format "table {{.Names}}\t{{.Status}}"
    exit 1
fi

RABBIT_CONTAINER_NAME=$(docker ps --filter "id=${RABBIT_CONTAINER_ID}" --format "{{.Names}}")
echo -e "${GREEN}Found RabbitMQ container: ${RABBIT_CONTAINER_NAME}${NC}\n"

# Check current RabbitMQ users
echo -e "${YELLOW}Current RabbitMQ users:${NC}"
docker exec "$RABBIT_CONTAINER_ID" rabbitmqctl list_users || true
echo ""

# Check if the user already exists
USER_EXISTS=$(docker exec "$RABBIT_CONTAINER_ID" rabbitmqctl list_users 2>/dev/null | grep -c "^${RABBITMQ_USER}" || true)

if [ "$USER_EXISTS" -gt 0 ]; then
    echo -e "${YELLOW}User '${RABBITMQ_USER}' already exists. Deleting and recreating...${NC}"
    docker exec "$RABBIT_CONTAINER_ID" rabbitmqctl delete_user "$RABBITMQ_USER" || true
fi

# Create the user
echo -e "${GREEN}Creating RabbitMQ user: ${RABBITMQ_USER}${NC}"
docker exec "$RABBIT_CONTAINER_ID" rabbitmqctl add_user "$RABBITMQ_USER" "$RABBITMQ_PASS"

# Set administrator permissions
echo -e "${GREEN}Setting administrator tag for user${NC}"
docker exec "$RABBIT_CONTAINER_ID" rabbitmqctl set_user_tags "$RABBITMQ_USER" administrator

# Set permissions for all vhosts
echo -e "${GREEN}Setting permissions for user${NC}"
docker exec "$RABBIT_CONTAINER_ID" rabbitmqctl set_permissions -p / "$RABBITMQ_USER" ".*" ".*" ".*"

echo ""
echo -e "${YELLOW}Updated RabbitMQ users:${NC}"
docker exec "$RABBIT_CONTAINER_ID" rabbitmqctl list_users
echo ""

# Update environment file if it exists
ENV_FILE=".env"
if [ -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}Updating ${ENV_FILE} file...${NC}"
    
    # Backup existing .env file
    cp "$ENV_FILE" "${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Update or add RabbitMQ credentials
    if grep -q "RABBITMQ_USERNAME=" "$ENV_FILE"; then
        sed -i "s/^RABBITMQ_USERNAME=.*/RABBITMQ_USERNAME=${RABBITMQ_USER}/" "$ENV_FILE"
    else
        echo "RABBITMQ_USERNAME=${RABBITMQ_USER}" >> "$ENV_FILE"
    fi
    
    if grep -q "RABBITMQ_PASSWORD=" "$ENV_FILE"; then
        sed -i "s/^RABBITMQ_PASSWORD=.*/RABBITMQ_PASSWORD=${RABBITMQ_PASS}/" "$ENV_FILE"
    else
        echo "RABBITMQ_PASSWORD=${RABBITMQ_PASS}" >> "$ENV_FILE"
    fi
    
    if grep -q "RABBITMQ_URI=" "$ENV_FILE"; then
        sed -i "s|^RABBITMQ_URI=.*|RABBITMQ_URI=amqp://${RABBITMQ_USER}:${RABBITMQ_PASS}@rabbit:5672/|" "$ENV_FILE"
    else
        echo "RABBITMQ_URI=amqp://${RABBITMQ_USER}:${RABBITMQ_PASS}@rabbit:5672/" >> "$ENV_FILE"
    fi
    
    echo -e "${GREEN}Environment file updated${NC}"
else
    echo -e "${YELLOW}No .env file found. Creating one...${NC}"
    cat > "$ENV_FILE" << EOF
# RabbitMQ Credentials
RABBITMQ_USERNAME=${RABBITMQ_USER}
RABBITMQ_PASSWORD=${RABBITMQ_PASS}
RABBITMQ_URI=amqp://${RABBITMQ_USER}:${RABBITMQ_PASS}@rabbit:5672/
EOF
    echo -e "${GREEN}.env file created${NC}"
fi

echo ""
echo -e "${GREEN}=== Fix Applied Successfully ===${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Restart the affected services:"
echo "   ${DOCKER_COMPOSE} restart api pushd events"
echo ""
echo "2. Monitor the logs:"
echo "   ${DOCKER_COMPOSE} logs -f api pushd"
echo ""
echo "3. Verify services are running:"
echo "   docker ps"
echo ""
echo -e "${YELLOW}Credentials configured:${NC}"
echo "   Username: ${RABBITMQ_USER}"
echo "   Password: ${RABBITMQ_PASS}"
echo "   URI: amqp://${RABBITMQ_USER}:${RABBITMQ_PASS}@rabbit:5672/"
echo ""
