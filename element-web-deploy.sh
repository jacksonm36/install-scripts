#!/usr/bin/env bash
set -Eeuo pipefail

# Element Web deployment script (interactive, multi-OS)
# - Debian/Ubuntu + Fedora/RHEL-family
# - Installs latest (or specified) Element Web static build
# - Configures Nginx
# - Optional: Let's Encrypt TLS
# - Optional: proxy Matrix API paths to local Synapse
# - Optional: firewall rules (UFW/firewalld)

SCRIPT_VERSION="1.0.0"

OS_FAMILY=""
PKG_MANAGER=""
PRETTY_NAME=""

ELEMENT_VERSION="latest"
ELEMENT_TAG=""
ELEMENT_VERSION_SOURCE=""
ELEMENT_FQDN=""
MATRIX_SERVER_NAME=""
HOMESERVER_URL=""
PROXY_MATRIX_ENDPOINTS="false"
SYNAPSE_UPSTREAM="http://127.0.0.1:8008"
INSTALL_TLS="true"
USE_LETSENCRYPT="true"
LETSENCRYPT_EMAIL=""
CONFIGURE_FIREWALL="true"
OPEN_FEDERATION_PORT="false"
DISABLE_NGINX_DEFAULT="true"
EXTERNAL_REVERSE_PROXY="true"

ELEMENT_ROOT="/var/www/element"
NGINX_CONF="/etc/nginx/conf.d/element-web.conf"
NGINX_BOOTSTRAP_CONF="/etc/nginx/conf.d/element-web-bootstrap.conf"
CERTBOT_WEBROOT="/var/www/certbot"
TLS_CERT_FILE=""
TLS_KEY_FILE=""
SUMMARY_FILE="/root/element-web-install-summary.txt"

WEB_USER="www-data"
WEB_GROUP="www-data"

# Optional preferred defaults for interactive prompts
PREFERRED_ELEMENT_FQDN="${ELEMENT_DEFAULT_PUBLIC_FQDN:-chat.gamedns.hu}"
PREFERRED_MATRIX_SERVER_NAME="${ELEMENT_DEFAULT_MATRIX_SERVER_NAME:-matrix.gamedns.hu}"
PREFERRED_HOMESERVER_URL="${ELEMENT_DEFAULT_HOMESERVER_URL:-https://${PREFERRED_MATRIX_SERVER_NAME}}"
PREFERRED_ESS_HELM_RELEASE="${ELEMENT_DEFAULT_ESS_HELM_RELEASE:-26.2.0}"
PREFERRED_ELEMENT_VERSION="${ELEMENT_DEFAULT_VERSION:-ess-helm:${PREFERRED_ESS_HELM_RELEASE}}"
FORCE_EXTERNAL_REVERSE_PROXY="${ELEMENT_FORCE_EXTERNAL_REVERSE_PROXY:-}"

log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

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

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "Please run this script as root."
fi

if ! command_exists systemctl; then
  die "systemd is required."
fi

detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found."
  # shellcheck disable=SC1091
  source /etc/os-release
  PRETTY_NAME="${PRETTY_NAME:-$ID}"

  case "${ID,,}" in
    debian|ubuntu)
      OS_FAMILY="debian"
      PKG_MANAGER="apt-get"
      export DEBIAN_FRONTEND=noninteractive
      WEB_USER="www-data"
      WEB_GROUP="www-data"
      ;;
    fedora)
      OS_FAMILY="fedora"
      PKG_MANAGER="dnf"
      WEB_USER="nginx"
      WEB_GROUP="nginx"
      ;;
    rhel|centos|rocky|almalinux|ol|oraclelinux)
      OS_FAMILY="rhel"
      if command_exists dnf; then
        PKG_MANAGER="dnf"
      elif command_exists yum; then
        PKG_MANAGER="yum"
      else
        die "Neither dnf nor yum is available."
      fi
      WEB_USER="nginx"
      WEB_GROUP="nginx"
      ;;
    *)
      if [[ "${ID_LIKE:-}" =~ (debian|ubuntu) ]]; then
        OS_FAMILY="debian"
        PKG_MANAGER="apt-get"
        export DEBIAN_FRONTEND=noninteractive
        WEB_USER="www-data"
        WEB_GROUP="www-data"
      elif [[ "${ID_LIKE:-}" =~ (rhel|fedora|centos) ]]; then
        OS_FAMILY="rhel"
        if command_exists dnf; then
          PKG_MANAGER="dnf"
        elif command_exists yum; then
          PKG_MANAGER="yum"
        else
          die "Neither dnf nor yum is available."
        fi
        WEB_USER="nginx"
        WEB_GROUP="nginx"
      else
        die "Unsupported OS: ${ID}"
      fi
      ;;
  esac
}

