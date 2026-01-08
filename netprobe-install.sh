#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo >&2 "[!] Error on line $LINENO: $BASH_COMMAND (exit $?)"' ERR

###############################################################################
# Netprobe installer (Linux) - Docker Compose
#
# This installs and runs your Netprobe stack:
# - Postgres (named volume)
# - Netprobe (either from image, or build from ./probe if you provide source)
#
# Defaults are written to /opt/netprobe/.env and can be edited safely.
###############################################################################

### CONFIG (override via environment) #########################################

STACK_DIR="${STACK_DIR:-/opt/netprobe}"
COMPOSE_FILE="${COMPOSE_FILE:-${STACK_DIR}/docker-compose.yml}"
ENV_FILE="${ENV_FILE:-${STACK_DIR}/.env}"

# If you want to build Netprobe from source:
# - set NETPROBE_GIT_URL to a git repo URL that contains the Dockerfile in its root OR in ./probe
# - set NETPROBE_GIT_REF optionally (branch/tag/sha)
NETPROBE_GIT_URL="${NETPROBE_GIT_URL:-}"
NETPROBE_GIT_REF="${NETPROBE_GIT_REF:-}"

# If no git URL is provided, we run the published image by default.
NETPROBE_IMAGE="${NETPROBE_IMAGE:-bmmbmm01/netprobe:latest}"

### HELPERS ###################################################################

require_root() {
  if [[ ${EUID:-0} -ne 0 ]]; then
    echo >&2 "Run as root (or with sudo)."
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

pkg_install() {
  if need_cmd apt-get; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
  elif need_cmd dnf; then
    dnf -y install "$@"
  elif need_cmd yum; then
    yum -y install "$@"
  elif need_cmd pacman; then
    pacman -Sy --noconfirm --needed "$@"
  else
    echo >&2 "[!] Unsupported distro: need apt-get/dnf/yum/pacman"
    exit 1
  fi
}

ensure_docker() {
  if ! need_cmd docker; then
    echo "[*] Installing Docker (via get.docker.com)..."
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
}

docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif need_cmd docker-compose; then
    docker-compose "$@"
  else
    echo >&2 "[!] docker compose is missing. Install the Docker Compose plugin."
    exit 1
  fi
}

### MAIN ######################################################################

require_root

if ! [[ -d /run/systemd/system ]]; then
  echo >&2 "This installer expects systemd."
  exit 1
fi

echo "[*] Installing prerequisites..."
pkg_install ca-certificates curl

if [[ -n "$NETPROBE_GIT_URL" ]]; then
  pkg_install git
fi

ensure_docker

echo "[*] Creating ${STACK_DIR}..."
install -d -m 0755 "${STACK_DIR}"

if [[ -n "$NETPROBE_GIT_URL" ]]; then
  echo "[*] Cloning Netprobe source into ${STACK_DIR}/probe ..."
  if [[ -d "${STACK_DIR}/probe/.git" ]]; then
    git -C "${STACK_DIR}/probe" fetch --all --tags
  else
    rm -rf "${STACK_DIR}/probe"
    git clone "$NETPROBE_GIT_URL" "${STACK_DIR}/probe"
  fi
  if [[ -n "$NETPROBE_GIT_REF" ]]; then
    git -C "${STACK_DIR}/probe" checkout "$NETPROBE_GIT_REF"
  fi
fi

echo "[*] Writing env file at ${ENV_FILE} (edit anytime)..."
if [[ ! -f "${ENV_FILE}" ]]; then
  cat > "${ENV_FILE}" <<'EOF'
# ---- Netprobe defaults ----
WEB_PORT=8080
APP_TIMEZONE=UTC

# Ping targets
SITES=fast.com,google.com,youtube.com
ROUTER_IP=

# Probe timing
PROBE_INTERVAL=30
PING_COUNT=4

# DNS checks
DNS_TEST_SITE=google.com
DNS_NAMESERVER_1=Google_DNS
DNS_NAMESERVER_1_IP=8.8.8.8
DNS_NAMESERVER_2=Quad9_DNS
DNS_NAMESERVER_2_IP=9.9.9.9
DNS_NAMESERVER_3=CloudFlare_DNS
DNS_NAMESERVER_3_IP=1.1.1.1
DNS_NAMESERVER_4=My_DNS_Server
DNS_NAMESERVER_4_IP=192.168.1.1

# Score weights (sum to 1.0)
WEIGHT_LOSS=0.6
WEIGHT_LATENCY=0.15
WEIGHT_JITTER=0.2
WEIGHT_DNS_LATENCY=0.05

# Score thresholds
THRESHOLD_LOSS=5
THRESHOLD_LATENCY=100
THRESHOLD_JITTER=30
THRESHOLD_DNS_LATENCY=100

# Speedtest
SPEEDTEST_ENABLED=True
SPEEDTEST_INTERVAL=14400

# ---- Database defaults (Postgres) ----
DB_ENGINE=postgres
POSTGRES_DB=netprobe
POSTGRES_USER=netprobe
POSTGRES_PASSWORD=netprobe
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
EOF
fi

