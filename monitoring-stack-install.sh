#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo >&2 "[!] Error on line $LINENO: $BASH_COMMAND (exit $?)"' ERR

### CONFIG (override via environment) #########################################

PROM_VERSION="${PROM_VERSION:-2.53.0}"
GRAFANA_VERSION="${GRAFANA_VERSION:-12.1.0}"

PROM_USER="${PROM_USER:-prometheus}"
PROM_DATA="${PROM_DATA:-/var/lib/prometheus}"
PROM_CFG="${PROM_CFG:-/etc/prometheus}"

BB_CFG="${BB_CFG:-/etc/blackbox_exporter/blackbox.yml}"

PROM_PORT="${PROM_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
SPEEDTEST_PORT="${SPEEDTEST_PORT:-9798}"
BLACKBOX_PORT="${BLACKBOX_PORT:-9115}"

### HELPERS ###################################################################

require_root() {
  if [[ ${EUID:-0} -ne 0 ]]; then
    echo >&2 "Run as root (or with sudo)."
    exit 1
  fi
}

arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *)
      echo >&2 "[!] Unsupported CPU architecture: ${m}"
      exit 1
      ;;
  esac
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

detect_pkg_mgr() {
  if need_cmd apt-get; then
    echo "apt"
  elif need_cmd dnf; then
    echo "dnf"
  elif need_cmd yum; then
    echo "yum"
  elif need_cmd pacman; then
    echo "pacman"
  else
    echo >&2 "[!] Unsupported distro: no apt-get/dnf/yum/pacman found."
    exit 1
  fi
}

pkg_update() {
  case "$(detect_pkg_mgr)" in
    apt) apt-get update -y ;;
    dnf) dnf -y makecache ;;
    yum) yum -y makecache ;;
    pacman) pacman -Sy --noconfirm ;;
  esac
}

pkg_install() {
  case "$(detect_pkg_mgr)" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
    dnf) dnf -y install "$@" ;;
    yum) yum -y install "$@" ;;
    pacman) pacman -S --noconfirm --needed "$@" ;;
  esac
}

download() {
  # download URL DEST
  local url="$1"
  local dest="$2"
  curl -fsSL "$url" -o "$dest"
}

verify_sha256() {
  # verify_sha256 FILE SHA256SUM
  local file="$1"
  local expected="$2"
  echo "${expected}  ${file}" | sha256sum -c - >/dev/null
}

### PRECHECK ##################################################################

require_root

if ! [[ -d /run/systemd/system ]]; then
  echo >&2 "This installer expects systemd (no /run/systemd/system found)."
  exit 1
fi

echo "[*] Installing base packages..."
pkg_update
case "$(detect_pkg_mgr)" in
  apt) pkg_install ca-certificates curl gnupg tar wget ;;
  dnf|yum) pkg_install ca-certificates curl gnupg2 tar wget ;;
  pacman) pkg_install ca-certificates curl gnupg tar wget ;;
esac

### DOCKER (for exporters) ####################################################

if ! need_cmd docker; then
  echo "[*] Installing Docker (via get.docker.com)..."
  curl -fsSL https://get.docker.com | sh
fi

systemctl enable --now docker

### PROMETHEUS ################################################################

echo "[*] Creating Prometheus user and directories..."
if ! id -u "$PROM_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "$PROM_USER"
fi

install -d -m 0755 "$PROM_CFG"
install -d -m 0755 "$PROM_DATA"
chown -R "$PROM_USER:$PROM_USER" "$PROM_DATA" "$PROM_CFG"

echo "[*] Installing Prometheus ${PROM_VERSION}..."
tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

prom_arch="$(arch)"
prom_tar="prometheus-${PROM_VERSION}.linux-${prom_arch}.tar.gz"
prom_url="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${prom_tar}"
prom_sha_url="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/sha256sums.txt"

download "$prom_url" "${tmpdir}/${prom_tar}"
download "$prom_sha_url" "${tmpdir}/sha256sums.txt"

# sha256sums.txt format: "<sha>  <filename>"
prom_expected_sha="$(
  awk -v f="${prom_tar}" '$2 == f { print $1 }' "${tmpdir}/sha256sums.txt" | head -n1
)"
if [[ -z "${prom_expected_sha}" ]]; then
  echo >&2 "[!] Could not find SHA256 for ${prom_tar} in sha256sums.txt"
  exit 1
fi
verify_sha256 "${tmpdir}/${prom_tar}" "$prom_expected_sha"

tar -xzf "${tmpdir}/${prom_tar}" -C "$tmpdir"

install -m 0755 "${tmpdir}/prometheus-${PROM_VERSION}.linux-${prom_arch}/prometheus" /usr/local/bin/prometheus
install -m 0755 "${tmpdir}/prometheus-${PROM_VERSION}.linux-${prom_arch}/promtool" /usr/local/bin/promtool

rm -rf "${PROM_CFG}/consoles" "${PROM_CFG}/console_libraries"
cp -r "${tmpdir}/prometheus-${PROM_VERSION}.linux-${prom_arch}/consoles" "${PROM_CFG}/"
cp -r "${tmpdir}/prometheus-${PROM_VERSION}.linux-${prom_arch}/console_libraries" "${PROM_CFG}/"
chown -R "$PROM_USER:$PROM_USER" "$PROM_CFG"

echo "[*] Writing Prometheus config..."
cat > "${PROM_CFG}/prometheus.yml" <<EOF
global:
  scrape_interval: 30s
  evaluation_interval: 30s

scrape_configs:
  - job_name: 'speedtest'
    metrics_path: /metrics
    scrape_interval: 30m
    scrape_timeout: 90s
    static_configs:
      - targets: ['localhost:${SPEEDTEST_PORT}']

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
        replacement: localhost:${BLACKBOX_PORT}

  - job_name: 'blackbox-exporter'
    static_configs:
      - targets: ['localhost:${BLACKBOX_PORT}']