pkg_update() {
  case "$OS_FAMILY" in
    debian) apt-get update -y ;;
    fedora|rhel)
      if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf makecache -y
      else
        yum makecache -y
      fi
      ;;
    *) die "Unknown OS family: $OS_FAMILY" ;;
  esac
}

pkg_install() {
  case "$OS_FAMILY" in
    debian) apt-get install -y "$@" ;;
    fedora|rhel)
      if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf install -y "$@"
      else
        yum install -y "$@"
      fi
      ;;
    *) die "Unknown OS family: $OS_FAMILY" ;;
  esac
}

collect_inputs() {
  local default_host default_element_fqdn default_matrix_name default_homeserver_url
  local proxy_matrix_default
  default_host="$(hostname -f 2>/dev/null || hostname)"
  [[ -n "$default_host" ]] || default_host="chat.example.com"
  default_element_fqdn="${PREFERRED_ELEMENT_FQDN:-$default_host}"
  default_matrix_name="${PREFERRED_MATRIX_SERVER_NAME:-$default_element_fqdn}"
  default_homeserver_url="${PREFERRED_HOMESERVER_URL:-https://${default_matrix_name}}"

  printf "\nElement Web deployment v%s\n" "$SCRIPT_VERSION"
  printf "Detected OS: %s\n\n" "$PRETTY_NAME"

  ELEMENT_FQDN="$(ask_required_text "Element public domain (FQDN)" "$default_element_fqdn")"
  MATRIX_SERVER_NAME="$(ask_required_text "Matrix server_name (e.g. matrix.example.com)" "$default_matrix_name")"
  HOMESERVER_URL="$(ask_required_text "Homeserver base URL" "$default_homeserver_url")"
  if [[ ! "$HOMESERVER_URL" =~ ^https?:// ]]; then
    warn "Homeserver URL missing scheme, prefixing with https://"
    HOMESERVER_URL="https://${HOMESERVER_URL}"
  fi
  HOMESERVER_URL="${HOMESERVER_URL%/}"

  if [[ -n "$FORCE_EXTERNAL_REVERSE_PROXY" ]]; then
    case "${FORCE_EXTERNAL_REVERSE_PROXY,,}" in
      1|true|yes|y)
        EXTERNAL_REVERSE_PROXY="true"
        log "External reverse proxy mode forced ON by ELEMENT_FORCE_EXTERNAL_REVERSE_PROXY=${FORCE_EXTERNAL_REVERSE_PROXY}"
        ;;
      0|false|no|n)
        EXTERNAL_REVERSE_PROXY="false"
        log "External reverse proxy mode forced OFF by ELEMENT_FORCE_EXTERNAL_REVERSE_PROXY=${FORCE_EXTERNAL_REVERSE_PROXY}"
        ;;
      *)
        die "Invalid ELEMENT_FORCE_EXTERNAL_REVERSE_PROXY value: ${FORCE_EXTERNAL_REVERSE_PROXY} (use true/false)"
        ;;
    esac
  elif ask_yes_no "Use an external reverse proxy in front of Element?" "y"; then
    EXTERNAL_REVERSE_PROXY="true"
  else
    EXTERNAL_REVERSE_PROXY="false"
  fi

  ELEMENT_VERSION="$(ask_text "Element version ('latest', element tag, 'ess-helm:<release>', or ESS release URL)" "$PREFERRED_ELEMENT_VERSION")"
  ELEMENT_VERSION="${ELEMENT_VERSION:-latest}"

  proxy_matrix_default="y"
  if [[ "$EXTERNAL_REVERSE_PROXY" == "true" ]]; then
    proxy_matrix_default="n"
  fi

  if ask_yes_no "Proxy Matrix API endpoints (/_matrix, /_synapse/client) via this Nginx?" "$proxy_matrix_default"; then
    PROXY_MATRIX_ENDPOINTS="true"
    SYNAPSE_UPSTREAM="$(ask_required_text "Local Synapse upstream URL" "http://127.0.0.1:8008")"
    SYNAPSE_UPSTREAM="${SYNAPSE_UPSTREAM%/}"
  fi

  if [[ "$EXTERNAL_REVERSE_PROXY" == "true" ]]; then
    INSTALL_TLS="false"
    USE_LETSENCRYPT="false"
    log "External reverse proxy mode enabled: backend TLS is disabled, proxy should terminate HTTPS."
  else
    if ask_yes_no "Enable TLS (HTTPS)?" "y"; then
      INSTALL_TLS="true"
      if ask_yes_no "Use Let's Encrypt?" "y"; then
        USE_LETSENCRYPT="true"
        LETSENCRYPT_EMAIL="$(ask_required_text "Let's Encrypt email" "admin@${ELEMENT_FQDN}")"
      else
        USE_LETSENCRYPT="false"
      fi
    else
      INSTALL_TLS="false"
      USE_LETSENCRYPT="false"
    fi
  fi

  if [[ "$PROXY_MATRIX_ENDPOINTS" == "true" && "$INSTALL_TLS" == "true" ]]; then
    if ask_yes_no "Expose Matrix federation on 8448 via Nginx?" "n"; then
      OPEN_FEDERATION_PORT="true"
    fi
  fi

  if ! ask_yes_no "Auto-configure firewall rules?" "y"; then
    CONFIGURE_FIREWALL="false"
  fi

  if ! ask_yes_no "Disable default Nginx welcome site?" "y"; then
    DISABLE_NGINX_DEFAULT="false"
  fi
}

