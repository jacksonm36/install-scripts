#!/usr/bin/env bash
set -Eeuo pipefail

# Revolt interactive installer (multi-OS)
# - Debian/Ubuntu + Fedora/RHEL-family
# - Docker-based deployment with all required services
# - Optional components: Nginx + TLS, firewall rules, fail2ban
# - Services: MongoDB, RabbitMQ, Redis, MinIO, Revolt (API, Delta, Events, etc.)

SCRIPT_VERSION="1.0.0"

REVOLT_USER="revolt"
REVOLT_GROUP="revolt"
REVOLT_ROOT="/opt/revolt"
REVOLT_DATA="${REVOLT_ROOT}/data"
REVOLT_CONFIG="${REVOLT_ROOT}/.env"
SUMMARY_FILE="/root/revolt-install-summary.txt"

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
VAPID_PRIVATE_KEY=""
VAPID_PUBLIC_KEY=""

INSTALL_NGINX="false"
USE_LETSENCRYPT="false"
LETSENCRYPT_EMAIL=""
CONFIGURE_FIREWALL="false"
INSTALL_FAIL2BAN="false"
SSH_ALLOWED_CIDR="any"

TLS_CERT_FILE=""
TLS_KEY_FILE=""

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
  local default_host
  default_host="$(hostname -f 2>/dev/null || hostname)"
  if [[ -z "$default_host" ]]; then
    default_host="revolt.local"
  fi

  printf "\nRevolt interactive installer v%s\n" "$SCRIPT_VERSION"
  printf "Detected OS: %s\n\n" "$PRETTY_NAME"

  REVOLT_DOMAIN="$(ask_required_text "Revolt domain (e.g., revolt.example.com)" "${PREFERRED_REVOLT_DOMAIN:-$default_host}")"

  RABBITMQ_USERNAME="$(ask_required_text "RabbitMQ username" "rabbituser")"
  local rabbit_pass_prompt
  rabbit_pass_prompt="$(ask_text "RabbitMQ password (leave empty to auto-generate)" "")"
  RABBITMQ_PASSWORD="${rabbit_pass_prompt:-$(gen_alnum 32)}"
  RABBITMQ_URI="amqp://${RABBITMQ_USERNAME}:${RABBITMQ_PASSWORD}@rabbit:5672/"

  MINIO_ROOT_USER="$(ask_required_text "MinIO root user" "minio")"
  local minio_pass_prompt
  minio_pass_prompt="$(ask_text "MinIO root password (leave empty to auto-generate)" "")"
  MINIO_ROOT_PASSWORD="${minio_pass_prompt:-$(gen_alnum 32)}"

  MONGODB_URI="mongodb://database:27017/revolt"
  REDIS_URI="redis://redis:6379/"

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
      ca-certificates curl gnupg2 jq openssl sudo lsb-release git
  else
    pkg_install \
      ca-certificates curl gnupg2 jq openssl sudo git
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
    pkg_install fail2ban
  fi
}

install_docker() {
  log "Installing Docker and Docker Compose..."
  
  if command_exists docker; then
    log "Docker already installed: $(docker --version)"
  else
    if [[ "$OS_FAMILY" == "debian" ]]; then
      # Add Docker's official GPG key
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/${ID}/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc

      # Add the repository to Apt sources
      echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
      
      apt-get update -y
      pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      # RHEL/Fedora family
      if [[ "$OS_FAMILY" == "fedora" ]]; then
        dnf -y install dnf-plugins-core
        dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
      else
        yum install -y yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      fi
      
      pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    systemctl enable --now docker
  fi

  # Verify Docker Compose is available
  if ! docker compose version >/dev/null 2>&1; then
    die "Docker Compose plugin not available. Please install it manually."
  fi

  log "Docker installed: $(docker --version)"
  log "Docker Compose installed: $(docker compose version)"
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

  # Add revolt user to docker group
  usermod -aG docker "$REVOLT_USER" || true

  mkdir -p "$REVOLT_ROOT" "$REVOLT_DATA"
  chown -R "$REVOLT_USER:$REVOLT_GROUP" "$REVOLT_ROOT" "$REVOLT_DATA"
  chmod 750 "$REVOLT_ROOT" "$REVOLT_DATA"
}

