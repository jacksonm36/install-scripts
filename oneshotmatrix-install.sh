#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="2.0.0"
DEFAULT_REPO_URL="https://github.com/loponai/oneshotmatrix.git"
DEFAULT_INSTALL_DIR="/opt/matrix-discord-killer"
DEFAULT_REPO_REF="main"

REPO_URL="${ONESHOTMATRIX_REPO_URL:-$DEFAULT_REPO_URL}"
INSTALL_DIR="${ONESHOTMATRIX_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
REPO_REF="${ONESHOTMATRIX_REF:-$DEFAULT_REPO_REF}"

SKIP_SETUP="false"
SKIP_RABBITMQ_FIX="false"
FORCE_RECLONE="false"
FIX_RABBITMQ="false"
OS_FAMILY=""
PKG_MANAGER=""
PKG_UPDATED="false"

log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
oneshotmatrix-install.sh v${SCRIPT_VERSION}

Installs/updates loponai/oneshotmatrix with automatic RabbitMQ fixes.

Usage:
  sudo bash oneshotmatrix-install.sh [options]

Options:
  --install-dir <path>   Install path (default: ${DEFAULT_INSTALL_DIR})
  --repo-url <url>       Git repository URL (default: ${DEFAULT_REPO_URL})
  --repo-ref <ref>       Git ref to deploy (default: ${DEFAULT_REPO_REF})
  --skip-setup           Clone/update + patch only, do not run setup.sh
  --skip-rabbitmq-fix    Skip automatic RabbitMQ credential configuration
  --force-reclone        Remove existing install dir before cloning
  --fix-rabbitmq         Fix RabbitMQ auth (reset data so it reinitializes with .env)
  -h, --help             Show this help

Environment overrides:
  ONESHOTMATRIX_INSTALL_DIR
  ONESHOTMATRIX_REPO_URL
  ONESHOTMATRIX_REF

New in v2.0.0:
  - Automatic RabbitMQ credential configuration and verification
  - Post-deployment health checks for all services
  - Better error handling and diagnostics
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir)
        [[ $# -ge 2 ]] || die "--install-dir requires a value"
        INSTALL_DIR="$2"
        shift 2
        ;;
      --repo-url)
        [[ $# -ge 2 ]] || die "--repo-url requires a value"
        REPO_URL="$2"
        shift 2
        ;;
      --repo-ref)
        [[ $# -ge 2 ]] || die "--repo-ref requires a value"
        REPO_REF="$2"
        shift 2
        ;;
      --skip-setup)
        SKIP_SETUP="true"
        shift
        ;;
      --skip-rabbitmq-fix)
        SKIP_RABBITMQ_FIX="true"
        shift
        ;;
      --force-reclone)
        FORCE_RECLONE="true"
        shift
        ;;
      --fix-rabbitmq)
        FIX_RABBITMQ="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run this script as root."
}

fix_rabbitmq_auth() {
  local dir="${INSTALL_DIR:?INSTALL_DIR not set}"
  [[ -d "$dir" ]] || die "Install directory not found: $dir"
  [[ -f "$dir/docker-compose.stoat.yml" ]] || die "Stoat compose file not found. Is this a Stoat/Revolt deployment?"
  [[ -f "$dir/.env" ]] || die ".env not found at $dir/.env"
  grep -q "^RABBIT_USER=" "$dir/.env" || die "RABBIT_USER not set in .env"
  grep -q "^RABBIT_PASSWORD=" "$dir/.env" || die "RABBIT_PASSWORD not set in .env"

  log "Stopping RabbitMQ-dependent services..."
  (cd "$dir" && docker compose stop rabbit api pushd events 2>/dev/null) || true
  log "Resetting RabbitMQ data (will reinitialize with credentials from .env)..."
  rm -rf "$dir/data/rabbit"
  mkdir -p "$dir/data/rabbit"
  log "Starting services..."
  (cd "$dir" && docker compose up -d) || die "Docker compose up failed."
  log "RabbitMQ auth fix complete. API and pushd should connect within ~30 seconds."
}

detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found."
  # shellcheck disable=SC1091
  source /etc/os-release

  case "${ID,,}" in
    ubuntu|debian)
      OS_FAMILY="debian"
      PKG_MANAGER="apt-get"
      export DEBIAN_FRONTEND=noninteractive
      ;;
    fedora)
      OS_FAMILY="rhel"
      PKG_MANAGER="dnf"
      ;;
    rocky|rhel|centos|almalinux|ol|oraclelinux)
      OS_FAMILY="rhel"
      if command_exists dnf; then
        PKG_MANAGER="dnf"
      elif command_exists yum; then
        PKG_MANAGER="yum"
      else
        die "Neither dnf nor yum found."
      fi
      ;;
    *)
      if [[ "${ID_LIKE:-}" =~ (debian|ubuntu) ]]; then
        OS_FAMILY="debian"
        PKG_MANAGER="apt-get"
        export DEBIAN_FRONTEND=noninteractive
      elif [[ "${ID_LIKE:-}" =~ (rhel|fedora|centos) ]]; then
        OS_FAMILY="rhel"
        if command_exists dnf; then
          PKG_MANAGER="dnf"
        elif command_exists yum; then
          PKG_MANAGER="yum"
        else
          die "Neither dnf nor yum found."
        fi
      else
        die "Unsupported OS: ${ID}"
      fi
      ;;
  esac
}

pkg_update_once() {
  if [[ "$PKG_UPDATED" == "true" ]]; then
    return 0
  fi
  log "Refreshing package metadata..."
  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get update -y
  else
    if [[ "$PKG_MANAGER" == "dnf" ]]; then
      dnf makecache -y
    else
      yum makecache -y
    fi
  fi
  PKG_UPDATED="true"
}

pkg_install() {
  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get install -y "$@"
  else
    if [[ "$PKG_MANAGER" == "dnf" ]]; then
      dnf install -y "$@"
    else
      yum install -y "$@"
    fi
  fi
}

ensure_command() {
  local binary="$1"
  local package="$2"
  if command_exists "$binary"; then
    return 0
  fi
  pkg_update_once
  log "Installing required package: ${package}"
  pkg_install "$package"
  command_exists "$binary" || die "Failed to install command '${binary}' via package '${package}'."
}

