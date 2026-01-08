#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo >&2 "[!] Error on line $LINENO: $BASH_COMMAND (exit $?)"' ERR

### CONFIG (override via environment) #########################################

STACK_DIR="${STACK_DIR:-/opt/monitoring-stack}"

PROM_PORT="${PROM_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
BLACKBOX_PORT="${BLACKBOX_PORT:-9115}"
SPEEDTEST_PORT="${SPEEDTEST_PORT:-9798}"

PROM_IMAGE="${PROM_IMAGE:-prom/prometheus:v2.53.0}"
GRAFANA_IMAGE="${GRAFANA_IMAGE:-grafana/grafana-oss:12.1.0}"
BLACKBOX_IMAGE="${BLACKBOX_IMAGE:-prom/blackbox-exporter:v0.26.0}"
SPEEDTEST_IMAGE="${SPEEDTEST_IMAGE:-miguelndecarvalho/speedtest-exporter:v3.5.4}"

# Grafana bootstrap creds (change after first login)
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"

# Grafana.com dashboard ID to auto-provision (internet connection)
DASHBOARD_ID="${DASHBOARD_ID:-24364}"

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
    echo >&2 "[!] docker compose plugin not found."
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

### MAIN ######################################################################

require_root

if ! [[ -d /run/systemd/system ]]; then
  echo >&2 "This installer expects systemd (no /run/systemd/system found)."
  exit 1
fi

echo "[*] Ensuring base tools..."
if need_cmd apt-get; then
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl python3
elif need_cmd dnf; then
  dnf -y install ca-certificates curl python3
elif need_cmd yum; then
  yum -y install ca-certificates curl python3
elif need_cmd pacman; then
  pacman -Sy --noconfirm --needed ca-certificates curl python
else
  echo >&2 "[!] Unsupported distro: need apt/dnf/yum/pacman"
  exit 1
fi

ensure_docker

echo "[*] Creating stack directory at ${STACK_DIR}..."
install -d -m 0755 "${STACK_DIR}"/{prometheus,blackbox,prometheus/data,grafana/data,grafana/provisioning/datasources,grafana/provisioning/dashboards,grafana/dashboards}

# Fix permissions for containers that run as non-root:
# - prom/prometheus runs as nobody (uid/gid 65534)
# - grafana runs as uid 472
chown -R 65534:65534 "${STACK_DIR}/prometheus/data" || true
chown -R 472:472 "${STACK_DIR}/grafana/data" || true

echo "[*] Writing Prometheus config..."
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
          - https://www.google.com
          - https://www.cloudflare.com
          - https://www.github.com
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

echo "[*] Downloading Grafana dashboard ${DASHBOARD_ID} and binding it to datasource uid=prometheus..."
dashboard_raw="${STACK_DIR}/grafana/dashboards/dashboard-${DASHBOARD_ID}.raw.json"
dashboard_out="${STACK_DIR}/grafana/dashboards/dashboard-${DASHBOARD_ID}.json"
curl -fsSL "https://grafana.com/api/dashboards/${DASHBOARD_ID}/revisions/1/download" -o "$dashboard_raw"

# Patch dashboard JSON to not require import-time datasource mapping.
python3 - <<PY
import json
from pathlib import Path

src = Path("${dashboard_raw}")
dst = Path("${dashboard_out}")
data = json.loads(src.read_text(encoding="utf-8"))

def walk(x):
  if isinstance(x, dict):
    out = {}
    for k, v in x.items():
      # Remove import-only inputs so Grafana doesn't expect mapping.
      if k == "__inputs":
        continue
      out[k] = walk(v)
    return out
  if isinstance(x, list):
    return [walk(i) for i in x]
  # Bind any DS_PROMETHEUS placeholders directly to our provisioned datasource.
  if x in ("\${DS_PROMETHEUS}", "\${DS_PROMETHEUS}"):
    return {"type": "prometheus", "uid": "prometheus"}
  return x

patched = walk(data)

def patch_datasource_fields(x):
  if isinstance(x, dict):
    # Older dashboards sometimes store datasource as a string; normalize common cases.
    if x.get("datasource") in ("Prometheus", "prometheus", "\${DS_PROMETHEUS}"):
      x["datasource"] = {"type": "prometheus", "uid": "prometheus"}
    for v in x.values():
      patch_datasource_fields(v)
  elif isinstance(x, list):
    for i in x:
      patch_datasource_fields(i)

patch_datasource_fields(patched)
dst.write_text(json.dumps(patched, indent=2), encoding="utf-8")
PY

rm -f "$dashboard_raw"

echo "[*] Writing docker compose file..."
cat > "${STACK_DIR}/docker-compose.yml" <<EOF
services:
  prometheus:
    image: ${PROM_IMAGE}
    container_name: prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --web.enable-lifecycle
    ports:
      - "${PROM_PORT}:9090"
    volumes:
      - "${STACK_DIR}/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro"
      - "${STACK_DIR}/prometheus/data:/prometheus"
    restart: unless-stopped

  blackbox-exporter:
    image: ${BLACKBOX_IMAGE}
    container_name: blackbox-exporter
    command:
      - --config.file=/config/blackbox.yml
    ports:
      - "${BLACKBOX_PORT}:9115"
    volumes:
      - "${STACK_DIR}/blackbox/blackbox.yml:/config/blackbox.yml:ro"
    restart: unless-stopped

  speedtest-exporter:
    image: ${SPEEDTEST_IMAGE}
    container_name: speedtest-exporter
    ports:
      - "${SPEEDTEST_PORT}:9798"
    restart: unless-stopped

  grafana:
    image: ${GRAFANA_IMAGE}
    container_name: grafana
    environment:
      - GF_SECURITY_ADMIN_USER=${GRAFANA_ADMIN_USER}
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
    ports:
      - "${GRAFANA_PORT}:3000"
    volumes:
      - "${STACK_DIR}/grafana/data:/var/lib/grafana"
      - "${STACK_DIR}/grafana/provisioning:/etc/grafana/provisioning:ro"
      - "${STACK_DIR}/grafana/dashboards:/var/lib/grafana/dashboards:ro"
    restart: unless-stopped
EOF

echo "[*] Starting stack..."
docker_compose -f "${STACK_DIR}/docker-compose.yml" up -d --pull always --force-recreate

host_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
host_ip="${host_ip:-<this-host>}"

echo
echo "==============================================================="
echo " Stack running (Docker Compose)."
echo
echo " Prometheus:  http://${host_ip}:${PROM_PORT}"
echo " Grafana:     http://${host_ip}:${GRAFANA_PORT}  (${GRAFANA_ADMIN_USER}/${GRAFANA_ADMIN_PASSWORD})"
echo
echo " Grafana should already have:"
echo " - Datasource: prometheus (default)"
echo " - Dashboard:  provisioned from grafana.com id ${DASHBOARD_ID}"
echo
echo " Config dir:  ${STACK_DIR}"
echo "==============================================================="
echo

