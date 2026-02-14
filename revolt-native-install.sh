#!/usr/bin/env bash
set -Eeuo pipefail

# Revolt Native Installer (multi-OS) - No Docker
# - Debian/Ubuntu + Fedora/RHEL-family
# - Native installation of all components
# - Optional components: Nginx + TLS, firewall rules, fail2ban
# - Services: MongoDB, RabbitMQ, Redis, MinIO, Revolt (built from source)

SCRIPT_VERSION="1.0.0"

REVOLT_USER="revolt"
REVOLT_GROUP="revolt"
REVOLT_ROOT="/opt/revolt"
REVOLT_BUILD="${REVOLT_ROOT}/build"
REVOLT_DATA="${REVOLT_ROOT}/data"
REVOLT_CONFIG="${REVOLT_ROOT}/config"
REVOLT_LOG="/var/log/revolt"
REVOLT_ENV="${REVOLT_CONFIG}/.env"
SUMMARY_FILE="/root/revolt-install-summary.txt"

MINIO_ROOT="/opt/minio"
MINIO_DATA="${MINIO_ROOT}/data"

OS_FAMILY=""
PKG_MANAGER=""
PRETTY_NAME=""

REVOLT_DOMAIN=""
REVOLT_API_URL=""
REVOLT_APP_URL=""
REVOLT_EXTERNAL_WS_URL=""
REVOLT_EXTERNAL_API_URL=""

RABBITMQ_USERNAME=""
RABBITMQ_PASSWORD=""
RABBITMQ_URI=""
MONGODB_URI=""
REDIS_URI=""
MINIO_ROOT_USER=""
MINIO_ROOT_PASSWORD=""
MINIO_ENDPOINT=""
VAPID_PRIVATE_KEY=""
VAPID_PUBLIC_KEY=""

INSTALL_NGINX="false"
USE_LETSENCRYPT="false"
LETSENCRYPT_EMAIL=""
CONFIGURE_FIREWALL="false"
INSTALL_FAIL2BAN="false"
CREATE_ADMIN_ACCOUNT="false"
ADMIN_EMAIL=""
ADMIN_USERNAME=""
ADMIN_PASSWORD=""
SSH_ALLOWED_CIDR="any"

TLS_CERT_FILE=""
TLS_KEY_FILE=""

# Revolt repository URLs
REVOLT_BACKEND_REPO="https://github.com/revoltchat/backend.git"
REVOLT_FRONTEND_REPO="https://github.com/revoltchat/frontend.git"
REVOLT_BACKEND_BRANCH="master"
REVOLT_FRONTEND_BRANCH="master"

# Optional automation overrides
FORCE_INSTALL_NGINX="${REVOLT_FORCE_INSTALL_NGINX:-}"
FORCE_USE_LETSENCRYPT="${REVOLT_FORCE_USE_LETSENCRYPT:-}"
FORCE_CONFIGURE_FIREWALL="${REVOLT_FORCE_CONFIGURE_FIREWALL:-}"
FORCE_SSH_ALLOWED_CIDR="${REVOLT_FORCE_SSH_ALLOWED_CIDR:-}"

# Preferred defaults
PREFERRED_REVOLT_DOMAIN="${REVOLT_DEFAULT_DOMAIN:-revolt.local}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[ERROR] Please run this script as root." >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "[ERROR] systemd is required by this installer." >&2
  exit 1
fi

log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

gen_alnum() {
  local len="${1:-32}"
  local out=""
  while [[ "${#out}" -lt "$len" ]]; do
    if command_exists openssl; then
      out+=$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | awk -v L="$len" '{print substr($0,1,L)}')
    else
      out+=$(tr -dc 'A-Za-z0-9' </dev/urandom | awk -v L="$len" '{print substr($0,1,L)}')
    fi
  done
  printf '%s' "${out:0:len}"
}

gen_hex() {
  local len="${1:-32}"
  if command_exists openssl; then
    openssl rand -hex "$len" | head -c "$((len*2))"
  else
    tr -dc 'a-f0-9' </dev/urandom | head -c "$((len*2))"
  fi
}

pick_nologin_shell() {
  if [[ -x /usr/sbin/nologin ]]; then
    printf '/usr/sbin/nologin'
  elif [[ -x /sbin/nologin ]]; then
    printf '/sbin/nologin'
  else
    printf '/bin/false'
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local suffix="[Y/n]"
  local answer=""

  if [[ "${default,,}" == "n" ]]; then
    suffix="[y/N]"
  fi

  while true; do
    read -r -p "${prompt} ${suffix}: " answer || true
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "Please answer yes or no." ;;
    esac
  done
}

ask_text() {
  local prompt="$1"
  local default="${2:-}"
  local value=""
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " value || true
    value="${value:-$default}"
  else
    read -r -p "${prompt}: " value || true
  fi
  printf '%s' "$value"
}

ask_required_text() {
  local prompt="$1"
  local default="${2:-}"
  local value=""
  while true; do
    value="$(ask_text "$prompt" "$default")"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    warn "Value cannot be empty."
  done
}

detect_os() {
  if [[ ! -r /etc/os-release ]]; then
    die "Cannot detect OS: /etc/os-release is missing."
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  PRETTY_NAME="${PRETTY_NAME:-$ID}"

  case "${ID,,}" in
    debian|ubuntu)
      OS_FAMILY="debian"
      PKG_MANAGER="apt-get"
      export DEBIAN_FRONTEND=noninteractive
      ;;
    fedora)
      OS_FAMILY="fedora"
      PKG_MANAGER="dnf"
      ;;
    rhel|centos|rocky|almalinux|ol|oraclelinux)
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

