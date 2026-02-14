# Quick Fix for RabbitMQ Credential Error

## Your Current Issue

Your Revolt services are crashing with:
```
PLAIN login refused: user 'rabbituser' - invalid credentials
```

## Immediate Fix (Choose One)

### Option A: Use the Automated Script (Easiest)

```bash
# Download and run the fix script
curl -O https://raw.githubusercontent.com/jacksonm36/install-scripts/cursor/rabbitmq-connection-credentials-0f84/revolt-rabbitmq-credentials-fix.sh
chmod +x revolt-rabbitmq-credentials-fix.sh
cd /opt/matrix-discord-killer
./revolt-rabbitmq-credentials-fix.sh
```

Then restart services:
```bash
docker compose restart api pushd events
```

### Option B: Manual 3-Step Fix (Fast)

```bash
# Step 1: Create RabbitMQ user
docker exec matrix-discord-killer-rabbit-1 rabbitmqctl add_user rabbituser rabbitpass
docker exec matrix-discord-killer-rabbit-1 rabbitmqctl set_user_tags rabbituser administrator
docker exec matrix-discord-killer-rabbit-1 rabbitmqctl set_permissions -p / rabbituser ".*" ".*" ".*"

# Step 2: Update .env file (create if doesn't exist)
cd /opt/matrix-discord-killer
cat >> .env << EOF
RABBITMQ_USERNAME=rabbituser
RABBITMQ_PASSWORD=rabbitpass
RABBITMQ_URI=amqp://rabbituser:rabbitpass@rabbit:5672/
EOF

# Step 3: Restart services
docker compose restart api pushd events
```

### Verify Fix

```bash
# Check that services are now running (not restarting)
docker ps

# Should see:
# - matrix-discord-killer-api-1: Up
# - matrix-discord-killer-pushd-1: Up
# (not "Restarting")

# Check logs for success
docker compose logs --tail=20 api pushd | grep -v "invalid credentials"
```

## Security Note

For production, change `rabbitpass` to a secure password:

```bash
# Generate secure password
SECURE_PASS=$(openssl rand -base64 24)

# Use this password instead of 'rabbitpass' in the commands above
```

## Full Documentation

See [REVOLT_RABBITMQ_FIX.md](REVOLT_RABBITMQ_FIX.md) for:
- Detailed explanation of the issue
- Alternative solutions
- Troubleshooting steps
- Security best practices
