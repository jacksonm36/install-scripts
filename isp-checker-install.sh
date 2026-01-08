#!/usr/bin/env bash
#
# ISP-Checker installer (based on upstream README "Installation")
# Upstream: https://github.com/fmdlc/ISP-Checker
#
# What this script does:
# - Installs Docker Engine (if missing)
# - Ensures a working `docker-compose` command (required by upstream Makefile)
# - Clones/updates ISP-Checker into $ISP_CHECKER_DIR
# - Writes docker-compose/credentials.env (InfluxDB/Grafana credentials)
# - Optionally patches dashboard interface name (eth0 -> detected interface)
# - Runs `make install` (brings up the stack + provisions Grafana)
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Please run as root (e.g. sudo $0)"
    exit 1
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

genpw() {
  local len="${1:-24}"
  if have openssl; then
    openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c "${len}"
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${len}"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./isp-checker-install.sh [--dir /opt/ISP-Checker] [--iface eth0] [--no-make-install]

Env overrides (optional):
  ISP_CHECKER_DIR=/opt/ISP-Checker
  ISP_CHECKER_BRANCH=master
  INFLUXDB_DB=telegraf
  INFLUXDB_ADMIN_USER=root
  INFLUXDB_ADMIN_PASSWORD=...
  INFLUXDB_READ_USER=grafana
  INFLUXDB_READ_USER_PASSWORD=...
EOF
}

ISP_CHECKER_DIR="${ISP_CHECKER_DIR:-/opt/ISP-Checker}"
ISP_CHECKER_BRANCH="${ISP_CHECKER_BRANCH:-master}"
REPO_URL="https://github.com/fmdlc/ISP-Checker.git"
OVERRIDE_IFACE=""
NO_MAKE_INSTALL="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dir) ISP_CHECKER_DIR="${2:-}"; shift 2 ;;
    --iface) OVERRIDE_IFACE="${2:-}"; shift 2 ;;
    --no-make-install) NO_MAKE_INSTALL="1"; shift ;;
    *) err "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

detect_iface() {
  if [[ -n "${OVERRIDE_IFACE}" ]]; then
    echo "${OVERRIDE_IFACE}"
    return 0
  fi
  if have ip; then
    local dev
    dev="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' || true)"
    if [[ -n "${dev}" ]]; then
      echo "${dev}"
      return 0
    fi
  fi
  echo "eth0"
}

ensure_apt_deps() {
  if ! have apt-get; then
    err "This installer currently supports Debian/Ubuntu (apt-get not found)."
    exit 3
  fi
  export DEBIAN_FRONTEND=noninteractive
  log "Installing base dependencies (curl, git, make, iproute2)..."
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    make \
    iproute2 \
    sed \
    coreutils \
    openssl
}

ensure_docker() {
  if have docker; then
    log "Docker already installed."
  else
    log "Installing Docker Engine (get.docker.com)..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    bash /tmp/get-docker.sh
  fi
  if have systemctl; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  fi
}

ensure_docker_compose_cmd() {
  # Upstream Makefile uses `docker-compose`, not `docker compose`.
  if have docker-compose; then
    log "`docker-compose` is available."
    return 0
  fi

  # Try installing compose plugin (provides `docker compose`).
  if have apt-get; then
    apt-get install -y --no-install-recommends docker-compose-plugin >/dev/null 2>&1 || true
  fi

  if docker compose version >/dev/null 2>&1; then
    log "Docker Compose plugin detected; creating `docker-compose` wrapper."
    install -d /usr/local/bin
    cat >/usr/local/bin/docker-compose <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec docker compose "$@"
EOF
    chmod +x /usr/local/bin/docker-compose
    return 0
  fi

  # Fallback: install legacy docker-compose binary (as suggested in upstream README).
  log "Installing legacy docker-compose binary (fallback)."
  curl -fsSL \
    "https://github.com/docker/compose/releases/download/1.27.4/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
}

clone_or_update_repo() {
  log "Preparing ISP-Checker in: ${ISP_CHECKER_DIR}"
  if [[ -d "${ISP_CHECKER_DIR}/.git" ]]; then
    log "Repo exists; updating (fast-forward only) ..."
    git -C "${ISP_CHECKER_DIR}" fetch --all --prune
    git -C "${ISP_CHECKER_DIR}" checkout "${ISP_CHECKER_BRANCH}"
    git -C "${ISP_CHECKER_DIR}" pull --ff-only origin "${ISP_CHECKER_BRANCH}"
  else
    install -d "$(dirname "${ISP_CHECKER_DIR}")"
    git clone --depth 1 --branch "${ISP_CHECKER_BRANCH}" "${REPO_URL}" "${ISP_CHECKER_DIR}"
  fi
}