write_revolt_env() {
  log "Writing Revolt environment configuration..."
  
  cat >"$REVOLT_CONFIG" <<EOF
# Revolt Configuration
# Generated on $(date)

# Domain Configuration
REVOLT_DOMAIN=${REVOLT_DOMAIN}
REVOLT_PUBLIC_URL=${REVOLT_APP_URL}
REVOLT_API_URL=${REVOLT_API_URL}
REVOLT_APP_URL=${REVOLT_APP_URL}
REVOLT_EXTERNAL_WS_URL=${REVOLT_EXTERNAL_WS_URL}

# RabbitMQ Configuration
RABBITMQ_USERNAME=${RABBITMQ_USERNAME}
RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD}
RABBITMQ_URI=${RABBITMQ_URI}

# Database Configuration
MONGODB_URI=${MONGODB_URI}
REDIS_URI=${REDIS_URI}

# MinIO Configuration (File Storage)
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
MINIO_ENDPOINT=http://minio:9000
S3_REGION=revolt
S3_BUCKET=revolt-files

# VAPID Keys (Push Notifications)
VAPID_PRIVATE_KEY=${VAPID_PRIVATE_KEY}
VAPID_PUBLIC_KEY=${VAPID_PUBLIC_KEY}

# Optional: App Configuration
# REVOLT_APP_NAME=Revolt
# REVOLT_SMTP_HOST=smtp.example.com
# REVOLT_SMTP_PORT=587
# REVOLT_SMTP_USERNAME=
# REVOLT_SMTP_PASSWORD=
# REVOLT_SMTP_FROM=noreply@${REVOLT_DOMAIN}

# Security
# Set to 'true' for production
REVOLT_UNSAFE_NO_EMAIL=true

# Logging
RUST_LOG=info
EOF

  chown "$REVOLT_USER:$REVOLT_GROUP" "$REVOLT_CONFIG"
  chmod 640 "$REVOLT_CONFIG"
}

write_docker_compose() {
  log "Writing Docker Compose configuration..."
  
  cat >"${REVOLT_ROOT}/docker-compose.yml" <<'EOF'
version: '3.8'

services:
  # MongoDB Database
  database:
    image: mongo:latest
    container_name: revolt-database
    restart: unless-stopped
    volumes:
      - mongodb_data:/data/db
    networks:
      - revolt-network
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s

  # Redis Cache
  redis:
    image: redis:7-alpine
    container_name: revolt-redis
    restart: unless-stopped
    volumes:
      - redis_data:/data
    networks:
      - revolt-network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  # RabbitMQ Message Queue
  rabbit:
    image: rabbitmq:4
    container_name: revolt-rabbit
    restart: unless-stopped
    environment:
      RABBITMQ_DEFAULT_USER: ${RABBITMQ_USERNAME}
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD}
    volumes:
      - rabbitmq_data:/var/lib/rabbitmq
    networks:
      - revolt-network
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s

  # MinIO S3-compatible Storage
  minio:
    image: minio/minio:latest
    container_name: revolt-minio
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    volumes:
      - minio_data:/data
    networks:
      - revolt-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s

  # MinIO bucket initialization
  createbuckets:
    image: minio/mc:latest
    container_name: revolt-minio-setup
    depends_on:
      minio:
        condition: service_healthy
    networks:
      - revolt-network
    entrypoint: >
      /bin/sh -c "
      /usr/bin/mc alias set myminio http://minio:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD};
      /usr/bin/mc mb --ignore-existing myminio/revolt-files;
      /usr/bin/mc anonymous set download myminio/revolt-files;
      exit 0;
      "

  # Revolt API (Delta)
  api:
    image: ghcr.io/revoltchat/server:latest
    container_name: revolt-api
    restart: unless-stopped
    env_file:
      - .env
    environment:
      RABBITMQ_URI: ${RABBITMQ_URI}
      MONGODB_URI: ${MONGODB_URI}
      REDIS_URI: ${REDIS_URI}
    depends_on:
      rabbit:
        condition: service_healthy
      database:
        condition: service_healthy
      redis:
        condition: service_healthy
    ports:
      - "8000:8000"
    networks:
      - revolt-network

  # Revolt Events WebSocket
  events:
    image: ghcr.io/revoltchat/bonfire:latest
    container_name: revolt-events
    restart: unless-stopped
    env_file:
      - .env
    environment:
      RABBITMQ_URI: ${RABBITMQ_URI}
    depends_on:
      rabbit:
        condition: service_healthy
    ports:
      - "9000:9000"
    networks:
      - revolt-network

  # Revolt Push Notifications Daemon
  pushd:
    image: ghcr.io/revoltchat/pushd:latest
    container_name: revolt-pushd
    restart: unless-stopped
    env_file:
      - .env
    environment:
      RABBITMQ_URI: ${RABBITMQ_URI}
      VAPID_PRIVATE_KEY: ${VAPID_PRIVATE_KEY}
      VAPID_PUBLIC_KEY: ${VAPID_PUBLIC_KEY}
    depends_on:
      rabbit:
        condition: service_healthy
    networks:
      - revolt-network

  # Revolt Web Client
  web:
    image: ghcr.io/revoltchat/client:latest
    container_name: revolt-web
    restart: unless-stopped
    environment:
      REVOLT_API_URL: ${REVOLT_EXTERNAL_API_URL}
      REVOLT_WS_URL: ${REVOLT_EXTERNAL_WS_URL}
    ports:
      - "3000:3000"
    networks:
      - revolt-network

