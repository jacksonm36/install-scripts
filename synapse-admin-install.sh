#!/usr/bin/env bash
set -Eeuo pipefail

# Standalone Matrix Synapse + Synapse Admin installer (Debian/Ubuntu).
# Converted from an LXC helper-based script to run directly on host systems.

SCRIPT_VERSION="1.0.0"
NODE_MAJOR="${NODE_MAJOR:-22}"
SYNAPSE_CONFIG="/etc/matrix-synapse/homeserver.yaml"
SYNAPSE_CREDS_FILE="/root/matrix.creds"
SYNAPSE_ADMIN_DIR="/opt/synapse-admin"
SYNAPSE_ADMIN_SERVICE="/etc/systemd/system/synapse-admin.service"
MATRIX_REPO_KEYRING="/usr/share/keyrings/matrix-org-archive-keyring.gpg"
MATRIX_REPO_FILE="/etc/apt/sources.list.d/matrix-org.sources"
MATRIX_REPO_KEY_URL="https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg"
MATRIX_REPO_URL="https://packages.matrix.org/debian/"

OS_CODENAME=""
SERVER_NAME=""
REGISTRATION_SHARED_SECRET=""
ADMIN_USER="admin"
ADMIN_PASS=""
POLICY_RC_D_BACKUP=""
POLICY_RC_D_GUARD_ENABLED="false"

log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Please run this script as root."
  fi
}

require_systemd() {
  if ! command_exists systemctl; then
    die "systemd is required by this installer."
  fi
}

detect_os() {
  [[ -r /etc/os-release ]] || die "Cannot detect OS: /etc/os-release is missing."
  # shellcheck disable=SC1091
  source /etc/os-release

  case "${ID,,}" in
    debian|ubuntu) ;;
    *)
      die "Unsupported OS: ${ID:-unknown}. This installer supports Debian/Ubuntu only."
      ;;
  esac

  OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  if [[ -z "$OS_CODENAME" ]] && command_exists lsb_release; then
    OS_CODENAME="$(lsb_release -cs || true)"
  fi
  [[ -n "$OS_CODENAME" ]] || die "Could not determine distro codename."
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

prepare_inputs() {
  local default_name
  default_name="$(hostname -f 2>/dev/null || hostname || true)"
  default_name="${default_name:-matrix.example.com}"

  printf "\nSynapse + Synapse Admin installer v%s\n\n" "$SCRIPT_VERSION"
  SERVER_NAME="$(ask_required_text "Matrix server name (example: matrix.example.com)" "$default_name")"
}

install_base_packages() {
  log "Installing system dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    debconf-utils \
    gpg \
    jq \
    openssl \
    tar
}

install_node_and_tooling() {
  local current_major=""

  if command_exists node; then
    current_major="$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || true)"
  fi

  if [[ "$current_major" != "$NODE_MAJOR" ]]; then
    log "Installing Node.js ${NODE_MAJOR}.x..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y nodejs
  else
    log "Node.js ${NODE_MAJOR}.x already installed."
  fi

  log "Installing yarn and serve CLI..."
  npm install -g yarn serve
}

setup_matrix_repo() {
  log "Configuring Matrix APT repository..."
  install -m 0755 -d /usr/share/keyrings
  curl -fsSL "$MATRIX_REPO_KEY_URL" | gpg --dearmor -o "$MATRIX_REPO_KEYRING"
  chmod 0644 "$MATRIX_REPO_KEYRING"

  cat >"$MATRIX_REPO_FILE" <<EOF
Types: deb
URIs: ${MATRIX_REPO_URL}
Suites: ${OS_CODENAME}
Components: main
Signed-By: ${MATRIX_REPO_KEYRING}
EOF

  apt-get update -y
}

enable_policy_rc_guard() {
  if [[ -e /usr/sbin/policy-rc.d ]]; then
    POLICY_RC_D_BACKUP="/usr/sbin/policy-rc.d.backup.$(date +%s)"
    cp -a /usr/sbin/policy-rc.d "$POLICY_RC_D_BACKUP"
  else
    POLICY_RC_D_BACKUP=""
  fi

  cat >/usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
  chmod 0755 /usr/sbin/policy-rc.d
  POLICY_RC_D_GUARD_ENABLED="true"
}

restore_policy_rc_guard() {
  if [[ "$POLICY_RC_D_GUARD_ENABLED" != "true" ]]; then
    return 0
  fi

  if [[ -n "$POLICY_RC_D_BACKUP" && -e "$POLICY_RC_D_BACKUP" ]]; then
    mv -f "$POLICY_RC_D_BACKUP" /usr/sbin/policy-rc.d
  else
    rm -f /usr/sbin/policy-rc.d
  fi

  POLICY_RC_D_BACKUP=""
  POLICY_RC_D_GUARD_ENABLED="false"
}