detect_ssh_port_safe() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    awk '{print $4}' <<<"$SSH_CONNECTION"
    return 0
  fi

  local cfg port=""
  for cfg in /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config; do
    [[ -f "$cfg" ]] || continue
    port="$(awk 'tolower($1)=="port"{print $2; exit}' "$cfg" 2>/dev/null || true)"
    if [[ -n "${port:-}" ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  done

  port="$(ss -tlnp 2>/dev/null | awk '/sshd/ {split($4,a,":"); p=a[length(a)]; if (p ~ /^[0-9]+$/) {print p; exit}}' || true)"
  printf '%s\n' "${port:-22}"
}

clone_or_update_repo() {
  if [[ "$FORCE_RECLONE" == "true" && -d "$INSTALL_DIR" ]]; then
    log "Removing existing install directory due to --force-reclone."
    rm -rf "$INSTALL_DIR"
  fi

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    log "Updating existing clone in ${INSTALL_DIR}"
    if git -C "$INSTALL_DIR" fetch --prune origin "$REPO_REF"; then
      if git -C "$INSTALL_DIR" checkout -f "$REPO_REF" >/dev/null 2>&1; then
        git -C "$INSTALL_DIR" reset --hard "origin/${REPO_REF}"
      else
        git -C "$INSTALL_DIR" checkout -f -B "$REPO_REF" "origin/${REPO_REF}"
      fi
    else
      warn "Fetch failed, re-cloning repository."
      rm -rf "$INSTALL_DIR"
    fi
  fi

  if [[ ! -d "$INSTALL_DIR/.git" ]]; then
    log "Cloning ${REPO_URL} (${REPO_REF}) into ${INSTALL_DIR}"
    git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$INSTALL_DIR" \
      || die "Unable to clone ${REPO_URL} at ref '${REPO_REF}'."
  fi
}

apply_setup_hotfixes() {
  local setup_file="$INSTALL_DIR/setup.sh"
  [[ -f "$setup_file" ]] || die "setup.sh not found at ${setup_file}"

  log "Applying setup.sh hotfixes (v2.0.0)..."
  python3 - "$setup_file" <<'PY'
import sys
from pathlib import Path

setup_path = Path(sys.argv[1])
text = setup_path.read_text(encoding="utf-8")
changes = []

def replace_once(old: str, new: str, name: str) -> None:
    global text
    if old in text:
        text = text.replace(old, new, 1)
        changes.append(name)

replace_once(
"""detect_ssh_port() {
    # Detect SSH port: check sshd_config + drop-in configs, then running sshd via ss
    local port=""
    # Primary: read from sshd config and drop-in files
    for cfg in /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config; do
        [ -f "$cfg" ] || continue
        port=$(grep -iE '^\\s*Port\\s+' "$cfg" 2>/dev/null | awk '{print $2}' | head -1)
        [ -n "$port" ] && break
    done
    # Fallback: check what sshd is actually listening on
    if [ -z "$port" ]; then
        port=$(ss -tlnp 2>/dev/null | grep -E '"sshd"|sshd' | awk '{print $4}' | rev | cut -d: -f1 | rev | head -1)
    fi
    echo "${port:-22}"
}
""",
"""detect_ssh_port() {
    # Prefer active SSH session port when available.
    if [ -n "${SSH_CONNECTION:-}" ]; then
        echo "$SSH_CONNECTION" | awk '{print $4}'
        return 0
    fi

    local cfg port=""
    for cfg in /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config; do
        [ -f "$cfg" ] || continue
        port=$(awk 'tolower($1)=="port"{print $2; exit}' "$cfg" 2>/dev/null || true)
        [ -n "${port:-}" ] && break
    done

    if [ -z "${port:-}" ]; then
        port=$(ss -tlnp 2>/dev/null | awk '/sshd/ {split($4,a,":"); p=a[length(a)]; if (p ~ /^[0-9]+$/) {print p; exit}}' || true)
    fi
    echo "${port:-22}"
}
""",
"safe SSH port detection under set -e",
)

replace_once(
'        dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo >/dev/null 2>&1 || return 1\n',
'        dnf install -y -q dnf-plugins-core >/dev/null 2>&1 || true\n'
'        dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo >/dev/null 2>&1 || return 1\n',
"dnf-plugins-core install before dnf config-manager",
)

replace_once(
"""if [ -f "$INSTALL_DIR/.env" ]; then
    POSTGRES_PASSWORD=$(grep "^POSTGRES_PASSWORD=" "$INSTALL_DIR/.env" | cut -d= -f2-)
    REGISTRATION_SHARED_SECRET=$(grep "^SYNAPSE_REGISTRATION_SHARED_SECRET=" "$INSTALL_DIR/.env" | cut -d= -f2-)
    MACAROON_SECRET_KEY=$(grep "^SYNAPSE_MACAROON_SECRET_KEY=" "$INSTALL_DIR/.env" | cut -d= -f2-)
    FORM_SECRET=$(grep "^SYNAPSE_FORM_SECRET=" "$INSTALL_DIR/.env" | cut -d= -f2-)
    TURN_SHARED_SECRET=$(grep "^TURN_SHARED_SECRET=" "$INSTALL_DIR/.env" | cut -d= -f2-)
fi
""",
"""if [ -f "$INSTALL_DIR/.env" ]; then
    POSTGRES_PASSWORD=$(grep "^POSTGRES_PASSWORD=" "$INSTALL_DIR/.env" | cut -d= -f2- || true)
    REGISTRATION_SHARED_SECRET=$(grep "^SYNAPSE_REGISTRATION_SHARED_SECRET=" "$INSTALL_DIR/.env" | cut -d= -f2- || true)
    MACAROON_SECRET_KEY=$(grep "^SYNAPSE_MACAROON_SECRET_KEY=" "$INSTALL_DIR/.env" | cut -d= -f2- || true)
    FORM_SECRET=$(grep "^SYNAPSE_FORM_SECRET=" "$INSTALL_DIR/.env" | cut -d= -f2- || true)
    TURN_SHARED_SECRET=$(grep "^TURN_SHARED_SECRET=" "$INSTALL_DIR/.env" | cut -d= -f2- || true)
fi
""",
"safe matrix .env secret reuse",
)

replace_once(
"""if [ -f "$INSTALL_DIR/.env" ]; then
    VAPID_PRIVATE_KEY=$(grep "^VAPID_PRIVATE_KEY=" "$INSTALL_DIR/.env" | cut -d= -f2-) || true
    VAPID_PUBLIC_KEY=$(grep "^VAPID_PUBLIC_KEY=" "$INSTALL_DIR/.env" | cut -d= -f2-) || true
    FILE_ENCRYPTION_KEY=$(grep "^FILE_ENCRYPTION_KEY=" "$INSTALL_DIR/.env" | cut -d= -f2-) || true
    MONGO_USER=$(grep "^MONGO_USER=" "$INSTALL_DIR/.env" | cut -d= -f2-) || true
    MONGO_PASSWORD=$(grep "^MONGO_PASSWORD=" "$INSTALL_DIR/.env" | cut -d= -f2-) || true
    RABBIT_USER=$(grep "^RABBIT_USER=" "$INSTALL_DIR/.env" | cut -d= -f2-) || true
    RABBIT_PASSWORD=$(grep "^RABBIT_PASSWORD=" "$INSTALL_DIR/.env" | cut -d= -f2-) || true
    MINIO_USER=$(grep "^MINIO_USER=" "$INSTALL_DIR/.env" | cut -d= -f2-) || true
    MINIO_PASSWORD=$(grep "^MINIO_PASSWORD=" "$INSTALL_DIR/.env" | cut -d= -f2-) || true
    REDIS_PASSWORD=$(grep "^REDIS_PASSWORD=" "$INSTALL_DIR/.env" | cut -d= -f2-) || true
fi
""",
"""if [ -f "$INSTALL_DIR/.env" ]; then
    VAPID_PRIVATE_KEY=$(grep "^VAPID_PRIVATE_KEY=" "$INSTALL_DIR/.env" | cut -d= -f2- || true)
    VAPID_PUBLIC_KEY=$(grep "^VAPID_PUBLIC_KEY=" "$INSTALL_DIR/.env" | cut -d= -f2- || true)
    FILE_ENCRYPTION_KEY=$(grep "^FILE_ENCRYPTION_KEY=" "$INSTALL_DIR/.env" | cut -d= -f2- || true)
    MONGO_USER=$(grep "^MONGO_USER=" "$INSTALL_DIR/.env" | cut -d= -f2- || true)
    MONGO_PASSWORD=$(grep "^MONGO_PASSWORD=" "$INSTALL_DIR/.env" | cut -d= -f2- || true)
    RABBIT_USER=$(grep "^RABBIT_USER=" "$INSTALL_DIR/.env" | cut -d= -f2- || true)
    RABBIT_PASSWORD=$(grep "^RABBIT_PASSWORD=" "$INSTALL_DIR/.env" | cut -d= -f2- || true)
    MINIO_USER=$(grep "^MINIO_USER=" "$INSTALL_DIR/.env" | cut -d= -f2- || true)
    MINIO_PASSWORD=$(grep "^MINIO_PASSWORD=" "$INSTALL_DIR/.env" | cut -d= -f2- || true)
    REDIS_PASSWORD=$(grep "^REDIS_PASSWORD=" "$INSTALL_DIR/.env" | cut -d= -f2- || true)
fi
""",
"safe stoat .env secret reuse",
)

replace_once(
"    if docker compose exec -T synapse curl -sf http://localhost:8008/health >/dev/null 2>&1; then\n",
"    if docker compose exec -T synapse python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8008/health', timeout=3).read()\" >/dev/null 2>&1; then\n",
"matrix readiness probe without curl dependency",
)

replace_once(
"    if docker compose exec -T api curl -sf http://localhost:14702/ >/dev/null 2>&1; then\n",
"    if docker inspect -f '{{.State.Status}}' \"$(docker compose ps -q api)\" 2>/dev/null | grep -qx running; then\n",
"stoat readiness probe without container curl dependency",
)

replace_once(
"""cd "$INSTALL_DIR"

COMPOSE_EXIT=0
docker compose up -d 2>&1 || COMPOSE_EXIT=$?""",
"""cd "$INSTALL_DIR"

# RabbitMQ only applies RABBITMQ_DEFAULT_* on first init. If credentials in .env
# were changed, reset RabbitMQ data so it reinitializes with current credentials.
if [ -d "$DATA_DIR/rabbit" ]; then
    docker compose stop rabbit api pushd events 2>/dev/null || true
    rm -rf "$DATA_DIR/rabbit"
    mkdir -p "$DATA_DIR/rabbit"
fi

COMPOSE_EXIT=0
docker compose up -d 2>&1 || COMPOSE_EXIT=$?""",
"RabbitMQ auth reset on stoat setup re-run",
)

setup_path.write_text(text, encoding="utf-8")
print("Applied hotfixes:")
if changes:
    for item in changes:
        print(f" - {item}")
else:
    print(" - none (upstream may already include fixes)")
PY

  chmod +x "$INSTALL_DIR/setup.sh" "$INSTALL_DIR/install.sh" "$INSTALL_DIR/uninstall.sh"
  bash -n "$INSTALL_DIR/setup.sh" || die "Patched setup.sh failed syntax validation."
}

preopen_acme_firewall_paths() {
  local ssh_port
  ssh_port="$(detect_ssh_port_safe)"

  if [[ "$OS_FAMILY" == "debian" ]]; then
    if command_exists ufw && ufw status 2>/dev/null | grep -qi 'Status: active'; then
      log "Pre-opening SSH (${ssh_port}), 80, and 443 in active UFW."
      ufw allow "${ssh_port}/tcp" >/dev/null 2>&1 || true
      ufw allow 80/tcp >/dev/null 2>&1 || true
      ufw allow 443/tcp >/dev/null 2>&1 || true
    fi
  else
    if command_exists firewall-cmd && systemctl is-active --quiet firewalld; then
      log "Pre-opening SSH (${ssh_port}), 80, and 443 in active firewalld."
      firewall-cmd --permanent --zone=public --add-port="${ssh_port}/tcp" >/dev/null 2>&1 || true
      firewall-cmd --permanent --zone=public --add-port=80/tcp >/dev/null 2>&1 || true
      firewall-cmd --permanent --zone=public --add-port=443/tcp >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
    fi
  fi
}

configure_rabbitmq_credentials() {
  [[ -d "$INSTALL_DIR" ]] || die "Install directory not found: ${INSTALL_DIR}"
  cd "$INSTALL_DIR" || die "Cannot change to ${INSTALL_DIR}"

  log "Configuring RabbitMQ credentials..."

  # Determine docker compose command
  local dc_cmd
  if docker compose version &>/dev/null 2>&1; then
    dc_cmd="docker compose"
  else
    dc_cmd="docker-compose"
  fi

  # Source .env file if it exists
  if [[ ! -f ".env" ]]; then
    warn ".env file not found, skipping RabbitMQ configuration"
    return 0
  fi

  # shellcheck disable=SC1091
  set +u  # Allow unset variables temporarily
  source .env 2>/dev/null || true
  set -u

  local rabbit_user="${RABBIT_USER:-rabbituser}"
  local rabbit_pass="${RABBIT_PASSWORD:-}"

  # Get password from docker-compose config if not in .env
  if [[ -z "$rabbit_pass" ]]; then
    rabbit_pass=$($dc_cmd config 2>/dev/null | grep -A1 "RABBITMQ_DEFAULT_PASS" | tail -1 | sed 's/.*: //' | tr -d ' ' || true)
  fi

  if [[ -z "$rabbit_pass" ]]; then
    warn "No RabbitMQ password found, skipping credential configuration"
    return 0
  fi

  log "Waiting for RabbitMQ to be ready..."
  local max_wait=60
  local waited=0
  local rabbit_ready=false

  while [[ $waited -lt $max_wait ]]; do
    if $dc_cmd exec -T rabbit rabbitmq-diagnostics ping &>/dev/null; then
      rabbit_ready=true
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done

  if [[ "$rabbit_ready" != "true" ]]; then
    warn "RabbitMQ did not become ready within ${max_wait} seconds"
    return 1
  fi

  log "RabbitMQ is ready, configuring user '${rabbit_user}'..."

  # Check if user exists
  local user_exists=false
  if $dc_cmd exec -T rabbit rabbitmqctl list_users 2>/dev/null | grep -q "^${rabbit_user}"; then
    user_exists=true
    log "User '${rabbit_user}' exists, updating credentials..."
  else
    log "Creating user '${rabbit_user}'..."
  fi

  # Delete existing user if it exists (to ensure clean state)
  if [[ "$user_exists" == "true" ]]; then
    $dc_cmd exec -T rabbit rabbitmqctl delete_user "$rabbit_user" &>/dev/null || true
    sleep 1
  fi

  # Create user with correct password
  if $dc_cmd exec -T rabbit rabbitmqctl add_user "$rabbit_user" "$rabbit_pass" &>/dev/null; then
    log "User created successfully"
  else
    warn "Failed to create user"
    return 1
  fi

  # Set administrator tag
  if $dc_cmd exec -T rabbit rabbitmqctl set_user_tags "$rabbit_user" administrator &>/dev/null; then
    log "Administrator permissions set"
  else
    warn "Failed to set administrator permissions"
  fi

  # Grant full permissions
  if $dc_cmd exec -T rabbit rabbitmqctl set_permissions -p / "$rabbit_user" ".*" ".*" ".*" &>/dev/null; then
    log "Permissions granted"
  else
    warn "Failed to grant permissions"
  fi

  # Verify configuration
  log "Verifying RabbitMQ configuration..."
  if $dc_cmd exec -T rabbit rabbitmqctl list_users 2>/dev/null | grep -q "^${rabbit_user}.*\[administrator\]"; then
    log "✓ RabbitMQ user '${rabbit_user}' configured successfully"
  else
    warn "RabbitMQ user verification failed"
    return 1
  fi

  # Restart services that depend on RabbitMQ
  log "Restarting Revolt services..."
  for service in api pushd events; do
    if $dc_cmd ps "$service" &>/dev/null; then
      $dc_cmd restart "$service" &>/dev/null || warn "Failed to restart $service"
    fi
  done

  sleep 5

  # Check service health
  log "Checking service status..."
  local api_status=$($dc_cmd ps api 2>/dev/null | grep -c "Up" || echo "0")
  local pushd_status=$($dc_cmd ps pushd 2>/dev/null | grep -c "Up" || echo "0")

  if [[ "$api_status" -gt 0 && "$pushd_status" -gt 0 ]]; then
    log "✓ Services are running"
  else
    warn "Some services may not be running properly"
    warn "Check with: cd ${INSTALL_DIR} && docker compose ps"
  fi

  # Check for recent errors
  local error_count=$($dc_cmd logs --tail=20 api pushd 2>/dev/null | grep -ci "invalid credentials\|connection reset" || true)
  if [[ "$error_count" -gt 0 ]]; then
    warn "Still seeing ${error_count} RabbitMQ connection errors in recent logs"
    warn "Check logs with: cd ${INSTALL_DIR} && docker compose logs -f api pushd"
    return 1
  else
    log "✓ No RabbitMQ connection errors detected"
  fi

  return 0
}

main() {
  parse_args "$@"
  require_root

  if [[ "$FIX_RABBITMQ" == "true" ]]; then
    fix_rabbitmq_auth
    exit 0
  fi

  detect_os

  log "Detected OS family: ${OS_FAMILY}"
  ensure_command git git
  ensure_command curl curl
  ensure_command python3 python3

  clone_or_update_repo
  apply_setup_hotfixes

  if [[ "$SKIP_SETUP" == "true" ]]; then
    log "Setup execution skipped (--skip-setup)."
    exit 0
  fi

  preopen_acme_firewall_paths

  [[ -e /dev/tty ]] || die "/dev/tty not available. Run from an interactive terminal."
  log "Starting patched oneshotmatrix setup..."
  
  # Run setup.sh but don't exec (so we can continue after)
  if bash "$INSTALL_DIR/setup.sh" </dev/tty; then
    log "Setup completed successfully"
  else
    die "Setup failed with exit code $?"
  fi

  # Configure RabbitMQ after setup completes
  if [[ "$SKIP_RABBITMQ_FIX" != "true" ]]; then
    log "========================================="
    log "Applying post-setup RabbitMQ configuration..."
    log "========================================="
    if configure_rabbitmq_credentials; then
      log "========================================="
      log "✓ Installation completed successfully!"
      log "========================================="
      log ""
      log "Next steps:"
      log "  1. Access your installation: http://$(hostname -f) or http://$(hostname -I | awk '{print $1}')"
      log "  2. Check service status: cd ${INSTALL_DIR} && docker compose ps"
      log "  3. View logs: cd ${INSTALL_DIR} && docker compose logs -f"
      log ""
    else
      warn "========================================="
      warn "RabbitMQ configuration encountered issues"
      warn "========================================="
      warn ""
      warn "Manual fix:"
      warn "  cd ${INSTALL_DIR}"
      warn "  docker compose down"
      warn "  docker compose up -d"
      warn "  # Wait 30 seconds for RabbitMQ to initialize"
      warn "  docker compose restart api pushd events"
      warn ""
    fi
  else
    log "RabbitMQ configuration skipped (--skip-rabbitmq-fix)"
  fi
}

main "$@"
