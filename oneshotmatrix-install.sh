#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
DEFAULT_REPO_URL="https://github.com/loponai/oneshotmatrix.git"
DEFAULT_INSTALL_DIR="/opt/matrix-discord-killer"
DEFAULT_REPO_REF="main"

REPO_URL="${ONESHOTMATRIX_REPO_URL:-$DEFAULT_REPO_URL}"
INSTALL_DIR="${ONESHOTMATRIX_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
REPO_REF="${ONESHOTMATRIX_REF:-$DEFAULT_REPO_REF}"

SKIP_SETUP="false"
FORCE_RECLONE="false"
PANGOLIN_SSL_OFFLOAD="false"
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

Installs/updates loponai/oneshotmatrix and applies setup hotfixes.

Usage:
  sudo bash oneshotmatrix-install.sh [options]

Options:
  --install-dir <path>   Install path (default: ${DEFAULT_INSTALL_DIR})
  --repo-url <url>       Git repository URL (default: ${DEFAULT_REPO_URL})
  --repo-ref <ref>       Git ref to deploy (default: ${DEFAULT_REPO_REF})
  --pangolin-ssl-offload Configure for external TLS proxy (backend on :80)
  --skip-setup           Clone/update + patch only, do not run setup.sh
  --force-reclone        Remove existing install dir before cloning
  -h, --help             Show this help

Environment overrides:
  ONESHOTMATRIX_INSTALL_DIR
  ONESHOTMATRIX_REPO_URL
  ONESHOTMATRIX_REF
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
      --pangolin-ssl-offload)
        PANGOLIN_SSL_OFFLOAD="true"
        shift
        ;;
      --skip-setup)
        SKIP_SETUP="true"
        shift
        ;;
      --force-reclone)
        FORCE_RECLONE="true"
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