networks:
  revolt-network:
    driver: bridge

volumes:
  mongodb_data:
    driver: local
  redis_data:
    driver: local
  rabbitmq_data:
    driver: local
  minio_data:
    driver: local
EOF

  chown "$REVOLT_USER:$REVOLT_GROUP" "${REVOLT_ROOT}/docker-compose.yml"
  chmod 644 "${REVOLT_ROOT}/docker-compose.yml"
}

start_revolt_services() {
  log "Starting Revolt services..."
  cd "$REVOLT_ROOT"
  
  # Pull images first
  runuser -u "$REVOLT_USER" -- docker compose pull
  
  # Start services
  runuser -u "$REVOLT_USER" -- docker compose up -d
  
  log "Waiting for services to start..."
  sleep 10
  
  # Check service status
  runuser -u "$REVOLT_USER" -- docker compose ps
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

  # Bootstrap HTTP config first (used for ACME challenge and initial startup).
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

# HTTP - redirect to HTTPS
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

# HTTPS - Main Revolt server
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
  systemctl enable --now nginx
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

  if [[ "${SSH_ALLOWED_CIDR,,}" == "any" ]]; then
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

  if [[ "${SSH_ALLOWED_CIDR,,}" == "any" ]]; then
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
    if ! command_exists ufw; then
      die "ufw is not installed."
    fi
    configure_ufw
  else
    if ! command_exists firewall-cmd; then
      die "firewalld is not installed."
    fi
    configure_firewalld
  fi
}

write_summary() {
  cat >"$SUMMARY_FILE" <<EOF
Revolt installation summary
===========================
Date: $(date)
OS: ${PRETTY_NAME}

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
Endpoint: http://localhost:9000 (internal)
Console: http://localhost:9001 (internal)

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

Security Configuration
----------------------
Firewall configured: ${CONFIGURE_FIREWALL}
SSH source restriction: ${SSH_ALLOWED_CIDR}
fail2ban installed: ${INSTALL_FAIL2BAN}

Paths
-----
Installation root: ${REVOLT_ROOT}
Data directory: ${REVOLT_DATA}
Configuration: ${REVOLT_CONFIG}
Docker Compose: ${REVOLT_ROOT}/docker-compose.yml

Useful Commands
---------------
View logs: cd ${REVOLT_ROOT} && docker compose logs -f
Restart services: cd ${REVOLT_ROOT} && docker compose restart
Stop services: cd ${REVOLT_ROOT} && docker compose down
Start services: cd ${REVOLT_ROOT} && docker compose up -d
Check status: cd ${REVOLT_ROOT} && docker compose ps
EOF
  chmod 600 "$SUMMARY_FILE"
}

print_final_notes() {
  printf '\n'
  log "Installation complete."
  printf "  - Revolt domain: %s\n" "$REVOLT_DOMAIN"
  printf "  - Web interface: %s\n" "$REVOLT_APP_URL"
  printf "  - API endpoint:  %s\n" "$REVOLT_API_URL"
  printf "\n"
  printf "  Access Revolt at: %s\n" "$REVOLT_APP_URL"
  printf "\n"
  printf "  Full summary saved to: %s\n\n" "$SUMMARY_FILE"
  
  if [[ "$USE_LETSENCRYPT" != "true" && "$INSTALL_NGINX" == "true" ]]; then
    warn "Self-signed certificate is in use. You may see browser warnings."
    warn "For production, consider using Let's Encrypt or a valid certificate."
  fi
}

main() {
  detect_os
  configure_prompts
  install_system_packages
  install_docker
  create_revolt_user_and_dirs
  write_revolt_env
  write_docker_compose
  start_revolt_services

  if [[ "$INSTALL_NGINX" == "true" ]]; then
    configure_nginx
  fi

  configure_firewall_rules

  if [[ "$INSTALL_FAIL2BAN" == "true" ]]; then
    configure_fail2ban
  fi

  write_summary
  print_final_notes
}

main "$@"