install_packages() {
  log "Installing required packages..."
  pkg_update

  if [[ "$OS_FAMILY" == "debian" ]]; then
    pkg_install ca-certificates curl jq tar openssl nginx
    if [[ "$INSTALL_TLS" == "true" && "$USE_LETSENCRYPT" == "true" ]]; then
      pkg_install certbot
    fi
    if [[ "$CONFIGURE_FIREWALL" == "true" ]]; then
      pkg_install ufw
    fi
  else
    pkg_install ca-certificates curl jq tar openssl nginx
    if [[ "$INSTALL_TLS" == "true" && "$USE_LETSENCRYPT" == "true" ]]; then
      pkg_install certbot
    fi
    if [[ "$CONFIGURE_FIREWALL" == "true" ]]; then
      pkg_install firewalld
    fi
  fi
}

resolve_element_asset() {
  local metadata api_url version_request chart_tag chart_url
  api_url="https://api.github.com/repos/element-hq/element-web/releases/latest"
  version_request="${ELEMENT_VERSION}"

  chart_tag=""
  if [[ "$version_request" =~ ^https://github.com/element-hq/ess-helm/releases/tag/([^/]+)$ ]]; then
    chart_tag="${BASH_REMATCH[1]}"
  elif [[ "$version_request" =~ ^ess-helm:(.+)$ ]]; then
    chart_tag="${BASH_REMATCH[1]}"
  fi

  if [[ -n "$chart_tag" ]]; then
    chart_url="https://github.com/element-hq/ess-helm/releases/download/${chart_tag}/matrix-stack-${chart_tag}.tgz"
    ELEMENT_TAG="$(resolve_element_tag_from_ess_helm "$chart_url")"
    ELEMENT_VERSION_SOURCE="ess-helm:${chart_tag}"
    ELEMENT_ASSET_URL="https://github.com/element-hq/element-web/releases/download/${ELEMENT_TAG}/element-${ELEMENT_TAG}.tar.gz"
    log "Resolved Element version ${ELEMENT_TAG} from ${ELEMENT_VERSION_SOURCE}"
    return 0
  fi

  if [[ "${version_request,,}" == "latest" ]]; then
    metadata="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$api_url")"
    ELEMENT_TAG="$(printf '%s\n' "$metadata" | jq -r '.tag_name')"
    [[ -n "$ELEMENT_TAG" && "$ELEMENT_TAG" != "null" ]] || die "Could not resolve latest Element release tag."
    ELEMENT_ASSET_URL="$(printf '%s\n' "$metadata" | jq -r '.assets[] | select(.name | test("^element-.*\\.tar\\.gz$")) | .browser_download_url' | awk 'NR==1{print; exit}')"
    ELEMENT_VERSION_SOURCE="element-web:latest"
  else
    if [[ "$version_request" =~ ^v ]]; then
      ELEMENT_TAG="$version_request"
    else
      ELEMENT_TAG="v${version_request}"
    fi
    ELEMENT_ASSET_URL="https://github.com/element-hq/element-web/releases/download/${ELEMENT_TAG}/element-${ELEMENT_TAG}.tar.gz"
    ELEMENT_VERSION_SOURCE="element-web:${ELEMENT_TAG}"
  fi

  [[ -n "${ELEMENT_ASSET_URL:-}" && "${ELEMENT_ASSET_URL}" != "null" ]] || die "Could not resolve Element release asset URL."
}

resolve_element_tag_from_ess_helm() {
  local chart_url="$1"
  python3 - "$chart_url" <<'PY'
import io
import re
import sys
import tarfile
import urllib.request

chart_url = sys.argv[1]
with urllib.request.urlopen(chart_url, timeout=40) as response:
    content = response.read()

with tarfile.open(fileobj=io.BytesIO(content), mode="r:gz") as tar:
    values_member = None
    for name in tar.getnames():
        if name.endswith("/values.yaml"):
            values_member = name
            break

    if values_member is None:
        raise SystemExit("Could not find values.yaml in ESS helm chart.")

    values_text = tar.extractfile(values_member).read().decode("utf-8", "ignore")

match = re.search(
    r"(?ms)^elementWeb:\n(?:^[ \t].*\n)*?^[ \t]{2}image:\n(?:^[ \t].*\n)*?^[ \t]{4}tag:\s*[\"']?([^\"'\n#]+)",
    values_text,
)

if not match:
    raise SystemExit("Could not extract elementWeb.image.tag from ESS values.yaml")

print(match.group(1).strip())
PY
}

download_and_install_element() {
  resolve_element_asset
  log "Downloading Element Web ${ELEMENT_TAG}..."

  local archive tmpdir
  archive="/tmp/element-web-${ELEMENT_TAG}.tar.gz"
  tmpdir="$(mktemp -d)"

  curl -fL "$ELEMENT_ASSET_URL" -o "$archive"

  mkdir -p "$ELEMENT_ROOT"
  find "$ELEMENT_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  tar -xzf "$archive" --strip-components=1 -C "$ELEMENT_ROOT"

  [[ -f "${ELEMENT_ROOT}/index.html" ]] || die "Element deployment failed: index.html not found."

  mkdir -p "$CERTBOT_WEBROOT"
  chown -R "$WEB_USER:$WEB_GROUP" "$ELEMENT_ROOT" "$CERTBOT_WEBROOT"
  chmod -R u=rwX,go=rX "$ELEMENT_ROOT"

  rm -rf "$tmpdir" "$archive"
  log "Element Web files installed to ${ELEMENT_ROOT}"
}

write_element_config_json() {
  log "Writing Element config.json..."
  cat >"${ELEMENT_ROOT}/config.json" <<EOF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "${HOMESERVER_URL}",
      "server_name": "${MATRIX_SERVER_NAME}"
    },
    "m.identity_server": {
      "base_url": "https://vector.im"
    }
  },
  "disable_custom_urls": false,
  "disable_guests": false,
  "show_labs_settings": true,
  "brand": "Element"
}
EOF
  chown "$WEB_USER:$WEB_GROUP" "${ELEMENT_ROOT}/config.json"
  chmod 644 "${ELEMENT_ROOT}/config.json"
}