install_synapse() {
  log "Installing matrix-synapse..."
  echo "matrix-synapse-py3 matrix-synapse/server-name string ${SERVER_NAME}" | debconf-set-selections
  echo "matrix-synapse-py3 matrix-synapse/report-stats boolean false" | debconf-set-selections

  enable_policy_rc_guard
  apt-get install -y matrix-synapse-py3
  restore_policy_rc_guard
}

configure_synapse() {
  [[ -f "$SYNAPSE_CONFIG" ]] || die "Synapse config not found: $SYNAPSE_CONFIG"

  log "Configuring ${SYNAPSE_CONFIG}..."
  cp -a "$SYNAPSE_CONFIG" "${SYNAPSE_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

  sed -i "s/'127\\.0\\.0\\.1'/'0.0.0.0'/g" "$SYNAPSE_CONFIG"
  sed -i 's/"127\\.0\\.0\\.1"/"0.0.0.0"/g' "$SYNAPSE_CONFIG"
  sed -i "s/'::1', //g" "$SYNAPSE_CONFIG"
  sed -i 's/"::1", //g' "$SYNAPSE_CONFIG"
  sed -i '/^registration_shared_secret:/d' "$SYNAPSE_CONFIG"

  REGISTRATION_SHARED_SECRET="$(openssl rand -hex 32)"
  printf '\nregistration_shared_secret: "%s"\n' "$REGISTRATION_SHARED_SECRET" >>"$SYNAPSE_CONFIG"
}

wait_for_synapse() {
  local i
  for i in {1..60}; do
    if curl -fsS "http://127.0.0.1:8008/_matrix/client/versions" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

create_admin_user() {
  ADMIN_PASS="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | cut -c1-13)"
  [[ -n "$ADMIN_PASS" ]] || die "Failed to generate admin password."

  log "Starting Synapse service..."
  systemctl enable --now matrix-synapse
  if ! wait_for_synapse; then
    journalctl -u matrix-synapse --no-pager -n 100 || true
    die "Synapse did not become ready."
  fi

  log "Creating Matrix admin user '${ADMIN_USER}'..."
  register_new_matrix_user \
    -u "$ADMIN_USER" \
    -p "$ADMIN_PASS" \
    -a \
    -k "$REGISTRATION_SHARED_SECRET" \
    "http://127.0.0.1:8008"

  cat >"$SYNAPSE_CREDS_FILE" <<EOF
Matrix-Credentials
Admin username: ${ADMIN_USER}
Admin password: ${ADMIN_PASS}
EOF
  chmod 600 "$SYNAPSE_CREDS_FILE"
}

deploy_synapse_admin_files() {
  local tmp_archive release_json tarball_url
  tmp_archive="$(mktemp /tmp/synapse-admin-XXXXXX.tar.gz)"

  log "Downloading Synapse Admin source..."
  tarball_url="https://api.github.com/repos/etkecc/synapse-admin/tarball"
  if release_json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/etkecc/synapse-admin/releases/latest" 2>/dev/null)"; then
    tarball_url="$(printf '%s\n' "$release_json" | jq -r '.tarball_url // empty')"
    tarball_url="${tarball_url:-https://api.github.com/repos/etkecc/synapse-admin/tarball}"
  fi

  curl -fsSL "$tarball_url" -o "$tmp_archive"

  install -d -m 0755 "$SYNAPSE_ADMIN_DIR"
  find "$SYNAPSE_ADMIN_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  tar -xzf "$tmp_archive" --strip-components=1 -C "$SYNAPSE_ADMIN_DIR"
  rm -f "$tmp_archive"
}

build_synapse_admin() {
  log "Building Synapse Admin frontend..."
  cd "$SYNAPSE_ADMIN_DIR"
  yarn install --ignore-engines
  yarn build
}

create_synapse_admin_service() {
  local serve_bin
  serve_bin="$(command -v serve || true)"
  [[ -n "$serve_bin" ]] || die "'serve' binary not found after npm install -g serve."

  log "Creating synapse-admin systemd service..."
  cat >"$SYNAPSE_ADMIN_SERVICE" <<EOF
[Unit]
Description=Synapse-Admin Service
After=network.target matrix-synapse.service
Requires=matrix-synapse.service

[Service]
Type=simple
WorkingDirectory=${SYNAPSE_ADMIN_DIR}
ExecStart=${serve_bin} -s dist -l 5173
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now synapse-admin
}

print_summary() {
  printf '\n'
  log "Installation completed."
  printf "  - Synapse service:     matrix-synapse\n"
  printf "  - Synapse Admin URL:   http://<server-ip>:5173\n"
  printf "  - Synapse config:      %s\n" "$SYNAPSE_CONFIG"
  printf "  - Credentials file:    %s\n\n" "$SYNAPSE_CREDS_FILE"
}

main() {
  trap restore_policy_rc_guard EXIT
  require_root
  require_systemd
  detect_os
  prepare_inputs
  install_base_packages
  install_node_and_tooling
  setup_matrix_repo
  install_synapse
  configure_synapse
  create_admin_user
  deploy_synapse_admin_files
  build_synapse_admin
  create_synapse_admin_service
  print_summary
}

main "$@"
