# Revolt RabbitMQ Credentials Fix

## Problem Description

When deploying Revolt (self-hosted chat platform) using Docker Compose, the `api` (revolt-delta) and `pushd` (revolt-pushd) services may crash with the following error:

```
PLAIN login refused: user 'rabbituser' - invalid credentials
```

This occurs in the RabbitMQ logs as:
```
rabbit-1  | [error] <0.1142.0> Error on AMQP connection <0.1142.0> (172.18.0.10:36366 -> 172.18.0.4:5672, state: starting):
rabbit-1  | [error] <0.1142.0> PLAIN login refused: user 'rabbituser' - invalid credentials
```

And causes the Revolt services to crash:
```
api-1     | thread 'main' (1) panicked at crates/delta/src/main.rs:122:6:
api-1     | Failed to connect to RabbitMQ: NetworkError("network io error: Connection reset by peer (os error 104)")

pushd-1   | thread 'main' (1) panicked at crates/daemons/pushd/src/main.rs:209:6:
pushd-1   | called `Result::unwrap()` on an `Err` value: NetworkError("network io error: Connection reset by peer (os error 104)")
```

## Root Cause

The issue occurs because:

1. **RabbitMQ starts with default credentials** (usually `guest/guest`) or no user named `rabbituser`
2. **Revolt services are configured to use** `rabbituser/rabbitpass` (or similar credentials)
3. **Credential mismatch** causes authentication failures
4. **Services crash** because they cannot establish RabbitMQ connections

## Solution Options

### Option 1: Automated Fix Script (Recommended)

Use the provided `revolt-rabbitmq-credentials-fix.sh` script to automatically configure RabbitMQ with the correct credentials:

```bash
# Make the script executable
chmod +x revolt-rabbitmq-credentials-fix.sh

# Run the script from your docker-compose directory
cd /path/to/your/revolt/deployment
/path/to/revolt-rabbitmq-credentials-fix.sh

# Or specify the directory as an argument
/path/to/revolt-rabbitmq-credentials-fix.sh /opt/matrix-discord-killer
```

The script will:
- Create the `rabbituser` user in RabbitMQ
- Set the correct password
- Grant administrator permissions
- Update your `.env` file with the credentials
- Provide instructions for restarting services

### Option 2: Manual Fix

If you prefer to fix this manually, follow these steps:

#### Step 1: Access the RabbitMQ container

```bash
# Find your RabbitMQ container name
docker ps | grep rabbitmq

# Access the container (replace 'rabbit-1' with your container name)
docker exec -it <container-name> bash
```

#### Step 2: Create the RabbitMQ user

```bash
# Create the user (replace with your desired password)
rabbitmqctl add_user rabbituser rabbitpass

# Set administrator tag
rabbitmqctl set_user_tags rabbituser administrator

# Grant permissions
rabbitmqctl set_permissions -p / rabbituser ".*" ".*" ".*"

# Verify the user was created
rabbitmqctl list_users

# Exit the container
exit
```

#### Step 3: Update your environment configuration

Edit your `.env` file to include:

```env
RABBITMQ_USERNAME=rabbituser
RABBITMQ_PASSWORD=rabbitpass
RABBITMQ_URI=amqp://rabbituser:rabbitpass@rabbit:5672/
```

#### Step 4: Restart the affected services

```bash
docker-compose restart api pushd events
# or
docker compose restart api pushd events
```

#### Step 5: Verify the fix

```bash
# Watch the logs to ensure services start successfully
docker-compose logs -f api pushd

# Check that all containers are running
docker ps
```

### Option 3: Configure RabbitMQ on First Start

To prevent this issue from occurring, configure RabbitMQ with the correct credentials from the start:

#### Update docker-compose.yml

Add environment variables to the RabbitMQ service:

```yaml
services:
  rabbit:
    image: rabbitmq:4
    environment:
      RABBITMQ_DEFAULT_USER: rabbituser
      RABBITMQ_DEFAULT_PASS: rabbitpass
    # ... rest of configuration
```

#### Update .env file

Ensure your `.env` file has matching credentials:

```env
RABBITMQ_USERNAME=rabbituser
RABBITMQ_PASSWORD=rabbitpass
RABBITMQ_URI=amqp://rabbituser:rabbitpass@rabbit:5672/
```

## Verification

After applying the fix, verify that:

1. **RabbitMQ accepts connections:**
   ```bash
   docker-compose logs rabbit | grep "rabbituser"
   ```
   Should show successful authentication instead of errors.

2. **Services start successfully:**
   ```bash
   docker ps
   ```
   Both `api` and `pushd` containers should show "Up" status, not "Restarting".

3. **No authentication errors in logs:**
   ```bash
   docker-compose logs --tail=50 api pushd | grep -i "credential\|refused\|panic"
   ```
   Should return no results.

## Common Issues

### Issue: User already exists but with wrong password

**Solution:** Delete and recreate the user:
```bash
docker exec <rabbitmq-container> rabbitmqctl delete_user rabbituser
docker exec <rabbitmq-container> rabbitmqctl add_user rabbituser rabbitpass
docker exec <rabbitmq-container> rabbitmqctl set_user_tags rabbituser administrator
docker exec <rabbitmq-container> rabbitmqctl set_permissions -p / rabbituser ".*" ".*" ".*"
```

### Issue: Environment variables not being picked up

**Solution:** Ensure your docker-compose.yml references the `.env` file:
```yaml
services:
  api:
    env_file: .env
    # or explicitly set:
    environment:
      RABBITMQ_URI: ${RABBITMQ_URI}
```

### Issue: Services still crash after fix

**Solution:** 
1. Completely restart the stack:
   ```bash
   docker-compose down
   docker-compose up -d
   ```

2. Check RabbitMQ logs for other errors:
   ```bash
   docker-compose logs rabbit
   ```

## Security Recommendations

1. **Change default credentials** - Don't use `rabbituser/rabbitpass` in production
2. **Use strong passwords** - Generate a secure random password
3. **Limit permissions** - If possible, use least-privilege permissions for Revolt services
4. **Use secrets management** - Consider Docker Secrets or external secret management for production

## Example: Generating Secure Credentials

```bash
# Generate a secure password
RABBITMQ_PASSWORD=$(openssl rand -base64 32)

# Update .env file
echo "RABBITMQ_USERNAME=rabbituser" > .env
echo "RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD}" >> .env
echo "RABBITMQ_URI=amqp://rabbituser:${RABBITMQ_PASSWORD}@rabbit:5672/" >> .env

# Create user in RabbitMQ
docker exec <rabbitmq-container> rabbitmqctl add_user rabbituser "${RABBITMQ_PASSWORD}"
docker exec <rabbitmq-container> rabbitmqctl set_user_tags rabbituser administrator
docker exec <rabbitmq-container> rabbitmqctl set_permissions -p / rabbituser ".*" ".*" ".*"
```

## Additional Resources

- [RabbitMQ Access Control Documentation](https://www.rabbitmq.com/access-control.html)
- [Revolt Self-Hosting Guide](https://github.com/revoltchat/self-hosted)
- [Docker Compose Environment Variables](https://docs.docker.com/compose/environment-variables/)

## Support

If you continue to experience issues after applying this fix:

1. Check RabbitMQ container logs: `docker-compose logs rabbit`
2. Check service logs: `docker-compose logs api pushd events`
3. Verify network connectivity between containers
4. Ensure all containers are on the same Docker network
5. Check for firewall or security group rules blocking traffic

## License

This fix documentation is provided as-is for the Revolt community.