generate_self_signed_cert() {
  local cert_dir
  cert_dir="/etc/ssl/element-web"
  mkdir -p "$cert_dir"
  TLS_CERT_FILE="${cert_dir}/element-web.crt"
  TLS_KEY_FILE="${cert_dir}/element-web.key"

  if [[ ! -f "$TLS_CERT_FILE" || ! -f "$TLS_KEY_FILE" ]]; then
    log "Generating self-signed certificate..."
    if ! openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
      -keyout "$TLS_KEY_FILE" \
      -out "$TLS_CERT_FILE" \
      -subj "/CN=${ELEMENT_FQDN}" \
      -addext "subjectAltName=DNS:${ELEMENT_FQDN}" >/dev/null 2>&1; then
      openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
        -keyout "$TLS_KEY_FILE" \
        -out "$TLS_CERT_FILE" \
        -subj "/CN=${ELEMENT_FQDN}" >/dev/null 2>&1
    fi
    chmod 640 "$TLS_KEY_FILE"
    chmod 644 "$TLS_CERT_FILE"
  fi
}

matrix_proxy_locations() {
  if [[ "$PROXY_MATRIX_ENDPOINTS" != "true" ]]; then
    return 0
  fi

  cat <<EOF
    location ~ ^(/_matrix|/_synapse/client) {
        proxy_pass ${SYNAPSE_UPSTREAM};
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_read_timeout 600s;
    }
EOF
}

