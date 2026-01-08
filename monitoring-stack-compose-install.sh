#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo >&2 "[!] Error on line $LINENO: $BASH_COMMAND (exit $?)"' ERR

###############################################################################
# Monitoring stack installer (Linux) - Docker Compose
#
# Installs/starts:
# - Prometheus
# - Grafana (provisioned Prometheus datasource)
# - Blackbox exporter
# - Speedtest exporter
#
# Key goals:
# - Works on Debian/Ubuntu (and many other distros)
# - No host bind-mount permission issues (uses named Docker volumes for data)
# - Cleans up old containers from earlier attempts (grafana/prometheus etc.)
###############################################################################

### CONFIG (override via environment) #########################################

PROJECT_NAME="${PROJECT_NAME:-monitoring-stack}"
STACK_DIR="${STACK_DIR:-/opt/monitoring-stack}"

PROM_PORT="${PROM_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
BLACKBOX_PORT="${BLACKBOX_PORT:-9115}"
SPEEDTEST_PORT="${SPEEDTEST_PORT:-9798}"

# Pin images for reproducibility
PROM_IMAGE="${PROM_IMAGE:-prom/prometheus:v2.53.0}"
GRAFANA_IMAGE="${GRAFANA_IMAGE:-grafana/grafana-oss:12.1.0}"
BLACKBOX_IMAGE="${BLACKBOX_IMAGE:-prom/blackbox-exporter:v0.26.0}"
SPEEDTEST_IMAGE="${SPEEDTEST_IMAGE:-miguelndecarvalho/speedtest-exporter:v3.5.4}"

# Grafana bootstrap creds (change after first login)
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"

# Space-separated list of URLs for blackbox probing
BLACKBOX_TARGETS="${BLACKBOX_TARGETS:-https://www.google.com https://www.cloudflare.com https://www.github.com}"

# Provision a dashboard file automatically (internet connection dashboard)
PROVISION_DASHBOARD="${PROVISION_DASHBOARD:-1}"
DASHBOARD_ID="${DASHBOARD_ID:-24364}"
DASHBOARD_REVISION="${DASHBOARD_REVISION:-1}"

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
    echo >&2 "[!] docker compose is missing. Re-run after installing Docker Compose plugin."
    exit 1
  fi
}

yaml_list_8() {
  # Print YAML list items indented by 8 spaces (for the targets: list)
  local item
  for item in "$@"; do
    printf "        - %s\n" "$item"
  done
}

cleanup_old_containers() {
  # Old versions used explicit container names; remove them to avoid conflicts.
  local c
  for c in prometheus grafana blackbox-exporter speedtest-exporter; do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
}

fix_named_volume_permissions() {
  # Ensure named volumes exist and are writeable by container users.
  # - Grafana runs as uid 472
  # - Prometheus runs as nobody (uid 65534) in official image
  local prom_vol="${PROJECT_NAME}_prometheus_data"
  local graf_vol="${PROJECT_NAME}_grafana_data"

  docker volume create "$prom_vol" >/dev/null
  docker volume create "$graf_vol" >/dev/null

  docker run --rm \
    -v "${prom_vol}:/prom" \
    -v "${graf_vol}:/graf" \
    alpine:3.20 \
    sh -euc 'chown -R 65534:65534 /prom && chown -R 472:472 /graf' >/dev/null
}

### MAIN ######################################################################

require_root

if ! [[ -d /run/systemd/system ]]; then
  echo >&2 "This installer expects systemd."
  exit 1
fi

echo "[*] Installing base dependencies..."
pkg_install ca-certificates curl python3

ensure_docker

echo "[*] Writing config under ${STACK_DIR}..."
install -d -m 0755 \
  "${STACK_DIR}/prometheus" \
  "${STACK_DIR}/blackbox" \
  "${STACK_DIR}/grafana/provisioning/datasources" \
  "${STACK_DIR}/grafana/provisioning/dashboards" \
  "${STACK_DIR}/grafana/dashboards"

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
$(yaml_list_8 "${targets[@]}")
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

echo "[*] Provisioning Grafana datasource (prometheus)..."
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

if [[ "${PROVISION_DASHBOARD}" == "1" ]]; then
  echo "[*] Provisioning Grafana dashboards provider..."
  cat > "${STACK_DIR}/grafana/provisioning/dashboards/provider.yml" <<'EOF'
apiVersion: 1
providers:
  - name: 'provisioned'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards
EOF

  echo "[*] Downloading and patching Grafana dashboard ${DASHBOARD_ID}..."
  raw="${STACK_DIR}/grafana/dashboards/dashboard-${DASHBOARD_ID}.raw.json"
  out="${STACK_DIR}/grafana/dashboards/dashboard-${DASHBOARD_ID}.json"
  curl -fsSL "https://grafana.com/api/dashboards/${DASHBOARD_ID}/revisions/${DASHBOARD_REVISION}/download" -o "$raw"

  # Patch dashboard JSON:
  # - Remove __inputs so Grafana doesn't require import-time datasource mapping
  # - Replace DS_PROMETHEUS placeholders and common datasource strings with uid-based datasource
  python3 - <<PY
import json
from pathlib import Path

src = Path("${raw}")
dst = Path("${out}")
data = json.loads(src.read_text(encoding="utf-8"))

DS_OBJ = {"type": "prometheus", "uid": "prometheus"}

def rewrite(x):
  if isinstance(x, dict):
    out = {}
    for k, v in x.items():
      if k == "__inputs":
        continue
      out[k] = rewrite(v)
    # normalize datasource fields
    if out.get("datasource") in ("Prometheus", "prometheus", "${DS_PROMETHEUS}"):
      out["datasource"] = DS_OBJ
    return out
  if isinstance(x, list):
    return [rewrite(i) for i in x]
  if isinstance(x, str) and x == "${DS_PROMETHEUS}":
    return DS_OBJ
  return x

patched = rewrite(data)
dst.write_text(json.dumps(patched, indent=2), encoding="utf-8")
PY
  rm -f "$raw"
fi

echo "[*] Writing docker compose file..."
cat > "${STACK_DIR}/docker-compose.yml" <<EOF
name: ${PROJECT_NAME}

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
      - "${STACK_DIR}/grafana/dashboards:/var/lib/grafana/dashboards:ro"
    restart: unless-stopped

volumes:
  prometheus_data: {}
  grafana_data: {}
EOF

echo "[*] Stopping any existing stack (safe if none)..."
docker_compose -f "${STACK_DIR}/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
cleanup_old_containers
fix_named_volume_permissions

echo "[*] Starting stack..."
docker_compose -f "${STACK_DIR}/docker-compose.yml" up -d --pull always --force-recreate --remove-orphans

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
if [[ "${PROVISION_DASHBOARD}" == "1" ]]; then
  echo " - Dashboard:  grafana.com id ${DASHBOARD_ID} (provisioned)"
fi
echo
echo " Useful commands:"
echo "   docker ps"
echo "   docker logs ${PROJECT_NAME}-grafana-1 --tail 50"
echo "   docker logs ${PROJECT_NAME}-prometheus-1 --tail 50"
echo
echo " Config dir: ${STACK_DIR}"
echo "==============================================================="
echo

