# RabbitMQ Credentials Fix for Revolt

This repository contains a complete solution for fixing RabbitMQ authentication issues in Revolt (self-hosted Discord alternative) deployments.

## The Problem

When deploying Revolt using Docker Compose, you may encounter services crashing with:

```
PLAIN login refused: user 'rabbituser' - invalid credentials
```

This causes the `api`, `pushd`, and `events` services to continuously crash and restart.

## Quick Start

Choose the solution that best fits your needs:

### 🚀 Option 1: Automated Fix (Recommended)

Run the automated fix script:

```bash
chmod +x revolt-rabbitmq-credentials-fix.sh
./revolt-rabbitmq-credentials-fix.sh /path/to/your/revolt/deployment
```

Then restart your services:
```bash
docker compose restart api pushd events
```

### ⚡ Option 2: Manual Quick Fix

```bash
# Create RabbitMQ user
docker exec <rabbitmq-container> rabbitmqctl add_user rabbituser rabbitpass
docker exec <rabbitmq-container> rabbitmqctl set_user_tags rabbituser administrator
docker exec <rabbitmq-container> rabbitmqctl set_permissions -p / rabbituser ".*" ".*" ".*"

# Restart services
docker compose restart api pushd events
```

### 🛡️ Option 3: Prevention (New Deployments)

Use the provided Docker Compose example to set up RabbitMQ correctly from the start:

```bash
# Copy the example configuration
cp docker-compose-rabbitmq-example.yml docker-compose.yml

# Create .env file with credentials
cat > .env << EOF
RABBITMQ_USERNAME=rabbituser
RABBITMQ_PASSWORD=$(openssl rand -base64 32)
RABBITMQ_URI=amqp://rabbituser:${RABBITMQ_PASSWORD}@rabbit:5672/
EOF

# Start services
docker compose up -d
```

## Files in This Repository

| File | Purpose |
|------|---------|
| **QUICK_FIX_GUIDE.md** | Immediate solutions for active issues |
| **REVOLT_RABBITMQ_FIX.md** | Complete documentation and troubleshooting |
| **revolt-rabbitmq-credentials-fix.sh** | Automated fix script |
| **test-rabbitmq-connection.sh** | Diagnostic and verification test suite |
| **docker-compose-rabbitmq-example.yml** | Example configuration to prevent issues |
| **README_RABBITMQ_FIX.md** | This file - overview and quick start |

## Documentation Structure

```
📁 RabbitMQ Fix Solution
├── 📄 README_RABBITMQ_FIX.md              ← Start here
├── 📄 QUICK_FIX_GUIDE.md                  ← Need immediate fix?
├── 📄 REVOLT_RABBITMQ_FIX.md              ← Detailed documentation
├── 🔧 revolt-rabbitmq-credentials-fix.sh  ← Automated fix
├── 🧪 test-rabbitmq-connection.sh         ← Verify & diagnose
└── 📋 docker-compose-rabbitmq-example.yml ← Reference configuration
```

## When to Use Each Resource

- **Having issues right now?** → Start with [QUICK_FIX_GUIDE.md](QUICK_FIX_GUIDE.md)
- **Want to understand the problem?** → Read [REVOLT_RABBITMQ_FIX.md](REVOLT_RABBITMQ_FIX.md)
- **Setting up new deployment?** → Use [docker-compose-rabbitmq-example.yml](docker-compose-rabbitmq-example.yml)
- **Need automated solution?** → Run `revolt-rabbitmq-credentials-fix.sh`

## Common Scenarios

### Scenario 1: Services Keep Crashing

**Symptoms:**
- `api` and `pushd` containers show "Restarting" status
- Logs show "invalid credentials" or "Connection reset by peer"

**Solution:**
1. Run the automated fix script
2. Restart affected services
3. Verify with `docker ps`

See: [QUICK_FIX_GUIDE.md](QUICK_FIX_GUIDE.md)

### Scenario 2: First Time Setup

**Symptoms:**
- Setting up Revolt for the first time
- Want to avoid authentication issues

**Solution:**
1. Use the example docker-compose.yml
2. Configure RabbitMQ environment variables
3. Create .env file with credentials

See: [docker-compose-rabbitmq-example.yml](docker-compose-rabbitmq-example.yml)

### Scenario 3: Need to Change Credentials

**Symptoms:**
- Want to update RabbitMQ password
- Need to implement better security

**Solution:**
1. Generate new secure password
2. Update RabbitMQ user
3. Update .env file
4. Restart services

See: [REVOLT_RABBITMQ_FIX.md](REVOLT_RABBITMQ_FIX.md) - Security Recommendations

## Verification Steps

After applying any fix, verify success:

### Automated Verification (Recommended)

```bash
# Run comprehensive test suite
./test-rabbitmq-connection.sh /path/to/your/deployment

# This will check:
# - Container status and health
# - User existence and permissions
# - Environment configuration
# - Service connectivity
# - Recent error logs
```

### Manual Verification