element_static_locations() {
  cat <<'EOF'
    location = /config.json {
        add_header Cache-Control "no-store";
        try_files $uri =404;
    }

    location = /sw.js {
        add_header Cache-Control "no-cache";
        try_files $uri =404;
    }

    location = /service-worker.js {
        add_header Cache-Control "no-cache";
        try_files $uri =404;
    }

    location ~* \.(js|mjs|css|png|jpg|jpeg|gif|svg|ico|webp|woff|woff2|ttf|map)$ {
        try_files $uri =404;
        expires 7d;
        access_log off;
    }
EOF
}

render_nginx_bootstrap_config() {
  cat >"$NGINX_BOOTSTRAP_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${ELEMENT_FQDN};

    root ${ELEMENT_ROOT};
    index index.html;

    location ^~ /.well-known/acme-challenge/ {
        root ${CERTBOT_WEBROOT};
    }

$(element_static_locations)

    location / {
        try_files \$uri \$uri/ /index.html;
    }
$(matrix_proxy_locations)
}
EOF
}

render_nginx_final_config_tls() {
  local federation_block=""
  if [[ "$OPEN_FEDERATION_PORT" == "true" && "$PROXY_MATRIX_ENDPOINTS" == "true" ]]; then
    federation_block=$(cat <<EOF

server {
    listen 8448 ssl;
    listen [::]:8448 ssl;
    http2 on;
    server_name ${ELEMENT_FQDN};

    ssl_certificate ${TLS_CERT_FILE};
    ssl_certificate_key ${TLS_KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;

$(matrix_proxy_locations)
}
EOF
)
  fi

  cat >"$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${ELEMENT_FQDN};

    location ^~ /.well-known/acme-challenge/ {
        root ${CERTBOT_WEBROOT};
    }

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${ELEMENT_FQDN};

    root ${ELEMENT_ROOT};
    index index.html;

    ssl_certificate ${TLS_CERT_FILE};
    ssl_certificate_key ${TLS_KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 100M;

$(element_static_locations)

    location / {
        try_files \$uri \$uri/ /index.html;
    }
$(matrix_proxy_locations)
}
${federation_block}
EOF
}

render_nginx_final_config_http() {
  cat >"$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${ELEMENT_FQDN};

    root ${ELEMENT_ROOT};
    index index.html;

$(element_static_locations)

    location / {
        try_files \$uri \$uri/ /index.html;
    }
$(matrix_proxy_locations)
}
EOF
}

disable_stale_synapse_nginx_configs_if_proxying() {
  if [[ "$PROXY_MATRIX_ENDPOINTS" != "true" && "$EXTERNAL_REVERSE_PROXY" != "true" ]]; then
    return 0
  fi

  local removed=0
  local path=""
  for path in \
    /etc/nginx/conf.d/matrix-synapse.conf \
    /etc/nginx/conf.d/matrix-synapse-bootstrap.conf \
    /etc/nginx/sites-enabled/matrix-synapse \
    /etc/nginx/sites-available/matrix-synapse; do
    if [[ -e "$path" ]]; then
      rm -f "$path"
      removed=1
    fi
  done

  if [[ "$removed" -eq 1 ]]; then
    log "Removed stale Synapse Nginx config because Element is proxying Matrix endpoints."
  fi
}