write_credentials_env() {
  local env_path="${ISP_CHECKER_DIR}/docker-compose/credentials.env"
  local db="${INFLUXDB_DB:-telegraf}"
  local admin_user="${INFLUXDB_ADMIN_USER:-root}"
  local admin_pw="${INFLUXDB_ADMIN_PASSWORD:-}"
  local read_user="${INFLUXDB_READ_USER:-grafana}"
  local read_pw="${INFLUXDB_READ_USER_PASSWORD:-}"

  if [[ -z "${admin_pw}" ]]; then admin_pw="$(genpw 28)"; fi
  if [[ -z "${read_pw}" ]]; then read_pw="$(genpw 28)"; fi

  log "Writing credentials to ${env_path}"
  cat >"${env_path}" <<EOF
#--------------------------------------------------
# Setup here credentials for InfluxDB and Telegraf
#--------------------------------------------------
## InfluxDB database name
INFLUXDB_DB=${db}

## InfluxDB admin credentials
INFLUXDB_ADMIN_USER=${admin_user}
INFLUXDB_ADMIN_PASSWORD=${admin_pw}

## Read Only user for Grafana
INFLUXDB_READ_USER=${read_user}
INFLUXDB_READ_USER_PASSWORD=${read_pw}
EOF

  chmod 0600 "${env_path}" || true

  # Save for summary output
  export __ISP_INFLUXDB_DB="${db}"
  export __ISP_INFLUXDB_ADMIN_USER="${admin_user}"
  export __ISP_INFLUXDB_ADMIN_PASSWORD="${admin_pw}"
  export __ISP_INFLUXDB_READ_USER="${read_user}"
  export __ISP_INFLUXDB_READ_USER_PASSWORD="${read_pw}"
}

patch_dashboard_iface() {
  local iface="$1"
  local graf_dir="${ISP_CHECKER_DIR}/docker-compose/grafana"

  if [[ ! -d "${graf_dir}" ]]; then
    warn "Grafana provisioning dir not found (${graf_dir}); skipping interface patch."
    return 0
  fi

  local patched=0
  shopt -s nullglob
  for f in "${graf_dir}"/*.json; do
    if grep -q 'eth0' "${f}"; then
      sed -i "s/eth0/${iface}/g" "${f}"
      patched=1
    fi
  done
  shopt -u nullglob

  if [[ "${patched}" -eq 1 ]]; then
    log "Patched dashboard interface name: eth0 -> ${iface}"
  else
    log "No 'eth0' found in Grafana JSON; no interface patch needed."
  fi
}

run_make_install() {
  log "Running: make install"
  (cd "${ISP_CHECKER_DIR}" && make install)
}

summary() {
  local iface="$1"
  local ip_addr="127.0.0.1"
  if have hostname; then
    ip_addr="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")"
  fi

  echo ""
  echo "================ ISP-Checker installed ================"
  echo "Directory: ${ISP_CHECKER_DIR}"
  echo "Interface: ${iface}"
  echo ""
  echo "Grafana:"
  echo "  URL:      http://${ip_addr}:3000/"
  echo "  Username: admin"
  echo "  Password: admin"
  echo "  NOTE: change it immediately after first login."
  echo ""
  echo "InfluxDB credentials written to:"
  echo "  ${ISP_CHECKER_DIR}/docker-compose/credentials.env"
  echo ""
  echo "InfluxDB (from credentials.env):"
  echo "  DB:            ${__ISP_INFLUXDB_DB}"
  echo "  Admin user:    ${__ISP_INFLUXDB_ADMIN_USER}"
  echo "  Admin pass:    ${__ISP_INFLUXDB_ADMIN_PASSWORD}"
  echo "  Grafana user:  ${__ISP_INFLUXDB_READ_USER}"
  echo "  Grafana pass:  ${__ISP_INFLUXDB_READ_USER_PASSWORD}"
  echo "======================================================="
}

main() {
  need_root
  ensure_apt_deps
  ensure_docker
  ensure_docker_compose_cmd
  clone_or_update_repo
  write_credentials_env

  local iface
  iface="$(detect_iface)"
  patch_dashboard_iface "${iface}"

  if [[ "${NO_MAKE_INSTALL}" -eq 0 ]]; then
    run_make_install
  else
    warn "Skipping 'make install' (--no-make-install)."
    warn "Next step: (cd \"${ISP_CHECKER_DIR}\" && make install)"
  fi

  summary "${iface}"
}

main "$@"