pkg_update() {
  case "$OS_FAMILY" in
    debian)
      apt-get update -y
      ;;
    fedora|rhel)
      if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf makecache -y
      else
        yum makecache -y
      fi
      ;;
    *)
      die "Unknown OS family: $OS_FAMILY"
      ;;
  esac
}

pkg_install() {
  case "$OS_FAMILY" in
    debian)
      apt-get install -y "$@"
      ;;
    fedora|rhel)
      if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf install -y "$@"
      else
        yum install -y "$@"
      fi
      ;;
    *)
      die "Unknown OS family: $OS_FAMILY"
      ;;
  esac
}

configure_prompts() {
  local default_host default_ip
  default_host="$(hostname -f 2>/dev/null || hostname)"
  default_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  
  if [[ -z "$default_host" ]]; then
    default_host="${default_ip:-revolt.local}"
  fi

  printf "\n╔════════════════════════════════════════════════════════════╗\n"
  printf "║       Revolt Native Installer v%s (No Docker)        ║\n" "$SCRIPT_VERSION"
  printf "╚════════════════════════════════════════════════════════════╝\n"
  printf "Detected OS: %s\n" "$PRETTY_NAME"
  if [[ -n "$default_ip" ]]; then
    printf "Server IP: %s\n" "$default_ip"
  fi
  printf "\n"

  printf "═══ Domain Configuration ═══\n"
  REVOLT_DOMAIN="$(ask_required_text "Revolt domain or IP (e.g., revolt.example.com or ${default_ip})" "${PREFERRED_REVOLT_DOMAIN:-$default_host}")"

  printf "\n═══ Database & Services Configuration ═══\n"
  RABBITMQ_USERNAME="$(ask_required_text "RabbitMQ username" "rabbituser")"
  local rabbit_pass_prompt
  rabbit_pass_prompt="$(ask_text "RabbitMQ password (leave empty to auto-generate)" "")"
  RABBITMQ_PASSWORD="${rabbit_pass_prompt:-$(gen_alnum 32)}"
  RABBITMQ_URI="amqp://${RABBITMQ_USERNAME}:${RABBITMQ_PASSWORD}@127.0.0.1:5672/"

  MINIO_ROOT_USER="$(ask_required_text "MinIO root user" "minio")"
  local minio_pass_prompt
  minio_pass_prompt="$(ask_text "MinIO root password (leave empty to auto-generate)" "")"
  MINIO_ROOT_PASSWORD="${minio_pass_prompt:-$(gen_alnum 32)}"

  MONGODB_URI="mongodb://127.0.0.1:27017/revolt"
  REDIS_URI="redis://127.0.0.1:6379/"
  MINIO_ENDPOINT="http://127.0.0.1:9000"

  printf "\n═══ Web Server & TLS Configuration ═══\n"
  if [[ -n "$FORCE_INSTALL_NGINX" ]]; then
    case "${FORCE_INSTALL_NGINX,,}" in
      1|true|yes|y)
        INSTALL_NGINX="true"
        log "Nginx install forced by REVOLT_FORCE_INSTALL_NGINX=${FORCE_INSTALL_NGINX}"
        ;;
      0|false|no|n)
        INSTALL_NGINX="false"
        USE_LETSENCRYPT="false"
        log "Nginx install forced OFF by REVOLT_FORCE_INSTALL_NGINX=${FORCE_INSTALL_NGINX}"
        ;;
      *)
        die "Invalid REVOLT_FORCE_INSTALL_NGINX value: ${FORCE_INSTALL_NGINX} (use true/false)"
        ;;
    esac
  elif ask_yes_no "Install and configure Nginx reverse proxy + TLS?" "y"; then
    INSTALL_NGINX="true"
  fi

  if [[ "$INSTALL_NGINX" == "true" ]]; then
    if [[ -n "$FORCE_USE_LETSENCRYPT" ]]; then
      case "${FORCE_USE_LETSENCRYPT,,}" in
        1|true|yes|y)
          USE_LETSENCRYPT="true"
          log "Let's Encrypt forced ON by REVOLT_FORCE_USE_LETSENCRYPT=${FORCE_USE_LETSENCRYPT}"
          ;;
        0|false|no|n)
          USE_LETSENCRYPT="false"
          log "Let's Encrypt forced OFF by REVOLT_FORCE_USE_LETSENCRYPT=${FORCE_USE_LETSENCRYPT}"
          ;;
        *)
          die "Invalid REVOLT_FORCE_USE_LETSENCRYPT value: ${FORCE_USE_LETSENCRYPT} (use true/false)"
          ;;
      esac
    elif ask_yes_no "Use Let's Encrypt certificate (requires working public DNS + port 80)?" "n"; then
      USE_LETSENCRYPT="true"
    fi

    if [[ "$USE_LETSENCRYPT" == "true" ]]; then
      LETSENCRYPT_EMAIL="$(ask_required_text "Let's Encrypt email" "admin@${REVOLT_DOMAIN}")"
    fi
  fi

  printf "\n═══ Security Configuration ═══\n"
  if [[ -n "$FORCE_CONFIGURE_FIREWALL" ]]; then
    case "${FORCE_CONFIGURE_FIREWALL,,}" in
      1|true|yes|y)
        CONFIGURE_FIREWALL="true"
        if [[ -n "$FORCE_SSH_ALLOWED_CIDR" ]]; then
          SSH_ALLOWED_CIDR="$FORCE_SSH_ALLOWED_CIDR"
        else
          SSH_ALLOWED_CIDR="any"
        fi
        log "Firewall config forced ON by REVOLT_FORCE_CONFIGURE_FIREWALL=${FORCE_CONFIGURE_FIREWALL}"
        ;;
      0|false|no|n)
        CONFIGURE_FIREWALL="false"
        log "Firewall config forced OFF by REVOLT_FORCE_CONFIGURE_FIREWALL=${FORCE_CONFIGURE_FIREWALL}"
        ;;
      *)
        die "Invalid REVOLT_FORCE_CONFIGURE_FIREWALL value: ${FORCE_CONFIGURE_FIREWALL} (use true/false)"
        ;;
    esac
  elif ask_yes_no "Configure firewall automatically?" "y"; then
    CONFIGURE_FIREWALL="true"
    SSH_ALLOWED_CIDR="$(ask_text "Allow SSH from CIDR (or 'any')" "any")"
  fi

  if ask_yes_no "Install fail2ban hardening?" "y"; then
    INSTALL_FAIL2BAN="true"
  fi

  printf "\n═══ Admin Account Setup ═══\n"
  if ask_yes_no "Create a Revolt admin account now?" "y"; then
    CREATE_ADMIN_ACCOUNT="true"
    ADMIN_USERNAME="$(ask_required_text "Admin username" "admin")"
    ADMIN_EMAIL="$(ask_required_text "Admin email" "admin@${REVOLT_DOMAIN}")"
    local admin_pass_input
    admin_pass_input="$(ask_text "Admin password (leave empty to auto-generate)" "")"
    ADMIN_PASSWORD="${admin_pass_input:-$(gen_alnum 24)}"
  fi

  # Set URLs based on Nginx configuration
  if [[ "$INSTALL_NGINX" == "true" ]]; then
    REVOLT_API_URL="https://${REVOLT_DOMAIN}/api"
    REVOLT_APP_URL="https://${REVOLT_DOMAIN}"
    REVOLT_EXTERNAL_WS_URL="wss://${REVOLT_DOMAIN}/ws"
    REVOLT_EXTERNAL_API_URL="https://${REVOLT_DOMAIN}/api"
  else
    REVOLT_API_URL="http://${REVOLT_DOMAIN}:8000"
    REVOLT_APP_URL="http://${REVOLT_DOMAIN}:3000"
    REVOLT_EXTERNAL_WS_URL="ws://${REVOLT_DOMAIN}:9000"
    REVOLT_EXTERNAL_API_URL="http://${REVOLT_DOMAIN}:8000"
  fi

  # Generate VAPID keys (required for push notifications)
  log "Generating VAPID keys for push notifications..."
  VAPID_PRIVATE_KEY="$(gen_hex 32)"
  VAPID_PUBLIC_KEY="$(gen_hex 32)"
}