configure_nginx() {
  log "Configuring Nginx..."

  if [[ "$DISABLE_NGINX_DEFAULT" == "true" ]]; then
    rm -f /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
  fi

  disable_stale_synapse_nginx_configs_if_proxying

  if [[ "$INSTALL_TLS" == "true" && "$USE_LETSENCRYPT" == "true" ]]; then
    render_nginx_bootstrap_config
    rm -f "$NGINX_CONF"
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx

    log "Requesting Let's Encrypt certificate for ${ELEMENT_FQDN}..."
    if certbot certonly \
      --webroot \
      -w "$CERTBOT_WEBROOT" \
      -d "$ELEMENT_FQDN" \
      --email "$LETSENCRYPT_EMAIL" \
      --agree-tos \
      --non-interactive; then
      TLS_CERT_FILE="/etc/letsencrypt/live/${ELEMENT_FQDN}/fullchain.pem"
      TLS_KEY_FILE="/etc/letsencrypt/live/${ELEMENT_FQDN}/privkey.pem"
    else
      warn "Let's Encrypt failed. Falling back to self-signed certificate."
      generate_self_signed_cert
    fi

    rm -f "$NGINX_BOOTSTRAP_CONF"
    render_nginx_final_config_tls
  elif [[ "$INSTALL_TLS" == "true" ]]; then
    generate_self_signed_cert
    rm -f "$NGINX_BOOTSTRAP_CONF"
    render_nginx_final_config_tls
  else
    rm -f "$NGINX_BOOTSTRAP_CONF"
    render_nginx_final_config_http
  fi

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx

  if [[ "$PROXY_MATRIX_ENDPOINTS" == "true" ]]; then
    if ! curl -fsS "${SYNAPSE_UPSTREAM}/_matrix/client/versions" >/dev/null 2>&1; then
      warn "Could not verify Synapse upstream at ${SYNAPSE_UPSTREAM}. Element is deployed, but Matrix API proxy may need attention."
    fi
  fi

  if [[ "$OS_FAMILY" != "debian" && "$PROXY_MATRIX_ENDPOINTS" == "true" ]]; then
    if command_exists getenforce && command_exists setsebool; then
      if [[ "$(getenforce 2>/dev/null || true)" == "Enforcing" ]]; then
        setsebool -P httpd_can_network_connect 1 || warn "Failed to set SELinux boolean httpd_can_network_connect."
      fi
    fi
  fi
}

configure_ufw() {
  log "Applying UFW rules..."
  ufw allow 22/tcp comment 'SSH'
  ufw allow 80/tcp comment 'Element HTTP'
  if [[ "$INSTALL_TLS" == "true" ]]; then
    ufw allow 443/tcp comment 'Element HTTPS'
  fi
  if [[ "$OPEN_FEDERATION_PORT" == "true" ]]; then
    ufw allow 8448/tcp comment 'Matrix federation via nginx'
  fi
  ufw --force enable
}

configure_firewalld() {
  log "Applying firewalld rules..."
  systemctl enable --now firewalld
  firewall-cmd --permanent --add-service=ssh
  firewall-cmd --permanent --add-port=80/tcp
  if [[ "$INSTALL_TLS" == "true" ]]; then
    firewall-cmd --permanent --add-port=443/tcp
  fi
  if [[ "$OPEN_FEDERATION_PORT" == "true" ]]; then
    firewall-cmd --permanent --add-port=8448/tcp
  fi
  firewall-cmd --reload
}

configure_firewall() {
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
Element Web deployment summary
==============================
Date: $(date)
OS: ${PRETTY_NAME}

Element version requested: ${ELEMENT_VERSION}
Element deployed tag: ${ELEMENT_TAG}
Element version source: ${ELEMENT_VERSION_SOURCE}
Element domain: ${ELEMENT_FQDN}
Element root path: ${ELEMENT_ROOT}

Matrix server_name: ${MATRIX_SERVER_NAME}
Homeserver URL: ${HOMESERVER_URL}
Proxy Matrix API endpoints: ${PROXY_MATRIX_ENDPOINTS}
Synapse upstream: ${SYNAPSE_UPSTREAM}
External reverse proxy mode: ${EXTERNAL_REVERSE_PROXY}

TLS enabled: ${INSTALL_TLS}
Let's Encrypt used: ${USE_LETSENCRYPT}
TLS cert file: ${TLS_CERT_FILE:-N/A}
TLS key file: ${TLS_KEY_FILE:-N/A}

Firewall configured: ${CONFIGURE_FIREWALL}
Federation port 8448 exposed: ${OPEN_FEDERATION_PORT}
Nginx config: ${NGINX_CONF}
EOF
  chmod 600 "$SUMMARY_FILE"
}

print_final_notes() {
  local ui_url
  if [[ "$INSTALL_TLS" == "true" ]]; then
    ui_url="https://${ELEMENT_FQDN}/"
  else
    ui_url="http://${ELEMENT_FQDN}/"
  fi

  printf '\n'
  log "Element Web deployment completed."
  printf "  - UI URL:            %s\n" "$ui_url"
  printf "  - Homeserver URL:    %s\n" "$HOMESERVER_URL"
  printf "  - External proxy:    %s\n" "$EXTERNAL_REVERSE_PROXY"
  printf "  - Matrix proxy mode: %s\n" "$PROXY_MATRIX_ENDPOINTS"
  printf "  - Summary file:      %s\n\n" "$SUMMARY_FILE"
}

main() {
  detect_os
  collect_inputs
  install_packages
  download_and_install_element
  write_element_config_json
  configure_nginx
  configure_firewall
  write_summary
  print_final_notes
}

main "$@"
