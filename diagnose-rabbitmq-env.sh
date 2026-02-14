#!/bin/bash
# Quick diagnostic script to check RabbitMQ environment variable mismatch

set -e

INSTALL_DIR="${1:-/opt/matrix-discord-killer}"
cd "$INSTALL_DIR" || exit 1

echo "=== RabbitMQ Environment Diagnostic ==="
echo ""

echo "1. Checking .env file for RabbitMQ variables:"
if [ -f .env ]; then
    grep -E "RABBIT|RABBITMQ" .env | sed 's/PASSWORD=.*/PASSWORD=***REDACTED***/' || echo "  No RabbitMQ variables found"
else
    echo "  ERROR: .env file not found!"
fi
echo ""

echo "2. Checking what API container sees:"
API_CONTAINER=$(docker compose ps -q api 2>/dev/null || docker ps -q -f name=api | head -1)
if [ -n "$API_CONTAINER" ]; then
    docker exec "$API_CONTAINER" env 2>/dev/null | grep -E "RABBIT|RABBITMQ" | sed 's/PASSWORD=.*/PASSWORD=***REDACTED***/' || echo "  No RabbitMQ env vars in API container"
else
    echo "  API container not found"
fi
echo ""

echo "3. Checking what pushd container sees:"
PUSHD_CONTAINER=$(docker compose ps -q pushd 2>/dev/null || docker ps -q -f name=pushd | head -1)
if [ -n "$PUSHD_CONTAINER" ]; then
    docker exec "$PUSHD_CONTAINER" env 2>/dev/null | grep -E "RABBIT|RABBITMQ" | sed 's/PASSWORD=.*/PASSWORD=***REDACTED***/' || echo "  No RabbitMQ env vars in pushd container"
else
    echo "  pushd container not found"
fi
echo ""

echo "4. Checking docker-compose.yml for RabbitMQ config:"
if [ -f docker-compose.yml ]; then
    echo "  RabbitMQ service env vars:"
    grep -A20 "rabbit:" docker-compose.yml | grep -E "RABBIT|environment:" | head -10 || echo "    None configured"
    echo ""
    echo "  API service env vars:"
    grep -A20 "^\s*api:" docker-compose.yml | grep -E "RABBIT|environment:|env_file:" | head -10 || echo "    None configured"
else
    echo "  ERROR: docker-compose.yml not found!"
fi
echo ""

echo "5. Recommendation:"
echo "  The services need RABBITMQ_URI environment variable."
echo "  Run this command to check:"
echo "    docker compose config | grep -i rabbitmq"
echo ""
