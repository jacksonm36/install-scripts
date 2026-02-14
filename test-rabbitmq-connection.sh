#!/bin/bash
#
# RabbitMQ Connection Test Script
#
# This script tests RabbitMQ connectivity and authentication
# to help diagnose credential and connection issues.
#
# Usage: ./test-rabbitmq-connection.sh [docker-compose-directory]
#

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
COMPOSE_DIR="${1:-.}"
RABBITMQ_CONTAINER=""
TEST_PASSED=0
TEST_FAILED=0

echo -e "${BLUE}=== RabbitMQ Connection Test ===${NC}\n"

# Change to compose directory
cd "$COMPOSE_DIR" || {
    echo -e "${RED}Error: Cannot change to directory $COMPOSE_DIR${NC}"
    exit 1
}

# Determine docker compose command
if docker compose version &> /dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
else
    DOCKER_COMPOSE="docker-compose"
fi

# Find RabbitMQ container
echo -e "${YELLOW}Searching for RabbitMQ container...${NC}"
RABBITMQ_CONTAINER=$(docker ps --filter "name=rabbit" --format "{{.Names}}" | head -n 1)

if [ -z "$RABBITMQ_CONTAINER" ]; then
    echo -e "${RED}✗ RabbitMQ container not found${NC}"
    echo "Available containers:"
    docker ps --format "table {{.Names}}\t{{.Status}}"
    exit 1
fi

echo -e "${GREEN}✓ Found RabbitMQ container: ${RABBITMQ_CONTAINER}${NC}\n"

# Helper function for test results
pass() {
    echo -e "${GREEN}✓ $1${NC}"
    ((TEST_PASSED++))
}

fail() {
    echo -e "${RED}✗ $1${NC}"
    ((TEST_FAILED++))
}

warn() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Test 1: Container is running
echo -e "${BLUE}Test 1: Container Status${NC}"
if docker ps --filter "name=${RABBITMQ_CONTAINER}" --filter "status=running" | grep -q "${RABBITMQ_CONTAINER}"; then
    pass "RabbitMQ container is running"
else
    fail "RabbitMQ container is not running"
fi
echo ""

# Test 2: RabbitMQ service is responding
echo -e "${BLUE}Test 2: RabbitMQ Service Health${NC}"
if docker exec "$RABBITMQ_CONTAINER" rabbitmq-diagnostics ping &>/dev/null; then
    pass "RabbitMQ service is responding"
else
    fail "RabbitMQ service is not responding"
fi
echo ""

# Test 3: Check for users
echo -e "${BLUE}Test 3: RabbitMQ Users${NC}"
USERS=$(docker exec "$RABBITMQ_CONTAINER" rabbitmqctl list_users 2>/dev/null || echo "")
if [ -z "$USERS" ]; then
    fail "Unable to list RabbitMQ users"
else
    pass "Successfully retrieved user list"
    info "Current users:"
    echo "$USERS" | while IFS= read -r line; do
        echo "    $line"
    done
fi
echo ""

# Test 4: Check for 'rabbituser'
echo -e "${BLUE}Test 4: Required User 'rabbituser'${NC}"
if echo "$USERS" | grep -q "^rabbituser"; then
    pass "User 'rabbituser' exists"
    
    # Check tags
    USER_TAGS=$(echo "$USERS" | grep "^rabbituser" | awk '{print $2}')
    if echo "$USER_TAGS" | grep -q "administrator"; then
        pass "User 'rabbituser' has administrator tag"
    else
        fail "User 'rabbituser' missing administrator tag (has: $USER_TAGS)"
    fi
else
    fail "User 'rabbituser' does not exist"
    warn "Create user with: docker exec $RABBITMQ_CONTAINER rabbitmqctl add_user rabbituser rabbitpass"
fi
echo ""

# Test 5: Check permissions
echo -e "${BLUE}Test 5: User Permissions${NC}"
if echo "$USERS" | grep -q "^rabbituser"; then
    PERMS=$(docker exec "$RABBITMQ_CONTAINER" rabbitmqctl list_permissions -p / 2>/dev/null || echo "")
    if echo "$PERMS" | grep -q "^rabbituser"; then
        pass "User 'rabbituser' has permissions on vhost '/'"
        info "Permissions:"
        echo "$PERMS" | grep "^rabbituser" | while IFS= read -r line; do
            echo "    $line"
        done
    else
        fail "User 'rabbituser' has no permissions on vhost '/'"
        warn "Set permissions with: docker exec $RABBITMQ_CONTAINER rabbitmqctl set_permissions -p / rabbituser '.*' '.*' '.*'"
    fi
else
    warn "Skipping permission check (user does not exist)"
fi
echo ""

# Test 6: Check environment variables
echo -e "${BLUE}Test 6: Environment Configuration${NC}"
if [ -f ".env" ]; then
    pass ".env file exists"
    
    if grep -q "RABBITMQ_USERNAME" .env; then
        RABBIT_USER=$(grep "RABBITMQ_USERNAME" .env | cut -d= -f2)
        pass "RABBITMQ_USERNAME is set to: $RABBIT_USER"
    else
        fail "RABBITMQ_USERNAME not found in .env"
    fi
    
    if grep -q "RABBITMQ_PASSWORD" .env; then
        pass "RABBITMQ_PASSWORD is set"
    else
        fail "RABBITMQ_PASSWORD not found in .env"
    fi
    
    if grep -q "RABBITMQ_URI" .env; then
        RABBIT_URI=$(grep "RABBITMQ_URI" .env | cut -d= -f2)
        # Redact password in output
        RABBIT_URI_DISPLAY=$(echo "$RABBIT_URI" | sed 's/:\/\/[^:]*:[^@]*@/:\/\/***:***@/')
        pass "RABBITMQ_URI is set to: $RABBIT_URI_DISPLAY"
    else
        fail "RABBITMQ_URI not found in .env"
    fi