install_system_packages() {
  log "Installing base dependencies..."
  pkg_update

  if [[ "$OS_FAMILY" == "debian" ]]; then
    pkg_install \
      ca-certificates curl gnupg2 jq openssl sudo lsb-release git \
      build-essential pkg-config libssl-dev wget
  else
    pkg_install \
      ca-certificates curl gnupg2 jq openssl sudo git \
      gcc gcc-c++ make openssl-devel wget
  fi

  if [[ "$INSTALL_NGINX" == "true" ]]; then
    pkg_install nginx
    if [[ "$USE_LETSENCRYPT" == "true" ]]; then
      pkg_install certbot
    fi
  fi

  if [[ "$CONFIGURE_FIREWALL" == "true" ]]; then
    if [[ "$OS_FAMILY" == "debian" ]]; then
      pkg_install ufw
    else
      pkg_install firewalld
    fi
  fi

  if [[ "$INSTALL_FAIL2BAN" == "true" ]]; then
    if [[ "$OS_FAMILY" == "debian" ]]; then
      pkg_install fail2ban
    else
      # RHEL/Fedora family - fail2ban requires EPEL
      log "Installing EPEL repository for fail2ban..."
      if [[ "$OS_FAMILY" == "fedora" ]]; then
        pkg_install fail2ban || warn "fail2ban installation failed - skipping"
      else
        if ! pkg_install epel-release 2>/dev/null; then
          warn "EPEL repository not available, trying to install from URL..."
          if [[ "$PKG_MANAGER" == "dnf" ]]; then
            dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm" 2>/dev/null || warn "Could not install EPEL"
          else
            yum install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm" 2>/dev/null || warn "Could not install EPEL"
          fi
        fi
        pkg_install fail2ban || {
          warn "fail2ban installation failed - this is optional, continuing without it"
          INSTALL_FAIL2BAN="false"
        }
      fi
    fi
  fi
}