is_directory_empty() {
  local dir="$1"
  local entries=()
  shopt -s nullglob dotglob
  entries=("${dir}"/*)
  shopt -u nullglob dotglob
  [[ "${#entries[@]}" -eq 0 ]]
}

clone_or_update_repo() {
  if [[ "$FORCE_RECLONE" == "true" && -d "$INSTALL_DIR" ]]; then
    log "Removing existing install directory due to --force-reclone."
    rm -rf "$INSTALL_DIR"
  fi

  if [[ -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR" ]]; then
    die "Install path exists and is not a directory: ${INSTALL_DIR}"
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

  if [[ -d "$INSTALL_DIR" && ! -d "$INSTALL_DIR/.git" ]]; then
    if is_directory_empty "$INSTALL_DIR"; then
      log "Removing empty existing directory at ${INSTALL_DIR} before clone."
      rmdir "$INSTALL_DIR"
    else
      local backup_dir
      backup_dir="${INSTALL_DIR}.backup.$(date +%Y%m%d%H%M%S)"
      warn "Non-git directory exists at ${INSTALL_DIR}; moving it to ${backup_dir}"
      mv "$INSTALL_DIR" "$backup_dir" \
        || die "Failed to move existing directory. Use --force-reclone to remove it."
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

  log "Applying setup.sh hotfixes..."
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

if "compose_up_with_retries()" not in text:
    marker = "# ─── Pre-flight ──────────────────────────────────────────────────────"
    helper = """compose_up_with_retries() {
    # Retry image pulls/starts because GHCR/network timeouts are common on fresh VPSes.
    local attempt max_attempts delay
    max_attempts=5
    delay=5
    export COMPOSE_PARALLEL_LIMIT="${COMPOSE_PARALLEL_LIMIT:-4}"

    for attempt in $(seq 1 "$max_attempts"); do
        if docker compose "$@" up -d; then
            return 0
        fi

        if [ "$attempt" -lt "$max_attempts" ]; then
            echo -e "  ${YELLOW}Docker start failed (attempt ${attempt}/${max_attempts}); retrying in ${delay}s...${NC}"
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done
    return 1
}
"""
    if marker in text:
        text = text.replace(marker, helper + "\n" + marker, 1)
        changes.append("docker compose retry helper")

replace_once(
"""COMPOSE_EXIT=0
docker compose "${PROFILES[@]}" up -d 2>&1 || COMPOSE_EXIT=$?
if [ "$COMPOSE_EXIT" -ne 0 ]; then
    fail "Docker failed to start. Run 'cd $INSTALL_DIR && docker compose logs' to see what went wrong."
fi
""",
"""if ! compose_up_with_retries "${PROFILES[@]}"; then
    fail "Docker failed to start after retries. Check internet/registry access, then run: cd $INSTALL_DIR && docker compose logs"
fi
""",
"matrix compose up retry",
)

replace_once(
"""COMPOSE_EXIT=0
docker compose up -d 2>&1 || COMPOSE_EXIT=$?
if [ "$COMPOSE_EXIT" -ne 0 ]; then
    fail "Docker failed to start. Run 'cd $INSTALL_DIR && docker compose logs' to see what went wrong."
fi
""",
"""if ! compose_up_with_retries; then
    fail "Docker failed to start after retries. Check internet/registry access, then run: cd $INSTALL_DIR && docker compose logs"
fi
""",
"stoat compose up retry",
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

apply_pangolin_offload_patches() {
  log "Applying Pangolin SSL offload patches..."

  local setup_file="$INSTALL_DIR/setup.sh"
  local compose_file="$INSTALL_DIR/docker-compose.yml"
  local matrix_template="$INSTALL_DIR/templates/matrix.conf.template"

  [[ -f "$setup_file" ]] || die "setup.sh not found at ${setup_file}"
  [[ -f "$compose_file" ]] || die "docker-compose.yml not found at ${compose_file}"
  [[ -f "$matrix_template" ]] || die "matrix.conf template not found at ${matrix_template}"

  # 1) Patch setup flow: skip certbot, generate local self-signed cert, and avoid local 443/8448 firewall rules.
  python3 - "$setup_file" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
changes = []

certbot_block_replacement = '''step "Preparing TLS assets (Let's Encrypt or proxy-offload mode)..."

if [ "${PANGOLIN_SSL_OFFLOAD:-false}" = "true" ]; then
    echo -e "  ${YELLOW}Pangolin SSL offload enabled: skipping certbot and generating a local self-signed cert for internal services.${NC}"
    CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
    mkdir -p "$CERT_DIR"
    if [ ! -f "$CERT_DIR/fullchain.pem" ] || [ ! -f "$CERT_DIR/privkey.pem" ]; then
        if ! openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
            -keyout "$CERT_DIR/privkey.pem" \
            -out "$CERT_DIR/fullchain.pem" \
            -subj "/CN=${DOMAIN}" \
            -addext "subjectAltName=DNS:${DOMAIN}" >/dev/null 2>&1; then
            fail "Failed to generate local self-signed certificate."
        fi
        chmod 600 "$CERT_DIR/privkey.pem"
        chmod 644 "$CERT_DIR/fullchain.pem"
    fi
else
    # Stop anything on port 80
    systemctl stop nginx 2>/dev/null || true
    docker compose -f "$INSTALL_DIR/docker-compose.yml" down 2>/dev/null || true

    certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --email "$ACME_EMAIL" \
        -d "$DOMAIN" \
        --preferred-challenges http \
        2>/dev/null

    if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
        echo ""
        echo -e "${RED}SSL certificate failed. This usually means one of:${NC}"
        echo "  1. Your domain ($DOMAIN) doesn't point to this server's IP yet"
        echo "  2. DNS changes haven't propagated (can take up to 24 hours)"
        echo "  3. Port 80 is blocked (check your firewall/VPS provider)"
        echo ""
        echo "Fix the issue and re-run this installer — it will pick up where it left off."
        exit 1
    fi

    # Patch certbot renewal config to use webroot (standalone only works when nginx is down)
    RENEWAL_CONF="/etc/letsencrypt/renewal/${DOMAIN}.conf"
    if [ -f "$RENEWAL_CONF" ]; then
        sed -i "s|authenticator = standalone|authenticator = webroot|" "$RENEWAL_CONF"
        if ! grep -q "webroot_path" "$RENEWAL_CONF"; then
            sed -i "/\\[renewalparams\\]/a webroot_path = $DATA_DIR/certbot/www" "$RENEWAL_CONF"
        fi
        # Add webroot map section if missing
        if ! grep -q "\\[\\[webroot\\]\\]" "$RENEWAL_CONF"; then
            printf '\\n[[webroot]]\\n%s = %s\\n' "$DOMAIN" "$DATA_DIR/certbot/www" >> "$RENEWAL_CONF"
        fi
    fi
fi

ok'''

start_marker = "step \"Getting SSL certificate (HTTPS) from Let's Encrypt...\""
end_marker = '# ─── [7/11] Configure firewall'
start_index = text.find(start_marker)
if start_index != -1:
    end_index = text.find(end_marker, start_index)
    if end_index != -1:
        text = text[:start_index] + certbot_block_replacement.rstrip() + "\n\n" + text[end_index:]
        changes.append("certbot step made offload-aware")

firewall_block_old = '''# Preserve SSH access before enabling firewall
SSH_PORT=$(detect_ssh_port)
fw_allow "${SSH_PORT}/tcp"
fw_allow 80/tcp
fw_allow 443/tcp
fw_allow 8448/tcp
fw_allow 3478/tcp
fw_allow 3478/udp
fw_allow 5349/tcp
fw_allow 5349/udp
fw_allow 49152:49200/udp
fw_enable'''

firewall_block_new = '''# Preserve SSH access before enabling firewall
SSH_PORT=$(detect_ssh_port)
fw_allow "${SSH_PORT}/tcp"
fw_allow 80/tcp
if [ "${PANGOLIN_SSL_OFFLOAD:-false}" = "true" ]; then
    echo -e "  ${YELLOW}Pangolin SSL offload mode: skipping local 443/8448 firewall rules.${NC}"
else
    fw_allow 443/tcp
    fw_allow 8448/tcp
fi
fw_allow 3478/tcp
fw_allow 3478/udp
fw_allow 5349/tcp
fw_allow 5349/udp
fw_allow 49152:49200/udp
fw_enable'''

if firewall_block_old in text:
    text = text.replace(firewall_block_old, firewall_block_new, 1)
    changes.append("firewall step adapted for offload mode")

cron_block_old = '''# Certbot cron for renewal (webroot mode using nginx)
# Add cert renewal cron if not already present
CRON_LINE="0 3 * * * certbot renew --deploy-hook 'cd $INSTALL_DIR && docker compose exec -T nginx nginx -s reload && docker compose restart coturn' # matrix-discord-killer"
(crontab -l 2>/dev/null | grep -v "# matrix-discord-killer" || true; echo "$CRON_LINE") | crontab -'''

cron_block_new = '''if [ "${PANGOLIN_SSL_OFFLOAD:-false}" != "true" ]; then
    # Certbot cron for renewal (webroot mode using nginx)
    # Add cert renewal cron if not already present
    CRON_LINE="0 3 * * * certbot renew --deploy-hook 'cd $INSTALL_DIR && docker compose exec -T nginx nginx -s reload && docker compose restart coturn' # matrix-discord-killer"
    (crontab -l 2>/dev/null | grep -v "# matrix-discord-killer" || true; echo "$CRON_LINE") | crontab -
fi'''

if cron_block_old in text:
    text = text.replace(cron_block_old, cron_block_new, 1)
    changes.append("certbot renewal cron disabled in offload mode")

path.write_text(text, encoding="utf-8")
print("Pangolin setup.sh patches:")
if changes:
    for item in changes:
        print(f" - {item}")
else:
    print(" - none (upstream layout changed)")
PY

  # 2) Use HTTP-only matrix nginx template (proxy backend :80, no 80->443 redirect loop).
  cat >"$matrix_template" <<'EOF'
# Pangolin SSL offload mode: serve Matrix/Element on plain HTTP internally.
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location /.well-known/matrix/server {
        default_type application/json;
        add_header Access-Control-Allow-Origin * always;
        return 200 '{"m.server": "__DOMAIN__:443"}';
    }

    location /.well-known/matrix/client {
        default_type application/json;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Origin, X-Requested-With, Content-Type, Accept, Authorization" always;
        return 200 '{"m.homeserver": {"base_url": "https://__DOMAIN__"}}';
    }

    location ~ ^/_matrix/client/(r0|v3|unstable)/login$ {
        limit_req zone=matrix_login burst=3 nodelay;
        proxy_pass http://synapse:8008;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Host $host;
    }

    location /_matrix/ {
        limit_req zone=matrix_general burst=50 nodelay;
        proxy_pass http://synapse:8008;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Host $host;
        proxy_read_timeout 600s;
    }

    location /_synapse/ {
        limit_req zone=matrix_general burst=50 nodelay;
        proxy_pass http://synapse:8008;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Host $host;
    }

    location / {
        proxy_pass http://element:80;
        proxy_set_header Host $host;
    }
}
EOF

  # 3) Expose only backend HTTP when SSL is terminated by Pangolin.
  python3 - "$compose_file" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = '''    ports:
      - "80:80"
      - "443:443"
      - "8448:8448"
'''
new = '''    ports:
      - "80:80"
'''
if old in text:
    text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")
print("Pangolin docker-compose patch applied.")
PY

  bash -n "$setup_file" || die "Pangolin-patched setup.sh failed syntax validation."
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

main() {
  parse_args "$@"
  require_root
  detect_os

  log "Detected OS family: ${OS_FAMILY}"
  ensure_command git git
  ensure_command curl curl
  ensure_command python3 python3

  clone_or_update_repo
  apply_setup_hotfixes
  if [[ "$PANGOLIN_SSL_OFFLOAD" == "true" ]]; then
    apply_pangolin_offload_patches
  fi

  if [[ "$SKIP_SETUP" == "true" ]]; then
    log "Setup execution skipped (--skip-setup)."
    exit 0
  fi

  preopen_acme_firewall_paths

  [[ -e /dev/tty ]] || die "/dev/tty not available. Run from an interactive terminal."
  log "Starting patched oneshotmatrix setup..."
  PANGOLIN_SSL_OFFLOAD="$PANGOLIN_SSL_OFFLOAD" exec "$INSTALL_DIR/setup.sh" </dev/tty
}

main "$@"