echo "[*] Writing docker-compose.yml at ${COMPOSE_FILE}..."
if [[ -n "$NETPROBE_GIT_URL" ]]; then
  netprobe_service=$(cat <<'EOF'
  netprobe:
    build: ./probe
    container_name: netprobe
EOF
)
else
  netprobe_service=$(cat <<EOF
  netprobe:
    image: ${NETPROBE_IMAGE}
    container_name: netprobe
EOF
)
fi

cat > "${COMPOSE_FILE}" <<EOF
services:
  postgres:
    image: postgres:16-alpine
    container_name: netprobe-postgres
    restart: unless-stopped
    env_file:
      - ./.env
    environment:
      POSTGRES_DB: \${POSTGRES_DB:-netprobe}
      POSTGRES_USER: \${POSTGRES_USER:-netprobe}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:-netprobe}
    volumes:
      - netprobe_pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER:-netprobe} -d \${POSTGRES_DB:-netprobe}"]
      interval: 10s
      timeout: 5s
      retries: 5

${netprobe_service}
    restart: unless-stopped
    env_file:
      - ./.env
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      WEB_PORT: \${WEB_PORT:-8080}
      DB_PATH: \${DB_PATH:-/data/netprobe.sqlite}
      DB_ENGINE: \${DB_ENGINE:-postgres}
      POSTGRES_HOST: \${POSTGRES_HOST:-postgres}
      POSTGRES_PORT: \${POSTGRES_PORT:-5432}
      POSTGRES_DB: \${POSTGRES_DB:-netprobe}
      POSTGRES_USER: \${POSTGRES_USER:-netprobe}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:-netprobe}
      PROBE_INTERVAL: \${PROBE_INTERVAL:-30}
      PING_COUNT: \${PING_COUNT:-4}
      APP_TIMEZONE: \${APP_TIMEZONE:-UTC}
      SITES: \${SITES:-fast.com,google.com,youtube.com}
      ROUTER_IP: \${ROUTER_IP:-}
      DNS_TEST_SITE: \${DNS_TEST_SITE:-google.com}
      DNS_NAMESERVER_1: \${DNS_NAMESERVER_1:-Google_DNS}
      DNS_NAMESERVER_1_IP: \${DNS_NAMESERVER_1_IP:-8.8.8.8}
      DNS_NAMESERVER_2: \${DNS_NAMESERVER_2:-Quad9_DNS}
      DNS_NAMESERVER_2_IP: \${DNS_NAMESERVER_2_IP:-9.9.9.9}
      DNS_NAMESERVER_3: \${DNS_NAMESERVER_3:-CloudFlare_DNS}
      DNS_NAMESERVER_3_IP: \${DNS_NAMESERVER_3_IP:-1.1.1.1}
      DNS_NAMESERVER_4: \${DNS_NAMESERVER_4:-My_DNS_Server}
      DNS_NAMESERVER_4_IP: \${DNS_NAMESERVER_4_IP:-192.168.1.1}
      WEIGHT_LOSS: \${WEIGHT_LOSS:-0.6}
      WEIGHT_LATENCY: \${WEIGHT_LATENCY:-0.15}
      WEIGHT_JITTER: \${WEIGHT_JITTER:-0.2}
      WEIGHT_DNS_LATENCY: \${WEIGHT_DNS_LATENCY:-0.05}
      THRESHOLD_LOSS: \${THRESHOLD_LOSS:-5}
      THRESHOLD_LATENCY: \${THRESHOLD_LATENCY:-100}
      THRESHOLD_JITTER: \${THRESHOLD_JITTER:-30}
      THRESHOLD_DNS_LATENCY: \${THRESHOLD_DNS_LATENCY:-100}
      SPEEDTEST_ENABLED: \${SPEEDTEST_ENABLED:-True}
      SPEEDTEST_INTERVAL: \${SPEEDTEST_INTERVAL:-14400}
    ports:
      - "\${WEB_PORT:-8080}:\${WEB_PORT:-8080}"
    volumes:
      - netprobe_data:/data
    cap_add:
      - NET_RAW

volumes:
  netprobe_data: {}
  netprobe_pgdata: {}
EOF

echo "[*] Starting stack..."
docker_compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" down --remove-orphans >/dev/null 2>&1 || true
docker_compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d --pull always --build

host_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
host_ip="${host_ip:-<this-host>}"

web_port="$(. "${ENV_FILE}" >/dev/null 2>&1; echo "${WEB_PORT:-8080}")"

echo
echo "==============================================================="
echo " Netprobe is running."
echo
echo " Web UI: http://${host_ip}:${web_port}"
echo " Config: ${ENV_FILE}"
echo " Compose: ${COMPOSE_FILE}"
echo
echo " Useful:"
echo "  docker ps"
echo "  docker logs netprobe --tail 50"
echo "  docker logs netprobe-postgres --tail 50"
echo "==============================================================="
echo