install_mongodb() {
  log "Installing MongoDB..."
  
  if [[ "$OS_FAMILY" == "debian" ]]; then
    # Import MongoDB GPG key
    curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | \
      gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg

    # Add MongoDB repository
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/7.0 multiverse" | \
      tee /etc/apt/sources.list.d/mongodb-org-7.0.list

    pkg_update
    pkg_install mongodb-org
  else
    # RHEL/Fedora family
    # MongoDB may not support the latest RHEL versions yet, so we use compatibility mode
    local rhel_version
    rhel_version=$(rpm -E %rhel 2>/dev/null || echo "9")
    
    # For RHEL 10+, use RHEL 9 repository (compatible)
    if [[ "$rhel_version" -ge 10 ]]; then
      warn "Rocky/RHEL ${rhel_version} detected - using RHEL 9 repository for MongoDB (compatible)"
      rhel_version="9"
    fi
    
    cat >/etc/yum.repos.d/mongodb-org-7.0.repo <<EOF
[mongodb-org-7.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/${rhel_version}/mongodb-org/7.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-7.0.asc
EOF
    
    pkg_install mongodb-org
  fi

  # Enable and start MongoDB
  systemctl enable mongod
  systemctl start mongod
  
  # Wait for MongoDB to start
  local i
  for i in {1..30}; do
    if mongosh --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
      log "MongoDB is ready!"
      return 0
    fi
    sleep 1
  done
  
  die "MongoDB failed to start"
}

install_redis() {
  log "Installing Redis..."
  
  if [[ "$OS_FAMILY" == "debian" ]]; then
    pkg_install redis-server
    systemctl enable --now redis-server
  else
    pkg_install redis
    systemctl enable --now redis
  fi
  
  # Test Redis
  if ! redis-cli ping >/dev/null 2>&1; then
    die "Redis failed to start"
  fi
  
  log "Redis is ready!"
}

install_rabbitmq() {
  log "Installing RabbitMQ..."
  
  if [[ "$OS_FAMILY" == "debian" ]]; then
    # Import RabbitMQ signing key
    curl -fsSL https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc | \
      gpg --dearmor -o /usr/share/keyrings/rabbitmq.gpg

    # Add RabbitMQ repository
    echo "deb [signed-by=/usr/share/keyrings/rabbitmq.gpg] https://ppa1.novemberain.com/rabbitmq/rabbitmq-server/deb/ubuntu $(lsb_release -cs) main" | \
      tee /etc/apt/sources.list.d/rabbitmq.list

    pkg_update
    pkg_install rabbitmq-server
  else
    # RHEL/Fedora family - use EPEL or direct package
    if ! pkg_install rabbitmq-server 2>/dev/null; then
      warn "RabbitMQ not in standard repos, installing from EPEL/RabbitMQ repo..."
      
      # Try PackageCloud repository
      curl -s https://packagecloud.io/install/repositories/rabbitmq/rabbitmq-server/script.rpm.sh | bash
      pkg_install rabbitmq-server || {
        # Fallback to Erlang + RabbitMQ manual install
        pkg_install erlang
        local rmq_rpm="rabbitmq-server-3.12.13-1.el9.noarch.rpm"
        wget "https://github.com/rabbitmq/rabbitmq-server/releases/download/v3.12.13/${rmq_rpm}"
        rpm -Uvh "$rmq_rpm" || yum localinstall -y "$rmq_rpm"
        rm -f "$rmq_rpm"
      }
    fi
  fi

  systemctl enable rabbitmq-server
  systemctl start rabbitmq-server
  
  # Wait for RabbitMQ to start
  local i
  for i in {1..40}; do
    if rabbitmqctl status >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  # Create RabbitMQ user
  log "Configuring RabbitMQ user: ${RABBITMQ_USERNAME}"
  rabbitmqctl delete_user guest 2>/dev/null || true
  rabbitmqctl add_user "$RABBITMQ_USERNAME" "$RABBITMQ_PASSWORD" 2>/dev/null || \
    rabbitmqctl change_password "$RABBITMQ_USERNAME" "$RABBITMQ_PASSWORD"
  rabbitmqctl set_user_tags "$RABBITMQ_USERNAME" administrator
  rabbitmqctl set_permissions -p / "$RABBITMQ_USERNAME" ".*" ".*" ".*"
  
  log "RabbitMQ is ready!"
}

install_minio() {
  log "Installing MinIO..."
  
  local minio_binary="/usr/local/bin/minio"
  
  # Download MinIO binary
  wget -q https://dl.min.io/server/minio/release/linux-amd64/minio -O "$minio_binary"
  chmod +x "$minio_binary"
  
  # Create MinIO user
  local nologin_shell
  nologin_shell="$(pick_nologin_shell)"
  
  if ! id -u minio >/dev/null 2>&1; then
    useradd \
      --system \
      --user-group \
      --home-dir "$MINIO_ROOT" \
      --create-home \
      --shell "$nologin_shell" \
      minio
  fi
  
  # Create directories
  mkdir -p "$MINIO_DATA"
  chown -R minio:minio "$MINIO_ROOT" "$MINIO_DATA"
  
  # Create MinIO systemd service
  cat >/etc/systemd/system/minio.service <<EOF
[Unit]
Description=MinIO Object Storage
Documentation=https://min.io/docs/minio/linux/index.html
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=minio
Group=minio
Environment="MINIO_ROOT_USER=${MINIO_ROOT_USER}"
Environment="MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}"
ExecStart=/usr/local/bin/minio server ${MINIO_DATA} --console-address ":9001" --address ":9000"
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now minio
  
  # Wait for MinIO to start
  local i
  for i in {1..30}; do
    if curl -fsS http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1; then
      log "MinIO is ready!"
      break
    fi
    sleep 1
  done
  
  # Install MinIO Client (mc)
  wget -q https://dl.min.io/client/mc/release/linux-amd64/mc -O /usr/local/bin/mc
  chmod +x /usr/local/bin/mc
  
  # Configure MinIO and create bucket
  sleep 2
  mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1
  mc mb --ignore-existing local/revolt-files >/dev/null 2>&1 || true
  mc anonymous set download local/revolt-files >/dev/null 2>&1 || true
  
  log "MinIO bucket 'revolt-files' created!"
}

install_rust() {
  log "Installing Rust toolchain..."
  
  if ! command_exists rustc; then
    # Install Rust using rustup
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    source "$HOME/.cargo/env"
  fi
  
  # Ensure cargo is in PATH
  export PATH="$HOME/.cargo/bin:$PATH"
  
  log "Rust installed: $(rustc --version)"
}

install_nodejs() {
  log "Installing Node.js..."
  
  if ! command_exists node; then
    if [[ "$OS_FAMILY" == "debian" ]]; then
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
      pkg_install nodejs
    else
      curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
      pkg_install nodejs
    fi
  fi
  
  # Install pnpm
  if ! command_exists pnpm; then
    npm install -g pnpm
  fi
  
  log "Node.js installed: $(node --version)"
  log "pnpm installed: $(pnpm --version)"
}

create_revolt_user_and_dirs() {
  local nologin_shell
  nologin_shell="$(pick_nologin_shell)"

  if ! id -u "$REVOLT_USER" >/dev/null 2>&1; then
    useradd \
      --system \
      --user-group \
      --home-dir "$REVOLT_ROOT" \
      --create-home \
      --shell "$nologin_shell" \
      "$REVOLT_USER"
  fi
  REVOLT_GROUP="$(id -gn "$REVOLT_USER")"

  mkdir -p "$REVOLT_ROOT" "$REVOLT_BUILD" "$REVOLT_DATA" "$REVOLT_CONFIG" "$REVOLT_LOG"
  chown -R "$REVOLT_USER:$REVOLT_GROUP" "$REVOLT_ROOT" "$REVOLT_DATA" "$REVOLT_CONFIG" "$REVOLT_LOG"
  chmod 750 "$REVOLT_ROOT" "$REVOLT_DATA" "$REVOLT_CONFIG" "$REVOLT_LOG"
}

write_revolt_env() {
  log "Writing Revolt environment configuration..."
  
  cat >"$REVOLT_ENV" <<EOF
# Revolt Configuration
# Generated on $(date)

# Domain Configuration
REVOLT_PUBLIC_URL=${REVOLT_APP_URL}
REVOLT_API_URL=${REVOLT_API_URL}
REVOLT_APP_URL=${REVOLT_APP_URL}
VITE_API_URL=${REVOLT_EXTERNAL_API_URL}

# RabbitMQ Configuration
RABBITMQ_URI=${RABBITMQ_URI}

# Database Configuration
MONGODB_URI=${MONGODB_URI}
REDIS_URI=${REDIS_URI}

# MinIO Configuration (File Storage)
AWS_ACCESS_KEY_ID=${MINIO_ROOT_USER}
AWS_SECRET_ACCESS_KEY=${MINIO_ROOT_PASSWORD}
AWS_REGION=revolt
AWS_S3_BUCKET_NAME=revolt-files
AWS_ENDPOINT=${MINIO_ENDPOINT}

# VAPID Keys (Push Notifications)
VAPID_PRIVATE_KEY=${VAPID_PRIVATE_KEY}
VAPID_PUBLIC_KEY=${VAPID_PUBLIC_KEY}

# Security
REVOLT_UNSAFE_NO_EMAIL=true

# Logging
RUST_LOG=info
EOF

  chown "$REVOLT_USER:$REVOLT_GROUP" "$REVOLT_ENV"
  chmod 640 "$REVOLT_ENV"
}

build_revolt_backend() {
  log "Building Revolt backend (this may take 10-30 minutes)..."
  
  cd "$REVOLT_BUILD"
  
  # Clone backend repository
  if [[ ! -d "backend" ]]; then
    runuser -u "$REVOLT_USER" -- git clone "$REVOLT_BACKEND_REPO" backend
  fi
  
  cd backend
  runuser -u "$REVOLT_USER" -- git checkout "$REVOLT_BACKEND_BRANCH"
  runuser -u "$REVOLT_USER" -- git pull
  
  # Build backend services with Rust
  log "Building API server..."
  runuser -u "$REVOLT_USER" -- bash -c "source $HOME/.cargo/env && cargo build --release --bin revolt-delta"
  
  log "Building Events server..."
  runuser -u "$REVOLT_USER" -- bash -c "source $HOME/.cargo/env && cargo build --release --bin revolt-bonfire"
  
  log "Building Push daemon..."
  runuser -u "$REVOLT_USER" -- bash -c "source $HOME/.cargo/env && cargo build --release --bin revolt-pushd"
  
  # Copy binaries
  cp target/release/revolt-delta "$REVOLT_ROOT/revolt-api"
  cp target/release/revolt-bonfire "$REVOLT_ROOT/revolt-events"
  cp target/release/revolt-pushd "$REVOLT_ROOT/revolt-pushd"
  
  chown "$REVOLT_USER:$REVOLT_GROUP" "$REVOLT_ROOT"/revolt-*
  chmod 755 "$REVOLT_ROOT"/revolt-*
  
  log "Backend built successfully!"
}

build_revolt_frontend() {
  log "Building Revolt frontend..."
  
  cd "$REVOLT_BUILD"
  
  # Clone frontend repository
  if [[ ! -d "frontend" ]]; then
    runuser -u "$REVOLT_USER" -- git clone "$REVOLT_FRONTEND_REPO" frontend
  fi
  
  cd frontend
  runuser -u "$REVOLT_USER" -- git checkout "$REVOLT_FRONTEND_BRANCH"
  runuser -u "$REVOLT_USER" -- git pull
  
  # Install dependencies and build
  log "Installing frontend dependencies..."
  runuser -u "$REVOLT_USER" -- pnpm install
  
  log "Building frontend application..."
  runuser -u "$REVOLT_USER" -- bash -c "source ${REVOLT_ENV} && pnpm run build:web"
  
  # Copy built files
  mkdir -p "$REVOLT_ROOT/web"
  cp -r dist/* "$REVOLT_ROOT/web/"
  chown -R "$REVOLT_USER:$REVOLT_GROUP" "$REVOLT_ROOT/web"
  
  log "Frontend built successfully!"
}

create_systemd_services() {
  log "Creating systemd services..."
  
  # API Service
  cat >/etc/systemd/system/revolt-api.service <<EOF
[Unit]
Description=Revolt API Server (Delta)
After=network-online.target mongod.service redis.service rabbitmq-server.service
Wants=network-online.target

[Service]
Type=simple
User=${REVOLT_USER}
Group=${REVOLT_GROUP}
WorkingDirectory=${REVOLT_ROOT}
EnvironmentFile=${REVOLT_ENV}
ExecStart=${REVOLT_ROOT}/revolt-api
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  # Events Service
  cat >/etc/systemd/system/revolt-events.service <<EOF
[Unit]
Description=Revolt Events Server (Bonfire)
After=network-online.target rabbitmq-server.service
Wants=network-online.target

[Service]
Type=simple
User=${REVOLT_USER}
Group=${REVOLT_GROUP}
WorkingDirectory=${REVOLT_ROOT}
EnvironmentFile=${REVOLT_ENV}
ExecStart=${REVOLT_ROOT}/revolt-events
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  # Push Daemon Service
  cat >/etc/systemd/system/revolt-pushd.service <<EOF
[Unit]
Description=Revolt Push Notifications Daemon
After=network-online.target rabbitmq-server.service
Wants=network-online.target

[Service]
Type=simple
User=${REVOLT_USER}
Group=${REVOLT_GROUP}
WorkingDirectory=${REVOLT_ROOT}
EnvironmentFile=${REVOLT_ENV}
ExecStart=${REVOLT_ROOT}/revolt-pushd
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  # Web Server Service (using Python's http.server for simplicity)
  cat >/etc/systemd/system/revolt-web.service <<EOF
[Unit]
Description=Revolt Web Client Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${REVOLT_USER}
Group=${REVOLT_GROUP}
WorkingDirectory=${REVOLT_ROOT}/web
ExecStart=/usr/bin/python3 -m http.server 3000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable revolt-api revolt-events revolt-pushd revolt-web
  systemctl start revolt-api revolt-events revolt-pushd revolt-web
  
  log "Revolt services started!"
}

wait_for_revolt_api() {
  log "Waiting for Revolt API to become ready..."
  local i
  local api_url="http://127.0.0.1:8000"
  
  for i in {1..60}; do
    if curl -fsS "${api_url}/" >/dev/null 2>&1; then
      log "Revolt API is ready!"
      return 0
    fi
    sleep 2
  done
  
  warn "Revolt API did not become ready in time, but continuing..."
  return 1
}

create_admin_account() {
  if [[ "$CREATE_ADMIN_ACCOUNT" != "true" ]]; then
    return 0
  fi

  log "Creating Revolt admin account..."
  
  if ! wait_for_revolt_api; then
    warn "Could not verify API is ready. Admin account creation may fail."
  fi

  local api_url="http://127.0.0.1:8000"
  local signup_response
  local user_id
  
  # Create account via API
  signup_response=$(curl -fsS -X POST "${api_url}/auth/account/create" \
    -H "Content-Type: application/json" \
    -d "{
      \"email\": \"${ADMIN_EMAIL}\",
      \"password\": \"${ADMIN_PASSWORD}\",
      \"captcha\": null
    }" 2>/dev/null)
  
  if [[ $? -eq 0 ]] && [[ -n "$signup_response" ]]; then
    log "Admin account created successfully!"
    
    user_id=$(echo "$signup_response" | jq -r '._id // .id // empty' 2>/dev/null)
    
    if [[ -n "$user_id" ]]; then
      log "Admin User ID: ${user_id}"
      
      # Grant admin privileges via MongoDB
      mongosh revolt --eval "db.users.updateOne({_id: '${user_id}'}, {\$set: {privileged: true, badges: 1}})" >/dev/null 2>&1 && \
        log "Admin privileges granted to user: ${ADMIN_USERNAME}" || \
        warn "Could not grant admin privileges automatically."
    fi
  else
    warn "Failed to create admin account via API."
    warn "You can create it manually after installation."
  fi
}

create_self_signed_cert() {
  local cert_dir="$1"
  local cert_name="$2"
  mkdir -p "$cert_dir"

  TLS_CERT_FILE="${cert_dir}/${cert_name}.crt"
  TLS_KEY_FILE="${cert_dir}/${cert_name}.key"

  if [[ ! -f "$TLS_CERT_FILE" || ! -f "$TLS_KEY_FILE" ]]; then
    log "Generating self-signed TLS certificate for ${REVOLT_DOMAIN}..."
    if ! openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
      -keyout "$TLS_KEY_FILE" \
      -out "$TLS_CERT_FILE" \
      -subj "/CN=${REVOLT_DOMAIN}" \
      -addext "subjectAltName=DNS:${REVOLT_DOMAIN}" >/dev/null 2>&1; then
      openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
        -keyout "$TLS_KEY_FILE" \
        -out "$TLS_CERT_FILE" \
        -subj "/CN=${REVOLT_DOMAIN}" >/dev/null 2>&1
    fi
    chmod 640 "$TLS_KEY_FILE"
    chmod 644 "$TLS_CERT_FILE"
  fi
}

configure_nginx() {
  log "Configuring Nginx reverse proxy..."
  mkdir -p /etc/nginx/conf.d /var/www/certbot
  rm -f /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default

  # Bootstrap HTTP config first
  cat >/etc/nginx/conf.d/revolt-bootstrap.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${REVOLT_DOMAIN} _;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx

  if [[ "$USE_LETSENCRYPT" == "true" ]]; then
    log "Requesting Let's Encrypt certificate for ${REVOLT_DOMAIN}..."
    if certbot certonly \
      --webroot \
      -w /var/www/certbot \
      -d "$REVOLT_DOMAIN" \
      --email "$LETSENCRYPT_EMAIL" \
      --agree-tos \
      --non-interactive; then
      TLS_CERT_FILE="/etc/letsencrypt/live/${REVOLT_DOMAIN}/fullchain.pem"
      TLS_KEY_FILE="/etc/letsencrypt/live/${REVOLT_DOMAIN}/privkey.pem"
    else
      warn "Let's Encrypt issuance failed. Falling back to self-signed certificate."
      create_self_signed_cert "/etc/ssl/revolt" "revolt"
    fi
  else
    create_self_signed_cert "/etc/ssl/revolt" "revolt"
  fi

  rm -f /etc/nginx/conf.d/revolt-bootstrap.conf

  cat >/etc/nginx/conf.d/revolt.conf <<EOF
# Revolt reverse proxy

server {
    listen 80;
    listen [::]:80;
    server_name ${REVOLT_DOMAIN} _;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${REVOLT_DOMAIN} _;

    ssl_certificate ${TLS_CERT_FILE};
    ssl_certificate_key ${TLS_KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 100M;

    # WebSocket for events
    location /ws {
        proxy_pass http://127.0.0.1:9000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }

    # API endpoints
    location /api {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_read_timeout 600s;
    }

    # Web client
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  nginx -t
  systemctl reload nginx
}

configure_fail2ban() {
  log "Configuring fail2ban..."
  mkdir -p /etc/fail2ban/jail.d
  cat >/etc/fail2ban/jail.d/revolt.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 6

[sshd]
enabled = true
EOF

  if [[ "$INSTALL_NGINX" == "true" ]]; then
    cat >>/etc/fail2ban/jail.d/revolt.local <<EOF

[nginx-http-auth]
enabled = true
EOF
  fi

  systemctl enable --now fail2ban
}

configure_ufw() {
  log "Applying UFW rules..."
  ufw default deny incoming
  ufw default allow outgoing

  if [[ "${SSH_ALLOWED_CIDR,,}" == "any" || "${SSH_ALLOWED_CIDR,,}" == "y" || "${SSH_ALLOWED_CIDR,,}" == "yes" ]]; then
    ufw allow 22/tcp comment 'SSH'
  else
    ufw allow from "$SSH_ALLOWED_CIDR" to any port 22 proto tcp comment 'SSH restricted'
  fi

  if [[ "$INSTALL_NGINX" == "true" ]]; then
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
  else
    ufw allow 3000/tcp comment 'Revolt Web'
    ufw allow 8000/tcp comment 'Revolt API'
    ufw allow 9000/tcp comment 'Revolt WebSocket'
  fi

  ufw --force enable
}

configure_firewalld() {
  log "Applying firewalld rules..."
  systemctl enable --now firewalld

  if [[ "${SSH_ALLOWED_CIDR,,}" == "any" || "${SSH_ALLOWED_CIDR,,}" == "y" || "${SSH_ALLOWED_CIDR,,}" == "yes" ]]; then
    firewall-cmd --permanent --add-service=ssh
  else
    firewall-cmd --permanent --remove-service=ssh >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${SSH_ALLOWED_CIDR}' port protocol='tcp' port='22' accept"
  fi

  if [[ "$INSTALL_NGINX" == "true" ]]; then
    firewall-cmd --permanent --add-port=80/tcp
    firewall-cmd --permanent --add-port=443/tcp
  else
    firewall-cmd --permanent --add-port=3000/tcp
    firewall-cmd --permanent --add-port=8000/tcp
    firewall-cmd --permanent --add-port=9000/tcp
  fi

  firewall-cmd --reload
}

configure_firewall_rules() {
  if [[ "$CONFIGURE_FIREWALL" != "true" ]]; then
    return 0
  fi

  if [[ "$OS_FAMILY" == "debian" ]]; then
    configure_ufw
  else
    configure_firewalld
  fi
}

write_summary() {
  cat >"$SUMMARY_FILE" <<EOF
Revolt Native Installation Summary
===================================
Date: $(date)
OS: ${PRETTY_NAME}
Installation Type: Native (No Docker)

Domain: ${REVOLT_DOMAIN}
Web URL: ${REVOLT_APP_URL}
API URL: ${REVOLT_API_URL}
WebSocket URL: ${REVOLT_EXTERNAL_WS_URL}

RabbitMQ Configuration
----------------------
Username: ${RABBITMQ_USERNAME}
Password: ${RABBITMQ_PASSWORD}
URI: ${RABBITMQ_URI}

MinIO Configuration
-------------------
Root User: ${MINIO_ROOT_USER}
Root Password: ${MINIO_ROOT_PASSWORD}
Endpoint: ${MINIO_ENDPOINT}
Console: http://127.0.0.1:9001

Database Configuration
----------------------
MongoDB URI: ${MONGODB_URI}
Redis URI: ${REDIS_URI}

VAPID Keys (Push Notifications)
--------------------------------
Private Key: ${VAPID_PRIVATE_KEY}
Public Key: ${VAPID_PUBLIC_KEY}

Nginx Configuration
-------------------
Nginx installed: ${INSTALL_NGINX}
Let's Encrypt used: ${USE_LETSENCRYPT}
TLS certificate: ${TLS_CERT_FILE:-not-set}
TLS private key: ${TLS_KEY_FILE:-not-set}

Admin Account
-------------
Admin account created: ${CREATE_ADMIN_ACCOUNT}
Admin username: ${ADMIN_USERNAME:-not-created}
Admin email: ${ADMIN_EMAIL:-not-created}
Admin password: ${ADMIN_PASSWORD:-not-set}

Security Configuration
----------------------
Firewall configured: ${CONFIGURE_FIREWALL}
SSH source restriction: ${SSH_ALLOWED_CIDR}
fail2ban installed: ${INSTALL_FAIL2BAN}

Paths
-----
Installation root: ${REVOLT_ROOT}
Build directory: ${REVOLT_BUILD}
Data directory: ${REVOLT_DATA}
Configuration: ${REVOLT_CONFIG}
Logs: ${REVOLT_LOG}
Environment file: ${REVOLT_ENV}

Services
--------
revolt-api.service       - Revolt API Server (Delta)
revolt-events.service    - Revolt Events Server (Bonfire)
revolt-pushd.service     - Revolt Push Notifications Daemon
revolt-web.service       - Revolt Web Client Server
mongod.service           - MongoDB Database
redis.service            - Redis Cache
rabbitmq-server.service  - RabbitMQ Message Queue
minio.service            - MinIO Object Storage

Useful Commands
---------------
View API logs:     journalctl -u revolt-api -f
View Events logs:  journalctl -u revolt-events -f
View Push logs:    journalctl -u revolt-pushd -f
View Web logs:     journalctl -u revolt-web -f
Restart services:  systemctl restart revolt-{api,events,pushd,web}
Check status:      systemctl status revolt-{api,events,pushd,web}
Update backend:    cd ${REVOLT_BUILD}/backend && git pull && cargo build --release
Update frontend:   cd ${REVOLT_BUILD}/frontend && git pull && pnpm run build:web
EOF
  chmod 600 "$SUMMARY_FILE"
}

print_final_notes() {
  printf '\n'
  printf "╔════════════════════════════════════════════════════════════╗\n"
  printf "║     Installation Complete! 🎉 (Native Installation)       ║\n"
  printf "╚════════════════════════════════════════════════════════════╝\n\n"
  
  printf "📍 Access Information:\n"
  printf "  ├─ Revolt domain: %s\n" "$REVOLT_DOMAIN"
  printf "  ├─ Web interface: %s\n" "$REVOLT_APP_URL"
  printf "  └─ API endpoint:  %s\n\n" "$REVOLT_API_URL"
  
  if [[ "$CREATE_ADMIN_ACCOUNT" == "true" ]]; then
    printf "👤 Admin Account:\n"
    printf "  ├─ Username: %s\n" "$ADMIN_USERNAME"
    printf "  ├─ Email:    %s\n" "$ADMIN_EMAIL"
    printf "  └─ Password: %s\n\n" "$ADMIN_PASSWORD"
    printf "  ⚠️  Save these credentials securely!\n\n"
  fi
  
  if [[ "$INSTALL_NGINX" != "true" ]]; then
    printf "🔀 External Reverse Proxy Configuration:\n"
    local server_ip
    server_ip="$(hostname -I | awk '{print $1}')"
    printf "  Configure your reverse proxy to forward:\n"
    printf "    ├─ Web client:  -> http://%s:3000\n" "$server_ip"
    printf "    ├─ API:         -> http://%s:8000\n" "$server_ip"
    printf "    └─ WebSocket:   -> http://%s:9000\n\n" "$server_ip"
  fi
  
  printf "🔧 Services Status:\n"
  systemctl is-active --quiet revolt-api && printf "  ✓ revolt-api\n" || printf "  ✗ revolt-api\n"
  systemctl is-active --quiet revolt-events && printf "  ✓ revolt-events\n" || printf "  ✗ revolt-events\n"
  systemctl is-active --quiet revolt-pushd && printf "  ✓ revolt-pushd\n" || printf "  ✗ revolt-pushd\n"
  systemctl is-active --quiet revolt-web && printf "  ✓ revolt-web\n\n" || printf "  ✗ revolt-web\n\n"
  
  printf "📄 Full summary saved to: %s\n\n" "$SUMMARY_FILE"
  
  if [[ "$USE_LETSENCRYPT" != "true" && "$INSTALL_NGINX" == "true" ]]; then
    warn "Self-signed certificate is in use. You may see browser warnings."
  fi
}

main() {
  detect_os
  configure_prompts
  install_system_packages
  install_mongodb
  install_redis
  install_rabbitmq
  install_minio
  install_rust
  install_nodejs
  create_revolt_user_and_dirs
  write_revolt_env
  build_revolt_backend
  build_revolt_frontend
  create_systemd_services

  if [[ "$INSTALL_NGINX" == "true" ]]; then
    configure_nginx
  fi

  configure_firewall_rules

  if [[ "$INSTALL_FAIL2BAN" == "true" ]]; then
    configure_fail2ban
  fi

  create_admin_account
  write_summary
  print_final_notes
}

main "$@"
