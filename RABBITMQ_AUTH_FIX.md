# RabbitMQ Authentication Fix for Oneshotmatrix

## Problem

After installing oneshotmatrix (Revolt chat server), the `api` and `pushd` services fail to start with RabbitMQ authentication errors:

```
PLAIN login refused: user 'rabbituser' - invalid credentials
NetworkError("network io error: Connection reset by peer (os error 104)")
```

This occurs because the RabbitMQ container starts with default credentials, but the application services are configured to use credentials from the `.env` file that were never properly configured in RabbitMQ.

## Symptoms

- `api-1` container repeatedly crashes with: `Failed to connect to RabbitMQ: NetworkError`
- `pushd-1` container repeatedly crashes with the same error
- RabbitMQ logs show: `PLAIN login refused: user 'rabbituser' - invalid credentials`
- `docker compose ps` shows `api` and `pushd` in `Restarting` status

## Root Cause

The oneshotmatrix setup process creates a `.env` file with `RABBIT_USER` and `RABBIT_PASSWORD` values, but these credentials are not properly initialized in the RabbitMQ container. RabbitMQ starts with only the default `guest` user, so when the application services try to authenticate with the credentials from `.env`, they are rejected.

## Solution

Run the `fix-rabbitmq-auth.sh` script to configure RabbitMQ with the correct credentials from your `.env` file.

### Usage

```bash
# Navigate to your oneshotmatrix installation directory
cd /opt/matrix-discord-killer

# Download and run the fix script
curl -fsSL https://raw.githubusercontent.com/[your-repo]/fix-rabbitmq-auth.sh -o fix-rabbitmq-auth.sh
chmod +x fix-rabbitmq-auth.sh
sudo ./fix-rabbitmq-auth.sh

# Or if the script is in the parent directory:
sudo bash ../fix-rabbitmq-auth.sh /opt/matrix-discord-killer
```

### What the script does

1. Reads `RABBIT_USER` and `RABBIT_PASSWORD` from your `.env` file
2. Ensures the RabbitMQ container is running
3. Waits for RabbitMQ to be ready
4. Creates the user with the correct password (recreating if it already exists)
5. Sets administrator privileges for the user
6. Grants full permissions on the default vhost `/`
7. Verifies the user was created successfully

### After running the fix

Restart the affected services:

```bash
cd /opt/matrix-discord-killer
docker compose restart api pushd events
```

Monitor the logs to verify the services start successfully:

```bash
docker compose logs -f api pushd
```

You should see the services connect to RabbitMQ successfully without authentication errors.

## Prevention

This issue should be fixed in the upstream oneshotmatrix setup script. The proper fix would be to add initialization commands to the RabbitMQ container or use an init script that runs when RabbitMQ first starts.

### Recommended upstream fix

Add to the `docker-compose.yml` file in the RabbitMQ service:

```yaml
rabbit:
  image: rabbitmq:4
  environment:
    RABBITMQ_DEFAULT_USER: ${RABBIT_USER}
    RABBITMQ_DEFAULT_PASS: ${RABBIT_PASSWORD}
```

Or create a RabbitMQ init script that runs on first startup.

## Verification

After applying the fix, verify the services are running:

```bash
docker compose ps
```

All services should show `Up` status instead of `Restarting`.

Check the API service logs:

```bash
docker compose logs --tail=20 api
```

You should see successful startup messages without RabbitMQ connection errors.

## Troubleshooting

### Script fails with "RabbitMQ did not become ready in time"

The RabbitMQ container may be taking longer to start. Try:

```bash
docker compose restart rabbit
sleep 10
sudo ./fix-rabbitmq-auth.sh
```

### Services still failing after running the fix

1. Check the credentials in `.env` match what the script configured:
   ```bash
   grep RABBIT_ .env
   ```

2. Verify the user exists in RabbitMQ:
   ```bash
   docker compose exec rabbit rabbitmqctl list_users
   ```

3. Check the user has correct permissions:
   ```bash
   docker compose exec rabbit rabbitmqctl list_user_permissions [your_rabbit_user]
   ```

4. Restart all services:
   ```bash
   docker compose restart
   ```

### Manual fix

If the script doesn't work, you can manually configure RabbitMQ:

```bash
cd /opt/matrix-discord-killer

# Get credentials from .env
source .env

# Create user in RabbitMQ
docker compose exec rabbit rabbitmqctl add_user "$RABBIT_USER" "$RABBIT_PASSWORD"
docker compose exec rabbit rabbitmqctl set_user_tags "$RABBIT_USER" administrator
docker compose exec rabbit rabbitmqctl set_permissions -p / "$RABBIT_USER" ".*" ".*" ".*"

# Restart services
docker compose restart api pushd events
```

## Related Issues

This fix addresses authentication issues between Revolt services and RabbitMQ in the oneshotmatrix deployment.

## License

This fix is provided as-is to help users experiencing RabbitMQ authentication issues with oneshotmatrix deployments.