```bash
# 1. Check container status
docker ps | grep -E "api|pushd|rabbit"

# Expected: All containers show "Up", not "Restarting"

# 2. Check logs for errors
docker compose logs --tail=50 api pushd | grep -i error

# Expected: No authentication or connection errors

# 3. Verify RabbitMQ user
docker compose exec rabbit rabbitmqctl list_users

# Expected: rabbituser exists with [administrator] tag
```

## Troubleshooting

If the fix doesn't work:

1. **Check RabbitMQ is running:**
   ```bash
   docker compose ps rabbit
   docker compose logs rabbit
   ```

2. **Verify environment variables:**
   ```bash
   docker compose config | grep RABBITMQ
   ```

3. **Test credentials manually:**
   ```bash
   docker compose exec rabbit rabbitmqctl authenticate_user rabbituser rabbitpass
   ```

4. **Complete restart:**
   ```bash
   docker compose down
   docker compose up -d
   ```

For detailed troubleshooting, see [REVOLT_RABBITMQ_FIX.md](REVOLT_RABBITMQ_FIX.md).

## Security Best Practices

⚠️ **Important Security Notes:**

1. **Never use default credentials in production**
   - Change `rabbituser` and `rabbitpass` to secure values
   - Use strong, randomly generated passwords

2. **Protect your .env file**
   ```bash
   chmod 600 .env
   echo ".env" >> .gitignore
   ```

3. **Use Docker Secrets for production**
   - Don't store credentials in plain text
   - Consider external secret management

4. **Limit network exposure**
   - Don't expose RabbitMQ ports publicly
   - Use internal Docker networks

See the Security section in [REVOLT_RABBITMQ_FIX.md](REVOLT_RABBITMQ_FIX.md) for complete recommendations.

## Production Deployment

For production deployments:

```bash
# 1. Generate secure credentials
RABBITMQ_USER="revolt_prod_$(openssl rand -hex 4)"
RABBITMQ_PASS=$(openssl rand -base64 32)

# 2. Configure RabbitMQ
docker compose exec rabbit rabbitmqctl add_user "$RABBITMQ_USER" "$RABBITMQ_PASS"
docker compose exec rabbit rabbitmqctl set_user_tags "$RABBITMQ_USER" administrator
docker compose exec rabbit rabbitmqctl set_permissions -p / "$RABBITMQ_USER" ".*" ".*" ".*"

# 3. Update .env securely
cat > .env << EOF
RABBITMQ_USERNAME=${RABBITMQ_USER}
RABBITMQ_PASSWORD=${RABBITMQ_PASS}
RABBITMQ_URI=amqp://${RABBITMQ_USER}:${RABBITMQ_PASS}@rabbit:5672/
EOF
chmod 600 .env

# 4. Restart services
docker compose restart api pushd events
```

## Support and Contributing

### Getting Help

1. Check the documentation files in this repository
2. Review RabbitMQ logs: `docker compose logs rabbit`
3. Verify container status: `docker ps`
4. Check the [Revolt self-hosting guide](https://github.com/revoltchat/self-hosted)

### Reporting Issues

If you encounter issues not covered by this documentation:

1. Collect logs: `docker compose logs --tail=100 api pushd rabbit`
2. Note your configuration (without credentials)
3. Document steps taken
4. Open an issue with details

### Contributing

Contributions welcome! Please submit pull requests with:
- Clear description of changes
- Testing results
- Updated documentation if needed

## License

This solution is provided as-is for the Revolt and open-source community.

## Related Resources

- [Revolt Self-Hosting Guide](https://github.com/revoltchat/self-hosted)
- [RabbitMQ Documentation](https://www.rabbitmq.com/documentation.html)
- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [RabbitMQ Access Control](https://www.rabbitmq.com/access-control.html)

## Quick Reference

### Essential Commands

```bash
# Create RabbitMQ user
docker exec <container> rabbitmqctl add_user <username> <password>

# Set administrator permissions
docker exec <container> rabbitmqctl set_user_tags <username> administrator

# Grant full permissions
docker exec <container> rabbitmqctl set_permissions -p / <username> ".*" ".*" ".*"

# List users
docker exec <container> rabbitmqctl list_users

# Delete user
docker exec <container> rabbitmqctl delete_user <username>

# Restart services
docker compose restart api pushd events

# View logs
docker compose logs -f api pushd rabbit
```

### Environment Variables

```env
# Required in .env file
RABBITMQ_USERNAME=rabbituser
RABBITMQ_PASSWORD=rabbitpass
RABBITMQ_URI=amqp://rabbituser:rabbitpass@rabbit:5672/
```

### Docker Compose Environment

```yaml
# Add to RabbitMQ service in docker-compose.yml
environment:
  RABBITMQ_DEFAULT_USER: ${RABBITMQ_USERNAME}
  RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD}
```

---

**Last Updated:** 2026-02-14

**Tested With:**
- RabbitMQ 4.x
- Revolt 0.11.0
- Docker Compose v2.x

**Status:** ✅ Production Ready