EOF
chown "$PROM_USER:$PROM_USER" "${PROM_CFG}/prometheus.yml"
chmod 0644 "${PROM_CFG}/prometheus.yml"

echo "[*] Creating systemd unit for Prometheus..."
cat > /etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus
After=network-online.target
Wants=network-online.target

[Service]
User=${PROM_USER}
Group=${PROM_USER}
Type=simple
ExecStart=/usr/local/bin/prometheus \\
  --config.file=${PROM_CFG}/prometheus.yml \\
  --storage.tsdb.path=${PROM_DATA} \\
  --web.listen-address=:${PROM_PORT} \\
  --web.console.templates=${PROM_CFG}/consoles \\
  --web.console.libraries=${PROM_CFG}/console_libraries
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=${PROM_DATA} ${PROM_CFG}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now prometheus

### BLACKBOX EXPORTER (Docker) ################################################

echo "[*] Writing Blackbox exporter config..."
install -d -m 0755 "$(dirname "$BB_CFG")"
cat > "${BB_CFG}" <<'EOF'
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []
      method: GET
      preferred_ip_protocol: "ip4"
EOF

echo "[*] Starting Blackbox exporter container..."
docker rm -f blackbox-exporter >/dev/null 2>&1 || true
docker pull prom/blackbox-exporter:latest >/dev/null
docker run -d \
  --name blackbox-exporter \
  -p "${BLACKBOX_PORT}:9115" \
  -v "${BB_CFG}":/config/blackbox.yml:ro \
  --restart unless-stopped \
  prom/blackbox-exporter:latest \
  --config.file=/config/blackbox.yml

### SPEEDTEST EXPORTER (Docker) ###############################################

echo "[*] Starting Speedtest exporter container..."
docker rm -f speedtest-exporter >/dev/null 2>&1 || true
docker pull miguelndecarvalho/speedtest-exporter:latest >/dev/null
docker run -d \
  --name speedtest-exporter \
  -p "${SPEEDTEST_PORT}:9798" \
  --restart unless-stopped \
  miguelndecarvalho/speedtest-exporter:latest

### GRAFANA ###################################################################

echo "[*] Installing Grafana ${GRAFANA_VERSION}..."
grafana_arch="$(arch)" # amd64|arm64
pkg_mgr="$(detect_pkg_mgr)"

if [[ "$pkg_mgr" == "apt" ]]; then
  grafana_deb="grafana_${GRAFANA_VERSION}_${grafana_arch}.deb"
  grafana_url="https://dl.grafana.com/oss/release/${grafana_deb}"
  grafana_sha_url="${grafana_url}.sha256"

  download "$grafana_url" "${tmpdir}/${grafana_deb}"
  download "$grafana_sha_url" "${tmpdir}/${grafana_deb}.sha256"

  grafana_expected_sha="$(cut -d' ' -f1 < "${tmpdir}/${grafana_deb}.sha256")"
  verify_sha256 "${tmpdir}/${grafana_deb}" "$grafana_expected_sha"

  pkg_install adduser libfontconfig1
  dpkg -i "${tmpdir}/${grafana_deb}" || apt-get -f install -y
else
  case "$grafana_arch" in
    amd64) grafana_rpm_arch="x86_64" ;;
    arm64) grafana_rpm_arch="aarch64" ;;
  esac

  grafana_rpm="grafana-${GRAFANA_VERSION}-1.${grafana_rpm_arch}.rpm"
  grafana_url="https://dl.grafana.com/oss/release/${grafana_rpm}"
  grafana_sha_url="${grafana_url}.sha256"

  download "$grafana_url" "${tmpdir}/${grafana_rpm}"
  download "$grafana_sha_url" "${tmpdir}/${grafana_rpm}.sha256"

  grafana_expected_sha="$(cut -d' ' -f1 < "${tmpdir}/${grafana_rpm}.sha256")"
  verify_sha256 "${tmpdir}/${grafana_rpm}" "$grafana_expected_sha"

  # fontconfig is required by Grafana; package name differs by distro family.
  case "$pkg_mgr" in
    dnf|yum) pkg_install fontconfig ;;
    pacman) pkg_install fontconfig ;;
  esac

  case "$pkg_mgr" in
    dnf) dnf -y install "${tmpdir}/${grafana_rpm}" ;;
    yum) yum -y install "${tmpdir}/${grafana_rpm}" ;;
    pacman)
      echo >&2 "[!] Grafana RPM install not supported on pacman-based distros."
      exit 1
      ;;
  esac
fi

systemctl daemon-reload
systemctl enable --now grafana-server

echo "[*] Provisioning Grafana Prometheus datasource..."
install -d -m 0755 /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/prometheus.yml <<EOF
apiVersion: 1

datasources:
  - name: prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://localhost:${PROM_PORT}
    isDefault: true
    editable: true
EOF

systemctl restart grafana-server

### SUMMARY ###################################################################

host_ip="$(hostname -I 2>/dev/null | cut -d' ' -f1 || true)"
host_ip="${host_ip:-<this-host>}"

echo
echo "==============================================================="
echo " Stack installed."
echo
echo " Prometheus:        http://${host_ip}:${PROM_PORT}"
echo " Grafana:           http://${host_ip}:${GRAFANA_PORT}  (default admin/admin)"
echo
echo " Next steps:"
echo " 1) Log into Grafana."
echo " 2) Add Prometheus data source: http://localhost:${PROM_PORT}"
echo " 3) Import dashboard ID: 24364 (Internet Connection)."
echo "==============================================================="
echo