else
    fail ".env file not found"
    warn "Create .env file with RabbitMQ credentials"
fi
echo ""

# Test 7: Check docker-compose configuration
echo -e "${BLUE}Test 7: Docker Compose Configuration${NC}"
if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
    pass "docker-compose file exists"
    
    # Check if RabbitMQ has environment variables
    if $DOCKER_COMPOSE config 2>/dev/null | grep -A5 "rabbit:" | grep -q "RABBITMQ_DEFAULT_USER"; then
        pass "RabbitMQ service has RABBITMQ_DEFAULT_USER configured"
    else
        warn "RabbitMQ service missing RABBITMQ_DEFAULT_USER environment variable"
        info "Add to rabbit service: RABBITMQ_DEFAULT_USER: \${RABBITMQ_USERNAME}"
    fi
else
    fail "docker-compose file not found"
fi
echo ""

# Test 8: Check API service connection
echo -e "${BLUE}Test 8: API Service Status${NC}"
API_CONTAINER=$(docker ps --filter "name=api" --format "{{.Names}}" | head -n 1)
if [ -n "$API_CONTAINER" ]; then
    if docker ps --filter "name=${API_CONTAINER}" --filter "status=running" | grep -q "${API_CONTAINER}"; then
        pass "API container is running"
        
        # Check logs for RabbitMQ errors
        RECENT_LOGS=$(docker logs --tail=20 "$API_CONTAINER" 2>&1 || echo "")
        if echo "$RECENT_LOGS" | grep -qi "invalid credentials\|connection reset\|failed to connect to rabbitmq"; then
            fail "API container shows RabbitMQ connection errors"
            warn "Check logs with: docker logs $API_CONTAINER"
        else
            pass "No recent RabbitMQ errors in API logs"
        fi
    else
        fail "API container exists but is not running"
    fi
else
    warn "API container not found (may not be started yet)"
fi
echo ""

# Test 9: Check pushd service connection  
echo -e "${BLUE}Test 9: Pushd Service Status${NC}"
PUSHD_CONTAINER=$(docker ps -a --filter "name=pushd" --format "{{.Names}}" | head -n 1)
if [ -n "$PUSHD_CONTAINER" ]; then
    if docker ps --filter "name=${PUSHD_CONTAINER}" --filter "status=running" | grep -q "${PUSHD_CONTAINER}"; then
        pass "Pushd container is running"
        
        # Check logs for RabbitMQ errors
        RECENT_LOGS=$(docker logs --tail=20 "$PUSHD_CONTAINER" 2>&1 || echo "")
        if echo "$RECENT_LOGS" | grep -qi "invalid credentials\|connection reset\|failed to connect to rabbitmq"; then
            fail "Pushd container shows RabbitMQ connection errors"
            warn "Check logs with: docker logs $PUSHD_CONTAINER"
        else
            pass "No recent RabbitMQ errors in Pushd logs"
        fi
    else
        fail "Pushd container exists but is not running"
        CONTAINER_STATUS=$(docker ps -a --filter "name=${PUSHD_CONTAINER}" --format "{{.Status}}")
        info "Status: $CONTAINER_STATUS"
    fi
else
    warn "Pushd container not found (may not be started yet)"
fi
echo ""

# Test 10: Network connectivity
echo -e "${BLUE}Test 10: Network Connectivity${NC}"
if [ -n "$API_CONTAINER" ]; then
    if docker exec "$API_CONTAINER" timeout 5 nc -zv rabbit 5672 &>/dev/null; then
        pass "API can reach RabbitMQ on port 5672"
    else
        fail "API cannot reach RabbitMQ on port 5672"
        warn "Check Docker network configuration"
    fi
else
    warn "Skipping network test (API container not found)"
fi
echo ""

# Summary
echo -e "${BLUE}=== Test Summary ===${NC}"
echo -e "Tests passed: ${GREEN}${TEST_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TEST_FAILED}${NC}"
echo ""

if [ $TEST_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed! RabbitMQ appears to be configured correctly.${NC}"
    exit 0
else
    echo -e "${RED}✗ Some tests failed. Please review the issues above.${NC}"
    echo ""
    echo -e "${YELLOW}Common fixes:${NC}"
    echo "1. Create RabbitMQ user:"
    echo "   docker exec $RABBITMQ_CONTAINER rabbitmqctl add_user rabbituser rabbitpass"
    echo "   docker exec $RABBITMQ_CONTAINER rabbitmqctl set_user_tags rabbituser administrator"
    echo "   docker exec $RABBITMQ_CONTAINER rabbitmqctl set_permissions -p / rabbituser '.*' '.*' '.*'"
    echo ""
    echo "2. Create/update .env file with:"
    echo "   RABBITMQ_USERNAME=rabbituser"
    echo "   RABBITMQ_PASSWORD=rabbitpass"
    echo "   RABBITMQ_URI=amqp://rabbituser:rabbitpass@rabbit:5672/"
    echo ""
    echo "3. Restart services:"
    echo "   docker compose restart api pushd events"
    echo ""
    echo "For automated fix, run: ./revolt-rabbitmq-credentials-fix.sh"
    exit 1
fi
