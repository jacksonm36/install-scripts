#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo >&2 "[!] Error on line $LINENO: $BASH_COMMAND (exit $?)"' ERR

### CONFIG (override via environment) #########################################

STACK_DIR="${STACK_DIR:-/opt/monitoring-stack}"

PROM_PORT="${PROM_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
BLACKBOX_PORT="${BLACKBOX_PORT:-9115}"
SPEEDTEST_PORT="${SPEEDTEST_PORT:-9798}"

# Pin images for reproducibility (override if you want newer)
PROM_IMAGE="${PROM_IMAGE:-prom/prometheus:v2.53.0}"
GRAFANA_IMAGE="${GRAFANA_IMAGE:-grafana/grafana-oss:12.1.0}"
BLACKBOX_IMAGE="${BLACKBOX_IMAGE:-prom/blackbox-exporter:v0.26.0}"
SPEEDTEST_IMAGE="${SPEEDTEST_IMAGE:-miguelndecarvalho/speedtest-exporter:v3.5.4}"

# Grafana bootstrap creds (change after first login)
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"

# Space-separated list of URLs to probe via blackbox (override as needed)
BLACKBOX_TARGETS="${BLACKBOX_TARGETS:-https://www.google.com https://www.cloudflare.com https://www.github.com}"

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

docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif need_cmd docker-compose; then
    docker-compose "$@"
  else
    echo >&2 "[!] docker compose is missing. Install the Docker Compose plugin or docker-compose."
    exit 1
  fi
}

ensure_base_tools() {
  if need_cmd apt-get; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl
  elif need_cmd dnf; then
    dnf -y install ca-certificates curl
  elif need_cmd yum; then
    yum -y install ca-certificates curl
  elif need_cmd pacman; then
    pacman -Sy --noconfirm --needed ca-certificates curl
  else
    echo >&2 "[!] Unsupported distro: need apt/dnf/yum/pacman"
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

yaml_list() {
  # Print a YAML list of items passed as args with proper indentation (4 spaces).
  local item
  for item in "$@"; do
    printf "        - %s\n" "$item"
  done
}

### MAIN ######################################################################

require_root

if ! [[ -d /run/systemd/system ]]; then
  echo >&2 "This installer expects systemd."
  exit 1
fi

ensure_base_tools
ensure_docker

echo "[*] Writing stack config under ${STACK_DIR}..."
install -d -m 0755 \
  "${STACK_DIR}/prometheus" \
  "${STACK_DIR}/blackbox" \
  "${STACK_DIR}/grafana/provisioning/datasources"

echo "[*] Writing Prometheus config..."
targets=()
while IFS= read -r t; do
  [[ -n "$t" ]] && targets+=("$t")
done < <(printf "%s\n" ${BLACKBOX_TARGETS})

cat > "${STACK_DIR}/prometheus/prometheus.yml" <<EOF
global:
  scrape_interval: 30s
  evaluation_interval: 30s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['prometheus:9090']

  - job_name: 'speedtest'
    metrics_path: /metrics
    scrape_interval: 30m
    scrape_timeout: 90s
    static_configs:
      - targets: ['speedtest-exporter:9798']

  - job_name: 'blackbox'
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
$(yaml_list "${targets[@]}")
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115

  - job_name: 'blackbox-exporter'
    static_configs:
      - targets: ['blackbox-exporter:9115']
EOF

echo "[*] Writing Blackbox exporter config..."
cat > "${STACK_DIR}/blackbox/blackbox.yml" <<'EOF'
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      method: GET
      preferred_ip_protocol: "ip4"
EOF

echo "[*] Provisioning Grafana datasource..."
cat > "${STACK_DIR}/grafana/provisioning/datasources/prometheus.yml" <<EOF
apiVersion: 1
datasources:
  - name: prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
EOF

echo "[*] Writing docker compose file..."
cat > "${STACK_DIR}/docker-compose.yml" <<EOF
name: monitoring-stack

services:
  prometheus:
    image: ${PROM_IMAGE}
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
    ports:
      - "${PROM_PORT}:9090"
    volumes:
      - "${STACK_DIR}/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro"
      - prometheus_data:/prometheus
    restart: unless-stopped

  blackbox-exporter:
    image: ${BLACKBOX_IMAGE}
    command:
      - --config.file=/config/blackbox.yml
    ports:
      - "${BLACKBOX_PORT}:9115"
    volumes:
      - "${STACK_DIR}/blackbox/blackbox.yml:/config/blackbox.yml:ro"
    restart: unless-stopped

  speedtest-exporter:
    image: ${SPEEDTEST_IMAGE}
    ports:
      - "${SPEEDTEST_PORT}:9798"
    restart: unless-stopped

  grafana:
    image: ${GRAFANA_IMAGE}
    environment:
      - GF_SECURITY_ADMIN_USER=${GRAFANA_ADMIN_USER}
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
    ports:
      - "${GRAFANA_PORT}:3000"
    volumes:
      - grafana_data:/var/lib/grafana
      - "${STACK_DIR}/grafana/provisioning:/etc/grafana/provisioning:ro"
    restart: unless-stopped

volumes:
  prometheus_data: {}
  grafana_data: {}
EOF

echo "[*] Starting stack..."
docker_compose -f "${STACK_DIR}/docker-compose.yml" up -d --pull always

host_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
host_ip="${host_ip:-<this-host>}"

echo
echo "==============================================================="
echo " Stack running (Docker Compose)."
echo
echo " Prometheus:  http://${host_ip}:${PROM_PORT}"
echo " Grafana:     http://${host_ip}:${GRAFANA_PORT}  (${GRAFANA_ADMIN_USER}/${GRAFANA_ADMIN_PASSWORD})"
echo
echo " Grafana provisioned:"
echo " - Datasource: prometheus (default)"
echo
echo " Config dir: ${STACK_DIR}"
echo " Update targets: edit BLACKBOX_TARGETS or ${STACK_DIR}/prometheus/prometheus.yml"
echo "==============================================================="
echo

